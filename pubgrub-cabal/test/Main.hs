module Main (main) where

import qualified ConstraintSpec
import qualified FlagSolveSpec
import qualified InstalledSpec
import qualified InstanceSetSpec
import qualified PaperSpec
import qualified ReleaseSpec
import qualified ReportSpec
import qualified SolverSpec
import qualified StoreSpec
import           Test.Tasty      (defaultMain, testGroup)
import qualified VersionSetSpec

main :: IO ()
main =
    defaultMain $
        testGroup
            "pubgrub-cabal"
            [ VersionSetSpec.tests
            , InstanceSetSpec.tests
            , SolverSpec.tests
            , ConstraintSpec.tests
            , StoreSpec.tests
            , PaperSpec.tests
            , ReportSpec.tests
            , FlagSolveSpec.tests
            , InstalledSpec.tests
            , ReleaseSpec.tests
            ]
