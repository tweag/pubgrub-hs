-- | Differential tests for the 'InstanceSet' and 'ValueSet' algebras.
--
-- The strategy is to fix a small finite universe of instances and compare the
-- real implementation against the obvious extensional model — a plain list of
-- the universe's members, filtered by 'memberInstance'. Every operation must
-- commute with that projection:
--
-- @
-- model (a `union` b)  ==  model a ∪ model b
-- @
--
-- The source half is a range over /all/ of version space, and the universe
-- here is five points of it, so a range such as @<1@ is non-empty while
-- containing no instance of the universe. The emptiness-based predicates are
-- therefore checked in the one direction a finite sample can check: a claim
-- they make is always true of the model. Their exactness over version space
-- is 'VersionSetSpec''s business.
--
-- The 'Term' properties matter as much as the set ones: 'Term' is what the
-- solver actually manipulates, and a wrong @difference@ shows up there as a
-- bogus 'Contradicted' — which is how a bad set algebra becomes a wrong
-- "no solution".
module InstanceSetSpec (tests) where

import qualified Data.Set                   as Set
import           Distribution.Types.UnitId  (mkUnitId)
import           Distribution.Version       (earlierVersion, orLaterVersion)
import           PubGrub.Cabal.PreInstalled (PreInstalledPackage (..))
import           PubGrub.Cabal.InstanceSet        (Instance (..), InstanceSet (..),
                                             emptyInstanceSet, memberInstance,
                                             singletonInstance)
import           PubGrub.Relation           (Relation (..), relation)
import           PubGrub.SetOps             (SetOps (..), equivalent,
                                             isDisjoint, isSubsetOf)
import           PubGrub.Term               (Term (..), intersectTerm,
                                             isBottomTerm, isTopTerm,
                                             negateTerm, unionTerm)
import           PubGrub.Cabal.Value              (BoolSet (..), Value (..),
                                             boolSet,
                                             flagSet, instanceSet,
                                             memberValue, singletonValue)
import           PubGrub.Cabal.Version            (Version, mkVersion,
                                             toCabalVersion)
import           PubGrub.Cabal.VersionSet         (VersionSet, emptyVersionSet,
                                             fromVersionRange, fullVersionSet,
                                             singletonVersionSet)
import           Test.Tasty                 (TestTree, testGroup)
import           Test.Tasty.QuickCheck      (Arbitrary (..), Gen, elements,
                                             oneof, sized, sublistOf,
                                             testProperty, (===))

-- --------------------------------------------------------------------------
-- The universe
-- --------------------------------------------------------------------------

versions :: [Version]
versions = [mkVersion [k] | k <- [1 .. 5]]

installed :: [PreInstalledPackage]
installed =
    [ PreInstalledPackage (mkUnitId "u1") (mkVersion [2]) []
    , PreInstalledPackage (mkUnitId "u2") (mkVersion [4]) []
    ]

universe :: [Instance]
universe = map UsePreInstalled installed ++ map BuildSource versions

-- | The extension of a set over the universe.
model :: InstanceSet -> Set.Set Instance
model s = Set.fromList [i | i <- universe, memberInstance i s]

-- --------------------------------------------------------------------------
-- Generators
-- --------------------------------------------------------------------------

genVersionSet :: Gen VersionSet
genVersionSet = sized go
  where
    go n
        | n <= 1 = oneof [atom, pure emptyVersionSet, pure fullVersionSet]
        | otherwise =
            oneof
                [ atom
                , union <$> go (n `div` 2) <*> go (n `div` 2)
                , intersect <$> go (n `div` 2) <*> go (n `div` 2)
                , difference <$> go (n `div` 2) <*> go (n `div` 2)
                ]
    atom =
        oneof
            [ singletonVersionSet <$> elements versions
            , fromVersionRange . orLaterVersion . toCabalVersion <$> elements versions
            , fromVersionRange . earlierVersion . toCabalVersion <$> elements versions
            ]

newtype Sym = Sym InstanceSet
    deriving (Show)

instance Arbitrary Sym where
    arbitrary = do
        units <- sublistOf installed
        vs <- genVersionSet
        pure (Sym (InstanceSet (Set.fromList units) vs))

newtype SymTerm = SymTerm (Term InstanceSet)
    deriving (Show)

instance Arbitrary SymTerm where
    arbitrary = do
        Sym s <- arbitrary
        SymTerm <$> elements [Positive s, Negative s]

-- | A term's extension: over the universe extended by the absent state.
data State = Absent | Present Instance
    deriving (Eq, Ord, Show)

termModel :: Term InstanceSet -> Set.Set State
termModel (Positive s) = Set.map Present (model s)
termModel (Negative s) = Set.insert Absent (Set.map Present (Set.fromList universe `Set.difference` model s))

-- --------------------------------------------------------------------------
-- Tests
-- --------------------------------------------------------------------------

