-- | Tests for 'PubGrub.Store': merging dependency facts as they are inserted.
--
-- The property under test is the one @references\/pubgrub.md:456@ asks for: two
-- facts stating the same dependency of two /adjacent/ releases become one fact
-- over the joined range. It works without reading any @.cabal@ because the
-- provider emits over release __slots__ — half-open ranges up to the next
-- release — so the two ranges touch and their union is contiguous.
--
-- The cases here are the boundaries of that: what must merge, what must not, and
-- what the merge must preserve (the clause's place in the scan order, and a
-- 'CauseDependency' leaf rather than a derived node).
module StoreSpec (tests) where

import qualified Data.Map.Strict                 as Map
import qualified Data.Set                        as Set
import           Distribution.Types.Flag         (mkFlagName)
import           Distribution.Types.PackageName  (PackageName, mkPackageName)
import           Distribution.Types.Version      (Version, mkVersion)
import           Distribution.Types.VersionRange (earlierVersion,
                                                  orLaterVersion)
import           PubGrub.Incompatibility        (IncompatCause (..),
                                                 Incompatibility (..),
                                                 fromDependency, noInstances,
                                                 unbuildable)
import           PubGrub.InstanceSet            (InstanceSet (..))
import           PubGrub.InstanceSet.SourceCell (FlagPin (..), SourceCell (..))
import           PubGrub.SetOps                 (equivalent)
import           PubGrub.Store                  (emptyStore, insertClause,
                                                 insertClauses, storeClauses)
import qualified PubGrub.VersionSet             as VersionSet
import           Test.Tasty                     (TestTree, testGroup)
import           Test.Tasty.HUnit               (assertBool, assertFailure,
                                                 testCase, (@?=))

-- --------------------------------------------------------------------------
-- Fixtures
-- --------------------------------------------------------------------------

pkgA, pkgB, pkgQ :: PackageName
pkgA = mkPackageName "a"
pkgB = mkPackageName "b"
pkgQ = mkPackageName "q"

v :: Int -> Version
v n = mkVersion [n]

-- | A release's slot, as 'Bridge.Provider.withSlots' mints it: from this release
-- up to the next one that exists.
slot :: Int -> Int -> InstanceSet
slot lo next = sourceOnly (VersionSet.halfOpenVersionSet (v lo) (Just (v next)))

-- | An unbounded slot — the newest release, with nothing above it.
slotFrom :: Int -> InstanceSet
slotFrom lo = sourceOnly (VersionSet.halfOpenVersionSet (v lo) Nothing)

-- | A dependee set, the shape the provider's @widen@ produces: one cell, no pins.
range :: Int -> Int -> InstanceSet
range lo hi =
    sourceOnly
        ( VersionSet.intersectionVersionSet
            (VersionSet.fromVersionRange (orLaterVersion (v lo)))
            (VersionSet.fromVersionRange (earlierVersion (v hi)))
        )

sourceOnly :: VersionSet.VersionSet -> InstanceSet
sourceOnly vs = InstanceSet{isInstalled = Set.empty, isSource = [SourceCell vs Map.empty]}

-- | @a@ over some range depends on @q@ in @1..3@.
dependsOnQ :: InstanceSet -> Incompatibility
dependsOnQ dependers = fromDependency pkgA dependers pkgQ (range 1 3)

tests :: TestTree
tests =
    testGroup
        "PubGrub.Store"
        [ testGroup "merging dependency facts" mergeTests
        , testGroup "merging unbuildable facts" unbuildableTests
        , testGroup "what must not merge" separateTests
        ]

-- --------------------------------------------------------------------------
-- What merges
-- --------------------------------------------------------------------------

