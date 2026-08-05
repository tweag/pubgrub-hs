# PubGrub Native Solver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the native PubGrub (CDNL) version solver in Haskell, validated end-to-end against an in-memory `DependencyProvider`.

**Architecture:** A `VersionSet` (normalized intervals, backed by Cabal's canonical `VersionInterval` form so structural `Eq` is semantic) underpins `Term`s and `Incompatibility`s. The solver is a flat partial-solution + incompatibility-list loop implementing naïve unit propagation, conflict resolution (Rule of Resolution + satisfier / previous-satisfier search), and decision making. Logic mirrors the Rust reference in `references/pubgrub/src/`.

**Tech Stack:** GHC 9.12.4, `Cabal-syntax` (Version/VersionRange/VersionInterval), `containers`, `text`; tests with `tasty` + `tasty-quickcheck` + `tasty-hunit`.

---

## Deviations from the spec (`docs/superpowers/specs/2026-06-10-pubgrub-native-solver-design.md`)

These refinements were validated against Cabal's API and the Rust reference during planning. They override the spec where they conflict:

1. **`VersionSet` is backed by Cabal's `VersionInterval`** (`newtype VersionSet = VersionSet [VersionInterval]`), kept in canonical form via `asVersionIntervals`. This removes the spec's `nextVersion`/successor problem entirely: bounds carry explicit inclusive/exclusive flags. Verified: `asVersionIntervals` merges adjacency so derived `Eq` is semantic.
2. **`solve` takes a concrete root `Version`, not a `VersionSet`** (spec §5 had `VersionSet`; the reference and the intro doc §6 use a version). Root seed is `notRoot root rootV = { root: Negative (singleton rootV) }` (matches Rust `Incompatibility::not_root`), pinning the root, rather than the intro doc's simplified `Negative empty`.
3. **Unit propagation uses the naïve full-rescan fixpoint** (intro doc §6.1 explicitly blesses this), not Rust's `unit_propagation_buffer` worklist.
4. **`Assignment` keeps the spec's `Decision | Derivation` constructors**, with a uniform `assignmentTerm` accessor for satisfier scans.

## Environment / verification note

The sandbox cannot reach `hackage.haskell.org`, so `tasty`/`QuickCheck` cannot be fetched here. **The implementer (you, the human, or CI) runs `cabal build` / `cabal test` where hackage is reachable** — those are the authoritative pass/fail gates. As an *interim* check the agent can typecheck library modules offline (they need only boot libs):

```sh
ghc -fno-code -Wall -isrc -package Cabal-syntax -XGHC2021 src/PubGrub/VersionSet.hs
```

Always pass `-Wall` so the offline check matches the cabal `warnings` stanza (otherwise warnings like redundant imports slip through). Even better, run the real library build when offline allows it (it needs only boot libs): `cabal build pubgrub-hs:lib:pubgrub-hs`. Each task's "run tests" step is the human/CI gate; treat the offline typecheck/build as a fast pre-check, not a substitute.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `src/PubGrub/VersionSet.hs` | Normalized version-set type + arithmetic + `Lattice` instance |
| `src/PubGrub/Lattice.hs` | (existing) `Lattice` class — keep as-is, `VersionSet` instances it |
| `src/PubGrub/Types.hs` | `Package`; `Term` + term algebra; `Incompatibility`, `IncompatCause`, relations, smart constructors, `priorCause`, `isTerminal` |
| `src/PubGrub/Solver.hs` | `DependencyProvider`; `Assignment`, `PartialSolution`; satisfier search; `conflictResolution`; `unitPropagation`; `solve`; `SolveError`; `reportConflict` |
| `src/PubGrub.hs` | Top-level re-export (replaces current sketch) |
| `test/Main.hs` | `tasty` test tree entry point |
| `test/VersionSetSpec.hs` | QuickCheck properties + `Arbitrary` instances |
| `test/SolverSpec.hs` | In-memory `DependencyProvider` + scenario tests |
| `pubgrub-hs.cabal` | Module list, deps, `test-suite` stanza |

---

## Task 1: Cabal scaffolding

**Files:**
- Modify: `pubgrub-hs.cabal`

- [ ] **Step 1: Update the `library` stanza**

Replace the existing `library` stanza (lines 13–30) with:

```cabal
library
    import:           warnings
    exposed-modules:
        PubGrub
        PubGrub.VersionSet
        PubGrub.Types
        PubGrub.Solver
    other-modules:
        PubGrub.Lattice
    build-depends:
        , base ^>=4.21.0.0
        , containers
        , Cabal-syntax
        , text
    hs-source-dirs:   src
    default-language: GHC2021
```

- [ ] **Step 2: Add a `test-suite` stanza**

Append to `pubgrub-hs.cabal`:

```cabal
test-suite pubgrub-hs-test
    import:           warnings
    type:             exitcode-stdio-1.0
    main-is:          Main.hs
    other-modules:
        VersionSetSpec
        SolverSpec
    build-depends:
        , pubgrub-hs
        , base
        , containers
        , Cabal-syntax
        , tasty
        , tasty-quickcheck
        , tasty-hunit
    hs-source-dirs:   test
    default-language: GHC2021
```

- [ ] **Step 3: Create placeholder source files so the project configures**

Create `src/PubGrub/VersionSet.hs`:

```haskell
module PubGrub.VersionSet () where
```

Create `src/PubGrub/Types.hs`:

```haskell
module PubGrub.Types () where
```

Create `src/PubGrub/Solver.hs`:

```haskell
module PubGrub.Solver () where
```

Create `test/Main.hs`:

```haskell
module Main (main) where

main :: IO ()
main = putStrLn "placeholder"
```

Create `test/VersionSetSpec.hs` and `test/SolverSpec.hs`:

```haskell
module VersionSetSpec () where
```

```haskell
module SolverSpec () where
```

Leave the existing `src/PubGrub.hs` (the type-class sketch) untouched for now; Task 9 rewrites it.

- [ ] **Step 4: Verify configuration**

Run: `cabal build --dry-run all`
Expected: succeeds listing the library and test-suite (no compile yet). If hackage is unreachable, instead run the offline typecheck of the existing library to confirm the cabal file parses: `cabal build pubgrub-hs:lib:pubgrub-hs 2>&1 | head` — expect it to compile the old `PubGrub` sketch or report only missing-module errors for the new empty modules (which still compile).

- [ ] **Step 5: Commit**

```bash
git add pubgrub-hs.cabal src/PubGrub/VersionSet.hs src/PubGrub/Types.hs src/PubGrub/Solver.hs test/
git commit -m "chore: scaffold solver modules and test-suite"
```

---

## Task 2: VersionSet implementation

**Files:**
- Modify: `src/PubGrub/VersionSet.hs`
- Read: `src/PubGrub/Lattice.hs` (for the `Lattice` class — `(\/)` join, `(/\)` meet)

- [ ] **Step 1: Write the module with full API**

Replace the contents of `src/PubGrub/VersionSet.hs`:

```haskell
{-# LANGUAGE DerivingStrategies #-}

-- | A version set: a canonical, sorted, disjoint, non-adjacent collection of
-- version intervals. Backed by Cabal's 'VersionInterval' so that derived
-- structural equality coincides with semantic equality.
module PubGrub.VersionSet
  ( VersionSet
  , empty
  , full
  , singleton
  , fromVersionRange
  , toVersionRange
  , complement
  , union
  , intersection
  , contains
  , isEmpty
  , isFull
  , subsetOf
  , isDisjoint
  , intervals
  ) where

import Distribution.Version
  ( Version
  , VersionRange
  , anyVersion
  , noVersion
  , thisVersion
  , orLaterVersion
  , laterVersion
  , orEarlierVersion
  , earlierVersion
  , unionVersionRanges
  , intersectVersionRanges
  )
import Distribution.Types.VersionInterval
  ( VersionInterval (..)
  , LowerBound (..)
  , UpperBound (..)
  , Bound (..)
  , asVersionIntervals
  )

import PubGrub.Lattice (Lattice (..))

newtype VersionSet = VersionSet [VersionInterval]
  deriving stock (Eq, Show)

-- | The raw canonical interval list (for testing / reporting).
intervals :: VersionSet -> [VersionInterval]
intervals (VersionSet is) = is

-- | Build a canonical 'VersionSet' from any 'VersionRange'.
fromVersionRange :: VersionRange -> VersionSet
fromVersionRange = VersionSet . asVersionIntervals

-- | Convert back to a 'VersionRange' (used to delegate set arithmetic to Cabal).
toVersionRange :: VersionSet -> VersionRange
toVersionRange (VersionSet is) =
  foldr (unionVersionRanges . intervalToRange) noVersion is
  where
    intervalToRange (VersionInterval lo hi) =
      intersectVersionRanges (lowerToRange lo) (upperToRange hi)
    lowerToRange (LowerBound v InclusiveBound) = orLaterVersion v
    lowerToRange (LowerBound v ExclusiveBound) = laterVersion v
    upperToRange NoUpperBound = anyVersion
    upperToRange (UpperBound v InclusiveBound) = orEarlierVersion v
    upperToRange (UpperBound v ExclusiveBound) = earlierVersion v

empty :: VersionSet
empty = VersionSet []

full :: VersionSet
full = fromVersionRange anyVersion

-- | The set containing exactly one version.
singleton :: Version -> VersionSet
singleton = fromVersionRange . thisVersion

union :: VersionSet -> VersionSet -> VersionSet
union a b = fromVersionRange (unionVersionRanges (toVersionRange a) (toVersionRange b))

intersection :: VersionSet -> VersionSet -> VersionSet
intersection a b = fromVersionRange (intersectVersionRanges (toVersionRange a) (toVersionRange b))

-- | Complement: intersection of the complements of each interval.
complement :: VersionSet -> VersionSet
complement (VersionSet is) =
  fromVersionRange (foldr (intersectVersionRanges . complementInterval) anyVersion is)
  where
    complementInterval (VersionInterval lo hi) =
      unionVersionRanges (belowLower lo) (aboveUpper hi)
    belowLower (LowerBound v InclusiveBound) = earlierVersion v   -- < v
    belowLower (LowerBound v ExclusiveBound) = orEarlierVersion v -- <= v
    aboveUpper NoUpperBound = noVersion                           -- nothing above
    aboveUpper (UpperBound v InclusiveBound) = laterVersion v     -- > v
    aboveUpper (UpperBound v ExclusiveBound) = orLaterVersion v   -- >= v

contains :: VersionSet -> Version -> Bool
contains (VersionSet is) v = any inside is
  where
    inside (VersionInterval lo hi) = lowerOk lo && upperOk hi
    lowerOk (LowerBound w InclusiveBound) = v >= w
    lowerOk (LowerBound w ExclusiveBound) = v > w
    upperOk NoUpperBound = True
    upperOk (UpperBound w InclusiveBound) = v <= w
    upperOk (UpperBound w ExclusiveBound) = v < w

isEmpty :: VersionSet -> Bool
isEmpty (VersionSet is) = null is

isFull :: VersionSet -> Bool
isFull = (== full)

-- | @a `subsetOf` b@ iff every version in @a@ is in @b@ (a ∩ ¬b = ∅).
subsetOf :: VersionSet -> VersionSet -> Bool
subsetOf a b = isEmpty (intersection a (complement b))

-- | Two sets are disjoint iff their intersection is empty.
isDisjoint :: VersionSet -> VersionSet -> Bool
isDisjoint a b = isEmpty (intersection a b)

instance Lattice VersionSet where
  (\/) = union
  (/\) = intersection
```

- [ ] **Step 2: Typecheck offline**

Run: `ghc -fno-code -isrc -package Cabal-syntax -XGHC2021 src/PubGrub/VersionSet.hs`
Expected: compiles with no errors or warnings.

- [ ] **Step 3: Commit**

```bash
git add src/PubGrub/VersionSet.hs
git commit -m "feat: VersionSet over canonical Cabal intervals"
```

---

## Task 3: VersionSet property tests

**Files:**
- Modify: `test/VersionSetSpec.hs`
- Modify: `test/Main.hs`

- [ ] **Step 1: Write `Arbitrary` instances and properties**

Replace `test/VersionSetSpec.hs`:

```haskell
{-# LANGUAGE ScopedTypeVariables #-}
module VersionSetSpec (tests) where

import Distribution.Version (Version, mkVersion, orLaterVersion)
import qualified PubGrub.VersionSet as VS
import PubGrub.VersionSet (VersionSet)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.QuickCheck (testProperty, Arbitrary (..), Gen, choose, listOf, elements, (===), (.&&.), property)

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
          _ -> VS.intersection (VS.fromVersionRange (orLaterVersion lo))
                               (VS.complement (VS.fromVersionRange (orLaterVersion hi)))

sampleVersions :: [Version]
sampleVersions = [mkVersion [a, b] | a <- [0 .. 3], b <- [0 .. 3]]

tests :: TestTree
tests = testGroup "VersionSet"
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
        .&&. conjoinV (\w -> if w == v then property True
                             else VS.contains (VS.singleton v) w === False)
  , testProperty "subsetOf agrees with intersection" $ \(a :: VersionSet) (b :: VersionSet) ->
      VS.subsetOf a b === (VS.intersection a b == a)
  , testGroup "Lattice laws"
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
```

- [ ] **Step 2: Wire into the test tree**

Replace `test/Main.hs`:

```haskell
module Main (main) where

import Test.Tasty (defaultMain, testGroup)
import qualified VersionSetSpec
import qualified SolverSpec

main :: IO ()
main = defaultMain $ testGroup "pubgrub-hs"
  [ VersionSetSpec.tests
  , SolverSpec.tests
  ]
```

Update `test/SolverSpec.hs` to expose a (temporarily empty) `tests`:

```haskell
module SolverSpec (tests) where

import Test.Tasty (TestTree, testGroup)

tests :: TestTree
tests = testGroup "Solver" []
```

- [ ] **Step 3: Run the property tests (human/CI gate)**

Run: `cabal test pubgrub-hs-test --test-show-details=direct`
Expected: all `VersionSet` properties PASS. (If hackage is unreachable in the agent sandbox, defer this run to the human/CI and record the result.)

- [ ] **Step 4: Commit**

```bash
git add test/
git commit -m "test: VersionSet algebra properties"
```

---

## Task 4: Term and term algebra

**Files:**
- Modify: `src/PubGrub/Types.hs`

- [ ] **Step 1: Write `Package`, `Term`, and the term algebra**

Replace `src/PubGrub/Types.hs` (this task adds the term layer; Task 5 appends the incompatibility layer to the same module):

```haskell
{-# LANGUAGE DerivingStrategies #-}

module PubGrub.Types
  ( -- * Packages
    Package
    -- * Terms
  , Term (..)
  , anyTerm
  , emptyTerm
  , exactTerm
  , isPositive
  , negateTerm
  , termContains
  , intersectTerms
  , unionTerms
  , termSubsetOf
  , termIsDisjoint
  , termIsEmpty
    -- * Term relation
  , TermRelation (..)
  , relationWith
  ) where

import Distribution.Version (Version)
import qualified PubGrub.VersionSet as VS
import PubGrub.VersionSet (VersionSet)

-- | A package is anything with equality, ordering, and a printable name.
class (Eq p, Ord p, Show p) => Package p

-- | A positive or negative assertion about a package's selected version.
data Term
  = Positive VersionSet  -- ^ a version in this set is selected
  | Negative VersionSet  -- ^ no version selected, or one outside this set
  deriving stock (Eq, Show)

-- | Always-true term (Negative empty): selecting nothing is allowed.
anyTerm :: Term
anyTerm = Negative VS.empty

-- | Never-true term (Positive empty): no version can satisfy it.
emptyTerm :: Term
emptyTerm = Positive VS.empty

-- | Positive singleton term for a concrete version.
exactTerm :: Version -> Term
exactTerm = Positive . VS.singleton

isPositive :: Term -> Bool
isPositive (Positive _) = True
isPositive (Negative _) = False

negateTerm :: Term -> Term
negateTerm (Positive s) = Negative s
negateTerm (Negative s) = Positive s

-- | Does a concrete chosen version satisfy this term?
termContains :: Term -> Version -> Bool
termContains (Positive s) v = VS.contains s v
termContains (Negative s) v = not (VS.contains s v)

-- | Logical AND of two terms (over the same package).
intersectTerms :: Term -> Term -> Term
intersectTerms (Positive r1) (Positive r2) = Positive (VS.intersection r1 r2)
intersectTerms (Positive p)  (Negative n)  = Positive (VS.intersection (VS.complement n) p)
intersectTerms (Negative n)  (Positive p)  = Positive (VS.intersection (VS.complement n) p)
intersectTerms (Negative r1) (Negative r2) = Negative (VS.union r1 r2)

-- | Logical OR of two terms (over the same package).
unionTerms :: Term -> Term -> Term
unionTerms (Positive r1) (Positive r2) = Positive (VS.union r1 r2)
unionTerms (Positive p)  (Negative n)  = Negative (VS.intersection (VS.complement p) n)
unionTerms (Negative n)  (Positive p)  = Negative (VS.intersection (VS.complement p) n)
unionTerms (Negative r1) (Negative r2) = Negative (VS.intersection r1 r2)

-- | @t1 `termSubsetOf` t2@ iff t1 ∩ t2 = t1.
termSubsetOf :: Term -> Term -> Bool
termSubsetOf (Positive r1) (Positive r2) = VS.subsetOf r1 r2
termSubsetOf (Positive r1) (Negative r2) = VS.isDisjoint r1 r2
termSubsetOf (Negative _)  (Positive _)  = False
termSubsetOf (Negative r1) (Negative r2) = VS.subsetOf r2 r1

-- | Are two terms mutually exclusive (intersection is the empty term)?
termIsDisjoint :: Term -> Term -> Bool
termIsDisjoint (Positive r1) (Positive r2) = VS.isDisjoint r1 r2
termIsDisjoint (Negative _)  (Negative _)  = False
termIsDisjoint (Positive p)  (Negative n)  = VS.subsetOf p n
termIsDisjoint (Negative n)  (Positive p)  = VS.subsetOf p n

-- | Is this the never-true term?
termIsEmpty :: Term -> Bool
termIsEmpty (Positive s) = VS.isEmpty s
termIsEmpty (Negative s) = VS.isFull s

-- | Relation of a term to an accumulated set of terms (their intersection).
data TermRelation = Satisfied | Contradicted | Inconclusive
  deriving stock (Eq, Show)

-- | @relationWith t acc@: how the accumulated term @acc@ relates to @t@.
--   Satisfied iff acc ⊆ t; Contradicted iff acc ∩ t = ∅; else Inconclusive.
relationWith :: Term -> Term -> TermRelation
relationWith t acc
  | acc `termSubsetOf` t = Satisfied
  | termIsDisjoint t acc = Contradicted
  | otherwise            = Inconclusive
```

- [ ] **Step 2: Typecheck offline**

Run: `ghc -fno-code -isrc -package Cabal-syntax -XGHC2021 src/PubGrub/Types.hs`
Expected: compiles, no warnings.

- [ ] **Step 3: Commit**

```bash
git add src/PubGrub/Types.hs
git commit -m "feat: Term type and term algebra"
```

---

## Task 5: Incompatibility, causes, relations, prior cause

**Files:**
- Modify: `src/PubGrub/Types.hs`
- Read: `references/pubgrub/src/internal/incompatibility.rs` (for `relation`, `prior_cause`, `is_terminal`)

- [ ] **Step 1: Extend the export list**

In `src/PubGrub/Types.hs`, extend the module export list (add to the existing list before the closing `)`):

```haskell
    -- * Incompatibilities
  , IncompatCause (..)
  , Incompatibility (..)
  , notRoot
  , noVersions
  , fromDependency
  , incompGet
  , IncompatRelation (..)
  , incompRelation
  , isTerminal
  , priorCause
```

- [ ] **Step 2: Add imports**

Ensure these imports are present at the top of `src/PubGrub/Types.hs`:

```haskell
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
```

- [ ] **Step 3: Append the incompatibility layer**

Append to `src/PubGrub/Types.hs`:

```haskell
-- | Why an incompatibility exists (drives error reporting).
data IncompatCause p
  = NotRoot p Version
  | NoVersions p VersionSet
  | FromDependencyOf p VersionSet p VersionSet
  | DerivedFrom (Incompatibility p) (Incompatibility p)
  deriving stock (Eq, Show)

-- | A set of terms (at most one per package) that can never all hold.
data Incompatibility p = Incompatibility
  { incompTerms :: Map p Term
  , incompCause :: IncompatCause p
  }
  deriving stock (Eq, Show)

-- | The root seed: it is impossible for @root@ to NOT be @version@.
notRoot :: p -> Version -> Incompatibility p
notRoot p v = Incompatibility
  { incompTerms = Map.singleton p (Negative (VS.singleton v))
  , incompCause = NotRoot p v
  }

-- | Ban an entire range of a package (used when no version is available).
--   The term must be positive.
noVersions :: p -> VersionSet -> Incompatibility p
noVersions p s = Incompatibility
  { incompTerms = Map.singleton p (Positive s)
  , incompCause = NoVersions p s
  }

-- | Dependency incompatibility: @package@ in @versions@ requires @dep@ in @depSet@.
--   Encoded as @{ package: Positive versions, dep: Negative depSet }@.
--   If @depSet@ is empty the dependency is unsatisfiable, leaving a unit term.
fromDependency :: Ord p => p -> VersionSet -> (p, VersionSet) -> Incompatibility p
fromDependency package versions (dep, depSet) = Incompatibility
  { incompTerms =
      if VS.isEmpty depSet
        then Map.singleton package (Positive versions)
        else Map.fromList [(package, Positive versions), (dep, Negative depSet)]
  , incompCause = FromDependencyOf package versions dep depSet
  }

incompGet :: Ord p => p -> Incompatibility p -> Maybe Term
incompGet p i = Map.lookup p (incompTerms i)

-- | Relation of a partial-solution term lookup to a whole incompatibility.
data IncompatRelation p
  = ISatisfied
  | IContradicted p
  | IAlmostSatisfied p   -- ^ all terms satisfied but one (the named package)
  | IInconclusive
  deriving stock (Eq, Show)

-- | Mirror of @Incompatibility::relation@ in the Rust reference.
--   @lookupTerm p@ returns the accumulated term for @p@ in the partial
--   solution, or Nothing if @p@ is absent (treated as the any-term).
incompRelation :: Ord p => (p -> Maybe Term) -> Incompatibility p -> IncompatRelation p
incompRelation lookupTerm i = go ISatisfied (Map.toList (incompTerms i))
  where
    go acc [] = acc
    go acc ((p, it) : rest) =
      case lookupTerm p of
        Just term ->
          case relationWith it term of
            Satisfied    -> go acc rest
            Contradicted -> IContradicted p
            Inconclusive -> almost p acc rest
        Nothing -> almost p acc rest
    -- absent or inconclusive term: at most one allowed for AlmostSatisfied
    almost p ISatisfied rest = go (IAlmostSatisfied p) rest
    almost _ _ _             = IInconclusive

-- | Does this incompatibility end the algorithm (satisfies the root)?
isTerminal :: Ord p => p -> Version -> Incompatibility p -> Bool
isTerminal rootPkg rootV i =
  case Map.toList (incompTerms i) of
    []          -> True
    [(p, term)] -> p == rootPkg && termContains term rootV
    _           -> False

-- | Rule of Resolution. From the current incompatibility and the cause of the
--   satisfier (sharing @package@), derive their resolvent: union the shared
--   term, intersect every other package's terms, drop the shared term if it
--   becomes always-true. Mirrors @Incompatibility::prior_cause@.
priorCause
  :: Ord p
  => Incompatibility p   -- ^ current incompatibility
  -> Incompatibility p   -- ^ satisfier's cause
  -> p                   -- ^ shared (pivot) package
  -> Incompatibility p
priorCause cur sat package = Incompatibility
  { incompTerms = finalTerms
  , incompCause = DerivedFrom cur sat
  }
  where
    curTerms = Map.delete package (incompTerms cur)
    satTerms = Map.delete package (incompTerms sat)
    merged   = Map.unionWith intersectTerms curTerms satTerms
    t1 = Map.findWithDefault anyTerm package (incompTerms cur)
    t2 = Map.findWithDefault anyTerm package (incompTerms sat)
    unioned = unionTerms t1 t2
    finalTerms
      | unioned == anyTerm = merged
      | otherwise          = Map.insert package unioned merged
```

- [ ] **Step 4: Typecheck offline**

Run: `ghc -fno-code -isrc -package Cabal-syntax -XGHC2021 src/PubGrub/Types.hs`
Expected: compiles, no warnings.

- [ ] **Step 5: Add Rule-of-Resolution unit tests**

In `test/SolverSpec.hs`, replace the placeholder with the rule-of-resolution test (the rest of `SolverSpec` is filled in Task 9). For now:

```haskell
{-# LANGUAGE FlexibleInstances #-}
module SolverSpec (tests) where

import qualified Data.Map.Strict as Map
import Distribution.Version (mkVersion)
import qualified PubGrub.VersionSet as VS
import PubGrub.Types
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

instance Package String

tests :: TestTree
tests = testGroup "Solver"
  [ testCase "rule of resolution combines { p1:t1, p2:¬t2 } and { p2:t2, p3:t3 }" $
      let t1 = Positive (VS.singleton (mkVersion [1]))
          t2 = Positive (VS.singleton (mkVersion [2]))
          t3 = Positive (VS.singleton (mkVersion [3]))
          i1 = Incompatibility
                 (Map.fromList [("p1", t1), ("p2", negateTerm t2)])
                 (FromDependencyOf "p1" VS.full "p2" VS.full)
          i2 = Incompatibility
                 (Map.fromList [("p2", t2), ("p3", t3)])
                 (FromDependencyOf "p2" VS.full "p3" VS.full)
          res = priorCause i1 i2 "p2"
      in incompTerms res @?= Map.fromList [("p1", t1), ("p3", t3)]
  ]
```

- [ ] **Step 6: Run tests (human/CI gate)**

Run: `cabal test pubgrub-hs-test --test-show-details=direct`
Expected: the rule-of-resolution case PASSES (alongside the VersionSet properties).

- [ ] **Step 7: Commit**

```bash
git add src/PubGrub/Types.hs test/SolverSpec.hs
git commit -m "feat: Incompatibility, relations, and rule of resolution"
```

---

## Task 6: PartialSolution and assignments

**Files:**
- Modify: `src/PubGrub/Solver.hs`
- Read: `references/pubgrub/src/internal/partial_solution.rs`

- [ ] **Step 1: Write the partial-solution core**

Replace `src/PubGrub/Solver.hs` (this task establishes the state types and accessors; later tasks append):

```haskell
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE NamedFieldPuns #-}

module PubGrub.Solver
  ( -- * Provider
    DependencyProvider (..)
    -- * Partial solution
  , Assignment (..)
  , assignmentTerm
  , PartialSolution (..)
  , emptyPS
  , addDecision
  , addDerivation
  , backtrack
  , termIntersectionForPackage
  , relation
  , extractSolution
  , undecidedPositive
  ) where

import Data.List (foldl')
import Data.Maybe (mapMaybe)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Distribution.Version (Version)

import PubGrub.Types
import qualified PubGrub.VersionSet as VS
import PubGrub.VersionSet (VersionSet)

-- | The oracle: pick a version in a range and report a version's dependencies.
class Package p => DependencyProvider dp p | dp -> p where
  chooseVersion   :: dp -> p -> VersionSet -> Maybe Version
  getDependencies :: dp -> p -> Version -> Map p VersionSet

-- | A single entry in the partial solution.
data Assignment p
  = Decision
      { aIndex   :: !Int
      , aLevel   :: !Int
      , aPackage :: p
      , aVersion :: Version
      }
  | Derivation
      { aIndex   :: !Int
      , aLevel   :: !Int
      , aPackage :: p
      , aTerm    :: Term
      , aCause   :: Incompatibility p
      }
  deriving stock (Show)

-- | The term contributed by an assignment.
assignmentTerm :: Assignment p -> Term
assignmentTerm Decision{aVersion}  = exactTerm aVersion
assignmentTerm Derivation{aTerm}   = aTerm

-- | Assignments are stored newest-first; @psLevel@ is the current decision
-- level; @psNextIndex@ is a monotone counter giving chronological order.
data PartialSolution p = PartialSolution
  { psAssignments :: [Assignment p]
  , psLevel       :: !Int
  , psNextIndex   :: !Int
  }
  deriving stock (Show)

emptyPS :: PartialSolution p
emptyPS = PartialSolution { psAssignments = [], psLevel = 0, psNextIndex = 0 }

-- | Record a decision (a guess); increments the decision level.
addDecision :: p -> Version -> PartialSolution p -> PartialSolution p
addDecision p v ps@PartialSolution{psAssignments, psLevel, psNextIndex} =
  ps { psAssignments = Decision psNextIndex (psLevel + 1) p v : psAssignments
     , psLevel = psLevel + 1
     , psNextIndex = psNextIndex + 1
     }

-- | Record a derivation: the negation of @cause@'s term for @p@, at the
-- current level. Mirrors @PartialSolution::add_derivation@.
addDerivation :: Ord p => p -> Incompatibility p -> PartialSolution p -> PartialSolution p
addDerivation p cause ps@PartialSolution{psAssignments, psLevel, psNextIndex} =
  let term = maybe anyTerm negateTerm (incompGet p cause)
  in ps { psAssignments = Derivation psNextIndex psLevel p term cause : psAssignments
        , psNextIndex = psNextIndex + 1
        }

-- | Backtrack: drop every assignment strictly above the target level.
backtrack :: Int -> PartialSolution p -> PartialSolution p
backtrack level ps@PartialSolution{psAssignments} =
  ps { psAssignments = filter ((<= level) . aLevel) psAssignments
     , psLevel = level
     }

-- | Intersection of all terms recorded for a package (Nothing if absent).
termIntersectionForPackage :: Ord p => PartialSolution p -> p -> Maybe Term
termIntersectionForPackage PartialSolution{psAssignments} p =
  case [ assignmentTerm a | a <- psAssignments, aPackage a == p ] of
    []       -> Nothing
    (t : ts) -> Just (foldl' intersectTerms t ts)

-- | Relation of the whole partial solution to an incompatibility.
relation :: Ord p => PartialSolution p -> Incompatibility p -> IncompatRelation p
relation ps = incompRelation (termIntersectionForPackage ps)

-- | The decisions, as a solution map.
extractSolution :: Ord p => PartialSolution p -> Map p Version
extractSolution PartialSolution{psAssignments} =
  Map.fromList [ (aPackage a, aVersion a) | a@Decision{} <- psAssignments ]

-- | Packages that have a positive accumulated term but no decision yet,
-- with that positive range. Chronological (oldest first) for determinism.
undecidedPositive :: Ord p => PartialSolution p -> [(p, VersionSet)]
undecidedPositive ps@PartialSolution{psAssignments} =
  let decided = [ aPackage a | a@Decision{} <- psAssignments ]
      pkgs = uniqueOldestFirst [ aPackage a | a <- reverse psAssignments ]
  in mapMaybe positive (filter (`notElem` decided) pkgs)
  where
    positive p = case termIntersectionForPackage ps p of
      Just (Positive r) -> Just (p, r)
      _                 -> Nothing
    uniqueOldestFirst = go []
      where go seen [] = reverse seen
            go seen (x:xs) | x `elem` seen = go seen xs
                           | otherwise     = go (x:seen) xs
```

Note: this module uses `MultiParamTypeClasses` and `FunctionalDependencies` for `DependencyProvider`. Add `{-# LANGUAGE MultiParamTypeClasses #-}` and `{-# LANGUAGE FunctionalDependencies #-}` to the top of the file.

- [ ] **Step 2: Typecheck offline**

Run: `ghc -fno-code -isrc -package Cabal-syntax -XGHC2021 src/PubGrub/Solver.hs`
Expected: compiles with no warnings.

- [ ] **Step 3: Commit**

```bash
git add src/PubGrub/Solver.hs
git commit -m "feat: PartialSolution, assignments, and relation"
```

---

## Task 7: Satisfier search and conflict resolution

**Files:**
- Modify: `src/PubGrub/Solver.hs`
- Read: `references/pubgrub/src/internal/partial_solution.rs` (`satisfier_search`, `find_satisfier`, `find_previous_satisfier`, `satisfier`), `references/pubgrub/src/internal/core.rs` (`conflict_resolution`)

- [ ] **Step 1: Extend exports and imports**

Add to the export list of `src/PubGrub/Solver.hs`:

```haskell
  , conflictResolution
```

Update imports: change `import Data.List (foldl')` to `import Data.List (foldl', maximumBy)`, and add `import Data.Ord (comparing)`.

- [ ] **Step 2: Append satisfier search and conflict resolution**

Append to `src/PubGrub/Solver.hs`:

```haskell
-- | All assignments for a package, oldest first.
packageHistory :: Ord p => PartialSolution p -> p -> [Assignment p]
packageHistory PartialSolution{psAssignments} p =
  reverse [ a | a <- psAssignments, aPackage a == p ]

-- | Earliest assignment of @p@ whose running accumulated term becomes disjoint
-- from @startTerm@. Mirrors @PackageAssignments::satisfier@.
-- Precondition: such an assignment exists.
satisfierOf :: Ord p => PartialSolution p -> p -> Term -> Assignment p
satisfierOf ps p startTerm = go anyTerm (packageHistory ps p)
  where
    go _ [] = error "satisfierOf: no satisfier (precondition violated)"
    go acc (a : as) =
      let acc' = intersectTerms acc (assignmentTerm a)
      in if termIsDisjoint acc' startTerm then a else go acc' as

-- | Result of searching for the satisfier of a conflict incompatibility.
data SatisfierSearch p
  = DifferentDecisionLevels !Int               -- ^ backtrack to this level
  | SameDecisionLevels (Incompatibility p)      -- ^ satisfier's cause

-- | For each term find its satisfier; the overall satisfier is the latest
-- (max index). Then recompute the previous satisfier level. Mirrors
-- @PartialSolution::satisfier_search@.
satisfierSearch :: Ord p => PartialSolution p -> Incompatibility p -> (p, SatisfierSearch p)
satisfierSearch ps i =
  let satMap = [ (p, satisfierOf ps p (negateTerm it))
               | (p, it) <- Map.toList (incompTerms i) ]
      (satPkg, satAssign) = maximumBy (comparing (aIndex . snd)) satMap
      satLevel = aLevel satAssign
      it_s = maybe anyTerm id (incompGet satPkg i)
      startTerm' = intersectTerms (assignmentTerm satAssign) (negateTerm it_s)
      prevForSat = satisfierOf ps satPkg startTerm'
      satMap' = [ (p, if p == satPkg then prevForSat else a) | (p, a) <- satMap ]
      prevLevel = max 1 (aLevel (snd (maximumBy (comparing (aIndex . snd)) satMap')))
  in case satAssign of
       Derivation{aCause}
         | prevLevel >= satLevel -> (satPkg, SameDecisionLevels aCause)
       _ -> (satPkg, DifferentDecisionLevels prevLevel)

-- | Conflict resolution loop. Returns either the terminal (unsatisfiable)
-- incompatibility, or @(almostPackage, rootCause, backtrackedSolution)@.
-- Mirrors @State::conflict_resolution@ + @backtrack@.
conflictResolution
  :: Ord p
  => p -> Version           -- ^ root package and version (for is-terminal)
  -> Incompatibility p      -- ^ the satisfied (conflict) incompatibility
  -> PartialSolution p
  -> Either (Incompatibility p) (p, Incompatibility p, PartialSolution p)
conflictResolution rootPkg rootV = loop
  where
    loop current ps
      | isTerminal rootPkg rootV current = Left current
      | otherwise =
          case satisfierSearch ps current of
            (satPkg, DifferentDecisionLevels prevLevel) ->
              Right (satPkg, current, backtrack prevLevel ps)
            (satPkg, SameDecisionLevels satCause) ->
              loop (priorCause current satCause satPkg) ps
```

- [ ] **Step 3: Typecheck offline**

Run: `ghc -fno-code -isrc -package Cabal-syntax -XGHC2021 src/PubGrub/Solver.hs`
Expected: compiles, no warnings.

- [ ] **Step 4: Commit**

```bash
git add src/PubGrub/Solver.hs
git commit -m "feat: satisfier search and conflict resolution"
```

---

## Task 8: Unit propagation

**Files:**
- Modify: `src/PubGrub/Solver.hs`
- Read: `references/pubgrub/src/internal/core.rs` (`unit_propagation`)

- [ ] **Step 1: Extend exports**

Add to the export list:

```haskell
  , unitPropagation
```

- [ ] **Step 2: Append the naïve fixpoint propagation**

Append to `src/PubGrub/Solver.hs`:

```haskell
-- | Naïve unit propagation (intro doc §6.1): repeatedly scan all
-- incompatibilities until a fixpoint, handling conflicts via
-- 'conflictResolution'. Returns the (possibly extended) incompatibility list
-- and updated partial solution, or a terminal incompatibility on failure.
unitPropagation
  :: Ord p
  => p -> Version
  -> [Incompatibility p]
  -> PartialSolution p
  -> Either (Incompatibility p) ([Incompatibility p], PartialSolution p)
unitPropagation rootPkg rootV = scan
  where
    scan incompats ps = step incompats ps incompats

    -- Walk the worklist of incompatibilities once; on any action, restart scan.
    step incompats ps [] = Right (incompats, ps)   -- fixpoint
    step incompats ps (i : rest) =
      case relation ps i of
        ISatisfied ->
          case conflictResolution rootPkg rootV i ps of
            Left terminal -> Left terminal
            Right (almostPkg, rootCause, ps') ->
              let ps'' = addDerivation almostPkg rootCause ps'
              in scan (rootCause : incompats) ps''
        IAlmostSatisfied q ->
          scan incompats (addDerivation q i ps)
        _ -> step incompats ps rest
```

- [ ] **Step 3: Typecheck offline**

Run: `ghc -fno-code -isrc -package Cabal-syntax -XGHC2021 src/PubGrub/Solver.hs`
Expected: compiles, no warnings.

- [ ] **Step 4: Commit**

```bash
git add src/PubGrub/Solver.hs
git commit -m "feat: naive unit propagation"
```

---

## Task 9: Solve loop, SolveError, in-memory provider, scenario tests

**Files:**
- Modify: `src/PubGrub/Solver.hs`
- Modify: `test/SolverSpec.hs`
- Read: `references/pubgrub/src/internal/core.rs` (main flow), `references/pubgrub/src/solver.rs`

- [ ] **Step 1: Extend exports**

Add to the export list:

```haskell
  , SolveError (..)
  , solve
```

- [ ] **Step 2: Append the solve loop**

Append to `src/PubGrub/Solver.hs`:

```haskell
-- | Failure: no solution; carries the terminal incompatibility (the root of
-- the derivation tree, for reporting).
newtype SolveError p = NoSolution (Incompatibility p)
  deriving stock (Eq, Show)

-- | Solve for a root package pinned to @rootV@. Returns a complete assignment
-- or a 'SolveError'. Mirrors the main loop in the Rust reference / intro §6.
solve
  :: DependencyProvider dp p
  => dp -> p -> Version
  -> Either (SolveError p) (Map p Version)
solve dp rootPkg rootV = go [notRoot rootPkg rootV] emptyPS
  where
    go incompats ps =
      case unitPropagation rootPkg rootV incompats ps of
        Left terminal -> Left (NoSolution terminal)
        Right (incompats', ps') ->
          case undecidedPositive ps' of
            [] -> Right (extractSolution ps')
            ((p, range) : _) ->
              case chooseVersion dp p range of
                Nothing ->
                  -- No version available in the allowed range: ban it and let
                  -- the next propagation turn it into a conflict.
                  go (noVersions p range : incompats') ps'
                Just v ->
                  let deps = getDependencies dp p v
                      depIncs =
                        [ fromDependency p (VS.singleton v) (q, r)
                        | (q, r) <- Map.toList deps ]
                  in go (depIncs ++ incompats') (addDecision p v ps')
```

- [ ] **Step 3: Typecheck offline**

Run: `ghc -fno-code -isrc -package Cabal-syntax -XGHC2021 src/PubGrub/Solver.hs`
Expected: compiles, no warnings.

- [ ] **Step 4: Rewrite the top-level re-export**

Replace `src/PubGrub.hs` entirely:

```haskell
-- | PubGrub native dependency solver — public surface.
module PubGrub
  ( module PubGrub.VersionSet
  , module PubGrub.Types
  , module PubGrub.Solver
  ) where

import PubGrub.VersionSet
import PubGrub.Types
import PubGrub.Solver
```

- [ ] **Step 5: Write the in-memory provider and scenario tests**

Replace `test/SolverSpec.hs` (keep the rule-of-resolution case, add the provider and scenarios):

```haskell
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module SolverSpec (tests) where

import Data.List (sortBy)
import Data.Maybe (listToMaybe)
import Data.Ord (Down (..), comparing)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Distribution.Version (Version, mkVersion)
import qualified PubGrub.VersionSet as VS
import PubGrub.VersionSet (VersionSet)
import PubGrub.Types
import PubGrub.Solver
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, assertBool, (@?=))

instance Package String

-- | An in-memory registry: package -> version -> its dependencies.
newtype Registry = Registry (Map String (Map Version (Map String VersionSet)))

instance DependencyProvider Registry String where
  chooseVersion (Registry reg) p range =
    let vs = maybe [] Map.keys (Map.lookup p reg)
    in listToMaybe (sortBy (comparing Down) (filter (VS.contains range) vs))
  getDependencies (Registry reg) p v =
    Map.findWithDefault Map.empty v (Map.findWithDefault Map.empty p reg)

v :: [Int] -> Version
v = mkVersion

geq :: [Int] -> VersionSet
geq = VS.fromVersionRange . Distribution.Version.orLaterVersion . mkVersion

-- Helpers to build a registry.
reg :: [(String, [([Int], [(String, VersionSet)])])] -> Registry
reg xs = Registry $ Map.fromList
  [ (p, Map.fromList [ (mkVersion ver, Map.fromList deps) | (ver, deps) <- versions ])
  | (p, versions) <- xs ]

tests :: TestTree
tests = testGroup "Solver"
  [ testCase "rule of resolution combines { p1:t1, p2:¬t2 } and { p2:t2, p3:t3 }" $
      let t1 = Positive (VS.singleton (v [1]))
          t2 = Positive (VS.singleton (v [2]))
          t3 = Positive (VS.singleton (v [3]))
          i1 = Incompatibility
                 (Map.fromList [("p1", t1), ("p2", negateTerm t2)])
                 (FromDependencyOf "p1" VS.full "p2" VS.full)
          i2 = Incompatibility
                 (Map.fromList [("p2", t2), ("p3", t3)])
                 (FromDependencyOf "p2" VS.full "p3" VS.full)
      in incompTerms (priorCause i1 i2 "p2") @?= Map.fromList [("p1", t1), ("p3", t3)]

  , testCase "trivial: root with no deps" $
      let r = reg [("root", [([1], [])])]
      in solve r "root" (v [1]) @?= Right (Map.fromList [("root", v [1])])

  , testCase "transitive: root -> a -> b" $
      let r = reg
            [ ("root", [([1], [("a", VS.full)])])
            , ("a",    [([1], [("b", VS.full)])])
            , ("b",    [([1], [])])
            ]
      in solve r "root" (v [1])
           @?= Right (Map.fromList [("root", v [1]), ("a", v [1]), ("b", v [1])])

  , testCase "backtracking: newest a (2) conflicts, falls back to a (1)" $
      -- root deps on a (any) and b (>=2).
      -- a@2 deps on b (<2)  => conflict with root's b>=2, must use a@1.
      -- a@1 deps on b (any).
      let r = reg
            [ ("root", [([1], [("a", VS.full), ("b", geq [2])])])
            , ("a", [ ([2], [("b", VS.fromVersionRange (Distribution.Version.earlierVersion (mkVersion [2])))])
                    , ([1], [("b", VS.full)]) ])
            , ("b", [ ([2], []), ([1], []) ])
            ]
      in solve r "root" (v [1])
           @?= Right (Map.fromList [("root", v [1]), ("a", v [1]), ("b", v [2])])

  , testCase "unsat: conflicting text requirements" $
      -- root -> aeson (>=2.2) and servant (any).
      -- aeson@2.2 -> text (>=2.0); servant@0.20 -> text (<2.0). No text works.
      let r = reg
            [ ("root", [([1], [("aeson", geq [2,2]), ("servant", VS.full)])])
            , ("aeson", [([2,2], [("text", geq [2,0])])])
            , ("servant", [([0,20], [("text", VS.fromVersionRange (Distribution.Version.earlierVersion (mkVersion [2,0])))])])
            , ("text", [([2,0], []), ([1,2], [])])
            ]
      in case solve r "root" (v [1]) of
           Left _  -> pure ()
           Right s -> assertBool ("expected unsat, got " ++ show s) False

  , testCase "no valid version: dependency range has no package version" $
      let r = reg
            [ ("root", [([1], [("a", geq [5])])])
            , ("a", [([1], [])])   -- only a@1 exists, but root needs >=5
            ]
      in case solve r "root" (v [1]) of
           Left _  -> pure ()
           Right s -> assertBool ("expected unsat, got " ++ show s) False
  ]
```

Add the missing import for the range constructors used above: at the top of `test/SolverSpec.hs` add

```haskell
import qualified Distribution.Version
```

(The qualified references `Distribution.Version.orLaterVersion` / `.earlierVersion` then resolve.)

- [ ] **Step 6: Run the full suite (human/CI gate)**

Run: `cabal test pubgrub-hs-test --test-show-details=direct`
Expected: every case PASSES — VersionSet properties, rule of resolution, trivial, transitive, backtracking, both unsat scenarios.

If a scenario fails, use `superpowers:systematic-debugging`: print the `SolveError`'s incompatibility and trace `unitPropagation`/`conflictResolution` against the reference semantics in `references/pubgrub/src/internal/`.

- [ ] **Step 7: Commit**

```bash
git add src/PubGrub/Solver.hs src/PubGrub.hs test/SolverSpec.hs
git commit -m "feat: solve loop with in-memory provider scenario tests"
```

---

## Task 10: Error reporting (derivation tree)

**Files:**
- Modify: `src/PubGrub/Solver.hs`
- Modify: `test/SolverSpec.hs`
- Read: `references/pubgrub/src/report.rs` (rendering style), intro doc §7

- [ ] **Step 1: Extend exports**

Add to the export list:

```haskell
  , reportConflict
```

- [ ] **Step 2: Append the reporter**

Append to `src/PubGrub/Solver.hs`:

```haskell
-- | Render an incompatibility (and its derivation, if any) as a human-readable
-- proof. Post-order over 'DerivedFrom'; leaves describe external facts.
-- Deduplication/line-numbering is intentionally omitted in this milestone.
reportConflict :: (Package p) => Incompatibility p -> String
reportConflict = render
  where
    render i = case incompCause i of
      DerivedFrom c1 c2 ->
        "Because " ++ render c1 ++ " and " ++ render c2
          ++ ", " ++ summary i ++ "."
      _ -> summary i

    summary i = case Map.toList (incompTerms i) of
      [] -> "version solving failed"
      [(p, Positive r)] -> show p ++ " " ++ showVS r ++ " is forbidden"
      [(p, Negative r)] -> show p ++ " " ++ showVS r ++ " is mandatory"
      [(p1, Positive r1), (p2, Negative r2)] -> dep p1 r1 p2 r2
      [(p2, Negative r2), (p1, Positive r1)] -> dep p1 r1 p2 r2
      terms -> intercalate ", " [ showTerm p t | (p, t) <- terms ] ++ " are incompatible"

    dep p1 r1 p2 r2 =
      show p1 ++ " " ++ showVS r1 ++ " depends on " ++ show p2 ++ " " ++ showVS r2
    showTerm p (Positive r) = show p ++ " " ++ showVS r
    showTerm p (Negative r) = show p ++ " not " ++ showVS r
    showVS = show . VS.intervals
```

Update the `Data.List` import to `import Data.List (foldl', maximumBy, intercalate)`. `intercalate` is total (unlike `foldr1`), satisfying the project's no-partial-functions rule.

- [ ] **Step 3: Typecheck offline**

Run: `ghc -fno-code -isrc -package Cabal-syntax -XGHC2021 src/PubGrub/Solver.hs`
Expected: compiles, no warnings.

- [ ] **Step 4: Assert the report mentions both conflicting requirements**

In `test/SolverSpec.hs`, change the "unsat: conflicting text requirements" case to inspect the message:

```haskell
  , testCase "unsat: conflicting text requirements (report mentions text)" $
      let r = reg
            [ ("root", [([1], [("aeson", geq [2,2]), ("servant", VS.full)])])
            , ("aeson", [([2,2], [("text", geq [2,0])])])
            , ("servant", [([0,20], [("text", VS.fromVersionRange (Distribution.Version.earlierVersion (mkVersion [2,0])))])])
            , ("text", [([2,0], []), ([1,2], [])])
            ]
      in case solve r "root" (v [1]) of
           Right s -> assertBool ("expected unsat, got " ++ show s) False
           Left (NoSolution i) ->
             let msg = reportConflict i
             in assertBool ("report should mention text: " ++ msg)
                  ("text" `isInfixOf` msg)
```

Change the `import Data.List (sortBy)` line in `test/SolverSpec.hs` to `import Data.List (sortBy, isInfixOf)`.

- [ ] **Step 5: Run the suite (human/CI gate)**

Run: `cabal test pubgrub-hs-test --test-show-details=direct`
Expected: all cases PASS, including the report-content assertion.

- [ ] **Step 6: Commit**

```bash
git add src/PubGrub/Solver.hs test/SolverSpec.hs
git commit -m "feat: derivation-tree conflict reporting"
```

---

## Task 11: Final integration check

**Files:**
- Read: all of `src/`

- [ ] **Step 1: Full build with warnings-as-information**

Run: `cabal build all`
Expected: library and test-suite compile with no `-Wall` warnings.

- [ ] **Step 2: Full test run (human/CI gate)**

Run: `cabal test pubgrub-hs-test --test-show-details=direct`
Expected: 100% pass.

- [ ] **Step 3: Confirm the public API is usable**

Run: `cabal repl pubgrub-hs` then in GHCi:

```haskell
:m + PubGrub Data.Map.Strict Distribution.Version
-- (Construct a tiny Registry inline or import SolverSpec helpers) and call `solve`.
```

Expected: `solve` is in scope and typechecks. (Optional smoke check.)

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "chore: integration verification for native solver milestone"
```

---

## Out of scope (next milestones)

- Wiring `solve` to the real Hackage index (`app/Database.hs`, `app/Main.hs`).
- ASP/Clingo cross-validation (`PubGrub/ASP.hs`).
- Cabal boolean flags / conditional dependencies.
- Watched-literals propagation; derivation-tree deduplication & line numbering.
- Incompatibility merging across adjacent versions (`merge_dependents`).
