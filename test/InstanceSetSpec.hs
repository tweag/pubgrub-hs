-- | Differential tests for the 'InstanceSet' algebra.
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
-- The properties go through the public API only ('SetOps' plus
-- 'emptyInstanceSet' \/ 'singletonInstance' \/ 'memberInstance'), so they hold
-- for any representation. In particular they assume no 'Eq', 'Ord' or 'Show' on
-- 'InstanceSet' — a non-canonical representation has no lawful structural
-- equality, so set equality is only ever asked of the /model/, and
-- counterexamples are shown as their extension rather than their
-- representation.
--
-- The 'Term' properties matter as much as the set ones: 'Term' is what the
-- solver actually manipulates, and a wrong @difference@ shows up there as a
-- bogus 'Contradicted' — which is how a bad set algebra becomes a wrong
-- "no solution".
module InstanceSetSpec (tests) where

import           Data.List                    (intercalate)
import           Data.Map.Strict              (Map)
import qualified Data.Map.Strict              as Map
import           Data.Maybe                   (catMaybes)
import qualified Data.Text                    as T
import           Distribution.Types.Flag      (FlagAssignment, FlagName,
                                               lookupFlagAssignment,
                                               mkFlagAssignment, mkFlagName)
import           Distribution.Types.UnitId    (mkUnitId)
import           Distribution.Version         (Version, earlierVersion,
                                               mkVersion, orLaterVersion)
import           PubGrub.Index.PreInstalled   (PreInstalledPackage (..))
import           PubGrub.InstanceSet          (Instance (..), InstanceSet,
                                               emptyInstanceSet, memberInstance,
                                               singletonInstance)
import           PubGrub.Pretty               (Pretty (..))
import           PubGrub.Relation             (Relation (..), relation)
import           PubGrub.SetOps               (SetOps (..), equivalent,
                                               isDisjoint, isSubsetOf)
import           PubGrub.Term                 (Term (..), intersectTerm,
                                               isBottomTerm, isTopTerm,
                                               negateTerm, unionTerm)
import           PubGrub.VersionSet           (VersionSet, contains,
                                               emptyVersionSet,
                                               fromVersionRange, fullVersionSet,
                                               singletonVersionSet,
                                               unionVersionSet)
import           Test.Tasty                   (TestTree, testGroup)
import           Test.Tasty.QuickCheck        (Arbitrary (..), Gen, elements,
                                               frequency, oneof, sized,
                                               sublistOf, testProperty, (===))

-- --------------------------------------------------------------------------
-- ADAPTER — the only part tied to the representation
-- --------------------------------------------------------------------------

-- | All source instances whose version lies in @vs@ and whose flag assignment
-- agrees with @pins@ (a flag absent from @pins@ is unconstrained).
--
-- The body unions singletons drawn from the universe, and a union of
-- fully-pinned singletons only ever produces fully-pinned cells. So the
-- range-shaped cells, and the flag-splitting branch of cell difference, are
-- never exercised. Building the set as the provider widens a dependency's
-- 'VersionSet', from one cell, would exercise them; nothing else in this
-- module depends on the body.
sourceInstances :: VersionSet -> Map FlagName Bool -> InstanceSet
sourceInstances vs pins =
    unionAll
        [ singletonInstance i
        | i <- sourceUniverse
        , BuildSource v fa <- [i]
        , contains vs v
        , agrees fa
        ]
  where
    agrees fa = all (\(f, b) -> lookupFlagAssignment f fa == Just b) (Map.toList pins)

unionAll :: [InstanceSet] -> InstanceSet
unionAll = foldr union emptyInstanceSet

-- --------------------------------------------------------------------------
-- The universe
-- --------------------------------------------------------------------------

-- Small enough to enumerate exhaustively, large enough that a wrong
-- flag-splitting difference cannot hide: three versions x four total flag
-- assignments over two declared flags, plus two installed units.

versions :: [Version]
versions = [mkVersion [1, 0], mkVersion [1, 1], mkVersion [2, 0]]

-- | The two declared flags of every source package in this universe, so a
-- total assignment fixes both.
flagA, flagB :: FlagName
flagA = mkFlagName "a"
flagB = mkFlagName "b"

-- | Every /total/ assignment over the two declared flags.
totalAssignments :: [FlagAssignment]
totalAssignments =
    [ mkFlagAssignment [(flagA, a), (flagB, b)]
    | a <- [False, True]
    , b <- [False, True]
    ]

sourceUniverse :: [Instance]
sourceUniverse =
    [ BuildSource v fa
    | v <- versions
    , fa <- totalAssignments
    ]

installedUniverse :: [Instance]
installedUniverse =
    [ UsePreInstalled (PreInstalledPackage (mkUnitId ("u-" ++ show n)) v [])
    | (n, v) <- zip [1 :: Int ..] [mkVersion [1, 0], mkVersion [2, 0]]
    ]

