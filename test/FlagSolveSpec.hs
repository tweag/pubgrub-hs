-- | End-to-end solver tests in which /flags/ are the interesting axis.
--
-- 'SolverSpec' and 'PaperSpec' both build every 'Instance' at
-- @mkFlagAssignment []@, so the search over flag assignments never runs there.
-- The algebra of flag pins is covered by @InstanceSetSpec@ and the @.cabal@
-- flattening by @FlattenSpec@; what this module adds is the loop that closes
-- over the two: the solver learning "not this assignment" and the provider
-- coming back with a different one.
--
-- The toy provider imitates 'Bridge.Provider.mkExpand' rather than inventing
-- its own rule, because that rule /is/ the thing under test:
--
--  * enumerate the package's own versions, newest first (an 'InstanceSet' is
--    symbolic and cannot be enumerated, so candidates come from the world);
--  * for each 'SourceCell' of the offered set that contains that version, derive
--    a /total/ assignment: the cell's pins, plus every remaining declared flag
--    at its default;
--  * keep that candidate only if 'memberInstance' accepts it, and compute the
--    dependencies at exactly that assignment.
--
-- So a non-default assignment is tried only after the solver has learned an
-- incompatibility that pins the flag the other way, which is what makes flags
-- a search dimension rather than a constant.
module FlagSolveSpec (tests) where

import           Colog                          (LoggerT, usingLoggerT)
import           Control.Monad.IO.Class          (liftIO)
import           Data.Either                    (isLeft)
import           Data.IORef                     (IORef, modifyIORef', newIORef,
                                                 readIORef)
import           Data.List                       (sortOn)
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Data.Maybe                     (fromMaybe)
import           Data.Ord                       (Down (..))
import qualified Data.Set                       as Set
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Distribution.Types.Flag        (FlagAssignment, FlagName,
                                                 lookupFlagAssignment,
                                                 mkFlagAssignment, mkFlagName)
import           Distribution.Types.PackageName (PackageName, mkPackageName)
import           Distribution.Types.Version     (Version, mkVersion)
import           PubGrub.Incompatibility        (Incompatibility, fromDependency)
import           PubGrub.InstanceSet            (Instance (BuildSource),
                                                 InstanceSet (..),
                                                 memberInstance,
                                                 singletonInstance)
import           PubGrub.InstanceSet.SourceCell (SourceCell (..), assignmentFrom)
import           PubGrub.Provider               (Provider (Provider, expand))
import           PubGrub.Report                 (reportConflict)
import           PubGrub.Solver                 (SolveError (NoSolution),
                                                 SolverMsg, solve)
import           PubGrub.VersionSet             (VersionSet, contains,
                                                 fullVersionSet)
import           Test.Tasty                     (TestTree, testGroup)
import           Test.Tasty.HUnit               (assertBool, testCase, (@?=))

-- --------------------------------------------------------------------------
-- A toy world with flags
-- --------------------------------------------------------------------------

