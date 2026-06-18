module CompilerSpec (tests) where

import           Data.Either            (isLeft)
import           Distribution.Version   (mkVersion)
import           PubGrub.Cabal.Compiler (ghcPkgFromLibdir, parseCompilerVersion)
import           Test.Tasty             (TestTree, testGroup)
import           Test.Tasty.HUnit       (assertBool, testCase, (@?=))

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
        , testCase "parses numeric-version output with a trailing newline" $
            parseCompilerVersion "9.12.2\n" @?= Right (mkVersion [9, 12, 2])
        , testCase "tolerates surrounding whitespace" $
            parseCompilerVersion "  9.4.8  " @?= Right (mkVersion [9, 4, 8])
        , testCase "rejects non-version output" $
            assertBool "expected Left" (isLeft (parseCompilerVersion "not-a-version"))
        , testCase "rejects empty output" $
            assertBool "expected Left" (isLeft (parseCompilerVersion ""))
        ]
