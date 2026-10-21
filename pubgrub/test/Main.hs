module Main (main) where

import qualified PartialSolutionSpec
import qualified StoreInvariantsSpec
import           Test.Tasty          (defaultMain, testGroup)
import qualified ToyDomainSpec

main :: IO ()
main = defaultMain (testGroup "pubgrub" [PartialSolutionSpec.tests, StoreInvariantsSpec.tests, ToyDomainSpec.tests])
