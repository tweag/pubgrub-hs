module Main (main) where

import qualified CookbookSpec
import qualified PartialSolutionSpec
import qualified RelationSpec
import qualified StoreInvariantsSpec
import           Test.Tasty          (defaultMain, testGroup)
import qualified ToyDomainSpec

main :: IO ()
main = defaultMain (testGroup "pubgrub" [CookbookSpec.tests, PartialSolutionSpec.tests, RelationSpec.tests, StoreInvariantsSpec.tests, ToyDomainSpec.tests])
