{-# LANGUAGE OverloadedStrings #-}

module InstalledDbSpec (tests) where

import qualified Data.ByteString.Char8
import           Distribution.Types.PackageName (mkPackageName)
import           Distribution.Types.UnitId      (mkUnitId)
import           Distribution.Version           (mkVersion)
import           PubGrub.Cabal.InstalledDb      (InstalledPkg (..),
                                                 parseGhcPkgDump)
import           Test.Tasty                     (TestTree, testGroup)
import           Test.Tasty.HUnit               (testCase, (@?=))

dump :: String
dump =
    unlines
        [ "name: ghc-prim"
        , "version: 0.11.0"
        , "id: ghc-prim-0.11.0-aaa"
        , "depends:"
        , "---"
        , "name: base"
        , "version: 4.21.0.0"
        , "id: base-4.21.0.0-bbb"
        , "depends: ghc-prim-0.11.0-aaa"
        , "---"
        ]

tests :: TestTree
tests =
    testGroup
        "InstalledDb"
        [ testCase "parses two records with names, versions, unit-ids" $
            (fmap (map ipName) (parseGhcPkgDump' dump))
                @?= Right [mkPackageName "ghc-prim", mkPackageName "base"]
        , testCase "parses dependency unit-ids" $
            (fmap (map ipDepends) (parseGhcPkgDump' dump))
                @?= Right [[], [mkUnitId "ghc-prim-0.11.0-aaa"]]
        , testCase "parses the unit-id and version of base" $
            (fmap (take 1 . drop 1) (parseGhcPkgDump' dump))
                @?= Right
                    [ InstalledPkg
                        (mkUnitId "base-4.21.0.0-bbb")
                        (mkPackageName "base")
                        (mkVersion [4, 21, 0, 0])
                        [mkUnitId "ghc-prim-0.11.0-aaa"]
                    ]
        ]
  where
    parseGhcPkgDump' = parseGhcPkgDump . encodeUtf8'
    -- Tests feed ASCII, so a Char->Word8 pack is faithful here.
    encodeUtf8' = Data.ByteString.Char8.pack
