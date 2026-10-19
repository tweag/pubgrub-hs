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

import           Data.List.NonEmpty              (NonEmpty)
import qualified Data.List.NonEmpty              as NE
import qualified Data.Map.Strict                 as Map
import qualified Data.Set                        as Set
import           Distribution.Types.Flag         (mkFlagName)
import           Distribution.Types.PackageName  (PackageName, mkPackageName)
import           Distribution.Types.PkgconfigDependency (PkgconfigDependency (..))
import           Distribution.Types.PkgconfigName (mkPkgconfigName)
import           Distribution.Types.PkgconfigVersionRange (anyPkgconfigVersion)
import qualified Distribution.Types.Version      as Cabal
import           PubGrub.Cabal.Version                 (Version)
import qualified PubGrub.Cabal.Version                 as V
import           Distribution.Types.VersionRange (earlierVersion,
                                                  orLaterVersion)
import           PubGrub.Cabal                  (Cabal,
                                                 CabalFact (..),
                                                 UnbuildableReason (..),
                                                 fromDependency,
                                                 unbuildable)
import           PubGrub.Incompatibility        (Cause (..),
                                                 Incompatibility (..),
                                                 noValues)
import           PubGrub.Cabal.InstanceSet            (InstanceSet (..))
import           PubGrub.SetOps                 (SetOps (isEmpty), equivalent)
import           PubGrub.Cabal.Value                  (ValueSet (..), instanceSet)
import           PubGrub.Cabal.Variable               (Flag (..), Var (..))
import           PubGrub.Term                   (Term (..))
import           PubGrub.Store                  (emptyStore, insertClause,
                                                 insertClauses, storeClauses)
import qualified PubGrub.Cabal.VersionSet             as VersionSet
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
v n = V.mkVersion [n]

-- | The same, as a Cabal version: what a declared range is written with.
cv :: Int -> Cabal.Version
cv n = Cabal.mkVersion [n]

-- | A release's slot, as 'PubGrub.Cabal.Provider.withSlots' mints it: from this release
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
            (VersionSet.fromVersionRange (orLaterVersion (cv lo)))
            (VersionSet.fromVersionRange (earlierVersion (cv hi)))
        )

sourceOnly :: VersionSet.VersionSet -> InstanceSet
sourceOnly vs = InstanceSet{isInstalled = Set.empty, isSource = vs}

-- | An unconditional dependency fact.
dependency :: PackageName -> InstanceSet -> PackageName -> InstanceSet -> Incompatibility Cabal
dependency p s q r = fromDependency p s Map.empty q r

-- | A ban on a range of a package, as the solver mints one.
ban :: PackageName -> InstanceSet -> Incompatibility Cabal
ban p s = noValues (PackageVar p) (instanceSet s)

-- | @a@ over some range depends on @q@ in @1..3@.
dependsOnQ :: InstanceSet -> Incompatibility Cabal
dependsOnQ dependers = dependency pkgA dependers pkgQ (range 1 3)

-- | The same, under a flag guard.
dependsOnQWhen :: Flag -> Bool -> InstanceSet -> Incompatibility Cabal
dependsOnQWhen f b dependers = fromDependency pkgA dependers (Map.singleton f b) pkgQ (range 1 3)

fast :: Flag
fast = Flag (mkFlagName "fast") True

-- | Why a release cannot be built: a @pkg-config@ module this machine lacks.
missing :: String -> UnbuildableReason
missing name = MissingPkgConfig (PkgconfigDependency (mkPkgconfigName name) anyPkgconfigVersion)

libpq, zlib :: NonEmpty UnbuildableReason
libpq = NE.singleton (missing "libpq")
zlib = NE.singleton (missing "zlib")

-- | A release cannot be built here for want of @libpq@ — the reason every
-- unbuildable fact below gives unless it says otherwise.
needsLibpq :: InstanceSet -> Incompatibility Cabal
needsLibpq s = unbuildable pkgA s Map.empty libpq

