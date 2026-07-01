{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Laws for 'SourceConfigSet', a set of (version, flag assignment) pairs.
--
-- Each operation is checked against its denotation over a finite universe of
-- 3 versions and 2 flags (12 configurations): it must match the corresponding
-- set operation on the elements it denotes. This is the exploratory spike in
-- @docs\/flags-spike.hs@, promoted to a test.
module SourceConfigSpec (tests) where

import           Data.Map.Strict         (Map)
import qualified Data.Map.Strict         as Map
import           Data.Set                (Set)
import qualified Data.Set                as Set

import           Distribution.Types.Flag (FlagName, mkFlagName)
import           Distribution.Version    (Version, mkVersion)

import           PubGrub.Lattice
import           PubGrub.SourceConfig
import           PubGrub.VersionSet      (VersionSet)
import qualified PubGrub.VersionSet      as VS

import           Test.Tasty              (TestTree, testGroup)
import           Test.Tasty.HUnit        (testCase, (@?=))
import           Test.Tasty.QuickCheck   (Arbitrary (..), Gen, elements, oneof,
                                          sublistOf, testProperty, (===))

--------------------------------------------------------------------------------
-- Finite universe
--------------------------------------------------------------------------------

flagNames :: [FlagName]
flagNames = [mkFlagName "a", mkFlagName "b"]

versions :: [Version]
versions = [mkVersion [1], mkVersion [2], mkVersion [3]]

-- Every total assignment over the flag universe
allAssignments :: [Map FlagName Bool]
allAssignments = [Map.fromList (zip flagNames bs) | bs <- mapM (const [False, True]) flagNames]

universe :: [SourceConfig]
universe = [SourceConfig v m | v <- versions, m <- allAssignments]

universeSet :: Set SourceConfig
universeSet = Set.fromList universe

denot :: SourceConfigSet -> Set SourceConfig
denot s = Set.fromList [e | e <- universe, member e s]

--------------------------------------------------------------------------------
-- Generators
--------------------------------------------------------------------------------

genVersionSet :: Gen VersionSet
genVersionSet = do
    picked <- sublistOf versions
    pure (foldr (\/) bottom (map VS.singleton picked))

genFlagConj :: Gen FlagConj
genFlagConj =
    oneof
        [ pure FCBottom
        , do
            fs <- sublistOf flagNames
            bs <- mapM (const arbitrary) fs
            pure (FCConj (Map.fromList (zip fs bs)))
        ]

instance Arbitrary FlagConj where
    arbitrary = genFlagConj

instance Arbitrary SourceConfigSet where
    arbitrary = do
        k <- elements [0 :: Int, 1, 2, 3]
        cs <- sequence (replicate k (mkCell <$> genVersionSet <*> genFlagConj))
        pure (foldr (\/) bottom cs)

instance Arbitrary SourceConfig where
    arbitrary = elements universe

--------------------------------------------------------------------------------

constrainFlag :: String -> Bool -> SourceConfigSet
constrainFlag f b = mkCell VS.full (FCConj (Map.singleton (mkFlagName f) b))

cfg :: [Int] -> [(String, Bool)] -> SourceConfig
cfg v fs = SourceConfig (mkVersion v) (Map.fromList [(mkFlagName f, b) | (f, b) <- fs])

-- | A singleton set, with the type pinned (the @Elem@ family is not injective).
decision :: SourceConfig -> SourceConfigSet
decision = singleton

tests :: TestTree
tests =
    testGroup
        "SourceConfig"
        [ testGroup
            "denotation homomorphism"
            [ testProperty "join denotes union" $ \(a :: SourceConfigSet) b ->
                denot (a \/ b) === Set.union (denot a) (denot b)
            , testProperty "meet denotes intersection" $ \(a :: SourceConfigSet) b ->
                denot (a /\ b) === Set.intersection (denot a) (denot b)
            , testProperty "neg denotes complement" $ \(a :: SourceConfigSet) ->
                denot (neg a) === Set.difference universeSet (denot a)
            , testProperty "member agrees with denotation" $ \(a :: SourceConfigSet) (e :: SourceConfig) ->
                member e a === Set.member e (denot a)
            , testProperty "singleton denotes a point" $ \(e :: SourceConfig) ->
                denot (singleton e) === Set.singleton e
            , testProperty "isBottom iff empty denotation" $ \(a :: SourceConfigSet) ->
                isBottom a === Set.null (denot a)
            , testProperty "semantic Eq iff equal denotation" $ \(a :: SourceConfigSet) b ->
                (a == b) === (denot a == denot b)
            ]
        , testGroup
            -- isTop quantifies over the whole, infinite version space, which the
            -- finite universe cannot check, so these are targeted cases rather
            -- than a denotation property.
            "isTop (global)"
            [ testCase "top is top" $ isTop (top :: SourceConfigSet) @?= True
            , testCase "bottom is not top" $ isTop (bottom :: SourceConfigSet) @?= False
            , testCase "one pinned flag is not top" $
                isTop (constrainFlag "a" True) @?= False
            , testCase "both values of a flag (all versions) is top" $
                isTop (constrainFlag "a" True \/ constrainFlag "a" False) @?= True
            ]
        , testGroup
            "Boolean laws"
            [ testProperty "idempotent join" $ \(a :: SourceConfigSet) -> (a \/ a) === a
            , testProperty "idempotent meet" $ \(a :: SourceConfigSet) -> (a /\ a) === a
            , testProperty "commutative join" $ \(a :: SourceConfigSet) b -> (a \/ b) === (b \/ a)
            , testProperty "commutative meet" $ \(a :: SourceConfigSet) b -> (a /\ b) === (b /\ a)
            , testProperty "associative join" $ \(a :: SourceConfigSet) b c -> ((a \/ b) \/ c) === (a \/ (b \/ c))
            , testProperty "associative meet" $ \(a :: SourceConfigSet) b c -> ((a /\ b) /\ c) === (a /\ (b /\ c))
            , testProperty "absorption join" $ \(a :: SourceConfigSet) b -> (a \/ (a /\ b)) === a
            , testProperty "absorption meet" $ \(a :: SourceConfigSet) b -> (a /\ (a \/ b)) === a
            , testProperty "complement meet is bottom" $ \(a :: SourceConfigSet) -> isBottom (a /\ neg a)
            , testProperty "complement join is top" $ \(a :: SourceConfigSet) -> isTop (a \/ neg a)
            , testProperty "double negation" $ \(a :: SourceConfigSet) -> neg (neg a) === a
            , testProperty "De Morgan" $ \(a :: SourceConfigSet) b ->
                neg (a \/ b) === (neg a /\ neg b)
            ]
        , testGroup
            "leniency (per-version flag domain)"
            [ testCase "a version declaring only 'a' satisfies a constraint on 'b'" $
                member (cfg [1] [("a", True)]) (constrainFlag "b" True) @?= True
            , testCase "a declared flag is enforced" $
                member (cfg [1] [("a", True)]) (constrainFlag "a" False) @?= False
            ]
        , testGroup
            "backtracking (point subtraction)"
            [ testCase "neg(decision) excludes exactly the decided point" $
                member (cfg [2] [("a", True), ("b", True)]) (neg (decision (cfg [2] [("a", True), ("b", True)]))) @?= False
            , testCase "neg(decision) keeps a different flag config of the same version" $
                member (cfg [2] [("a", False), ("b", True)]) (neg (decision (cfg [2] [("a", True), ("b", True)]))) @?= True
            , testCase "neg(decision) keeps other versions" $
                member (cfg [1] [("a", True), ("b", True)]) (neg (decision (cfg [2] [("a", True), ("b", True)]))) @?= True
            ]
        , testGroup
            "semantic equality is required"
            [ testCase "a 4-cell cover of everything equals the 1-cell top" $
                let e0 = cfg [1] [("a", False), ("b", False)]
                 in (decision e0 \/ neg (decision e0)) == top @?= True
            ]
        ]
