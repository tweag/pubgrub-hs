module Main (main) where

import qualified FlagSolveSpec
import qualified FlattenSpec
import qualified InstalledSpec
import qualified InstanceSetSpec
import qualified PartialSolutionSpec
import qualified PaperSpec
import qualified ReportSpec
import qualified SolverSpec
import qualified StoreSpec
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
            , StoreSpec.tests
            , PaperSpec.tests
            , ReportSpec.tests
            , FlattenSpec.tests
            , FlagSolveSpec.tests
            , InstalledSpec.tests
            ]
