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
--
-- == What the store assumes of its rule, and what it does not
--
-- The store is correct for any t'MergeRule' that keeps its one law: a merged
-- clause has the key its two halves had. It assumes nothing else about what
-- the rule does. A merge may change which variables a clause mentions, and the
-- index follows it, dropping a variable no clause mentions any more. 'valid'
-- states every invariant the store keeps.
module PubGrub.Store
    ( Store
    , ClauseId
    , emptyStore
    , emptyStoreWith
    , storeClauses
    , insertClause
    , insertClauses
    , clauseAt
    , clausesOf
    , allClauses
    , touch
    , takeDirty
    , valid
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
-- the merge rule with the clause each of its keys names, and the clauses
-- propagation has not judged since they changed.
data Store d = Store
    { stClauses :: !(IntMap (Incompatibility d))
    , stIndex   :: !(Map (VarOf d) IntSet)
    , stMerging :: !(MergeIndex d)
    , stDirty   :: !IntSet
    , stNext    :: !ClauseId
    }

-- | The rule's key for each clause that has one, mapped to that clause's id,
-- with the rule itself. The key type is the rule's own and existential, as in
-- t'MergeRule', and only here: the store only ever asks whether a key is
-- present.
data MergeIndex d = forall k. Ord k => MergeIndex
    { miTargets :: !(Map k ClauseId)
    , miKey     :: Incompatibility d -> Maybe k
    , miMerge   :: Incompatibility d -> Incompatibility d -> Incompatibility d
    }

-- | The empty store, under the domain's 'mergeRule'.
emptyStore :: Domain d => Store d
emptyStore = emptyStoreWith mergeRule

-- | The empty store, under the given rule.
emptyStoreWith :: MergeRule d -> Store d
emptyStoreWith MergeRule{mergeKey, mergeWith} =
    Store
        { stClauses = IntMap.empty
        , stIndex = Map.empty
        , stMerging = MergeIndex{miTargets = Map.empty, miKey = mergeKey, miMerge = mergeWith}
        , stDirty = IntSet.empty
        , stNext = 0
        }

-- | Where an arriving clause goes: 'Left' the id of the clause it merges into,
-- or 'Right' the index with the clause registered under its key at the given
-- id. A clause without a key leaves the index as it was.
place :: ClauseId -> Incompatibility d -> MergeIndex d -> Either ClauseId (MergeIndex d)
place c i mi@(MergeIndex targets key merge) = case key i of
    Nothing -> Right mi
    Just k -> (\targets' -> MergeIndex targets' key merge) <$> Map.alterF slot k targets
  where
    slot (Just target) = Left target
    slot Nothing       = Right (Just c)

-- | The rule's merge of the existing clause and the arriving one.
mergeOf :: MergeIndex d -> Incompatibility d -> Incompatibility d -> Incompatibility d
mergeOf MergeIndex{miMerge} = miMerge

-- | The clauses in scan order, newest first.
storeClauses :: Store d -> [Incompatibility d]
storeClauses Store{stClauses} = IntMap.foldl (flip (:)) [] stClauses

-- | Add a clause: merge it into the fact it agrees with, or put it at the front.
-- Either way the clause that results is dirty.
insertClause :: Domain d => Incompatibility d -> Store d -> Store d
insertClause i store@Store{stClauses, stIndex, stMerging, stDirty, stNext} =
    case place stNext i stMerging of
        Left target -> mergeInto target
        Right merging ->
            store
                { stClauses = IntMap.insert stNext i stClauses
                , stIndex = index stNext (incompTerms i) stIndex
                , stMerging = merging
                , stDirty = IntSet.insert stNext stDirty
                , stNext = stNext + 1
                }
  where
    -- Replace the clause at @target@ with the merge of it and @i@, in place: the
    -- id, and so the scan position, is the one the existing clause had. The
    -- index moves only the variables the merge added or dropped.
    --
    -- A key names a clause that is there — 'valid' holds it, and the tests hold
    -- 'valid' — so the 'Nothing' branch is unreachable. If it is ever reached,
    -- the arriving clause takes the id its key names, which makes the store
    -- valid again rather than leaving a key that names nothing.
    mergeInto target =
        let (merged, ix) = case IntMap.lookup target stClauses of
                Nothing -> (i, index target (incompTerms i) stIndex)
                Just existing ->
                    let m = mergeOf stMerging existing i
                     in (m, reindex target (incompTerms existing) (incompTerms m) stIndex)
         in store
                { stClauses = IntMap.insert target merged stClauses
                , stIndex = ix
                , stDirty = IntSet.insert target stDirty
                }

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

-- | Every invariant the store keeps, for the tests:
--
-- * the index is exactly the variables the clauses mention, each mapped to the
--   clauses that mention it, so no variable maps to no clause;
-- * the merge index is exactly the clauses that have a key, by key, so a key
--   names a clause that is there and no two clauses share a key;
-- * the dirty clauses are clauses, and every id is below the next one.
--
-- The second holds only under a rule that keeps its law (see t'MergeRule'): a
-- merge that changes the key leaves the old key naming the merged clause.
valid :: Domain d => Store d -> Bool
valid Store{stClauses, stIndex, stMerging = MergeIndex{miTargets, miKey}, stDirty, stNext} =
    stIndex == mentions
        && length keyed == Map.size miTargets
        && Map.fromList keyed == miTargets
        && stDirty `IntSet.isSubsetOf` ids
        && maybe True ((< stNext) . fst) (IntSet.maxView ids)
  where
    ids = IntMap.keysSet stClauses
    clauses = IntMap.toList stClauses
    mentions = Map.fromListWith IntSet.union [(v, IntSet.singleton c) | (c, i) <- clauses, v <- Map.keys (incompTerms i)]
    keyed = [(k, c) | (c, i) <- clauses, Just k <- [miKey i]]

-- | File a clause under each variable it mentions, and the inverse. 'unindex'
-- drops a variable that no clause mentions any more.
index, unindex :: Ord v => ClauseId -> Map v a -> Map v IntSet -> Map v IntSet
index c terms ix = Map.foldlWithKey' (\acc v _ -> Map.insertWith IntSet.union v (IntSet.singleton c) acc) ix terms
unindex c terms ix = Map.foldlWithKey' (\acc v _ -> Map.update without v acc) ix terms
  where
    without cs = let cs' = IntSet.delete c cs in if IntSet.null cs' then Nothing else Just cs'

-- | Move a clause's filing from its old terms to its new ones: only the
-- variables it stopped or started mentioning change.
reindex :: Ord v => ClauseId -> Map v a -> Map v a -> Map v IntSet -> Map v IntSet
reindex c old new = index c (Map.difference new old) . unindex c (Map.difference old new)
