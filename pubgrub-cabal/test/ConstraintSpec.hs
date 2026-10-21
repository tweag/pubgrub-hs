{-# LANGUAGE OverloadedStrings #-}
-- | The other seed: a __constraint__, \"if this package is chosen, it is in this
-- range\" ('PubGrub.Cabal.constraint'), built over a toy world the way the
-- bridge builds one ('PubGrub.Cabal.Provider.constrainTo').
--
-- A request forces a package into the plan; a constraint only bounds it. The
-- four facts pinned down here are the ones a planner relies on: a constraint
-- steers a choice, a constraint on a package nobody needs is vacuous, a
-- constraint the requests cannot live with is a terminal failure that the proof
-- names, and the conflict set of that failure is the path to it.
module ConstraintSpec (tests) where

import           Data.List                      (maximumBy)
import qualified Data.Map.Strict                as Map
import           Data.Ord                       (comparing)
import qualified Data.Set                       as Set
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Distribution.Types.PackageName (PackageName, mkPackageName)
import qualified Distribution.Version           as Cabal
import           PubGrub.Cabal                  (Var (..), fromDependency,
                                                 request)
import           PubGrub.Cabal.Installed        (InstalledDb, mkInstalledDb)
import           PubGrub.Cabal.InstanceSet      (HasVersion (version),
                                                 Instance (..), InstanceSet,
                                                 emptyInstanceSet,
                                                 memberInstance,
                                                 singletonInstance,
                                                 sourceInstances)
import           PubGrub.Cabal.Provider         (constrainTo)
import           PubGrub.Cabal.Report           (reportConflict)
import           PubGrub.Cabal.Value            (Value (..), ValueSet (..))
import           PubGrub.Cabal.Version          (mkVersion)
import           PubGrub.Cabal.VersionSet       (fromVersionRange)
import           PubGrub.Derivation             (conflictSet)
import           PubGrub.Incompatibility        (Incompatibility)
import           PubGrub.Provider               (Provider (..))
import           PubGrub.SetOps                 (union)
import           PubGrub.Solver                 (SolveError (..), solve)
import           Test.Tasty                     (TestTree, testGroup)
import           Test.Tasty.HUnit               (assertBool, assertFailure,
                                                 testCase, (@?=))

-- --------------------------------------------------------------------------
-- A toy world: root needs foo; foo has two releases; bar has one nobody needs
-- --------------------------------------------------------------------------

root, foo, bar :: PackageName
root = mkPackageName "root"
foo = mkPackageName "foo"
bar = mkPackageName "bar"

inst :: [Int] -> Instance
inst = BuildSource . mkVersion

rootI, foo1, foo2, bar1 :: Instance
rootI = inst [0]
foo1 = inst [1]
foo2 = inst [2]
bar1 = inst [1]

setOf :: [Instance] -> InstanceSet
setOf = foldr (union . singletonInstance) emptyInstanceSet

-- | The provider: newest instance the range admits, dependencies from a table.
-- @rootNeeds@ is what @root@ asks of @foo@, so the two worlds below differ in
-- one entry.
provider :: [Instance] -> Provider Var Maybe
provider rootNeeds = Provider expand'
  where
    expand' (PackageVar p) set =
        case filter (`memberInstance` vsInstances set) (instancesOf p) of
            [] -> pure (Nothing, [])
            candidates ->
                let chosen = maximumBy (comparing version) candidates
                 in pure
                        ( Just (PackageValue chosen)
                        , [fromDependency p (singletonInstance chosen) Map.empty d (setOf ds) | (d, ds) <- deps p chosen]
                        )
    expand' _ _ = pure (Nothing, [])

    instancesOf p
        | p == root = [rootI]
        | p == foo = [foo1, foo2]
        | p == bar = [bar1]
        | otherwise = []

    deps p i
        | p == root && i == rootI = [(foo, rootNeeds)]
        | otherwise = []

-- | No compiler in this world: every package is source.
noInstalled :: InstalledDb
noInstalled = mkInstalledDb []

-- | @p@ must be in the range if chosen, in cabal's syntax.
constrained :: PackageName -> Cabal.VersionRange -> Incompatibility Var
constrained p r = constrainTo noInstalled p (sourceInstances (fromVersionRange r))

-- | Solve for @root@ with the given constraints.
run :: [Instance] -> [Incompatibility Var] -> Either (SolveError Var) (Map.Map Var Value)
run rootNeeds constraints =
    case solve mempty (provider rootNeeds) (request root (singletonInstance rootI) : constraints) of
        Nothing -> Left (NoSatisfier (PackageVar root) (request root (singletonInstance rootI)))
        Just r  -> r

-- | 'run' with a failure rendered, so a plan can be compared with '@?='.
planOf :: [Instance] -> [Incompatibility Var] -> Either Text (Map.Map Var Value)
planOf rootNeeds = either (Left . proofOf) Right . run rootNeeds

proofOf :: SolveError Var -> Text
proofOf (NoSolution i)    = reportConflict i
proofOf (NoSatisfier p _) = T.pack ("internal error: no satisfier for " <> show p)
proofOf _                 = T.pack "internal error"

plan :: [(PackageName, Instance)] -> Map.Map Var Value
plan entries = Map.fromList [(PackageVar p, PackageValue i) | (p, i) <- entries]

-- --------------------------------------------------------------------------
-- Tests
-- --------------------------------------------------------------------------

tests :: TestTree
tests =
    testGroup
        "PubGrub.Cabal.constraint"
        [ testCase "a constraint steers the choice to an older release" $
            planOf [foo1, foo2] [constrained foo (Cabal.earlierVersion (Cabal.mkVersion [2]))]
                @?= Right (plan [(root, rootI), (foo, foo1)])
        , testCase "without it the newest release wins" $
            planOf [foo1, foo2] []
                @?= Right (plan [(root, rootI), (foo, foo2)])
        , testCase "a constraint on a package nothing needs is vacuous" $
            planOf [foo1, foo2] [constrained bar (Cabal.thisVersion (Cabal.mkVersion [99]))]
                @?= Right (plan [(root, rootI), (foo, foo2)])
        , testCase "a constraint the request cannot live with is terminal, and the proof says so" $
            case run [foo2] [constrained foo (Cabal.earlierVersion (Cabal.mkVersion [2]))] of
                Right _ -> assertFailure "expected no solution"
                Left err -> do
                    let proof = proofOf err
                    assertBool ("proof names the constraint:\n" <> T.unpack proof) ("foo is constrained to <2" `T.isInfixOf` proof)
                    assertBool ("proof names the request:\n" <> T.unpack proof) ("root ==0 is requested" `T.isInfixOf` proof)
        , testCase "the conflict set is the path to the failure" $
            case run [foo2] [constrained foo (Cabal.earlierVersion (Cabal.mkVersion [2]))] of
                Left (NoSolution i) -> conflictSet i @?= Set.fromList [PackageVar root, PackageVar foo]
                Left err -> assertFailure (T.unpack (proofOf err))
                Right _ -> assertFailure "expected no solution"
        ]