tests :: TestTree
tests =
    testGroup
        "InstanceSet"
        [ testGroup
            "operations commute with the extensional model"
            [ testProperty "union" $ \(Sym a) (Sym b) ->
                model (a `union` b) === model a `Set.union` model b
            , testProperty "intersect" $ \(Sym a) (Sym b) ->
                model (a `intersect` b) === model a `Set.intersection` model b
            , testProperty "difference" $ \(Sym a) (Sym b) ->
                model (a `difference` b) === model a `Set.difference` model b
            ]
        , testGroup
            "a claim is always true of the model"
            [ testProperty "isEmpty" $ \(Sym a) ->
                not (isEmpty a) || Set.null (model a)
            , testProperty "isSubsetOf" $ \(Sym a) (Sym b) ->
                not (isSubsetOf a b) || model a `Set.isSubsetOf` model b
            , testProperty "isDisjoint" $ \(Sym a) (Sym b) ->
                not (isDisjoint a b) || Set.null (model a `Set.intersection` model b)
            , -- The direct forms answer exactly what the set-building defaults
              -- would: 'isEmpty' is exact on an instance set, and on a term both
              -- sides go through the same one-sided test.
              testProperty "isSubsetOf is the emptiness of the difference" $ \(Sym a) (Sym b) ->
                isSubsetOf a b === isEmpty (a `difference` b)
            , testProperty "isDisjoint is the emptiness of the intersection" $ \(Sym a) (Sym b) ->
                isDisjoint a b === isEmpty (a `intersect` b)
            , testProperty "on terms, likewise" $ \(SymTerm x) (SymTerm y) ->
                (isSubsetOf x y, isDisjoint x y) === (isEmpty (x `difference` y), isEmpty (x `intersect` y))
            , testProperty "equivalent" $ \(Sym a) (Sym b) ->
                not (equivalent a b) || model a == model b
            , testProperty "Eq" $ \(Sym a) (Sym b) ->
                a /= b || model a == model b
            , -- The direction the sample can settle: a set whose range holds one of
              -- the universe's versions, or an installed unit, is never called empty.
              testProperty "a set with a member is not empty" $ \(Sym a) ->
                Set.null (model a) || not (isEmpty a)
            ]
        , testGroup
            "constructors"
            [ testProperty "the empty set contains nothing" $
                model emptyInstanceSet === Set.empty
            , testProperty "singletonInstance denotes exactly that instance" $
                \i -> model (singletonInstance (universe !! (abs i `mod` length universe)))
                        === Set.singleton (universe !! (abs i `mod` length universe))
            ]
        , testGroup
            "terms"
            [ testProperty "intersectTerm" $ \(SymTerm x) (SymTerm y) ->
                termModel (intersectTerm x y) === termModel x `Set.intersection` termModel y
            , testProperty "unionTerm" $ \(SymTerm x) (SymTerm y) ->
                termModel (unionTerm x y) === termModel x `Set.union` termModel y
            , testProperty "negateTerm is complement" $ \(SymTerm x) ->
                termModel (negateTerm x) === everything `Set.difference` termModel x
            , testProperty "isTopTerm only claims a real top" $ \(SymTerm x) ->
                not (isTopTerm x) || termModel x == everything
            , testProperty "isBottomTerm only claims a real bottom" $ \(SymTerm x) ->
                not (isBottomTerm x) || Set.null (termModel x)
            , testProperty "relation never claims a relation the model denies" $ \(SymTerm x) (SymTerm y) ->
                case relation x y of
                    Satisfied    -> termModel x `Set.isSubsetOf` termModel y
                    Contradicted -> Set.null (termModel x `Set.intersection` termModel y)
                    Inconclusive -> True
            ]
        , testGroup
            "flag value sets"
            [ testProperty "BoolSet operations commute with the model" $ \a b c ->
                let x = BoolSet a b
                    y = BoolSet c (a /= c)
                    m (BoolSet f t) = Set.fromList ([False | f] ++ [True | t])
                 in (m (x `union` y), m (x `intersect` y), m (x `difference` y))
                        === (m x `Set.union` m y, m x `Set.intersection` m y, m x `Set.difference` m y)
            , testProperty "a flag value is a member of its own singleton only" $ \b ->
                (memberValue (FlagValue b) (singletonValue (FlagValue b)), memberValue (FlagValue (not b)) (singletonValue (FlagValue b)))
                    === (True, False)
            , testProperty "a package value never belongs to a flag set, nor the reverse" $ \b ->
                (memberValue (PackageValue (BuildSource (mkVersion [1]))) (flagSet (boolSet b)), memberValue (FlagValue b) (instanceSet emptyInstanceSet))
                    === (False, False)
            ]
        ]
  where
    everything = Set.insert Absent (Set.map Present (Set.fromList universe))
