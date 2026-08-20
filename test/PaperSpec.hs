-- | The worked examples from the PubGrub paper (references/pubgrub.md,
-- "Examples" section), as end-to-end solver tests.
--
-- Unlike 'SolverSpec', which lists allowed instances explicitly, this harness
-- models a package universe the way the paper does: each release declares its
-- dependencies as version /ranges/, and the 'Provider' widens those ranges
-- into instance sets against the world. So these tests also exercise
-- 'VersionSet' and the range-to-instance widening the real bridge will do.
--
-- The four satisfiable examples assert the exact solution the paper reports; the two
-- error-reporting examples are unsatisfiable and assert the __rendered proof__ against
-- a golden file in @test\/golden@. The spec publishes its own expected wording for
-- both (@references\/pubgrub.md:1005@ and @:1150@), so these two cases are the closest
-- thing there is to a conformance test for 'PubGrub.Report' — see the note above each
-- for the differences that remain and which known gap each belongs to.
module PaperSpec (tests) where

import           Colog                          (LoggerT, usingLoggerT)
import qualified Data.ByteString.Lazy          as BL
import           Data.Functor.Identity          (Identity, runIdentity)
import           Data.List                      (maximumBy)
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Data.Ord                       (comparing)
import qualified Data.Set                       as Set
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import qualified Data.Text.Encoding             as T
import           Distribution.Types.Flag        (mkFlagAssignment)
import           Distribution.Types.PackageName (PackageName, mkPackageName)
import           Distribution.Version           (earlierVersion,
                                                 intersectVersionRanges,
                                                 mkVersion, orLaterVersion)
import           PubGrub.Incompatibility        (fromDependency)
import           PubGrub.InstanceSet            (HasVersion (version),
                                                 Instance (BuildSource),
                                                 InstanceSet (..),
                                                 memberInstance,
                                                 singletonInstance)
import           PubGrub.InstanceSet.SourceCell (SourceCell (..))
import           PubGrub.Provider               (Provider (Provider))
import           PubGrub.Report                 (reportConflict)
import           PubGrub.Solver                 (SolveError (..), SolverMsg,
                                                 solve)
import           PubGrub.VersionSet             (VersionSet, fromVersionRange)
import           Test.Tasty                     (TestName, TestTree, testGroup)
import           Test.Tasty.Golden              (goldenVsString)
import           Test.Tasty.HUnit               (testCase, (@?=))

-- --------------------------------------------------------------------------
-- A range-based package universe
-- --------------------------------------------------------------------------

-- | One source release: a version and its dependencies as (name, range) pairs.
data Release = Release
    { relVersion :: [Int]
    , relDeps    :: [(PackageName, VersionSet)]
    }

-- | The whole universe: each package's available releases.
type World = [(PackageName, [Release])]

-- Range helpers mirroring the paper's (semver) notation. Note this is NOT
-- Cabal's PVP caret: the paper's @^1.0.0@ is @>=1.0.0 && <2.0.0@ (major = the
-- first component), whereas Cabal's 'majorBoundVersion' would stop at @<1.1@.
caret :: [Int] -> VersionSet -- ^1.2.3  =  >=1.2.3 && <2.0.0
caret [] = error "caret: empty version"
caret v@(major : _) =
    fromVersionRange
        (intersectVersionRanges (orLaterVersion (mkVersion v)) (earlierVersion (mkVersion [major + 1])))

gte :: [Int] -> VersionSet -- >=1.2.3
gte v = fromVersionRange (orLaterVersion (mkVersion v))

lt :: [Int] -> VersionSet -- <1.2.3
lt v = fromVersionRange (earlierVersion (mkVersion v))

-- | A release as a solver 'Instance': its version under the default (empty)
-- flag assignment. An 'Instance' only identifies a release, so the dependencies
-- stay in the world and the provider looks them up — exactly as the real bridge
-- reads them from the index.
releaseInstance :: Release -> Instance
releaseInstance r = BuildSource (mkVersion (relVersion r)) (mkFlagAssignment [])

