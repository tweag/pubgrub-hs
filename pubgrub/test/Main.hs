module Main (main) where

import           Test.Tasty    (defaultMain, testGroup)
import qualified StoreInvariantsSpec
import qualified ToyDomainSpec

main :: IO ()
main = defaultMain (testGroup "pubgrub" [StoreInvariantsSpec.tests, ToyDomainSpec.tests])