mergeTests :: [TestTree]
mergeTests =
    [ testCase "two adjacent slots of one depender become one fact" $ do
        let store = insertClauses [dependsOnQ (slot 1 2), dependsOnQ (slot 2 3)] emptyStore
        case storeClauses store of
            [only] -> dependerOf only `shouldDenote` sourceOnly (halfOpen 1 3)
            cs     -> assertFailure ("expected one clause, got " ++ show (length cs))
    , -- The reason slots are what the provider emits: two singleton ranges would
      -- union to a set with a hole in it, and the hole is a range the solver then
      -- has to refute separately.
      testCase "the joined range is contiguous, with no hole between the releases" $ do
        let store = insertClauses [dependsOnQ (slot 1 2), dependsOnQ (slot 2 3)] emptyStore
            wholeSpan = sourceOnly (halfOpen 1 3)
        case storeClauses store of
            [only] ->
                do
                    assertBool
                        "1.5 should be inside the merged depender range"
                        (dependerOf only `denotesVersion` mkVersion [1, 5])
                    dependerOf only `shouldDenote` wholeSpan
            cs -> assertFailure ("expected one clause, got " ++ show (length cs))
    , testCase "three slots merge into one, in any arrival order" $ do
        let forwards = insertClauses [dependsOnQ (slot 1 2), dependsOnQ (slot 2 3), dependsOnQ (slotFrom 3)] emptyStore
            backwards = insertClauses [dependsOnQ (slotFrom 3), dependsOnQ (slot 2 3), dependsOnQ (slot 1 2)] emptyStore
        length (storeClauses forwards) @?= 1
        length (storeClauses backwards) @?= 1
    , -- What the merge is for on the reporting side: the result must stay a leaf.
      -- Reaching the same range by resolving the narrow facts against each other
      -- produces a 'CauseDerivedFrom' node, and those nodes are the proof lines
      -- this exists to remove.
      testCase "the merged fact is a dependency leaf, not a derived node" $ do
        let store = insertClauses [dependsOnQ (slot 1 2), dependsOnQ (slot 2 3)] emptyStore
        case map incompCause (storeClauses store) of
            [CauseDependency p _ (q, _)] -> (p, q) @?= (pkgA, pkgQ)
            _ -> assertFailure "expected a single CauseDependency leaf"
    , -- Clause position dominates propagation cost, so a merge must not move the
      -- clause it merges into: the store here is [newest … oldest] and the merged
      -- fact stays where the fact it absorbed was.
      testCase "merging leaves the scan order alone" $ do
        let other = noInstances pkgB (sourceOnly (halfOpen 1 2))
            store =
                insertClause (dependsOnQ (slot 2 3)) $
                    insertClause other $
                        insertClause (dependsOnQ (slot 1 2)) emptyStore
        case storeClauses store of
            [b, a] -> do
                case incompCause b of
                    CauseNoInstances p _ -> p @?= pkgB
                    _ -> assertFailure "the newest clause should still be the ban"
                dependerOf a `shouldDenote` sourceOnly (halfOpen 1 3)
            cs -> assertFailure ("expected two clauses, got " ++ show (length cs))
    ]

-- --------------------------------------------------------------------------
-- What stays separate
-- --------------------------------------------------------------------------

separateTests :: [TestTree]
separateTests =
    [ testCase "different dependees stay separate" $ do
        let store =
                insertClauses
                    [ fromDependency pkgA (slot 1 2) pkgQ (range 1 3)
                    , fromDependency pkgA (slot 2 3) pkgB (range 1 3)
                    ]
                    emptyStore
        length (storeClauses store) @?= 2
    , -- The dependee term has to be identical, not merely overlapping: two
      -- releases requiring different ranges of @q@ are two different facts, and
      -- unioning their dependers would claim each release accepts the other's
      -- range.
      testCase "the same dependee at a different range stays separate" $ do
        let store =
                insertClauses
                    [ fromDependency pkgA (slot 1 2) pkgQ (range 1 3)
                    , fromDependency pkgA (slot 2 3) pkgQ (range 1 4)
                    ]
                    emptyStore
        length (storeClauses store) @?= 2
    , testCase "different dependers stay separate" $ do
        let store =
                insertClauses
                    [ fromDependency pkgA (slot 1 2) pkgQ (range 1 3)
                    , fromDependency pkgB (slot 1 2) pkgQ (range 1 3)
                    ]
                    emptyStore
        length (storeClauses store) @?= 2
    , -- A @noInstances@ ban is not a merge candidate. Unlike the unbuildable facts
      -- below it is minted by the /solver/, for the one range it happened to query,
      -- and no part of the spec asks for those to be collapsed; merging them would
      -- be sound and simply is not done. Derived clauses are
      -- excluded for a stronger reason: their terms have been through the algebra,
      -- where the DNF stops being canonical and structural equality stops meaning
      -- set equality.
      testCase "bans are never merged, even for the same package" $ do
        let store =
                insertClauses
                    [ noInstances pkgA (sourceOnly (halfOpen 1 2))
                    , noInstances pkgA (sourceOnly (halfOpen 1 2))
                    ]
                    emptyStore
        length (storeClauses store) @?= 2
    , -- A pinned depender cell and an unpinned one over the same range are
      -- A pinned depender cell and an unpinned one over the same range are
      -- different facts about different instances, but only the *dependee* side
      -- is keyed on, so they merge into one fact whose depender is the union.
      -- That is sound, and it is the intended behaviour.
      testCase "dependers differing in flags merge, because only the dependee is keyed" $ do
        let pinned =
                InstanceSet
                    { isInstalled = Set.empty
                    , isSource = [SourceCell (halfOpen 1 2) (Map.singleton (mkFlagName "fast") (PinnedTo True))]
                    }
            store =
                insertClauses
                    [ fromDependency pkgA pinned pkgQ (range 1 3)
                    , fromDependency pkgA (slot 2 3) pkgQ (range 1 3)
                    ]
                    emptyStore
        length (storeClauses store) @?= 1
    ]

