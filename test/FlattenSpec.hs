-- | Tests for 'PubGrub.Cabal.Flatten': turning a @.cabal@ file's conditional
-- dependency tree into flag-guarded groups, and evaluating those guards at a
-- concrete flag assignment.
--
-- The inputs are real @.cabal@ sources parsed by Cabal-syntax, so the tests
-- exercise the same 'CondTree' shapes Hackage produces (in particular @else@
-- branches, which the parser desugars into a second sub-tree rather than a
-- negated guard).
--
-- Two things are being pinned down: that the /environment/ (OS, arch, compiler)
-- is resolved away at flatten time, and that /flags/ stay symbolic until
-- 'depsAt' is given an assignment.
module FlattenSpec (tests) where

import           Bridge.Hackage                               (parseGPD)
import           Bridge.Provider                              (pkgConfigPresent)
import qualified Data.ByteString.Lazy.Char8                   as BL
import           Data.List                                    (isInfixOf)
import qualified Data.Map.Strict                              as Map
import           Distribution.Compiler                        (AbiTag (NoAbiTag),
                                                               CompilerFlavor (GHC),
                                                               CompilerId (..),
                                                               CompilerInfo,
                                                               unknownCompilerInfo)
import           Distribution.Solver.Types.PkgConfigDb        (pkgConfigDbFromList)
import           Distribution.System                          (Arch (X86_64),
                                                               OS (Linux),
                                                               Platform (..))
import           Distribution.Types.Condition                 (Condition (..))
import           Distribution.Types.Dependency                (depPkgName)
import           Distribution.Types.ExeDependency             (ExeDependency (..))
import           Distribution.Types.Flag                      (FlagAssignment,
                                                               mkFlagAssignment,
                                                               mkFlagName)
import           Distribution.Types.GenericPackageDescription (GenericPackageDescription)
import           Distribution.Types.PackageName               (unPackageName)
import           Distribution.Types.PkgconfigDependency       (PkgconfigDependency (..))
import           Distribution.Types.PkgconfigName             (mkPkgconfigName)
import           Distribution.Types.PkgconfigVersionRange     (anyPkgconfigVersion)
import           Distribution.Types.UnqualComponentName       (unUnqualComponentName)
import           Distribution.Version                         (earlierVersion,
                                                               intersectVersionRanges,
                                                               mkVersion,
                                                               orLaterVersion)
import           PubGrub.Cabal                                (UnbuildableReason (..))
import           PubGrub.Cabal.Flatten                        (Stanzas (..),
                                                               allStanzas,
                                                               buildableCondition,
                                                               componentDeps,
                                                               componentDepsAtDefaults,
                                                               componentTools,
                                                               componentToolsAtDefaults,
                                                               defaultFlags,
                                                               depsAt,
                                                               expandGuard,
                                                               flattenDeps,
                                                               noStanzas,
                                                               setupDeps,
                                                               toolsAt,
                                                               unbuildableAtDefaults)
import           PubGrub.Cabal.Provider                       (ParseError (..))
import           PubGrub.Cabal.VersionSet                     (VersionSet,
                                                               fromVersionRange)
import           Test.Tasty                                   (TestTree,
                                                               testGroup)
import           Test.Tasty.HUnit                             (assertBool,
                                                               assertFailure,
                                                               testCase, (@?=))

-- --------------------------------------------------------------------------
-- Fixtures
-- --------------------------------------------------------------------------

-- | The fixed environment the guards are resolved against. Deliberately not
-- the build platform: the tests must not change answer on a Windows machine.
testPlatform :: Platform
testPlatform = Platform X86_64 Linux

testCompiler :: CompilerInfo
testCompiler = unknownCompilerInfo (CompilerId GHC (mkVersion [9, 12, 2])) NoAbiTag

-- | Parse a @.cabal@ source, failing the test on a parse error.
gpdOf :: String -> IO GenericPackageDescription
gpdOf src = case parseGPD (BL.pack src) of
    Right gpd -> pure gpd
    Left err  -> assertFailure ("test fixture failed to parse: " ++ show err)

-- | A minimal package stanza with the given body appended.
pkg :: String -> String
pkg body =
    unlines
        [ "cabal-version: 3.0"
        , "name: fixture"
        , "version: 1.0"
        , "build-type: Simple"
        , ""
        ]
        ++ body

