-- | The incompatibility store: what the solver has learned, in the order
-- propagation scans it, with facts that say the same thing __merged as they
-- arrive__ — dependency facts about the same pair of packages, declarations of
-- the same flag, and unbuildable facts about the same package.
--
-- == Why this is not just a list
--
-- PubGrub states identical dependencies of /adjacent versions of the depender/
-- as one incompatibility — @{foo >=1.0 && <1.3, not bar >=1.0 && <2}@ rather
-- than one fact per version of @foo@. There are two places to do that, and
-- __both run__. When a fact is generated, the provider walks out from the
-- release it was asked about and reads its neighbours to learn whether they
-- carry the same dependency. That is affordable only because a read is a decode
-- of the derived index rather than a @.cabal@ parse.
--
-- This module is the other place. The provider emits one fact per
-- release __slot__ — the half-open range up to the next release in the index —
-- so adjacent slots /touch/, and this module unions the depender terms of two
-- facts that agree about the dependee. @unionVersionSet@ then coalesces the
-- touching ranges into one contiguous interval. No neighbour is read /here/,
-- because the only releases that merge are ones the solver expanded anyway.
--
-- The rule is weaker than PubGrub's: it collapses the releases the solver
-- expanded, not every release that carries the dependency. But those are the
-- only ones whose clauses exist, so for both things collapsing is for —
-- clauses to propagate, and lines in a proof — it is nearly as good.
--
-- == Why merging is sound
--
-- Two incompatibilities that state the same term about @q@:
--
-- @
-- ¬(p ∈ A ∧ q ∉ R)   and   ¬(p ∈ B ∧ q ∉ R)
-- @
--
-- together give @¬(p ∈ A∪B ∧ q ∉ R)@, since @p ∈ A∪B@ is @p ∈ A ∨ p ∈ B@ and the
-- conjunction distributes. Each half was established separately, so the union
-- claims nothing new — it is the /same/ knowledge in one clause instead of two,
-- which is exactly what makes it a stronger clause to propagate: a wider positive
-- term is satisfied by more of the partial solutions that can arise.
--
-- == The merged clause is a leaf, and that is the point for reports
--
-- It is rebuilt with its own constructor — 'fromDependency',
-- 'PubGrub.Incompatibility.declaresFlag' or 'PubGrub.Incompatibility.unbuildable'
-- — so its cause stays a leaf cause with the unioned term. The alternative — letting conflict resolution reach
-- the same range by resolving the narrow facts against each other — produces
-- 'CauseDerivedFrom' nodes, and those derived nodes /are/ the proof lines this
-- exists to remove. Merging at insert does not shorten those lines; it stops
-- them existing.
--
-- == Scan position is preserved, deliberately
--
-- Clause /position/ dominates propagation cost, and new knowledge goes at the
-- front. A merge therefore replaces the existing clause __where it already
-- sits__ rather than removing it and prepending the result, so learning that
-- two facts were one does not disturb the scan order the solver has converged on.
module PubGrub.Store
    ( Store
    , emptyStore
    , storeClauses
    , insertClause
    , insertClauses
    ) where

import qualified Data.List.NonEmpty             as NE
import           Data.Set                       (Set)
import qualified Data.Set                       as Set
import           Distribution.Types.PackageName (PackageName)
import           PubGrub.Incompatibility        (Guard, IncompatCause (..),
                                                 Incompatibility (..),
                                                 UnbuildableReason,
                                                 declaresFlag, fromDependency,
                                                 unbuildable)
import           PubGrub.InstanceSet            (InstanceSet)
import           PubGrub.SetOps                 (SetOps (..))
import           PubGrub.Variable               (Flag)

-- | The clauses, newest first, plus an index of which of them a new dependency
-- fact could merge with.
--
-- The clauses are held as plain values in scan order, so propagation walks them
-- with no lookup per clause. Locating a merge target is instead an
-- @O(position)@ rebuild of the list's prefix, paid only when a merge actually
-- happens, and @stMergeable@ is what keeps that walk from happening when it
-- would find nothing — the common case by far, since most dependency facts are
-- the first of their kind.
data Store = Store
    { stClauses   :: [Incompatibility]
    , stMergeable :: !(Set MergeKey)
    }

