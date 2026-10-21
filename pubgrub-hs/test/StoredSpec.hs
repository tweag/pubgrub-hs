-- | Tests for the derived index's entry format ('PubGrub.Cabal.Flatten.toStored')
-- and its CBOR codec ('Bridge.Hackage.Store').
--
-- The store exists to avoid re-parsing a @.cabal@, so the one property that
-- matters is that __reading a release through it is indistinguishable from
-- parsing it__. Everything here asserts that equality, on @.cabal@ sources
-- covering the shapes that could break it: @else@ branches, @os@\/@arch@\/@impl@
-- conditions (which the /flatten/ resolves and the /store/ must therefore leave
-- alone), flags at their defaults, sub-libraries and executables, and the two
-- inputs to buildability.
--
-- Every case also puts the entry through 'serialise' and back before resolving,
-- so a codec that loses a branch or reorders a constructor fails here rather
-- than in a solve.
module StoredSpec (tests) where

import           Bridge.Hackage                               (parseGPD)
import           Bridge.Hackage.Store                         (StoreCorrupt (..))
import           Bridge.Provider                              (pkgConfigPresent)
import           Codec.Serialise                              (deserialise,
                                                               deserialiseOrFail,
                                                               serialise)
import           Control.Exception                            (evaluate, try)
import qualified Data.ByteString                              as BS
import qualified Data.ByteString.Lazy.Char8                   as BL
import           Distribution.Compiler                        (AbiTag (NoAbiTag),
                                                               CompilerFlavor (GHC),
                                                               CompilerId (..),
                                                               CompilerInfo,
                                                               unknownCompilerInfo)
import           Distribution.Solver.Types.PkgConfigDb        (PkgConfigDb,
                                                               pkgConfigDbFromList)
import           Distribution.System                          (Arch (X86_64),
                                                               OS (Linux),
                                                               Platform (..))
import           Distribution.Types.GenericPackageDescription (GenericPackageDescription)
import           Distribution.Version                         (mkVersion)
import           PubGrub.Cabal.Flatten                        (FlagModel (..),
                                                               StoredRelease (..),
                                                               allStanzas,
                                                               componentDepsAtDefaults,
                                                               componentDepsAtDefaultsStored,
                                                               componentToolsAtDefaults,
                                                               componentToolsStored,
                                                               noStanzas,
                                                               setupDeps,
                                                               toStored,
                                                               unbuildableAtDefaults,
                                                               unbuildableAtDefaultsStored)
import           Test.Tasty                                   (TestTree,
                                                               testGroup)
import           Test.Tasty.HUnit                             (assertFailure,
                                                               testCase, (@?=))

testPlatform :: Platform
testPlatform = Platform X86_64 Linux

testCompiler :: CompilerInfo
testCompiler = unknownCompilerInfo (CompilerId GHC (mkVersion [9, 12, 2])) NoAbiTag

testPkgConfigDb :: PkgConfigDb
testPkgConfigDb = pkgConfigDbFromList [("zlib", "1.3.1")]

gpdOf :: String -> IO GenericPackageDescription
gpdOf src = case parseGPD (BL.pack src) of
    Right gpd -> pure gpd
    Left err  -> assertFailure ("could not parse the test .cabal: " <> show err)

-- | The two resolvers must agree with their description-taking counterparts,
-- both directly off 'toStored' and after a trip through the codec.
agrees :: String -> String -> TestTree
agrees name src = testCase name $ do
    gpd <- gpdOf src
    let stored = toStored gpd
        roundTripped = deserialise (serialise stored)
        db = pkgConfigPresent (Just testPkgConfigDb)

    -- The codec has to carry the optional stanzas as well as the four
    -- unconditional components, so each form is checked under both choices.
    mapM_ (agreeUnder gpd stored) [noStanzas, allStanzas]
    mapM_ (agreeUnder gpd roundTripped) [noStanzas, allStanzas]

    unbuildableAtDefaultsStored db testPlatform testCompiler stored
        @?= unbuildableAtDefaults db testPlatform testCompiler gpd
    unbuildableAtDefaultsStored db testPlatform testCompiler roundTripped
        @?= unbuildableAtDefaults db testPlatform testCompiler gpd
    srSetup roundTripped @?= setupDeps gpd
  where
    agreeUnder gpd stored stanzas = do
        componentDepsAtDefaultsStored stanzas testPlatform testCompiler stored
            @?= componentDepsAtDefaults stanzas testPlatform testCompiler gpd
        componentToolsStored FixedFlags stanzas testPlatform testCompiler stored
            @?= componentToolsAtDefaults stanzas testPlatform testCompiler gpd

