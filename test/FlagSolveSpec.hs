{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}

-- | End-to-end solver tests in which /flags/ are the interesting axis, plus
-- the provider-rule tests that need the same harness.
--
-- 'SolverSpec' and 'PaperSpec' build worlds without flags, so the search over
-- flag values never runs there. What this module adds is the loop that closes
-- over the flag variables: a release's automatic flags become goals of their
-- own ('PubGrub.Incompatibility.declaresFlag'), its guarded dependencies name
-- them, and the solver learns \"not this value\" and the provider offers the
-- other.
--
-- These tests run the __real__ provider. 'PubGrub.Cabal.Provider.mkExpand' is the whole
-- rule — candidate enumeration, flag emission, incompatibility emission — and it
-- takes its world as arguments, so 'worldProviderUnder' feeds it an in-memory
-- index instead of Hackage. Nothing about the rule is restated here: a
-- paraphrase of the rule can only ever test the paraphrase.
--
-- What the worlds supply is the /data/: which packages and versions exist,
-- which flags each declares, and its dependencies as flag-guarded groups (the toy
-- analogue of @PubGrub.Cabal.Flatten.GuardedDeps@). A package absent from the world
-- has no versions at all, which is how these tests write an unsatisfiable
-- dependency.
module FlagSolveSpec (tests) where

import           PubGrub.Cabal.Flatten          (FlagModel (..))
import           PubGrub.Cabal.Installed        (InstalledPkg (..), mkInstalledDb)
import qualified PubGrub.Cabal.Provider         as BP
import           PubGrub.Cabal.Provider         (ParseError (..))
import           Control.Exception              (toException)
import           Control.Monad.IO.Class         (liftIO)
import           Data.Either                    (fromLeft, isLeft)
import           Data.IORef                     (IORef, modifyIORef', newIORef,
                                                 readIORef)
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Data.Maybe                     (fromMaybe)
import qualified Data.Set                       as Set
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Distribution.Types.Condition   (Condition (..))
import           Distribution.Types.Dependency  (Dependency, mainLibSet,
                                                 mkDependency)
import           Distribution.Types.Flag        (FlagName, mkFlagAssignment,
                                                 mkFlagName)
import           Distribution.Types.PackageName (PackageName, mkPackageName)
import           Distribution.Types.UnitId      (mkUnitId)
import           Distribution.Types.Version     (mkVersion)
import           Distribution.Version           (anyVersion, thisVersion)
import           PubGrub.Cabal                  (Cabal,
                                                 CabalFact (..),
                                                 UnbuildableReason (..),
                                                 flagConstraint, request)
import           PubGrub.Incompatibility        (Cause (..),
                                                 Incompatibility (..))
import           PubGrub.Index.PreInstalled     (PreInstalledPackage (..))
import           PubGrub.InstanceSet            (Instance (..),
                                                 InstanceSet (..),
                                                 singletonInstance,
                                                 sourceInstances)
import           PubGrub.Provider               (Provider (Provider, expand))
import           PubGrub.Report                 (reportConflict)
import           PubGrub.Solver                 (SolveError (..),
                                                 solve)
import           PubGrub.Value                  (Resolved (..), Value (..),
                                                 foldFlags, instanceSet)
import           PubGrub.Variable               (Flag (..), Var (..))
import           PubGrub.Version                (Version)
import qualified PubGrub.Version                as V
import qualified PubGrub.VersionSet             as VersionSet
import           Test.Tasty                     (TestTree, testGroup)
import           Test.Tasty.HUnit               (assertBool, assertFailure,
                                                 testCase, (@?=))

-- --------------------------------------------------------------------------
-- A toy world with flags
-- --------------------------------------------------------------------------

-- | One source release: a version, and its dependencies as /flag-guarded groups/
-- — the toy stand-in for @PubGrub.Cabal.Flatten.GuardedDeps@, which is what a
-- @.cabal@ file's conditional tree flattens to.
data Release = Release
    { relVersion :: Version
    , relGuarded :: [(Condition FlagName, [Dependency])]
    }

