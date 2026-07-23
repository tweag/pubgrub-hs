-- | The PubGrub solving loop, over whole package instances.
--
-- The previous implementation, over a generic set algebra, is commented out
-- at the bottom of this file as the reference this one was ported from.
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

      -- * The algorithm (stubs)
    , unitPropagation
    , conflictResolution
    , SolveError (..)
    , solve
    ) where

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
-- The algorithm (stubs)
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
    :: PackageName
    -> Instance
    -> [Incompatibility]
    -> PartialSolution
    -> Either Incompatibility ([Incompatibility], PartialSolution)
unitPropagation rootPkg rootI = scan
  where
    scan :: [Incompatibility]
         -> PartialSolution
         -> Either Incompatibility ([Incompatibility], PartialSolution)
    scan incompats ps = step incompats ps incompats

    -- Walk the worklist of incompatibilities once; on any action, restart scan.
    step :: [Incompatibility]
         -> PartialSolution
         -> [Incompatibility]
         -> Either Incompatibility ([Incompatibility], PartialSolution)
    step incompats ps [] = Right (incompats, ps)
    step incompats ps (i : rest) =
        case psRelation ps i of
            ISatisfied ->
                case conflictResolution rootPkg rootI i ps of
                    Left terminal -> Left terminal
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

-- | Solve for a root package pinned to a root instance: alternate
-- 'unitPropagation' with decisions — take the first 'undecidedPositive'
-- package and ask the 'Provider' to 'expand' its range into an instance and
-- the incompatibilities that instance entails.
solve
    :: Provider
    -> PackageName
    -> Instance
    -> Either SolveError (Map PackageName Instance)