-- | The full instance universe, in a fixed order. Filtering this list is what
-- makes every model value canonical, so plain list equality is set equality.
universe :: [Instance]
universe = installedUniverse ++ sourceUniverse

-- --------------------------------------------------------------------------
-- The model
-- --------------------------------------------------------------------------

-- | The extension of a set: which of the universe's instances it contains.
-- Canonical by construction (universe order preserved), so '==' is set
-- equality and no 'Ord'\/'Eq' on 'InstanceSet' is needed.
model :: InstanceSet -> [Instance]
model s = filter (`memberInstance` s) universe

subsetOfL :: Eq a => [a] -> [a] -> Bool
subsetOfL xs ys = all (`elem` ys) xs

-- --------------------------------------------------------------------------
-- Generators
-- --------------------------------------------------------------------------

-- | Generated version sets are clipped to versions the universe actually
-- contains. A model-based test can only observe the universe, so a set like
-- @<1.0@ — non-empty, yet containing no universe member — would make 'isEmpty'
-- disagree with @null . model@ for no good reason. Free-form ranges still
-- /build/ the set; they are just clipped afterwards. (Interval structure is
-- covered by "VersionSetSpec"; what matters here is the flag algebra.)
supportedVersions :: VersionSet
supportedVersions =
    foldr (unionVersionSet . singletonVersionSet) emptyVersionSet versions

genVersionSet :: Gen VersionSet
genVersionSet = (`intersect` supportedVersions) <$> genRawVersionSet

genRawVersionSet :: Gen VersionSet
genRawVersionSet =
    oneof
        [ pure emptyVersionSet
        , pure fullVersionSet
        , singletonVersionSet <$> elements versions
        , fromVersionRange . orLaterVersion <$> elements versions
        , fromVersionRange . earlierVersion <$> elements versions
        , unionVersionSet
            <$> (singletonVersionSet <$> elements versions)
            <*> (singletonVersionSet <$> elements versions)
        ]

-- | A partial pin map: each flag independently pinned or left free.
genPins :: Gen (Map FlagName Bool)
genPins = do
    a <- genPin flagA
    b <- genPin flagB
    pure (Map.fromList (catMaybes [a, b]))
  where
    genPin f =
        frequency
            [ (1, pure Nothing)
            , (2, (\v -> Just (f, v)) <$> arbitrary)
            ]

genLeaf :: Gen InstanceSet
genLeaf =
    oneof
        [ pure emptyInstanceSet
        , singletonInstance <$> elements universe
        , sourceInstances <$> genVersionSet <*> genPins
        , unionAll . map singletonInstance <$> sublistOf installedUniverse
        ]

genSet :: Int -> Gen InstanceSet
genSet n
    | n <= 0 = genLeaf
    | otherwise =
        oneof
            [ genLeaf
            , union <$> half <*> half
            , intersect <$> half <*> half
            , difference <$> half <*> half
            ]
  where
    half = genSet (n `div` 2)

-- | A generated set, shown as its /extension/ rather than its representation —
-- so counterexamples stay readable whatever the internals look like, and no
-- 'Show InstanceSet' is required.
newtype Sym = Sym InstanceSet

instance Show Sym where
    show (Sym s) = "{" ++ intercalate ", " (map (T.unpack . pretty) (model s)) ++ "}"

instance Arbitrary Sym where
    arbitrary = Sym <$> sized (\n -> genSet (min n 4))

newtype SymTerm = SymTerm (Term InstanceSet)

instance Show SymTerm where
    show (SymTerm t) = case t of
        Positive s -> "Positive " ++ show (Sym s)
        Negative s -> "Negative " ++ show (Sym s)

instance Arbitrary SymTerm where
    arbitrary = do
        Sym s <- arbitrary
        SymTerm <$> elements [Positive s, Negative s]

-- --------------------------------------------------------------------------
-- Term model: a term denotes a subset of the universe extended by one point
-- (the /absent/ state, represented as 'Nothing').
-- --------------------------------------------------------------------------

termModel :: Term InstanceSet -> [Maybe Instance]
termModel (Positive s) = map Just (model s)
termModel (Negative s) =
    Nothing : map Just (filter (`notElem` model s) universe)

fullTermModel :: [Maybe Instance]
fullTermModel = Nothing : map Just universe

-- Set operations on term models, canonicalised against 'fullTermModel'.
meetT, joinT :: [Maybe Instance] -> [Maybe Instance] -> [Maybe Instance]
meetT xs ys = filter (\e -> e `elem` xs && e `elem` ys) fullTermModel
joinT xs ys = filter (\e -> e `elem` xs || e `elem` ys) fullTermModel

compT :: [Maybe Instance] -> [Maybe Instance]
compT xs = filter (`notElem` xs) fullTermModel

-- --------------------------------------------------------------------------
-- Properties
-- --------------------------------------------------------------------------