-- | A package: the flags it declares (with their defaults) and its releases.
-- Every release of a package shares the declared flags, as in a @.cabal@ file.
data Pkg = Pkg
    { pkgFlags    :: [(FlagName, Bool)]
    , pkgReleases :: [Release]
    }

-- | The whole universe. A package /absent/ from the world has no versions at
-- all, which is how these tests write an unsatisfiable dependency: the provider
-- returns 'Nothing' and the solver mints a "no instances" incompatibility,
-- the same shape a missing Hackage package produces.
type World = [(PackageName, Pkg)]

-- | The provider for a world under a flag model: the /real/ 'BP.mkExpand',
-- driven from an in-memory index built out of the world. Under 'FlagPackages'
-- every declared flag is automatic and a variable; under 'FixedFlags' the
-- guards are resolved at the declared defaults before the provider sees them,
-- which is what 'PubGrub.Cabal.Flatten.componentDepsStored' does to a real
-- release.
worldProviderUnder :: FlagModel -> [(PackageName, Version)] -> World -> Provider Cabal TestM
worldProviderUnder = worldProviderUnderWith BP.noPreference

-- | 'worldProviderUnder' with flag search and a 'BP.Preference'.
worldProviderUnderPreferring :: BP.Preference -> [(PackageName, Version)] -> World -> Provider Cabal TestM
worldProviderUnderPreferring preference = worldProviderUnderWith preference FlagPackages

worldProviderUnderWith :: BP.Preference -> FlagModel -> [(PackageName, Version)] -> World -> Provider Cabal TestM
worldProviderUnderWith preference model unbuildableHere world =
    Provider (BP.mkExpand mempty preference (mkInstalledDb []) source)
  where
    source =
        BP.ReleaseSource
            { BP.rsVersionsOf = \p ->
                maybe Set.empty (Set.fromList . map relVersion . pkgReleases) (lookup p world)
            , BP.rsReadRelease = \p v -> pure (readRelease p v)
            }

    releases :: Map (PackageName, Version) BP.Release
    releases =
        Map.fromList
            [ ( (p, relVersion r)
              , BP.Release
                    { BP.relAutomatic = case model of
                        FixedFlags   -> []
                        FlagPackages -> [Flag f d | (f, d) <- pkgFlags pk]
                    , BP.relGuarded = case model of
                        FixedFlags   -> [(Lit True, deps) | (g, deps) <- relGuarded r, atDefaults (pkgFlags pk) g]
                        FlagPackages -> relGuarded r
                    , BP.relUnbuildable = [NotBuildable | (p, relVersion r) `elem` unbuildableHere]
                    , BP.relTools = []
                    , BP.relSetup = []
                    }
              )
            | (p, pk) <- world
            , r <- pkgReleases pk
            ]

    readRelease p v =
        maybe (Left (missing p v)) Right (Map.lookup (p, v) releases)

    missing p v =
        ParseException (toException (userError ("not in world: " <> show (p, v))))

-- | A guard at the declared defaults; an undeclared flag is 'False', as in
-- 'PubGrub.Cabal.Flatten'.
atDefaults :: [(FlagName, Bool)] -> Condition FlagName -> Bool
atDefaults defaults = go
  where
    go (Var f)    = fromMaybe False (lookup f defaults)
    go (Lit b)    = b
    go (CNot c)   = not (go c)
    go (COr a b)  = go a || go b
    go (CAnd a b) = go a && go b

worldProvider :: World -> Provider Cabal TestM
worldProvider = worldProviderUnder FlagPackages []

-- --------------------------------------------------------------------------
-- The monad the tests solve in
-- --------------------------------------------------------------------------

-- The solver and the provider rule take their log actions as arguments, so plain
-- 'IO' with both silenced ('mempty') is the whole harness.
type TestM = IO

runTestM :: TestM a -> IO a
runTestM = id

-- --------------------------------------------------------------------------
-- Running a world
-- --------------------------------------------------------------------------

root :: PackageName
root = pkg "root"

rootInstance :: Instance
rootInstance = BuildSource v1

-- | Run the solver and fold its flag decisions into their owners, so an answer
-- reads as a plan. A failure is kept as its rendered proof.
runSolve :: Provider Cabal TestM -> IO (Either Text (Map PackageName Resolved))
runSolve = runSolveWith []

