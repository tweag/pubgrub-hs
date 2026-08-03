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

import           Control.Monad                (replicateM)
import           Data.List                    (intercalate)
import           Data.Map.Strict              (Map)
import qualified Data.Map.Strict              as Map
import           Data.Maybe                   (catMaybes)
import qualified Data.Set                     as Set
import qualified Data.Text                    as T
import           Distribution.Types.Flag      (FlagAssignment, FlagName,
                                               mkFlagAssignment, mkFlagName)
import           Distribution.Types.UnitId    (mkUnitId)
import           Distribution.Version         (Version, earlierVersion,
                                               mkVersion, orLaterVersion)
import           PubGrub.Index.PreInstalled   (PreInstalledPackage (..))
import           PubGrub.InstanceSet          (Instance (..), InstanceSet (..),
                                               emptyInstanceSet, memberInstance,
                                               singletonInstance)
import           PubGrub.InstanceSet.SourceCell (FlagPin (..), SourceCell (..))
import           PubGrub.Pretty               (Pretty (..))
import           PubGrub.Relation             (Relation (..), relation)
import           PubGrub.SetOps               (SetOps (..), equivalent,
                                               isDisjoint, isSubsetOf)
import           PubGrub.Term                 (Term (..), intersectTerm,
                                               isBottomTerm, isTopTerm,
                                               negateTerm, unionTerm)
import           PubGrub.VersionSet           (VersionSet,
                                               emptyVersionSet,
                                               fromVersionRange, fullVersionSet,
                                               singletonVersionSet,
                                               unionVersionSet)
import           Test.Tasty                   (TestTree, testGroup)
import           Test.Tasty.HUnit             (assertBool, assertEqual, testCase)
import           Test.Tasty.QuickCheck        (Arbitrary (..), Gen, elements,
                                               forAll, frequency, oneof, sized,
                                               sublistOf, testProperty, (===))

-- --------------------------------------------------------------------------
-- ADAPTER — the only part tied to the representation
-- --------------------------------------------------------------------------

-- | All source instances whose version lies in @vs@ and whose flag assignment
-- agrees with @pins@ (a flag absent from @pins@ is unconstrained).
--
-- This is the /intensional/ constructor — one cell carrying the range and the
-- pins themselves, the same shape the provider produces when it widens a
-- dependency's 'VersionSet'. It has to be: the extensional alternative (union
-- singletons drawn from the universe) only ever produces fully-pinned,
-- version-singleton cells, so range-shaped cells and the flag-splitting branch
-- of cell difference — the two things most likely to be wrong — would never be
-- exercised.
sourceInstances :: VersionSet -> Map FlagName FlagPin -> InstanceSet
sourceInstances vs pins =
    InstanceSet { isInstalled = Set.empty, isSource = [SourceCell vs pins] }

unionAll :: [InstanceSet] -> InstanceSet
unionAll = foldr union emptyInstanceSet

-- --------------------------------------------------------------------------
-- The universe
-- --------------------------------------------------------------------------

-- Small enough to enumerate exhaustively, large enough that a wrong
-- flag-splitting difference cannot hide: five versions with their total flag
-- assignments (fifteen source instances), plus two installed units.

-- | Two flag names, and — this is the load-bearing part — /not/ every version
-- declares both.
--
-- A flag is declared by a @.cabal@ file, so it is a property of a
-- @(package, version)@, not of a package. An 'Instance' therefore carries an
-- assignment total over /that version's/ flags, while a 'SourceCell' pins bare
-- flag names across a whole range. A universe where every version declares the
-- same flags cannot tell the two apart, and so cannot see what a pin on a flag
-- some version does not declare is supposed to mean.
flagA, flagB :: FlagName
flagA = mkFlagName "a"
flagB = mkFlagName "b"

-- | The universe's source releases, each with the flags it declares.
declaredFlags :: [(Version, [FlagName])]
declaredFlags =
    [ (mkVersion [1, 0], [flagA, flagB])
    , (mkVersion [1, 1], [flagA, flagB])
    , (mkVersion [2, 0], [flagA, flagB])
    , (mkVersion [3, 0], [flagA]) -- dropped b
    , (mkVersion [4, 0], []) -- declares no flags at all
    ]

