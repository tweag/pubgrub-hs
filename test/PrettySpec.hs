{-# LANGUAGE OverloadedStrings #-}

module PrettySpec (tests) where

import           Distribution.Types.PackageName (mkPackageName)
import           Distribution.Types.UnitId      (mkUnitId)
import           Distribution.Version           (mkVersion, orLaterVersion)
import           PubGrub.Choice                 (Choice (..),
                                                 ChoiceInstalled (..),
                                                 ChoiceSet (..),
                                                 ChoiceSource (..),
                                                 Repository (..))
import           PubGrub.Compiler               (PackageDb (..))
import           PubGrub.Lattice                (bottom)
import           PubGrub.Pretty                 (pretty)
import qualified PubGrub.VersionSet             as VS
import           Test.Tasty                     (TestTree, testGroup)
import           Test.Tasty.HUnit               (testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "Pretty"
        [ testCase "version" $ pretty (mkVersion [1, 2]) @?= "1.2"
        , testCase "singleton set" $ pretty (VS.singleton (mkVersion [1])) @?= "==1"
        , testCase "lower-bounded set" $
            pretty (VS.fromVersionRange (orLaterVersion (mkVersion [1]))) @?= ">=1"
        , testCase "installed choice is marked" $
            pretty (Installed (ChoiceInstalled (mkPackageName "foo") (mkVersion [1, 5]) GlobalDb (mkUnitId "foo-1.5-x")))
                @?= "1.5 (installed)"
        , testCase "source choice renders its version" $
            pretty (Source (ChoiceSource (mkPackageName "foo") (mkVersion [1, 5]) Hackage))
                @?= "1.5"
        , testCase "choiceset renders the source range" $
            pretty (ChoiceSet bottom (VS.fromVersionRange (orLaterVersion (mkVersion [1]))))
                @?= ">=1"
        ]
