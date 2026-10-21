{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
-- | The worked examples from the PubGrub paper (references/pubgrub.md,
-- "Examples" section), as end-to-end solver tests.
--
-- These tests run the __real__ provider: 'PubGrub.Cabal.Provider.mkExpand' takes its
-- world as arguments, so 'mkProvider' feeds it the paper's universe out of memory
-- instead of Hackage, as @test\/FlagSolveSpec.hs@ does. Nothing about the rule —
-- candidate enumeration, version slots, the newest-first preference, range widening,
-- incompatibility emission — is restated here. A copy of the rule would test only
-- the copy, and a golden file would not notice it drifting, because a golden
-- absorbs whatever proof comes out.
--
-- What the worlds supply is the /data/, the way the paper writes it: each
-- release declares its dependencies as version /ranges/, and the provider widens
-- them into instance sets. So these tests also exercise 'PubGrub.Cabal.VersionSet'
-- and the provider's own range-to-instance widening.
--
-- The four satisfiable examples assert the exact solution the paper reports; the two
-- error-reporting examples are unsatisfiable and assert the __rendered proof__ against
-- a golden file in @test\/golden@. The spec publishes its own expected wording for
-- both (@references\/pubgrub.md:1005@ and @:1150@), so these two cases are the closest
-- thing there is to a conformance test for 'PubGrub.Report' — see the note above each
-- for the differences that remain and which known gap each belongs to.
module PaperSpec (tests) where

import           Control.Exception              (toException)
import qualified Data.ByteString.Lazy           as BL
import           Data.Functor.Identity          (Identity, runIdentity)
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import qualified Data.Set                       as Set
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import qualified Data.Text.Encoding             as T
import           Distribution.Types.Condition   (Condition (Lit))
import           Distribution.Types.Dependency  (mainLibSet, mkDependency)
import           Distribution.Types.PackageName (PackageName, mkPackageName)
import           Distribution.Version           (VersionRange, earlierVersion,
                                                 intersectVersionRanges,
                                                 mkVersion, orLaterVersion)
import           PubGrub.Cabal                  (Var (..), request)
import           PubGrub.Cabal.Installed        (mkInstalledDb)
import           PubGrub.Cabal.InstanceSet      (Instance (BuildSource))
import           PubGrub.Cabal.Provider         (ParseError (..))
import qualified PubGrub.Cabal.Provider         as BP
import           PubGrub.Cabal.Report           (reportConflict)
import           PubGrub.Cabal.Value            (Value (..))
import           PubGrub.Cabal.Version          (Version)
import qualified PubGrub.Cabal.Version          as V
import qualified PubGrub.Cabal.VersionSet       as VersionSet
import           PubGrub.Incompatibility        (Incompatibility)
import           PubGrub.Provider               (Provider (Provider))
import           PubGrub.Solver                 (SolveError (..), solve)
import           Test.Tasty                     (TestName, TestTree, testGroup)
import           Test.Tasty.Golden              (goldenVsString)
import           Test.Tasty.HUnit               (testCase, (@?=))

-- --------------------------------------------------------------------------
-- A range-based package universe
-- --------------------------------------------------------------------------

-- | One source release: a version and its dependencies as (name, range) pairs.
data Release = Release
    { relVersion :: [Int]
    , relDeps    :: [(PackageName, VersionRange)]
    }

-- | The whole universe: each package's available releases.
type World = [(PackageName, [Release])]

-- Range helpers mirroring the paper's (semver) notation. Note this is NOT
-- Cabal's PVP caret: the paper's @^1.0.0@ is @>=1.0.0 && <2.0.0@ (major = the
-- first component), whereas Cabal's 'majorBoundVersion' would stop at @<1.1@.
--
-- These are 'VersionRange's, not 'PubGrub.Cabal.VersionSet.VersionSet's, because
-- that is what a @.cabal@ dependency carries and therefore what 'BP.mkExpand' is
-- handed. Turning one into a set is the provider's job, and doing it here would
-- be taking over a step of the rule under test.
caret :: [Int] -> VersionRange -- ^1.2.3  =  >=1.2.3 && <2.0.0
caret [] = error "caret: empty version"
caret v@(major : _) =
    intersectVersionRanges (orLaterVersion (mkVersion v)) (earlierVersion (mkVersion [major + 1]))

gte :: [Int] -> VersionRange -- >=1.2.3
gte v = orLaterVersion (mkVersion v)

lt :: [Int] -> VersionRange -- <1.2.3
lt v = earlierVersion (mkVersion v)

-- | A release as a solver 'Instance': a source build of its version. An
-- 'Instance' only identifies a release, so the dependencies stay in the world
-- and the provider looks them up — exactly as the real bridge reads them from
-- the index.
releaseInstance :: Release -> Instance
releaseInstance r = BuildSource (V.mkVersion (relVersion r))

-- | The instance for a specific package version in the world (for asserting
-- expected solutions). Errors only if the test names a version not in @world@.
instanceOf :: World -> PackageName -> [Int] -> Instance
instanceOf world p v =
    case [releaseInstance r | (q, rs) <- world, q == p, r <- rs, relVersion r == v] of
        (i : _) -> i
        []      -> error ("instanceOf: no " ++ show p ++ " " ++ show v)

-- | The provider for a world: the /real/ 'BP.mkExpand', driven from an in-memory
-- release source built out of the world.
--
-- Three departures from a Hackage-backed run, none of them touching the rule:
--
--  * the 'BP.ReleaseSource' answers from the world rather than from an index, and
--    no @.cabal@ is ever parsed. Its two questions are exactly what a paper world
--    can answer: which versions exist, and what one release declares.
--  * the paper\'s top-level dependencies are the solve\'s seeds, one 'request'
--    per dependency (@:252@). So the worlds hold only the packages the paper
--    resolves, and the expected solutions name only those.
--  * the installed db is empty: these worlds have no pre-installed units, so the
--    installed half of every 'PubGrub.Cabal.InstanceSet.InstanceSet' is empty and
--    the prefer-installed and non-reinstallable branches never run.
--
-- The paper\'s releases have no flags, so every guard is @'Lit' True@ — a real
-- guard, not the absence of one, which 'PubGrub.Cabal.Flatten.expandGuard' resolves
-- to the single empty pin set. That is the shape every guard folds to while flags
-- are fixed at their declared defaults.
mkProvider :: World -> Provider Var Identity
mkProvider world = Provider (BP.mkExpand mempty BP.noPreference (mkInstalledDb []) source)
  where
    source =
        BP.ReleaseSource
            { BP.rsVersionsOf = \p ->
                Set.fromList [V.mkVersion (relVersion r) | (q, rs) <- world, q == p, r <- rs]
            , BP.rsReadRelease = \p v -> pure (readRelease p v)
            }

    -- Every release of every package, in the reduced shape the bridge expects: no
    -- declared flags, one unconditional dependency group, buildable.
    releases :: Map (PackageName, Version) BP.Release
    releases =
        Map.fromList
            [ ( (p, V.mkVersion (relVersion r))
              , BP.Release
                    { BP.relAutomatic = []
                    , BP.relGuarded =
                        [(Lit True, [mkDependency d vr mainLibSet | (d, vr) <- relDeps r])]
                    , BP.relUnbuildable = []
                    , BP.relTools = []
                    , BP.relSetup = []
                    }
              )
            | (p, rs) <- world
            , r <- rs
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
-- The monad the worlds are solved in
-- --------------------------------------------------------------------------

-- | Run the solver purely, discarding both log channels: 'solve' emits
-- 'SolverMsg' and 'BP.mkExpand' emits 'Text', and each takes its action as an
-- argument, so 'mempty' silences both.
--
-- Over 'Identity' rather than 'IO', which the provider rule permits: 'BP.mkExpand'
-- asks only for 'Monad', so these tests stay pure and their assertions stay a
-- plain '@?='.
runSolve
    :: Provider Var Identity
    -> [Incompatibility Var]
    -> Either (SolveError Var) (Map Var Value)
runSolve provider seeds =
    runIdentity (solve mempty provider seeds)

-- | Run the solver against a world, seeded with the paper's top-level dependencies.
-- A failure is kept as its rendered report rather than 'show'n, because the
-- derived 'Show' would expand the whole derivation DAG as a tree.
solveWorld :: [(PackageName, VersionRange)] -> World -> Either Text (Map Var Value)
solveWorld rootDeps world =
    either (Left . renderFailure) Right $
        runSolve (mkProvider world) [request p (BP.widenTo (mkInstalledDb []) p (VersionSet.fromVersionRange vr)) | (p, vr) <- rootDeps]

-- | Render a solver failure as its explanatory proof.
renderFailure :: SolveError Var -> Text
renderFailure (NoSolution i) = reportConflict i
renderFailure (NoSatisfier p _) =
    T.pack ("internal error: no satisfier for " <> show p)
renderFailure _ = T.pack "internal error"

-- | Assert the rendered proof of an unsatisfiable world against a golden file.
--
-- Golden rather than an expected list in the source, because what is under test is a
-- block of English: in a file of its own it can be read as the proof a user would
-- see, and when the wording changes on purpose
-- @cabal test --test-options=--accept@ rewrites it instead of anyone hand-editing
-- string literals.
--
-- A world that /solves/ writes its solution into the same file, so a golden diff
-- says what happened rather than \"expected Left\".
proofGolden :: TestName -> FilePath -> [(PackageName, VersionRange)] -> World -> TestTree
proofGolden name file rootDeps world =
    goldenVsString name ("test/golden/" <> file) (pure (utf8 (rendered (solveWorld rootDeps world))))
  where
    rendered (Left proof) = proof <> T.pack "\n"
    rendered (Right sol) =
        T.pack ("expected no solution, got " <> show (Map.keys sol) <> "\n")
    utf8 = BL.fromStrict . T.encodeUtf8

-- | The expected solution as a map, from (name, version) pairs.
expected :: World -> [(String, [Int])] -> Map Var Value
expected world entries =
    Map.fromList [(PackageVar (mkPackageName n), PackageValue (instanceOf world (mkPackageName n) v)) | (n, v) <- entries]

pkg :: String -> PackageName
pkg = mkPackageName

-- --------------------------------------------------------------------------
-- The examples
-- --------------------------------------------------------------------------

tests :: TestTree
tests =
    testGroup
        "PubGrub paper examples"
        [ testCase "No Conflicts" $
            let world =
                    [ (pkg "foo", [Release [1, 0, 0] [(pkg "bar", caret [1, 0, 0])]])
                    , (pkg "bar", [Release [1, 0, 0] [], Release [2, 0, 0] []])
                    ]
             in solveWorld [(pkg "foo", caret [1, 0, 0])] world
                    @?= Right (expected world [("foo", [1, 0, 0]), ("bar", [1, 0, 0])])
        , testCase "Avoiding Conflict During Decision Making" $
            let world =
                    [
                        ( pkg "foo"
                        ,
                            [ Release [1, 1, 0] [(pkg "bar", caret [2, 0, 0])]
                            , Release [1, 0, 0] []
                            ]
                        )
                    , (pkg "bar", [Release [1, 0, 0] [], Release [1, 1, 0] [], Release [2, 0, 0] []])
                    ]
             in solveWorld [(pkg "foo", caret [1, 0, 0]), (pkg "bar", caret [1, 0, 0])] world
                    @?= Right (expected world [("foo", [1, 0, 0]), ("bar", [1, 1, 0])])
        , testCase "Performing Conflict Resolution" $
            let world =
                    [
                        ( pkg "foo"
                        ,
                            [ Release [2, 0, 0] [(pkg "bar", caret [1, 0, 0])]
                            , Release [1, 0, 0] []
                            ]
                        )
                    , (pkg "bar", [Release [1, 0, 0] [(pkg "foo", caret [1, 0, 0])]])
                    ]
             in solveWorld [(pkg "foo", gte [1, 0, 0])] world
                    @?= Right (expected world [("foo", [1, 0, 0])])
        , testCase "Conflict Resolution With a Partial Satisfier" $
            let world =
                    [
                        ( pkg "foo"
                        ,
                            [ Release [1, 1, 0] [(pkg "left", caret [1, 0, 0]), (pkg "right", caret [1, 0, 0])]
                            , Release [1, 0, 0] []
                            ]
                        )
                    , (pkg "left", [Release [1, 0, 0] [(pkg "shared", gte [1, 0, 0])]])
                    , (pkg "right", [Release [1, 0, 0] [(pkg "shared", lt [2, 0, 0])]])
                    ,
                        ( pkg "shared"
                        ,
                            [ Release [2, 0, 0] []
                            , Release [1, 0, 0] [(pkg "target", caret [1, 0, 0])]
                            ]
                        )
                    , (pkg "target", [Release [2, 0, 0] [], Release [1, 0, 0] []])
                    ]
             in solveWorld [(pkg "foo", caret [1, 0, 0]), (pkg "target", caret [2, 0, 0])] world
                    @?= Right (expected world [("foo", [1, 0, 0]), ("target", [2, 0, 0])])
        , -- @:1005@. The spec's own two lines are
          --
          -- > Because every version of foo depends on bar ^2.0.0 which depends on
          -- > baz ^3.0.0, every version of foo requires baz ^3.0.0.
          -- > So, because root depends on both baz ^1.0.0 and foo ^1.0.0, version
          -- > solving failed.
          --
          -- The first line is ours exactly, in Cabal's range syntax. The last
          -- differs in one way: where the spec's line has a depender for baz
          -- ^1.0.0 and foo ^1.0.0, ours says the two are requested, which is the
          -- same fact without the package in front of it.
          proofGolden "Linear Error Reporting (unsat)" "linear-error-reporting.txt"
            [(pkg "foo", caret [1, 0, 0]), (pkg "baz", caret [1, 0, 0])]
            [ (pkg "foo", [Release [1, 0, 0] [(pkg "bar", caret [2, 0, 0])]])
            , (pkg "bar", [Release [2, 0, 0] [(pkg "baz", caret [3, 0, 0])]])
            , (pkg "baz", [Release [1, 0, 0] [], Release [3, 0, 0] []])
            ]
        , -- @:1150@. Here the derivation branches, and the shape the spec asks for
          -- is reproduced: one line per step, a line number minted only for the
          -- conclusion that gets referred to later (1), the back-reference in the
          -- line that joins the two branches, and the blank line between them.
          -- Ours differs in which facts each branch's first line fuses, and its
          -- last line says \"foo >=1.0.0 && <2 is requested\" where the spec's
          -- has a depender for it.
          proofGolden "Branching Error Reporting (unsat)" "branching-error-reporting.txt"
            [(pkg "foo", caret [1, 0, 0])]
            [
                ( pkg "foo"
                ,
                    [ Release [1, 0, 0] [(pkg "a", caret [1, 0, 0]), (pkg "b", caret [1, 0, 0])]
                    , Release [1, 1, 0] [(pkg "x", caret [1, 0, 0]), (pkg "y", caret [1, 0, 0])]
                    ]
                )
            , (pkg "a", [Release [1, 0, 0] [(pkg "b", caret [2, 0, 0])]])
            , (pkg "b", [Release [1, 0, 0] [], Release [2, 0, 0] []])
            , (pkg "x", [Release [1, 0, 0] [(pkg "y", caret [2, 0, 0])]])
            , (pkg "y", [Release [1, 0, 0] [], Release [2, 0, 0] []])
            ]
        ]
