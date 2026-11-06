-- | The incompatibility store: what the solver has learned, in the order
-- propagation scans it, with facts that can be stated as one __merged as they
-- arrive__. Which facts those are is the domain's 'mergeRule'; for cabal,
-- dependency facts about the same pair of packages under the same guard, flag
-- declarations of the same flag, and unbuildable facts about the same package
-- for the same reasons ('PubGrub.Cabal').
--
-- == Why this is not just a list
--
-- PubGrub states identical dependencies of /adjacent versions of the depender/
-- as one incompatibility — @{foo >=1.0 && <1.3, not bar >=1.0 && <2}@ rather
-- than one fact per version of @foo@. There are two places to do that. When a
-- fact is generated, a provider can walk out from the release it was asked
-- about and read its neighbours to learn whether they carry the same
-- dependency; that costs a read per neighbour.
--
-- This module is the other place. The provider emits one fact per
-- release __slot__ — the half-open range up to the next release in the index —
-- so adjacent slots /touch/, and this module unions the depender terms of two
-- facts that agree about the dependee. @unionVersionSet@ then coalesces the
-- touching ranges into one contiguous interval. No neighbour is read /here/,
-- because the only releases that merge are ones the solver expanded anyway.
--
-- The rule is weaker than reading the neighbours: it collapses the releases
-- the solver expanded, not every release that carries the dependency. But
-- those are the only ones whose clauses exist, so for both things collapsing
-- is for — clauses to propagate, and lines in a proof — it is nearly as good.
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
-- lines this exists to remove: a proof that merges facts pairwise runs to
-- hundreds of lines. Merging at insert does not shorten those lines; it stops
-- them existing.
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
-- merged clause can. The store keeps the index that turns that into a worklist,
-- which clauses mention each variable ('clausesOf'), and an insert answers with
-- the id the clause landed at, new or merged into. Which clauses are still to
-- be judged is propagation's business, not the store's ("PubGrub.Solver").
--
-- == What the store assumes of its rule, and what it does not
--
-- The store's invariants hold for any t'MergeRule'. It holds each key with its
-- part and never takes a merged clause apart again, so it assumes nothing about
-- what the rule builds; the rule's law is what makes a merge sound, and the store
-- does not depend on it. A merge may change which variables a clause mentions,
-- and the index follows it, dropping a variable no clause mentions any more.
-- 'valid' states every invariant the store keeps.
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
    , storeSize
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

