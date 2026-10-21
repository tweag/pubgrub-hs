-- | Runs the @>>>@ examples in the library's Haddocks, so that an example
-- shows what the code does.
module Main (main) where

import           System.Environment (getArgs)
import           Test.DocTest       (mainFromCabal)

main :: IO ()
main = mainFromCabal "pubgrub" =<< getArgs
