module Main (main) where

import qualified FlattenSpec
import qualified IndexStateSpec
import qualified StoredSpec
import           Test.Tasty     (defaultMain, testGroup)

main :: IO ()
main =
    defaultMain $
        testGroup
            "pubgrub-hs"
            [ StoredSpec.tests
            , FlattenSpec.tests
            , IndexStateSpec.tests
            ]