-- | One source release: a version, and the dependencies it declares /at a given
-- flag assignment/. The function is the toy stand-in for a @.cabal@ file's
-- conditional tree, and it keeps the dependencies and the assignment that
-- produced them inseparable, as 'Bridge.Provider' does by flattening at the
-- assignment it has just pinned.
data Release = Release
    { relVersion :: Version
    , relDeps    :: FlagAssignment -> [(PackageName, VersionSet)]
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

-- | The provider for a world: the rule in the module header, which is
-- 'Bridge.Provider.mkExpand' without its installed half (these worlds have no
-- installed units, so the installed side of every 'InstanceSet' is empty).
mkProvider :: Applicative m => World -> Provider m
mkProvider world = Provider expand'
  where
    expand' pn range = pure (go (offers pn range))
      where
        -- Try the offered (version, cell) pairs in order and commit to the
        -- first whose derived assignment the offered set actually admits. The
        -- membership test can fail: a cell fixes only some flags, and the
        -- defaults filling in the rest may contradict a /different/ cell's pins
        -- — the same reason 'Bridge.Provider' loops instead of taking the head.
        go [] = Nothing
        go ((v, sc) : rest)
            | memberInstance i range = Just (i, depIncs pn i (depsOf pn v flags))
            | otherwise = go rest
          where
            flags = assignmentFor pn sc
            i = BuildSource v flags

    -- Newest version first, crossed with the cells of the offered set that
    -- admit that version.
    offers :: PackageName -> InstanceSet -> [(Version, SourceCell)]
    offers pn range =
        [ (v, sc)
        | v <- sortOn Down (versionsOf pn)
        , sc <- filter (\c -> scVersionSet c `contains` v) (isSource range)
        ]

    -- The cell's pins, completed at the declared defaults for every flag it
    -- leaves free. Total over the package's declared flags, which is the
    -- 'Instance' invariant 'singletonInstance' relies on.
    assignmentFor :: PackageName -> SourceCell -> FlagAssignment
    assignmentFor pn sc = assignmentFrom (flagsOf pn) sc

    depIncs :: PackageName -> Instance -> [(PackageName, VersionSet)] -> [Incompatibility]
    depIncs pn chosen deps =
        [ fromDependency pn (singletonInstance chosen) (d, widen vs)
        | (d, vs) <- deps
        ]

    -- One cell carrying the declared range, so the range survives into the
    -- incompatibility and into any conflict report.
    widen :: VersionSet -> InstanceSet
    widen vs = InstanceSet Set.empty [SourceCell vs Map.empty]

    lookupPkg pn = lookup pn world
    releasesOf pn = maybe [] pkgReleases (lookupPkg pn)
    versionsOf pn = map relVersion (releasesOf pn)
    flagsOf pn = maybe [] pkgFlags (lookupPkg pn)
    depsOf pn v flags =
        concat [relDeps r flags | r <- releasesOf pn, relVersion r == v]

-- --------------------------------------------------------------------------
-- Running a world
-- --------------------------------------------------------------------------

-- | The monad the tests solve in. 'IO' rather than 'Identity' only so that
-- 'countingProvider' can observe how many times the solver asks about a
-- package; the solver itself is pure.
type M = LoggerT SolverMsg IO

-- | The root package, whose sole release is @1.0.0@ with no flags.
root :: PackageName
root = pkg "root"

rootInstance :: Instance
rootInstance = BuildSource v1 (mkFlagAssignment [])

-- | Run the solver, discarding its log trace. A failure is kept as its rendered
-- proof rather than 'show'n: the derived 'Show' would expand the whole
-- derivation DAG.
runSolve :: Provider M -> IO (Either Text (Map PackageName Instance))
runSolve provider =
    either (Left . renderFailure) Right
        <$> usingLoggerT mempty (solve provider root rootInstance)

renderFailure :: SolveError -> Text
renderFailure (NoSolution i) = reportConflict i

solveWorld :: World -> IO (Either Text (Map PackageName Instance))
solveWorld = runSolve . mkProvider

-- | Wrap a provider so that every @expand@ records the package it was asked
-- about. The solver asks exactly once per decision, so the tally counts
-- decision /attempts/: a package asked twice was reconsidered after a conflict.
countingProvider :: IORef [PackageName] -> Provider M -> Provider M
countingProvider ref provider = Provider $ \p range -> do
    liftIO (modifyIORef' ref (p :))
    expand provider p range

-- | Solve, and also report how many times each package was expanded.
solveCounting :: World -> IO (Either Text (Map PackageName Instance), Map PackageName Int)
solveCounting world = do
    ref <- newIORef []
    result <- runSolve (countingProvider ref (mkProvider world))
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

-- | An unconstrained dependency. These worlds are about flags, so no test needs
-- a narrower range than "any version".
dep :: PackageName -> (PackageName, VersionSet)
dep p = (p, fullVersionSet)

-- | A flagless package with a single release at @1.0.0@ and no dependencies.
leaf :: Pkg
leaf = Pkg [] [Release v1 (const [])]

-- | A flagless package with a single release at @1.0.0@ and fixed dependencies.
plain :: [PackageName] -> Pkg
plain deps = Pkg [] [Release v1 (const (map dep deps))]

-- | Is a flag on? The provider always supplies a total assignment, so an
-- unassigned flag would be a bug in the provider, not a case to handle.
isOn :: FlagName -> FlagAssignment -> Bool
isOn f fa = fromMaybe False (lookupFlagAssignment f fa)

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
                        [Release v1 (\fa -> [dep (if isOn fast fa then pkg "speedy" else pkg "slow")])]
                    )
                ,
                    ( pkg "bar"
                    , Pkg
                        [(tidy, False)]
                        [Release v1 (\fa -> [dep (pkg "neat") | isOn tidy fa])]
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
                        [Release v1 (\fa -> [dep (if isOn fast fa then pkg "speedy" else pkg "slow")])]
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
                            ( \fa ->
                                concat
                                    [ [dep (pkg "needs-a") | isOn a fa]
                                    , [dep (pkg "needs-b") | isOn b fa]
                                    , [dep (pkg "always")]
                                    ]
                            )
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
                        [Release v1 (\fa -> [dep (if isOn fast fa then pkg "speedy" else pkg "slow")])]
                    )
                ]
        result <- solveWorld world
        assertBool "expected no solution" (isLeft result)
        let report = either id (const T.empty) result
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
                , (pkg "foo", Pkg [(unused, True)] [Release v1 (const [dep (pkg "bar")])])
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

-- | 5b. An irrelevant flag /does/ multiply the search once something else
-- conflicts.
--
-- Here @foo 2.0.0@ is unusable for a reason that has nothing to do with @unused@
-- (it needs a package that does not exist), and @foo 1.0.0@ is fine. But what
-- conflict resolution learns is @foo ==2.0.0+unused is forbidden@ — one
-- /instance/, not the version — so @==2.0.0 -unused@ is still in @foo@'s range
-- and the provider is asked to try it. @foo@ is therefore expanded three times,
-- not two, and the dead version @2.0.0@ is flattened twice.
--
-- This is the per-version-depender divergence CLAUDE.md records under
-- "Depender-range collapsing", seen from the flag side: nothing here is unsound,
-- but the cost is @2^(unused flags)@ retries per rejected version, so the
-- collapsing is a performance item and not a cosmetic one.
irrelevantFlagRetried :: TestTree
irrelevantFlagRetried =
    testCase "an irrelevant flag still multiplies a version-level retry" $ do
        let unused = flg "unused"
            world =
                [ (pkg "root", plain [pkg "foo"])
                ,
                    ( pkg "foo"
                    , Pkg
                        [(unused, True)]
                        [ Release v2 (const [dep (pkg "gone")])
                        , Release v1 (const [dep (pkg "here")])
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
        -- foo: 2.0.0+unused, then 2.0.0-unused, then 1.0.0+unused.
        Map.lookup (pkg "foo") asks @?= Just 3