versions :: [Version]
versions = map fst declaredFlags

-- | Every /total/ assignment over the given flags — so one empty assignment for
-- a version that declares none.
totalAssignments :: [FlagName] -> [FlagAssignment]
totalAssignments fs =
    map mkFlagAssignment (traverse (\f -> [(f, False), (f, True)]) fs)

sourceUniverse :: [Instance]
sourceUniverse =
    [ BuildSource v fa
    | (v, fs) <- declaredFlags
    , fa <- totalAssignments fs
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

-- | Boolean implication. Deliberately not QuickCheck's '==>': the premises in
-- the one-sided properties below (emptiness, containment, equality) are rare, so
-- discarding whenever one is false would give up long before 100 tests.
implies :: Bool -> Bool -> Bool
implies p q = not p || q

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

-- | A partial pin map: each flag independently left free, pinned to a value, or
-- pinned 'NotDeclared'.
--
-- All four states per flag have to be generated. 'NotDeclared' is the one that
-- only arises internally — from negating a pin — so a generator that omitted it
-- would leave exactly the cells 'differenceCell' produces untested.
genPins :: Gen (Map FlagName FlagPin)
genPins = do
    a <- genPin flagA
    b <- genPin flagB
    pure (Map.fromList (catMaybes [a, b]))
  where
    genPin f =
        frequency
            [ (1, pure Nothing)
            , (2, (\v -> Just (f, PinnedTo v)) <$> arbitrary)
            , (1, pure (Just (f, NotDeclared)))
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
            ]
        , emptinessIsOneSided
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
            "derived predicates never claim more than the model allows"
            -- All three are emptiness questions underneath, so they inherit the
            -- one-sidedness of 'isEmpty': a claim must be true, a missing claim
            -- is permitted.
            [ testProperty "isSubsetOf only claims real containment" $ \(Sym a) (Sym b) ->
                isSubsetOf a b `implies` subsetOfL (model a) (model b)
            , testProperty "isDisjoint only claims real disjointness" $ \(Sym a) (Sym b) ->
                isDisjoint a b `implies` null (meetL (model a) (model b))
            , testProperty "equivalent only claims real equality" $ \(Sym a) (Sym b) ->
                equivalent a b `implies` (model a == model b)
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
            , testProperty "isTopTerm only claims a real top" $ \(SymTerm x) ->
                isTopTerm x `implies` (termModel x == fullTermModel)
            , testProperty "isBottomTerm only claims a real bottom" $ \(SymTerm x) ->
                isBottomTerm x `implies` null (termModel x)
            , -- The property that ties the set algebra to solver behaviour, and
              -- the one that matters most: a wrong 'difference' surfaces here as
              -- a bogus 'Satisfied' or 'Contradicted', which is how a bad algebra
              -- becomes a wrong "no solution".
              --
              -- Stated in the only direction that holds. 'Inconclusive' is always
              -- permitted, because 'isEmpty' may under-claim (see
              -- 'emptinessIsOneSided'); a definite answer must be right.
              testProperty "relation never claims a relation the model denies" $
                \(SymTerm x) (SymTerm y) ->
                    let tx = termModel x
                        ty = termModel y
                     in case relation x y of
                            Satisfied    -> tx `subsetOfL` ty
                            Contradicted -> null (meetT tx ty)
                            Inconclusive -> True
            ]
        , sizeControl
        ]

-- --------------------------------------------------------------------------
-- Emptiness
-- --------------------------------------------------------------------------

