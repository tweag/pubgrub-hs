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
-- The scan order decides /which/ clause propagation acts on when more than one
-- could fire, and through it which derivation is recorded first, which satisfier
-- a conflict finds, and so the shape of a proof. New knowledge goes to the front,
-- and a merge replaces the existing clause __where it already sits__ rather than
-- removing it and adding the result at the front, so learning that two facts were
-- one does not reorder anything the search has already settled on.
--
-- == What propagation reads
--
-- A clause's relation to the partial solution depends only on the accumulated
-- terms of the variables it mentions. So after an assignment to @v@ only the
-- clauses that mention @v@ can change their relation, and after a merge only the
-- merged clause can. The store keeps the index that turns that into a worklist:
-- which clauses mention each variable ('clausesOf'), and which clauses have been
-- inserted, merged or 'touch'ed since propagation last looked ('takeDirty').
module PubGrub.Store
    ( Store
    , ClauseId
    , emptyStore
    , storeClauses
    , insertClause
    , insertClauses
    , clauseAt
    , clausesOf
    , allClauses
    , touch
    , takeDirty
    ) where

import           Data.IntMap.Strict      (IntMap)
import qualified Data.IntMap.Strict      as IntMap
import           Data.IntSet             (IntSet)
import qualified Data.IntSet             as IntSet
import           Data.Map.Strict         (Map)
import qualified Data.Map.Strict         as Map
import           PubGrub.Incompatibility (Domain (..), Incompatibility (..),
                                          MergeRule (..))

-- | A clause's place in the scan order: higher is newer. A merge keeps the id of
-- the clause it merged into.
type ClauseId = Int

-- | The clauses by id, the index from a variable to the clauses that mention it,
-- the id of the clause each merge key names, and the clauses propagation has
-- not judged since they changed.
--
-- The key type is the rule's own and existential, as in t'MergeRule': the
-- store only ever asks whether a key is present.
data Store d = forall k. Ord k => Store
    { stClauses   :: !(IntMap (Incompatibility d))
    , stIndex     :: !(Map (VarOf d) IntSet)
    , stMergeable :: !(Map k ClauseId)
    , stDirty     :: !IntSet
    , stNext      :: !ClauseId
    , stKey       :: Incompatibility d -> Maybe k
    , stMerge     :: Incompatibility d -> Incompatibility d -> Incompatibility d
    }

-- | The empty store, under the domain's 'mergeRule'.
emptyStore :: Domain d => Store d
emptyStore = case mergeRule of
    MergeRule{mergeKey, mergeWith} ->
        Store
            { stClauses = IntMap.empty
            , stIndex = Map.empty
            , stMergeable = Map.empty
            , stDirty = IntSet.empty
            , stNext = 0
            , stKey = mergeKey
            , stMerge = mergeWith
            }

-- | The clauses in scan order, newest first.
storeClauses :: Store d -> [Incompatibility d]
storeClauses Store{stClauses} = IntMap.foldl (flip (:)) [] stClauses

-- | Add a clause: merge it into the fact it agrees with, or put it at the front.
-- Either way the clause that results is dirty.
insertClause :: Domain d => Incompatibility d -> Store d -> Store d
insertClause i (Store clauses ix mergeable dirty next key merge) =
    case key i of
        Just k | Just target <- Map.lookup k mergeable -> mergeInto target
        k ->
            Store
                (IntMap.insert next i clauses)
                (index next (incompTerms i) ix)
                (maybe mergeable (\k' -> Map.insert k' next mergeable) k)
                (IntSet.insert next dirty)
                (next + 1)
                key
                merge
  where
    -- Replace the clause at @target@ with the merge of it and @i@, in place: the
    -- id, and so the scan position, is the one the existing clause had. The
    -- index follows the merged clause's variables, which for every rule so far
    -- are the existing clause's own; a rule that changed them would still be
    -- indexed right. A key always names a clause that is there; if it ever did
    -- not, the arriving clause takes the place, which loses nothing.
    mergeInto target =
        let (merged, ix') = case IntMap.lookup target clauses of
                Nothing -> (i, index target (incompTerms i) ix)
                Just existing ->
                    let m = merge existing i
                     in (m, index target (incompTerms m) (unindex target (incompTerms existing) ix))
         in Store (IntMap.insert target merged clauses) ix' mergeable (IntSet.insert target dirty) next key merge

-- | Insert several clauses, preserving their order at the front: @insertClauses
-- [a,b,c]@ leaves the store scanning @a@, @b@, @c@, then what was there before,
-- except that a clause merged into an older one keeps that one's place.
insertClauses :: Domain d => [Incompatibility d] -> Store d -> Store d
insertClauses is store = foldr insertClause store is

-- | The clause with this id, if there is one.
clauseAt :: Store d -> ClauseId -> Maybe (Incompatibility d)
clauseAt Store{stClauses} c = IntMap.lookup c stClauses

-- | The clauses that mention a variable.
clausesOf :: Domain d => VarOf d -> Store d -> IntSet
clausesOf v Store{stIndex} = Map.findWithDefault IntSet.empty v stIndex

-- | Every clause.
allClauses :: Store d -> IntSet
allClauses Store{stClauses} = IntMap.keysSet stClauses

-- | The variable's accumulated term changed: every clause that mentions it is
-- dirty. What the solver calls after a decision; a derivation during
-- propagation is handled there.
touch :: Domain d => VarOf d -> Store d -> Store d
touch v store@Store{stDirty} = store{stDirty = IntSet.union (clausesOf v store) stDirty}

-- | The clauses inserted, merged or touched since the last call, and the store
-- with none outstanding.
takeDirty :: Store d -> (IntSet, Store d)
takeDirty store@Store{stDirty} = (stDirty, store{stDirty = IntSet.empty})

-- | File a clause under each variable it mentions, and the inverse.
index, unindex :: Ord v => ClauseId -> Map v a -> Map v IntSet -> Map v IntSet
index c terms ix = Map.foldlWithKey' (\acc v _ -> Map.insertWith IntSet.union v (IntSet.singleton c) acc) ix terms
unindex c terms ix = Map.foldlWithKey' (\acc v _ -> Map.adjust (IntSet.delete c) v acc) ix terms
