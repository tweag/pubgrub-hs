{-# LANGUAGE OverloadedStrings #-}

-- | "PubGrub.Cookbook" against what it shows: its code is "Cookbook", and
-- every result its sessions print is asserted here.
module CookbookSpec (tests) where

import qualified Data.Map.Strict  as Map
import qualified Data.Text        as T
import           DocCode          (codeMatches)
import           PubGrub          (fullVersionSet, mkVersion,
                                   singletonVersionSet)
import           Test.Tasty       (TestTree, testGroup)
import           Test.Tasty.HUnit (testCase, (@?=))

import           Cookbook

tests :: TestTree
tests =
    testGroup
        "the cookbook"
        [ testCase "its code is Cookbook.hs" $
            codeMatches "src/PubGrub/Cookbook.hs" "test/Cookbook.hs"
        , testCase "a plan" $
            plan example [request app fullVersionSet]
                @?= Just (Map.fromList [(app, mkVersion [1]), (lib, mkVersion [2]), (util, mkVersion [2])])
        , testCase "a constraint on a requested package" $
            plan example [request app fullVersionSet, constrain util (range [1] [2])]
                @?= Just (Map.fromList [(app, mkVersion [1]), (lib, mkVersion [2]), (util, mkVersion [1])])
        , testCase "a constraint on a package nothing requests" $
            plan example [request app fullVersionSet, constrain extra (range [2] [3])]
                @?= Just (Map.fromList [(app, mkVersion [1]), (lib, mkVersion [2]), (util, mkVersion [2])])
        , testCase "an explanation in the domain's words" $
            T.lines (why example [request app fullVersionSet, constrain util (range [3] [4])])
                @?= [ "Because app >=1 depends on lib >=1 && <2.1 which depends on util >=1 && <3, app >=1 requires util >=1 && <3."
                    , "And because no version of app <1 exists, app >=0 requires util >=1 && <3."
                    , "So, because app >=0 is requested and util >=3 && <4 is required by a constraint, version solving failed."
                    ]
        , testCase "a release passed over, with its reason" $
            why example [request lib (singletonVersionSet (mkVersion [2, 1]))]
                @?= "So, because lib >=2.1 cannot be used: it does not build here and lib ==2.1 is requested, version solving failed."
        , testCase "the search, step by step" $
            searchLog example [request app fullVersionSet, constrain util (range [3] [4])]
                @?= [ "app 1"
                    , "lib 2"
                    , "learned: lib >=2 && <2.1 requires util >=1 && <3"
                    , "back to level 1"
                    , "lib 1"
                    , "learned: app >=1 requires util >=1 && <3"
                    , "back to level 0"
                    , "no app in <1"
                    ]
        , testCase "a lock released where it took part in a failure" $
            either (const Nothing) Just
                ( solveWithLock
                    example
                    (Map.fromList [(util, mkVersion [1]), (extra, mkVersion [1])])
                    [request app fullVersionSet, request util (range [2] [3]), request extra fullVersionSet]
                )
                @?= Just (Map.fromList [(app, mkVersion [1]), (extra, mkVersion [1]), (lib, mkVersion [2]), (util, mkVersion [2])])
        ]
