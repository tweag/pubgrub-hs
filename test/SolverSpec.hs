{-# LANGUAGE FlexibleInstances #-}
module SolverSpec (tests) where

import qualified Data.Map.Strict      as Map
import           Distribution.Version (mkVersion)
import           PubGrub.Types
import qualified PubGrub.VersionSet   as VS
import           Test.Tasty           (TestTree, testGroup)
import           Test.Tasty.HUnit     (testCase, (@?=))

instance Package String

tests :: TestTree
tests = testGroup "Solver"
  [ testCase "rule of resolution combines { p1:t1, p2:¬t2 } and { p2:t2, p3:t3 }" $
      let t1 = Positive (VS.singleton (mkVersion [1]))
          t2 = Positive (VS.singleton (mkVersion [2]))
          t3 = Positive (VS.singleton (mkVersion [3]))
          i1 = Incompatibility
                 (Map.fromList [("p1", t1), ("p2", negateTerm t2)])
                 (FromDependencyOf "p1" VS.full "p2" VS.full)
          i2 = Incompatibility
                 (Map.fromList [("p2", t2), ("p3", t3)])
                 (FromDependencyOf "p2" VS.full "p3" VS.full)
          res = priorCause i1 i2 "p2"
      in incompTerms res @?= Map.fromList [("p1", t1), ("p3", t3)]
  ]
