module Main (main) where

import           Test.Tasty    (defaultMain, testGroup)
import qualified ToyDomainSpec

main :: IO ()
main = defaultMain (testGroup "pubgrub" [ToyDomainSpec.tests])
