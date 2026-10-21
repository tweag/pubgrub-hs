{-# LANGUAGE OverloadedStrings #-}

-- | The solver over a domain that is not cabal's.
--
-- 'PubGrub.Incompatibility.Domain' is the whole of what the algorithm asks of
-- a problem, and this module is the proof: the domain is "Toy", where a package
-- is a name, a value is an 'Int', a set of values is a 'Set' and a fact is one
-- of two sentences, and nothing from Cabal-syntax or "PubGrub.Cabal" is
-- imported. If the core leans on the cabal domain, this module stops
-- compiling.
--
-- "Toy" is also the code of "PubGrub.Tutorial", line for line, so the tests
-- here hold the tutorial to what it shows: its code is checked against "Toy",
-- and every result it prints is asserted.
module ToyDomainSpec (tests) where

import           Data.Functor.Identity   (Identity, runIdentity)
import           Data.List               (sort, tails)
import qualified Data.Map.Strict         as Map
import qualified Data.Set                as Set
import           Data.Text               (Text)
import qualified Data.Text               as T
import           DocCode                 (codeMatches)
import           PubGrub.Derivation      (asFact, asNoValues, conflictSet,
                                          externals)
import           PubGrub.Incompatibility (Cause (..), Incompatibility (..))
import           PubGrub.Provider        (Provider (..))
import           PubGrub.Solver          (SolveError (..), solve)
import           PubGrub.Term            (Term (..))
import           Test.Tasty              (TestTree, testGroup)
import           Test.Tasty.HUnit        (assertBool, assertFailure, testCase,
                                          (@?=))
import           Toy

tests :: TestTree
tests =
    testGroup
        "a domain that is not cabal's"
        [ testCase "solves, backtracking from lib 2 to lib 1" $
            plan world [wants app [1]] @?= Just (Map.fromList [(app, 1), (lib, 1), (util, 1)])
        , testCase "fails when nothing fits, and the derivation reads back" $
            case runIdentity (solve mempty (provider broken) [wants app [1]]) of
                Right plan' -> assertFailure ("expected no solution, got " ++ show plan')
                Left (NoSatisfier p _) -> assertFailure ("no satisfier for " ++ show p)
                Left (BadSeed _) -> assertFailure "the seed was refused"
                Left (BadValue p v _) -> assertFailure ("bad value " ++ show v ++ " for " ++ show p)
                Left (NoSolution root) -> do
                    -- The root is the empty clause, closed against the seeds.
                    Map.keys (incompTerms root) @?= []
                    -- Every variable the search touched is in the conflict set.
                    conflictSet root @?= Set.fromList [app, lib, util]
                    -- The leaves are the seed, the facts the provider stated,
                    -- and the two holes the solver found: util has no version 1
                    -- and no version 2.
                    let leaves = externals root
                    [p | Just (Wants p vs) <- map asFact leaves, vs == Set.fromList [1]] @?= [app]
                    sort [h | Just h <- map asNoValues leaves] @?= [(util, Set.fromList [1]), (util, Set.fromList [2])]
        , testGroup
            "the boundary"
            [ testCase "a seed of two negative terms is refused, not solved to an empty plan" $
                -- "app is 1 or lib is 1": neither variable is ever almost
                -- satisfied, so nothing would be decided and the empty plan
                -- would violate the seed.
                case runIdentity (solve mempty (provider world) [eitherOf app lib]) of
                    Left (BadSeed _) -> pure ()
                    Left _           -> assertFailure "refused for another reason"
                    Right plan'      -> assertFailure ("solved to " ++ show plan')
            , testCase "a request whose cause is not Seed is refused" $
                case runIdentity (solve mempty (provider world) [needs app 1 lib [1]]) of
                    Left (BadSeed _) -> pure ()
                    Left _           -> assertFailure "refused for another reason"
                    Right plan'      -> assertFailure ("solved to " ++ show plan')
            , testCase "a provider that answers outside the offered set stops the solve" $
                case runIdentity (solve mempty outside [wants app [1]]) of
                    Left (BadValue p v s) -> (p, v, s) @?= (app, 99, Set.fromList [1])
                    Left _                -> assertFailure "failed for another reason"
                    Right plan'           -> assertFailure ("solved to " ++ show plan')
            ]
        , testGroup
            "the tutorial"
            [ testCase "its code is Toy.hs" $
                codeMatches "src/PubGrub/Tutorial.hs" "test/Toy.hs"
            , testCase "a dependency's terms" $
                incompTerms (needs (Pkg "lib") 1 (Pkg "util") [1])
                    @?= Map.fromList [(Pkg "lib", Positive (Set.fromList [1])), (Pkg "util", Negative (Set.fromList [1]))]
            , testCase "the provider picks the newest" $
                fst (runIdentity (expand (provider world) lib (Set.fromList [1, 2]))) @?= Just 2
            , testCase "the broken world has no plan" $
                plan broken [wants app [1]] @?= Nothing
            , testCase "the explanation" $
                T.lines (why broken [wants app [1]]) @?= expectedProof
            , testCase "the README shows its explanation" $ do
                readme <- T.lines . T.pack <$> readFile "README.md"
                assertBool "the README quotes the explanation the tutorial prints" $
                    expectedProof `elem` [take (length expectedProof) rest | rest <- tails readme]
            , testCase "the original world has a plan" $
                why world [wants app [1]] @?= "There is a plan."
            ]
        ]

-- | A seed that says "@p@ is 1 or @q@ is 1": two negative terms, which is not
-- a request.
eitherOf :: Pkg -> Pkg -> Incompatibility Toy
eitherOf p q =
    Incompatibility
        (Map.fromList [(p, Negative (Set.singleton 1)), (q, Negative (Set.singleton 1))])
        (Seed (Wants p (Set.singleton 1)))

-- | A provider that ignores the set it is offered.
outside :: Provider Toy Identity
outside = Provider (\_ _ -> pure (Just 99, []))

-- | The proof, as the spec's three cases render the derivation above: the two
-- refutations of @lib@ are two branches (@references\/pubgrub.md:595@), so the
-- first ends on a numbered line and the second refers back to it (@:608@), and
-- the closing line ends in \"version solving failed\" (@:1030@).
expectedProof :: [Text]
expectedProof =
    [ "1. Because lib 1 depends on util 1 and util has no version 1, lib 1 is forbidden."
    , ""
    , "Because util has no version 2 and lib 2 depends on util 2, lib 2 is forbidden."
    , "And because lib 1 is forbidden (1), lib 1 or 2 is forbidden."
    , "So, because app 1 depends on lib 1 or 2 and app 1 is requested, version solving failed."
    ]