-- | The same with further seeds after the request: constraints, in these tests.
runSolveWith :: [Incompatibility Cabal] -> Provider Cabal TestM -> IO (Either Text (Map PackageName Resolved))
runSolveWith seeds provider =
    either (Left . renderFailure) (Right . foldFlags)
        <$> runTestM (solve mempty provider (request root (singletonInstance rootInstance) : seeds))

renderFailure :: SolveError Cabal -> Text
renderFailure (NoSolution i) = reportConflict i
renderFailure (NoSatisfier p _) =
    T.pack ("internal error: no satisfier for " <> show p)

solveWorld :: World -> IO (Either Text (Map PackageName Resolved))
solveWorld = runSolve . worldProvider

solveWorldUnder :: FlagModel -> World -> IO (Either Text (Map PackageName Resolved))
solveWorldUnder model = runSolve . worldProviderUnder model []

solveWorldWith :: [(PackageName, Version)] -> World -> IO (Either Text (Map PackageName Resolved))
solveWorldWith unbuildableHere = runSolve . worldProviderUnder FlagPackages unbuildableHere

-- | Wrap a provider so that every @expand@ of a /package/ records it. The
-- solver asks exactly once per decision, so the tally counts decision attempts:
-- a package asked twice was reconsidered after a conflict. Flags are not
-- counted; they are decided with their owner and are not what these counts
-- measure.
countingProvider :: IORef [PackageName] -> Provider Cabal TestM -> Provider Cabal TestM
countingProvider ref provider = Provider $ \v range -> do
    case v of
        PackageVar p -> liftIO (modifyIORef' ref (p :))
        FlagVar{}    -> pure ()
    expand provider v range

solveCounting :: World -> IO (Either Text (Map PackageName Resolved), Map PackageName Int)
solveCounting world = do
    ref <- newIORef []
    result <- runSolve (countingProvider ref (worldProvider world))
    asked <- readIORef ref
    pure (result, Map.fromListWith (+) [(p, 1 :: Int) | p <- asked])

-- --------------------------------------------------------------------------
-- Notation
-- --------------------------------------------------------------------------

pkg :: String -> PackageName
pkg = mkPackageName

flg :: String -> FlagName
flg = mkFlagName

v1, v2 :: Version
v1 = V.mkVersion [1, 0, 0]
v2 = V.mkVersion [2, 0, 0]

dep :: PackageName -> Dependency
dep p = mkDependency p anyVersion mainLibSet

type Group = (Condition FlagName, [Dependency])

always :: [PackageName] -> Group
always deps = (Lit True, map dep deps)

whenOn, whenOff :: FlagName -> [PackageName] -> Group
whenOn f deps = (Var f, map dep deps)
whenOff f deps = (CNot (Var f), map dep deps)

leaf :: Pkg
leaf = Pkg [] [Release v1 []]

plain :: [PackageName] -> Pkg
plain deps = Pkg [] [Release v1 [always deps]]

-- | The expected plan, written as @(package, version, flags)@ triples.
solutionOf :: [(PackageName, Version, [(FlagName, Bool)])] -> Map PackageName Resolved
solutionOf entries =
    Map.fromList [(p, Built v (mkFlagAssignment fs)) | (p, v, fs) <- entries]

-- --------------------------------------------------------------------------
-- Tests
-- --------------------------------------------------------------------------

tests :: TestTree
tests =
    testGroup
        "Flags (end to end)"
        [ defaultsUsed
        , flagFlip
        , fixedFlagsDoNotFlip
        , heldFlag
        , preferenceTests
        , twoFlags
        , unsatOverFlags
        , unusedFlag
        , irrelevantFlagRetried
        , irrelevantFlagsDoNotCompound
        , newestKeptFlagFlipped
        , bootPackageStatesItself
        , unbuildableStatesItself
        , selfDependencyDropped
        ]

-- | 1. The declared default is offered first, so a world that solves at the
-- defaults solves with them: @speedy@ is in the plan and @slow@ and @neat@
-- are not.
defaultsUsed :: TestTree
defaultsUsed =
    testCase "declared defaults are used when they solve" $ do
        let fast = flg "fast"
            tidy = flg "tidy"
            world =
                [ (pkg "root", plain [pkg "foo", pkg "bar"])
                , (pkg "foo", Pkg [(fast, True)] [Release v1 [whenOn fast [pkg "speedy"], whenOff fast [pkg "slow"]]])
                , (pkg "bar", Pkg [(tidy, False)] [Release v1 [whenOn tidy [pkg "neat"]]])
                , (pkg "speedy", leaf)
                , (pkg "slow", leaf)
                , (pkg "neat", leaf)
                ]
        result <- solveWorld world
        result
            @?= Right
                ( solutionOf
                    [ (pkg "root", v1, [])
                    , (pkg "foo", v1, [(fast, True)])
                    , (pkg "bar", v1, [(tidy, False)])
                    , (pkg "speedy", v1, [])
                    ]
                )

-- | 2. The central case. @foo@ has exactly one version, so the version axis
-- offers the solver nothing: the only way out is to flip @fast@. Under the
-- default (@True@) @foo@ needs @speedy@, which does not exist; under @False@ it
-- needs @slow@, which does.
--
-- What has to happen: the guarded fact @{foo 1.0.0, foo:fast on, not speedy}@
-- becomes a conflict once @speedy@ is found empty, conflict resolution learns
-- @foo 1.0.0 with +fast is forbidden@, and the provider is asked about the flag
-- again with only @off@ admitted.
flagFlip :: TestTree
flagFlip =
    testCase "a flag flips when its default branch cannot be satisfied" $ do
        let fast = flg "fast"
            world =
                [ (pkg "root", plain [pkg "foo"])
                , (pkg "foo", Pkg [(fast, True)] [Release v1 [whenOn fast [pkg "speedy"], whenOff fast [pkg "slow"]]])
                , (pkg "slow", leaf)
                ]
        result <- solveWorld world
        result
            @?= Right
                ( solutionOf
                    [ (pkg "root", v1, [])
                    , (pkg "foo", v1, [(fast, False)])
                    , (pkg "slow", v1, [])
                    ]
                )

-- | 2b. The same world under 'FixedFlags' has no flip to make: every flag is at
-- its default, @speedy@ is required, and the world is unsatisfiable. This is
-- the knob the baseline comparison runs with by default.
fixedFlagsDoNotFlip :: TestTree
fixedFlagsDoNotFlip =
    testCase "under fixed flags the default branch is the only branch" $ do
        let fast = flg "fast"
            world =
                [ (pkg "root", plain [pkg "foo"])
                , (pkg "foo", Pkg [(fast, True)] [Release v1 [whenOn fast [pkg "speedy"], whenOff fast [pkg "slow"]]])
                , (pkg "slow", leaf)
                ]
        result <- solveWorldUnder FixedFlags world
        assertBool "expected no solution under fixed flags" (isLeft result)

-- | 3. Two flags, four total assignments, one viable: @a@ pulls in a package
-- that does not exist, and so does @b@, so only @-a -b@ survives.
twoFlags :: TestTree
twoFlags =
    testCase "two flags: the solver finds the one viable assignment" $ do
        let a = flg "a"
            b = flg "b"
            world =
                [ (pkg "root", plain [pkg "foo"])
                , (pkg "foo", Pkg [(a, True), (b, True)] [Release v1 [whenOn a [pkg "nope"], whenOn b [pkg "nope-either"], whenOff a [pkg "x"], whenOff b [pkg "y"]]])
                , (pkg "x", leaf)
                , (pkg "y", leaf)
                ]
        result <- solveWorld world
        result
            @?= Right
                ( solutionOf
                    [ (pkg "root", v1, [])
                    , (pkg "foo", v1, [(a, False), (b, False)])
                    , (pkg "x", v1, [])
                    , (pkg "y", v1, [])
                    ]
                )

-- | 4. Both values of the flag lead to a missing package. The proof must name
-- both branches, with the flag's sign, so a reader can see each was tried.
unsatOverFlags :: TestTree
unsatOverFlags =
    testCase "unsat over every value of a flag, and the proof names both" $ do
        let fast = flg "fast"
            world =
                [ (pkg "root", plain [pkg "foo"])
                , (pkg "foo", Pkg [(fast, True)] [Release v1 [whenOn fast [pkg "speedy"], whenOff fast [pkg "slow"]]])
                ]
        result <- solveWorld world
        assertBool "expected no solution" (isLeft result)
        let report = fromLeft T.empty result
        assertBool ("report should mention +fast; got:\n" <> T.unpack report) (T.pack "+fast" `T.isInfixOf` report)
        assertBool ("report should mention -fast; got:\n" <> T.unpack report) (T.pack "-fast" `T.isInfixOf` report)

-- | 5. A declared flag that no dependency guard mentions stays at its default,
-- and costs no package decision: with no conflict anywhere, the provider is
-- asked about each package exactly once.
unusedFlag :: TestTree
unusedFlag =
    testCase "a flag no dependency mentions stays at its default" $ do
        let unused = flg "unused"
            world =
                [ (pkg "root", plain [pkg "foo"])
                , (pkg "foo", Pkg [(unused, True)] [Release v1 [always [pkg "bar"]]])
                , (pkg "bar", leaf)
                ]
        (result, asks) <- solveCounting world
        result
            @?= Right
                ( solutionOf
                    [ (pkg "root", v1, [])
                    , (pkg "foo", v1, [(unused, True)])
                    , (pkg "bar", v1, [])
                    ]
                )
        asks @?= Map.fromList [(pkg "root", 1), (pkg "foo", 1), (pkg "bar", 1)]

-- | 5b. The guard against a @2^k@ regression. @foo 2.0.0@ is unusable for a
-- reason that has nothing to do with @unused@ (it needs a package that does not
-- exist), and @foo 1.0.0@ is fine. The dependency is unconditional, so its
-- clause names no flag and the ban conflict resolution learns is on the
-- /version/, for every value of @unused@ at once: @foo@ is expanded twice, the
-- dead version then the good one.
irrelevantFlagRetried :: TestTree
irrelevantFlagRetried =
    testCase "an irrelevant flag does not multiply a version-level retry" $ do
        let unused = flg "unused"
            world =
                [ (pkg "root", plain [pkg "foo"])
                , (pkg "foo", Pkg [(unused, True)] [Release v2 [always [pkg "gone"]], Release v1 [always [pkg "here"]]])
                , (pkg "here", leaf)
                ]
        (result, asks) <- solveCounting world
        result
            @?= Right
                ( solutionOf
                    [ (pkg "root", v1, [])
                    , (pkg "foo", v1, [(unused, True)])
                    , (pkg "here", v1, [])
                    ]
                )
        Map.lookup (pkg "foo") asks @?= Just 2

-- | 5c. The same with a /second/ irrelevant flag, which is what would turn the
-- cost into an exponent. The count is the same as with one flag, and the same
-- as with none.
irrelevantFlagsDoNotCompound :: TestTree
irrelevantFlagsDoNotCompound =
    testCase "two irrelevant flags cost no more than none" $ do
        let u1 = flg "u1"
            u2 = flg "u2"
            world =
                [ (pkg "root", plain [pkg "foo"])
                , (pkg "foo", Pkg [(u1, True), (u2, True)] [Release v2 [always [pkg "gone"]], Release v1 [always [pkg "here"]]])
                , (pkg "here", leaf)
                ]
        (result, asks) <- solveCounting world
        result
            @?= Right
                ( solutionOf
                    [ (pkg "root", v1, [])
                    , (pkg "foo", v1, [(u1, True), (u2, True)])
                    , (pkg "here", v1, [])
                    ]
                )
        Map.lookup (pkg "foo") asks @?= Just 2

-- | 6. A flag is decided under its release, so a conflict on the default value
-- flips the flag rather than retreating to an older release that would need no
-- flip: the newest release is kept, with @-fast@.
newestKeptFlagFlipped :: TestTree
newestKeptFlagFlipped =
    testCase "the newest release is kept and its flag flipped, rather than downgrading" $ do
        let fast = flg "fast"
            world =
                [ (pkg "root", plain [pkg "foo"])
                , (pkg "foo", Pkg [(fast, True)] [Release v2 [whenOn fast [pkg "speedy"], whenOff fast [pkg "slow"]], Release v1 [always [pkg "slow"]]])
                , (pkg "slow", leaf)
                ]
        result <- solveWorld world
        result
            @?= Right
                ( solutionOf
                    [ (pkg "root", v1, [])
                    , (pkg "foo", v2, [(fast, False)])
                    , (pkg "slow", v1, [])
                    ]
                )

-- | 7. Not about flags, but about the same provider rule and needing the same
-- harness: committing to an installed unit of a __non-reinstallable__ package also
-- states, once, that the package cannot be built from source.
--
-- The fixture is called @base@ because the rule keys on
-- 'PubGrub.Cabal.Installed.nonReinstallablePackages', a fixed list of the compiler's own
-- packages; @ordinary@ is the control.
bootPackageStatesItself :: TestTree
bootPackageStatesItself =
    testGroup
        "non-reinstallable packages"
        [ testCase "deciding one also states that it cannot be built from source" $ do
            incs <- runTestM (expandInstalled "base")
            case [p | Fact (CauseOnlyInstalled p _) <- map incompCause incs] of
                [p] -> p @?= mkPackageName "base"
                ps -> assertFailure ("expected one such fact, got " ++ show (length ps))
        , testCase "an ordinary installed package states no such thing" $ do
            incs <- runTestM (expandInstalled "ordinary")
            [() | Fact (CauseOnlyInstalled _ _) <- map incompCause incs] @?= []
        , -- The case with no decision to hang the fact on: the offered range holds
          -- no installed unit, so the rule has nothing to return, and it says why.
          testCase "a source-only range of one still says why" $ do
            (chosen, incs) <- runTestM (expandIn "base" sourceOnly)
            chosen @?= Nothing
            [p | Fact (CauseOnlyInstalled p _) <- map incompCause incs] @?= [mkPackageName "base"]
        , testCase "an ordinary package in the same position says nothing" $ do
            (chosen, incs) <- runTestM (expandIn "ordinary" sourceOnly)
            chosen @?= Nothing
            assertBool "expected no facts" (null incs)
        ]
  where
    expandInstalled name = do
        result <- expandIn name (everything name)
        case result of
            (Just (PackageValue (UsePreInstalled _)), incs) -> pure incs
            _ -> liftIO (assertFailure "expected the installed unit to be chosen")

    -- The real provider rule over a world with one installed unit of @name@ and no
    -- releases at all, asked about that package with @offered@ on the table.
    expandIn name offered =
        BP.mkExpand mempty BP.noPreference db source (PackageVar (mkPackageName name)) (instanceSet offered)
      where
        db =
            mkInstalledDb
                [ InstalledPkg
                    { ipUnitId = mkUnitId name
                    , ipName = mkPackageName name
                    , ipVersion = mkVersion [1, 0]
                    , ipDepends = []
                    }
                ]
        source =
            BP.ReleaseSource
                (const Set.empty)
                (\_ _ -> error "this world has no releases to read")

    -- Any source release, and no installed unit: the shape a range takes once a
    -- constraint has excluded the compiler's own copy.
    sourceOnly = sourceInstances VersionSet.fullVersionSet

    -- What the solver offers before it knows anything: the installed unit, or any
    -- source release.
    everything name =
        InstanceSet
            { isInstalled =
                Set.singleton
                    PreInstalledPackage
                        { pipUnitId = mkUnitId name
                        , pipVersion = V.mkVersion [1, 0]
                        , pipDependencies = []
                        }
            , isSource = VersionSet.fullVersionSet
            }

-- | 8. Also not about flags: a release whose library cannot be built in this
-- environment is __stated__ rather than silently passed over
-- (@references\/pubgrub.md:477@).
--
-- The world is unsatisfiable either way: @foo 2.0.0@ cannot be built and @foo
-- 1.0.0@ needs a package that has no versions. The verdicts agree; only the proof
-- changes.
unbuildableStatesItself :: TestTree
unbuildableStatesItself =
    testGroup
        "unbuildable releases"
        [ testCase "the proof says a release cannot be built, not that it is absent" $ do
            result <- solveWorldWith [(pkg "foo", v2)] world
            case result of
                Right sol -> assertFailure ("expected no solution, got " ++ show (Map.keys sol))
                Left proof -> do
                    assertBool
                        ("the proof should say foo is marked buildable: False:\n" <> T.unpack proof)
                        (T.pack "is marked buildable: False" `T.isInfixOf` proof)
                    assertBool
                        ("and should not report foo >=2.0.0 as empty:\n" <> T.unpack proof)
                        (not (T.pack "no version for foo in >=2" `T.isInfixOf` proof))
        , testCase "the same world solves when that release can be built" $ do
            result <- solveWorld world
            result @?= Right (solutionOf [(pkg "root", v1, []), (pkg "foo", v2, [])])
        , -- The offered range holds *nothing but* unbuildable releases, so the scan
          -- exhausts and there is no decision for the facts to ride out with. They
          -- are reported anyway ('expand' answers @(Nothing, facts)@).
          testCase "a range of only unbuildable releases still says why" $ do
            let onlyBad = [(pkg "foo", v2), (pkg "foo", v1)]
            result <- solveWorldWith onlyBad world
            case result of
                Right sol -> assertFailure ("expected no solution, got " ++ show (Map.keys sol))
                Left proof -> do
                    assertBool
                        ("the proof should still say foo is marked buildable: False:\n" <> T.unpack proof)
                        (T.pack "is marked buildable: False" `T.isInfixOf` proof)
                    assertBool
                        ("and must not call the unbuildable range empty:\n" <> T.unpack proof)
                        (not (T.pack "no version for foo in >=1" `T.isInfixOf` proof))
        , -- The fact itself, at the point it is minted: the scan passes 2.0.0,
          -- settles on 1.0.0, and hands both out together.
          testCase "the fact rides out with the release the scan settles on" $ do
            let provider = worldProviderUnder FlagPackages [(pkg "foo", v2)] world
            result <- runTestM (expand provider (PackageVar (pkg "foo")) (instanceSet (sourceInstances VersionSet.fullVersionSet)))
            case result of
                (Just (PackageValue (BuildSource v)), incs) -> do
                    v @?= v1
                    [p | Fact (CauseUnbuildable p _ _) <- map incompCause incs] @?= [pkg "foo"]
                _ -> assertFailure "expected 1.0.0 to be chosen"
        ]
  where
    world =
        [ (pkg "root", plain [pkg "foo"])
        , (pkg "foo", Pkg [] [Release v2 [], Release v1 [always [pkg "gone"]]])
        ]

-- | 9. Also not about flags: a release that declares a dependency on __itself__
-- must not produce a fact about its own package. It is an intra-package edge,
-- resolved inside the package, and dropping it is cabal's rule
-- (@Distribution.Solver.Modular.Builder.extendOpen@).
selfDependencyDropped :: TestTree
selfDependencyDropped =
    testGroup
        "self-dependencies"
        [ testCase "a release depending on itself states nothing about itself" $ do
            incs <- runTestM expandSelfDep
            [q | Fact (CauseDependency _ _ _ (q, _)) <- map incompCause incs, q == pkg "p"] @?= []
        , testCase "its other dependencies are still stated" $ do
            incs <- runTestM expandSelfDep
            [q | Fact (CauseDependency _ _ _ (q, _)) <- map incompCause incs] @?= [pkg "q"]
        , testCase "and the world still solves" $ do
            result <- solveWorld selfDepWorld
            result @?= Right (solutionOf [(pkg "root", v1, []), (pkg "p", v1, []), (pkg "q", v1, [])])
        ]
  where
    selfDepWorld =
        [ (pkg "root", plain [pkg "p"])
        , (pkg "p", Pkg [] [Release v1 [(Lit True, [depAt (pkg "p") v2, dep (pkg "q")])]])
        , (pkg "q", leaf)
        ]

    depAt p v = mkDependency p (thisVersion (V.toCabalVersion v)) mainLibSet

    expandSelfDep = do
        let provider = worldProviderUnder FlagPackages [] selfDepWorld
        result <- expand provider (PackageVar (pkg "p")) (instanceSet (sourceInstances VersionSet.fullVersionSet))
        case result of
            (Just (PackageValue (BuildSource _)), incs) -> pure incs
            _ -> liftIO (assertFailure "expected p 1.0.0 to be chosen")

-- | 2c. A flag held at a value by a constraint seed ('flagConstraint'), the
-- shape a lock entry's automatic flags take, and the one a flag constraint such
-- as @--constraint 'foo +fast'@ would take. Held at its default, @fast@ cannot
-- flip to escape the missing @speedy@, so the world of 'flagFlip' has no solution
-- and the proof says why; held at the other value, the solver never tries the
-- default at all.
heldFlag :: TestTree
heldFlag =
    testGroup
        "a flag held by a constraint"
        [ testCase "held at the default, the flip that would have rescued the world is forbidden" $ do
            result <- runSolveWith [flagConstraint (pkg "foo") (Flag fast True) True] (worldProvider world)
            assertBool "expected no solution" (isLeft result)
            let proof = fromLeft T.empty result
            assertBool ("proof names the constraint:\n" <> T.unpack proof) (T.pack "foo is constrained to +fast" `T.isInfixOf` proof)
        , testCase "held at the other value, the default is never tried" $ do
            result <- runSolveWith [flagConstraint (pkg "foo") (Flag fast False) False] (worldProvider world)
            result
                @?= Right
                    ( solutionOf
                        [ (pkg "root", v1, [])
                        , (pkg "foo", v1, [(fast, False)])
                        , (pkg "slow", v1, [])
                        ]
                    )
        ]
  where
    fast = flg "fast"
    world =
        [ (pkg "root", plain [pkg "foo"])
        , (pkg "foo", Pkg [(fast, True)] [Release v1 [whenOn fast [pkg "speedy"], whenOff fast [pkg "slow"]]])
        , (pkg "slow", leaf)
        ]

-- | 'BP.Preference': the main plan's choices, tried first when the offered set
-- admits them. A choice of value and never an incompatibility, so a preferred
-- release that cannot be built here, or that the index lacks, falls through to
-- the rule — installed first, then newest — with nothing lost.
preferenceTests :: TestTree
preferenceTests =
    testGroup
        "a preference is tried first"
        [ testCase "a preferred older release beats the newest" $ do
            result <- runSolve (preferring [(pkg "foo", (v1, Map.empty))] world)
            fmap (fmap versionOf . Map.lookup (pkg "foo")) result @?= Right (Just (Just v1))
        , testCase "a preferred release the index lacks changes nothing" $ do
            result <- runSolve (preferring [(pkg "foo", (V.mkVersion [9], Map.empty))] world)
            fmap (fmap versionOf . Map.lookup (pkg "foo")) result @?= Right (Just (Just v2))
        , testCase "a preferred release that cannot be built here falls through, and says why" $ do
            result <- runSolveWith [] (worldProviderUnderPreferring (preferring' [(pkg "foo", (v1, Map.empty))]) [(pkg "foo", v1)] world)
            fmap (fmap versionOf . Map.lookup (pkg "foo")) result @?= Right (Just (Just v2))
        , testCase "a preferred flag value beats the declared default" $ do
            result <- runSolve (preferring [(pkg "flagged", (v1, Map.fromList [(fast, False)]))] flagWorld)
            result
                @?= Right
                    ( solutionOf
                        [ (pkg "root", v1, [])
                        , (pkg "flagged", v1, [(fast, False)])
                        , (pkg "slow", v1, [])
                        ]
                    )
        ]
  where
    fast = flg "fast"
    -- foo has two releases and nothing forces either.
    world =
        [ (pkg "root", plain [pkg "foo"])
        , (pkg "foo", Pkg [] [Release v1 [], Release v2 []])
        ]
    -- Either value of the flag resolves; the default is True.
    flagWorld =
        [ (pkg "root", plain [pkg "flagged"])
        , (pkg "flagged", Pkg [(fast, True)] [Release v1 [whenOn fast [pkg "speedy"], whenOff fast [pkg "slow"]]])
        , (pkg "speedy", leaf)
        , (pkg "slow", leaf)
        ]
    preferring' prefs p = lookup p prefs
    versionOf (Built v _) = Just v
    versionOf Installed{} = Nothing
    preferring prefs = worldProviderUnderPreferring (preferring' prefs) []
