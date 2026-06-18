{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module VersionSetSpec (tests) where

import           Distribution.Version  (Version, mkVersion, orLaterVersion)
import           PubGrub.VersionSet    (VersionSet)
import qualified PubGrub.VersionSet    as VS
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
        pure (foldr VS.union VS.empty pieces)
      where
        genPiece = do
            kind <- elements [0 :: Int, 1, 2]
            a <- genVersion
            b <- genVersion
            let lo = min a b; hi = max a b
            pure $ case kind of
                0 -> VS.singleton a
                1 -> VS.fromVersionRange (orLaterVersion lo)
                _ ->
                    VS.intersection
                        (VS.fromVersionRange (orLaterVersion lo))
                        (VS.complement (VS.fromVersionRange (orLaterVersion hi)))

sampleVersions :: [Version]
sampleVersions = [mkVersion [a, b] | a <- [0 .. 3], b <- [0 .. 3]]

tests :: TestTree
tests =
    testGroup
        "VersionSet"
        [ testProperty "complement is involutive" $ \(s :: VersionSet) ->
            VS.complement (VS.complement s) === s
        , testProperty "De Morgan (union)" $ \(a :: VersionSet) (b :: VersionSet) ->
            VS.complement (VS.union a b) === VS.intersection (VS.complement a) (VS.complement b)
        , testProperty "De Morgan (intersection)" $ \(a :: VersionSet) (b :: VersionSet) ->
            VS.complement (VS.intersection a b) === VS.union (VS.complement a) (VS.complement b)
        , testProperty "intersection membership" $ \(a :: VersionSet) (b :: VersionSet) ->
            conjoinV $ \v ->
                VS.contains (VS.intersection a b) v === (VS.contains a v && VS.contains b v)
        , testProperty "union membership" $ \(a :: VersionSet) (b :: VersionSet) ->
            conjoinV $ \v ->
                VS.contains (VS.union a b) v === (VS.contains a v || VS.contains b v)
        , testProperty "complement membership" $ \(a :: VersionSet) ->
            conjoinV $ \v -> VS.contains (VS.complement a) v === not (VS.contains a v)
        , testProperty "singleton contains exactly its version" $ \(NonEmptyVer v) ->
            VS.contains (VS.singleton v) v
                .&&. conjoinV
                    ( \w ->
                        if w == v
                            then property True
                            else VS.contains (VS.singleton v) w === False
                    )
        , testProperty "subsetOf agrees with intersection" $ \(a :: VersionSet) (b :: VersionSet) ->
            VS.subsetOf a b === (VS.intersection a b == a)
        , testGroup
            "Lattice laws"
            [ testProperty "union commutative" $ \(a :: VersionSet) b -> VS.union a b === VS.union b a
            , testProperty "intersection commutative" $ \(a :: VersionSet) b -> VS.intersection a b === VS.intersection b a
            , testProperty "union idempotent" $ \(a :: VersionSet) -> VS.union a a === a
            , testProperty "absorption" $ \(a :: VersionSet) b ->
                VS.union a (VS.intersection a b) === a
            ]
        ]
  where
    conjoinV f = foldr (.&&.) (property True) (map f sampleVersions)

newtype NonEmptyVer = NonEmptyVer Version deriving Show
instance Arbitrary NonEmptyVer where
    arbitrary = NonEmptyVer <$> genVersion