flag :: String -> Bool -> String
flag name def =
    unlines
        [ "flag " ++ name
        , "  default: " ++ show def
        , "  manual: True"
        , ""
        ]

-- | Flatten then evaluate at an assignment — the two primitives, composed the
-- way callers do. Deliberately not via 'flattenDeps': that convenience pins the
-- assignment to the declared defaults, which is the one thing some of these
-- tests need to vary.
depsAtSrc :: FlagAssignment -> String -> IO [(String, VersionSet)]
depsAtSrc flags src = do
    gpd <- gpdOf src
    pure
        [ (unPackageName n, vs)
        | (n, vs) <- Map.toList (depsAt flags (componentDeps noStanzas testPlatform testCompiler gpd))
        ]

-- | The names of the dependencies active at an assignment, sorted.
namesAt :: FlagAssignment -> String -> IO [String]
namesAt flags src = map fst <$> depsAtSrc flags src

assign :: [(String, Bool)] -> FlagAssignment
assign fs = mkFlagAssignment [(mkFlagName n, b) | (n, b) <- fs]

-- --------------------------------------------------------------------------
-- Tests
-- --------------------------------------------------------------------------

tests :: TestTree
tests =
    testGroup
        "PubGrub.Cabal.Flatten"
        [ testGroup "components" componentTests
        , testGroup "environment (resolved at flatten time)" envTests
        , testGroup "flags (resolved at depsAt time)" flagTests
        , testGroup "flags (resolved at flatten time, at their defaults)" defaultedTests
        , testGroup "buildability (pkg-config, buildable: False)" buildableTests
        , testGroup "merging" mergeTests
        , testGroup "build tools and setup dependencies (not dependencies)" toolTests
        ]

-- | 'buildableCondition' and 'unbuildableAtDefaults': resolving the machine's
-- @pkg-config@ database, a constant of the environment like OS and arch, into a
-- statement about which flag assignments remain, and at the defaults into the
-- reasons the release is ruled out, module by module.
--
-- The fixtures take zlib's shape: a @pkgconfig-depends@ inside a flag-guarded
-- block, so whether the library is present decides whether a flag value is
-- available, not whether the package is usable outright.
buildableTests :: [TestTree]
buildableTests =
    [ testCase "no pkgconfig-depends and nothing unbuildable: no constraint" $ do
        gpd <-
            gpdOf . pkg $
                unlines
                    [ "library"
                    , "  build-depends: base"
                    ]
        buildableCondition testPkgConfig testPlatform testCompiler gpd
            @?= Lit True
    , testCase "a satisfied pkgconfig-depends adds no constraint" $ do
        gpd <- gpdOf zlibish
        buildableCondition testPkgConfig testPlatform testCompiler gpd
            @?= Lit True
        unbuildableAtDefaults testPkgConfig testPlatform testCompiler gpd @?= []
    , -- The whole point of keeping a condition: the missing library does not make
      -- the release unusable, it rules out the flag values that need it.
      testCase "an unsatisfied pkgconfig-depends rules out the guard, not the release" $ do
        gpd <- gpdOf zlibish
        buildableCondition emptyPkgConfig testPlatform testCompiler gpd
            @?= CNot (Var (mkFlagName "pkg-config"))
    , -- ...and with flags fixed at their defaults, that condition is a verdict:
      -- the flag defaults True, so the ruled-out value is the one we would use.
      testCase "at the defaults, a needed-but-missing library makes it unbuildable, and is named" $ do
        gpd <- gpdOf zlibish
        unbuildableAtDefaults emptyPkgConfig testPlatform testCompiler gpd
            @?= [MissingPkgConfig (pkgconfig "zlib")]
    , testCase "the same release is fine when the flag defaults the other way" $ do
        gpd <- gpdOf (zlibishDefaulting False)
        unbuildableAtDefaults emptyPkgConfig testPlatform testCompiler gpd @?= []
    , -- Mirrors cabal: no pkg-config executable is a statement about the machine,
      -- not permission to assume the library is there. The module is still named,
      -- since it is what the reader has to install either way.
      testCase "no pkg-config db at all rejects, as cabal does" $ do
        gpd <- gpdOf zlibish
        unbuildableAtDefaults (pkgConfigPresent Nothing) testPlatform testCompiler gpd
            @?= [MissingPkgConfig (pkgconfig "zlib")]
    , -- Every missing module is a reason of its own, in the order the .cabal
      -- names them: the proof says each, and a reader fixing one should not
      -- have to run the solver again to learn of the next.
      testCase "two missing modules are both named" $ do
        gpd <-
            gpdOf . pkg $
                unlines
                    [ "library"
                    , "  build-depends: base"
                    , "  pkgconfig-depends: libpq, zlib"
                    ]
        unbuildableAtDefaults emptyPkgConfig testPlatform testCompiler gpd
            @?= [MissingPkgConfig (pkgconfig "libpq"), MissingPkgConfig (pkgconfig "zlib")]
    , testCase "buildable: False in the library is unconditional" $ do
        gpd <-
            gpdOf . pkg $
                unlines
                    [ "library"
                    , "  build-depends: base"
                    , "  buildable: False"
                    ]
        unbuildableAtDefaults testPkgConfig testPlatform testCompiler gpd @?= [NotBuildable]
    , -- Narrower than 'componentDeps' on purpose. A dependency needs the library;
      -- an unbuildable executable does not make the package unusable as one, and
      -- 'componentDeps' drops that executable's dependencies rather than the
      -- release.
      testCase "buildable: False in an executable does not condemn the package" $ do
        gpd <-
            gpdOf . pkg $
                unlines
                    [ "library"
                    , "  build-depends: base"
                    , ""
                    , "executable demo"
                    , "  main-is: Main.hs"
                    , "  buildable: False"
                    ]
        unbuildableAtDefaults testPkgConfig testPlatform testCompiler gpd @?= []
    ]
  where
    zlibish = zlibishDefaulting True

    -- A @pkgconfig-depends@ on the module at any version, as the fixtures write it.
    pkgconfig name = PkgconfigDependency (mkPkgconfigName name) anyPkgconfigVersion

    -- zlib's shape: a flag choosing between the system library and a bundled copy.
    zlibishDefaulting def =
        pkg $
            unlines
                [ "flag pkg-config"
                , "  default: " ++ show def
                , "  manual: False"
                , ""
                , "library"
                , "  build-depends: base"
                , "  if flag(pkg-config)"
                , "    pkgconfig-depends: zlib"
                , "  else"
                , "    build-depends: bundled-zlib"
                ]

    testPkgConfig = pkgConfigPresent (Just (pkgConfigDbFromList [("zlib", "1.3.1")]))
    emptyPkgConfig = pkgConfigPresent (Just (pkgConfigDbFromList []))

