{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module VersionSetSpec (tests) where

import           Data.List                         (nub, sort)
import           Data.Set                          (Set)
import qualified Data.Text                         as T
import qualified Data.Set                          as Set
import           Distribution.Pretty   (prettyShow)
import qualified Distribution.Types.Version as Cabal
import           Distribution.Version  (VersionRange, anyVersion,
                                        earlierVersion, intersectVersionRanges,
                                        laterVersion, majorBoundVersion,
                                        majorUpperBound, noVersion,
                                        orEarlierVersion, orLaterVersion,
                                        thisVersion, unionVersionRanges)
import           PubGrub.Pretty        (Pretty (pretty))
import           PubGrub.SetOps        (isSubsetOf)
import           PubGrub.Version       (Version, mkVersion, toCabalVersion,
                                        versionNumbers)
import           PubGrub.VersionSet
import           Test.Tasty            (TestTree, testGroup)
import           Test.Tasty.QuickCheck (Arbitrary (..), Gen, choose, elements,
                                        forAll, listOf, oneof, property, sized,
                                        testProperty, (.&&.), (===))

-- Small bounded version universe: components drawn from 0..3, length 1..3.
-- Trailing zeros are allowed on purpose: @1.0@ and @1@ are one version here,
-- and the properties below have to hold across both spellings.
genVersion :: Gen Version
genVersion = do
    n <- choose (1, 3)
    cs <- vectorOfRange n (choose (0, 3))
    pure (mkVersion cs)
  where
    vectorOfRange k g = sequence (replicate k g)

-- | The same version for a Cabal range combinator: what a declared range is
-- written with.
asCabal :: Version -> Cabal.Version
asCabal = toCabalVersion

cv :: [Int] -> Cabal.Version
cv = Cabal.mkVersion

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
                1 -> fromVersionRange (orLaterVersion (asCabal lo))
                _ ->
                    intersectionVersionSet
                        (fromVersionRange (orLaterVersion (asCabal lo)))
                        (complementVersionSet (fromVersionRange (orLaterVersion (asCabal hi))))

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
                            === fromVersionRange (orLaterVersion (asCabal first))
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
                forAll genUniverse $ \universe (vs :: VersionSet) ->
                    foldr
                        ((.&&.) . (\v -> contains (snapToVersions universe vs) v === contains vs v))
                        (property True)
                        (Set.toList universe)
            , testProperty "never grows the set" $
                forAll genUniverse $ \universe (vs :: VersionSet) ->
                    isSubsetOf (snapToVersions universe vs) vs
            , testProperty "idempotent" $
                forAll genUniverse $ \universe (vs :: VersionSet) ->
                    snapToVersions universe (snapToVersions universe vs)
                        === snapToVersions universe vs
            , testProperty "an empty universe snaps everything away" $ \(vs :: VersionSet) ->
                snapToVersions Set.empty vs === emptyVersionSet
            ]
        , testGroup
            -- A set built from a declared range remembers that range, and only
            -- that: the tag is what a report quotes, so it has to be the author's
            -- spelling; it must not leak into equality, or two sets denoting the
            -- same versions would stop being equal; and nothing an operation
            -- produces may carry one, because nobody wrote that range.
            "declared range"
            [ testProperty "is handed back as written" $
                forAll genVersion $ \v ->
                    prettyShow (toVersionRange (fromVersionRange (majorBoundVersion (asCabal v))))
                        === prettyShow (majorBoundVersion (asCabal v))
            , testProperty "is invisible to Eq and Ord" $
                forAll genVersion $ \v ->
                    let sugared = fromVersionRange (majorBoundVersion (asCabal v))
                        spelled =
                            fromVersionRange
                                ( intersectVersionRanges
                                    (orLaterVersion (asCabal v))
                                    (earlierVersion (majorUpperBound (asCabal v)))
                                )
                     in (sugared === spelled) .&&. (compare sugared spelled === EQ)
            , testProperty "is dropped by every operation" $ \(a :: VersionSet) b ->
                let untagged vs = declaredRange vs === Nothing
                 in untagged (unionVersionSet a b)
                        .&&. untagged (intersectionVersionSet a b)
                        .&&. untagged (complementVersionSet a)
                        .&&. untagged (fromVersionRange anyVersion `unionVersionSet` a)
            , testProperty "the constructors carry none" $
                forAll genVersion $ \v ->
                    (declaredRange (singletonVersionSet v) === Nothing)
                        .&&. (declaredRange (halfOpenVersionSet v Nothing) === Nothing)
                        .&&. (declaredRange (belowVersionSet (Just v)) === Nothing)
                        .&&. (declaredRange fullVersionSet === Nothing)
                        .&&. (declaredRange emptyVersionSet === Nothing)
            , testProperty "an untagged set prints canonically" $ \(a :: VersionSet) ->
                prettyShow (toVersionRange a)
                    === prettyShow (toVersionRange (fromVersionRange (toVersionRange a)))
            ]
        , testGroup
            -- 'fillGaps' is the dual of 'snapToVersions' restricted to interior
            -- holes: it may only ever add version space that no member of the
            -- universe occupies, and it may never move an outer bound.
            "fillGaps"
            [ testProperty "keeps exactly the universe members it had" $
                forAll genUniverse $ \universe (vs :: VersionSet) ->
                    foldr
                        ((.&&.) . (\v -> contains (fillGaps universe vs) v === contains vs v))
                        (property True)
                        (Set.toList universe)
            , testProperty "never shrinks the set" $
                forAll genUniverse $ \universe (vs :: VersionSet) ->
                    isSubsetOf vs (fillGaps universe vs)
            , testProperty "idempotent" $
                forAll genUniverse $ \universe (vs :: VersionSet) ->
                    fillGaps universe (fillGaps universe vs) === fillGaps universe vs
            , testProperty "leaves the outer bounds where they were" $
                forAll genUniverse $ \universe (vs :: VersionSet) ->
                    let bounds s = (take 1 (intervals s), take 1 (reverse (intervals s)))
                        lower = fst
                        upper = snd
                        (los, his) = bounds vs
                        (los', his') = bounds (fillGaps universe vs)
                     in (map lower los === map lower los') .&&. (map upper his === map upper his')
            , testProperty "fills a gap nobody published into, and only that" $
                let declared =
                        fromVersionRange
                            ( unionVersionRanges
                                (intersectVersionRanges (orLaterVersion (cv [1, 0])) (earlierVersion (cv [1, 2])))
                                (intersectVersionRanges (orLaterVersion (cv [1, 3])) (earlierVersion (cv [2])))
                            )
                    published = Set.fromList (map mkVersion [[1, 0], [1, 1], [1, 3], [1, 4]])
                    filled = fromVersionRange (intersectVersionRanges (orLaterVersion (cv [1, 0])) (earlierVersion (cv [2])))
                 in (fillGaps published declared === filled)
                        -- and leaves the gap alone once something is published in it
                        .&&. (fillGaps (Set.insert (mkVersion [1, 2, 5]) published) declared === declared)
            , testProperty "an empty universe fills every hole" $ \(vs :: VersionSet) ->
                length (intervals (fillGaps Set.empty vs)) <= 1
            , testProperty "the result carries no declared range" $
                forAll genUniverse $ \universe (vs :: VersionSet) ->
                    declaredRange (fillGaps universe vs) === Nothing
            ]
        , testGroup
            -- The operations work on the intervals directly. This pins them
            -- to the round trip through 'VersionRange' syntax: hand each side
            -- back as a range, combine with Cabal's combinator, fold the result
            -- into a set again. Same set, and the same canonical
            -- /representation/, since 'Eq' is semantic equality only while the
            -- form stays canonical. Cabal's own canonicaliser is not the
            -- reference: it orders @1.0@ below @1@, and this module does not.
            -- The membership properties above are the semantic oracle.
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
            -- The version order is the solver's, not Cabal's: trailing zeros are
            -- insignificant (see 'PubGrub.Version'). Each case here is a shape
            -- found in real proofs or in the index.
            "trailing zeros are insignificant"
            [ testProperty "two spellings are one version, and sort as one" $
                (mkVersion [1, 2] === mkVersion [1, 2, 0, 0])
                    .&&. (compare (mkVersion [1, 2]) (mkVersion [1, 2, 0]) === EQ)
                    .&&. (mkVersion [1, 2] < mkVersion [1, 2, 0, 1])
                    .&&. (Set.size (Set.fromList [mkVersion [1, 2], mkVersion [1, 2, 0], mkVersion [1, 2, 0, 0]]) === 1)
            , testProperty "a version keeps its spelling for display" $
                (T.unpack (pretty (mkVersion [1, 2, 0, 0])) === "1.2.0.0") .&&. (T.unpack (pretty (mkVersion [1, 2])) === "1.2")
            , testProperty "a singleton admits every spelling of its version" $
                contains (singletonVersionSet (mkVersion [1, 2])) (mkVersion [1, 2, 0, 0])
                    .&&. contains (singletonVersionSet (mkVersion [1, 2, 0, 0])) (mkVersion [1, 2])
            , testProperty "consecutive major windows are one interval" $
                -- haddock's @base ^>=4.13.0.0 || ^>=4.14.0.0@: Cabal's @^>=4.13.0.0@
                -- stops at @<4.14@ and the next window starts at @>=4.14.0.0@.
                let windows = fromVersionRange (unionVersionRanges (majorBoundVersion (cv [4, 13, 0, 0])) (majorBoundVersion (cv [4, 14, 0, 0])))
                    spelled = fromVersionRange (intersectVersionRanges (orLaterVersion (cv [4, 13, 0, 0])) (earlierVersion (cv [4, 15])))
                 in (windows === spelled) .&&. (length (intervals windows) === 1)
            , testProperty "the space between two spellings is empty" $
                -- scion-browser's @tar >=0.3 && <0.3.0.0@: a declared @>=0.3@ minus
                -- the slot of the release @0.3.0.0@ leaves no residue below it.
                let declared = fromVersionRange (orLaterVersion (cv [0, 3]))
                    slot = halfOpenVersionSet (mkVersion [0, 3, 0, 0]) (Just (mkVersion [0, 3, 2, 0]))
                 in (halfOpenVersionSet (mkVersion [0, 3]) (Just (mkVersion [0, 3, 0, 0])) === emptyVersionSet)
                        .&&. (intersectionVersionSet declared (complementVersionSet slot) === fromVersionRange (orLaterVersion (cv [0, 3, 2, 0])))
            , testProperty "a bound spelled longer than the release still names it" $
                -- @time >=1.8.0@ against the release @time 1.8@, and @lens <5.0@
                -- against @lens 5@: Cabal excludes the first and admits the second.
                contains (fromVersionRange (orLaterVersion (cv [1, 8, 0]))) (mkVersion [1, 8])
                    .&&. (contains (fromVersionRange (earlierVersion (cv [5, 0]))) (mkVersion [5]) === False)
            , testProperty "where two spellings meet at one cut, the shorter is kept, either way round" $
                -- language-puppet's @aeson >=2.0@ against the slot of @aeson 2.0.0.0@:
                -- the derived term should read @>=2.0@, as the author wrote it.
                let declared = fromVersionRange (orLaterVersion (cv [2, 0]))
                    slot = halfOpenVersionSet (mkVersion [2, 0, 0, 0]) (Just (mkVersion [2, 0, 2, 0]))
                    lowerSpelling s = [versionNumbers v | (Cut v _, _) <- intervals s]
                    upperSpelling s = [versionNumbers v | (_, Cut v _) <- intervals s]
                    below = fromVersionRange (earlierVersion (cv [1, 5]))
                    belowLong = halfOpenVersionSet (mkVersion [1]) (Just (mkVersion [1, 5, 0, 0]))
                 in (lowerSpelling (intersectionVersionSet declared slot) === [[2, 0]])
                        .&&. (lowerSpelling (intersectionVersionSet slot declared) === [[2, 0]])
                        .&&. (upperSpelling (intersectionVersionSet below belowLong) === [[1, 5]])
                        .&&. (upperSpelling (intersectionVersionSet belowLong below) === [[1, 5]])
                        .&&. (upperSpelling (unionVersionSet below belowLong) === [[1, 5]])
                        .&&. (lowerSpelling (unionVersionSet slot (halfOpenVersionSet (mkVersion [2]) (Just (mkVersion [2, 0, 1])))) === [[2]])
            , testProperty "two cuts at one version, spelled differently, are one cut" $
                intersectionVersionSet (fromVersionRange (earlierVersion (cv [1, 5]))) (fromVersionRange (earlierVersion (cv [1, 5, 0, 0])))
                    === fromVersionRange (earlierVersion (cv [1, 5]))
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
    complementInterval (lo, hi) =
        unionVersionRanges (belowLower lo) (aboveUpper hi)
    belowLower (Cut v Before) = earlierVersion (asCabal v) -- < v
    belowLower (Cut v After)  = orEarlierVersion (asCabal v) -- <= v
    belowLower Unbounded      = noVersion -- unreachable: no interval starts there
    aboveUpper Unbounded      = noVersion -- nothing above
    aboveUpper (Cut v After)  = laterVersion (asCabal v) -- > v
    aboveUpper (Cut v Before) = orLaterVersion (asCabal v) -- >= v

-- | Sets built from random 'VersionRange' syntax. 'fromVersionRange' folds it
-- through this module's own union and intersection, so these sets are not
-- independent of the implementation under test.
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
            , thisVersion . asCabal <$> genVersion
            , orLaterVersion . asCabal <$> genVersion
            , laterVersion . asCabal <$> genVersion
            , earlierVersion . asCabal <$> genVersion
            , orEarlierVersion . asCabal <$> genVersion
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

-- | A package's version universe, in the shape 'snapToVersions' takes it.
genUniverse :: Gen (Set Version)
genUniverse = Set.fromList <$> listOf genVersion
