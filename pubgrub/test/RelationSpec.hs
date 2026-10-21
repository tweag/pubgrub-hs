-- | 'PubGrub.Relation.relation', on small sets: how a term the partial
-- solution holds stands to a term of an incompatibility.
module RelationSpec (tests) where

import qualified Data.Set         as Set
import           PubGrub.Relation (Relation (..), relation)
import           PubGrub.Term     (Term (..))
import           Test.Tasty       (TestTree, testGroup)
import           Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "relation"
        [ testCase "a subject inside the reference satisfies it" $
            relation (Positive (Set.fromList [3 :: Int])) (Positive (Set.fromList [1 .. 9])) @?= Satisfied
        , testCase "a subject outside the reference contradicts it" $
            relation (Positive (Set.fromList [3 :: Int])) (Positive (Set.fromList [5 .. 9])) @?= Contradicted
        , testCase "a subject wider than the reference leaves it open" $
            relation (Positive (Set.fromList [1 .. 9 :: Int])) (Positive (Set.fromList [3])) @?= Inconclusive
        , testCase "an exact subject that avoids a negative reference satisfies it" $
            relation (Positive (Set.fromList [3 :: Int])) (Negative (Set.fromList [5 .. 9])) @?= Satisfied
        , testCase "an exact subject that lands in a negative reference contradicts it" $
            relation (Positive (Set.fromList [6 :: Int])) (Negative (Set.fromList [5 .. 9])) @?= Contradicted
        , testCase "a negative subject never satisfies a positive reference" $
            relation (Negative (Set.fromList [5, 6 :: Int])) (Positive (Set.fromList [1 .. 4])) @?= Inconclusive
        ]
