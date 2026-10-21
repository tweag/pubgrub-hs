{-# LANGUAGE DerivingStrategies   #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE StandaloneDeriving   #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Solving: 'solve' runs PubGrub over a t'PubGrub.Provider.Provider' and the
-- incompatibilities it is asked to satisfy, and answers with a value for every
-- variable it decided, or with the incompatibility that proves there is none.
module PubGrub.Solver
    ( solve
    , SolveError (..)
    , SolverMsg (..)
    ) where

import           Colog.Core              (LogAction, (<&))
import           Control.Monad           (foldM)
import           Data.Bifunctor          (first)
import           Data.IntSet             (IntSet)
import qualified Data.IntSet             as IntSet
import           Data.List.NonEmpty      (nonEmpty)
import qualified Data.List.NonEmpty      as NE
import           Data.Map.Strict         (Map)
import qualified Data.Map.Strict         as Map
import           Data.Maybe              (fromMaybe)
import           PubGrub.Incompatibility (Domain (..), Incompatibility (..),
                                          incompGet, isSeed, noValues,
                                          priorCause)
import           PubGrub.PartialSolution (Assignment (..), AssignmentKind (..),
                                          PartialSolution (..), addDecision,
                                          addDerivation, assignmentTerm,
                                          backtrack, emptyPS, extractSolution,
                                          psRelation, undecidedPositive,
                                          varHistory)
import           PubGrub.Provider        (Provider (..))
import           PubGrub.Relation        (IncompatRelation (..), incompRelation)
import           PubGrub.SetOps          (SetOps (..))
import           PubGrub.Store           (Store, allClauses, clauseAt,
                                          clausesOf, emptyStore, insertClause,
                                          insertClauses)
import           PubGrub.Term            (Term (..), anyTerm, intersectTerm,
                                          negateTerm)

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

-- | 'Data.List.maximumBy' on a key, total. Ties keep the earlier element, which never
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
-- seed ('isSeed'). They are the oldest assignments of all, and they are never
-- backtracked.
seedAssignments :: Domain d => PartialSolution d -> VarOf d -> [Assignment d]
seedAssignments ps p = [a | a <- varHistory ps p, fromSeed a]
  where
    fromSeed a = case aKind a of
        Derivation _ cause -> isSeed cause
        Decision _         -> False

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
            Nothing        -> pure (Right (store, ps))
            Just (c, rest) -> act c rest store ps

    judge store ps acc c = case clauseAt store c of
        Just i | actionableRelation (psRelation ps i) -> IntSet.insert c acc
        _                                             -> IntSet.delete c acc

    actionableRelation ISatisfied           = True
    actionableRelation (IAlmostSatisfied _) = True
    actionableRelation _                    = False

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


-- | Why 'solve' found no solution. Only 'NoSolution' is a verdict on the
-- problem; the others say the solve was given something it cannot work with.
data SolveError d
    = -- | There is none. The incompatibility is the end of the proof: normally
      -- one with no terms, which can never be satisfied, derived from the seeds
      -- and from facts the provider stated. Its 'PubGrub.Incompatibility.Cause'
      -- tree is the argument for why; "PubGrub.Report" writes it out and
      -- "PubGrub.Derivation" reads it.
      NoSolution (Incompatibility d)
    | -- | This seed is not a request or a constraint: its cause is not
      -- 'PubGrub.Incompatibility.Seed', or it has more or fewer than one term.
      -- The solve is refused before it starts. A seed with two negative terms,
      -- say, asks for one of two variables to have a value without saying
      -- which, and the search would never decide either: the answer would be a
      -- plan that violates the seed.
      BadSeed (Incompatibility d)
    | -- | The provider chose a value outside the set it was offered: the
      -- variable, the value, and the set. The solver stops at once, because
      -- recording such a decision contradicts what it had already derived and
      -- the search would never end. This is a bug in the provider.
      BadValue (VarOf d) (ValueOf d) (SetOf d)
    | -- | The solver broke an invariant of its own: conflict resolution found a
      -- term of a violated incompatibility that nothing it had recorded about
      -- the variable accounts for. This is a bug in the solver, returned as a
      -- value so that a caller can report it.
      NoSatisfier (VarOf d) (Incompatibility d)

deriving stock instance (Eq (VarOf d), Eq (ValueOf d), Eq (SetOf d), Eq (FactOf d)) => Eq (SolveError d)
deriving stock instance (Show (VarOf d), Show (ValueOf d), Show (SetOf d), Show (FactOf d)) => Show (SolveError d)

-- | What the solver is doing, one message per step of the search. 'solve'
-- sends them to the log action it is given.
data SolverMsg d
    = -- | About to ask the provider for a value of the variable in the set.
      Deciding (VarOf d) (SetOf d)
    | -- | The provider chose this value, and the solver decided it.
      Chose (VarOf d) (ValueOf d)
    | -- | The provider had no value in the set. A conflict follows.
      NoVersionFor (VarOf d) (SetOf d)
    | -- | This incompatibility is violated by what has been decided: a
      -- conflict, which conflict resolution starts from.
      Conflict (Incompatibility d)
    | -- | One step of conflict resolution: the variable it resolved on, and
      -- the incompatibility it derived. The number of these between a
      -- 'Conflict' and its 'Backtracked' is how deep that resolution went.
      Resolving (VarOf d) (Incompatibility d)
    | -- | The incompatibility conflict resolution learned, which the solver now
      -- keeps. The 'Conflict' that started it was already known; this is new.
      Learned (Incompatibility d)
    | -- | The solver undid every decision above this level. A level is the
      -- number of decisions in force.
      Backtracked Int
    | -- | One round of propagation examined this many incompatibilities, the
      -- ones that may have changed since the last. The round right after a
      -- 'Backtracked' re-examines what the backtrack undid.
      Judged Int

deriving stock instance (Eq (VarOf d), Eq (ValueOf d), Eq (SetOf d), Eq (FactOf d)) => Eq (SolverMsg d)
deriving stock instance (Show (VarOf d), Show (ValueOf d), Show (SetOf d), Show (FactOf d)) => Show (SolverMsg d)

-- | Solve: find a value for every variable the request needs, or prove that
-- there is none.
--
-- The seeds are the request, incompatibilities whose cause is
-- 'PubGrub.Incompatibility.Seed': @{p: Negative s}@ asks for @p@ to have a
-- value in @s@, and @{p: Positive f}@ forbids @p@ the values in @f@ (see
-- t'Incompatibility'). Those are the only two shapes: a seed with any other
-- cause, or with more or fewer than one term, is answered with 'BadSeed'
-- before the search starts. The solver alternates two steps. It derives
-- everything that what it knows implies about each variable; then, of the
-- variables that must have a value and have none yet, it takes the one the
-- search reached first, and asks the provider for a value
-- ('PubGrub.Provider.expand'). The requested variables come first, in the
-- order of the seeds. When no variable is left without a value, the solve is
-- done; when a conflict rests on the seeds alone, there is no solution.
--
-- The answer maps each variable the solver decided to its value: those the
-- request requires, directly or through what the provider stated. A variable
-- nothing requires is not in it.
--
-- The first argument receives a 'SolverMsg' at each step, a @LogAction@ from
-- co-log-core; 'mempty' discards them.
solve
    :: (Domain d, Monad m)
    => LogAction m (SolverMsg d)
    -> Provider d m
    -> [Incompatibility d]
    -> m (Either (SolveError d) (Map (VarOf d) (ValueOf d)))
solve logA provider seeds
    | (bad : _) <- filter (not . wellFormedSeed) seeds = pure (Left (BadSeed bad))
    | otherwise = uncurry go (insertClauses seeds emptyStore) emptyPS
    where
        -- A request or a constraint: one term, marked as a seed.
        wellFormedSeed i = isSeed i && Map.size (incompTerms i) == 1

        go pending incompats ps =
            unitPropagation logA pending incompats ps >>= \case
                Left err -> pure (Left err)
                Right (incompats', ps') ->
                    case undecidedPositive ps' of
                        [] -> pure (Right (extractSolution ps'))
                        ((p, range) : _) -> do
                            logA <& Deciding p range
                            expand provider p range >>= \case
                                -- The provider's contract, checked: a decision
                                -- outside the offered set would contradict the
                                -- derivation that offered it, and the search
                                -- would not terminate.
                                (Just i, _)
                                    | not (singleton p i `isSubsetOf` range) ->
                                        pure (Left (BadValue p i range))
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
