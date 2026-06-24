module Main (main) where

import qualified BootSpec
import qualified CompilerSpec
import qualified FlattenSpec
import qualified LatticeSpec
import qualified PowSpec
import qualified SolverSpec
import           Test.Tasty     (defaultMain, testGroup)
import qualified VersionSetSpec

main :: IO ()
main =
    defaultMain $
        testGroup
            "pubgrub-hs"
            [ VersionSetSpec.tests
            , LatticeSpec.tests
            , PowSpec.tests
            , SolverSpec.tests
            , FlattenSpec.tests
            , BootSpec.tests
            , CompilerSpec.tests
            ]
