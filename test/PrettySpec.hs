{-# LANGUAGE OverloadedStrings #-}

module PrettySpec (tests) where

import           Distribution.Types.UnitId (mkUnitId)
import           Distribution.Version      (mkVersion, orLaterVersion)
import           PubGrub.Choice            (Choice (..), ChoiceSet (..))
import           PubGrub.Lattice           (bottom)
import           PubGrub.Pretty            (pretty)
import qualified PubGrub.VersionSet        as VS
import           Test.Tasty                (TestTree, testGroup)
import           Test.Tasty.HUnit          (testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "Pretty"
        [ testCase "version" $ pretty (mkVersion [1, 2]) @?= "1.2"
        , testCase "singleton set" $ pretty (VS.singleton (mkVersion [1])) @?= "==1"
        , testCase "lower-bounded set" $
            pretty (VS.fromVersionRange (orLaterVersion (mkVersion [1]))) @?= ">=1"
        , testCase "installed choice renders its unit-id, marked" $
            pretty (Installed (mkUnitId "foo-1.5-x")) @?= "foo-1.5-x (installed)"
        , testCase "source choice renders its version" $
            pretty (Source (mkVersion [1, 5])) @?= "1.5"
        , testCase "choiceset renders the source range" $
            pretty (ChoiceSet bottom (VS.fromVersionRange (orLaterVersion (mkVersion [1]))))
                @?= ">=1"
        ]
