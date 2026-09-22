{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}

-- | End-to-end solver tests in which /flags/ are the interesting axis.
--
-- 'SolverSpec' and 'PaperSpec' both build every 'Instance' at
-- @mkFlagAssignment []@, so the search over flag assignments never runs there.
-- The algebra of flag pins is covered by @InstanceSetSpec@ and the @.cabal@
-- flattening by @FlattenSpec@; what this module adds is the loop that closes
-- over the two: the solver learning "not this assignment" and the provider
-- coming back with a different one.
--
-- These tests run the __real__ provider. 'Bridge.Provider.mkExpand' is the whole
-- rule — candidate enumeration, flag completion, the fewest-deviations
-- preference, and incompatibility emission — and it takes its world as arguments,
-- so 'worldProvider' feeds it an in-memory index instead of Hackage. Nothing about
-- the rule is restated here: a paraphrase of the rule can only ever test the
-- paraphrase.
--
-- What the worlds supply is the /data/: which packages and versions exist,
-- which flags each declares, and its dependencies as flag-guarded groups (the toy
-- analogue of @Bridge.Cabal.Flatten.GuardedDeps@). A package absent from the world
-- has no versions at all, which is how these tests write an unsatisfiable
-- dependency.
--
-- A non-default assignment is tried only after the solver has learned an
-- incompatibility that pins the flag the other way, which is what makes flags a
-- search dimension rather than a constant.
module FlagSolveSpec (tests) where

import           Bridge.Cabal.InstalledPkg      (InstalledPkg (..))
import           Bridge.Hackage                 (ParseError (..))
import           Bridge.Installed               (mkInstalledDb)
import qualified Bridge.Provider                as BP
import           Colog                          (HasLog (..), LogAction)
import           Control.Exception              (toException)
import           Control.Monad.IO.Class         (MonadIO, liftIO)
import           Control.Monad.Reader           (MonadReader, ReaderT,
                                                 runReaderT)
import           Data.Either                    (fromLeft, isLeft)
import           Data.IORef                     (IORef, modifyIORef', newIORef,
                                                 readIORef)
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
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
import           PubGrub.Incompatibility        (IncompatCause (..), request,
                                                 Incompatibility (..),
                                                 UnbuildableReason (..))
import           PubGrub.Index.PreInstalled     (PreInstalledPackage (..))
import           PubGrub.InstanceSet            (Instance (..),
                                                 InstanceSet (..),
                                                 singletonInstance)
import           PubGrub.InstanceSet.SourceCell (SourceCell (..))
import           PubGrub.Provider               (Provider (Provider, expand))
import           PubGrub.Version                (Version)
import qualified PubGrub.Version                as V
import           PubGrub.Report                 (reportConflict)
import           PubGrub.Solver                 (SolveError (..), SolverMsg,
                                                 solve)
import qualified PubGrub.VersionSet             as VersionSet
import           Test.Tasty                     (TestTree, testGroup)
import           Test.Tasty.HUnit               (assertBool, assertFailure,
                                                 testCase, (@?=))

-- --------------------------------------------------------------------------
-- A toy world with flags
-- --------------------------------------------------------------------------

-- | One source release: a version, and its dependencies as /flag-guarded groups/
-- — the toy stand-in for @Bridge.Cabal.Flatten.GuardedDeps@, which is what a
-- @.cabal@ file's conditional tree flattens to.
--
-- The guard is kept as a real 'Condition' rather than collapsed to a predicate on
-- assignments, because the guard is what the emitted incompatibility names: a
-- release that declares @simd@ and @docs@ but guards a dependency on @simd@ alone
-- must produce a depender term mentioning @simd@ and /not/ @docs@. A
-- @FlagAssignment -> [dep]@ function cannot express that: it answers only yes or
-- no at one assignment, so every assignment of an irrelevant flag would have to
-- be refuted on its own.
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

