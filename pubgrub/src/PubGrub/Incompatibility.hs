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
      -- * Building one
    , incompatibility
    , seed
    , fact
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
import           Data.Void       (Void, absurd)
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

    -- | Which incompatibilities can be stated as one, and the one that states
    -- them. The solver applies it as incompatibilities arrive. The default
    -- merges nothing.
    mergeRule :: MergeRule v
    mergeRule = noMerging

-- | A merge rule: it splits an incompatibility into a key and a part. Two with
-- the same key are one piece of knowledge in two parts, the parts combine with
-- @<>@, and 'mergeBuild' makes the one incompatibility that states the result.
-- The solver keeps at most one incompatibility per key: one that arrives with a
-- key already taken is merged into the one that has it, which keeps its place in
-- the order the solver judges them in. The two types are the rule's own.
--
-- Merging pays where a provider states a dependency once per release. If two
-- releases of @p@ both need @q@ in @r@, the solver is given one incompatibility
-- for each. Merged, they can propagate where neither part can: knowing only that
-- @p@ is one of the two releases, without knowing which, is enough to conclude
-- that @q@ is in @r@. A proof then states the dependency once.
--
-- __The law.__ The merged incompatibility replaces both, so it must say exactly
-- what the two say together: whenever @mergeParts a == Just (k, x)@ and
-- @mergeParts b == Just (k, y)@, @mergeBuild k (x <> y)@ forbids exactly what @a@
-- and @b@ forbid between them. 'Semigroup' cannot check this. Merging
-- @{p: Positive a, q: Negative r}@ with @{p: Positive b, q: Negative r}@ into
-- @{p: Positive (a ∪ b), q: Negative r}@ keeps it, because "@p@ in @a ∪ b@" is
-- "@p@ in @a@ or @p@ in @b@", so the key is @(p, q, r)@ and the part is the set
-- under union. Nothing else is required: a merge may change which variables the
-- incompatibility mentions.
data MergeRule v = forall k s. (Ord k, Semigroup s) => MergeRule
    { mergeParts :: Incompatibility v -> Maybe (k, s)
      -- ^ the key and the part of an incompatibility that may be merged, or
      -- 'Nothing' for one that is never merged
    , mergeBuild :: k -> s -> Incompatibility v
      -- ^ the incompatibility that states a key and a part: the key the first
      -- of them arrived with, and the @<>@ of their parts in the order they
      -- arrived
    }

-- | No two clauses merge, so a fact the provider states again, when the solver
-- decides a variable a second time, is a second clause. "PubGrub.Cookbook" has a
-- rule that stops that.
noMerging :: MergeRule v
noMerging = MergeRule{mergeParts = const (Nothing :: Maybe (Void, ())), mergeBuild = \k _ -> absurd k}

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
--
-- Build one with 'seed', 'fact' or 'incompatibility', which keep that shape;
-- the constructor is for taking one apart.
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

-- | An incompatibility from its cause and terms, in the shape the solver
-- expects: a variable named twice gets the intersection of its terms, and a
-- term that is always true is left out.
incompatibility :: Domain v => Cause v -> [(v, Term (SetOf v))] -> Incompatibility v
incompatibility cause terms =
    Incompatibility (Map.filter (not . isTopTerm) (Map.fromListWith intersectTerm terms)) cause

-- | A seed: one term about one variable, with what the request said as its
-- fact. @'Negative' s@ asks for the variable to have a value in @s@, and
-- @'Positive' f@ forbids it the values in @f@. 'PubGrub.Solver.solve' takes a
-- list of these, and a seed built here is always one it accepts.
seed :: FactOf v -> v -> Term (SetOf v) -> Incompatibility v
seed f v t = Incompatibility (Map.singleton v t) (Seed f)

-- | A fact the provider states, from what it says and its terms, in the shape
-- 'incompatibility' keeps.
fact :: Domain v => FactOf v -> [(v, Term (SetOf v))] -> Incompatibility v
fact f = incompatibility (Fact f)

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
