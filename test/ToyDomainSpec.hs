{-# LANGUAGE TypeFamilies #-}

-- | The solver over a domain that is not cabal's.
--
-- 'PubGrub.Incompatibility.Domain' is the whole of what the algorithm asks of
-- a problem, and this module is the proof: a package is a name, a value is an
-- 'Int', a set of values is a 'Set', a fact is one of two sentences, and nothing
-- from Cabal-syntax or "PubGrub.Cabal" is imported. If the core leans on the
-- cabal domain, this module stops compiling.
module ToyDomainSpec (tests) where

import           Data.Functor.Identity   (Identity, runIdentity)
import           Data.List               (maximumBy, sort)
import           Data.Map.Strict         (Map)
import qualified Data.Map.Strict         as Map
import           Data.Ord                (comparing)
import           Data.Set                (Set)
import qualified Data.Set                as Set
import           PubGrub.Derivation      (asFact, asNoValues, conflictSet,
                                          externals)
import           PubGrub.Incompatibility (Cause (..), Domain (..),
                                          Incompatibility (..))
import           PubGrub.Provider        (Provider (..))
import           PubGrub.Solver          (SolveError (..), solve)
import           PubGrub.Term            (Term (..))
import           Test.Tasty              (TestTree, testGroup)
import           Test.Tasty.HUnit        (assertFailure, testCase, (@?=))

-- --------------------------------------------------------------------------
-- The domain
-- --------------------------------------------------------------------------

newtype Pkg = Pkg String
    deriving (Eq, Ord, Show)

-- | The domain: a type with no values, naming the instantiation.
data Toy

-- | What a leaf says: a package was asked for in some versions, or a version
-- of a package needs another package in some versions.
data ToyFact
    = Wants Pkg (Set Int)
    | Needs Pkg Int Pkg (Set Int)
    deriving (Eq, Show)

instance Domain Toy where
    type VarOf Toy = Pkg
    type ValueOf Toy = Int
    type SetOf Toy = Set Int
    type FactOf Toy = ToyFact
    singleton _ = Set.singleton

-- | A seed: @p@ must be in the plan, at a version in @vs@.
wants :: Pkg -> [Int] -> Incompatibility Toy
wants p vs = Incompatibility (Map.singleton p (Negative (Set.fromList vs))) (Seed (Wants p (Set.fromList vs)))

-- | A fact: @p@ at @v@ needs @q@ at a version in @ws@.
needs :: Pkg -> Int -> Pkg -> [Int] -> Incompatibility Toy
needs p v q ws =
    Incompatibility
        (Map.fromList [(p, Positive (Set.singleton v)), (q, Negative (Set.fromList ws))])
        (Fact (Needs p v q (Set.fromList ws)))

-- --------------------------------------------------------------------------
-- A world
-- --------------------------------------------------------------------------

-- | Each package's versions, and what each version needs.
type World = Map Pkg [(Int, [(Pkg, [Int])])]

-- | The provider: the newest version the offered set admits, and its needs.
provider :: World -> Provider Toy Identity
provider w = Provider $ \p offered ->
    pure $ case [(v, ds) | (v, ds) <- Map.findWithDefault [] p w, v `Set.member` offered] of
        [] -> (Nothing, [])
        candidates ->
            let (v, ds) = maximumBy (comparing fst) candidates
             in (Just v, [needs p v q ws | (q, ws) <- ds])

run :: World -> [Incompatibility Toy] -> Either (SolveError Toy) (Map Pkg Int)
run w seeds = runIdentity (solve mempty (provider w) seeds)

app, lib, util :: Pkg
app = Pkg "app"
lib = Pkg "lib"
util = Pkg "util"

-- | @app 1@ needs @lib@ 1 or 2; @lib 2@ needs @util 2@, @lib 1@ needs @util 1@;
-- only @util 1@ exists.
world :: World
world =
    Map.fromList
        [ (app, [(1, [(lib, [1, 2])])])
        , (lib, [(1, [(util, [1])]), (2, [(util, [2])])])
        , (util, [(1, [])])
        ]

-- | The same, but the only @util@ is version 3, which no @lib@ accepts.
worldWithout :: World
worldWithout = Map.insert util [(3, [])] world

-- --------------------------------------------------------------------------
-- Tests
-- --------------------------------------------------------------------------

tests :: TestTree
tests =
    testGroup
        "a domain that is not cabal's"
        [ testCase "solves, backtracking from lib 2 to lib 1" $
            case run world [wants app [1]] of
                Right plan -> plan @?= Map.fromList [(app, 1), (lib, 1), (util, 1)]
                Left _     -> assertFailure "expected a solution"
        , testCase "fails when nothing fits, and the derivation reads back" $
            case run worldWithout [wants app [1]] of
                Right plan -> assertFailure ("expected no solution, got " ++ show plan)
                Left (NoSatisfier p _) -> assertFailure ("no satisfier for " ++ show p)
                Left (NoSolution root) -> do
                    -- The root is the empty clause, closed against the seeds.
                    Map.keys (incompTerms root) @?= []
                    -- Every variable the search touched is in the conflict set.
                    conflictSet root @?= Set.fromList [app, lib, util]
                    -- The leaves are the seed, the facts the provider stated,
                    -- and the two holes the solver found: util has no version 1
                    -- and no version 2.
                    let leaves = externals root
                    [f | Just f <- map asFact leaves, isWants f] @?= [Wants app (Set.fromList [1])]
                    sort [h | Just h <- map asNoValues leaves] @?= [(util, Set.fromList [1]), (util, Set.fromList [2])]
        ]
  where
    isWants Wants{} = True
    isWants _       = False
