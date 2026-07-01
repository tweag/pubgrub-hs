module Main (main) where

import qualified BootSpec
import qualified ChoiceSetSpec
import qualified CompilerSpec
import qualified FlattenSpec
import qualified InstalledDbProviderSpec
import qualified InstalledDbSpec
import qualified LatticeSpec
import qualified PowSpec
import qualified PrettySpec
import qualified ProviderSpec
import qualified SolverSpec
import qualified SourceConfigSpec
import           Test.Tasty              (defaultMain, testGroup)
import qualified VersionSetSpec

main :: IO ()
main =
    defaultMain $
        testGroup
            "pubgrub-hs"
            [ VersionSetSpec.tests
            , LatticeSpec.tests
            , PowSpec.tests
            , PrettySpec.tests
            , ChoiceSetSpec.tests
            , SourceConfigSpec.tests
            , SolverSpec.tests
            , FlattenSpec.tests
            , BootSpec.tests
            , CompilerSpec.tests
            , InstalledDbSpec.tests
            , InstalledDbProviderSpec.tests
            , ProviderSpec.tests
            ]
