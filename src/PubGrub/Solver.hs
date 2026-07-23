{-# LANGUAGE LambdaCase #-}

-- | The PubGrub solving loop, over whole package instances.
module PubGrub.Solver
    ( -- * Provider
      Provider (..)

      -- * Partial solution
    , Assignment (..)
    , assignmentTerm
    , assignmentPackageTerm
    , PartialSolution (..)
    , emptyPS
    , addDecision
    , addDerivation
    , backtrack
    , termIntersectionForPackage
    , psRelation
    , extractSolution
    , undecidedPositive
    , packageHistory

      -- * The algorithm
    , unitPropagation
    , conflictResolution
    , SolveError (..)
    , SolverMsg (..)
    , solve
    ) where

import           Colog                          (WithLog, logMsg)
import           Data.Foldable                  (Foldable (..), maximumBy)
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Data.Maybe                     (fromMaybe, mapMaybe)
import           Data.Ord                       (comparing)
import           Data.Sequence                  (Seq)
import qualified Data.Sequence                  as Seq
import           Distribution.Types.PackageName
import           PubGrub.Incompatibility        (IncompatRelation (..),
                                                 Incompatibility (..),
                                                 PackageTerm (..), anyTerm,
                                                 incompGet, incompRelation,
                                                 isTerminal, noInstances,
                                                 notRoot, priorCause)
import           PubGrub.InstanceSet            (Instance, InstanceSet,
                                                 singletonInstance)
import           PubGrub.Provider               (Provider (..))
import           PubGrub.SetOps                 (SetOps (..))
import           PubGrub.Term                   (Term (..), intersectTerm,
                                                 negateTerm)


-- --------------------------------------------------------------------------
-- Partial solution
-- --------------------------------------------------------------------------

-- | A single entry in the partial solution: a decision (a freely chosen
-- singleton instance) or a derivation (a term forced by unit propagation,
-- with the incompatibility that forced it as its cause).
data Assignment
    = Decision
        { aIndex    :: !Int
        , aLevel    :: !Int
        , aPackage  :: PackageName
        , aInstance :: Instance
        }
    | Derivation
        { aIndex   :: !Int
        , aLevel   :: !Int
        , aPackage :: PackageName
        , aTerm    :: Term InstanceSet
        , aCause   :: Incompatibility
        }
    deriving (Eq, Show)

-- | The term contributed by an assignment; for a decision, @Positive@ of the
-- singleton.
assignmentTerm :: Assignment -> Term InstanceSet
assignmentTerm Decision{aInstance} = Positive (singletonInstance aInstance)
assignmentTerm Derivation{aTerm}   = aTerm

-- | The assignment as "one term about one package".
assignmentPackageTerm :: Assignment -> PackageTerm
assignmentPackageTerm a = PackageTerm (aPackage a) (assignmentTerm a)

-- | Assignments are stored oldest-first (chronological), so the satisfier
-- search reads them in order without reversing; @psLevel@ is the current
-- decision level; @psNextIndex@ is a monotone counter giving chronological
-- order.
data PartialSolution = PartialSolution
    { psAssignments :: Seq Assignment
    , psLevel       :: !Int
    , psNextIndex   :: !Int
    }
    deriving (Eq, Show)

emptyPS :: PartialSolution
emptyPS = PartialSolution{psAssignments = Seq.empty, psLevel = 0, psNextIndex = 0}

-- | Record a decision (a guess); increments the decision level.
addDecision :: PackageName -> Instance -> PartialSolution -> PartialSolution
addDecision p i ps@PartialSolution{psAssignments, psLevel, psNextIndex} =
    ps
        { psAssignments = psAssignments Seq.|> Decision psNextIndex (psLevel + 1) p i
        , psLevel = psLevel + 1
        , psNextIndex = psNextIndex + 1
        }

-- | Record a derivation: the negation of @cause@'s term for @p@, at the
-- current level.
addDerivation :: PackageName -> Incompatibility -> PartialSolution -> PartialSolution
addDerivation p cause ps@PartialSolution{psAssignments, psLevel, psNextIndex} =
    let term = maybe anyTerm negateTerm (incompGet p cause)
     in ps
            { psAssignments = psAssignments Seq.|> Derivation psNextIndex psLevel p term cause
            , psNextIndex = psNextIndex + 1
            }

-- | Backtrack: drop every assignment strictly above the target level.
backtrack :: Int -> PartialSolution -> PartialSolution
backtrack level ps@PartialSolution{psAssignments} =
    ps
        { psAssignments = Seq.filter ((<= level) . aLevel) psAssignments
        , psLevel = level
        }

-- | Intersection of all terms recorded for a package ('Nothing' if the
-- package is unmentioned, which judges as 'anyTerm' = ⊤).
termIntersectionForPackage :: PartialSolution -> PackageName -> Maybe (Term InstanceSet)
termIntersectionForPackage PartialSolution{psAssignments} p =
    case assignmentTerm <$> Seq.filter ((== p) . aPackage) psAssignments of
        Seq.Empty    -> Nothing
        t Seq.:<| ts -> Just (foldl' intersectTerm t ts)

-- | Relation of the whole partial solution to an incompatibility.
psRelation :: PartialSolution -> Incompatibility -> IncompatRelation
psRelation ps = incompRelation (termIntersectionForPackage ps)

-- | The decisions, as a solution map.
extractSolution :: PartialSolution -> Map PackageName Instance
extractSolution PartialSolution{psAssignments} =
    Map.fromList [(aPackage a, aInstance a) | a@Decision{} <- toList psAssignments]

-- | Packages that have a positive accumulated term but no decision yet, with
-- that positive instance set. Chronological (oldest first) for determinism.
undecidedPositive :: PartialSolution -> [(PackageName, InstanceSet)]
undecidedPositive ps@PartialSolution{psAssignments} =
    let assigns = toList psAssignments -- oldest-first
        decided = [aPackage a | a@Decision{} <- assigns]
        pkgs = uniqueOldestFirst [aPackage a | a <- assigns]
     in mapMaybe positive (filter (`notElem` decided) pkgs)
  where
    positive p = case termIntersectionForPackage ps p of
        Just (Positive r) -> Just (p, r)
        _                 -> Nothing
    uniqueOldestFirst = go []
      where
        go seen []       = reverse seen
        go seen (x : xs)
            | x `elem` seen = go seen xs
            | otherwise = go (x : seen) xs

-- | All assignments for a package, oldest first. The satisfier search walks
-- this list.
packageHistory :: PartialSolution -> PackageName -> [Assignment]
packageHistory PartialSolution{psAssignments} p =
    toList (Seq.filter ((== p) . aPackage) psAssignments)

-- --------------------------------------------------------------------------
-- The algorithm
-- --------------------------------------------------------------------------

-- | Result of searching for the satisfier of a conflict incompatibility.
data SatisfierSearch
    = DifferentDecisionLevels !Int
      -- ^ backtrack to this level
    | SameDecisionLevels Incompatibility
      -- ^ satisfier's cause

-- | Earliest assignment of @p@ whose running accumulated term becomes disjoint
-- from @startTerm@.
-- Precondition: such an assignment exists (guaranteed during conflict resolution).
satisfierOf
    :: PartialSolution
    -> PackageName
    -> Term InstanceSet
    -> Assignment
satisfierOf ps p startTerm = go anyTerm (packageHistory ps p)
  where
    go _ [] = error "satisfierOf: no satisfier (precondition violated)"
    go acc (a : as) =
        let acc' = intersect acc (assignmentTerm a)
         in if isEmpty (intersectTerm acc' startTerm) then a else go acc' as

-- | The satisfier of an incompatibility is the latest of its terms' satisfiers.
-- When the satisfier is a derivation and the previous satisfier sits at its
-- level, resolution continues with the satisfier's cause; otherwise it
-- backtracks to the previous satisfier's level (at least 1).
satisfierSearch
    :: PartialSolution
    -> Incompatibility
    -> (PackageName, SatisfierSearch)
satisfierSearch ps i =
    let satMap =
            [ (p, satisfierOf ps p (negateTerm it))
            | (p, it) <- Map.toList (incompTerms i)
            ]
        (satPkg, satAssign) = maximumBy (comparing (aIndex . snd)) satMap
        satLevel = aLevel satAssign
        it_s = fromMaybe anyTerm (incompGet satPkg i)
        startTerm' = intersect (assignmentTerm satAssign) (negateTerm it_s)
        prevForSat = satisfierOf ps satPkg startTerm'
        satMap' = [(p, if p == satPkg then prevForSat else a) | (p, a) <- satMap]
        prevLevel = max 1 (aLevel (snd (maximumBy (comparing (aIndex . snd)) satMap')))
     in case satAssign of
            Derivation{aCause}
                | prevLevel >= satLevel -> (satPkg, SameDecisionLevels aCause)
            _ -> (satPkg, DifferentDecisionLevels prevLevel)


-- | Propagate the incompatibilities to a fixpoint: judge each with
-- 'psRelation'; on @IAlmostSatisfied p@ derive (¬ its term for @p@) via
-- 'addDerivation'; on @ISatisfied@ hand off to 'conflictResolution'. Returns
-- the terminal incompatibility on unsolvable input, or the (possibly grown)
-- incompatibility list and updated solution.
unitPropagation
    :: (Monad m, WithLog env SolverMsg m)
    => PackageName
    -> Instance
    -> [Incompatibility]
    -> PartialSolution
    -> m (Either Incompatibility ([Incompatibility], PartialSolution))
unitPropagation rootPkg rootI = scan
  where
    scan incompats ps = step incompats ps incompats

    -- Walk the worklist of incompatibilities once; on any action, restart scan.
    step incompats ps [] = pure (Right (incompats, ps))
    step incompats ps (i : rest) =
        case psRelation ps i of
            ISatisfied ->
                case conflictResolution rootPkg rootI i ps of
                    Left terminal ->
                        pure (Left terminal)
                    Right (almostPkg, rootCause, ps') ->
                        scan (rootCause : incompats) (addDerivation almostPkg rootCause ps')
            IAlmostSatisfied q ->
                scan incompats (addDerivation q i ps)
            _ -> step incompats ps rest


-- | Conflict resolution: satisfier search over 'packageHistory', 'priorCause'
-- while satisfier and previous satisfier share a decision level, then
-- 'backtrack'. Returns the terminal incompatibility (no solution), or the
-- pivot package, the learned root cause, and the backtracked solution.
conflictResolution
    :: PackageName
    -> Instance
    -> Incompatibility
    -> PartialSolution
    -> Either Incompatibility (PackageName, Incompatibility, PartialSolution)
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


-- | Failure: no solution; carries the terminal incompatibility (the root of
-- the derivation tree, for reporting).
newtype SolveError = NoSolution Incompatibility
    deriving (Eq, Show)

-- | Structured progress events emitted during resolution.
data SolverMsg
    = -- | about to choose an element for p within this range
      Deciding PackageName InstanceSet
    | -- | picked this element for p
      Chose PackageName Instance
    | -- | no element available in range (forces a conflict next)
      NoVersionFor PackageName InstanceSet
    | -- | this incompatibility is satisfied (a conflict)
      Conflict Incompatibility
    | -- | backtracked to this decision level
      Backtracked Int
    deriving (Eq, Show)

-- | Solve for a root package pinned to a root instance: alternate
-- 'unitPropagation' with decisions — take the first 'undecidedPositive'
-- package and ask the 'Provider' to 'expand' its range into an instance and
-- the incompatibilities that instance entails.
solve
    :: (Monad m, WithLog env SolverMsg m)
    => Provider m
    -> PackageName
    -> Instance
    -> m (Either SolveError (Map PackageName Instance))
solve provider rootPkg rootV =
    go [notRoot rootPkg rootV] emptyPS
    where
        go incompats ps =
            unitPropagation rootPkg rootV incompats ps >>= \case
                Left terminal -> pure (Left (NoSolution terminal))
                Right (incompats', ps') ->
                    case undecidedPositive ps' of
                        [] -> pure (Right (extractSolution ps'))
                        ((p, range) : _) -> do
                            logMsg (Deciding p range)
                            expand provider p range >>= \case
                                Nothing ->
                                    go (noInstances p range : incompats') ps'
                                Just (i, depIncs) ->
                                    go (depIncs ++ incompats') (addDecision p i ps')