-- | The provider for a world: the /real/ 'BP.mkExpand', driven from an in-memory
-- index built out of the world. Two departures from a Hackage-backed run, neither
-- touching the rule:
--
--  * the 'BP.ReleaseSource' answers from a list rather than from an index, so no
--    @.cabal@ is ever parsed.
--  * the world's root is an ordinary release, seeded as the one request, so it
--    is resolved through the same path as every other package.
--
-- The installed db is empty: these worlds have no pre-installed units, so every
-- 'PubGrub.InstanceSet.InstanceSet' has an empty installed side.
worldProvider :: World -> Provider TestM
worldProvider = worldProviderWith []

-- | The same, with some releases marked as impossible to build /here/.
--
-- Buildability is named beside the world rather than inside 'Release' because in
-- the bridge it is not part of a release's dependency data either:
-- @Bridge.Provider.relUnbuildable@ is as much a verdict about this machine
-- (@pkgconfig-depends@ against the real @pkg-config@ db) as about the @.cabal@
-- (@buildable: False@). It is also the one thing these fixtures cannot express by
-- writing guarded groups, since both inputs are read off a @BuildInfo@ they do not
-- have. The reason given is @buildable: False@; which reason it is does not matter
-- to the rule under test here, and the wording of each is @ReportSpec@'s.
worldProviderWith :: [(PackageName, Version)] -> World -> Provider TestM
worldProviderWith unbuildableHere world =
    Provider (BP.mkExpand (mkInstalledDb []) source)
  where
    source =
        BP.ReleaseSource
            { BP.rsVersionsOf = \p ->
                maybe Set.empty (Set.fromList . map relVersion . pkgReleases) (lookup p world)
            , BP.rsReadRelease = \p v -> pure (readRelease p v)
            }

    -- Every release of every package, in the reduced shape the bridge expects:
    -- the package's declared flags, this release's guarded dependency groups, and
    -- why its library cannot be built here, if it cannot.
    releases :: Map (PackageName, Version) BP.Release
    releases =
        Map.fromList
            [ ( (p, relVersion r)
              , BP.Release
                    (pkgFlags pk)
                    (relGuarded r)
                    [NotBuildable | (p, relVersion r) `elem` unbuildableHere]
              )
            | (p, pk) <- world
            , r <- pkgReleases pk
            ]

    -- 'BP.mkExpand' only ever asks about versions @rsVersionsOf@ reported, so the
    -- miss branch is unreachable; it answers with a parse failure rather than an
    -- 'error' so a future wiring bug degrades into a skipped release instead of a
    -- crash.
    readRelease p v =
        maybe (Left (missing p v)) Right (Map.lookup (p, v) releases)

    missing p v =
        ParseException (toException (userError ("not in world: " <> show (p, v))))

-- --------------------------------------------------------------------------
-- The monad the tests solve in
-- --------------------------------------------------------------------------

-- | Two log channels, because the pieces being composed want different message
-- types: 'solve' emits 'SolverMsg' and the bridge emits 'Text'. This mirrors the
-- application monad in @app\/Main.hs@, with both channels discarded.
data TestEnv = TestEnv
    { teText   :: LogAction TestM Text
    , teSolver :: LogAction TestM SolverMsg
    }

newtype TestM a = TestM {unTestM :: ReaderT TestEnv IO a}
    deriving newtype (Functor, Applicative, Monad, MonadIO, MonadReader TestEnv)

instance HasLog TestEnv Text TestM where
    getLogAction = teText
    setLogAction a e = e {teText = a}

instance HasLog TestEnv SolverMsg TestM where
    getLogAction = teSolver
    setLogAction a e = e {teSolver = a}

runTestM :: TestM a -> IO a
runTestM m = runReaderT (unTestM m) (TestEnv mempty mempty)

-- --------------------------------------------------------------------------
-- Running a world
-- --------------------------------------------------------------------------

-- | The root package, whose sole release is @1.0.0@ with no flags. An ordinary
-- package of the world that the solve is seeded with: see 'worldProvider'.
root :: PackageName
root = pkg "root"

rootInstance :: Instance
rootInstance = BuildSource v1 (mkFlagAssignment [])

-- | Run the solver, discarding both log channels. A failure is kept as its
-- rendered proof rather than 'show'n: the derived 'Show' would expand the whole
-- derivation DAG.
runSolve :: Provider TestM -> IO (Either Text (Map PackageName Instance))
runSolve provider =
    either (Left . renderFailure) Right
        <$> runTestM (solve provider [request root (singletonInstance rootInstance)])

