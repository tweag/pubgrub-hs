{-# LANGUAGE DerivingStrategies     #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE NamedFieldPuns         #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE ScopedTypeVariables    #-}

module PubGrub.Solver
  ( -- * Provider
    DependencyProvider (..),

    -- * Partial solution
    Assignment (..),
    assignmentTerm,
    PartialSolution (..),
    emptyPS,
    addDecision,
    addDerivation,
    backtrack,
    termIntersectionForPackage,
    relation,
    extractSolution,
    undecidedPositive,

    -- * Conflict resolution
    conflictResolution,

    -- * Unit propagation
    unitPropagation,

    -- * Solve
    SolveError (..),
    SolverMsg (..),
    solve,

    -- * Reporting
    ReportEnv (..),
    defaultReportEnv,
    reportConflict,
    reportConflictWith,
  )
where

import           Colog                (WithLog, logMsg)
import           Data.List            (maximumBy)
import           Data.Map.Strict      (Map)
import qualified Data.Map.Strict      as Map
import           Data.Maybe           (fromMaybe, mapMaybe)
import           Data.Ord             (comparing)
import           Data.Text            (Text)
import qualified Data.Text            as T
import           Distribution.Pretty  (prettyShow)
import           Distribution.Version (Version)
import           PubGrub.Types
import           PubGrub.VersionSet   (VersionSet)
import qualified PubGrub.VersionSet   as VS

-- | The oracle: pick a version in a range and report a version's dependencies.
-- Effects (e.g. lazy index loading) run in the monad @m@.
class (Package p, Monad m) => DependencyProvider dp p m | dp -> p where
  chooseVersion :: dp -> p -> VersionSet -> m (Maybe Version)
  getDependencies :: dp -> p -> Version -> m (Map p VersionSet)

-- | A single entry in the partial solution.
data Assignment p
  = Decision
      { aIndex   :: !Int,
        aLevel   :: !Int,
        aPackage :: p,
        aVersion :: Version
      }
  | Derivation
      { aIndex   :: !Int,
        aLevel   :: !Int,
        aPackage :: p,
        aTerm    :: Term,
        aCause   :: Incompatibility p
      }
  deriving stock (Show)

-- | The term contributed by an assignment.
assignmentTerm :: Assignment p -> Term
assignmentTerm Decision {aVersion} = exactTerm aVersion
assignmentTerm Derivation {aTerm}  = aTerm

-- | Assignments are stored newest-first; @psLevel@ is the current decision
-- level; @psNextIndex@ is a monotone counter giving chronological order.
data PartialSolution p = PartialSolution
  { psAssignments :: [Assignment p],
    psLevel       :: !Int,
    psNextIndex   :: !Int
  }
  deriving stock (Show)

emptyPS :: PartialSolution p
emptyPS = PartialSolution {psAssignments = [], psLevel = 0, psNextIndex = 0}

-- | Record a decision (a guess); increments the decision level.
addDecision :: p -> Version -> PartialSolution p -> PartialSolution p
addDecision p v ps@PartialSolution {psAssignments, psLevel, psNextIndex} =
  ps
    { psAssignments = Decision psNextIndex (psLevel + 1) p v : psAssignments,
      psLevel = psLevel + 1,
      psNextIndex = psNextIndex + 1
    }

-- | Record a derivation: the negation of @cause@'s term for @p@, at the
-- current level.
addDerivation :: (Ord p) => p -> Incompatibility p -> PartialSolution p -> PartialSolution p
addDerivation p cause ps@PartialSolution {psAssignments, psLevel, psNextIndex} =
  let term = maybe anyTerm negateTerm (incompGet p cause)
   in ps
        { psAssignments = Derivation psNextIndex psLevel p term cause : psAssignments,
          psNextIndex = psNextIndex + 1
        }

-- | Backtrack: drop every assignment strictly above the target level.
backtrack :: Int -> PartialSolution p -> PartialSolution p
backtrack level ps@PartialSolution {psAssignments} =
  ps
    { psAssignments = filter ((<= level) . aLevel) psAssignments,
      psLevel = level
    }

-- | Intersection of all terms recorded for a package (Nothing if absent).
termIntersectionForPackage :: (Ord p) => PartialSolution p -> p -> Maybe Term
termIntersectionForPackage PartialSolution {psAssignments} p =
  case [assignmentTerm a | a <- psAssignments, aPackage a == p] of
    []       -> Nothing
    (t : ts) -> Just (foldl' intersectTerms t ts)

-- | Relation of the whole partial solution to an incompatibility.
relation :: (Ord p) => PartialSolution p -> Incompatibility p -> IncompatRelation p
relation ps = incompRelation (termIntersectionForPackage ps)

-- | The decisions, as a solution map.
extractSolution :: (Ord p) => PartialSolution p -> Map p Version
extractSolution PartialSolution {psAssignments} =
  Map.fromList [(aPackage a, aVersion a) | a@Decision {} <- psAssignments]

-- | Packages that have a positive accumulated term but no decision yet,
-- with that positive range. Chronological (oldest first) for determinism.
undecidedPositive :: (Ord p) => PartialSolution p -> [(p, VersionSet)]
undecidedPositive ps@PartialSolution {psAssignments} =
  let decided = [aPackage a | a@Decision {} <- psAssignments]
      pkgs = uniqueOldestFirst [aPackage a | a <- reverse psAssignments]
   in mapMaybe positive (filter (`notElem` decided) pkgs)
  where
    positive p = case termIntersectionForPackage ps p of
      Just (Positive r) -> Just (p, r)
      _                 -> Nothing
    uniqueOldestFirst = go []
      where
        go seen [] = reverse seen
        go seen (x : xs)
          | x `elem` seen = go seen xs
          | otherwise = go (x : seen) xs

-- | All assignments for a package, oldest first.
packageHistory :: (Ord p) => PartialSolution p -> p -> [Assignment p]
packageHistory PartialSolution {psAssignments} p =
  reverse [a | a <- psAssignments, aPackage a == p]

-- | Earliest assignment of @p@ whose running accumulated term becomes disjoint
-- from @startTerm@.
-- Precondition: such an assignment exists (guaranteed during conflict resolution).
satisfierOf :: (Ord p) => PartialSolution p -> p -> Term -> Assignment p
satisfierOf ps p startTerm = go anyTerm (packageHistory ps p)
  where
    go _ [] = error "satisfierOf: no satisfier (precondition violated)"
    go acc (a : as) =
      let acc' = intersectTerms acc (assignmentTerm a)
       in if termIsDisjoint acc' startTerm then a else go acc' as

-- | Result of searching for the satisfier of a conflict incompatibility.
data SatisfierSearch p
  = -- | backtrack to this level
    DifferentDecisionLevels !Int
  | -- | satisfier's cause
    SameDecisionLevels (Incompatibility p)

-- | The satisfier of an incompatibility is the latest of its terms' satisfiers.
-- When the satisfier is a derivation and the previous satisfier sits at its
-- level, resolution continues with the satisfier's cause; otherwise it
-- backtracks to the previous satisfier's level (at least 1).
satisfierSearch :: (Ord p) => PartialSolution p -> Incompatibility p -> (p, SatisfierSearch p)
satisfierSearch ps i =
  let satMap =
        [ (p, satisfierOf ps p (negateTerm it))
        | (p, it) <- Map.toList (incompTerms i)
        ]
      (satPkg, satAssign) = maximumBy (comparing (aIndex . snd)) satMap
      satLevel = aLevel satAssign
      it_s = fromMaybe anyTerm (incompGet satPkg i)
      startTerm' = intersectTerms (assignmentTerm satAssign) (negateTerm it_s)
      prevForSat = satisfierOf ps satPkg startTerm'
      satMap' = [(p, if p == satPkg then prevForSat else a) | (p, a) <- satMap]
      prevLevel = max 1 (aLevel (snd (maximumBy (comparing (aIndex . snd)) satMap')))
   in case satAssign of
        Derivation {aCause}
          | prevLevel >= satLevel -> (satPkg, SameDecisionLevels aCause)
        _ -> (satPkg, DifferentDecisionLevels prevLevel)

-- | Conflict resolution loop. Returns either the terminal (unsatisfiable)
-- incompatibility, or @(almostPackage, rootCause, backtrackedSolution)@.
conflictResolution ::
  (Ord p) =>
  p ->
  -- | root package and version (for is-terminal)
  Version ->
  -- | the satisfied (conflict) incompatibility
  Incompatibility p ->
  PartialSolution p ->
  Either (Incompatibility p) (p, Incompatibility p, PartialSolution p)
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

-- | Naïve unit propagation: repeatedly scan all incompatibilities until a
-- fixpoint, logging 'Conflict' and 'Backtracked' as they happen. The monad is
-- constrained only by 'WithLog', not @MonadIO@, so the loop can log but cannot
-- perform other I/O.
unitPropagation ::
  forall p env m.
  (Ord p, WithLog env (SolverMsg p) m) =>
  p ->
  Version ->
  [Incompatibility p] ->
  PartialSolution p ->
  m (Either (Incompatibility p) ([Incompatibility p], PartialSolution p))
unitPropagation rootPkg rootV = scan
  where
    scan ::
      [Incompatibility p] ->
      PartialSolution p ->
      m (Either (Incompatibility p) ([Incompatibility p], PartialSolution p))
    scan incompats ps = step incompats ps incompats

    -- Walk the worklist of incompatibilities once; on any action, restart scan.
    step ::
      [Incompatibility p] ->
      PartialSolution p ->
      [Incompatibility p] ->
      m (Either (Incompatibility p) ([Incompatibility p], PartialSolution p))
    step incompats ps [] = pure (Right (incompats, ps)) -- fixpoint
    step incompats ps (i : rest) =
      case relation ps i of
        ISatisfied -> do
          logMsg (Conflict i)
          case conflictResolution rootPkg rootV i ps of
            Left terminal -> pure (Left terminal)
            Right (almostPkg, rootCause, ps') -> do
              logMsg (Backtracked (psLevel ps') :: SolverMsg p)
              let ps'' = addDerivation almostPkg rootCause ps'
              scan (rootCause : incompats) ps''
        IAlmostSatisfied q ->
          scan incompats (addDerivation q i ps)
        _ -> step incompats ps rest

-- | Failure: no solution; carries the terminal incompatibility (the root of
-- the derivation tree, for reporting).
newtype SolveError p = NoSolution (Incompatibility p)
  deriving stock (Eq, Show)

-- | Structured progress events emitted during resolution.
data SolverMsg p
  = -- | about to choose a version for p within this range
    Deciding p VersionSet
  | -- | picked this version for p
    Chose p Version
  | -- | no version available in range (forces a conflict next)
    NoVersionFor p VersionSet
  | -- | this incompatibility is satisfied (a conflict)
    Conflict (Incompatibility p)
  | -- | backtracked to this decision level
    Backtracked Int
  deriving stock (Eq, Show)

-- | Solve for a root package pinned to @rootV@. Returns a complete assignment
-- or a 'SolveError'. Emits decision-level progress via co-log.
solve ::
  (DependencyProvider dp p m, WithLog env (SolverMsg p) m) =>
  dp ->
  p ->
  Version ->
  m (Either (SolveError p) (Map p Version))
solve dp rootPkg rootV = go [notRoot rootPkg rootV] emptyPS
  where
    go incompats ps = do
      result <- unitPropagation rootPkg rootV incompats ps
      case result of
        Left terminal -> pure (Left (NoSolution terminal))
        Right (incompats', ps') ->
          case undecidedPositive ps' of
            [] -> pure (Right (extractSolution ps'))
            ((p, range) : _) -> do
              logMsg (Deciding p range)
              mv <- chooseVersion dp p range
              case mv of
                Nothing -> do
                  logMsg (NoVersionFor p range)
                  go (noVersions p range : incompats') ps'
                Just v -> do
                  logMsg (Chose p v)
                  deps <- getDependencies dp p v
                  let depIncs =
                        [ fromDependency p (VS.singleton v) (q, r)
                        | (q, r) <- Map.toList deps
                        ]
                  go (depIncs ++ incompats') (addDecision p v ps')

-- | Caller-supplied context for rendering a conflict. The solver is generic
-- over the package type, but a good report needs facts only the caller knows:
-- which packages are the synthetic root, and which are fixed by the compiler
-- (boot packages) rather than chosen from a range.
data ReportEnv p = ReportEnv
  { -- | The version a package is pinned to by the compiler, if it is a boot
    -- package. Used to explain an empty range as "provided by the compiler as
    -- X" instead of the misleading "no version for …".
    rePinnedVersion :: p -> Maybe Version,
    -- | Whether a package is the synthetic root. Its version carries no
    -- meaning to the user, so it is omitted when it appears as a depender.
    reIsRoot        :: p -> Bool
  }

-- | A context that knows nothing special: every package is an ordinary,
-- range-selected dependency. Used by 'reportConflict'.
defaultReportEnv :: ReportEnv p
defaultReportEnv = ReportEnv {rePinnedVersion = const Nothing, reIsRoot = const False}

-- | 'reportConflictWith' using 'defaultReportEnv'.
reportConflict :: (Package p) => Incompatibility p -> Text
reportConflict = reportConflictWith defaultReportEnv

-- | Render an incompatibility and its derivation as a human-readable proof.
--
-- Each derived ('DerivedFrom') step becomes a numbered line; a step references
-- the earlier lines it was derived from as @(n)@, while external leaf facts are
-- inlined. Post-order numbering guarantees every reference points backwards.
-- A sub-derivation shared by two steps gets a line for each.
reportConflictWith :: forall p. (Package p) => ReportEnv p -> Incompatibility p -> Text
reportConflictWith env root = case incompCause root of
  DerivedFrom c1 c2 ->
    let (r1, acc1, n1) = visit c1 [] 1
        (r2, acc2, n2) = visit c2 acc1 n1
        final = "Because " <> r1 <> " and " <> r2 <> ", " <> conclusion root <> "."
        steps = reverse ((n2, final) : acc2)
     in T.intercalate "\n" [T.pack (show n) <> ". " <> t | (n, t) <- steps]
  _ -> leaf root
  where
    -- Emit a line per derived step, threading the next free number and the
    -- lines accumulated so far (newest first). Returns how to refer to this
    -- node: @(n)@ for a derived step, or the inlined phrase for a leaf.
    visit ::
      Incompatibility p -> [(Int, Text)] -> Int -> (Text, [(Int, Text)], Int)
    visit inc acc n = case incompCause inc of
      DerivedFrom c1 c2 ->
        let (r1, acc1, n1) = visit c1 acc n
            (r2, acc2, n2) = visit c2 acc1 n1
            line = "Because " <> r1 <> " and " <> r2 <> ", " <> summary inc
         in ("(" <> T.pack (show n2) <> ")", (n2, line) : acc2, n2 + 1)
      _ -> (leaf inc, acc, n)

    -- External facts at the leaves of the proof. We render these from the cause
    -- rather than the bare terms so each explains itself: a 'NoVersions' leaf
    -- means the range is simply empty, not in conflict with anything else, and
    -- for a compiler-provided package we say which version the compiler provides.
    leaf c = case incompCause c of
      NoVersions p s -> case rePinnedVersion env p of
        Just v ->
          prettyPackage p
            <> " is provided by the compiler as "
            <> prettyVer v
            <> ", which does not satisfy "
            <> prettyVS s
        Nothing -> "no version for " <> prettyPackage p <> " " <> prettyVS s
      _ -> summary c

    -- The final line of the proof. A lone positive term here is the root being
    -- ruled out at its synthetic version, which reads better as plain failure.
    conclusion c = case Map.toList (incompTerms c) of
      [(_, Positive _)] -> "version solving failed"
      _                 -> summary c

    summary c = case Map.toList (incompTerms c) of
      [] -> "version solving failed"
      [(p, Positive r)] -> prettyPackage p <> " " <> prettyVS r <> " is forbidden"
      [(p, Negative r)] -> prettyPackage p <> " " <> prettyVS r <> " is required"
      [(p1, Positive r1), (p2, Negative r2)] -> dep p1 r1 p2 r2
      [(p2, Negative r2), (p1, Positive r1)] -> dep p1 r1 p2 r2
      terms -> T.intercalate " and " [showTerm p t | (p, t) <- terms] <> " are incompatible"

    -- Keep the depender's range so distinct derivation steps stay distinct
    -- ("assoc ==1.0.2 depends on …" vs "assoc >=1.0.2 && <1.1 depends on …"),
    -- but omit it for the root, whose synthetic version means nothing.
    dep p1 r1 p2 r2 =
      prettyPackage p1 <> depender r1 <> " depends on " <> prettyPackage p2 <> " " <> prettyVS r2
      where
        depender r = if reIsRoot env p1 then "" else " " <> prettyVS r
    showTerm p (Positive r) = prettyPackage p <> " " <> prettyVS r
    showTerm p (Negative r) = prettyPackage p <> " not " <> prettyVS r

-- | Render a single version, e.g. @4.21.0.0@.
prettyVer :: Version -> Text
prettyVer = T.pack . prettyShow

-- | Render a version set the way Cabal would, e.g. @==5.2@ or @>=1 && <2@.
prettyVS :: VersionSet -> Text
prettyVS = T.pack . prettyShow . VS.toVersionRange
