-- | From a @.cabal@ file to a plan, through 'PubGrub.Cabal.Provider.releaseOf':
-- the route a tool takes when it holds the descriptions itself and builds a
-- 'ReleaseSource' out of them, as the bridge does from the index.
--
-- What is under test is the reduction's two switches as the solve sees them.
-- The 'Stanzas' decide whether a release's test suites and benchmarks are
-- dependencies of it: a planner says yes for a local package under @cabal
-- test@ and no for everything else. And a test suite depends on its own
-- package's library — the intra-package edge @docs\/DESIGN.md@ §8 drops — so
-- turning the stanzas on must neither pin the package to itself nor fail the
-- solve.
module ReleaseSpec (tests) where

import           Control.Exception                            (toException)
import qualified Data.ByteString.Char8                        as BS
import qualified Data.Map.Strict                              as Map
import qualified Data.Set                                     as Set
import           Data.Text                                    (Text)
import qualified Data.Text                                    as T
import           Distribution.Compiler                        (AbiTag (NoAbiTag),
                                                               CompilerFlavor (GHC),
                                                               CompilerId (..),
                                                               CompilerInfo,
                                                               unknownCompilerInfo)
import           Distribution.PackageDescription.Parsec       (parseGenericPackageDescription,
                                                               runParseResult)
import           Distribution.System                          (Arch (X86_64),
                                                               OS (Linux),
                                                               Platform (..))
import           Distribution.Types.Dependency                (depPkgName)
import           Distribution.Types.Flag                      (mkFlagAssignment,
                                                               mkFlagName)
import           Distribution.Types.GenericPackageDescription (GenericPackageDescription)
import           Distribution.Types.PackageName               (PackageName,
                                                               mkPackageName)
import qualified Distribution.Types.Version                   as Cabal
import           PubGrub.Cabal                                (Var, foldFlags,
                                                               request)
import           PubGrub.Cabal.Flatten                        (FlagModel (..),
                                                               Stanzas,
                                                               allStanzas,
                                                               noStanzas)
import           PubGrub.Cabal.Installed                      (mkInstalledDb)
import           PubGrub.Cabal.InstanceSet                    (Instance (..),
                                                               singletonInstance)
import qualified PubGrub.Cabal.Provider                       as BP
import           PubGrub.Cabal.Report                         (reportConflict)
import           PubGrub.Cabal.Value                          (Resolved (..))
import           PubGrub.Cabal.Version                        (Version)
import qualified PubGrub.Cabal.Version                        as V
import           PubGrub.Provider                             (Provider (..))
import           PubGrub.Solver                               (SolveError (..),
                                                               solve)
import           Test.Tasty                                   (TestTree,
                                                               testGroup)
import           Test.Tasty.HUnit                             (assertFailure,
                                                               testCase, (@?=))

testPlatform :: Platform
testPlatform = Platform X86_64 Linux

testCompiler :: CompilerInfo
testCompiler = unknownCompilerInfo (CompilerId GHC (Cabal.mkVersion [9, 12, 2])) NoAbiTag

-- | Parse a fixture. The error is not shown: Cabal-syntax 3.18 tags it with a
-- source type this test never fixes, and the fixtures are ours.
gpdOf :: String -> IO GenericPackageDescription
gpdOf src = case snd (runParseResult (parseGenericPackageDescription (BS.pack src))) of
    Right gpd -> pure gpd
    Left _    -> assertFailure ("test fixture failed to parse:\n" ++ src)

-- | A world of one release per package, each reduced from its @.cabal@ under
-- the 'Stanzas' given for it, with no installed units and no pkg-config.
worldFrom :: [(PackageName, Stanzas, GenericPackageDescription)] -> Provider Var IO
worldFrom entries =
    Provider (BP.mkExpand mempty BP.noPreference (mkInstalledDb []) source)
  where
    releases =
        Map.fromList
            [ (p, BP.releaseOf FlagPackages stanzas testPlatform testCompiler (const False) gpd)
            | (p, stanzas, gpd) <- entries
            ]
    source =
        BP.ReleaseSource
            { BP.rsVersionsOf = \p -> if Map.member p releases then Set.singleton v1 else Set.empty
            , BP.rsReadRelease = \p v ->
                pure $ case Map.lookup p releases of
                    Just r | v == v1 -> Right r
                    _ -> Left (BP.ParseException (toException (userError ("not in world: " ++ show (p, v)))))
            }

