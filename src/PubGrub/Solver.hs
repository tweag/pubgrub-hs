{-# LANGUAGE LambdaCase #-}

-- | The PubGrub solving loop, over whole package instances.
--
-- Two layers: the storage layer — 'Assignment', 'PackageAssignments',
-- 'PartialSolution' and their queries — and the algorithm on top
-- ('unitPropagation', 'conflictResolution', 'solve').
--
-- The storage layer exists to make the algorithm's questions cheap. Every one
-- of them is about a single package, so assignments are indexed by package and
-- each package's accumulated term is cached: propagation judges an
-- incompatibility with a lookup per term instead of a scan of the whole
-- partial solution.
module PubGrub.Solver
    ( -- * Provider
      Provider (..)

      -- * Partial solution
    , Assignment (..)
    , AssignmentKind (..)
    , assignmentTerm
    , decidedInstance
    , assignmentPackageTerm
    , PackageAssignments (..)
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
import           Control.Applicative            (Alternative (..))
import           Data.Foldable                  (Foldable (..))
import           Data.List                      (sortOn)
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Data.Maybe                     (fromMaybe, mapMaybe)
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

-- | A single entry in the partial solution: one package, at one decision
-- level, with the reason it is there.
data Assignment = Assignment
    { aIndex   :: !Int
    , aLevel   :: !Int
    , aPackage :: PackageName
    , aKind    :: AssignmentKind
    }

-- | Why an assignment is in the partial solution, and what it asserts: a
-- decision (a freely chosen singleton instance) or a derivation (a term forced
-- by unit propagation, with the incompatibility that forced it).
--
-- The two shapes are a sum /inside/ the record rather than two constructors of
-- it because they carry different payloads: sharing @aIndex@, @aLevel@ and
-- @aPackage@ across two constructors is what would make the payload fields
-- partial selectors, and a partial selector is a crash waiting for the wrong
-- constructor.
data AssignmentKind
    = Decided Instance
    | Derived (Term InstanceSet) Incompatibility

-- | The term contributed by an assignment; for a decision, @Positive@ of the
-- singleton.
assignmentTerm :: Assignment -> Term InstanceSet
assignmentTerm a = case aKind a of
    Decided i   -> Positive (singletonInstance i)
    Derived t _ -> t

-- | The instance a decision decides; 'Nothing' for a derivation.
decidedInstance :: Assignment -> Maybe Instance
decidedInstance a = case aKind a of
    Decided i -> Just i
    Derived{} -> Nothing

-- | The assignment as "one term about one package".
assignmentPackageTerm :: Assignment -> PackageTerm
assignmentPackageTerm a = PackageTerm (aPackage a) (assignmentTerm a)

-- | Everything recorded about one package: its own assignments oldest-first,
-- the intersection of their terms, and the instance it was decided to be if it
-- has been decided.
--
-- @paTerm@ is a cache of @foldl1 intersectTerm (assignmentTerm <$> paHistory)@
-- and @paDecision@ a cache of the (at most one) decision in @paHistory@;
-- keeping them is what lets propagation ask about a package without scanning
-- the partial solution. Invariant: a record exists only for a package with a
-- non-empty history.
data PackageAssignments = PackageAssignments
    { paHistory  :: Seq Assignment
    , paTerm     :: Term InstanceSet
    , paDecision :: Maybe Instance
    }

-- | Assignments are indexed by package, and within a package stored
-- oldest-first (chronological), so the satisfier search reads them in order
-- without reversing; @psLevel@ is the current decision level; @psNextIndex@ is
-- a monotone counter giving chronological order /across/ packages.
data PartialSolution = PartialSolution
    { psPackages  :: Map PackageName PackageAssignments
    , psLevel     :: !Int
    , psNextIndex :: !Int
    }

emptyPS :: PartialSolution
emptyPS = PartialSolution{psPackages = Map.empty, psLevel = 0, psNextIndex = 0}

-- | Add one assignment to a package's record, creating the record if this is
-- the package's first assignment. The caches move with it: the term folds in
-- by intersection, the decision is remembered.
extendPackage :: Assignment -> Maybe PackageAssignments -> PackageAssignments
extendPackage a Nothing =
    PackageAssignments
        { paHistory = Seq.singleton a
        , paTerm = assignmentTerm a
        , paDecision = decidedInstance a
        }
extendPackage a (Just pa) =
    pa
        { paHistory = paHistory pa Seq.|> a
        , paTerm = intersectTerm (paTerm pa) (assignmentTerm a)
        , paDecision = decidedInstance a <|> paDecision pa
        }

-- | Rebuild a record from a history, recomputing both caches. 'Nothing' for an
-- empty history, which has no record.
fromHistory :: Seq Assignment -> Maybe PackageAssignments
fromHistory = foldl' (\acc a -> Just (extendPackage a acc)) Nothing

-- | File an assignment under its package and consume its index.
recordAssignment :: Assignment -> PartialSolution -> PartialSolution
recordAssignment a ps@PartialSolution{psPackages, psNextIndex} =
    ps
        { psPackages = Map.alter (Just . extendPackage a) (aPackage a) psPackages
        , psNextIndex = psNextIndex + 1
        }

-- | Record a decision (a guess); increments the decision level.
addDecision :: PackageName -> Instance -> PartialSolution -> PartialSolution
addDecision p i ps@PartialSolution{psLevel, psNextIndex} =
    recordAssignment
        (Assignment psNextIndex (psLevel + 1) p (Decided i))
        ps{psLevel = psLevel + 1}

-- | Record a derivation: the negation of @cause@'s term for @p@, at the
-- current level.
addDerivation :: PackageName -> Incompatibility -> PartialSolution -> PartialSolution
addDerivation p cause ps@PartialSolution{psLevel, psNextIndex} =
    let term = maybe anyTerm negateTerm (incompGet p cause)
     in recordAssignment (Assignment psNextIndex psLevel p (Derived term cause)) ps

-- | Backtrack: drop every assignment strictly above the target level.
--
-- Levels are non-decreasing along a history (a derivation takes the current
-- level, a decision the next, and backtracking only lowers it), so what is
-- dropped is always a suffix — which is why this splits the history from the
-- right instead of filtering it: a package that drops nothing keeps its history
-- as it stands, rather than paying to rebuild an identical one.
--
-- A package that does lose assignments must have both its caches rebuilt from
-- the survivors — @intersectTerm@ cannot be undone, so the accumulated term is
-- recomputed, and a dropped decision must stop being remembered. A package that
-- loses all of them loses its record.
backtrack :: Int -> PartialSolution -> PartialSolution
backtrack level ps@PartialSolution{psPackages} =
    ps
        { psPackages = Map.mapMaybe prune psPackages
        , psLevel = level
        }
  where
    prune pa = case Seq.spanr ((> level) . aLevel) (paHistory pa) of
        (dropped, kept)
            | Seq.null dropped -> Just pa
            | otherwise -> fromHistory kept

-- | Intersection of all terms recorded for a package ('Nothing' if the
-- package is unmentioned, which judges as 'anyTerm' = ⊤).
termIntersectionForPackage :: PartialSolution -> PackageName -> Maybe (Term InstanceSet)
termIntersectionForPackage PartialSolution{psPackages} p =
    paTerm <$> Map.lookup p psPackages

-- | Relation of the whole partial solution to an incompatibility.
psRelation :: PartialSolution -> Incompatibility -> IncompatRelation
psRelation ps = incompRelation (termIntersectionForPackage ps)

-- | The decisions, as a solution map.
extractSolution :: PartialSolution -> Map PackageName Instance
extractSolution PartialSolution{psPackages} = Map.mapMaybe paDecision psPackages

-- | Packages that have a positive accumulated term but no decision yet, with
-- that positive instance set. Ordered by first mention (oldest first) for
-- determinism.
undecidedPositive :: PartialSolution -> [(PackageName, InstanceSet)]
undecidedPositive PartialSolution{psPackages} =
    map snd (sortOn fst (mapMaybe candidate (Map.toList psPackages)))
  where
    candidate (p, pa) = case (paDecision pa, paTerm pa) of
        (Nothing, Positive r) -> Just (firstIndex pa, (p, r))
        _                     -> Nothing
    -- The package's first mention, which is what the order is keyed on. A
    -- record always has a non-empty history, so the fallback is unreachable.
    firstIndex pa = maybe maxBound aIndex (Seq.lookup 0 (paHistory pa))

-- | All assignments for a package, oldest first. The satisfier search walks
-- this list.
packageHistory :: PartialSolution -> PackageName -> [Assignment]
packageHistory PartialSolution{psPackages} p =
    maybe [] (toList . paHistory) (Map.lookup p psPackages)

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
-- from @startTerm@, or 'Nothing' if none does.
satisfierOf
    :: PartialSolution
    -> PackageName
    -> Term InstanceSet
    -> Maybe Assignment
satisfierOf ps p startTerm = go anyTerm (packageHistory ps p)
  where
    go _ [] = Nothing
    go acc (a : as)
        | isEmpty (intersectTerm acc' startTerm) = Just a
        | otherwise = go acc' as
      where
        acc' = intersect acc (assignmentTerm a)

-- | 'maximumBy' on a key, total. Ties keep the earlier element, which never
-- arises here: the key is @aIndex@, and indices are unique.
maximumOn :: Ord b => (a -> b) -> [a] -> Maybe a
maximumOn f = foldl' pick Nothing
  where
    pick Nothing x = Just x
    pick (Just best) x
        | f x > f best = Just x
        | otherwise = Just best

-- | The satisfier of an incompatibility is the latest of its terms' satisfiers.
-- When the satisfier is a derivation and the previous satisfier sits at its
-- level, resolution continues with the satisfier's cause; otherwise it
-- backtracks to the previous satisfier's level (at least 1).
--
-- Every term of a satisfied incompatibility has a satisfier, so 'satisfierOf'
-- returning 'Nothing' means the partial solution and 'psRelation' disagree.
-- That is reported as a 'NoSatisfier' failure rather than thrown, so a bug
-- there is something the caller can print, not a crash inside a pure fold.
satisfierSearch
    :: PartialSolution
    -> Incompatibility
    -> Either SolveError (PackageName, SatisfierSearch)
satisfierSearch ps i = do
    satMap <- traverse satisfierForTerm (Map.toList (incompTerms i))
    (satPkg, satAssign) <- latestSatisfier satMap
    let satLevel = aLevel satAssign
        it_s = fromMaybe anyTerm (incompGet satPkg i)
        startTerm' = intersect (assignmentTerm satAssign) (negateTerm it_s)
    prevForSat <- require satPkg (satisfierOf ps satPkg startTerm')
    let satMap' = [(p, if p == satPkg then prevForSat else a) | (p, a) <- satMap]
    (_, prevAssign) <- latestSatisfier satMap'
    let prevLevel = max 1 (aLevel prevAssign)
    pure $ case aKind satAssign of
        Derived _ cause
            | prevLevel >= satLevel -> (satPkg, SameDecisionLevels cause)
        _ -> (satPkg, DifferentDecisionLevels prevLevel)
  where
    satisfierForTerm (p, it) = (,) p <$> require p (satisfierOf ps p (negateTerm it))
    require p = maybe (Left (NoSatisfier p i)) Right
    -- An incompatibility with no terms is the empty clause: unsatisfiable
    -- outright, hence a terminal failure. 'isTerminal' catches it before
    -- conflict resolution ever gets here, so this is the same verdict by
    -- another route, not a second opinion.
    latestSatisfier = maybe (Left (NoSolution i)) Right . maximumOn (aIndex . snd)

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
    -> m (Either SolveError ([Incompatibility], PartialSolution))
unitPropagation rootPkg rootI = scan
  where
    scan incompats ps = step incompats ps incompats

    -- Walk the worklist of incompatibilities once; on any action, restart scan.
    step incompats ps [] = pure (Right (incompats, ps))
    step incompats ps (i : rest) =
        case psRelation ps i of
            ISatisfied ->
                case conflictResolution rootPkg rootI i ps of
                    Left err ->
                        pure (Left err)
                    Right (almostPkg, rootCause, ps') ->
                        scan (rootCause : incompats) (addDerivation almostPkg rootCause ps')
            IAlmostSatisfied q ->
                scan incompats (addDerivation q i ps)
            _ -> step incompats ps rest


-- | Conflict resolution: satisfier search over 'packageHistory', 'priorCause'
-- while satisfier and previous satisfier share a decision level, then
-- 'backtrack'. Returns the failure (no solution, or a violated invariant), or
-- the pivot package, the learned root cause, and the backtracked solution.
conflictResolution
    :: PackageName
    -> Instance
    -> Incompatibility
    -> PartialSolution
    -> Either SolveError (PackageName, Incompatibility, PartialSolution)
conflictResolution rootPkg rootV = loop
  where
    loop current ps
        | isTerminal rootPkg rootV current = Left (NoSolution current)
        | otherwise =
            satisfierSearch ps current >>= \case
                (satPkg, DifferentDecisionLevels prevLevel) ->
                    Right (satPkg, current, backtrack prevLevel ps)
                (satPkg, SameDecisionLevels satCause) ->
                    loop (priorCause current satCause satPkg) ps


-- | Failure. Either the problem has no solution, or an invariant the solver
-- relies on did not hold — the latter cannot happen for a consistent partial
-- solution, and exists so that if it ever does, it arrives as a value to
-- report instead of an exception from inside a pure function.
data SolveError
    = -- | no solution; carries the terminal incompatibility (the root of the
      -- derivation tree, for reporting)
      NoSolution Incompatibility
    | -- | conflict resolution found a term of a satisfied incompatibility
      -- whose package has no satisfier in the partial solution
      NoSatisfier PackageName Incompatibility

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
                Left err -> pure (Left err)
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