renderFailure :: SolveError -> Text
renderFailure (NoSolution i) = reportConflict i
renderFailure (NoSatisfier p _) =
    T.pack ("internal error: no satisfier for " <> show p)

solveWorld :: World -> IO (Either Text (Map PackageName Instance))
solveWorld = runSolve . worldProvider

-- | Solve a world in which the named releases cannot be built here.
solveWorldWith
    :: [(PackageName, Version)] -> World -> IO (Either Text (Map PackageName Instance))
solveWorldWith unbuildableHere = runSolve . worldProviderWith unbuildableHere

-- | Wrap a provider so that every @expand@ records the package it was asked
-- about. The solver asks exactly once per decision, so the tally counts
-- decision /attempts/: a package asked twice was reconsidered after a conflict.
countingProvider :: IORef [PackageName] -> Provider TestM -> Provider TestM
countingProvider ref provider = Provider $ \p range -> do
    liftIO (modifyIORef' ref (p :))
    expand provider p range

-- | Solve, and also report how many times each package was expanded.
solveCounting :: World -> IO (Either Text (Map PackageName Instance), Map PackageName Int)
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

-- | An unconstrained dependency on a package's main library. These worlds are
-- about flags, so no test needs a narrower range than "any version".
dep :: PackageName -> Dependency
dep p = mkDependency p anyVersion mainLibSet

-- | One guarded dependency group, the toy analogue of a @.cabal@ conditional
-- block. @always@ is the unconditional block every component has — its guard is
-- literally @Lit True@, which is a real guard and not the absence of one.
type Group = (Condition FlagName, [Dependency])

always :: [PackageName] -> Group
always deps = (Lit True, map dep deps)

-- | @if flag(f)@ / @else@ — the two branches a single flag produces.
whenOn, whenOff :: FlagName -> [PackageName] -> Group
whenOn f deps = (Var f, map dep deps)
whenOff f deps = (CNot (Var f), map dep deps)

-- | A flagless package with a single release at @1.0.0@ and no dependencies.
leaf :: Pkg
leaf = Pkg [] [Release v1 []]

-- | A flagless package with a single release at @1.0.0@ and fixed dependencies.
plain :: [PackageName] -> Pkg
plain deps = Pkg [] [Release v1 [always deps]]

-- | The expected decision map, written as @(package, version, flags)@ triples.
solutionOf :: [(PackageName, Version, [(FlagName, Bool)])] -> Map PackageName Instance
solutionOf entries =
    Map.fromList [(p, BuildSource v (mkFlagAssignment fs)) | (p, v, fs) <- entries]

-- --------------------------------------------------------------------------
-- Tests
-- --------------------------------------------------------------------------

tests :: TestTree
tests =
    testGroup
        "Flags (end to end)"
        [ defaultsUsed
        , flagFlip
        , twoFlags
        , unsatOverFlags
        , unusedFlag
        , irrelevantFlagRetried
        , irrelevantFlagsDoNotCompound
        , bootPackageStatesItself
        , unbuildableStatesItself
        , selfDependencyDropped
        ]

-- | 8. Not about flags, but about the same provider rule and needing the same
-- harness: committing to an installed unit of a __non-reinstallable__ package also
-- states, once, that the package cannot be built from source.
--
-- Without that standing fact the solver rediscovers it one range at a time — every
-- range of @base@ containing no installed unit costs a decision, a provider call
-- answering 'Nothing' and a fresh @noInstances@ clause naming that range. On
-- @aeson \'<2\'@ that happened five times over five ranges (@docs\/STATUS.md@,
-- "Where the no-version events came from").
--
-- The fixture is called @base@ because the rule keys on
-- 'Bridge.Installed.nonReinstallablePackages', a fixed list of the compiler's own
-- packages; @ordinary@ is the control.
bootPackageStatesItself :: TestTree
bootPackageStatesItself =
    testGroup
        "non-reinstallable packages"
        [ testCase "deciding one also states that it cannot be built from source" $ do
            incs <- runTestM (expandInstalled "base")
            case [p | CauseOnlyInstalled p _ <- map incompCause incs] of
                [p] -> p @?= mkPackageName "base"
                ps -> assertFailure ("expected one such fact, got " ++ show (length ps))
        , testCase "an ordinary installed package states no such thing" $ do
            incs <- runTestM (expandInstalled "ordinary")
            [() | CauseOnlyInstalled _ _ <- map incompCause incs] @?= []
        , -- The case with no decision to hang the fact on. The offered range holds
          -- The case with no decision to hang the fact on. The offered range holds
          -- no installed unit, so the rule has nothing to return; without a
          -- /reason/ the solver would state that the range is empty. On
          -- @lens \'<4\'@ three of the four no-version events were this, every one
          -- of them before @base@ was first decided, and each reached the proof as
          -- \"no version for base in …\" about a range full of real releases.
          testCase "a source-only range of one still says why" $ do
            (chosen, incs) <- runTestM (expandIn "base" sourceOnly)
            chosen @?= Nothing
            [p | CauseOnlyInstalled p _ <- map incompCause incs] @?= [mkPackageName "base"]
        , testCase "an ordinary package in the same position says nothing" $ do
            (chosen, incs) <- runTestM (expandIn "ordinary" sourceOnly)
            chosen @?= Nothing
            assertBool "expected no facts" (null incs)
        ]
  where
    expandInstalled name = do
        result <- expandIn name (everything name)
        case result of
            (Just (UsePreInstalled _), incs) -> pure incs
            _ -> liftIO (assertFailure "expected the installed unit to be chosen")

    -- The real provider rule over a world with one installed unit of @name@ and no
    -- releases at all, asked about that package with @offered@ on the table. The
    -- reader errors because nothing here should reach it: a non-reinstallable
    -- package never consults the source side, and @ordinary@ has no versions.
    expandIn name offered =
        BP.mkExpand db source (mkPackageName name) offered
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
    sourceOnly =
        InstanceSet
            { isInstalled = Set.empty
            , isSource = [SourceCell VersionSet.fullVersionSet Map.empty]
            }

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
            , isSource = [SourceCell VersionSet.fullVersionSet Map.empty]
            }

