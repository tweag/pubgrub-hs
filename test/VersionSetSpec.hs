{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module VersionSetSpec (tests) where

import           Distribution.Version  (Version, mkVersion, orLaterVersion)
import           PubGrub.SetOps        (isSubsetOf)
import           PubGrub.VersionSet
import           Test.Tasty            (TestTree, testGroup)
import           Test.Tasty.QuickCheck (Arbitrary (..), Gen, choose, elements,
                                        listOf, property, testProperty, (.&&.),
                                        (===))

-- Small bounded version universe: components drawn from 0..3, length 1..3.
genVersion :: Gen Version
genVersion = do
    n <- choose (1, 3)
    cs <- vectorOfRange n (choose (0, 3))
    pure (mkVersion cs)
  where
    vectorOfRange k g = sequence (replicate k g)

-- A version set built from a handful of random singletons/ranges, unioned.
instance Arbitrary VersionSet where
    arbitrary = do
        pieces <- listOf genPiece
        pure (foldr unionVersionSet emptyVersionSet pieces)
      where
        genPiece = do
            kind <- elements [0 :: Int, 1, 2]
            a <- genVersion
            b <- genVersion
            let lo = min a b; hi = max a b
            pure $ case kind of
                0 -> singletonVersionSet a
                1 -> fromVersionRange (orLaterVersion lo)
                _ ->
                    intersectionVersionSet
                        (fromVersionRange (orLaterVersion lo))
                        (complementVersionSet (fromVersionRange (orLaterVersion hi)))

sampleVersions :: [Version]
sampleVersions = [mkVersion [a, b] | a <- [0 .. 3], b <- [0 .. 3]]

tests :: TestTree
tests =
    testGroup
        "VersionSet"
        [ testProperty "complement is involutive" $ \(s :: VersionSet) ->
            complementVersionSet (complementVersionSet s) === s
        , testProperty "De Morgan (union)" $ \(a :: VersionSet) (b :: VersionSet) ->
            complementVersionSet (unionVersionSet a b) === intersectionVersionSet (complementVersionSet a) (complementVersionSet b)
        , testProperty "De Morgan (intersection)" $ \(a :: VersionSet) (b :: VersionSet) ->
            complementVersionSet (intersectionVersionSet a b) === unionVersionSet (complementVersionSet a) (complementVersionSet b)
        , testProperty "intersection membership" $ \(a :: VersionSet) (b :: VersionSet) ->
            conjoinV $ \v ->
                contains (intersectionVersionSet a b) v === (contains a v && contains b v)
        , testProperty "union membership" $ \(a :: VersionSet) (b :: VersionSet) ->
            conjoinV $ \v ->
                contains (unionVersionSet a b) v === (contains a v || contains b v)
        , testProperty "complement membership" $ \(a :: VersionSet) ->
            conjoinV $ \v -> contains (complementVersionSet a) v === not (contains a v)
        , testProperty "singleton contains exactly its version" $ \(NonEmptyVer v) ->
            contains (singletonVersionSet v) v
                .&&. conjoinV
                    ( \w ->
                        if w == v
                            then property True
                            else contains (singletonVersionSet v) w === False
                    )
        , testProperty "isSubsetOf agrees with intersection" $ \(a :: VersionSet) (b :: VersionSet) ->
            isSubsetOf a b === (intersectionVersionSet a b == a)
        , testGroup
            "Lattice laws"
            [ testProperty "union commutative" $ \(a :: VersionSet) b -> unionVersionSet a b === unionVersionSet b a
            , testProperty "intersection commutative" $ \(a :: VersionSet) b -> intersectionVersionSet a b === intersectionVersionSet b a
            , testProperty "union idempotent" $ \(a :: VersionSet) -> unionVersionSet a a === a
            , testProperty "absorption" $ \(a :: VersionSet) b ->
                unionVersionSet a (intersectionVersionSet a b) === a
            ]
        ]
  where
    conjoinV f = foldr ((.&&.) . f) (property True) sampleVersions

newtype NonEmptyVer = NonEmptyVer Version deriving Show
instance Arbitrary NonEmptyVer where
    arbitrary = NonEmptyVer <$> genVersion