tests :: TestTree
tests =
    testGroup
        "PubGrub.Store"
        [ testGroup "merging dependency facts" mergeTests
        , testGroup "merging unbuildable facts" unbuildableTests
        , testGroup "what must not merge" separateTests
        , testGroup "self-dependencies" selfDepTests
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
                        (dependerOf only `denotesVersion` V.mkVersion [1, 5])
                    dependerOf only `shouldDenote` wholeSpan
            cs -> assertFailure ("expected one clause, got " ++ show (length cs))
    , testCase "three slots merge into one, in any arrival order" $ do
        let forwards = insertClauses [dependsOnQ (slot 1 2), dependsOnQ (slot 2 3), dependsOnQ (slotFrom 3)] emptyStore
            backwards = insertClauses [dependsOnQ (slotFrom 3), dependsOnQ (slot 2 3), dependsOnQ (slot 1 2)] emptyStore
        length (storeClauses forwards) @?= 1
        length (storeClauses backwards) @?= 1
    , -- What the merge is for on the reporting side: the result must stay a leaf.
      -- Reaching the same range by resolving the narrow facts against each other
      -- produces a 'Derived' node, and those nodes are the proof lines
      -- this exists to remove.
      testCase "the merged fact is a dependency leaf, not a derived node" $ do
        let store = insertClauses [dependsOnQ (slot 1 2), dependsOnQ (slot 2 3)] emptyStore
        case map incompCause (storeClauses store) of
            [Fact (CauseDependency p _ _ (q, _))] -> (p, q) @?= (pkgA, pkgQ)
            _ -> assertFailure "expected a single CauseDependency leaf"
    , -- Clause position dominates propagation cost, so a merge must not move the
      -- clause it merges into: the store here is [newest … oldest] and the merged
      -- fact stays where the fact it absorbed was.
      testCase "merging leaves the scan order alone" $ do
        let other = ban pkgB (sourceOnly (halfOpen 1 2))
            store =
                insertClause (dependsOnQ (slot 2 3)) $
                    insertClause other $
                        insertClause (dependsOnQ (slot 1 2)) emptyStore
        case storeClauses store of
            [b, a] -> do
                case incompCause b of
                    NoValues p _ -> p @?= PackageVar pkgB
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
                    [ dependency pkgA (slot 1 2) pkgQ (range 1 3)
                    , dependency pkgA (slot 2 3) pkgB (range 1 3)
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
                    [ dependency pkgA (slot 1 2) pkgQ (range 1 3)
                    , dependency pkgA (slot 2 3) pkgQ (range 1 4)
                    ]
                    emptyStore
        length (storeClauses store) @?= 2
    , testCase "different dependers stay separate" $ do
        let store =
                insertClauses
                    [ dependency pkgA (slot 1 2) pkgQ (range 1 3)
                    , dependency pkgB (slot 1 2) pkgQ (range 1 3)
                    ]
                    emptyStore
        length (storeClauses store) @?= 2
    , -- A @noValues@ ban is not a merge candidate. Unlike the unbuildable facts
      -- below it is minted by the /solver/, for the one range it happened to query,
      -- and no part of the spec asks for those to be collapsed; merging them would
      -- be sound and simply is not done. Derived clauses are
      -- excluded for a stronger reason: their terms have been through the algebra,
      -- where the DNF stops being canonical and structural equality stops meaning
      -- set equality.
      testCase "bans are never merged, even for the same package" $ do
        let store =
                insertClauses
                    [ ban pkgA (sourceOnly (halfOpen 1 2))
                    , ban pkgA (sourceOnly (halfOpen 1 2))
                    ]
                    emptyStore
        length (storeClauses store) @?= 2
    , -- The guard is part of the fact. A dependency that holds only with @fast@ on
      -- and one that holds unconditionally say different things about the same
      -- releases, and merging them would drop the condition from one of them.
      testCase "a guarded fact and an unguarded one stay separate" $ do
        let store =
                insertClauses
                    [ dependsOnQWhen fast True (slot 1 2)
                    , dependsOnQ (slot 2 3)
                    ]
                    emptyStore
        length (storeClauses store) @?= 2
    , testCase "the same guard at the opposite value stays separate" $ do
        let store =
                insertClauses
                    [ dependsOnQWhen fast True (slot 1 2)
                    , dependsOnQWhen fast False (slot 2 3)
                    ]
                    emptyStore
        length (storeClauses store) @?= 2
    , -- Two adjacent releases carrying the same guarded occurrence are one fact,
      -- exactly as unguarded ones are: the guard's terms are identical on both
      -- sides, so the union argument holds term for term.
      testCase "two adjacent slots under the same guard become one fact" $ do
        let store =
                insertClauses
                    [ dependsOnQWhen fast True (slot 1 2)
                    , dependsOnQWhen fast True (slot 2 3)
                    ]
                    emptyStore
        case storeClauses store of
            [only] -> do
                dependerOf only `shouldDenote` sourceOnly (halfOpen 1 3)
                case incompCause only of
                    Fact (CauseDependency _ _ g _) -> g @?= Map.singleton fast True
                    _ -> assertFailure "expected a dependency leaf"
            cs -> assertFailure ("expected one clause, got " ++ show (length cs))
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
                    [needsLibpq (slot 1 2), needsLibpq (slot 2 3)]
                    emptyStore
        case storeClauses store of
            [only] -> bannedBy only `shouldDenote` sourceOnly (halfOpen 1 3)
            cs     -> assertFailure ("expected one clause, got " ++ show (length cs))
    , -- The point of the slot, again: a run of unbuildable releases must read as one
      -- range in the proof, not as one line per release with holes between them.
      testCase "the run is contiguous, and covers between the releases" $ do
        let store =
                insertClauses
                    [needsLibpq (slot 1 2), needsLibpq (slot 2 3)]
                    emptyStore
        case storeClauses store of
            [only] ->
                assertBool
                    "1.5 should be inside the merged run"
                    (bannedBy only `denotesVersion` V.mkVersion [1, 5])
            cs -> assertFailure ("expected one clause, got " ++ show (length cs))
    , testCase "the merged fact stays an unbuildable leaf, with its reasons" $ do
        let store =
                insertClauses
                    [needsLibpq (slot 1 2), needsLibpq (slot 2 3)]
                    emptyStore
        case map incompCause (storeClauses store) of
            [Fact (CauseUnbuildable p _ _ why)] -> (p, why) @?= (pkgA, libpq)
            _ -> assertFailure "expected a single CauseUnbuildable leaf"
    , testCase "different packages stay separate" $ do
        let store =
                insertClauses
                    [needsLibpq (slot 1 2), unbuildable pkgB (slot 2 3) Map.empty libpq]
                    emptyStore
        length (storeClauses store) @?= 2
    , -- The reasons are part of the fact. Merging a release that lacks libpq with
      -- one that lacks zlib would print one module against both ranges, which is
      -- false of each.
      testCase "adjacent slots ruled out for different reasons stay separate" $ do
        let store =
                insertClauses
                    [needsLibpq (slot 1 2), unbuildable pkgA (slot 2 3) Map.empty zlib]
                    emptyStore
        length (storeClauses store) @?= 2
    , -- ...but the same reasons in another order are the same fact: the key is a
      -- set, so the order the .cabal lists its modules in does not split a run.
      testCase "the same reasons in a different order still merge" $ do
        let both = unbuildable pkgA (slot 1 2) Map.empty (NE.fromList [missing "libpq", missing "zlib"])
            swapped = unbuildable pkgA (slot 2 3) Map.empty (NE.fromList [missing "zlib", missing "libpq"])
            store = insertClauses [both, swapped] emptyStore
        case storeClauses store of
            [only] -> bannedBy only `shouldDenote` sourceOnly (halfOpen 1 3)
            cs     -> assertFailure ("expected one clause, got " ++ show (length cs))
    , -- A verdict under a flag is a fact about those flag values, so two runs
      -- unbuildable under the same value of the same flag are one fact, and the
      -- merged clause keeps the flag term.
      testCase "guarded unbuildable facts merge under the same guard, and keep it" $ do
        let under b s = unbuildable pkgA s (Map.singleton fast b) libpq
            store = insertClauses [under True (slot 1 2), under True (slot 2 3)] emptyStore
        case storeClauses store of
            [only] -> do
                bannedBy only `shouldDenote` sourceOnly (halfOpen 1 3)
                Map.member (FlagVar pkgA fast) (incompTerms only) @?= True
            cs -> assertFailure ("expected one clause, got " ++ show (length cs))
    , testCase "guarded unbuildable facts under different guards stay separate" $ do
        let under b s = unbuildable pkgA s (Map.singleton fast b) libpq
            store = insertClauses [under True (slot 1 2), under False (slot 2 3), needsLibpq (slot 3 4)] emptyStore
        length (storeClauses store) @?= 3
    , -- Two different facts about the same instances: "cannot be built" and
      -- "has this dependency". Merging them would state one as the other.
      testCase "an unbuildable fact does not merge with a dependency fact" $ do
        let store =
                insertClauses
                    [needsLibpq (slot 1 2), dependsOnQ (slot 2 3)]
                    emptyStore
        length (storeClauses store) @?= 2
    ]

-- --------------------------------------------------------------------------
-- Helpers
-- --------------------------------------------------------------------------

-- | The instance set an unbuildable fact bans, read off its cause.
bannedBy :: Incompatibility Cabal -> InstanceSet
bannedBy i = case incompCause i of
    Fact (CauseUnbuildable _ s _ _) -> s
    _ -> error "not an unbuildable clause"

halfOpen :: Int -> Int -> VersionSet.VersionSet
halfOpen lo hi = VersionSet.halfOpenVersionSet (v lo) (Just (v hi))

-- | The depender's instance set, read off the clause's cause.
dependerOf :: Incompatibility Cabal -> InstanceSet
dependerOf i = case incompCause i of
    Fact (CauseDependency _ s _ _) -> s
    _ -> error "not a dependency clause"

-- | Semantic equality, by mutual containment; with a canonical 'InstanceSet'
-- this is '==', and keeping the semantic form says what is being asked.
shouldDenote :: InstanceSet -> InstanceSet -> IO ()
shouldDenote actual expected =
    assertBool "instance sets denote different things" (equivalent actual expected)

-- | Whether the set contains the given version — asked about a version that
-- exists in no index, to check the merged range has no hole where the two slots
-- met.
denotesVersion :: InstanceSet -> Version -> Bool
denotesVersion s ver = VersionSet.contains (isSource s) ver

-- --------------------------------------------------------------------------
-- Self-dependencies
-- --------------------------------------------------------------------------

-- | A dependency of @p@ on @p@ puts /two/ entries about one variable into
-- 'fromDependency'. They have to be intersected, not overwritten.
--
-- 'PubGrub.Store.mergeInto' rebuilds a merged clause through 'fromDependency', so
-- the shape matters here as well as at the provider, which is the other reason
-- this lives in this module. The provider does not emit such a fact at all
-- (@Bridge.Provider@, following cabal\'s @extendOpen@), so these tests are the
-- guard rather than the rule.
selfDepTests :: [TestTree]
selfDepTests =
    [ testCase "the depender term survives, and the clause stays positive" $ do
        -- p in [1,2) requires p in [2,3): impossible for every instance of p in
        -- [1,2), and says nothing whatever about the rest of p.
        case Map.toList (incompTerms (dependency pkgA (slot 1 2) pkgA (range 2 3))) of
            [(p, Positive (ValueSet s _))] -> do
                p @?= PackageVar pkgA
                s `shouldDenote` sourceOnly (halfOpen 1 2)
            ts ->
                assertFailure
                    ( "expected one positive term about a, got "
                        ++ show (length ts)
                        ++ " term(s): "
                        ++ show [(p, negativeTerm t) | (p, t) <- ts]
                    )
    , -- The regression proper. Overwriting instead of intersecting left
      -- Overwriting instead of intersecting would leave @{p: Negative depSet}@ —
      -- "p must be in depSet", asserted of every instance of p rather than of the
      -- ones the depender term named. On @lens@ that forces @lens ==1.7@ across a
      -- whole solve.
      testCase "it is never a bare requirement on the whole package" $ do
        let inc = dependency pkgA (slot 1 2) pkgA (range 2 3)
        assertBool
            "a self-dependency must not become a Negative unit clause"
            (not (any negativeTerm (Map.elems (incompTerms inc))))
    , testCase "a self-dependency covering its own slot claims nothing" $ do
        -- The ordinary case: a component built against its own library, at its own
        -- version. The difference is empty, so the clause is unsatisfiable — it
        -- forbids nothing and constrains nothing.
        case Map.toList (incompTerms (dependency pkgA (slot 1 2) pkgA (range 1 3))) of
            [(_, Positive s)] ->
                assertBool "expected an empty positive term" (isEmpty s)
            ts -> assertFailure ("expected one term, got " ++ show (length ts))
    ]
  where
    negativeTerm (Negative _) = True
    negativeTerm (Positive _) = False
