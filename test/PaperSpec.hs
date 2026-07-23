-- | The worked examples from the PubGrub paper (references/pubgrub.md,
-- "Examples" section), as end-to-end solver tests.
--
-- Unlike 'SolverSpec', which lists allowed instances explicitly, this harness
-- models a package universe the way the paper does: each release declares its
-- dependencies as version /ranges/, and the 'Provider' widens those ranges
-- into instance sets against the world. So these tests also exercise
-- 'VersionSet' and the range-to-instance widening the real bridge will do.
--
-- The four satisfiable examples assert the exact solution the paper reports.
-- The two error-reporting examples are unsatisfiable, and since nothing renders
-- a derivation graph yet, they assert only that solving fails.
module PaperSpec (tests) where

import           Colog                          (LoggerT, usingLoggerT)
import           Data.Either                    (isLeft)
import           Data.Functor.Identity          (Identity, runIdentity)
import           Data.List                      (maximumBy)
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Data.Ord                       (comparing)
import qualified Data.Set                       as Set
import           Distribution.Types.Condition   (Condition (Lit))
import           Distribution.Types.Flag        (mkFlagAssignment)
import           Distribution.Types.PackageName (PackageName, mkPackageName)
import           Distribution.Version           (earlierVersion,
                                                 intersectVersionRanges,
                                                 mkVersion, orLaterVersion)
import           PubGrub.Incompatibility        (fromDependency)
import           PubGrub.InstanceSet            (Dependency (..),
                                                 HasVersion (version),
                                                 Instance (BuildSource),
                                                 InstanceSet (InstanceSet),
                                                 SourcePackage (..),
                                                 singletonInstance)
import           PubGrub.Provider               (Provider (Provider))
import           PubGrub.Solver                 (SolveError, SolverMsg, solve)
import           PubGrub.VersionSet             (VersionSet, contains,
                                                 fromVersionRange)
import           Test.Tasty                     (TestTree, testGroup)
import           Test.Tasty.HUnit               (assertBool, testCase, (@?=))

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

-- | A release as a solver 'Instance'. The instance carries its own
-- dependencies, all unconditional, as the whole-instance model intends.
releaseInstance :: Release -> Instance
releaseInstance r =
    BuildSource
        (SourcePackage (mkVersion (relVersion r)) [] deps (Lit True))
        (mkFlagAssignment [])
  where
    deps = [Dependency d vs (Lit True) | (d, vs) <- relDeps r]

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

    widen :: PackageName -> VersionSet -> InstanceSet
    widen d vs = InstanceSet (Set.fromList [i | i <- universe d, contains vs (version i)])

    expand' p (InstanceSet s)
        | Set.null s = pure Nothing
        | otherwise =
            let chosen = maximumBy (comparing version) (Set.toList s)
                deps = case chosen of
                    BuildSource sp _ -> spDependencies sp
                    _                -> []
                incs =
                    [ fromDependency p (singletonInstance chosen) (d, widen d vs)
                    | Dependency d vs _ <- deps
                    ]
             in pure (Just (chosen, incs))

-- | Run the solver purely, discarding the solver's log trace.
runSolve
    :: Provider (LoggerT SolverMsg Identity)
    -> PackageName
    -> Instance
    -> Either SolveError (Map PackageName Instance)
runSolve provider p i = runIdentity (usingLoggerT mempty (solve provider p i))

-- | Run the solver against a world, rooted at @root 1.0.0@.
solveWorld :: World -> Either String (Map PackageName Instance)
solveWorld world =
    either (Left . show) Right $
        runSolve (mkProvider world) (mkPackageName "root") (instanceOf world (mkPackageName "root") [1, 0, 0])

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
        , testCase "Linear Error Reporting (unsat)" $
            let world =
                    [ (pkg "root", [Release [1, 0, 0] [(pkg "foo", caret [1, 0, 0]), (pkg "baz", caret [1, 0, 0])]])
                    , (pkg "foo", [Release [1, 0, 0] [(pkg "bar", caret [2, 0, 0])]])
                    , (pkg "bar", [Release [2, 0, 0] [(pkg "baz", caret [3, 0, 0])]])
                    , (pkg "baz", [Release [1, 0, 0] [], Release [3, 0, 0] []])
                    ]
             in assertBool "expected no solution" (isLeft (solveWorld world))
        , testCase "Branching Error Reporting (unsat)" $
            let world =
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
             in assertBool "expected no solution" (isLeft (solveWorld world))
        ]
