{-# LANGUAGE LambdaCase #-}

-- | The PubGrub solving loop, over the variables of a 'Domain': for cabal,
-- package names, each taking an instance, and automatic flags, each taking a
-- Boolean.
--
-- Two layers: the storage layer — 'Assignment', 'VarAssignments',
-- 'PartialSolution' and their queries — and the algorithm on top
-- ('unitPropagation', 'conflictResolution', 'solve').
--
-- The storage layer exists to make the algorithm's questions cheap. Every one
-- of them is about a single variable, so assignments are indexed by variable and
-- each variable's accumulated term is cached: propagation judges an
-- incompatibility with a lookup per term instead of a scan of the whole
-- partial solution.
module PubGrub.Solver
    ( -- * Provider
      Provider (..)

      -- * Partial solution
    , Assignment (..)
    , AssignmentKind (..)
    , assignmentTerm
    , decidedValue
    , assignmentVarTerm
    , VarAssignments (..)
    , PartialSolution (..)
    , emptyPS
    , addDecision
    , addDerivation
    , backtrack
    , termIntersectionFor
    , psRelation
    , extractSolution
    , undecidedPositive
    , varHistory

      -- * The algorithm
    , unitPropagation
    , conflictResolution
    , SolveError (..)
    , SolverMsg (..)
    , solve
    ) where

import           Colog.Core                     (LogAction, (<&))
import           Control.Applicative            (Alternative (..))
import           Control.Monad                  (foldM)
import           Data.Bifunctor                 (first)
import           Data.Foldable                  (Foldable (..))
import           Data.IntSet                    (IntSet)
import qualified Data.IntSet                    as IntSet
import           Data.List                      (sortOn)
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Data.Maybe                     (fromMaybe, mapMaybe)
import           Data.Sequence                  (Seq)
import qualified Data.Sequence                  as Seq
import           Data.List.NonEmpty             (nonEmpty)
import qualified Data.List.NonEmpty             as NE
import           PubGrub.Incompatibility        (Domain (..),
                                                 IncompatRelation (..),
                                                 Incompatibility (..),
                                                 VarTerm (..),
                                                 incompGet, incompRelation,
                                                 isSeed, noValues, priorCause)
import           PubGrub.Provider               (Provider (..))
import           PubGrub.SetOps                 (SetOps (..))
import           PubGrub.Store                  (Store, allClauses, clauseAt,
                                                 clausesOf, emptyStore,
                                                 insertClause, insertClauses)
import           PubGrub.Term                   (Term (..), anyTerm,
                                                 intersectTerm, negateTerm)


-- --------------------------------------------------------------------------
-- Partial solution
-- --------------------------------------------------------------------------

-- | A single entry in the partial solution: one variable, at one decision
-- level, with the reason it is there.
data Assignment d = Assignment
    { aIndex   :: !Int
    , aLevel   :: !Int
    , aVar :: VarOf d
    , aKind    :: AssignmentKind d
    }

-- | Why an assignment is in the partial solution, and what it asserts: a
-- decision (a freely chosen value) or a derivation (a term forced by unit
-- propagation, with the incompatibility that forced it).
--
-- The two shapes are a sum /inside/ the record rather than two constructors of
-- it because they carry different payloads: sharing @aIndex@, @aLevel@ and
-- @aVar@ across two constructors is what would make the payload fields
-- partial selectors, and a partial selector is a crash waiting for the wrong
-- constructor.
data AssignmentKind d
    = Decision (ValueOf d)
    | Derivation (Term (SetOf d)) (Incompatibility d)

-- | The term contributed by an assignment; for a decision, @Positive@ of the
-- singleton.
assignmentTerm :: Domain d => Assignment d -> Term (SetOf d)
assignmentTerm a = case aKind a of
    Decision i   -> Positive (singleton (aVar a) i)
    Derivation t _ -> t

-- | The value a decision decides; 'Nothing' for a derivation.
decidedValue :: Assignment d -> Maybe (ValueOf d)
decidedValue a = case aKind a of
    Decision i -> Just i
    Derivation{} -> Nothing

-- | The assignment as "one term about one variable".
assignmentVarTerm :: Domain d => Assignment d -> VarTerm d
assignmentVarTerm a = VarTerm (aVar a) (assignmentTerm a)

-- | Everything recorded about one variable: its own assignments oldest-first,
-- the intersection of their terms, and the value it was decided to be if it
-- has been decided.
--
-- @vaTerm@ is a cache of @foldl1 intersectTerm (assignmentTerm <$> vaHistory)@
-- and @vaDecision@ a cache of the (at most one) decision in @vaHistory@;
-- keeping them is what lets propagation ask about a variable without scanning
-- the partial solution. Invariant: a record exists only for a variable with a
-- non-empty history.
data VarAssignments d = VarAssignments
    { vaHistory  :: Seq (Assignment d)
    , vaTerm     :: Term (SetOf d)
    , vaDecision :: Maybe (ValueOf d)
    }

-- | Assignments are indexed by variable, and within a variable stored
-- oldest-first (chronological), so the satisfier search reads them in order
-- without reversing; @psLevel@ is the current decision level; @psNextIndex@ is
-- a monotone counter giving chronological order /across/ variables.
data PartialSolution d = PartialSolution
    { psVariables  :: Map (VarOf d) (VarAssignments d)
    , psLevel     :: !Int
    , psNextIndex :: !Int
    }

emptyPS :: PartialSolution d
emptyPS = PartialSolution{psVariables = Map.empty, psLevel = 0, psNextIndex = 0}

-- | Add one assignment to a variable's record, creating the record if this is
-- the variable's first assignment. The caches move with it: the term folds in
-- by intersection, the decision is remembered.
extendVar :: Domain d => Assignment d -> Maybe (VarAssignments d) -> VarAssignments d
extendVar a Nothing =
    VarAssignments
        { vaHistory = Seq.singleton a
        , vaTerm = assignmentTerm a
        , vaDecision = decidedValue a
        }
extendVar a (Just pa) =
    pa
        { vaHistory = vaHistory pa Seq.|> a
        , vaTerm = intersectTerm (vaTerm pa) (assignmentTerm a)
        , vaDecision = decidedValue a <|> vaDecision pa
        }

-- | Rebuild a record from a history, recomputing both caches. 'Nothing' for an
-- empty history, which has no record.
fromHistory :: Domain d => Seq (Assignment d) -> Maybe (VarAssignments d)
fromHistory = foldl' (\acc a -> Just (extendVar a acc)) Nothing

-- | File an assignment under its variable and consume its index.
recordAssignment :: Domain d => Assignment d -> PartialSolution d -> PartialSolution d
recordAssignment a ps@PartialSolution{psVariables, psNextIndex} =
    ps
        { psVariables = Map.alter (Just . extendVar a) (aVar a) psVariables
        , psNextIndex = psNextIndex + 1
        }

-- | Record a decision (a guess); increments the decision level.
addDecision :: Domain d => VarOf d -> ValueOf d -> PartialSolution d -> PartialSolution d
addDecision p i ps@PartialSolution{psLevel, psNextIndex} =
    recordAssignment
        (Assignment psNextIndex (psLevel + 1) p (Decision i))
        ps{psLevel = psLevel + 1}

-- | Record a derivation: the negation of @cause@'s term for @p@, at the
-- current level.
addDerivation :: Domain d => VarOf d -> Incompatibility d -> PartialSolution d -> PartialSolution d
addDerivation p cause ps@PartialSolution{psLevel, psNextIndex} =
    let term = maybe anyTerm negateTerm (incompGet p cause)
     in recordAssignment (Assignment psNextIndex psLevel p (Derivation term cause)) ps

-- | Backtrack: drop every assignment strictly above the target level.
--
-- Levels are non-decreasing along a history (a derivation takes the current
-- level, a decision the next, and backtracking only lowers it), so what is
-- dropped is always a suffix — which is why this splits the history from the
-- right instead of filtering it: a variable that drops nothing keeps its history
-- as it stands, rather than paying to rebuild an identical one.
--
-- A variable that does lose assignments must have both its caches rebuilt from
-- the survivors — @intersectTerm@ cannot be undone, so the accumulated term is
-- recomputed, and a dropped decision must stop being remembered. A variable that
-- loses all of them loses its record.
backtrack :: Domain d => Int -> PartialSolution d -> PartialSolution d
backtrack level ps@PartialSolution{psVariables} =
    ps
        { psVariables = Map.mapMaybe prune psVariables
        , psLevel = level
        }
  where
    prune pa = case Seq.spanr ((> level) . aLevel) (vaHistory pa) of
        (dropped, kept)
            | Seq.null dropped -> Just pa
            | otherwise -> fromHistory kept

-- | Intersection of all terms recorded for a variable ('Nothing' if the
-- variable is unmentioned, which judges as 'anyTerm' = ⊤).
termIntersectionFor :: Domain d => PartialSolution d -> VarOf d -> Maybe (Term (SetOf d))
termIntersectionFor PartialSolution{psVariables} p =
    vaTerm <$> Map.lookup p psVariables

-- | Relation of the whole partial solution to an incompatibility.
psRelation :: Domain d => PartialSolution d -> Incompatibility d -> IncompatRelation (VarOf d)
psRelation ps = incompRelation (termIntersectionFor ps)

-- | The decisions, as a solution map.
extractSolution :: PartialSolution d -> Map (VarOf d) (ValueOf d)
extractSolution PartialSolution{psVariables} = Map.mapMaybe vaDecision psVariables

-- | Variables that have a positive accumulated term but no decision yet, with
-- that positive set. Ordered by first mention (oldest first) for
-- determinism.
undecidedPositive :: PartialSolution d -> [(VarOf d, SetOf d)]
undecidedPositive PartialSolution{psVariables} =
    map snd (sortOn fst (mapMaybe candidate (Map.toList psVariables)))
  where
    candidate (p, pa) = case (vaDecision pa, vaTerm pa) of
        (Nothing, Positive r) -> Just (firstIndex pa, (p, r))
        _                     -> Nothing
    -- The variable's first mention, which is what the order is keyed on. A
    -- record always has a non-empty history, so the fallback is unreachable.
    firstIndex pa = maybe maxBound aIndex (Seq.lookup 0 (vaHistory pa))

-- | All assignments for a variable, oldest first. The satisfier search walks
-- this list.
varHistory :: Domain d => PartialSolution d -> VarOf d -> [Assignment d]
varHistory PartialSolution{psVariables} p =
    maybe [] (toList . vaHistory) (Map.lookup p psVariables)

-- --------------------------------------------------------------------------
-- The algorithm
-- --------------------------------------------------------------------------

-- | Result of searching for the satisfier of a conflict incompatibility.
data SatisfierSearch d
    = DifferentDecisionLevels !Int
      -- ^ backtrack to this level
    | SameDecisionLevels (Incompatibility d)
      -- ^ satisfier's cause

-- | Earliest assignment of @p@ whose running accumulated term becomes disjoint
-- from @startTerm@, or 'Nothing' if none does.
satisfierOf
    :: Domain d
    => PartialSolution d
    -> VarOf d
    -> Term (SetOf d)
    -> Maybe (Assignment d)
satisfierOf ps p startTerm = go anyTerm (varHistory ps p)
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
    :: Domain d
    => PartialSolution d
    -> Incompatibility d
    -> Either (SolveError d) (VarOf d, SatisfierSearch d)
satisfierSearch ps i = do
    satMap <- traverse satisfierForTerm (Map.toList (incompTerms i))
    (satVar, satAssign) <- latestSatisfier satMap
    let satLevel = aLevel satAssign
        it_s = fromMaybe anyTerm (incompGet satVar i)
        startTerm' = intersect (assignmentTerm satAssign) (negateTerm it_s)
    prevForSat <- require satVar (satisfierOf ps satVar startTerm')
    let satMap' = [(p, if p == satVar then prevForSat else a) | (p, a) <- satMap]
    (_, prevAssign) <- latestSatisfier satMap'
    -- No floor. The requests are derivations at level 0, so the first decision
    -- at level 1 is an ordinary one that a conflict may have to undo. The spec
    -- stops at level 1 (@references\/pubgrub.md:398@), where its root package
    -- was selected, and notes that level 0 is safe (:401).
    let prevLevel = aLevel prevAssign
    pure $ case aKind satAssign of
        Derivation _ cause
            | prevLevel >= satLevel -> (satVar, SameDecisionLevels cause)
        _ -> (satVar, DifferentDecisionLevels prevLevel)
  where
    satisfierForTerm (p, it) = (,) p <$> require p (satisfierOf ps p (negateTerm it))
    require p = maybe (Left (NoSatisfier p i)) Right
    -- An incompatibility with no terms is the empty clause: unsatisfiable
    -- outright, hence a terminal failure. 'satisfiedBySeeds' catches it before
    -- conflict resolution ever gets here, so this is the same verdict by
    -- another route, not a second opinion.
    latestSatisfier = maybe (Left (NoSolution i)) Right . maximumOn (aIndex . snd)

-- | The assignments the seeds made: the level-0 derivations whose cause is a
-- 'PubGrub.Incompatibility.request'. They are the oldest assignments of all,
-- and they are never backtracked.
seedAssignments :: Domain d => PartialSolution d -> VarOf d -> [Assignment d]
seedAssignments ps p = [a | a <- varHistory ps p, fromSeed a]
  where
    fromSeed a = case aKind a of
        Derivation _ cause -> isSeed cause
        Decision _       -> False

-- | Is the incompatibility satisfied by the seeds' own derivations alone? Then
-- no decision took part in the conflict, so nothing can be backtracked and
-- version solving has failed. This is PubGrub's terminal test stated over the
-- seeds. The published algorithm starts from a single root package, so its
-- only level-0 derivation is the root's, and it stops on an incompatibility
-- that is empty or names the root alone; here the level-0 derivations are
-- whatever the seeds derived. An empty incompatibility is satisfied by
-- anything, and one whose every term is subsumed by a seed's derivation is
-- satisfied before anything is decided.
--
-- Checked before the satisfier search, which is what keeps a seed from ever being
-- a satisfier's cause: the seeds are the oldest assignments, so a seed derivation
-- is the latest satisfier only when it is the only one.
satisfiedBySeeds :: Domain d => PartialSolution d -> Incompatibility d -> Bool
satisfiedBySeeds ps inc = incompRelation seedTerm inc == ISatisfied
  where
    seedTerm p = foldr1 intersectTerm . NE.map assignmentTerm <$> nonEmpty (seedAssignments ps p)

-- | Resolve a terminal incompatibility against the seeds it rests on, one
-- 'priorCause' per seed, so that the incompatibility handed to the report is the
-- empty one and its derivation ends with the request: a proof's last line names
-- the request and concludes "version solving failed". Here the request is the
-- seeds, and the last step is taken explicitly.
--
-- Each step is a genuine resolution: 'satisfiedBySeeds' holds, so every term is
-- subsumed by its seed's derivation and the union over the pivot is ⊤. The
-- emptiness test that drops it is the one 'PubGrub.Relation.relation' answered
-- "satisfied" with, so the two agree. A term that nonetheless survives is left
-- as it is: the verdict is decided, and the report prints the closing line as
-- failure whatever the terms say.
closeWithSeeds
    :: (Domain d, Monad m)
    => LogAction m (SolverMsg d) -> PartialSolution d -> Incompatibility d -> m (Incompatibility d)
closeWithSeeds logA ps = go
  where
    -- One pass over the seeds of every variable still named; another pass while
    -- a pass removed something. Two seeds on one variable need the second pass:
    -- the first alone leaves the part of its range the other seed excludes.
    go inc = do
        inc' <- foldM step inc [(p, cause) | p <- Map.keys (incompTerms inc), a <- seedAssignments ps p, Derivation _ cause <- [aKind a]]
        if Map.size (incompTerms inc') < Map.size (incompTerms inc) then go inc' else pure inc'
    step inc (p, cause)
        | Map.member p (incompTerms inc) = do
            let next = priorCause inc cause p
            logA <& Resolving p next
            pure next
        | otherwise = pure inc

-- | Propagate the incompatibilities to a fixpoint: judge each with
-- 'psRelation'; on @IAlmostSatisfied p@ derive (¬ its term for @p@) via
-- 'addDerivation'; on @ISatisfied@ hand off to 'conflictResolution'. Returns
-- the terminal incompatibility on unsolvable input, or the (possibly grown)
-- store and updated solution.
--
-- The clause acted on is the __newest__ clause that is satisfied or almost
-- satisfied — the first one a scan of the store from the front would find — and
-- a learned clause goes back through 'insertClause' rather than being consed
-- on, which is what gives dependency facts about one pair of packages the chance
-- to merge ('PubGrub.Store').
--
-- Which clauses are judged is a worklist, not the store. A clause's relation
-- depends only on the accumulated terms of the variables it mentions, and a
-- call starts from a fixpoint — nothing was actionable when the last one
-- returned — so the only clauses whose relation can have changed are the ones
-- the caller names: the ones inserted or merged into since then, and the ones
-- mentioning a variable it decided. Within the call, after a derivation on @q@
-- they are the clauses that mention @q@ ('clausesOf'). Those are re-judged and
-- the set of actionable clauses kept up to date; everything else keeps the
-- judgement it had. After a backtrack every clause is re-judged, once per
-- conflict. The clause chosen is therefore the one a full scan would choose,
-- every time: the search does not depend on the worklist, and between
-- conflicts the number of judgements is proportional to what changed.
unitPropagation
    :: forall d m. (Domain d, Monad m)
    => LogAction m (SolverMsg d)
    -> IntSet
    -- ^ the clauses whose relation may have changed since the last fixpoint
    -> Store d
    -> PartialSolution d
    -> m (Either (SolveError d) (Store d, PartialSolution d))
unitPropagation logA pending store0 ps0 = settle pending IntSet.empty store0 ps0
  where
    -- Judge the dirty clauses, then act on the newest actionable one.
    settle dirty actionable store ps = do
        logA <& (Judged (IntSet.size dirty) :: SolverMsg d)
        let actionable' = IntSet.foldl' (judge store ps) actionable dirty
        case IntSet.maxView actionable' of
            Nothing -> pure (Right (store, ps))
            Just (c, rest) -> act c rest store ps

    judge store ps acc c = case clauseAt store c of
        Just i | actionableRelation (psRelation ps i) -> IntSet.insert c acc
        _ -> IntSet.delete c acc

    actionableRelation ISatisfied          = True
    actionableRelation (IAlmostSatisfied _) = True
    actionableRelation _                   = False

    act c actionable store ps = case clauseAt store c of
        Nothing -> settle IntSet.empty actionable store ps
        Just i -> case psRelation ps i of
            ISatisfied -> do
                -- 'conflictResolution' is pure, so both of its events are logged
                -- from here: the conflict before it runs, and the level it landed
                -- on after. A terminal conflict logs the first and not the second,
                -- which is the right shape — nothing was backtracked to.
                logA <& Conflict i
                conflictResolution logA i ps >>= \case
                    Left err ->
                        pure (Left err)
                    Right (almostVar, rootCause, ps') -> do
                        logA <& Learned rootCause
                        -- 'Backtracked' carries only a level, which does not
                        -- determine @d@, so the message's type is annotated.
                        logA <& (Backtracked (psLevel ps') :: SolverMsg d)
                        -- Judge everything again, learned clause included. Only
                        -- the clauses of the variables the backtrack moved can
                        -- have changed, but judging just those saves nothing
                        -- measurable (DESIGN §5), and this needs no argument.
                        let (_, store') = insertClause rootCause store
                        settle (allClauses store') IntSet.empty store' (addDerivation almostVar rootCause ps')
            IAlmostSatisfied q ->
                settle (clausesOf q store) actionable store (addDerivation q i ps)
            -- Not actionable after all: unreachable while the actionable set is
            -- kept right, and harmless if it is not — the clause is dropped from
            -- the set and the next newest is tried.
            _ -> settle IntSet.empty actionable store ps


-- | Conflict resolution: satisfier search over 'varHistory', 'priorCause'
-- while satisfier and previous satisfier share a decision level, then
-- 'backtrack'. Returns the failure (no solution, or a violated invariant), or
-- the pivot variable, the learned root cause, and the backtracked solution.
-- It is monadic only to log 'Resolving': the outcome depends on the partial
-- solution alone.
conflictResolution
    :: (Domain d, Monad m)
    => LogAction m (SolverMsg d)
    -> Incompatibility d
    -> PartialSolution d
    -> m (Either (SolveError d) (VarOf d, Incompatibility d, PartialSolution d))
conflictResolution logA = loop
  where
    loop current ps
        | satisfiedBySeeds ps current = Left . NoSolution <$> closeWithSeeds logA ps current
        | otherwise =
            case satisfierSearch ps current of
                Left err -> pure (Left err)
                Right (satVar, DifferentDecisionLevels prevLevel) ->
                    pure (Right (satVar, current, backtrack prevLevel ps))
                Right (satVar, SameDecisionLevels satCause) -> do
                    let next = priorCause current satCause satVar
                    logA <& Resolving satVar next
                    loop next ps


-- | Failure. Either the problem has no solution, or an invariant the solver
-- relies on did not hold — the latter cannot happen for a consistent partial
-- solution, and exists so that if it ever does, it arrives as a value to
-- report instead of an exception from inside a pure function.
data SolveError d
    = -- | no solution; carries the terminal incompatibility (the root of the
      -- derivation tree, for reporting)
      NoSolution (Incompatibility d)
    | -- | conflict resolution found a term of a satisfied incompatibility
      -- whose variable has no satisfier in the partial solution
      NoSatisfier (VarOf d) (Incompatibility d)

-- | Structured progress events emitted during resolution.
data SolverMsg d
    = -- | about to choose an element for p within this range
      Deciding (VarOf d) (SetOf d)
    | -- | picked this element for p
      Chose (VarOf d) (ValueOf d)
    | -- | no element available in range (forces a conflict next)
      NoVersionFor (VarOf d) (SetOf d)
    | -- | this incompatibility is satisfied (a conflict)
      Conflict (Incompatibility d)
    | -- | one step of conflict resolution: the satisfier it located, and the
      -- prior cause derived from it. Fires once per iteration in which the
      -- satisfier and the previous satisfier share a decision level, so the
      -- count of these between a 'Conflict' and its 'Backtracked' /is/ the depth
      -- of that resolution — which nothing else reports.
      Resolving (VarOf d) (Incompatibility d)
    | -- | the root cause conflict resolution settled on, about to be added to
      -- the store. Distinct from the 'Conflict' that started it: that one was
      -- already known, this one is what was learned.
      Learned (Incompatibility d)
    | -- | backtracked to this decision level
      Backtracked Int
    | -- | one round of propagation judged this many clauses against the
      -- partial solution: the ones the store had marked dirty. The round right
      -- after a 'Backtracked' is the one that re-judges after the backtrack, so
      -- the sum of those is what a backtrack costs propagation.
      Judged Int

-- | Solve for the seeds, one 'PubGrub.Incompatibility.request' per target, by
-- alternating 'unitPropagation' with decisions: take the first
-- 'undecidedPositive' variable and ask the 'Provider' to 'expand' its range
-- into a value and the incompatibilities that value entails.
--
-- The seeds go in first and in order, so their derivations are the oldest
-- assignments and the targets are decided in the order they were asked for.
solve
    :: (Domain d, Monad m)
    => LogAction m (SolverMsg d)
    -> Provider d m
    -> [Incompatibility d]
    -> m (Either (SolveError d) (Map (VarOf d) (ValueOf d)))
solve logA provider seeds =
    uncurry go (insertClauses seeds emptyStore) emptyPS
    where
        go pending incompats ps =
            unitPropagation logA pending incompats ps >>= \case
                Left err -> pure (Left err)
                Right (incompats', ps') ->
                    case undecidedPositive ps' of
                        [] -> pure (Right (extractSolution ps'))
                        ((p, range) : _) -> do
                            logA <& Deciding p range
                            expand provider p range >>= \case
                                (Just i, incs) -> do
                                    logA <& Chose p i
                                    let (inserted, store) = insertClauses incs incompats'
                                    go (inserted <> clausesOf p store) store (addDecision p i ps')
                                (Nothing, facts) -> do
                                    logA <& NoVersionFor p range
                                    let (banned, store) = banRest p range facts incompats'
                                        (inserted, store') = insertClauses facts store
                                    go (banned <> inserted) store' ps'

        -- The provider has nothing to offer in @range@, and may have said why:
        -- clauses banning the releases it rejected on the way
        -- (@references\/pubgrub.md:475@). Those are a better explanation than
        -- "no version for p in range" — they name the reason rather than the
        -- symptom — but they are not necessarily a complete one, so what is left
        -- of the range gets the weaker statement it deserves and no more.
        --
        -- __Progress does not depend on the provider being thorough.__ Whatever it
        -- says, this bans all of @range@ between them: the facts cover part, the
        -- @noValues@ clause covers the remainder. So @p@ cannot be offered the
        -- same set twice, which is the property termination rests on. 'isEmpty' is
        -- one-sided on a set — it may miss that a set is empty — and it
        -- errs in the safe direction here: a redundant clause, never a missing one.
        banRest p range facts
            -- Said nothing: the range itself, untouched. A @difference@ against the
            -- empty set would give an equivalent but differently shaped DNF, and so
            -- change the search for every provider that states no facts.
            | [] <- stated = landed (noValues p range)
            | isEmpty leftover = (,) IntSet.empty
            | otherwise = landed (noValues p leftover)
          where
            leftover = case stated of
                []       -> range
                (s : ss) -> range `difference` foldr union s ss
            stated = [s | inc <- facts, Just (Positive s) <- [incompGet p inc]]
            landed inc = first IntSet.singleton . insertClause inc
