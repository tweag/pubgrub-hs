-- | The incompatibility store: what the solver has learned, in the order
-- propagation scans it, with facts that say the same thing __merged as they
-- arrive__ — dependency facts about the same pair of packages, and unbuildable
-- facts about the same package.
--
-- == Why this is not just a list
--
-- PubGrub states identical dependencies of /adjacent versions of the depender/
-- as one incompatibility — @{foo >=1.0 && <1.3, not bar >=1.0 && <2}@ rather
-- than one fact per version of @foo@. Doing that when a fact is generated means
-- walking out from the release asked about and parsing its neighbours' @.cabal@
-- files to learn whether they carry the same dependency: reads, and residency,
-- spent on releases the search may never contest.
--
-- This module does it on insert instead. The provider emits one fact per
-- release __slot__ — the half-open range up to the next release in the index —
-- so adjacent slots /touch/, and this module unions the depender terms of two
-- facts that agree about the dependee. @unionVersionSet@ then coalesces the
-- touching ranges into one contiguous interval. No neighbour is read, because
-- the only releases that merge are ones the solver expanded anyway.
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
-- It is rebuilt with its own constructor — 'fromDependency', or
-- 'PubGrub.Incompatibility.unbuildable' — so its cause stays a leaf cause with the
-- unioned term. The alternative — letting conflict resolution reach
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

import           Data.Set                       (Set)
import qualified Data.Set                       as Set
import           Distribution.Types.PackageName (PackageName)
import           PubGrub.Incompatibility        (IncompatCause (..),
                                                 Incompatibility (..),
                                                 fromDependency, unbuildable)
import           PubGrub.Index.PreInstalled     (PreInstalledPackage)
import           PubGrub.InstanceSet            (InstanceSet (..))
import           PubGrub.InstanceSet.SourceCell (SourceCell)
import           PubGrub.SetOps                 (SetOps (..))

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
-- Two shapes qualify. A dependency fact ('MergeDep') matches on the depender
-- package, the dependee package, and the __dependee instance set__, which must be
-- identical rather than merely overlapping. An unbuildable fact
-- ('MergeUnbuildable') matches on the package alone: it is a unit clause, so
-- there is no second term to agree about, and two of them are the same fact about
-- two runs of releases. PubGrub asks for adjacent versions that cannot be
-- selected to be stated as one incompatibility.
--
-- On the dependency side, the set is compared /structurally/, via 'setKey'.
-- 'InstanceSet' deliberately has no 'Eq' — its source side is a non-canonical DNF, so structural equality is
-- not semantic equality and a lawful instance is impossible. That general problem
-- does not arise here, because the sets being compared are not general: a
-- dependee set is minted by the provider from a declared range and never
-- rewritten, so it is always one cell with an empty pin map over a canonical
-- 'VersionSet' alongside an extensional installed set. For sets of that shape
-- structural equality /is/ semantic equality. Sets that have been through the
-- algebra are non-canonical, and they only appear in 'CauseDerivedFrom'
-- clauses, which are not merge candidates.
--
-- The accumulated term of a merged clause is /not/ compared against anything: it
-- has been through 'union' and is therefore non-canonical, and neither key looks
-- at it.
data MergeKey
    = MergeDep PackageName PackageName SetKey
    | MergeUnbuildable PackageName
    deriving (Eq, Ord)

-- | A structural key for an 'InstanceSet'. Cells are sorted so that two DNFs
-- differing only in cell order compare equal; nothing else is normalised, and
-- nothing needs to be (see 'MergeKey').
type SetKey = (Set PreInstalledPackage, [SourceCell])

setKey :: InstanceSet -> SetKey
setKey s = (isInstalled s, Set.toAscList (Set.fromList (isSource s)))

-- | The key of a clause that may take part in a merge: a dependency fact or an
-- unbuildable one.
--
-- A clause is judged by its /cause/ rather than by its term map, because the term
-- map has already lost what is needed: 'fromDependency' drops the dependee entry
-- when the dependency is unsatisfiable, leaving a unit ban that says nothing about
-- which dependee it came from. The cause still names it, so those clauses merge
-- with each other rather than being excluded.
mergeKey :: Incompatibility -> Maybe MergeKey
mergeKey i = case incompCause i of
    CauseDependency p _ (q, depSet) -> Just (MergeDep p q (setKey depSet))
    CauseUnbuildable p _            -> Just (MergeUnbuildable p)
    _                               -> Nothing

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
        (CauseDependency p aSet (q, depSet), CauseDependency _ bSet _) ->
            fromDependency p (aSet `union` bSet) q depSet
        -- Two unit clauses banning instances of the same package: ¬(p ∈ A) and
        -- ¬(p ∈ B) is ¬(p ∈ A∪B), so the union claims nothing new. Slots touch, so
        -- for runs of adjacent unbuildable releases the union is one contiguous
        -- range — which is what @references\/pubgrub.md:476@ asks to be stated.
        (CauseUnbuildable p aSet, CauseUnbuildable _ bSet) ->
            unbuildable p (aSet `union` bSet)
        -- Unreachable: the two clauses answered 'mergeKey' with the same @Just k@,
        -- and each key shape pins the cause. Were it reached, the newer fact would
        -- be lost, not kept as 'mergeInto' promises for a missing match.
        _ -> c
