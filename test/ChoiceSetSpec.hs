{-# LANGUAGE ScopedTypeVariables #-}

module ChoiceSetSpec (tests) where

import           Distribution.Types.UnitId (mkUnitId)
import           Distribution.Version      (Version, mkVersion)
import           PubGrub.Choice
import           PubGrub.Lattice
import           Test.Tasty                (TestTree, testGroup)
import           Test.Tasty.HUnit          (testCase, (@?=))

ver :: [Int] -> Version
ver = mkVersion

inst :: String -> Choice
inst uid = Installed (mkUnitId uid)

src :: [Int] -> Choice
src v = Source (ver v)

tests :: TestTree
tests =
    testGroup
        "ChoiceSet"
        [ testCase "installed singleton contains itself" $
            member (inst "u1") (singleton (inst "u1") :: ChoiceSet) @?= True
        , testCase "installed singleton excludes a different unit-id at the same version" $
            member (inst "u2") (singleton (inst "u1") :: ChoiceSet) @?= False
        , testCase "source singleton contains itself" $
            member (src [1]) (singleton (src [1]) :: ChoiceSet) @?= True
        , testCase "installed singleton excludes the source world (same version)" $
            member (src [1]) (singleton (inst "u1") :: ChoiceSet) @?= False
        , testCase "source singleton excludes the installed world (same version)" $
            member (inst "u1") (singleton (src [1]) :: ChoiceSet) @?= False
        , testCase "bottom contains nothing" $
            member (inst "u1") (bottom :: ChoiceSet) @?= False
        , testCase "top contains both worlds" $
            ( member (inst "u1") (top :: ChoiceSet)
                && member (src [1]) (top :: ChoiceSet)
            )
                @?= True
        , testCase "neg complements installed membership" $
            member (inst "u1") (neg (singleton (inst "u1")) :: ChoiceSet) @?= False
        , testCase "neg complements source membership" $
            member (src [1]) (neg (singleton (src [1])) :: ChoiceSet) @?= False
        , testCase "union is membership-or across worlds" $
            let s = singleton (inst "u1") \/ singleton (src [2]) :: ChoiceSet
             in (member (inst "u1") s && member (src [2]) s) @?= True
        , testCase "intersection of disjoint worlds is bottom" $
            let s = singleton (inst "u1") /\ singleton (src [1]) :: ChoiceSet
             in isBottom s @?= True
        ]
