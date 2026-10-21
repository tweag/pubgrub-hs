-- | End-to-end tests for the solving loop over hand-built toy worlds. A world
-- is a dependency table keyed by instance, and its 'Provider' picks the newest
-- instance in the offered range. That exercises unit propagation, decisions,
-- conflict resolution and backtracking without a Cabal index.
module SolverSpec (tests) where

import           Data.Either                    (isLeft)
import           Data.Functor.Identity          (Identity, runIdentity)
import           Data.List                      (maximumBy)
import qualified Data.Map.Strict                as Map
import           Data.Ord                       (comparing)
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Distribution.Types.PackageName (PackageName, mkPackageName)
import           PubGrub.Cabal                  (Cabal, fromDependency, request)
import           PubGrub.Cabal.InstanceSet      (HasVersion (version),
                                                 Instance (..), InstanceSet,
                                                 emptyInstanceSet,
                                                 memberInstance,
                                                 singletonInstance)
import           PubGrub.Cabal.Report           (reportConflict)
import           PubGrub.Cabal.Value            (Value (..), ValueSet (..))
import           PubGrub.Cabal.Variable         (Var (..))
import           PubGrub.Cabal.Version          (mkVersion)
import           PubGrub.Provider               (Provider (..))
import           PubGrub.SetOps                 (union)
import           PubGrub.Solver                 (SolveError (..), solve)
import           Test.Tasty                     (TestTree, testGroup)
import           Test.Tasty.HUnit               (assertBool, testCase, (@?=))

-- --------------------------------------------------------------------------
-- Toy world helpers
-- --------------------------------------------------------------------------

-- | A source instance identified purely by its version; the toy worlds carry
-- their own dependency table.
inst :: [Int] -> Instance
inst ver = BuildSource (mkVersion ver)

setOf :: [Instance] -> InstanceSet
setOf = foldr (union . singletonInstance) emptyInstanceSet

-- | Every instance these toy worlds mention. An 'InstanceSet' cannot be
-- enumerated, so the provider enumerates these candidates and keeps the ones
-- the offered set admits, as the real bridge does.
allInstances :: [Instance]
allInstances = [rootI, foo1, foo2, bar1]

-- | Build a provider from a dependency table. @expand p range@ commits to the
-- newest instance in @range@ (the "newest wins" preference) and turns that
-- instance's table entry into dependency incompatibilities. These worlds have
-- no flags, so a flag variable is never asked about.
mkProvider :: Applicative m => (Instance -> [(PackageName, [Instance])]) -> Provider Cabal m
mkProvider deps = Provider expand'
  where
    expand' (PackageVar p) set =
        case filter (`memberInstance` vsInstances set) allInstances of
            [] -> pure (Nothing, [])
            candidates ->
                let chosen = maximumBy (comparing version) candidates
                    incs =
                        [ fromDependency p (singletonInstance chosen) Map.empty d (setOf ds)
                        | (d, ds) <- deps chosen
                        ]
                 in pure (Just (PackageValue chosen), incs)
    expand' _ _ = pure (Nothing, [])

-- | Run the solver purely, seeded with one package at one instance, discarding
-- the solver's log trace. A failure is kept as its rendered report rather than
-- 'show'n: the derived 'Show' would expand the whole derivation DAG as a tree.
runSolve
    :: Provider Cabal Identity
    -> PackageName
    -> Instance
    -> Either Text (Map.Map Var Value)
runSolve provider p i =
    either (Left . renderFailure) Right (runIdentity (solve mempty provider [request p (singletonInstance i)]))

renderFailure :: SolveError Cabal -> Text
renderFailure (NoSolution i) = reportConflict i
renderFailure (NoSatisfier p _) =
    T.pack ("internal error: no satisfier for " <> show p)
renderFailure _ = T.pack "internal error"

-- | The expected answer, as the solver states it.
solutionOf :: [(PackageName, Instance)] -> Map.Map Var Value
solutionOf entries = Map.fromList [(PackageVar p, PackageValue i) | (p, i) <- entries]

root, foo, bar :: PackageName
root = mkPackageName "root"
foo = mkPackageName "foo"
bar = mkPackageName "bar"

rootI :: Instance
rootI = inst [0]

foo1, foo2 :: Instance
foo1 = inst [1]
foo2 = inst [2]

bar1 :: Instance
bar1 = inst [1]

-- --------------------------------------------------------------------------
-- Tests
-- --------------------------------------------------------------------------

tests :: TestTree
tests =
    testGroup
        "Solver"
        [ testCase "sat: linear chain root -> foo -> bar" $
            let provider = mkProvider $ \i ->
                    if i == rootI
                        then [(foo, [foo1, foo2])]
                        else [(bar, [bar1]) | i == foo2]
             in runSolve provider root rootI
                    @?= Right (solutionOf [(root, rootI), (foo, foo2), (bar, bar1)])
        , testCase "unsat: dependency with no satisfying instance" $
            let provider = mkProvider $ \i -> [(foo, []) | i == rootI]
             in assertBool "expected NoSolution" (isLeft (runSolve provider root rootI))
        , testCase "backtrack: newest foo fails, solver recovers with older foo" $
            -- root needs foo; the newest (foo2) depends on an unsatisfiable
            -- bar, so the solver must backtrack and settle on foo1.
            let provider = mkProvider $ \i ->
                    if i == rootI
                        then [(foo, [foo1, foo2])]
                        else [(bar, []) | i == foo2]
             in runSolve provider root rootI
                    @?= Right (solutionOf [(root, rootI), (foo, foo1)])
        ]
