module Main (main) where

import qualified BootSpec
import qualified FlattenSpec
import qualified SolverSpec
import           Test.Tasty     (defaultMain, testGroup)
import qualified VersionSetSpec

main :: IO ()
main =
    defaultMain $
        testGroup
            "pubgrub-hs"
            [ VersionSetSpec.tests
            , SolverSpec.tests
            , FlattenSpec.tests
            , BootSpec.tests
            ]
