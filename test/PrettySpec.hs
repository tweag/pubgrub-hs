{-# LANGUAGE OverloadedStrings #-}

module PrettySpec (tests) where

import           Distribution.Version (mkVersion, orLaterVersion)
import           PubGrub.Pretty       (pretty)
import qualified PubGrub.VersionSet   as VS
import           Test.Tasty           (TestTree, testGroup)
import           Test.Tasty.HUnit     (testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "Pretty"
        [ testCase "version" $ pretty (mkVersion [1, 2]) @?= "1.2"
        , testCase "singleton set" $ pretty (VS.singleton (mkVersion [1])) @?= "==1"
        , testCase "lower-bounded set" $
            pretty (VS.fromVersionRange (orLaterVersion (mkVersion [1]))) @?= ">=1"
        ]