tests :: TestTree
tests =
    testGroup
        "InstanceSet"
        [ testGroup
            "model homomorphism"
            [ testProperty "union" $ \(Sym a) (Sym b) ->
                model (a `union` b) === joinL (model a) (model b)
            , testProperty "intersect" $ \(Sym a) (Sym b) ->
                model (a `intersect` b) === meetL (model a) (model b)
            , testProperty "difference" $ \(Sym a) (Sym b) ->
                model (a `difference` b) === diffL (model a) (model b)
            , testProperty "isEmpty agrees with the model" $ \(Sym a) ->
                isEmpty a === null (model a)
            ]
        , testGroup
            "element operations"
            [ testProperty "the empty set contains nothing" $
                model emptyInstanceSet === []
            , -- The load-bearing one: a "singleton" really must denote exactly
              -- one instance. This is where an under-pinned cell (a flag left
              -- free) is caught.
              testProperty "singletonInstance denotes exactly that instance" $
                \(InUniverse i) -> model (singletonInstance i) === [i]
            , testProperty "nothing is a member of the empty set" $
                \(InUniverse i) -> memberInstance i emptyInstanceSet === False
            ]
        , testGroup
            "derived predicates agree with the model"
            [ testProperty "isSubsetOf" $ \(Sym a) (Sym b) ->
                isSubsetOf a b === subsetOfL (model a) (model b)
            , testProperty "isDisjoint" $ \(Sym a) (Sym b) ->
                isDisjoint a b === null (meetL (model a) (model b))
            , testProperty "equivalent" $ \(Sym a) (Sym b) ->
                equivalent a b === (model a == model b)
            ]
        , testGroup
            "ring-of-sets laws"
            [ testProperty "union commutative" $ \(Sym a) (Sym b) ->
                model (a `union` b) === model (b `union` a)
            , testProperty "union associative" $ \(Sym a) (Sym b) (Sym c) ->
                model ((a `union` b) `union` c) === model (a `union` (b `union` c))
            , testProperty "union idempotent" $ \(Sym a) ->
                model (a `union` a) === model a
            , testProperty "intersect commutative" $ \(Sym a) (Sym b) ->
                model (a `intersect` b) === model (b `intersect` a)
            , testProperty "intersect associative" $ \(Sym a) (Sym b) (Sym c) ->
                model ((a `intersect` b) `intersect` c)
                    === model (a `intersect` (b `intersect` c))
            , testProperty "intersect idempotent" $ \(Sym a) ->
                model (a `intersect` a) === model a
            , testProperty "absorption" $ \(Sym a) (Sym b) ->
                model (a `union` (a `intersect` b)) === model a
            , testProperty "distributivity" $ \(Sym a) (Sym b) (Sym c) ->
                model (a `intersect` (b `union` c))
                    === model ((a `intersect` b) `union` (a `intersect` c))
            , testProperty "self-difference is empty" $ \(Sym a) ->
                model (a `difference` a) === []
            , testProperty "difference is intersection with the complement" $
                \(Sym a) (Sym b) ->
                    model (a `difference` b) === filter (`notElem` model b) (model a)
            ]
        , testGroup
            "Term algebra over InstanceSet"
            [ testProperty "intersectTerm" $ \(SymTerm x) (SymTerm y) ->
                termModel (intersectTerm x y) === meetT (termModel x) (termModel y)
            , testProperty "unionTerm" $ \(SymTerm x) (SymTerm y) ->
                termModel (unionTerm x y) === joinT (termModel x) (termModel y)
            , testProperty "negateTerm is complement" $ \(SymTerm x) ->
                termModel (negateTerm x) === compT (termModel x)
            , testProperty "isTopTerm" $ \(SymTerm x) ->
                isTopTerm x === (termModel x == fullTermModel)
            , testProperty "isBottomTerm" $ \(SymTerm x) ->
                isBottomTerm x === null (termModel x)
            , -- The property that ties the set algebra to solver behaviour: a
              -- wrong 'difference' surfaces here as a bogus 'Contradicted',
              -- which is how a bad algebra becomes a wrong "no solution".
              testProperty "relation matches subset/disjoint on term models" $
                \(SymTerm x) (SymTerm y) ->
                    let tx = termModel x
                        ty = termModel y
                        expected
                            | tx `subsetOfL` ty = Satisfied
                            | null (meetT tx ty) = Contradicted
                            | otherwise = Inconclusive
                     in relation x y === expected
            ]
        ]

-- List-level set operations on models, canonicalised against 'universe'.
meetL, joinL, diffL :: [Instance] -> [Instance] -> [Instance]
meetL xs ys = filter (\e -> e `elem` xs && e `elem` ys) universe
joinL xs ys = filter (\e -> e `elem` xs || e `elem` ys) universe
diffL xs ys = filter (\e -> e `elem` xs && e `notElem` ys) universe

-- | An instance drawn from the universe.
newtype InUniverse = InUniverse Instance

instance Show InUniverse where
    show (InUniverse i) = T.unpack (pretty i)

instance Arbitrary InUniverse where
    arbitrary = InUniverse <$> elements universe
