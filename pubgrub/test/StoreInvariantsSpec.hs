{-# LANGUAGE TypeFamilies #-}

-- | 'PubGrub.Store' as a data structure: its invariants ('valid') under any
-- merge rule that keeps 'MergeRule''s law, not only under cabal's.
--
-- Cabal's rule widens a depender term and never changes which variables a
-- clause mentions. The rules here do what it does not: one replaces a clause by
-- whatever arrived, so a merge can drop variables and add others, and one
-- unions the two clauses' terms, so a merge can only add them. A rule that
-- breaks the law is here too, to show that 'valid' catches it.
module StoreInvariantsSpec (tests) where

import qualified Data.IntSet             as IntSet
import           Data.List               (nub)
import qualified Data.Map.Strict         as Map
import           Data.Maybe              (fromMaybe)
import           Data.Set                (Set)
import qualified Data.Set                as Set
import           PubGrub.Incompatibility (Cause (..), Domain (..),
                                          Incompatibility (..), MergeRule (..),
                                          noMerging)
import           PubGrub.Store           (Store, allClauses, clausesOf,
                                          emptyStoreWith, insertClause,
                                          insertClauses, storeClauses, valid)
import           PubGrub.Term            (Term (..))
import           Test.Tasty              (TestTree, testGroup)
import           Test.Tasty.HUnit        (testCase, (@?=))
import           Test.Tasty.QuickCheck   (Arbitrary (..), Property, choose,
                                          frequency, listOf, sublistOf,
                                          testProperty, vectorOf, (===))

-- --------------------------------------------------------------------------
-- The domain
-- --------------------------------------------------------------------------

newtype V = V Int
    deriving (Eq, Ord, Show)

-- | The domain: variables are small numbers, and a fact is a tag the rules
-- key on.

instance Domain V where

    type ValueOf V = Int
    type SetOf V = Set Int
    type FactOf V = Int
    singleton _ = Set.singleton

-- | A clause, as data a counterexample can print: its tag, whether it carries
-- a key ('Fact') or not ('Seed'), and its terms.
data Spec = Spec
    { spTag   :: Int
    , spKeyed :: Bool
    , spTerms :: [(Int, Bool, [Int])]
    }
    deriving (Show)

clause :: Spec -> Incompatibility V
clause Spec{spTag, spKeyed, spTerms} =
    Incompatibility
        (Map.fromList [(V v, (if pos then Positive else Negative) (Set.fromList vs)) | (v, pos, vs) <- spTerms])
        ((if spKeyed then Fact else Seed) spTag)

instance Arbitrary Spec where
    arbitrary = do
        tag <- choose (0, 4)
        keyed <- frequency [(4, pure True), (1, pure False)]
        n <- choose (0, 3)
        terms <- vectorOf n ((,,) <$> choose (0, 5) <*> arbitrary <*> sublistOf [0 .. 3])
        pure (Spec tag keyed terms)

-- | What a test does to a store.
data Op
    = Insert Spec
    | InsertMany [Spec]
    deriving (Show)

instance Arbitrary Op where
    arbitrary = frequency [(3, Insert <$> arbitrary), (1, InsertMany <$> listOf arbitrary)]

apply :: Store V -> Op -> Store V
apply store op = case op of
    Insert s      -> snd (insertClause (clause s) store)
    InsertMany ss -> snd (insertClauses (map clause ss) store)

-- --------------------------------------------------------------------------
-- The rules
-- --------------------------------------------------------------------------

keyOf :: Incompatibility V -> Maybe Int
keyOf i = case incompCause i of
    Fact t -> Just t
    _      -> Nothing

-- | The arriving clause replaces the existing one: a merge may drop any
-- variable and add any other.
replacing :: MergeRule V
replacing = MergeRule{mergeKey = keyOf, mergeWith = \_ new -> new}

-- | The merged clause mentions every variable either half did.
widening :: MergeRule V
widening =
    MergeRule
        { mergeKey = keyOf
        , mergeWith = \old new -> Incompatibility (Map.union (incompTerms old) (incompTerms new)) (incompCause old)
        }

-- | Breaks the law: the merged clause has another key.
rekeying :: MergeRule V
rekeying = MergeRule{mergeKey = keyOf, mergeWith = \_ new -> new{incompCause = Fact (100 + fromMaybe 0 (keyOf new))}}

-- | Every store along the way is valid.
validThroughout :: MergeRule V -> [Op] -> Bool
validThroughout rule ops = all valid (scanl apply (emptyStoreWith rule) ops)

-- | An insert answers with the id of a clause that is in the store afterwards:
-- the one it merged into, or a new one exactly when nothing had its key.
landsWhereItSays :: MergeRule V -> [Spec] -> Spec -> Bool
landsWhereItSays rule before s =
    IntSet.member c (allClauses after) && isNew == not merges
  where
    store = foldl (\st x -> snd (insertClause (clause x) st)) (emptyStoreWith rule) before
    (c, after) = insertClause (clause s) store
    isNew = not (IntSet.member c (allClauses store))
    merges = spKeyed s && any ((== Just (spTag s)) . keyOf) (storeClauses store)

-- | Under a rule that merges by key, a store holds one clause per key and one
-- per clause without a key.
oneClausePerKey :: MergeRule V -> [Spec] -> Property
oneClausePerKey rule specs =
    length (storeClauses (foldl (\st x -> snd (insertClause x st)) (emptyStoreWith rule) (map clause specs)))
        === length (nub [spTag s | s <- specs, spKeyed s]) + length (filter (not . spKeyed) specs)

-- --------------------------------------------------------------------------
-- Tests
-- --------------------------------------------------------------------------

tests :: TestTree
tests =
    testGroup
        "the store under any lawful merge rule"
        [ testProperty "valid throughout, merging nothing" (validThroughout noMerging)
        , testProperty "valid throughout, a merge replacing the clause" (validThroughout replacing)
        , testProperty "valid throughout, a merge widening the clause" (validThroughout widening)
        , testProperty "an insert answers where the clause landed, replacing" (landsWhereItSays replacing)
        , testProperty "an insert answers where the clause landed, widening" (landsWhereItSays widening)
        , testProperty "one clause per key, replacing" (oneClausePerKey replacing)
        , testProperty "one clause per key, widening" (oneClausePerKey widening)
        , testCase "a variable the merged clause stops mentioning leaves the index" $ do
            let store =
                    snd . insertClause (clause (Spec 0 True [(2, True, [1])])) . snd $
                        insertClause (clause (Spec 0 True [(1, True, [1])])) (emptyStoreWith replacing)
            clausesOf (V 1) store @?= IntSet.empty
            clausesOf (V 2) store @?= IntSet.singleton 0
            valid store @?= True
        , testCase "a rule that changes the key is caught" $ do
            let store =
                    snd . insertClause (clause (Spec 0 True [(1, True, [1])])) . snd $
                        insertClause (clause (Spec 0 True [(1, True, [2])])) (emptyStoreWith rekeying)
            valid store @?= False
        , testCase "a clause compares and shows structurally, cause included" $ do
            let a = clause (Spec 0 True [(1, True, [1]), (2, False, [2])])
                b = clause (Spec 1 True [(1, True, [1]), (2, False, [2])])
            a @?= a
            (a == b) @?= False
            show a @?= "Incompatibility {incompTerms = fromList [(V 1,Positive (fromList [1])),(V 2,Negative (fromList [2]))], incompCause = Fact 0}"
        ]
