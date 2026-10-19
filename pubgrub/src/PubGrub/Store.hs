-- | The incompatibility store: what the solver has learned, in the order
-- propagation scans it, with facts that say the same thing __merged as they
-- arrive__. Which facts those are is the domain's 'mergeRule'; for cabal,
-- dependency facts about the same pair of packages under the same guard, flag
-- declarations of the same flag, and unbuildable facts about the same package
-- for the same reasons ('PubGrub.Cabal').
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
-- It is rebuilt with its own constructor — 'PubGrub.Cabal.fromDependency',
-- 'PubGrub.Cabal.declaresFlag' or 'PubGrub.Cabal.unbuildable' — so its cause
-- stays a leaf cause with the unioned term. The alternative — letting conflict
-- resolution reach the same range by resolving the narrow facts against each
-- other — produces derived nodes, and those derived nodes /are/ the proof
-- lines this exists to remove. Merging at insert does not shorten those lines;
-- it stops them existing.
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

import           Data.List               (elemIndex)
import           Data.Set                (Set)
import qualified Data.Set                as Set
import           PubGrub.Incompatibility (Domain (..), Incompatibility,
                                          MergeRule (..))

-- | The clauses, newest first, plus an index of which of them a new fact could
-- merge with, and the rule that says so.
--
-- The clauses are held as plain values in scan order, so propagation walks them
-- with no lookup per clause. Locating a merge target is instead an
-- @O(position)@ rebuild of the list's prefix, paid only when a merge actually
-- happens, and the key set is what keeps that walk from happening when it
-- would find nothing — the common case by far, since most dependency facts are
-- the first of their kind.
--
-- Each clause's key is computed once, on insert, and kept in @stKeys@ in
-- lockstep with @stClauses@: the walk to a merge target compares keys and
-- never recomputes one, which would otherwise be a key construction per clause
-- walked past. A merge keeps the key — the rule rebuilds the clause through
-- the constructor the key was read from — so the key list is never rebuilt.
--
-- The key type is the rule's own and existential, as in t'MergeRule': the
-- store only ever asks whether a key is present.
data Store d = forall k. Ord k => Store
    { stClauses   :: [Incompatibility d]
    , stKeys      :: [Maybe k]
    , stMergeable :: !(Set k)
    , stKey       :: Incompatibility d -> Maybe k
    , stMerge     :: Incompatibility d -> Incompatibility d -> Incompatibility d
    }

-- | The empty store, under the domain's 'mergeRule'.
emptyStore :: Domain d => Store d
emptyStore = case mergeRule of
    MergeRule{mergeKey, mergeWith} ->
        Store{stClauses = [], stKeys = [], stMergeable = Set.empty, stKey = mergeKey, stMerge = mergeWith}

-- | The clauses in scan order, newest first.
storeClauses :: Store d -> [Incompatibility d]
storeClauses = stClauses

-- | Add a clause: merge it into the fact it agrees with, or prepend it.
insertClause :: Incompatibility d -> Store d -> Store d
insertClause i (Store clauses keys mergeable key merge) = case key i of
    Nothing -> Store (i : clauses) (Nothing : keys) mergeable key merge
    Just k
        | k `Set.member` mergeable -> case elemIndex (Just k) keys of
            Just n -> Store (mergeAt n merge i clauses) keys mergeable key merge
            -- Unreachable: a key in the set is the key of some clause. If it
            -- ever is reached, the clause is kept — at the back, which is a
            -- bad scan position and a correct store; losing a fact would be a
            -- wrong answer, and rescanning one extra clause is not.
            Nothing -> Store (clauses ++ [i]) (keys ++ [Just k]) mergeable key merge
        | otherwise -> Store (i : clauses) (Just k : keys) (Set.insert k mergeable) key merge

-- | Insert several clauses, preserving their order at the front: @insertClauses
-- [a,b,c]@ leaves the store scanning @a@, @b@, @c@, then what was there before,
-- except that a clause merged into an older one keeps that one's place.
insertClauses :: [Incompatibility d] -> Store d -> Store d
insertClauses is store = foldr insertClause store is

-- | Replace the clause at position @n@ with the merge of it and @new@, in
-- place. The tail beyond it is shared, so the cost is the position, and every
-- other clause keeps the position it had. A position past the end cannot come
-- from 'insertClause'; if it did, @new@ would be appended with no key beside
-- it, which is a bad scan position and a correct store.
mergeAt
    :: Int
    -> (Incompatibility d -> Incompatibility d -> Incompatibility d)
    -> Incompatibility d
    -> [Incompatibility d]
    -> [Incompatibility d]
mergeAt n merge new = go n
  where
    go _ [] = [new]
    go 0 (c : cs) = merge c new : cs
    go m (c : cs) = c : go (m - 1) cs
