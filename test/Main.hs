module Main (main) where

import qualified InstanceSetSpec
import qualified PaperSpec
import qualified SolverSpec
import           Test.Tasty     (defaultMain, testGroup)
import qualified VersionSetSpec

main :: IO ()
main =
    defaultMain $
        testGroup
            "pubgrub-hs"
            [ VersionSetSpec.tests
            , InstanceSetSpec.tests
            , SolverSpec.tests
            , PaperSpec.tests
            ]
