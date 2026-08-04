module Main (main) where

import qualified FlagSolveSpec
import qualified FlattenSpec
import qualified InstalledSpec
import qualified InstanceSetSpec
import qualified PartialSolutionSpec
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
            , PartialSolutionSpec.tests
            , SolverSpec.tests
            , PaperSpec.tests
            , FlattenSpec.tests
            , FlagSolveSpec.tests
            , InstalledSpec.tests
            ]
