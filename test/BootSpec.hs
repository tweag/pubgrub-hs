module BootSpec (tests) where

import qualified Data.Map.Strict                as Map

import           Distribution.Types.PackageName (mkPackageName)
import           Distribution.Version           (mkVersion)

import           PubGrub.Cabal.Boot             (parseBootList)
import           Test.Tasty                     (TestTree, testGroup)
import           Test.Tasty.HUnit               (testCase, (@?=))

tests :: TestTree
tests = testGroup "Boot"
  [ testCase "parses simple name-version tokens" $
      parseBootList "base-4.21.0.0 containers-0.7"
        @?= Map.fromList
              [ (mkPackageName "base", mkVersion [4, 21, 0, 0])
              , (mkPackageName "containers", mkVersion [0, 7])
              ]

  , testCase "handles hyphenated package names" $
      parseBootList "Cabal-syntax-3.14.2.0"
        @?= Map.fromList [(mkPackageName "Cabal-syntax", mkVersion [3, 14, 2, 0])]

  , testCase "ignores tokens without a parseable version" $
      parseBootList "rts notaversion-foo base-4.21.0.0"
        @?= Map.fromList [(mkPackageName "base", mkVersion [4, 21, 0, 0])]
  ]