-- | The test suites and benchmarks are skipped, not decoded. An entry whose
-- deferred sections are not CBOR at all still decodes, and reads right without
-- stanzas, and only forcing the test suites finds the damage.
deferredSkipped :: TestTree
deferredSkipped = testCase "test suites and benchmarks are decoded only when forced" $ do
    gpd <-
        gpdOf $
            unlines
                [ "name: p"
                , "version: 1.0"
                , "library"
                , "  build-depends: base"
                , "test-suite spec"
                , "  type: exitcode-stdio-1.0"
                , "  main-is: Spec.hs"
                , "  build-depends: base, p, hspec"
                ]
    let stored = toStored gpd
        garbage = BS.pack [0xff]
        -- The layout of a stored release, spelt as a tuple so that the deferred
        -- sections can be bytes that are not CBOR.
        damaged =
            serialise
                (srFlags stored, srManual stored, srLibrary stored, srOthers stored, garbage, garbage, srSetup stored)
    case deserialiseOrFail damaged of
        Left err -> assertFailure ("the entry around the damage did not decode: " <> show err)
        Right (sr :: StoredRelease) -> do
            componentDepsAtDefaultsStored noStanzas testPlatform testCompiler sr
                @?= componentDepsAtDefaults noStanzas testPlatform testCompiler gpd
            forced <- try (evaluate (length (srTests sr)))
            case forced of
                Left (StoreCorrupt _) -> pure ()
                Right _               -> assertFailure "forcing damaged test suites did not throw"

tests :: TestTree
tests =
    testGroup
        "Bridge.Hackage.Store (derived index entries)"
        [ deferredSkipped
        , agrees "plain library" $
            unlines
                [ "name: p"
                , "version: 1.0"
                , "library"
                , "  build-depends: base >=4 && <5, containers"
                ]
        , -- Build tools and setup dependencies ride in the node data, not the
          -- constraints, and have to survive the codec with their guards.
          agrees "build tools, legacy build-tools and setup-depends" $
            unlines
                [ "cabal-version: 2.4"
                , "name: p"
                , "version: 1.0"
                , "build-type: Custom"
                , "custom-setup"
                , "  setup-depends: base, Cabal >=3.0"
                , "flag gen"
                , "  default: True"
                , "library"
                , "  build-depends: base"
                , "  build-tools: hsc2hs, gen"
                , "  if flag(gen)"
                , "    build-tool-depends: alex:alex >=3"
                , "executable gen"
                , "  main-is: Gen.hs"
                , "  build-depends: base"
                , "  build-tool-depends: happy:happy, p:gen"
                , "test-suite spec"
                , "  type: exitcode-stdio-1.0"
                , "  main-is: Spec.hs"
                , "  build-depends: base, p, hspec"
                , "  build-tool-depends: hspec-discover:hspec-discover"
                , "  if flag(gen)"
                , "    build-depends: tasty"
                , "benchmark bench"
                , "  type: exitcode-stdio-1.0"
                , "  main-is: Bench.hs"
                , "  build-depends: base, criterion"
                , "  buildable: False"
                ]
        , -- The environment is what the store must NOT resolve: these conditions
          -- have to survive encoding and be resolved on the way out, or the store
          -- would answer for the machine that wrote it.
          agrees "os, arch and impl conditions" $
            unlines
                [ "name: p"
                , "version: 1.0"
                , "library"
                , "  build-depends: base"
                , "  if os(linux)"
                , "    build-depends: unix >=2"
                , "  if os(windows)"
                , "    build-depends: Win32 >=2"
                , "  if arch(x86_64)"
                , "    build-depends: wide >=1"
                , "  if impl(ghc >= 9.4)"
                , "    build-depends: newghc >=1"
                , "  else"
                , "    build-depends: oldghc >=1"
                ]
        , agrees "flags, with an else branch" $
            unlines
                [ "name: p"
                , "version: 1.0"
                , "flag fast"
                , "  default: True"
                , "flag extra"
                , "  default: False"
                , "library"
                , "  build-depends: base"
                , "  if flag(fast)"
                , "    build-depends: fastdep >=2 && <3"
                , "  else"
                , "    build-depends: slowdep >=1"
                , "  if flag(extra) && os(linux)"
                , "    build-depends: extradep"
                ]
        , agrees "sub-libraries and executables" $
            unlines
                [ "name: p"
                , "version: 1.0"
                , "library"
                , "  build-depends: base"
                , "library sub"
                , "  build-depends: subdep >=1"
                , "executable e"
                , "  main-is: Main.hs"
                , "  build-depends: exedep >=3"
                ]
        , agrees "buildable: False in the library" $
            unlines
                [ "name: p"
                , "version: 1.0"
                , "library"
                , "  build-depends: base"
                , "  buildable: False"
                ]
        , agrees "a satisfied pkgconfig-depends" $
            unlines
                [ "name: p"
                , "version: 1.0"
                , "library"
                , "  build-depends: base"
                , "  pkgconfig-depends: zlib"
                ]
        , agrees "an unsatisfiable pkgconfig-depends" $
            unlines
                [ "name: p"
                , "version: 1.0"
                , "library"
                , "  build-depends: base"
                , "  pkgconfig-depends: libpq"
                ]
        , agrees "pkgconfig-depends under a flag" $
            unlines
                [ "name: p"
                , "version: 1.0"
                , "flag pkg-config"
                , "  default: True"
                , "library"
                , "  build-depends: base"
                , "  if flag(pkg-config)"
                , "    pkgconfig-depends: libpq"
                ]
        , agrees "no library at all" $
            unlines
                [ "name: p"
                , "version: 1.0"
                , "executable e"
                , "  main-is: Main.hs"
                , "  build-depends: base"
                ]
        ]