-- --------------------------------------------------------------------------
-- Unbuildable facts
-- --------------------------------------------------------------------------

-- | @references\/pubgrub.md:477@ asks for the same adjacency collapsing that
-- @:456@ asks for on dependencies: an unselectable version, "as well as any
-- adjacent versions that are also incompatible", is /one/ incompatibility. The
-- provider states one per release slot and these are where the run becomes
-- contiguous.
unbuildableTests :: [TestTree]
unbuildableTests =
    [ testCase "two adjacent unbuildable slots become one fact" $ do
        let store =
                insertClauses
                    [unbuildable pkgA (slot 1 2), unbuildable pkgA (slot 2 3)]
                    emptyStore
        case storeClauses store of
            [only] -> bannedBy only `shouldDenote` sourceOnly (halfOpen 1 3)
            cs     -> assertFailure ("expected one clause, got " ++ show (length cs))
    , -- The point of the slot, again: a run of unbuildable releases must read as one
      -- range in the proof, not as one line per release with holes between them.
      testCase "the run is contiguous, and covers between the releases" $ do
        let store =
                insertClauses
                    [unbuildable pkgA (slot 1 2), unbuildable pkgA (slot 2 3)]
                    emptyStore
        case storeClauses store of
            [only] ->
                assertBool
                    "1.5 should be inside the merged run"
                    (bannedBy only `denotesVersion` mkVersion [1, 5])
            cs -> assertFailure ("expected one clause, got " ++ show (length cs))
    , testCase "the merged fact stays an unbuildable leaf" $ do
        let store =
                insertClauses
                    [unbuildable pkgA (slot 1 2), unbuildable pkgA (slot 2 3)]
                    emptyStore
        case map incompCause (storeClauses store) of
            [CauseUnbuildable p _] -> p @?= pkgA
            _ -> assertFailure "expected a single CauseUnbuildable leaf"
    , testCase "different packages stay separate" $ do
        let store =
                insertClauses
                    [unbuildable pkgA (slot 1 2), unbuildable pkgB (slot 2 3)]
                    emptyStore
        length (storeClauses store) @?= 2
    , -- Two different facts about the same instances: "cannot be built here" and
      -- "has this dependency". Merging them would state one as the other.
      testCase "an unbuildable fact does not merge with a dependency fact" $ do
        let store =
                insertClauses
                    [unbuildable pkgA (slot 1 2), dependsOnQ (slot 2 3)]
                    emptyStore
        length (storeClauses store) @?= 2
    ]

-- --------------------------------------------------------------------------
-- Helpers
-- --------------------------------------------------------------------------

-- | The instance set an unbuildable fact bans, read off its cause.
bannedBy :: Incompatibility -> InstanceSet
bannedBy i = case incompCause i of
    CauseUnbuildable _ s -> s
    _                    -> error "not an unbuildable clause"

halfOpen :: Int -> Int -> VersionSet.VersionSet
halfOpen lo hi = VersionSet.halfOpenVersionSet (v lo) (Just (v hi))

-- | The depender's instance set, read off the clause's cause.
dependerOf :: Incompatibility -> InstanceSet
dependerOf i = case incompCause i of
    CauseDependency _ s _ -> s
    _                     -> error "not a dependency clause"

-- | Semantic equality: 'InstanceSet' has no lawful 'Eq', so compare by mutual
-- containment ('PubGrub.SetOps.equivalent').
shouldDenote :: InstanceSet -> InstanceSet -> IO ()
shouldDenote actual expected =
    assertBool "instance sets denote different things" (equivalent actual expected)

-- | Whether the set contains the given version — asked about a version that
-- exists in no index, to check the merged range has no hole where the two slots
-- met.
denotesVersion :: InstanceSet -> Version -> Bool
denotesVersion s ver = any (\vs -> VersionSet.contains vs ver) (map scVersionSet (isSource s))