-- Specialised in the client, with the solver ("PubGrub.Solver" says why).
{-# INLINABLE emptyStore #-}
{-# INLINABLE insertClause #-}
{-# INLINABLE insertClauses #-}
{-# INLINABLE clausesOf #-}
{-# INLINABLE index #-}
{-# INLINABLE unindex #-}
{-# INLINABLE reindex #-}

-- | A clause's place in the scan order: higher is newer. A merge keeps the id of
-- the clause it merged into.
type ClauseId = Int

-- | The clauses by id, the index from a variable to the clauses that mention it,
-- and the merge rule with the clause each of its keys names.
data Store v = Store
    { stClauses :: !(IntMap (Incompatibility v))
    , stIndex   :: !(Map (v) IntSet)
    , stMerging :: !(MergeIndex v)
    , stNext    :: !ClauseId
    }

-- | The clause a key names, the key it first arrived with, and the part it has
-- grown to. Keys that compare equal may still differ, in how a range is spelled
-- for one, and a merged clause says what the first one said.
data Target k s = Target !ClauseId !k !s

-- | The rule's key for each clause that has one, mapped to that clause's id and
-- part, with the rule itself. The two types are the rule's own and existential,
-- as in t'MergeRule', and only here.
data MergeIndex v = forall k s. (Ord k, Semigroup s) => MergeIndex
    { miTargets :: !(Map k (Target k s))
    , miParts   :: Incompatibility v -> Maybe (k, s)
    , miBuild   :: k -> s -> Incompatibility v
    }

-- | The empty store, under the domain's 'mergeRule'.
emptyStore :: Domain v => Store v
emptyStore = emptyStoreWith mergeRule

-- | The empty store, under the given rule.
emptyStoreWith :: MergeRule v -> Store v
emptyStoreWith MergeRule{mergeParts, mergeBuild} =
    Store
        { stClauses = IntMap.empty
        , stIndex = Map.empty
        , stMerging = MergeIndex{miTargets = Map.empty, miParts = mergeParts, miBuild = mergeBuild}
        , stNext = 0
        }

-- | Where an arriving clause goes: the id it lands at, the clause that is there
-- afterwards, and the index with the clause's part added. A clause whose key is
-- free lands at the given id as it arrived; one whose key is taken lands at that
-- clause's id, as what the rule builds; one without a key leaves the index as it
-- was.
place :: ClauseId -> Incompatibility v -> MergeIndex v -> (ClauseId, Incompatibility v, MergeIndex v)
place c i mi@(MergeIndex targets parts build) = case parts i of
    Nothing -> (c, i, mi)
    Just (k, s) ->
        let slot Nothing = ((c, i), Just (Target c k s))
            slot (Just (Target t first old)) =
                let merged = old <> s
                 in ((t, build first merged), Just (Target t first merged))
            ((landed, clause), targets') = Map.alterF slot k targets
         in (landed, clause, MergeIndex targets' parts build)

-- | The clauses in scan order, newest first.
storeClauses :: Store v -> [Incompatibility v]
storeClauses Store{stClauses} = IntMap.foldl (flip (:)) [] stClauses

-- | Add a clause: merge it into the fact it agrees with, or put it at the front.
-- Either way, the id of the clause that results: the one merged into, or a new
-- one.
insertClause :: Domain v => Incompatibility v -> Store v -> (ClauseId, Store v)
insertClause i Store{stClauses, stIndex, stMerging, stNext} =
    case place stNext i stMerging of
        -- A merge lands on a clause that is there, in place: the id, and so the
        -- scan position, is the one it had, and the index moves only the
        -- variables the merge added or dropped.
        (c, landed, merging) ->
            ( c
            , Store
                { stClauses = IntMap.insert c landed stClauses
                , stIndex = case IntMap.lookup c stClauses of
                    Nothing       -> index c (incompTerms landed) stIndex
                    Just existing -> reindex c (incompTerms existing) (incompTerms landed) stIndex
                , stMerging = merging
                , stNext = if c == stNext then stNext + 1 else stNext
                }
            )

-- | Insert several clauses, preserving their order at the front: @insertClauses
-- [a,b,c]@ leaves the store scanning @a@, @b@, @c@, then what was there before,
-- except that a clause merged into an older one keeps that one's place. Answers
-- with the ids they landed at.
insertClauses :: Domain v => [Incompatibility v] -> Store v -> (IntSet, Store v)
insertClauses is store = foldr step (IntSet.empty, store) is
  where
    step i (!ids, !s) = case insertClause i s of
        (c, s') -> (IntSet.insert c ids, s')

-- | The clause with this id, if there is one.
clauseAt :: Store v -> ClauseId -> Maybe (Incompatibility v)
clauseAt Store{stClauses} c = IntMap.lookup c stClauses

-- | The clauses that mention a variable.
clausesOf :: Domain v => v -> Store v -> IntSet
clausesOf v Store{stIndex} = Map.findWithDefault IntSet.empty v stIndex

-- | Every clause.
allClauses :: Store v -> IntSet
allClauses Store{stClauses} = IntMap.keysSet stClauses

-- | How many clauses there are. A pass over them, allocating nothing.
storeSize :: Store v -> Int
storeSize Store{stClauses} = IntMap.size stClauses

-- | Every invariant the store keeps, for the tests:
--
-- * the index is exactly the variables the clauses mention, each mapped to the
--   clauses that mention it, so no variable maps to no clause;
-- * every key names a clause that is there, and no two keys name the same one;
-- * every id is below the next one.
valid :: Domain v => Store v -> Bool
valid Store{stClauses, stIndex, stMerging = MergeIndex{miTargets}, stNext} =
    stIndex == mentions
        && all (`IntMap.member` stClauses) targets
        && IntSet.size (IntSet.fromList targets) == length targets
        && maybe True ((< stNext) . fst) (IntMap.lookupMax stClauses)
  where
    clauses = IntMap.toList stClauses
    mentions = Map.fromListWith IntSet.union [(v, IntSet.singleton c) | (c, i) <- clauses, v <- Map.keys (incompTerms i)]
    targets = [t | Target t _ _ <- Map.elems miTargets]

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