-- | 9. Also not about flags: a release whose library cannot be built in this
-- environment is __stated__ rather than silently passed over
-- (@references\/pubgrub.md:477@ — "we just add an incompatibility indicating that
-- it […] should never be selected").
--
-- The difference is entirely in the explanation, which is why it is asserted on the
-- rendered proof. Skipping the release quietly leaves the solver to find out that
-- the range above @1.0.0@ is empty, and it reports what it found: /no version for
-- foo in >=2/. That is false-sounding — the version exists, and the reason it may
-- not be used is local to this machine. With the fact stated, the same range is
-- contradicted by a clause that says so, and the proof line is the reason.
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
                    -- "No version for foo in <1.0.0" may still be there, and is
                    -- /true/ — nothing is published below the oldest release — but
                    -- the range holding 2.0.0 must not be reported as if it were
                    -- empty.
                    assertBool
                        ("and should not report foo >=2.0.0 as empty:\n" <> T.unpack proof)
                        (not (T.pack "no version for foo in >=2" `T.isInfixOf` proof))
        , -- The control, and the reason the verdict is not merely a coincidence of
          -- the fixture: with every release buildable the same world /solves/, on
          -- the very release the other case rules out.
          testCase "the same world solves when that release can be built" $ do
            result <- solveWorld world
            result
                @?= Right
                    ( solutionOf
                        [ (pkg "root", v1, [])
                        , (pkg "foo", v2, [])
                        ]
                    )
        , -- The case the fact used to be dropped in, and the one that actually
          -- The case that occurs on Hackage: the offered range holds *nothing
          -- but* unbuildable releases, so the scan exhausts and there is no
          -- decision for the facts to ride out with. They are reported anyway
          -- ('expand' answers @(Nothing, facts)@): `hpqtypes >=1.13` is three
          -- releases all needing libpq, and without the facts the proof says the
          -- range is empty when the releases exist and cannot be built.
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
        , -- And the fact itself, at the point it is minted: the scan passes 2.0.0,
          -- settles on 1.0.0, and hands both out together — an incompatibility need
          -- not be about the instance just decided.
          testCase "the fact rides out with the release the scan settles on" $ do
            let provider = worldProviderWith [(pkg "foo", v2)] world
            result <- runTestM (expand provider (pkg "foo") anyInstance)
            case result of
                (Just (BuildSource v _), incs) -> do
                    v @?= v1
                    [p | CauseUnbuildable p _ _ <- map incompCause incs] @?= [pkg "foo"]
                _ -> assertFailure "expected 1.0.0 to be chosen"
        ]
  where
    -- foo 2.0.0 has no dependencies at all, so nothing but buildability can rule it
    -- out; foo 1.0.0 depends on a package with no versions.
    world =
        [ (pkg "root", plain [pkg "foo"])
        ,
            ( pkg "foo"
            , Pkg
                []
                [ Release v2 []
                , Release v1 [always [pkg "gone"]]
                ]
            )
        ]

    -- Everything on offer, as the solver offers it before it knows anything. No
    -- installed side: these worlds have no pre-installed units.
    anyInstance =
        InstanceSet
            { isInstalled = Set.empty
            , isSource = [SourceCell VersionSet.fullVersionSet Map.empty]
            }

