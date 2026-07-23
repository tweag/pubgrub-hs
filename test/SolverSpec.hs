-- | End-to-end tests for the solving loop over hand-built toy worlds. A world
-- is a dependency table keyed by instance, and its 'Provider' picks the newest
-- instance in the offered range. That exercises unit propagation, decisions,
-- conflict resolution and backtracking without a Cabal index.
module SolverSpec (tests) where

import           Data.Either                    (isLeft)
import           Data.List                      (maximumBy)
import qualified Data.Map.Strict                as Map
import           Data.Ord                       (comparing)
import qualified Data.Set                       as Set
import           Distribution.Types.Condition   (Condition (Lit))
import           Distribution.Types.Flag        (mkFlagAssignment)
import           Distribution.Types.PackageName (PackageName, mkPackageName)
import           Distribution.Types.Version     (mkVersion)
import           PubGrub.Incompatibility        (fromDependency)
import           PubGrub.InstanceSet            (HasVersion (version),
                                                 Instance (BuildSource),
                                                 InstanceSet (InstanceSet),
                                                 SourcePackage (..),
                                                 singletonInstance)
import           PubGrub.Provider               (Provider (Provider))
import           PubGrub.Solver                 (solve)
import           Test.Tasty                     (TestTree, testGroup)
import           Test.Tasty.HUnit               (assertBool, testCase, (@?=))

-- --------------------------------------------------------------------------
-- Toy world helpers
-- --------------------------------------------------------------------------

-- | A source instance identified purely by its version; the toy worlds carry
-- their own dependency table, so the package's own dependency fields are left
-- empty.
inst :: [Int] -> Instance
inst ver = BuildSource (SourcePackage (mkVersion ver) [] [] (Lit True)) (mkFlagAssignment [])

setOf :: [Instance] -> InstanceSet
setOf = InstanceSet . Set.fromList

-- | Build a provider from a dependency table. @expand p range@ commits to the
-- newest instance in @range@ (the "newest wins" preference) and turns that
-- instance's table entry into dependency incompatibilities.
mkProvider :: (Instance -> [(PackageName, [Instance])]) -> Provider
mkProvider deps = Provider expand'
  where
    expand' p (InstanceSet s)
        | Set.null s = Nothing
        | otherwise =
            let chosen = maximumBy (comparing version) (Set.toList s)
                incs =
                    [ fromDependency p (singletonInstance chosen) (d, setOf ds)
                    | (d, ds) <- deps chosen
                    ]
             in Just (chosen, incs)

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
             in solve provider root rootI
                    @?= Right (Map.fromList [(root, rootI), (foo, foo2), (bar, bar1)])
        , testCase "unsat: dependency with no satisfying instance" $
            let provider = mkProvider $ \i -> [(foo, []) | i == rootI]
             in assertBool "expected NoSolution" (isLeft (solve provider root rootI))
        , testCase "backtrack: newest foo fails, solver recovers with older foo" $
            -- root needs foo; the newest (foo2) depends on an unsatisfiable
            -- bar, so the solver must backtrack and settle on foo1.
            let provider = mkProvider $ \i ->
                    if i == rootI
                        then [(foo, [foo1, foo2])]
                        else [(bar, []) | i == foo2]
             in solve provider root rootI
                    @?= Right (Map.fromList [(root, rootI), (foo, foo1)])
        ]