-- | The instance for a specific package version in the world (for asserting
-- expected solutions). Errors only if the test names a version not in @world@.
instanceOf :: World -> PackageName -> [Int] -> Instance
instanceOf world p v =
    case [releaseInstance r | (q, rs) <- world, q == p, r <- rs, relVersion r == v] of
        (i : _) -> i
        []      -> error ("instanceOf: no " ++ show p ++ " " ++ show v)

-- | The provider for a world: pick the newest instance in the range the
-- solver offers, and widen the chosen release's dependency ranges into
-- instance sets against the world's universe.
mkProvider :: Applicative m => World -> Provider m
mkProvider world = Provider expand'
  where
    universe :: PackageName -> [Instance]
    universe p = [releaseInstance r | (q, rs) <- world, q == p, r <- rs]

    -- Widen a range into the instances of @d@ it admits: one cell carrying the
    -- declared range, exactly as 'Bridge.Provider' does. The range therefore
    -- survives into the incompatibility, so a conflict report can name it
    -- instead of enumerating the versions that happen to be in this world.
    -- These worlds have no pre-installed packages, so the installed half is
    -- empty.
    widen :: PackageName -> VersionSet -> InstanceSet
    widen _d vs = InstanceSet Set.empty [SourceCell vs Map.empty]

    -- The dependencies the world records for the chosen release.
    --
    -- An 'InstanceSet' is symbolic and cannot be enumerated, so expand' picks
    -- the candidates out of the world and keeps those the offered set admits.
    depsOf :: PackageName -> Instance -> [(PackageName, VersionSet)]
    depsOf p chosen =
        concat
            [ relDeps r
            | (q, rs) <- world
            , q == p
            , r <- rs
            , mkVersion (relVersion r) == version chosen
            ]

    expand' p range =
        case filter (`memberInstance` range) (universe p) of
            [] -> pure Nothing
            candidates ->
                let chosen = maximumBy (comparing version) candidates
                    incs =
                        [ fromDependency p (singletonInstance chosen) d (widen d vs)
                        | (d, vs) <- depsOf p chosen
                        ]
                 in pure (Just (chosen, incs))

-- | Run the solver purely, discarding the solver's log trace.
runSolve
    :: Provider (LoggerT SolverMsg Identity)
    -> PackageName
    -> Instance
    -> Either SolveError (Map PackageName Instance)
runSolve provider p i = runIdentity (usingLoggerT mempty (solve provider p i))

-- | Run the solver against a world, rooted at @root 1.0.0@. A failure is kept
-- as its rendered report rather than 'show'n, because the derived 'Show' would
-- expand the whole derivation DAG as a tree.
solveWorld :: World -> Either Text (Map PackageName Instance)
solveWorld world =
    either (Left . renderFailure) Right $
        runSolve (mkProvider world) (mkPackageName "root") (instanceOf world (mkPackageName "root") [1, 0, 0])

-- | Render a solver failure as its explanatory proof.
renderFailure :: SolveError -> Text
renderFailure (NoSolution i) = reportConflict i
renderFailure (NoSatisfier p _) =
    T.pack ("internal error: no satisfier for " <> show p)

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
proofGolden :: TestName -> FilePath -> World -> TestTree
proofGolden name file world =
    goldenVsString name ("test/golden/" <> file) (pure (utf8 (rendered (solveWorld world))))
  where
    rendered (Left proof) = proof <> T.pack "\n"
    rendered (Right sol) =
        T.pack ("expected no solution, got " <> show (Map.keys sol) <> "\n")
    utf8 = BL.fromStrict . T.encodeUtf8

