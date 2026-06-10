{-# LANGUAGE DerivingStrategies     #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE NamedFieldPuns         #-}

module PubGrub.Solver
  ( -- * Provider
    DependencyProvider (..)
    -- * Partial solution
  , Assignment (..)
  , assignmentTerm
  , PartialSolution (..)
  , emptyPS
  , addDecision
  , addDerivation
  , backtrack
  , termIntersectionForPackage
  , relation
  , extractSolution
  , undecidedPositive
    -- * Conflict resolution
  , conflictResolution
    -- * Unit propagation
  , unitPropagation
    -- * Solve
  , SolveError (..)
  , solve
    -- * Reporting
  , reportConflict
  ) where

import           Data.List            (intercalate, maximumBy)
import           Data.Map.Strict      (Map)
import qualified Data.Map.Strict      as Map
import           Data.Maybe           (mapMaybe)
import           Data.Ord             (comparing)
import           Distribution.Version (Version)

import           PubGrub.Types
import           PubGrub.VersionSet   (VersionSet)
import qualified PubGrub.VersionSet   as VS

-- | The oracle: pick a version in a range and report a version's dependencies.
-- Effects (e.g. lazy index loading) run in the monad @m@.
class (Package p, Monad m) => DependencyProvider dp p m | dp -> p where
  chooseVersion   :: dp -> p -> VersionSet -> m (Maybe Version)
  getDependencies :: dp -> p -> Version -> m (Map p VersionSet)

-- | A single entry in the partial solution.
data Assignment p
  = Decision
      { aIndex   :: !Int
      , aLevel   :: !Int
      , aPackage :: p
      , aVersion :: Version
      }
  | Derivation
      { aIndex   :: !Int
      , aLevel   :: !Int
      , aPackage :: p
      , aTerm    :: Term
      , aCause   :: Incompatibility p
      }
  deriving stock (Show)

-- | The term contributed by an assignment.
assignmentTerm :: Assignment p -> Term
assignmentTerm Decision{aVersion} = exactTerm aVersion
assignmentTerm Derivation{aTerm}  = aTerm

-- | Assignments are stored newest-first; @psLevel@ is the current decision
-- level; @psNextIndex@ is a monotone counter giving chronological order.
data PartialSolution p = PartialSolution
  { psAssignments :: [Assignment p]
  , psLevel       :: !Int
  , psNextIndex   :: !Int
  }
  deriving stock (Show)

emptyPS :: PartialSolution p
emptyPS = PartialSolution { psAssignments = [], psLevel = 0, psNextIndex = 0 }

-- | Record a decision (a guess); increments the decision level.
addDecision :: p -> Version -> PartialSolution p -> PartialSolution p
addDecision p v ps@PartialSolution{psAssignments, psLevel, psNextIndex} =
  ps { psAssignments = Decision psNextIndex (psLevel + 1) p v : psAssignments
     , psLevel = psLevel + 1
     , psNextIndex = psNextIndex + 1
     }

-- | Record a derivation: the negation of @cause@'s term for @p@, at the
-- current level.
addDerivation :: Ord p => p -> Incompatibility p -> PartialSolution p -> PartialSolution p
addDerivation p cause ps@PartialSolution{psAssignments, psLevel, psNextIndex} =
  let term = maybe anyTerm negateTerm (incompGet p cause)
  in ps { psAssignments = Derivation psNextIndex psLevel p term cause : psAssignments
        , psNextIndex = psNextIndex + 1
        }

-- | Backtrack: drop every assignment strictly above the target level.
backtrack :: Int -> PartialSolution p -> PartialSolution p
backtrack level ps@PartialSolution{psAssignments} =
  ps { psAssignments = filter ((<= level) . aLevel) psAssignments
     , psLevel = level
     }

-- | Intersection of all terms recorded for a package (Nothing if absent).
termIntersectionForPackage :: Ord p => PartialSolution p -> p -> Maybe Term
termIntersectionForPackage PartialSolution{psAssignments} p =
  case [ assignmentTerm a | a <- psAssignments, aPackage a == p ] of
    []       -> Nothing
    (t : ts) -> Just (foldl' intersectTerms t ts)

-- | Relation of the whole partial solution to an incompatibility.
relation :: Ord p => PartialSolution p -> Incompatibility p -> IncompatRelation p
relation ps = incompRelation (termIntersectionForPackage ps)

-- | The decisions, as a solution map.
extractSolution :: Ord p => PartialSolution p -> Map p Version
extractSolution PartialSolution{psAssignments} =
  Map.fromList [ (aPackage a, aVersion a) | a@Decision{} <- psAssignments ]

-- | Packages that have a positive accumulated term but no decision yet,
-- with that positive range. Chronological (oldest first) for determinism.
undecidedPositive :: Ord p => PartialSolution p -> [(p, VersionSet)]
undecidedPositive ps@PartialSolution{psAssignments} =
  let decided = [ aPackage a | a@Decision{} <- psAssignments ]
      pkgs = uniqueOldestFirst [ aPackage a | a <- reverse psAssignments ]
  in mapMaybe positive (filter (`notElem` decided) pkgs)
  where
    positive p = case termIntersectionForPackage ps p of
      Just (Positive r) -> Just (p, r)
      _                 -> Nothing
    uniqueOldestFirst = go []
      where go seen [] = reverse seen
            go seen (x:xs) | x `elem` seen = go seen xs
                           | otherwise     = go (x:seen) xs

-- | All assignments for a package, oldest first.
packageHistory :: Ord p => PartialSolution p -> p -> [Assignment p]
packageHistory PartialSolution{psAssignments} p =
  reverse [ a | a <- psAssignments, aPackage a == p ]

-- | Earliest assignment of @p@ whose running accumulated term becomes disjoint
-- from @startTerm@.
-- Precondition: such an assignment exists (guaranteed during conflict resolution).
satisfierOf :: Ord p => PartialSolution p -> p -> Term -> Assignment p
satisfierOf ps p startTerm = go anyTerm (packageHistory ps p)
  where
    go _ [] = error "satisfierOf: no satisfier (precondition violated)"
    go acc (a : as) =
      let acc' = intersectTerms acc (assignmentTerm a)
      in if termIsDisjoint acc' startTerm then a else go acc' as

-- | Result of searching for the satisfier of a conflict incompatibility.
data SatisfierSearch p
  = DifferentDecisionLevels !Int               -- ^ backtrack to this level
  | SameDecisionLevels (Incompatibility p)      -- ^ satisfier's cause

-- | The satisfier of an incompatibility is the latest of its terms' satisfiers.
-- When the satisfier is a derivation and the previous satisfier sits at its
-- level, resolution continues with the satisfier's cause; otherwise it
-- backtracks to the previous satisfier's level (at least 1).
satisfierSearch :: Ord p => PartialSolution p -> Incompatibility p -> (p, SatisfierSearch p)
satisfierSearch ps i =
  let satMap = [ (p, satisfierOf ps p (negateTerm it))
               | (p, it) <- Map.toList (incompTerms i) ]
      (satPkg, satAssign) = maximumBy (comparing (aIndex . snd)) satMap
      satLevel = aLevel satAssign
      it_s = maybe anyTerm id (incompGet satPkg i)
      startTerm' = intersectTerms (assignmentTerm satAssign) (negateTerm it_s)
      prevForSat = satisfierOf ps satPkg startTerm'
      satMap' = [ (p, if p == satPkg then prevForSat else a) | (p, a) <- satMap ]
      prevLevel = max 1 (aLevel (snd (maximumBy (comparing (aIndex . snd)) satMap')))
  in case satAssign of
       Derivation{aCause}
         | prevLevel >= satLevel -> (satPkg, SameDecisionLevels aCause)
       _ -> (satPkg, DifferentDecisionLevels prevLevel)

-- | Conflict resolution loop. Returns either the terminal (unsatisfiable)
-- incompatibility, or @(almostPackage, rootCause, backtrackedSolution)@.
conflictResolution
  :: Ord p
  => p -> Version           -- ^ root package and version (for is-terminal)
  -> Incompatibility p      -- ^ the satisfied (conflict) incompatibility
  -> PartialSolution p
  -> Either (Incompatibility p) (p, Incompatibility p, PartialSolution p)
conflictResolution rootPkg rootV = loop
  where
    loop current ps
      | isTerminal rootPkg rootV current = Left current
      | otherwise =
          case satisfierSearch ps current of
            (satPkg, DifferentDecisionLevels prevLevel) ->
              Right (satPkg, current, backtrack prevLevel ps)
            (satPkg, SameDecisionLevels satCause) ->
              loop (priorCause current satCause satPkg) ps

-- | Naïve unit propagation: repeatedly scan all
-- incompatibilities until a fixpoint, handling conflicts via
-- 'conflictResolution'. Returns the (possibly extended) incompatibility list
-- and updated partial solution, or a terminal incompatibility on failure.
unitPropagation
  :: Ord p
  => p -> Version
  -> [Incompatibility p]
  -> PartialSolution p
  -> Either (Incompatibility p) ([Incompatibility p], PartialSolution p)
unitPropagation rootPkg rootV = scan
  where
    scan incompats ps = step incompats ps incompats

    -- Walk the worklist of incompatibilities once; on any action, restart scan.
    step incompats ps [] = Right (incompats, ps)   -- fixpoint
    step incompats ps (i : rest) =
      case relation ps i of
        ISatisfied ->
          case conflictResolution rootPkg rootV i ps of
            Left terminal -> Left terminal
            Right (almostPkg, rootCause, ps') ->
              let ps'' = addDerivation almostPkg rootCause ps'
              in scan (rootCause : incompats) ps''
        IAlmostSatisfied q ->
          scan incompats (addDerivation q i ps)
        _ -> step incompats ps rest

-- | Failure: no solution; carries the terminal incompatibility (the root of
-- the derivation tree, for reporting).
newtype SolveError p = NoSolution (Incompatibility p)
  deriving stock (Eq, Show)

-- | Solve for a root package pinned to @rootV@. Returns a complete assignment
-- or a 'SolveError'.
solve
  :: DependencyProvider dp p m
  => dp -> p -> Version
  -> m (Either (SolveError p) (Map p Version))
solve dp rootPkg rootV = go [notRoot rootPkg rootV] emptyPS
  where
    go incompats ps =
      case unitPropagation rootPkg rootV incompats ps of
        Left terminal -> pure (Left (NoSolution terminal))
        Right (incompats', ps') ->
          case undecidedPositive ps' of
            [] -> pure (Right (extractSolution ps'))
            ((p, range) : _) -> do
              mv <- chooseVersion dp p range
              case mv of
                Nothing ->
                  -- No version available in the allowed range: ban it and let
                  -- the next propagation turn it into a conflict.
                  go (noVersions p range : incompats') ps'
                Just v -> do
                  deps <- getDependencies dp p v
                  let depIncs =
                        [ fromDependency p (VS.singleton v) (q, r)
                        | (q, r) <- Map.toList deps ]
                  go (depIncs ++ incompats') (addDecision p v ps')

-- | Render an incompatibility (and its derivation, if any) as a human-readable
-- proof. Leaves describe external facts. A subderivation used twice is
-- written out twice, not numbered and referred back to.
reportConflict :: (Package p) => Incompatibility p -> String
reportConflict = render
  where
    render i = case incompCause i of
      DerivedFrom c1 c2 ->
        "Because " ++ render c1 ++ " and " ++ render c2
          ++ ", " ++ summary i ++ "."
      _ -> summary i

    summary i = case Map.toList (incompTerms i) of
      [] -> "version solving failed"
      [(p, Positive r)] -> show p ++ " " ++ showVS r ++ " is forbidden"
      [(p, Negative r)] -> show p ++ " " ++ showVS r ++ " is mandatory"
      [(p1, Positive r1), (p2, Negative r2)] -> dep p1 r1 p2 r2
      [(p2, Negative r2), (p1, Positive r1)] -> dep p1 r1 p2 r2
      terms -> intercalate ", " [ showTerm p t | (p, t) <- terms ] ++ " are incompatible"

    dep p1 r1 p2 r2 =
      show p1 ++ " " ++ showVS r1 ++ " depends on " ++ show p2 ++ " " ++ showVS r2
    showTerm p (Positive r) = show p ++ " " ++ showVS r
    showTerm p (Negative r) = show p ++ " not " ++ showVS r
    showVS = show . VS.intervals
