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
import           Data.List.NonEmpty             (nonEmpty)
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Distribution.Types.Condition   (Condition (..))
import           Distribution.Types.Dependency  (Dependency, mainLibSet,
                                                 mkDependency)
import           Distribution.Types.Flag        (FlagName, mkFlagAssignment,
                                                 mkFlagName)
import           Distribution.Types.PackageName (PackageName, mkPackageName)
import           Distribution.Types.Version     (Version, mkVersion)
import           Distribution.Version           (anyVersion)
import           PubGrub.InstanceSet            (Instance (BuildSource))
import           PubGrub.Provider               (Provider (Provider, expand))
import           PubGrub.Report                 (reportConflict)
import           PubGrub.Solver                 (SolveError (..), SolverMsg,
                                                 solve)
import           Test.Tasty                     (TestTree, testGroup)
import           Test.Tasty.HUnit               (assertBool, testCase, (@?=))

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
--  * the world's root is an ordinary release rather than 'BP.rootName', so the
--    synthetic-root shortcut never fires and the root is resolved through the same
--    path as every other package. Hence the empty target list.
--
-- The installed db is empty: these worlds have no pre-installed units, so every
-- 'PubGrub.InstanceSet.InstanceSet' has an empty installed side.
worldProvider :: World -> Provider TestM
worldProvider world =
    Provider (BP.mkExpand (mkInstalledDb []) source [])
  where
    source =
        BP.ReleaseSource
            { BP.rsVersionsOf = \p -> maybe [] (map relVersion . pkgReleases) (lookup p world)
            , BP.rsReadRelease = \p v -> pure (readRelease p v)
            }

    -- Every release of every package, in the reduced shape the bridge expects:
    -- the package's declared flags, and this release's guarded dependency groups.
    releases :: Map (PackageName, Version) BP.Release
    releases =
        Map.fromList
            [ ((p, relVersion r), BP.Release (pkgFlags pk) (relGuarded r))
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

-- | The root package, whose sole release is @1.0.0@ with no flags. Deliberately
-- /not/ 'BP.rootName': see 'worldProvider'.
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
        <$> runTestM (solve provider root rootInstance)

renderFailure :: SolveError -> Text
renderFailure (NoSolution i) = reportConflict i
renderFailure (NoSatisfier p _) =
    T.pack ("internal error: no satisfier for " <> show p)

solveWorld :: World -> IO (Either Text (Map PackageName Instance))
solveWorld = runSolve . worldProvider

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
v1 = mkVersion [1, 0, 0]
v2 = mkVersion [2, 0, 0]

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
        ]

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