componentTests :: [TestTree]
componentTests =
    [ testCase "unconditional library deps" $ do
        names <-
            namesAt (assign []) . pkg $
                unlines
                    [ "library"
                    , "  build-depends: base, containers"
                    ]
        names @?= ["base", "containers"]
    , testCase "sub-libraries and executables contribute" $ do
        names <-
            namesAt (assign []) . pkg $
                unlines
                    [ "library"
                    , "  build-depends: from-lib"
                    , ""
                    , "library internal"
                    , "  build-depends: from-sublib"
                    , ""
                    , "executable exe"
                    , "  main-is: Main.hs"
                    , "  build-depends: from-exe"
                    ]
        names @?= ["from-exe", "from-lib", "from-sublib"]
    , -- cabal pipes every component through Cabal-syntax's 'addBuildableCondition'
      -- before converting it (IndexConversion.convGPD), so a stanza that is not
      -- built contributes no constraint. Without that, http2-5.4.4's
      -- `hpack-encode`, which is `buildable: False` unless `devel` is on,
      -- contributes `aeson` and makes `optparse-applicative ==0.15.1.0` alongside
      -- `warp` unsolvable where cabal solves it.
      testCase "an unbuildable executable contributes no dependencies" $ do
        names <-
            namesAt (assign []) . pkg $
                unlines
                    [ "library"
                    , "  build-depends: from-lib"
                    , ""
                    , "executable demo"
                    , "  main-is: Main.hs"
                    , "  build-depends: from-exe"
                    , "  buildable: False"
                    ]
        names @?= ["from-lib"]
    , -- http2's own shape: the stanza is buildable only under a flag that is off
      -- by default, so the condition survives into the guard and evaluates away.
      testCase "an executable buildable only under an off flag contributes nothing" $ do
        let src =
                flag "devel" False
                    ++ unlines
                        [ "library"
                        , "  build-depends: from-lib"
                        , ""
                        , "executable demo"
                        , "  main-is: Main.hs"
                        , "  build-depends: from-exe"
                        , "  if flag(devel)"
                        , "  else"
                        , "    buildable: False"
                        ]
        atDefault <- namesAt (assign []) (pkg src)
        atDefault @?= ["from-lib"]
        -- and it comes back when the flag is on, so this gates rather than deletes
        withFlag <- namesAt (assign [("devel", True)]) (pkg src)
        withFlag @?= ["from-exe", "from-lib"]
    , -- an unbuildable SUB-library is gated the same way: cabal applies the same
      -- function to ComponentSubLib.
      testCase "an unbuildable sub-library contributes no dependencies" $ do
        names <-
            namesAt (assign []) . pkg $
                unlines
                    [ "library"
                    , "  build-depends: from-lib"
                    , ""
                    , "library internal"
                    , "  build-depends: from-sublib"
                    , "  buildable: False"
                    ]
        names @?= ["from-lib"]
    , -- The fourth component convGPD includes unconditionally, and gated like the
      -- rest. No corpus problem has one, so this test is the only thing holding it.
      testCase "a foreign library contributes, and not when unbuildable" $ do
        let src buildable' =
                unlines
                    [ "library"
                    , "  build-depends: from-lib"
                    , ""
                    , "foreign-library flib"
                    , "  type: native-shared"
                    , "  other-modules: F"
                    , "  build-depends: from-flib"
                    ]
                    ++ (if buildable' then "" else "  buildable: False\n")
        yes <- namesAt (assign []) (pkg (src True))
        no <- namesAt (assign []) (pkg (src False))
        yes @?= ["from-flib", "from-lib"]
        no @?= ["from-lib"]
    , -- Test-suites and benchmarks are the two convGPD puts behind a Stanza that a
      -- plain `cabal build` never enables: a solve for a build plan should not drag
      -- in a package's own test dependencies.
      testCase "test-suites and benchmarks do not contribute" $ do
        names <-
            namesAt (assign []) . pkg $
                unlines
                    [ "library"
                    , "  build-depends: from-lib"
                    , ""
                    , "test-suite spec"
                    , "  type: exitcode-stdio-1.0"
                    , "  main-is: Spec.hs"
                    , "  build-depends: from-test"
                    , ""
                    , "benchmark bench"
                    , "  type: exitcode-stdio-1.0"
                    , "  main-is: Bench.hs"
                    , "  build-depends: from-bench"
                    ]
        names @?= ["from-lib"]
    , -- ...unless the reduction is asked for them, which is what a planner does
      -- for a local package under `cabal test`: then they are read like any
      -- other component, gated on their own buildable: and flag-guarded.
      testCase "test-suites and benchmarks contribute when the stanzas ask" $ do
        gpd <-
            gpdOf . pkg $
                unlines
                    [ "flag slow"
                    , "  default: False"
                    , "  manual: True"
                    , ""
                    , "library"
                    , "  build-depends: from-lib"
                    , ""
                    , "test-suite spec"
                    , "  type: exitcode-stdio-1.0"
                    , "  main-is: Spec.hs"
                    , "  build-depends: fixture, from-test"
                    , "  if flag(slow)"
                    , "    build-depends: from-slow-test"
                    , ""
                    , "test-suite never"
                    , "  type: exitcode-stdio-1.0"
                    , "  main-is: Never.hs"
                    , "  build-depends: from-never"
                    , "  buildable: False"
                    , ""
                    , "benchmark bench"
                    , "  type: exitcode-stdio-1.0"
                    , "  main-is: Bench.hs"
                    , "  build-depends: from-bench"
                    ]
        let namesUnder stanzas flags =
                Map.keys (depsAt flags (componentDeps stanzas testPlatform testCompiler gpd))
        map unPackageName (namesUnder allStanzas (assign [])) @?= ["fixture", "from-bench", "from-lib", "from-test"]
        map unPackageName (namesUnder allStanzas (assign [("slow", True)])) @?= ["fixture", "from-bench", "from-lib", "from-slow-test", "from-test"]
        map unPackageName (namesUnder (Stanzas{withTests = True, withBenchmarks = False}) (assign [])) @?= ["fixture", "from-lib", "from-test"]
        map unPackageName (namesUnder (Stanzas{withTests = False, withBenchmarks = True}) (assign [])) @?= ["from-bench", "from-lib"]
        map unPackageName (namesUnder noStanzas (assign [])) @?= ["from-lib"]
    , testCase "a package with no components has no deps" $ do
        names <- namesAt (assign []) (pkg "")
        names @?= []
    ]

envTests :: [TestTree]
envTests =
    [ testCase "os() is resolved against the platform" $ do
        names <-
            namesAt (assign []) . pkg $
                unlines
                    [ "library"
                    , "  build-depends: base"
                    , "  if os(windows)"
                    , "    build-depends: Win32"
                    , "  else"
                    , "    build-depends: unix"
                    ]
        names @?= ["base", "unix"]
    , testCase "arch() is resolved against the platform" $ do
        names <-
            namesAt (assign []) . pkg $
                unlines
                    [ "library"
                    , "  if arch(x86_64)"
                    , "    build-depends: wide"
                    , "  else"
                    , "    build-depends: narrow"
                    ]
        names @?= ["wide"]
    , testCase "impl() is resolved against the compiler version" $ do
        names <-
            namesAt (assign []) . pkg $
                unlines
                    [ "library"
                    , "  if impl(ghc >= 9.0)"
                    , "    build-depends: modern"
                    , "  if impl(ghc < 9.0)"
                    , "    build-depends: ancient"
                    , "  if impl(ghcjs)"
                    , "    build-depends: jsbits"
                    ]
        names @?= ["modern"]
    , -- The point of resolving the environment at flatten time: nothing but
      -- flags survives into a guard, so 'depsAt' needs no platform or compiler.
      testCase "environment guards leave no free variables behind" $ do
        gpd <-
            gpdOf . pkg $
                unlines
                    [ "library"
                    , "  build-depends: base"
                    , "  if os(windows) && arch(x86_64)"
                    , "    build-depends: Win32"
                    , "  else"
                    , "    build-depends: unix"
                    ]
        map fst (componentDeps noStanzas testPlatform testCompiler gpd)
            @?= [Lit True, Lit False, Lit True]
    ]

-- | 'componentDepsAtDefaults', the entry point the solver is fed, with every
-- flag treated as manual and fixed at its declared default.
--
-- These tests pin down that /nothing symbolic survives the flatten/: the guards
-- come out as literals, so no flag can reach the solver however the result is
-- used afterwards. Fixing the flags rests on that property, and it is cheaper
-- to assert here than to infer from a solve.
defaultedTests :: [TestTree]
defaultedTests =
    [ testCase "every guard folds to a literal" $ do
        gpd <-
            gpdOf . pkg $
                flag "fast" False
                    ++ unlines
                        [ "library"
                        , "  build-depends: base"
                        , "  if flag(fast)"
                        , "    build-depends: speedy"
                        , "  else"
                        , "    build-depends: slow"
                        ]
        map fst (componentDepsAtDefaults noStanzas testPlatform testCompiler gpd)
            @?= [Lit True, Lit False, Lit True]
    , -- The flatten has already committed, so a later 'depsAt' cannot reopen the
      -- choice — which is exactly the difference from 'componentDeps', where the
      -- same assignment does switch the branch (see the group above).
      testCase "the default branch is chosen, and depsAt cannot unpick it" $ do
        gpd <-
            gpdOf . pkg $
                flag "fast" False
                    ++ unlines
                        [ "library"
                        , "  if flag(fast)"
                        , "    build-depends: speedy"
                        , "  else"
                        , "    build-depends: slow"
                        ]
        let guarded = componentDepsAtDefaults noStanzas testPlatform testCompiler gpd
            at fs = map (unPackageName . fst) (Map.toList (depsAt (assign fs) guarded))
        at [] @?= ["slow"]
        at [("fast", True)] @?= ["slow"]
    , testCase "a flag defaulting True selects its own branch" $ do
        gpd <-
            gpdOf . pkg $
                flag "fast" True
                    ++ unlines
                        [ "library"
                        , "  if flag(fast)"
                        , "    build-depends: speedy"
                        , "  else"
                        , "    build-depends: slow"
                        ]
        let guarded = componentDepsAtDefaults noStanzas testPlatform testCompiler gpd
        map (unPackageName . fst) (Map.toList (depsAt (assign []) guarded))
            @?= ["speedy"]
    , -- What 'PubGrub.Cabal.Provider' does with those literals, and why no other part of
      -- the pipeline has to handle them: the live group yields one candidate
      -- assignment with /no/ pins, so the dependency is emitted with its flag
      -- component unconstrained; the dead group yields none, and the provider
      -- drops a group whose expansion is empty.
      testCase "expandGuard turns the literals into an unpinned emission" $ do
        gpd <-
            gpdOf . pkg $
                flag "fast" False
                    ++ unlines
                        [ "library"
                        , "  build-depends: base"
                        , "  if flag(fast)"
                        , "    build-depends: speedy"
                        , "  else"
                        , "    build-depends: slow"
                        ]
        map (expandGuard . fst) (componentDepsAtDefaults noStanzas testPlatform testCompiler gpd)
            @?= [[Map.empty], [], [Map.empty]]
    , -- 'componentDepsAtDefaults' has to resolve every flag, so it needs an answer
      -- for one the release does not declare. It reads False, matching the
      -- convention 'evalCond' already documents — but the fallback is unreachable
      -- from a real index, because Cabal-syntax refuses the file outright. Pinned
      -- here so that stays a fact about the parser rather than an assumption.
      testCase "an undeclared flag cannot reach us: the parser rejects it" $ do
        let src =
                pkg $
                    unlines
                        [ "library"
                        , "  if flag(ghost)"
                        , "    build-depends: spooky"
                        ]
        case parseGPD (BL.pack src) of
            Left (ParseError _ errs) ->
                assertBool
                    ("expected an undefined-flag error, got: " ++ show errs)
                    (any (("used without having been defined" `isInfixOf`) . show) errs)
            Left err -> assertFailure ("expected a parse error, got: " ++ show err)
            Right _ -> assertFailure "expected the parse to fail on an undefined flag"
    ]

flagTests :: [TestTree]
flagTests =
    [ testCase "a flag guard admits deps only when the flag is True" $ do
        let src =
                pkg $
                    flag "fast" False
                        ++ unlines
                            [ "library"
                            , "  build-depends: base"
                            , "  if flag(fast)"
                            , "    build-depends: speedy"
                            ]
        onT <- namesAt (assign [("fast", True)]) src
        onF <- namesAt (assign [("fast", False)]) src
        onT @?= ["base", "speedy"]
        onF @?= ["base"]
    , testCase "the else branch is taken when the flag is False" $ do
        let src =
                pkg $
                    flag "fast" False
                        ++ unlines
                            [ "library"
                            , "  if flag(fast)"
                            , "    build-depends: speedy"
                            , "  else"
                            , "    build-depends: slow"
                            ]
        onT <- namesAt (assign [("fast", True)]) src
        onF <- namesAt (assign [("fast", False)]) src
        onT @?= ["speedy"]
        onF @?= ["slow"]
    , testCase "nested guards conjoin: both flags must hold" $ do
        let src =
                pkg $
                    flag "a" False
                        ++ flag "b" False
                        ++ unlines
                            [ "library"
                            , "  if flag(a)"
                            , "    build-depends: outer"
                            , "    if flag(b)"
                            , "      build-depends: inner"
                            ]
        both <- namesAt (assign [("a", True), ("b", True)]) src
        justA <- namesAt (assign [("a", True), ("b", False)]) src
        justB <- namesAt (assign [("a", False), ("b", True)]) src
        both @?= ["inner", "outer"]
        justA @?= ["outer"]
        justB @?= []
    , testCase "a flag mixed with an environment condition still switches" $ do
        let src =
                pkg $
                    flag "fast" False
                        ++ unlines
                            [ "library"
                            , "  if flag(fast) && !os(windows)"
                            , "    build-depends: speedy"
                            ]
        onT <- namesAt (assign [("fast", True)]) src
        onF <- namesAt (assign [("fast", False)]) src
        onT @?= ["speedy"]
        onF @?= []
    , -- 'depsAt' takes the assignment on trust: 'evalCond' reads an unassigned
      -- flag as False rather than as its declared default, on the precondition
      -- that the assignment is total over the declared flags. A partial map,
      -- such as a cell's pins, would silently select the wrong branch.
      testCase "depsAt takes the assignment on trust: unassigned reads False" $ do
        let src =
                pkg $
                    flag "fast" True
                        ++ unlines
                            [ "library"
                            , "  if flag(fast)"
                            , "    build-depends: speedy"
                            , "  else"
                            , "    build-depends: slow"
                            ]
        partial <- namesAt (assign []) src -- NB: 'fast' defaults to True
        total <- namesAt (assign [("fast", True)]) src
        partial @?= ["slow"]
        total @?= ["speedy"]
    , -- Nothing in 'Flatten' completes a partial assignment — the caller does
      -- (a flag the assignment leaves out is the caller's to decide, at its
      -- declared default where flags are fixed). 'defaultFlags' is the
      -- declared-default half of that rule, so this pins the completion every
      -- caller has to agree with.
      testCase "the declared defaults select the default branch" $ do
        gpd <-
            gpdOf . pkg $
                flag "fast" True
                    ++ unlines
                        [ "library"
                        , "  if flag(fast)"
                        , "    build-depends: speedy"
                        , "  else"
                        , "    build-depends: slow"
                        ]
        let defaults = mkFlagAssignment (Map.toList (defaultFlags gpd))
        map unPackageName (Map.keys (flattenDeps noStanzas testPlatform testCompiler defaults gpd))
            @?= ["speedy"]
    , testCase "flags not mentioned by any guard are simply ignored" $ do
        let src =
                pkg $
                    flag "unused" False
                        ++ unlines
                            [ "library"
                            , "  build-depends: base"
                            ]
        names <- namesAt (assign [("unused", True)]) src
        names @?= ["base"]
    ]

mergeTests :: [TestTree]
mergeTests =
    [ testCase "two constraints on one package intersect" $ do
        deps <-
            depsAtSrc (assign []) . pkg $
                unlines
                    [ "library"
                    , "  build-depends: base >= 4"
                    , ""
                    , "executable exe"
                    , "  main-is: Main.hs"
                    , "  build-depends: base < 5"
                    ]
        deps
            @?= [ ( "base"
                  , fromVersionRange
                        ( intersectVersionRanges
                            (orLaterVersion (mkVersion [4]))
                            (earlierVersion (mkVersion [5]))
                        )
                  )
                ]
    , testCase "a guarded constraint narrows the unguarded one" $ do
        let src =
                pkg $
                    flag "strict" False
                        ++ unlines
                            [ "library"
                            , "  build-depends: base >= 4"
                            , "  if flag(strict)"
                            , "    build-depends: base < 5"
                            ]
        loose <- depsAtSrc (assign [("strict", False)]) src
        tight <- depsAtSrc (assign [("strict", True)]) src
        loose @?= [("base", fromVersionRange (orLaterVersion (mkVersion [4])))]
        tight
            @?= [ ( "base"
                  , fromVersionRange
                        ( intersectVersionRanges
                            (orLaterVersion (mkVersion [4]))
                            (earlierVersion (mkVersion [5]))
                        )
                  )
                ]
    , -- 'componentDeps' is a pure flatten and 'depsAt' a pure evaluation, so
      -- one flattened tree can be evaluated at many assignments, which a
      -- solver that searches the flags needs.
      testCase "one flatten, many assignments" $ do
        gpd <-
            gpdOf . pkg $
                flag "a" False
                    ++ unlines
                        [ "library"
                        , "  if flag(a)"
                        , "    build-depends: yes-dep"
                        , "  else"
                        , "    build-depends: no-dep"
                        ]
        let guarded = componentDeps noStanzas testPlatform testCompiler gpd
            at fs = map unPackageName (Map.keys (depsAt (assign fs) guarded))
        at [("a", True)] @?= ["yes-dep"]
        at [("a", False)] @?= ["no-dep"]
    ]

-- | 'componentTools' and 'setupDeps': what a release owes to other namespaces,
-- kept out of its dependencies. The rules are cabal's own conversion's
-- (@getAllToolDependencies@ minus @isInternal@, and @desugarBuildTool@): a
-- @build-tool-depends@ as written, a legacy @build-tools@ name only when cabal
-- knows which package it is, and never the release's own executable.
toolTests :: [TestTree]
toolTests =
    [ testCase "build-tool-depends names the package and the executable, and is not a dependency" $ do
        gpd <-
            gpdOf . pkg $
                unlines
                    [ "library"
                    , "  build-depends: base"
                    , "  build-tool-depends: alex:alex >=3.2, happy:happy"
                    ]
        toolNames gpd @?= [("alex", "alex"), ("happy", "happy")]
        names (componentDeps noStanzas testPlatform testCompiler gpd) @?= ["base"]
    , testCase "a tool that is the package's own executable is internal and dropped" $ do
        gpd <-
            gpdOf . pkg $
                unlines
                    [ "library"
                    , "  build-depends: base"
                    , "  build-tool-depends: fixture:gen, alex:alex"
                    , ""
                    , "executable gen"
                    , "  main-is: Gen.hs"
                    , "  build-depends: base"
                    ]
        toolNames gpd @?= [("alex", "alex")]
    , testCase "legacy build-tools: a known name is its package, an own executable is internal, anything else is not a solver's business" $ do
        gpd <-
            gpdOf . legacyPkg $
                unlines
                    [ "library"
                    , "  build-depends: base"
                    , "  build-tools: hsc2hs, gen, some-script"
                    , ""
                    , "executable gen"
                    , "  main-is: Gen.hs"
                    , "  build-depends: base"
                    ]
        toolNames gpd @?= [("hsc2hs", "hsc2hs")]
    , testCase "a tool under a flag keeps its guard, and under a false branch is gone" $ do
        gpd <-
            gpdOf . pkg $
                flag "gen" True
                    ++ unlines
                        [ "library"
                        , "  build-depends: base"
                        , "  if flag(gen)"
                        , "    build-tool-depends: alex:alex"
                        , "  if os(windows)"
                        , "    build-tool-depends: happy:happy"
                        ]
        toolNamesAt (assign [("gen", True)]) gpd @?= [("alex", "alex")]
        toolNamesAt (assign [("gen", False)]) gpd @?= []
        toolNamesAtDefaults gpd @?= [("alex", "alex")]
    , testCase "an executable's tools count, a test suite's do not, as for dependencies" $ do
        gpd <-
            gpdOf . pkg $
                unlines
                    [ "library"
                    , "  build-depends: base"
                    , ""
                    , "executable tool"
                    , "  main-is: Main.hs"
                    , "  build-depends: base"
                    , "  build-tool-depends: alex:alex"
                    , ""
                    , "test-suite spec"
                    , "  type: exitcode-stdio-1.0"
                    , "  main-is: Spec.hs"
                    , "  build-depends: base"
                    , "  build-tool-depends: hspec-discover:hspec-discover"
                    ]
        toolNames gpd @?= [("alex", "alex")]
        toolNamesUnder allStanzas gpd @?= [("alex", "alex"), ("hspec-discover", "hspec-discover")]
    , testCase "setup-depends is read off the package, and is not a dependency" $ do
        gpd <-
            gpdOf $
                unlines
                    [ "cabal-version: 3.0"
                    , "name: fixture"
                    , "version: 1.0"
                    , "build-type: Custom"
                    , ""
                    , "custom-setup"
                    , "  setup-depends: base, Cabal >=3.0"
                    , ""
                    , "library"
                    , "  build-depends: base"
                    ]
        map (unPackageName . depPkgName) (setupDeps gpd) @?= ["base", "Cabal"]
        names (componentDeps noStanzas testPlatform testCompiler gpd) @?= ["base"]
    ]
  where
    -- @build-tools@ is gone from the 3.0 specification, so its fixture speaks 2.4.
    legacyPkg body = unlines ["cabal-version: 2.4", "name: fixture", "version: 1.0", "build-type: Simple", ""] ++ body
    toolNames = toolNamesUnder noStanzas
    toolNamesUnder stanzas gpd = [(unPackageName p, unUnqualComponentName e) | (_, ds) <- componentTools stanzas testPlatform testCompiler gpd, ExeDependency p e _ <- ds]
    toolNamesAt flags gpd = [(unPackageName p, unUnqualComponentName e) | ExeDependency p e _ <- toolsAt flags (componentTools noStanzas testPlatform testCompiler gpd)]
    toolNamesAtDefaults gpd = [(unPackageName p, unUnqualComponentName e) | ExeDependency p e _ <- toolsAt (mkFlagAssignment (Map.toList (defaultFlags gpd))) (componentToolsAtDefaults noStanzas testPlatform testCompiler gpd)]
    names guarded = [unPackageName (depPkgName d) | (_, ds) <- guarded, d <- ds]