-- | The expected solution as a map, from (name, version) pairs.
expected :: World -> [(String, [Int])] -> Map PackageName Instance
expected world entries =
    Map.fromList [(mkPackageName n, instanceOf world (mkPackageName n) v) | (n, v) <- entries]

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
                    [ (pkg "root", [Release [1, 0, 0] [(pkg "foo", caret [1, 0, 0])]])
                    , (pkg "foo", [Release [1, 0, 0] [(pkg "bar", caret [1, 0, 0])]])
                    , (pkg "bar", [Release [1, 0, 0] [], Release [2, 0, 0] []])
                    ]
             in solveWorld world
                    @?= Right (expected world [("root", [1, 0, 0]), ("foo", [1, 0, 0]), ("bar", [1, 0, 0])])
        , testCase "Avoiding Conflict During Decision Making" $
            let world =
                    [ (pkg "root", [Release [1, 0, 0] [(pkg "foo", caret [1, 0, 0]), (pkg "bar", caret [1, 0, 0])]])
                    ,
                        ( pkg "foo"
                        ,
                            [ Release [1, 1, 0] [(pkg "bar", caret [2, 0, 0])]
                            , Release [1, 0, 0] []
                            ]
                        )
                    , (pkg "bar", [Release [1, 0, 0] [], Release [1, 1, 0] [], Release [2, 0, 0] []])
                    ]
             in solveWorld world
                    @?= Right (expected world [("root", [1, 0, 0]), ("foo", [1, 0, 0]), ("bar", [1, 1, 0])])
        , testCase "Performing Conflict Resolution" $
            let world =
                    [ (pkg "root", [Release [1, 0, 0] [(pkg "foo", gte [1, 0, 0])]])
                    ,
                        ( pkg "foo"
                        ,
                            [ Release [2, 0, 0] [(pkg "bar", caret [1, 0, 0])]
                            , Release [1, 0, 0] []
                            ]
                        )
                    , (pkg "bar", [Release [1, 0, 0] [(pkg "foo", caret [1, 0, 0])]])
                    ]
             in solveWorld world
                    @?= Right (expected world [("root", [1, 0, 0]), ("foo", [1, 0, 0])])
        , testCase "Conflict Resolution With a Partial Satisfier" $
            let world =
                    [ (pkg "root", [Release [1, 0, 0] [(pkg "foo", caret [1, 0, 0]), (pkg "target", caret [2, 0, 0])]])
                    ,
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
             in solveWorld world
                    @?= Right (expected world [("root", [1, 0, 0]), ("foo", [1, 0, 0]), ("target", [2, 0, 0])])
        , -- @:1005@. The spec's own two lines are
          --
          -- > Because every version of foo depends on bar ^2.0.0 which depends on
          -- > baz ^3.0.0, every version of foo requires baz ^3.0.0.
          -- > So, because root depends on both baz ^1.0.0 and foo ^1.0.0, version
          -- > solving failed.
          --
          -- The last line is ours up to cosmetics, in Cabal's range syntax. The
          -- first is __two__ lines here, because our ranges are intensional: the
          -- solver separately learns that a range's /holes/ are empty, and each
          -- dependency fact is paired with a \"no version for …\" sibling instead
          -- of with the next dependency fact. That is CLAUDE.md's reporting gap 2
          -- (@collapseNoInstances@), and it is also what keeps the chain fusion
          -- from firing: absorb those siblings and the two dependency facts become
          -- each other's neighbours, which is exactly the \"which depends on\"
          -- line the spec writes.
          --
          -- The cosmetics are reporting gap 4: no terminal periods, a range where
          -- the spec says \"every version of\", and the root's synthetic version
          -- shown.
          proofGolden "Linear Error Reporting (unsat)" "linear-error-reporting.txt"
            [ (pkg "root", [Release [1, 0, 0] [(pkg "foo", caret [1, 0, 0]), (pkg "baz", caret [1, 0, 0])]])
            , (pkg "foo", [Release [1, 0, 0] [(pkg "bar", caret [2, 0, 0])]])
            , (pkg "bar", [Release [2, 0, 0] [(pkg "baz", caret [3, 0, 0])]])
            , (pkg "baz", [Release [1, 0, 0] [], Release [3, 0, 0] []])
            ]
        , -- @:1150@. Here the derivation branches, and the shape the spec asks for
          -- is reproduced: one line per step, a line number minted only for the
          -- conclusion that gets referred to later (1), the back-reference in the
          -- line that joins the two branches, and \"depends on both\" where one
          -- release's two dependencies are named together.
          --
          -- Same two residues as above: the \"no version for …\" siblings (gap 2)
          -- and the cosmetics (gap 4, which includes the blank line the spec puts
          -- between the branches).
          proofGolden "Branching Error Reporting (unsat)" "branching-error-reporting.txt"
            [ (pkg "root", [Release [1, 0, 0] [(pkg "foo", caret [1, 0, 0])]])
            ,
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
