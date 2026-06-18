module FlattenSpec (tests) where

import qualified Data.ByteString.Char8                        as BS
import qualified Data.Map.Strict                              as Map

import           Distribution.Compiler                        (AbiTag (..),
                                                               CompilerFlavor (..),
                                                               CompilerId (..),
                                                               CompilerInfo,
                                                               unknownCompilerInfo)
import           Distribution.PackageDescription.Parsec       (parseGenericPackageDescription,
                                                               runParseResult)
import           Distribution.System                          (Arch (..),
                                                               OS (..),
                                                               Platform (..))
import           Distribution.Types.GenericPackageDescription (GenericPackageDescription)
import           Distribution.Types.PackageName               (mkPackageName)
import           Distribution.Version                         (mkVersion)

import           PubGrub.Cabal.Flatten                        (flattenDeps)
import           Test.Tasty                                   (TestTree,
                                                               testGroup)
import           Test.Tasty.HUnit                             (testCase, (@?=))

plat :: Platform
plat = Platform X86_64 Linux

comp :: CompilerInfo
comp = unknownCompilerInfo (CompilerId GHC (mkVersion [9, 12, 4])) NoAbiTag

parseGPD :: String -> GenericPackageDescription
parseGPD s = case snd (runParseResult (parseGenericPackageDescription (BS.pack s))) of
    Right gpd -> gpd
    Left err  -> error ("parse failed: " ++ show err)

tests :: TestTree
tests =
    testGroup
        "Flatten"
        [ testCase "main library build-depends are extracted" $
            let gpd =
                    parseGPD
                        ( unlines
                            [ "cabal-version: 2.4"
                            , "name: demo"
                            , "version: 1.0"
                            , "library"
                            , "  build-depends: base >=4 && <5, containers"
                            , "  default-language: Haskell2010"
                            ]
                        )
             in Map.keys (flattenDeps plat comp gpd)
                    @?= [mkPackageName "base", mkPackageName "containers"]
        , testCase "conditional dep behind a default-false flag is excluded" $
            let gpd =
                    parseGPD
                        ( unlines
                            [ "cabal-version: 2.4"
                            , "name: demo"
                            , "version: 1.0"
                            , "flag fast"
                            , "  default: False"
                            , "  manual: True"
                            , "library"
                            , "  build-depends: base"
                            , "  if flag(fast)"
                            , "    build-depends: vector"
                            , "  default-language: Haskell2010"
                            ]
                        )
             in Map.member (mkPackageName "vector") (flattenDeps plat comp gpd) @?= False
        , testCase "package with no library yields no deps" $
            let gpd =
                    parseGPD
                        ( unlines
                            [ "cabal-version: 2.4"
                            , "name: demo"
                            , "version: 1.0"
                            , "executable foo"
                            , "  main-is: Main.hs"
                            , "  build-depends: base"
                            , "  default-language: Haskell2010"
                            ]
                        )
             in flattenDeps plat comp gpd @?= Map.empty
        ]