v1 :: Version
v1 = V.mkVersion [1, 0]

solveFor :: PackageName -> Provider Var IO -> IO (Either Text (Map.Map PackageName Resolved))
solveFor target provider =
    either (Left . render) (Right . foldFlags)
        <$> solve mempty provider [request target (singletonInstance (BuildSource v1))]
  where
    render (NoSolution i) = reportConflict i
    render (NoSatisfier p _) = T.pack ("internal error: no satisfier for " <> show p)
    render _                 = T.pack "internal error"

-- | A library package whose test suite depends on the package itself, on a
-- package of its own, and under a flag on a third; a benchmark too.
localSrc :: String
localSrc =
    unlines
        [ "cabal-version: 3.0"
        , "name: local"
        , "version: 1.0"
        , "build-type: Simple"
        , ""
        , "flag slow"
        , "  default: False"
        , ""
        , "library"
        , "  build-depends: core, lib-dep"
        , ""
        , "test-suite spec"
        , "  type: exitcode-stdio-1.0"
        , "  main-is: Spec.hs"
        , "  build-depends: core, local, test-dep"
        , "  if flag(slow)"
        , "    build-depends: slow-dep"
        , ""
        , "benchmark bench"
        , "  type: exitcode-stdio-1.0"
        , "  main-is: Bench.hs"
        , "  build-depends: core, bench-dep"
        ]

leafSrc :: String -> String
leafSrc name =
    unlines
        [ "cabal-version: 3.0"
        , "name: " ++ name
        , "version: 1.0"
        , "build-type: Simple"
        , ""
        , "library"
        , "  build-depends: core"
        , ""
        , "test-suite spec"
        , "  type: exitcode-stdio-1.0"
        , "  main-is: Spec.hs"
        , "  build-depends: core, " ++ name ++ ", nobody-has-this"
        ]

pkg :: String -> PackageName
pkg = mkPackageName

tests :: TestTree
tests =
    testGroup
        "releaseOf (a .cabal file to a plan)"
        [ testCase "the stanzas decide what a release depends on" $ do
            gpd <- gpdOf localSrc
            let depsUnder stanzas =
                    Set.toList (Set.fromList [depPkgName d | (_, ds) <- BP.relGuarded (BP.releaseOf FlagPackages stanzas testPlatform testCompiler (const False) gpd), d <- ds])
            depsUnder noStanzas @?= [pkg "core", pkg "lib-dep"]
            depsUnder allStanzas @?= [pkg "bench-dep", pkg "core", pkg "lib-dep", pkg "local", pkg "slow-dep", pkg "test-dep"]
        , testCase "a local package's tests are solved, its dependencies' are not, and the self-dependency pins nothing" $ do
            local <- gpdOf localSrc
            leaves <- mapM (gpdOf . leafSrc) ["core", "lib-dep", "test-dep", "slow-dep", "bench-dep"]
            let world =
                    worldFrom $
                        (pkg "local", allStanzas, local)
                            : [(pkg n, noStanzas, gpd) | (n, gpd) <- zip ["core", "lib-dep", "test-dep", "slow-dep", "bench-dep"] leaves]
            result <- solveFor (pkg "local") world
            result
                @?= Right
                    ( Map.fromList
                        [ (pkg "local", Built v1 (mkFlagAssignment [(mkFlagName "slow", False)]))
                        , (pkg "core", Built v1 (mkFlagAssignment []))
                        , (pkg "lib-dep", Built v1 (mkFlagAssignment []))
                        , (pkg "test-dep", Built v1 (mkFlagAssignment []))
                        , (pkg "bench-dep", Built v1 (mkFlagAssignment []))
                        ]
                    )
        ]
