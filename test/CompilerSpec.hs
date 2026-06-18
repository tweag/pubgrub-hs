module CompilerSpec (tests) where

import           PubGrub.Cabal.Compiler (ghcPkgFromLibdir)
import           Test.Tasty             (TestTree, testGroup)
import           Test.Tasty.HUnit       (testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "Compiler"
        [ testCase "derives version-matched ghc-pkg from a ghcup libdir" $
            ghcPkgFromLibdir "/home/u/.ghcup/ghc/9.12.2/lib/ghc-9.12.2/lib"
                @?= "/home/u/.ghcup/ghc/9.12.2/lib/ghc-9.12.2/bin/ghc-pkg"
        , testCase "places ghc-pkg in a sibling bin of the libdir parent" $
            ghcPkgFromLibdir "/opt/ghc/lib/ghc-9.8.3/lib"
                @?= "/opt/ghc/lib/ghc-9.8.3/bin/ghc-pkg"
        ]