-- | 1. When the declared defaults already solve, they are what gets decided —
-- for both polarities of default, so this cannot pass by accident with a
-- provider that always says @True@ (or always @False@).
defaultsUsed :: TestTree
defaultsUsed =
    testCase "declared defaults are used when they solve" $ do
        let fast = flg "fast"
            tidy = flg "tidy"
            world =
                [ (pkg "root", plain [pkg "foo", pkg "bar"])
                ,
                    ( pkg "foo"
                    , Pkg
                        [(fast, True)]
                        [Release v1 [whenOn fast [pkg "speedy"], whenOff fast [pkg "slow"]]]
                    )
                ,
                    ( pkg "bar"
                    , Pkg
                        [(tidy, False)]
                        [Release v1 [whenOn tidy [pkg "neat"]]]
                    )
                , (pkg "speedy", leaf)
                , (pkg "slow", leaf)
                , (pkg "neat", leaf)
                ]
        -- The assertion is on the whole solution, so it pins down not just the
        -- assignments but that the /dependencies/ came from the default branch:
        -- @speedy@ is in the plan and @slow@ and @neat@ are not.
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
-- For this to pass, conflict resolution must derive
-- @foo ==1.0.0+fast is forbidden@, and subtracting that singleton from @foo@'s
-- accumulated range must leave a cell @==1.0.0 -fast@ (the pin-escape route of
-- 'PubGrub.InstanceSet.SourceCell.differenceCell'), which the provider then
-- completes back into a total assignment.
flagFlip :: TestTree
flagFlip =
    testCase "a flag flips when its default branch cannot be satisfied" $ do
        let fast = flg "fast"
            world =
                [ (pkg "root", plain [pkg "foo"])
                ,
                    ( pkg "foo"
                    , Pkg
                        [(fast, True)]
                        [Release v1 [whenOn fast [pkg "speedy"], whenOff fast [pkg "slow"]]]
                    )
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

-- | 3. Two flags, four total assignments, one viable: @a@ pulls in a package
-- that does not exist, and so does @b@, so only @-a -b@ survives. The solver
-- has to rule out three assignments of the same single version before it gets
-- there.
twoFlags :: TestTree
twoFlags =
    testCase "two flags: the solver finds the one viable assignment" $ do
        let a = flg "a"
            b = flg "b"
            world =
                [ (pkg "root", plain [pkg "foo"])
                ,
                    ( pkg "foo"
                    , Pkg
                        [(a, True), (b, True)]
                        [ Release
                            v1
                            [ whenOn a [pkg "needs-a"]
                            , whenOn b [pkg "needs-b"]
                            , always [pkg "always"]
                            ]
                        ]
                    )
                , (pkg "always", leaf)
                ]
        result <- solveWorld world
        result
            @?= Right
                ( solutionOf
                    [ (pkg "root", v1, [])
                    , (pkg "foo", v1, [(a, False), (b, False)])
                    , (pkg "always", v1, [])
                    ]
                )

-- | 4. Unsatisfiable over the flag: /both/ branches need a package that does
-- not exist, so no assignment of @fast@ works and @foo@ has only the one
-- version. The report has to name the flag, or the proof would read as if two
-- unrelated facts about the same @foo 1.0.0@ contradicted each other. The
-- assertions look for @+fast@ and @-fast@, which is how a flag pin prints.
unsatOverFlags :: TestTree
unsatOverFlags =
    testCase "unsat over every assignment of a flag" $ do
        let fast = flg "fast"
            world =
                [ (pkg "root", plain [pkg "foo"])
                ,
                    ( pkg "foo"
                    , Pkg
                        [(fast, True)]
                        [Release v1 [whenOn fast [pkg "speedy"], whenOff fast [pkg "slow"]]]
                    )
                ]
        result <- solveWorld world
        assertBool "expected no solution" (isLeft result)
        let report = fromLeft T.empty result
        assertBool
            ("report should mention +fast; got:\n" <> T.unpack report)
            (T.pack "+fast" `T.isInfixOf` report)
        assertBool
            ("report should mention -fast; got:\n" <> T.unpack report)
            (T.pack "-fast" `T.isInfixOf` report)

-- | 5. A declared flag that no dependency guard mentions stays at its default,
-- and costs nothing: with no conflict anywhere, the provider is asked about each
-- package exactly once. That is the payoff of the provider committing to a
-- /total/ assignment per ask — flags are not enumerated up front, so a package
-- with an unused flag is not two candidates.
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

-- | 5b. An irrelevant flag does not multiply a version-level retry.
--
-- Here @foo 2.0.0@ is unusable for a reason that has nothing to do with @unused@
-- (it needs a package that does not exist), and @foo 1.0.0@ is fine. Because the
-- dependency is /unconditional/, its guard is @Lit True@ and the depender term is
-- @==2.0.0@ with no flag pins at all — so conflict resolution learns
-- @foo ==2.0.0 is forbidden@ for every assignment of @unused@ at once, and
-- @==2.0.0 -unused@ is never offered. @foo@ is expanded twice: the dead version,
-- then the good one.
--
-- **The count below is the assertion.** If it rises to 3, the depender has become
-- the decided instance instead of the guard's region: what is learned is then
-- @foo ==2.0.0+unused is forbidden@, one /instance/ rather than the version, and
-- each of the @2^(irrelevant flags)@ assignments is tried and rejected in turn.
irrelevantFlagRetried :: TestTree
irrelevantFlagRetried =
    testCase "an irrelevant flag does not multiply a version-level retry" $ do
        let unused = flg "unused"
            world =
                [ (pkg "root", plain [pkg "foo"])
                ,
                    ( pkg "foo"
                    , Pkg
                        [(unused, True)]
                        [ Release v2 [always [pkg "gone"]]
                        , Release v1 [always [pkg "here"]]
                        ]
                    )
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
        -- foo: 2.0.0+unused, then 1.0.0+unused. The banned version is banned
        -- outright, not one assignment at a time.
        Map.lookup (pkg "foo") asks @?= Just 2

-- | 5c. The same world as 5b with a /second/ irrelevant flag, which is what would
-- turn the cost into an exponent rather than a constant.
--
-- With the decided instance as the depender, the dead version would be rejected
-- once per assignment of the flags no guard mentions: @2^k@ times, four here,
-- before @1.0.0@ is reached. With the guard's region as the depender, the ban on
-- @==2.0.0@ mentions no flag at all, so the count is **the same as with one
-- irrelevant flag, and the same as with none**: the dead version, then the good
-- one.
--
-- 5b alone cannot tell a fixed cost from a smaller exponent; this case shows the
-- cost does not scale with @k@.
irrelevantFlagsDoNotCompound :: TestTree
irrelevantFlagsDoNotCompound =
    testCase "two irrelevant flags cost no more than none" $ do
        let u1 = flg "u1"
            u2 = flg "u2"
            world =
                [ (pkg "root", plain [pkg "foo"])
                ,
                    ( pkg "foo"
                    , Pkg
                        [(u1, True), (u2, True)]
                        [ Release v2 [always [pkg "gone"]]
                        , Release v1 [always [pkg "here"]]
                        ]
                    )
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

-- | 10. Also not about flags: a release that declares a dependency on __itself__
-- must not produce a fact about its own package.
--
-- Real packages do this constantly — an executable or a sublibrary of @p@ is built
-- against @p@\'s library, so @p@\'s flattened dependencies contain @p@. That is an
-- /intra-package/ edge, resolved inside the package, and it is not a version
-- constraint on @p@ at all.
--
-- Stated as a fact it says something far stronger and false. The depender and the
-- dependee are the same variable, so the clause collapses to a bare requirement:
-- @lens 1.7@\'s @lens ==1.7@ becomes @{lens: Negative ==1.7}@ — \"lens must be
-- exactly 1.7\" — asserted of every instance of @lens@, which pins an entire
-- solve to one release and is the unexplained first premise of its proof.
--
-- __Dropping it is cabal\'s rule.__
-- @Distribution.Solver.Modular.Builder.extendOpen@ matches @qpn == qpn\'@ and adds
-- no goal and no edge, except for a setup dependency where it adds a
-- reverse-dependency edge alone. Qualified goals would not subsume this: library
-- dependencies inherit their depender\'s qualifier (@qualifyDeps@), so an
-- executable\'s dependency on its own library is a self-dependency under any
-- qualifier scheme.
--
-- The world is the smallest one that shows it: @p 1.0.0@ depends on itself at a
-- version it is not, plus a real dependency. Both must hold — the self-dependency
-- silent, the real one stated — because dropping too much is as wrong as stating
-- too much.
selfDependencyDropped :: TestTree
selfDependencyDropped =
    testGroup
        "self-dependencies"
        [ testCase "a release depending on itself states nothing about itself" $ do
            incs <- runTestM expandSelfDep
            [q | CauseDependency _ _ (q, _) <- map incompCause incs, q == pkg "p"] @?= []
        , testCase "its other dependencies are still stated" $ do
            incs <- runTestM expandSelfDep
            [q | CauseDependency _ _ (q, _) <- map incompCause incs] @?= [pkg "q"]
        , testCase "and the world still solves" $ do
            result <- solveWorld selfDepWorld
            result @?= Right (solutionOf [(root, v1, []), (pkg "p", v1, []), (pkg "q", v1, [])])
        ]
  where
    -- @p 1.0.0@ depends on @p ==2.0.0@ (which it is not) and on @q@.
    selfDepWorld =
        [ (root, plain [pkg "p"])
        ,
            ( pkg "p"
            , Pkg [] [Release v1 [(Lit True, [dep (pkg "q"), depAt (pkg "p") v2])]]
            )
        , (pkg "q", leaf)
        ]

    depAt p v = mkDependency p (thisVersion (V.toCabalVersion v)) mainLibSet

    -- The real provider rule, asked to expand @p@ with everything on offer.
    expandSelfDep = do
        let source =
                BP.ReleaseSource
                    { BP.rsVersionsOf = \p ->
                        maybe Set.empty (Set.fromList . map relVersion . pkgReleases) (lookup p selfDepWorld)
                    , BP.rsReadRelease = \p v ->
                        pure
                            ( maybe
                                (Left (ParseException (toException (userError "not in world"))))
                                Right
                                (Map.lookup (p, v) reduced)
                            )
                    }
            reduced =
                Map.fromList
                    [ ((p, relVersion r), BP.Release (pkgFlags pk) (relGuarded r) [])
                    | (p, pk) <- selfDepWorld
                    , r <- pkgReleases pk
                    ]
        result <- BP.mkExpand (mkInstalledDb []) source (pkg "p") anySource
        case result of
            (Just (BuildSource _ _), incs) -> pure incs
            _ -> liftIO (assertFailure "expected p 1.0.0 to be chosen")

    anySource =
        InstanceSet
            { isInstalled = Set.empty
            , isSource = [SourceCell VersionSet.fullVersionSet Map.empty]
            }
