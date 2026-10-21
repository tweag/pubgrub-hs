{-# LANGUAGE DerivingStrategies   #-}
{-# LANGUAGE StandaloneDeriving   #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Incompatibilities, the solver's only kind of knowledge, and the 'Domain'
-- they are stated in.
--
-- The solver is written once, over a domain it knows only through 'Domain':
-- what a variable is, what its values and sets of values are, and what an
-- external fact says. Everything it is told, by the request and by the
-- provider, and everything it learns, is an t'Incompatibility'.
module PubGrub.Incompatibility
    ( -- * The domain
      Domain (..)
    , MergeRule (..)
    , noMerging
      -- * Incompatibilities
    , Incompatibility (..)
    , Cause (..)
    , incompGet
    , noValues
    , isSeed
      -- * Resolution
      -- | The step conflict resolution derives a new incompatibility with. A
      -- formatter's tests can build a derivation by hand with 'priorCause', and
      -- a formatter rule that says several steps in one line can check that it
      -- is sound by replaying them with 'priorCauseTerms'.
    , priorCause
    , priorCauseTerms
    ) where

import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           PubGrub.SetOps  (SetOps (..))
import           PubGrub.Term    (Term (..), anyTerm, intersectTerm, isTopTerm,
                                  unionTerm)

-- Specialised in the client, with the solver ("PubGrub.Solver" says why).
{-# INLINABLE incompGet #-}
{-# INLINABLE noValues #-}
{-# INLINABLE priorCause #-}
{-# INLINABLE priorCauseTerms #-}

-- --------------------------------------------------------------------------
-- Domain
-- --------------------------------------------------------------------------

-- | A problem domain: everything the solver needs to know about what it is
-- solving over, and nothing it does not. The solver compares variables with
-- 'Ord' and combines sets with 'SetOps'; what a variable, a value or a fact
-- /is/ never reaches it.
--
-- The instance is on the type of the /variables/, the things the solver
-- assigns values to, and that type names the domain everywhere: an
-- @t'Incompatibility' v@ is one over the domain whose variables are @v@. The
-- associated types say what a variable's values, its sets of values and the
-- facts about it are.
class (Ord v, SetOps (SetOf v)) => Domain v where
    -- | The values a variable takes.
    type ValueOf v
    -- | A set of values of one variable: what a 'Term' ranges over.
    type SetOf v
    -- | An external fact: what the domain knows about the world, recorded as
    -- the 'Cause' of the incompatibility that states it. The solver never reads
    -- it; it is what a failure is explained from.
    type FactOf v

    -- | The set holding exactly one value of the variable. The solver states
    -- a decision with it.
    singleton :: v -> ValueOf v -> SetOf v

    -- | Which incompatibilities say the same thing, and the one that says it
    -- once. The solver applies it as incompatibilities arrive. The default
    -- merges nothing.
    mergeRule :: MergeRule v
    mergeRule = noMerging

-- | A merge rule: two incompatibilities with the same key are one piece of
-- knowledge in two parts, and 'mergeWith' is the one incompatibility that
-- states both. The solver keeps at most one incompatibility per key: one that
-- arrives with a key already taken is merged into the one that has it, which
-- keeps its place in the order the solver judges them in. The key type is the
-- rule's own.
--
-- Merging is worth having where a provider states the same fact many times
-- over: two dependencies of neighbouring versions of @p@ on the same range of
-- @q@ are one dependency of both versions. The merged incompatibility
-- propagates further than either part, and a proof names it once.
--
-- __Soundness.__ The merged incompatibility replaces both parts, so it must say
-- exactly what the two say together. Merging @{p: Positive a, q: Negative r}@
-- with @{p: Positive b, q: Negative r}@ into
-- @{p: Positive (a ∪ b), q: Negative r}@ is sound, because "@p@ in @a ∪ b@"
-- is "@p@ in @a@ or @p@ in @b@".
--
-- __The law.__ A merged incompatibility has the key its parts had: whenever
-- @mergeKey a == Just k@ and @mergeKey b == Just k@,
--
-- @
-- mergeKey (mergeWith a b) == Just k
-- @
--
-- The solver files the merged incompatibility under @k@ without asking again.
-- Nothing else is required: a merge may change which variables the
-- incompatibility mentions.
data MergeRule v = forall k. Ord k => MergeRule
    { mergeKey  :: Incompatibility v -> Maybe k
      -- ^ the key of an incompatibility that may be merged, or 'Nothing' for
      -- one that is never merged
    , mergeWith :: Incompatibility v -> Incompatibility v -> Incompatibility v
      -- ^ the incompatibility already held and the arriving one, both with the
      -- same key, to the one that replaces them
    }

-- | No two clauses merge.
noMerging :: MergeRule v
noMerging = MergeRule{mergeKey = const (Nothing :: Maybe ()), mergeWith = const}

-- --------------------------------------------------------------------------
-- Incompatibility
-- --------------------------------------------------------------------------

-- | A set of terms, at most one per variable, that cannot /all/ be true in a
-- solution. Every fact the solver is given or learns has this shape:
--
-- @
-- {p: t, q: u}   means   not (t is true of p and u is true of q)
-- @
--
-- Read as an implication, it states the familiar facts. With @'Positive' s@
-- read as "has a value in @s@" and @'Negative' s@ as "has no value, or one
-- outside @s@":
--
--   * @{p: Negative s}@: @p@ must have a value, in @s@. A request, with
--     cause 'Seed'.
--   * @{p: Positive f}@: @p@ may not take a value in @f@. A constraint on the
--     request, with cause 'Seed', or the solver's own finding ('noValues').
--   * @{p: Positive s, q: Negative r}@: if @p@ has a value in @s@, then @q@
--     has a value in @r@. A dependency, with cause 'Fact'.
--   * @{p: Positive s, q: Positive r}@: @p@ in @s@ and @q@ in @r@ cannot both
--     be. A conflict, with cause 'Fact'.
--
-- A term that is always true ('PubGrub.Term.isTopTerm') says nothing, and is
-- left out. An incompatibility with a term that is never true
-- ('PubGrub.Term.isBottomTerm') can never be violated, and is not worth
-- stating. An incompatibility with no terms is always violated: it is what a
-- failed solve ends with.
--
-- Every incompatibility records why it holds, its 'Cause', which is what a
-- failure is explained from. The cause never changes what an incompatibility
-- means.
data Incompatibility v = Incompatibility
    { incompTerms :: Map (v) (Term (SetOf v))
    , incompCause :: Cause v
    }

-- | Why an incompatibility holds. It is either /external/, a fact the solver
-- was given or found, or /derived/ by the solver from two others. A failed
-- solve ends with an incompatibility whose causes form a tree: derived nodes,
-- with external facts at the leaves. That tree is the explanation of the
-- failure ("PubGrub.Derivation" reads it, "PubGrub.Report" writes it out), and
-- the domain supplies only what a leaf says ('FactOf').
--
-- A seed is kept apart from other facts because the solver treats it
-- specially: a conflict that rests on the seeds alone ends the search, since
-- no decision can be undone to avoid it.
data Cause v
    = Seed (FactOf v)
      -- ^ part of the request: what the solve was asked for, or a constraint
      -- on it
    | Fact (FactOf v)
      -- ^ a fact about the world, stated by the provider
    | NoValues (v) (SetOf v)
      -- ^ the solver's own fact: the provider had nothing to offer in this
      -- set of the variable's values ('noValues')
    | Derived (Incompatibility v) (Incompatibility v)
      -- ^ the resolvent of two incompatibilities, in the order 'priorCause'
      -- took them

-- The instances are structural, over the whole cause tree: two derived
-- incompatibilities are equal when their terms and their derivations are, and
-- 'show' prints the tree. They are what a test asserts with and what GHCi
-- prints; a report of a failure is "PubGrub.Report".
deriving stock instance (Eq (v), Eq (SetOf v), Eq (FactOf v)) => Eq (Incompatibility v)
deriving stock instance (Eq (v), Eq (SetOf v), Eq (FactOf v)) => Eq (Cause v)
deriving stock instance (Show (v), Show (SetOf v), Show (FactOf v)) => Show (Incompatibility v)
deriving stock instance (Show (v), Show (SetOf v), Show (FactOf v)) => Show (Cause v)

-- | The term an incompatibility states about @v@, if any.
incompGet :: Domain v => v -> Incompatibility v -> Maybe (Term (SetOf v))
incompGet v (Incompatibility m _) = Map.lookup v m

-- | @{v: Positive s}@, caused by 'NoValues': the variable takes no value in
-- @s@. The solver states it when the provider has no value to offer in @s@.
noValues :: Domain v => v -> SetOf v -> Incompatibility v
noValues v s = Incompatibility (Map.singleton v (Positive s)) (NoValues v s)

-- | Is this part of the request: is its cause a 'Seed'?
isSeed :: Incompatibility v -> Bool
isSeed i = case incompCause i of
    Seed _ -> True
    _      -> False

-- | The rule of resolution: from two incompatibilities that both mention the
-- pivot variable, the one that follows from both. Its terms are
-- 'priorCauseTerms', and its cause is 'Derived' from the two, in this order.
priorCause
    :: Domain v
    => Incompatibility v
    -- ^ the incompatibility being resolved
    -> Incompatibility v
    -- ^ the incompatibility it is resolved with
    -> v
    -- ^ the pivot, which both mention
    -> Incompatibility v
priorCause current@(Incompatibility cur _) satCause@(Incompatibility sat _) pivot =
    Incompatibility (priorCauseTerms pivot cur sat) (Derived current satCause)

-- | The terms 'priorCause' arrives at: the union of the pivot's two terms,
-- the intersection of every other variable's, and no term for the pivot where
-- the union is always true.
priorCauseTerms
    :: Domain v
    => v
    -- ^ the pivot
    -> Map (v) (Term (SetOf v))
    -- ^ the terms of the incompatibility being resolved
    -> Map (v) (Term (SetOf v))
    -- ^ the terms of the one it is resolved with
    -> Map (v) (Term (SetOf v))
priorCauseTerms pivot cur sat = finalTerms
  where
    merged =
        Map.unionWith
            intersectTerm
            (Map.delete pivot cur)
            (Map.delete pivot sat)
    t1 = Map.findWithDefault anyTerm pivot cur
    t2 = Map.findWithDefault anyTerm pivot sat
    unioned = unionTerm t1 t2
    finalTerms
        | isTopTerm unioned = merged
        | otherwise = Map.insert pivot unioned merged