-- | What has to match for two clauses to be merged.
--
-- Three shapes qualify. A dependency fact ('MergeDep') matches on the depender
-- package, the dependee package, its guard, and the __dependee instance set__,
-- which must be identical rather than merely overlapping. A flag declaration
-- ('MergeDeclares') matches on the package and the flag. An unbuildable fact
-- ('MergeUnbuildable') matches on the package and the __reasons__: it is a unit
-- clause, so there is no second term to agree about, and two of them giving the
-- same reasons are the same fact about two runs of releases. PubGrub asks for
-- adjacent versions that cannot be selected to be stated as one incompatibility.
-- Two runs ruled out for different reasons are two facts, and merging them
-- would put one release's missing module on the other's range in the proof. The
-- reasons compare as a set, so their order in the @.cabal@ does not keep two
-- identical facts apart.
--
-- On the dependency side the dependee set is compared with 'Eq', which
-- 'InstanceSet' has lawfully: both of its halves are canonical.
--
-- The accumulated depender term of a merged clause is /not/ part of any key:
-- it is what the merge grows.
data MergeKey
    = MergeDep PackageName PackageName Guard InstanceSet
      -- ^ a dependency fact merges only with one under the /same/ guard: the
      -- union argument above holds term for term, and the guard's terms are
      -- identical on both sides
    | MergeDeclares PackageName Flag
      -- ^ two releases declaring the same flag: one clause over both
    | MergeUnbuildable PackageName (Set UnbuildableReason)
    deriving (Eq, Ord)

-- | The key of a clause that may take part in a merge: a dependency fact, a flag
-- declaration, or an unbuildable fact.
--
-- A clause is judged by its /cause/ rather than by its term map, because the term
-- map has already lost what is needed: 'fromDependency' drops the dependee entry
-- when the dependency is unsatisfiable, leaving a unit ban that says nothing about
-- which dependee it came from. The cause still names it, so those clauses merge
-- with each other rather than being excluded.
mergeKey :: Incompatibility -> Maybe MergeKey
mergeKey i = case incompCause i of
    CauseDependency p _ g (q, depSet) -> Just (MergeDep p q g depSet)
    CauseDeclaresFlag p _ f           -> Just (MergeDeclares p f)
    CauseUnbuildable p _ why          -> Just (MergeUnbuildable p (Set.fromList (NE.toList why)))
    _                                 -> Nothing

emptyStore :: Store
emptyStore = Store{stClauses = [], stMergeable = Set.empty}

-- | The clauses in scan order, newest first.
storeClauses :: Store -> [Incompatibility]
storeClauses = stClauses

-- | Add a clause: merge it into the dependency fact it agrees with, or prepend
-- it.
insertClause :: Incompatibility -> Store -> Store
insertClause i store = case mergeKey i of
    Nothing -> prepend
    Just k
        | k `Set.member` stMergeable store ->
            store{stClauses = mergeInto k i (stClauses store)}
        | otherwise -> prepend{stMergeable = Set.insert k (stMergeable store)}
  where
    prepend = store{stClauses = i : stClauses store}

-- | Insert several clauses, preserving their order at the front: @insertClauses
-- [a,b,c]@ leaves the store scanning @a@, @b@, @c@, then what was there before,
-- except that a clause merged into an older one keeps that one's place.
insertClauses :: [Incompatibility] -> Store -> Store
insertClauses is store = foldr insertClause store is

-- | Replace the first clause carrying @k@ with the union of it and @new@, in
-- place. The tail beyond the match is shared, so the cost is the position of the
-- match, and every other clause keeps the position it had.
--
-- @k@ is known to be present, so running off the end cannot happen from
-- 'insertClause'. If it ever did, the clause is kept — at the back, which is a bad
-- scan position and a correct store; losing a fact would be a wrong answer, and
-- rescanning one extra clause is not.
mergeInto :: MergeKey -> Incompatibility -> [Incompatibility] -> [Incompatibility]
mergeInto k new = go
  where
    go [] = [new]
    go (c : cs)
        | mergeKey c == Just k = merged c : cs
        | otherwise = c : go cs

    merged c = case (incompCause c, incompCause new) of
        (CauseDependency p aSet g (q, depSet), CauseDependency _ bSet _ _) ->
            fromDependency p (aSet `union` bSet) g q depSet
        (CauseDeclaresFlag p aSet f, CauseDeclaresFlag _ bSet _) ->
            declaresFlag p (aSet `union` bSet) f
        -- Two unit clauses banning instances of the same package: ¬(p ∈ A) and
        -- ¬(p ∈ B) is ¬(p ∈ A∪B), so the union claims nothing new. Slots touch, so
        -- for runs of adjacent unbuildable releases the union is one contiguous
        -- range — which is what @references\/pubgrub.md:476@ asks to be stated.
        -- The key made the two reason sets equal, so the existing clause's
        -- reasons are the merged clause's.
        (CauseUnbuildable p aSet why, CauseUnbuildable _ bSet _) ->
            unbuildable p (aSet `union` bSet) why
        -- Unreachable: the two clauses answered 'mergeKey' with the same @Just k@,
        -- and each key shape pins the cause. Were it reached, the newer fact would
        -- be lost, not kept as 'mergeInto' promises for a missing match.
        _ -> c
