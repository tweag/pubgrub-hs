{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module VersionSetSpec (tests) where

import           Data.List                         (nub, sort)
import           Distribution.Types.VersionInterval (Bound (..),
                                                    LowerBound (..),
                                                    UpperBound (..),
                                                    VersionInterval (..))
import           Distribution.Version  (Version, VersionRange, anyVersion,
                                        earlierVersion, intersectVersionRanges,
                                        laterVersion, mkVersion, noVersion,
                                        orEarlierVersion, orLaterVersion,
                                        thisVersion, unionVersionRanges)
import           PubGrub.SetOps        (isSubsetOf)
import           PubGrub.VersionSet
import           Test.Tasty            (TestTree, testGroup)
import           Test.Tasty.QuickCheck (Arbitrary (..), Gen, choose, elements,
                                        forAll, listOf, oneof, property, sized,
                                        testProperty, (.&&.), (===))

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
            -- What the provider's version /slots/ rest on. A slot is
            -- @halfOpenVersionSet release (next release in the index)@. Slots
            -- touch, so they coalesce and tile without gaps, and an empty
            -- region between releases never becomes a term the solver has to
            -- learn about.
            "half-open ranges (version slots)"
            [ testProperty "holds its lower bound, up to but excluding the upper" $
                forAll (twoAscending genVersion) $ \(lo, hi) ->
                    conjoinV $ \v ->
                        contains (halfOpenVersionSet lo (Just hi)) v === (lo <= v && v < hi)
            , testProperty "adjacent ranges coalesce" $
                forAll (threeAscending genVersion) $ \(a, b, c) ->
                    unionVersionSet (halfOpenVersionSet a (Just b)) (halfOpenVersionSet b (Just c))
                        === halfOpenVersionSet a (Just c)
            , testProperty "consecutive ranges tile from the first bound up, with no holes" $
                forAll (ascendingList genVersion) $ \vs -> case vs of
                    [] -> property True
                    (first : _) ->
                        foldr
                            (unionVersionSet . uncurry halfOpenVersionSet)
                            emptyVersionSet
                            (zip vs (map Just (drop 1 vs) ++ [Nothing]))
                            === fromVersionRange (orLaterVersion first)
            , testProperty "empty when the bounds cross or meet" $
                forAll (twoAscending genVersion) $ \(lo, hi) ->
                    (halfOpenVersionSet hi (Just lo) === emptyVersionSet)
                        .&&. (halfOpenVersionSet lo (Just lo) === emptyVersionSet)
            ]
        , testGroup
            -- 'snapToVersions' drops version space no member of the universe
            -- occupies. Its whole contract is the pair "same versions of the
            -- universe" and "never larger than what it was given" — the first is
            -- what makes it sound to apply to a declared dependency range, the
            -- second is what stops a report quoting a range wider than its author
            -- wrote.
            "snapToVersions"
            [ testProperty "keeps exactly the universe members it had" $
                forAll (listOf genVersion) $ \universe (vs :: VersionSet) ->
                    foldr
                        ((.&&.) . (\v -> contains (snapToVersions universe vs) v === contains vs v))
                        (property True)
                        universe
            , testProperty "never grows the set" $
                forAll (listOf genVersion) $ \universe (vs :: VersionSet) ->
                    isSubsetOf (snapToVersions universe vs) vs
            , testProperty "idempotent" $
                forAll (listOf genVersion) $ \universe (vs :: VersionSet) ->
                    snapToVersions universe (snapToVersions universe vs)
                        === snapToVersions universe vs
            , testProperty "an empty universe snaps everything away" $ \(vs :: VersionSet) ->
                snapToVersions [] vs === emptyVersionSet
            ]
        , testGroup
            -- The operations work on the intervals directly. The reference is
            -- Cabal's combinators on 'VersionRange' syntax followed by Cabal's
            -- canonicaliser, and the operations must agree with it on the set and
            -- on the canonical /representation/, since the derived 'Eq' is
            -- semantic equality only while the form stays canonical.
            --
            -- Inputs come from 'genViaRange', which builds sets through Cabal's
            -- canonicaliser alone, so a bug in our own union cannot hide by
            -- producing agreeable inputs.
            "agree with the VersionRange reference"
            [ testProperty "union" $
                forAll genViaRange $ \a -> forAll genViaRange $ \b ->
                    unionVersionSet a b === viaRange2 unionVersionRanges a b
            , testProperty "intersection" $
                forAll genViaRange $ \a -> forAll genViaRange $ \b ->
                    intersectionVersionSet a b === viaRange2 intersectVersionRanges a b
            , testProperty "complement" $
                forAll genViaRange $ \a ->
                    complementVersionSet a === refComplement a
            , testProperty "difference" $
                forAll genViaRange $ \a -> forAll genViaRange $ \b ->
                    intersectionVersionSet a (complementVersionSet b)
                        === viaRange2 intersectVersionRanges a (refComplement b)
            ]
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

-- | Apply a Cabal range combinator by round-tripping through 'VersionRange'.
viaRange2 :: (VersionRange -> VersionRange -> VersionRange) -> VersionSet -> VersionSet -> VersionSet
viaRange2 f a b = fromVersionRange (f (toVersionRange a) (toVersionRange b))

-- | The reference complement: intersect the complements of each interval, each
-- built as a union of "below the lower bound" and "above the upper bound".
refComplement :: VersionSet -> VersionSet
refComplement vs =
    fromVersionRange
        (foldr (intersectVersionRanges . complementInterval) anyVersion (intervals vs))
  where
    complementInterval (VersionInterval lo hi) =
        unionVersionRanges (belowLower lo) (aboveUpper hi)
    belowLower (LowerBound v InclusiveBound) = earlierVersion v -- < v
    belowLower (LowerBound v ExclusiveBound) = orEarlierVersion v -- <= v
    aboveUpper NoUpperBound                  = noVersion -- nothing above
    aboveUpper (UpperBound v InclusiveBound) = laterVersion v -- > v
    aboveUpper (UpperBound v ExclusiveBound) = orLaterVersion v -- >= v

-- | Sets built only by Cabal's canonicaliser, so they are independent of the
-- implementation under test.
genViaRange :: Gen VersionSet
genViaRange = fromVersionRange <$> sized (\n -> genRange (min n 4))
  where
    genRange 0 = leaf
    genRange n =
        oneof
            [ leaf
            , unionVersionRanges <$> genRange (n `div` 2) <*> genRange (n `div` 2)
            , intersectVersionRanges <$> genRange (n `div` 2) <*> genRange (n `div` 2)
            ]
    leaf =
        oneof
            [ pure anyVersion
            , pure noVersion
            , thisVersion <$> genVersion
            , orLaterVersion <$> genVersion
            , laterVersion <$> genVersion
            , earlierVersion <$> genVersion
            , orEarlierVersion <$> genVersion
            ]

newtype NonEmptyVer = NonEmptyVer Version deriving Show
instance Arbitrary NonEmptyVer where
    arbitrary = NonEmptyVer <$> genVersion

-- | Distinct, strictly ascending draws — what a package's version list looks
-- like. Retried rather than sorted-and-nubbed so the generator cannot quietly
-- shrink the tuple to fewer distinct versions than the property asks for.
twoAscending :: Gen Version -> Gen (Version, Version)
twoAscending g = do
    (a, b) <- (,) <$> g <*> g
    if a == b then twoAscending g else pure (min a b, max a b)

threeAscending :: Gen Version -> Gen (Version, Version, Version)
threeAscending g = do
    (a, b, c) <- (,,) <$> g <*> g <*> g
    case nub (sort [a, b, c]) of
        [x, y, z] -> pure (x, y, z)
        _         -> threeAscending g

ascendingList :: Gen Version -> Gen [Version]
ascendingList g = nub . sort <$> listOf g
