{-# LANGUAGE ScopedTypeVariables #-}

module LatticeSpec (tests) where

import           Distribution.Version (Version, mkVersion)
import           PubGrub.Lattice
import           PubGrub.VersionSet   (VersionSet)
import qualified PubGrub.VersionSet   as VS
import           Test.Tasty           (TestTree, testGroup)
import           Test.Tasty.HUnit     (testCase, (@?=))

v :: [Int] -> Version
v = mkVersion

tests :: TestTree
tests =
  testGroup
    "Lattice"
    [ testCase "bottom is the empty version set" $
        (bottom :: VersionSet) @?= VS.empty
    , testCase "top is the full version set" $
        (top :: VersionSet) @?= VS.full
    , testCase "neg agrees with VS.complement" $
        neg (VS.singleton (v [1])) @?= VS.complement (VS.singleton (v [1]))
    , testCase "join agrees with VS.union" $
        (VS.singleton (v [1]) \/ VS.singleton (v [2]))
          @?= VS.union (VS.singleton (v [1])) (VS.singleton (v [2]))
    , testCase "meet agrees with VS.intersection" $
        (VS.full /\ VS.singleton (v [1])) @?= VS.singleton (v [1])
    , testCase "singleton agrees with VS.singleton" $
        (singleton (v [1]) :: VersionSet) @?= VS.singleton (v [1])
    , testCase "member agrees with VS.contains" $
        member (v [1]) (VS.singleton (v [1])) @?= True
    , testCase "member false outside the set" $
        member (v [2]) (VS.singleton (v [1])) @?= False
    , testCase "isBottom of empty" $ isBottom (VS.empty :: VersionSet) @?= True
    , testCase "isTop of full" $ isTop (VS.full :: VersionSet) @?= True
    , testCase "subsetOf: singleton in full" $
        subsetOf (VS.singleton (v [1])) (VS.full :: VersionSet) @?= True
    , testCase "disjoint singletons" $
        disjoint (VS.singleton (v [1])) (VS.singleton (v [2]) :: VersionSet) @?= True
    ]