solve provider rootPkg rootV =
    go [notRoot rootPkg rootV] emptyPS
    where
        go incompats ps =
            case unitPropagation rootPkg rootV incompats ps of
                Left terminal -> Left (NoSolution terminal)
                Right (incompats', ps') ->
                    case undecidedPositive ps' of
                        [] -> Right (extractSolution ps')
                        ((p, range) : _) ->
                            case expand provider p range of
                                Nothing ->
                                    go (noInstances p range : incompats') ps'
                                Just (i, depIncs) ->
                                    go (depIncs ++ incompats') (addDecision p i ps')


-- ===========================================================================
-- Old generic implementation (pre-instance model), kept as porting reference.
-- ===========================================================================

-- {-# LANGUAGE DerivingStrategies #-}
-- {-# LANGUAGE FlexibleContexts #-}
-- {-# LANGUAGE FunctionalDependencies #-}
-- {-# LANGUAGE NamedFieldPuns #-}
-- {-# LANGUAGE OverloadedStrings #-}
-- {-# LANGUAGE ScopedTypeVariables #-}
-- {-# LANGUAGE StandaloneDeriving #-}
-- {-# LANGUAGE TypeFamilies #-}
-- {-# LANGUAGE UndecidableInstances #-}

-- module PubGrub.Solver (
--     -- * Provider
--     DependencyProvider (..),

--     -- * Partial solution
--     Assignment (..),
--     assignmentTerm,
--     PartialSolution (..),
--     emptyPS,
--     addDecision,
--     addDerivation,
--     backtrack,
--     termIntersectionForPackage,
--     relation,
--     extractSolution,
--     undecidedPositive,

--     -- * Conflict resolution
--     conflictResolution,

--     -- * Unit propagation
--     unitPropagation,

--     -- * Solve
--     SolveError (..),
--     SolverMsg (..),
--     solve,
-- )
-- where

-- import Colog (WithLog, logMsg)
-- import Data.Foldable (maximumBy)
-- import Data.Map.Strict (Map)
-- import Data.Map.Strict qualified as Map
-- import Data.Maybe (fromMaybe, mapMaybe)
-- import Data.Ord (comparing)
-- import PubGrub.Incompatibility (
--     IncompatRelation (..),
--     Incompatibility (incompTerms),
--     fromDependency,
--     incompGet,
--     incompRelation,
--     isTerminal,
--     noVersions,
--     notRoot,
--     priorCause,
--  )
-- import PubGrub.Lattice
-- import PubGrub.Term

-- -- | The oracle the solver consults whenever it needs to make a decision.
-- -- Effects (e.g. lazy index loading) run in the monad @m@.
-- class (Monad m) => DependencyProvider dp p s m | dp -> p s where
--     -- | Pick an element of @p@ (e.g. a version) and report that element's
--     -- dependencies.
--     --
--     -- The solver calls @expand dp p range@ when it has narrowed @p@ down to the
--     -- set @range@ and needs to commit to a concrete element. The @range@ is the
--     -- accumulated constraint on @p@ from the current partial solution, not a
--     -- hint: it is a hard precondition the result must satisfy.
--     --
--     -- Contract:
--     --
--     -- * On @Just (v, deps)@, @v@ MUST satisfy @range@ (i.e. @member v range@).
--     --   The solver immediately records @v@ as a /decision/ — a positive
--     --   assignment — so an out-of-range @v@ directly contradicts the derivations
--     --   that produced @range@ and corrupts the search invariant. @deps@ is the
--     --   dependency map of exactly that @v@.
--     --
--     -- * Return @Nothing@ iff no element of @p@ satisfies @range@. The solver
--     --   turns this into a \"no versions\" incompatibility and backtracks.
--     --
--     -- A provider is free to choose /which/ in-range element to return (this is
--     -- where a selection policy lives, e.g. \"newest first\"). It need not be
--     -- clever: a wrong-but-in-range guess is not an error. If the chosen element
--     -- leads to a conflict, the solver derives an incompatibility, backtracks, and
--     -- calls @expand@ again with a strictly smaller @range@ that excludes the
--     -- rejected element — so repeated calls see a monotonically shrinking range
--     -- until a consistent element is found or the range is empty.
--     expand :: dp -> p -> s -> m (Maybe (Elem s, Map p s))

-- -- | A single entry in the partial solution.
-- data Assignment p s
--     = Decision
--         { aIndex :: !Int
--         , aLevel :: !Int
--         , aPackage :: p
--         , aVersion :: Elem s
--         }
--     | Derivation
--         { aIndex :: !Int
--         , aLevel :: !Int
--         , aPackage :: p
--         , aTerm :: Term s
--         , aCause :: Incompatibility p s
--         }

-- deriving stock instance (Show p, Show s, Show (Elem s)) => Show (Assignment p s)

-- -- | The term contributed by an assignment.
-- assignmentTerm :: Sets s => Assignment p s -> Term s
-- assignmentTerm Decision{aVersion} = exactTerm aVersion
-- assignmentTerm Derivation{aTerm} = aTerm

-- -- | Assignments are stored newest-first; @psLevel@ is the current decision
-- -- level; @psNextIndex@ is a monotone counter giving chronological order.
-- data PartialSolution p s = PartialSolution
--     { psAssignments :: [Assignment p s]
--     , psLevel :: !Int
--     , psNextIndex :: !Int
--     }

-- deriving stock instance (Show p, Show s, Show (Elem s)) => Show (PartialSolution p s)

-- emptyPS :: PartialSolution p s
-- emptyPS = PartialSolution{psAssignments = [], psLevel = 0, psNextIndex = 0}

-- -- | Record a decision (a guess); increments the decision level.
-- addDecision :: p -> Elem s -> PartialSolution p s -> PartialSolution p s
-- addDecision p v ps@PartialSolution{psAssignments, psLevel, psNextIndex} =
--     ps
--         { psAssignments = Decision psNextIndex (psLevel + 1) p v : psAssignments
--         , psLevel = psLevel + 1
--         , psNextIndex = psNextIndex + 1
--         }

-- -- | Record a derivation: the negation of @cause@'s term for @p@, at the
-- -- current level. Mirrors @PartialSolution::add_derivation@.
-- addDerivation
--     :: (Ord p, BoundedLattice s)
--     => p
--     -> Incompatibility p s
--     -> PartialSolution p s
--     -> PartialSolution p s
-- addDerivation p cause ps@PartialSolution{psAssignments, psLevel, psNextIndex} =
--     let term = maybe anyTerm negateTerm (incompGet p cause)
--      in ps
--             { psAssignments = Derivation psNextIndex psLevel p term cause : psAssignments
--             , psNextIndex = psNextIndex + 1
--             }

-- -- | Backtrack: drop every assignment strictly above the target level.
-- backtrack :: Int -> PartialSolution p s -> PartialSolution p s
-- backtrack level ps@PartialSolution{psAssignments} =
--     ps
--         { psAssignments = filter ((<= level) . aLevel) psAssignments
--         , psLevel = level
--         }

-- -- | Intersection of all terms recorded for a package (Nothing if absent).
-- termIntersectionForPackage
--     :: (Ord p, Sets s) => PartialSolution p s -> p -> Maybe (Term s)
-- termIntersectionForPackage PartialSolution{psAssignments} p =
--     case [assignmentTerm a | a <- psAssignments, aPackage a == p] of
--         [] -> Nothing
--         (t : ts) -> Just (foldl' intersectTerms t ts)

-- -- | Relation of the whole partial solution to an incompatibility.
-- relation
--     :: (Ord p, Sets s, Eq s)
--     => PartialSolution p s
--     -> Incompatibility p s
--     -> IncompatRelation p
-- relation ps = incompRelation (termIntersectionForPackage ps)

-- -- | The decisions, as a solution map.
-- extractSolution :: (Ord p) => PartialSolution p s -> Map p (Elem s)
-- extractSolution PartialSolution{psAssignments} =
--     Map.fromList [(aPackage a, aVersion a) | a@Decision{} <- psAssignments]

-- -- | Packages that have a positive accumulated term but no decision yet,
-- -- with that positive range. Chronological (oldest first) for determinism.
-- undecidedPositive :: (Ord p, Sets s) => PartialSolution p s -> [(p, s)]
-- undecidedPositive ps@PartialSolution{psAssignments} =
--     let decided = [aPackage a | a@Decision{} <- psAssignments]
--         pkgs = uniqueOldestFirst [aPackage a | a <- reverse psAssignments]
--      in mapMaybe positive (filter (`notElem` decided) pkgs)
--   where
--     positive p = case termIntersectionForPackage ps p of
--         Just (Positive r) -> Just (p, r)
--         _ -> Nothing
--     uniqueOldestFirst = go []
--       where
--         go seen [] = reverse seen
--         go seen (x : xs)
--             | x `elem` seen = go seen xs
--             | otherwise = go (x : seen) xs

-- -- | All assignments for a package, oldest first.
-- packageHistory :: Ord p => PartialSolution p s -> p -> [Assignment p s]
-- packageHistory PartialSolution{psAssignments} p =
--     reverse [a | a <- psAssignments, aPackage a == p]

-- -- | Earliest assignment of @p@ whose running accumulated term becomes disjoint
-- -- from @startTerm@. Mirrors @PackageAssignments::satisfier@.
-- -- Precondition: such an assignment exists (guaranteed during conflict resolution).
-- satisfierOf
--     :: (Ord p, Sets s, Eq s)
--     => PartialSolution p s
--     -> p
--     -> Term s
--     -> Assignment p s
-- satisfierOf ps p startTerm = go anyTerm (packageHistory ps p)
--   where
--     go _ [] = error "satisfierOf: no satisfier (precondition violated)"
--     go acc (a : as) =
--         let acc' = intersectTerms acc (assignmentTerm a)
--          in if termIsDisjoint acc' startTerm then a else go acc' as

-- -- | Result of searching for the satisfier of a conflict incompatibility.
-- data SatisfierSearch p s
--     = -- | backtrack to this level
--       DifferentDecisionLevels !Int
--     | -- | satisfier's cause
--       SameDecisionLevels (Incompatibility p s)

-- -- | For each term find its satisfier; the overall satisfier is the latest
-- -- (max index). Then recompute the previous satisfier level. Mirrors
-- -- @PartialSolution::satisfier_search@.
-- satisfierSearch
--     :: (Ord p, Sets s, Eq s)
--     => PartialSolution p s
--     -> Incompatibility p s
--     -> (p, SatisfierSearch p s)
-- satisfierSearch ps i =
--     let satMap =
--             [ (p, satisfierOf ps p (negateTerm it))
--             | (p, it) <- Map.toList (incompTerms i)
--             ]
--         (satPkg, satAssign) = maximumBy (comparing (aIndex . snd)) satMap
--         satLevel = aLevel satAssign
--         it_s = fromMaybe anyTerm (incompGet satPkg i)
--         startTerm' = intersectTerms (assignmentTerm satAssign) (negateTerm it_s)
--         prevForSat = satisfierOf ps satPkg startTerm'
--         satMap' = [(p, if p == satPkg then prevForSat else a) | (p, a) <- satMap]
--         prevLevel = max 1 (aLevel (snd (maximumBy (comparing (aIndex . snd)) satMap')))
--      in case satAssign of
--             Derivation{aCause}
--                 | prevLevel >= satLevel -> (satPkg, SameDecisionLevels aCause)
--             _ -> (satPkg, DifferentDecisionLevels prevLevel)

-- -- | Conflict resolution loop. Returns either the terminal (unsatisfiable)
-- -- incompatibility, or @(almostPackage, rootCause, backtrackedSolution)@.
-- -- Mirrors @State::conflict_resolution@ + @backtrack@.
-- conflictResolution
--     :: (Ord p, Eq s, Sets s)
--     => p
--     -> Elem s
--     -- ^ root package and version (for is-terminal)
--     -> Incompatibility p s
--     -- ^ the satisfied (conflict) incompatibility
--     -> PartialSolution p s
--     -> Either (Incompatibility p s) (p, Incompatibility p s, PartialSolution p s)
-- conflictResolution rootPkg rootV = loop
--   where
--     loop current ps
--         | isTerminal rootPkg rootV current = Left current
--         | otherwise =
--             case satisfierSearch ps current of
--                 (satPkg, DifferentDecisionLevels prevLevel) ->
--                     Right (satPkg, current, backtrack prevLevel ps)
--                 (satPkg, SameDecisionLevels satCause) ->
--                     loop (priorCause current satCause satPkg) ps

-- -- | Naïve unit propagation, now streaming 'Conflict'/'Backtracked' events as
-- -- they happen. The constraint is only @(Ord p, WithLog env (SolverMsg p) m)@ —
-- -- no @MonadIO@ — so the loop can log but cannot perform real I/O.
-- unitPropagation
--     :: forall p s env m
--      . (Ord p, Eq s, Sets s, WithLog env (SolverMsg p s) m)
--     => p
--     -> Elem s
--     -> [Incompatibility p s]
--     -> PartialSolution p s
--     -> m (Either (Incompatibility p s) ([Incompatibility p s], PartialSolution p s))
-- unitPropagation rootPkg rootV = scan
--   where
--     scan
--         :: [Incompatibility p s]
--         -> PartialSolution p s
--         -> m (Either (Incompatibility p s) ([Incompatibility p s], PartialSolution p s))
--     scan incompats ps = step incompats ps incompats

--     -- Walk the worklist of incompatibilities once; on any action, restart scan.
--     step
--         :: [Incompatibility p s]
--         -> PartialSolution p s
--         -> [Incompatibility p s]
--         -> m (Either (Incompatibility p s) ([Incompatibility p s], PartialSolution p s))
--     step incompats ps [] = pure (Right (incompats, ps)) -- fixpoint
--     step incompats ps (i : rest) =
--         case relation ps i of
--             ISatisfied -> do
--                 logMsg (Conflict i)
--                 case conflictResolution rootPkg rootV i ps of
--                     Left terminal -> pure (Left terminal)
--                     Right (almostPkg, rootCause, ps') -> do
--                         logMsg (Backtracked (psLevel ps') :: SolverMsg p s)
--                         let ps'' = addDerivation almostPkg rootCause ps'
--                         scan (rootCause : incompats) ps''
--             IAlmostSatisfied q ->
--                 scan incompats (addDerivation q i ps)
--             _ -> step incompats ps rest

-- -- | Failure: no solution; carries the terminal incompatibility (the root of
-- -- the derivation tree, for reporting).
-- newtype SolveError p s = NoSolution (Incompatibility p s)

-- deriving stock instance (Eq p, Eq s, Eq (Elem s)) => Eq (SolveError p s)
-- deriving stock instance (Show p, Show s, Show (Elem s)) => Show (SolveError p s)

-- -- | Structured progress events emitted during resolution.
-- data SolverMsg p s
--     = -- | about to choose an element for p within this range
--       Deciding p s
--     | -- | picked this element for p
--       Chose p (Elem s)
--     | -- | no element available in range (forces a conflict next)
--       NoVersionFor p s
--     | -- | this incompatibility is satisfied (a conflict)
--       Conflict (Incompatibility p s)
--     | -- | backtracked to this decision level
--       Backtracked Int

-- deriving stock instance (Eq p, Eq s, Eq (Elem s)) => Eq (SolverMsg p s)
-- deriving stock instance (Show p, Show s, Show (Elem s)) => Show (SolverMsg p s)

-- -- | Solve for a root package pinned to @rootV@. Returns a complete assignment
-- -- or a 'SolveError'. Emits decision-level progress via co-log.
-- solve
--     :: forall dp p s m env
--      . ( DependencyProvider dp p s m
--        , Eq s
--        , Sets s
--        , WithLog env (SolverMsg p s) m
--        , Ord p
--        )
--     => dp
--     -> p
--     -> Elem s
--     -> m (Either (SolveError p s) (Map p (Elem s)))
-- solve dp rootPkg rootV = go [notRoot rootPkg rootV] emptyPS
--   where
--     go incompats ps = do
--         result <- unitPropagation rootPkg rootV incompats ps
--         case result of
--             Left terminal -> pure (Left (NoSolution terminal))
--             Right (incompats', ps') ->
--                 case undecidedPositive ps' of
--                     [] -> pure (Right (extractSolution ps'))
--                     ((p, range) : _) -> do
--                         logMsg (Deciding p range)
--                         expanded <- expand dp p range
--                         case expanded of
--                             Nothing -> do
--                                 logMsg (NoVersionFor p range)
--                                 go (noVersions p range : incompats') ps'
--                             Just (v, deps) -> do
--                                 logMsg (Chose p v :: SolverMsg p s)
--                                 let depIncs =
--                                         [ fromDependency p (singleton v) (q, r)
--                                         | (q, r) <- Map.toList deps
--                                         ]
--                                 go (depIncs ++ incompats') (addDecision p v ps')
