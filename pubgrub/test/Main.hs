module Main (main) where

import qualified StoreInvariantsSpec
import           Test.Tasty          (defaultMain, testGroup)
import qualified ToyDomainSpec

main :: IO ()
main = defaultMain (testGroup "pubgrub" [StoreInvariantsSpec.tests, ToyDomainSpec.tests])
