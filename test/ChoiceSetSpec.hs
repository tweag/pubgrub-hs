{-# LANGUAGE ScopedTypeVariables #-}

module ChoiceSetSpec (tests) where

import           Distribution.Types.PackageName (PackageName, mkPackageName)
import           Distribution.Types.UnitId      (mkUnitId)
import           Distribution.Version           (Version, mkVersion)
import           PubGrub.Choice
import           PubGrub.Compiler               (PackageDb (..))
import           PubGrub.Lattice
import           Test.Tasty                     (TestTree, testGroup)
import           Test.Tasty.HUnit               (testCase, (@?=))

pkg :: PackageName
pkg = mkPackageName "foo"

ver :: [Int] -> Version
ver = mkVersion

inst :: String -> [Int] -> Choice
inst uid v = Installed (ChoiceInstalled pkg (ver v) GlobalDb (mkUnitId uid))

src :: [Int] -> Choice
src v = Source (ChoiceSource pkg (ver v) Hackage)

tests :: TestTree
tests =
    testGroup
        "ChoiceSet"
        [ testCase "installed singleton contains itself" $
            member (inst "u1" [1]) (singleton (inst "u1" [1]) :: ChoiceSet) @?= True
        , testCase "installed singleton excludes a different unit-id at the same version" $
            member (inst "u2" [1]) (singleton (inst "u1" [1]) :: ChoiceSet) @?= False
        , testCase "source singleton contains itself" $
            member (src [1]) (singleton (src [1]) :: ChoiceSet) @?= True
        , testCase "installed singleton excludes the source world (same version)" $
            member (src [1]) (singleton (inst "u1" [1]) :: ChoiceSet) @?= False
        , testCase "source singleton excludes the installed world (same version)" $
            member (inst "u1" [1]) (singleton (src [1]) :: ChoiceSet) @?= False
        , testCase "bottom contains nothing" $
            member (inst "u1" [1]) (bottom :: ChoiceSet) @?= False
        , testCase "top contains both worlds" $
            ( member (inst "u1" [1]) (top :: ChoiceSet)
                && member (src [1]) (top :: ChoiceSet)
            )
                @?= True
        , testCase "neg complements installed membership" $
            member (inst "u1" [1]) (neg (singleton (inst "u1" [1])) :: ChoiceSet) @?= False
        , testCase "neg complements source membership" $
            member (src [1]) (neg (singleton (src [1])) :: ChoiceSet) @?= False
        , testCase "union is membership-or across worlds" $
            let s = singleton (inst "u1" [1]) \/ singleton (src [2]) :: ChoiceSet
             in (member (inst "u1" [1]) s && member (src [2]) s) @?= True
        , testCase "intersection of disjoint worlds is bottom" $
            let s = singleton (inst "u1" [1]) /\ singleton (src [1]) :: ChoiceSet
             in isBottom s @?= True
        ]