-- | Emptiness is the one query the algebra is allowed to get wrong, in one
-- direction only:
--
-- * (a) a claim of emptiness must be true;
-- * (b) a set that is empty for /every/ possible flag-declaration function must
--   be detected.
--
-- The slack between them is real and unavoidable: a cell pinning @a@
-- 'NotDeclared' over a range whose versions all declare @a@ denotes nothing, and
-- seeing that needs to know which versions declare what — index data the algebra
-- does not have. Asserting @isEmpty ⟺ null . model@ would therefore fail on
-- correct code.
--
-- Note this cannot be dodged by generating "well-behaved" sets only:
-- 'PubGrub.InstanceSet.SourceCell.differenceCell' manufactures 'NotDeclared'
-- pins itself, so any chain of differences produces cells of this kind whatever
-- the inputs looked like.
--
-- What stops (a) alone from being satisfied by a do-nothing implementation is
-- (b) plus the end-to-end solver suites ("Solver", "PubGrub paper examples",
-- "Flags (end to end)"): a solver whose 'PubGrub.Relation.relation' always said
-- 'Inconclusive' would never terminate a conflict, so those tests are the real
-- guard on the strength of this one.
emptinessIsOneSided :: TestTree
emptinessIsOneSided =
    testGroup
        "emptiness is one-sided"
        [ testProperty "(a) a claim of emptiness is always true" $ \(Sym a) ->
            isEmpty a `implies` null (model a)
        , testProperty "(b) self-difference is detected empty" $ \(Sym a) ->
            isEmpty (a `difference` a)
        , testProperty "(b) a set minus itself twice over stays detected" $ \(Sym a) (Sym b) ->
            isEmpty ((a `intersect` b) `difference` b)
        , -- The three ways a pin map can contradict itself. These are what O5
          -- (progress) rests on: they hold whatever any version declares, so the
          -- solver can always detect the incompatibility it just derived.
          testProperty "(b) opposite values contradict" $
            isEmpty (pinned (PinnedTo True) `intersect` pinned (PinnedTo False))
        , testProperty "(b) a value contradicts NotDeclared" $
            isEmpty (pinned (PinnedTo True) `intersect` pinned NotDeclared)
        , testProperty "(b) an empty range is empty whatever the pins" $
            forAll genPins (isEmpty . sourceInstances emptyVersionSet)
        ]
  where
    pinned p = sourceInstances fullVersionSet (Map.singleton flagA p)

-- --------------------------------------------------------------------------
-- Size control
-- --------------------------------------------------------------------------

-- | Pruning is not a correctness property, so the model tests above cannot see
-- it. This is the guard for it.
--
-- The shape is the solver's own: a decision is refuted, the negated term is
-- intersected in, and the accumulated set becomes a difference against a
-- version-singleton, fully-pinned cell. 'differenceCell' splits one cell into
-- up to @1 + 2·|pins|@, so the cell count compounds while the denotation only
-- shrinks by one instance per ban. Measured over the 24 bans below: 28293 cells
-- for 56 remaining instances with null-dropping alone, 41 with 'pruneCells'.
--
-- The bans go assignment-major (all versions of one assignment, then the next),
-- which is the order that compounds: banning a version's assignments
-- consecutively instead lets the version's cell vanish outright and the count
-- collapses on its own.
sizeControl :: TestTree
sizeControl =
    testGroup
        "size control"
        [ testCase "repeated instance bans keep the cell count near the pin count" $ do
            let counts = map (length . isSource) states
            assertEqual
                "one instance leaves the denotation per ban"
                [80, 79 .. 56]
                (map (\s -> length (filter (`memberInstance` s) banUniverse)) states)
            assertBool
                ("cell counts along the chain: " ++ show counts)
                (maximum counts <= 48)
        ]
  where
    -- A universe of its own: four flags and five versions, so the split factor
    -- is large enough for compounding to show. (The module's two-flag universe
    -- is too small — it never exceeds four cells either way.)
    banFlags =
        [ mkFlagAssignment (zip (map mkFlagName ["a", "b", "c", "d"]) bs)
        | bs <- replicateM 4 [False, True]
        ]
    banUniverse =
        [ BuildSource v fa
        | fa <- banFlags
        , v <- [mkVersion [n] | n <- [1 .. 5]]
        ]
    everything =
        InstanceSet
            { isInstalled = Set.empty
            , isSource = [SourceCell fullVersionSet Map.empty]
            }
    states = scanl (\s i -> s `difference` singletonInstance i) everything (take 24 banUniverse)

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
