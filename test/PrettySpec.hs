{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms   #-}

module PrettySpec (tests) where

import qualified Data.Map.Strict           as Map
import qualified Data.Set                  as Set
import           Distribution.Types.Flag   (mkFlagName)
import           Distribution.Types.UnitId (mkUnitId)
import           Distribution.Version      (mkVersion, orLaterVersion)
import           PubGrub.Choice            (ChoiceSet (..), pattern Installed,
                                            pattern Source)
import           PubGrub.Lattice           (bottom)
import           PubGrub.Pow               (Pow (..))
import           PubGrub.Pretty            (pretty)
import           PubGrub.SourceConfig      (SourceConfig (..), fcTop, mkCell)
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
            pretty (Source (SourceConfig (mkVersion [1, 5]) mempty)) @?= "1.5"
        , testCase "source choice renders its version and flags" $
            pretty
                ( Source
                    ( SourceConfig
                        (mkVersion [1, 2])
                        (Map.fromList [(mkFlagName "fast", True), (mkFlagName "tls", False)])
                    )
                )
                @?= "1.2 +fast -tls"
        , testCase "choiceset renders the source range" $
            pretty (ChoiceSet (bottom, mkCell (VS.fromVersionRange (orLaterVersion (mkVersion [1]))) fcTop))
                @?= ">=1"
        , testCase "choiceset lists the installed instances it also admits" $
            pretty
                ( ChoiceSet
                    ( Incl (Set.fromList [mkUnitId "base-4.21-x"])
                    , mkCell (VS.fromVersionRange (orLaterVersion (mkVersion [1]))) fcTop
                    )
                )
                @?= ">=1 (also installed: base-4.21-x)"
        ]
