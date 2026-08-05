# Solver Lattice Generalization — Implementation Plan (Phases 0–1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generalize the PubGrub core to work over an abstract Boolean/Heyting set
algebra (with `VersionSet` as the sole instance for now), so a later phase can add
`ChoiceSet` for installed-vs-source choices — without reimplementing conflict
learning.

**Architecture:** Add a small lattice hierarchy (`BoundedLattice`/`Heyting`/`Sets`)
to `PubGrub.Lattice`, plus a second primitive instance `Pow a` (finite/cofinite
sets). Then parameterize `PubGrub.Types`, `PubGrub.Solver`, and the
`DependencyProvider` class over a set type `s` with associated element type
`Elem s`, instantiating every existing caller at `s = VersionSet`
(`Elem VersionSet = Version`). Phase 1 is behavior-preserving: the existing 32-test
suite must pass unchanged, proving no regression.

**Tech Stack:** GHC 9.12 / GHC2021, Cabal-syntax (`Version`/`VersionRange`),
`containers`, `tasty`/`tasty-quickcheck`/`tasty-hunit`, `co-log`.

This plan covers **Phase 0 and Phase 1** of
`docs/superpowers/specs/2026-06-24-choice-lattice-design.md`. Phases 2–3 (the
`Choice`/`ChoiceSet` types and the `PackageDbProvider` split) get their own plan,
written against the post-refactor code once Phase 1 lands.

## Global Constraints

- GHC2021; `-Wall` is on for every component (`common warnings`). Treat new
  warnings as defects to fix before committing.
- No partial functions (`head`, `fromJust`, etc.) — pattern-match or use
  `Maybe`/`Either`.
- Do **not** add a dependency on the `lattices` package; we vendor the class
  definitions ourselves.
- Phase 1 changes **no behavior**: `cabal test` must report the same 32 passing
  tests, and conflict-report text must be byte-for-byte identical.
- **Precondition:** start from a clean, building tree at commit `b3b0645` (or
  later on `with-compiler-option`). There is uncommitted WIP in
  `app/HackageProvider.hs` (an early `PackageDbProvider`/`Toolchain` sketch) that
  does **not** compile; stash or set it aside before starting
  (`git stash push app/HackageProvider.hs`) and re-apply it during the Phase 2–3
  plan. Verify `cabal build && cabal test` is green before Task 1.
- Commit after every task. Commit-message trailer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure

- `src/PubGrub/Lattice.hs` (modify) — add `BoundedLattice`, `Heyting`, `Sets`
  classes; the `SetAlg` constraint synonym; helper functions `isBottom`/`isTop`/
  `subsetOf`/`disjoint`.
- `src/PubGrub/VersionSet.hs` (modify) — add `BoundedLattice`/`Heyting`/`Sets`
  instances for `VersionSet`.
- `src/PubGrub/Pow.hs` (create) — `Pow a` finite/cofinite set + instances.
- `src/PubGrub/Pretty.hs` (create) — `Pretty` rendering class + `Version`/
  `VersionSet` instances.
- `src/PubGrub/Types.hs` (modify) — parameterize `Term`/`IncompatCause`/
  `Incompatibility` and all functions over `s`.
- `src/PubGrub/Solver.hs` (modify) — parameterize `Assignment`/`PartialSolution`/
  `SolverMsg`/`SolveError`/`ReportEnv`/`DependencyProvider`/`solve` over `s`;
  convert reporting to `Pretty`.
- `app/Solver.hs`, `app/HackageProvider.hs` (modify) — instantiate at
  `s = VersionSet`.
- `test/LatticeSpec.hs`, `test/PowSpec.hs`, `test/PrettySpec.hs` (create) — new
  unit/property tests; `test/SolverSpec.hs` (modify) — update provider instance
  head; `test/Main.hs` and `pubgrub-hs.cabal` (modify) — register new modules.

---

## Phase 0 — Lattice abstraction + primitives

### Task 1: Lattice/set classes and the `VersionSet` instance

**Files:**
- Modify: `src/PubGrub/Lattice.hs`
- Modify: `src/PubGrub/VersionSet.hs`
- Create: `test/LatticeSpec.hs`
- Modify: `test/Main.hs`, `pubgrub-hs.cabal`

**Interfaces:**
- Produces:
  - `class Lattice a => BoundedLattice a where bottom, top :: a`
  - `class BoundedLattice a => Heyting a where neg :: a -> a; (==>) :: a -> a -> a` (default `a ==> b = neg a \/ b`)
  - `class Heyting a => Sets a where type Elem a; singleton :: Elem a -> a; member :: Elem a -> a -> Bool`
  - `type SetAlg s = (Eq s, Sets s)` (ConstraintKinds)
  - `isBottom, isTop :: (Eq a, BoundedLattice a) => a -> Bool`
  - `subsetOf, disjoint :: (Eq a, Heyting a) => a -> a -> Bool`
  - instances `BoundedLattice VersionSet`, `Heyting VersionSet`, `Sets VersionSet` with `Elem VersionSet = Version`.

- [ ] **Step 1: Write the failing test**

Create `test/LatticeSpec.hs`:

```haskell
{-# LANGUAGE ScopedTypeVariables #-}

module LatticeSpec (tests) where

import Distribution.Version (Version, mkVersion)
import PubGrub.Lattice
import PubGrub.VersionSet (VersionSet)
import PubGrub.VersionSet qualified as VS
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

v :: [Int] -> Version
v = mkVersion

tests :: TestTree
tests =
  testGroup
    "Lattice"
    [ testCase "bottom is the empty version set" $
        (bottom :: VersionSet) @?= VS.empty
    , testCase "top is the full version set" $
        (top :: VersionSet) @?= VS.full
    , testCase "neg agrees with VS.complement" $
        neg (VS.singleton (v [1])) @?= VS.complement (VS.singleton (v [1]))
    , testCase "join agrees with VS.union" $
        (VS.singleton (v [1]) \/ VS.singleton (v [2]))
          @?= VS.union (VS.singleton (v [1])) (VS.singleton (v [2]))
    , testCase "meet agrees with VS.intersection" $
        (VS.full /\ VS.singleton (v [1])) @?= VS.singleton (v [1])
    , testCase "singleton agrees with VS.singleton" $
        (singleton (v [1]) :: VersionSet) @?= VS.singleton (v [1])
    , testCase "member agrees with VS.contains" $
        member (v [1]) (VS.singleton (v [1])) @?= True
    , testCase "member false outside the set" $
        member (v [2]) (VS.singleton (v [1])) @?= False
    , testCase "isBottom of empty" $ isBottom (VS.empty :: VersionSet) @?= True
    , testCase "isTop of full" $ isTop (VS.full :: VersionSet) @?= True
    , testCase "subsetOf: singleton in full" $
        subsetOf (VS.singleton (v [1])) (VS.full :: VersionSet) @?= True
    , testCase "disjoint singletons" $
        disjoint (VS.singleton (v [1])) (VS.singleton (v [2]) :: VersionSet) @?= True
    ]
```

- [ ] **Step 2: Register the test module and run to verify it fails**

In `pubgrub-hs.cabal`, add `LatticeSpec` to the test-suite `other-modules`. In
`test/Main.hs`, add `import LatticeSpec qualified` and add `LatticeSpec.tests` to
the `testGroup "pubgrub-hs"` list.

Run: `cabal test 2>&1 | tail -20`
Expected: FAIL — compile error, `Not in scope: bottom / top / neg / singleton / member / isBottom / …`.

- [ ] **Step 3: Add the classes and helpers to `PubGrub.Lattice`**

At the top of `src/PubGrub/Lattice.hs` add the pragmas:

```haskell
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ConstraintKinds #-}
```

Change the module header to export the new names (keep the existing exports):

```haskell
module PubGrub.Lattice
  ( Lattice (..)
  , joinLeq
  , meetLeq
  , BoundedLattice (..)
  , Heyting (..)
  , Sets (..)
  , SetAlg
  , isBottom
  , isTop
  , subsetOf
  , disjoint
  ) where
```

Append below the existing `Lattice` class and `joinLeq`/`meetLeq`:

```haskell
-- | A bounded lattice: least ('bottom') and greatest ('top') elements.
class Lattice a => BoundedLattice a where
    bottom :: a
    top :: a

-- | A Heyting algebra adds negation. Our instances are in fact Boolean
-- (@a \/ neg a == top@), so '==>' has a Boolean default and instances need only
-- define 'neg'. (The @lattices@ package takes '==>' as primary; we deviate
-- because the solver only ever uses 'neg'.)
class BoundedLattice a => Heyting a where
    neg :: a -> a
    (==>) :: a -> a -> a
    a ==> b = neg a \/ b

-- | A set type linked to its elements. (pubgrub-rs bundles this into its
-- VersionSet trait; we keep membership separate from the lattice structure.)
class Heyting a => Sets a where
    type Elem a
    singleton :: Elem a -> a
    member :: Elem a -> a -> Bool

-- | The constraint a generic set type must satisfy to drive the solver.
type SetAlg s = (Eq s, Sets s)

isBottom :: (Eq a, BoundedLattice a) => a -> Bool
isBottom = (== bottom)

isTop :: (Eq a, BoundedLattice a) => a -> Bool
isTop = (== top)

-- | @a `subsetOf` b@ iff @a /\ neg b == bottom@.
subsetOf :: (Eq a, Heyting a) => a -> a -> Bool
subsetOf a b = isBottom (a /\ neg b)

-- | Two elements are disjoint iff their meet is 'bottom'.
disjoint :: (Eq a, Heyting a) => a -> a -> Bool
disjoint a b = isBottom (a /\ b)
```

- [ ] **Step 4: Add the `VersionSet` instances**

In `src/PubGrub/VersionSet.hs`, add the pragma `{-# LANGUAGE TypeFamilies #-}` at
the top, and change the `PubGrub.Lattice` import to bring in the new classes:

```haskell
import PubGrub.Lattice (Lattice (..), BoundedLattice (..), Heyting (..), Sets (..))
```

Replace the existing `instance Lattice VersionSet` block at the bottom with:

```haskell
instance Lattice VersionSet where
    (\/) = union
    (/\) = intersection

instance BoundedLattice VersionSet where
    bottom = empty
    top = full

instance Heyting VersionSet where
    neg = complement

instance Sets VersionSet where
    type Elem VersionSet = Version
    singleton = fromVersionRange . thisVersion
    member = flip contains
```

(`thisVersion` and `fromVersionRange` are already imported/defined in this module;
inlining `singleton`'s body avoids a name clash with the existing exported
`singleton` function, which stays as-is.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `cabal test 2>&1 | tail -25`
Expected: PASS — the new `Lattice` group passes and all previously-passing tests
remain green (33+ tests total).

- [ ] **Step 6: Commit**

```bash
git add src/PubGrub/Lattice.hs src/PubGrub/VersionSet.hs test/LatticeSpec.hs test/Main.hs pubgrub-hs.cabal
git commit -m "feat: lattice/set class hierarchy with VersionSet instance

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `Pow a` — finite/cofinite sets (second primitive instance)

**Files:**
- Create: `src/PubGrub/Pow.hs`
- Create: `test/PowSpec.hs`
- Modify: `test/Main.hs`, `pubgrub-hs.cabal`

**Interfaces:**
- Consumes: classes from Task 1.
- Produces: `data Pow a = Incl (Set a) | Excl (Set a)` with `Eq`/`Show`, instances
  `Lattice`/`BoundedLattice`/`Heyting`/`Sets` (`Elem (Pow a) = a`, requires
  `Ord a`).

- [ ] **Step 1: Write the failing test**

Create `test/PowSpec.hs`:

```haskell
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module PowSpec (tests) where

import Data.Set qualified as Set
import PubGrub.Lattice
import PubGrub.Pow (Pow (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.QuickCheck (Arbitrary (..), Gen, elements, listOf, testProperty, (===))

-- Small domain so cofinite sets are exercised.
genElem :: Gen Int
genElem = elements [0 .. 5]

instance Arbitrary (Pow Int) where
    arbitrary = do
        wrap <- elements [Incl, Excl]
        xs <- listOf genElem
        pure (wrap (Set.fromList xs))

-- Reference membership over the test domain {0..5}.
ref :: Pow Int -> Set.Set Int
ref p = Set.fromList [x | x <- [0 .. 5], member x p]

tests :: TestTree
tests =
    testGroup
        "Pow"
        [ testProperty "neg is involutive" $ \(p :: Pow Int) ->
            ref (neg (neg p)) === ref p
        , testProperty "neg complements membership" $ \(p :: Pow Int) ->
            ref (neg p) === Set.difference (Set.fromList [0 .. 5]) (ref p)
        , testProperty "join is union of membership" $ \(a :: Pow Int) b ->
            ref (a \/ b) === Set.union (ref a) (ref b)
        , testProperty "meet is intersection of membership" $ \(a :: Pow Int) b ->
            ref (a /\ b) === Set.intersection (ref a) (ref b)
        , testProperty "bottom is empty" $
            ref (bottom :: Pow Int) === Set.empty
        , testProperty "top is the whole domain" $
            ref (top :: Pow Int) === Set.fromList [0 .. 5]
        , testProperty "member of singleton" $ \(x :: Int) ->
            member x (singleton x :: Pow Int) === True
        , testProperty "isBottom iff empty membership" $ \(p :: Pow Int) ->
            isBottom p === Set.null (ref p)
        ]
```

- [ ] **Step 2: Register and run to verify it fails**

In `pubgrub-hs.cabal`: add `PubGrub.Pow` to the **library** `exposed-modules`, and
add `PowSpec` to the test-suite `other-modules`. In `test/Main.hs`: add
`import PowSpec qualified` and `PowSpec.tests` to the list.

Run: `cabal test 2>&1 | tail -20`
Expected: FAIL — `Could not find module 'PubGrub.Pow'`.

- [ ] **Step 3: Implement `PubGrub.Pow`**

Create `src/PubGrub/Pow.hs`:

```haskell
{-# LANGUAGE TypeFamilies #-}

-- | Subsets of an unordered domain, represented so complement needs no universe:
-- either a finite included set or the complement of a finite set. This is the
-- Boolean algebra used for the installed world (keyed by UnitId).
module PubGrub.Pow (Pow (..)) where

import Data.Set (Set)
import Data.Set qualified as Set
import PubGrub.Lattice

data Pow a = Incl (Set a) | Excl (Set a)
    deriving stock (Eq, Show)

instance Ord a => Lattice (Pow a) where
    Incl a \/ Incl b = Incl (Set.union a b)
    Incl a \/ Excl b = Excl (Set.difference b a)
    Excl a \/ Incl b = Excl (Set.difference a b)
    Excl a \/ Excl b = Excl (Set.intersection a b)

    Incl a /\ Incl b = Incl (Set.intersection a b)
    Incl a /\ Excl b = Incl (Set.difference a b)
    Excl a /\ Incl b = Incl (Set.difference b a)
    Excl a /\ Excl b = Excl (Set.union a b)

instance Ord a => BoundedLattice (Pow a) where
    bottom = Incl Set.empty
    top = Excl Set.empty

instance Ord a => Heyting (Pow a) where
    neg (Incl s) = Excl s
    neg (Excl s) = Incl s

instance Ord a => Sets (Pow a) where
    type Elem (Pow a) = a
    singleton = Incl . Set.singleton
    member x (Incl s) = Set.member x s
    member x (Excl s) = not (Set.member x s)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cabal test 2>&1 | tail -25`
Expected: PASS — the `Pow` property group passes; all other tests remain green.

- [ ] **Step 5: Commit**

```bash
git add src/PubGrub/Pow.hs test/PowSpec.hs test/Main.hs pubgrub-hs.cabal
git commit -m "feat: Pow finite/cofinite set as a second Sets instance

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase 1 — Parameterize the core over the set type

### Task 3: `Pretty` rendering class

**Files:**
- Create: `src/PubGrub/Pretty.hs`
- Create: `test/PrettySpec.hs`
- Modify: `test/Main.hs`, `pubgrub-hs.cabal`

**Interfaces:**
- Produces: `class Pretty a where pretty :: a -> Text`; instances `Pretty Version`
  and `Pretty VersionSet`. These reproduce the current `prettyVer`/`prettyVS`
  output exactly.

- [ ] **Step 1: Write the failing test**

Create `test/PrettySpec.hs`:

```haskell
module PrettySpec (tests) where

import Distribution.Version (mkVersion, orLaterVersion)
import PubGrub.Pretty (pretty)
import PubGrub.VersionSet qualified as VS
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "Pretty"
        [ testCase "version" $ pretty (mkVersion [1, 2]) @?= "1.2"
        , testCase "singleton set" $ pretty (VS.singleton (mkVersion [1])) @?= "==1"
        , testCase "lower-bounded set" $
            pretty (VS.fromVersionRange (orLaterVersion (mkVersion [1]))) @?= ">=1"
        ]
```

- [ ] **Step 2: Register and run to verify it fails**

In `pubgrub-hs.cabal`: add `PubGrub.Pretty` to the **library** `exposed-modules`,
and `PrettySpec` to the test-suite `other-modules`. In `test/Main.hs`: add
`import PrettySpec qualified` and `PrettySpec.tests` to the list.

Run: `cabal test 2>&1 | tail -20`
Expected: FAIL — `Could not find module 'PubGrub.Pretty'`.

- [ ] **Step 3: Implement `PubGrub.Pretty`**

Create `src/PubGrub/Pretty.hs`:

```haskell
-- | Lightweight rendering to 'Text' for conflict reports. Distinct from Cabal's
-- 'Distribution.Pretty.Pretty' (which targets 'Doc'/'String'). 'Package' keeps
-- its own 'prettyPackage' for the package type.
module PubGrub.Pretty (Pretty (..)) where

import Data.Text (Text)
import Data.Text qualified as T
import Distribution.Pretty (prettyShow)
import Distribution.Version (Version)
import PubGrub.VersionSet (VersionSet)
import PubGrub.VersionSet qualified as VS

class Pretty a where
    pretty :: a -> Text

instance Pretty Version where
    pretty = T.pack . prettyShow

instance Pretty VersionSet where
    pretty = T.pack . prettyShow . VS.toVersionRange
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cabal test 2>&1 | tail -20`
Expected: PASS — `Pretty` group passes; all others green.

- [ ] **Step 5: Commit**

```bash
git add src/PubGrub/Pretty.hs test/PrettySpec.hs test/Main.hs pubgrub-hs.cabal
git commit -m "feat: Pretty rendering class for Version and VersionSet

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Parameterize `Types`, `Solver`, and `DependencyProvider` over `s`

This is one atomic refactor: the set type threads through `Term`, the
incompatibility types, the partial solution, the provider class, `solve`, and
reporting, so the project only type-checks once every file is updated. The test
cycle is the full suite at the end — it must stay byte-for-byte green (no behavior
change). Instantiate every existing caller at `s = VersionSet`,
`Elem VersionSet = Version`.

**Files:**
- Modify: `src/PubGrub/Types.hs`
- Modify: `src/PubGrub/Solver.hs`
- Modify: `app/Solver.hs`
- Modify: `app/HackageProvider.hs`
- Modify: `test/SolverSpec.hs`

**Interfaces:**
- Consumes: `Sets`/`Heyting`/`BoundedLattice`/`SetAlg`/`isBottom`/`isTop`/
  `subsetOf`/`disjoint` (Task 1); `Pretty` (Task 3).
- Produces (the new generic surface later phases build on):
  - `data Term s = Positive s | Negative s`
  - `data IncompatCause p s` with `NotRoot p (Elem s) | NoVersions p s | FromDependencyOf p s p s | DerivedFrom (Incompatibility p s) (Incompatibility p s)`
  - `data Incompatibility p s = Incompatibility { incompTerms :: Map p (Term s), incompCause :: IncompatCause p s }`
  - `class (Package p, Monad m) => DependencyProvider dp p s m | dp -> p s where expand :: dp -> p -> s -> m (Maybe (Elem s, Map p s))`
  - `data Assignment p s` with `Decision { aIndex, aLevel :: !Int, aPackage :: p, aChoice :: Elem s }` and `Derivation { …, aTerm :: Term s, aCause :: Incompatibility p s }`
  - `data PartialSolution p s`; `extractSolution :: Ord p => PartialSolution p s -> Map p (Elem s)`
  - `data SolverMsg p s = Deciding p s | Chose p (Elem s) | NoVersionFor p s | Conflict (Incompatibility p s) | Backtracked Int`
  - `newtype SolveError p s = NoSolution (Incompatibility p s)`
  - `data ReportEnv p s = ReportEnv { rePinned :: p -> Maybe (Elem s), reIsRoot :: p -> Bool }`
  - `solve :: (DependencyProvider dp p s m, SetAlg s, WithLog env (SolverMsg p s) m) => dp -> p -> Elem s -> m (Either (SolveError p s) (Map p (Elem s)))`
  - `reportConflictWith :: (Package p, Pretty s, Pretty (Elem s)) => ReportEnv p s -> Incompatibility p s -> Text`

**Mechanical substitution rule** (apply throughout `Types.hs` and `Solver.hs`
bodies; the explicit signatures below tell you the constraints to add):

| current | replacement |
|---|---|
| `VersionSet` (as a type) | `s` |
| `Version` (the chosen element) | `Elem s` |
| `VS.empty` | `bottom` |
| `VS.full` | `top` |
| `VS.complement` | `neg` |
| `VS.union` | `(\/)` |
| `VS.intersection` | `(/\)` |
| `VS.singleton` | `singleton` |
| `VS.contains s v` | `member v s` |
| `VS.isEmpty` | `isBottom` |
| `VS.isFull` | `isTop` |
| `VS.subsetOf` | `subsetOf` |
| `VS.isDisjoint` | `disjoint` |

- [ ] **Step 1: Parameterize `PubGrub.Types`**

Add pragmas at the top of `src/PubGrub/Types.hs`:

```haskell
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
```

Replace the `PubGrub.VersionSet` imports with the lattice abstraction:

```haskell
import PubGrub.Lattice
```

(Drop `import Distribution.Version (Version)` and the `PubGrub.VersionSet`
imports; `Version`/`VersionSet` no longer appear in this module.)

Apply the substitution rule and set these exact signatures/definitions. The
function **bodies** are unchanged except via the substitution table.

```haskell
data Term s = Positive s | Negative s
    deriving stock (Eq, Show)

anyTerm :: BoundedLattice s => Term s
anyTerm = Negative bottom

emptyTerm :: BoundedLattice s => Term s
emptyTerm = Positive bottom

exactTerm :: Sets s => Elem s -> Term s
exactTerm = Positive . singleton

-- isPositive, negateTerm: unchanged bodies; signatures become Term s -> …
isPositive :: Term s -> Bool
negateTerm :: Term s -> Term s

termContains :: Sets s => Term s -> Elem s -> Bool
-- (Positive s) v = member v s ; (Negative s) v = not (member v s)

intersectTerms :: Heyting s => Term s -> Term s -> Term s
unionTerms     :: Heyting s => Term s -> Term s -> Term s

termSubsetOf   :: (Eq s, Heyting s) => Term s -> Term s -> Bool
termIsDisjoint :: (Eq s, Heyting s) => Term s -> Term s -> Bool
termIsEmpty    :: (Eq s, BoundedLattice s) => Term s -> Bool
-- termIsEmpty (Positive x) = isBottom x ; (Negative x) = isTop x

relationWith :: (Eq s, Heyting s) => Term s -> Term s -> TermRelation
-- (TermRelation type unchanged)

data IncompatCause p s
    = NotRoot p (Elem s)
    | NoVersions p s
    | FromDependencyOf p s p s
    | DerivedFrom (Incompatibility p s) (Incompatibility p s)

data Incompatibility p s = Incompatibility
    { incompTerms :: Map p (Term s)
    , incompCause :: IncompatCause p s
    }

deriving stock instance (Eq p, Eq s, Eq (Elem s)) => Eq (IncompatCause p s)
deriving stock instance (Show p, Show s, Show (Elem s)) => Show (IncompatCause p s)
deriving stock instance (Eq p, Eq s, Eq (Elem s)) => Eq (Incompatibility p s)
deriving stock instance (Show p, Show s, Show (Elem s)) => Show (Incompatibility p s)

notRoot :: Sets s => p -> Elem s -> Incompatibility p s
-- body: Negative (singleton v); cause NotRoot p v

noVersions :: p -> s -> Incompatibility p s
-- body unchanged (Positive s)

fromDependency :: (Ord p, Eq s, BoundedLattice s) => p -> s -> (p, s) -> Incompatibility p s
-- body: replace VS.isEmpty depSet with isBottom depSet

incompGet :: Ord p => p -> Incompatibility p s -> Maybe (Term s)

incompRelation :: (Ord p, Eq s, Heyting s) => (p -> Maybe (Term s)) -> Incompatibility p s -> IncompatRelation p
-- (IncompatRelation p type unchanged)

isTerminal :: (Ord p, Sets s) => p -> Elem s -> Incompatibility p s -> Bool

priorCause :: (Ord p, Eq s, Heyting s) => Incompatibility p s -> Incompatibility p s -> p -> Incompatibility p s
```

Update the module export list: it stays the same name-wise (all the same
identifiers are exported); only the types gained parameters, which needs no export
change.

- [ ] **Step 2: Parameterize `PubGrub.Solver`**

Add pragmas to `src/PubGrub/Solver.hs` (keep existing ones, add):

```haskell
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
```

Add imports:

```haskell
import PubGrub.Lattice
import PubGrub.Pretty (Pretty (..))
```

Remove the now-unused concrete render helpers `prettyVer`/`prettyVS` and the
`Distribution.Pretty`/`PubGrub.VersionSet` imports they needed (the report now
uses `pretty`).

Apply the substitution rule and set these exact definitions/signatures:

```haskell
class (Package p, Monad m) => DependencyProvider dp p s m | dp -> p s where
    expand :: dp -> p -> s -> m (Maybe (Elem s, Map p s))

data Assignment p s
    = Decision  { aIndex :: !Int, aLevel :: !Int, aPackage :: p, aChoice :: Elem s }
    | Derivation { aIndex :: !Int, aLevel :: !Int, aPackage :: p, aTerm :: Term s, aCause :: Incompatibility p s }

deriving stock instance (Show p, Show s, Show (Elem s)) => Show (Assignment p s)

assignmentTerm :: Sets s => Assignment p s -> Term s
-- Decision {aChoice} = exactTerm aChoice ; Derivation {aTerm} = aTerm

data PartialSolution p s = PartialSolution
    { psAssignments :: [Assignment p s], psLevel :: !Int, psNextIndex :: !Int }

deriving stock instance (Show p, Show s, Show (Elem s)) => Show (PartialSolution p s)

emptyPS :: PartialSolution p s

addDecision :: p -> Elem s -> PartialSolution p s -> PartialSolution p s
-- constructs Decision … with the new field name aChoice

addDerivation :: (Ord p, BoundedLattice s) => p -> Incompatibility p s -> PartialSolution p s -> PartialSolution p s

backtrack :: Int -> PartialSolution p s -> PartialSolution p s

termIntersectionForPackage :: (Ord p, Heyting s) => PartialSolution p s -> p -> Maybe (Term s)

relation :: (Ord p, Eq s, Heyting s) => PartialSolution p s -> Incompatibility p s -> IncompatRelation p

extractSolution :: Ord p => PartialSolution p s -> Map p (Elem s)
-- body: use aChoice instead of aVersion

undecidedPositive :: (Ord p, Heyting s) => PartialSolution p s -> [(p, s)]

packageHistory :: Ord p => PartialSolution p s -> p -> [Assignment p s]

satisfierOf :: (Ord p, SetAlg s) => PartialSolution p s -> p -> Term s -> Assignment p s

data SatisfierSearch p s
    = DifferentDecisionLevels !Int
    | SameDecisionLevels (Incompatibility p s)

satisfierSearch :: (Ord p, SetAlg s) => PartialSolution p s -> Incompatibility p s -> (p, SatisfierSearch p s)

conflictResolution :: (Ord p, SetAlg s) => p -> Elem s -> Incompatibility p s -> PartialSolution p s
                   -> Either (Incompatibility p s) (p, Incompatibility p s, PartialSolution p s)

unitPropagation :: forall p s env m. (Ord p, SetAlg s, WithLog env (SolverMsg p s) m)
                => p -> Elem s -> [Incompatibility p s] -> PartialSolution p s
                -> m (Either (Incompatibility p s) ([Incompatibility p s], PartialSolution p s))

newtype SolveError p s = NoSolution (Incompatibility p s)
deriving stock instance (Eq p, Eq s, Eq (Elem s)) => Eq (SolveError p s)
deriving stock instance (Show p, Show s, Show (Elem s)) => Show (SolveError p s)

data SolverMsg p s
    = Deciding p s
    | Chose p (Elem s)
    | NoVersionFor p s
    | Conflict (Incompatibility p s)
    | Backtracked Int
deriving stock instance (Eq p, Eq s, Eq (Elem s)) => Eq (SolverMsg p s)
deriving stock instance (Show p, Show s, Show (Elem s)) => Show (SolverMsg p s)

solve :: (DependencyProvider dp p s m, SetAlg s, WithLog env (SolverMsg p s) m)
      => dp -> p -> Elem s -> m (Either (SolveError p s) (Map p (Elem s)))
```

In the `solve` body, the line `go (depIncs ++ incompats') (addDecision p v ps')`
and the `Just (v, deps)` binding are unchanged (the substitution makes `v :: Elem s`).

- [ ] **Step 3: Convert reporting to `Pretty` + generic `ReportEnv`**

Replace the `ReportEnv` record, `defaultReportEnv`, `reportConflict`, and
`reportConflictWith` with the generic versions. `rePinned` is the faithful
generalization of `rePinnedVersion` (richer text annotations arrive with `Choice`
in the Phase 2–3 plan). Bodies are unchanged except `prettyVer v → pretty v`,
`prettyVS s → pretty s`, and `rePinnedVersion → rePinned`:

```haskell
data ReportEnv p s = ReportEnv
    { rePinned :: p -> Maybe (Elem s)
    , reIsRoot :: p -> Bool
    }

defaultReportEnv :: ReportEnv p s
defaultReportEnv = ReportEnv {rePinned = const Nothing, reIsRoot = const False}

reportConflict :: (Package p, Pretty s, Pretty (Elem s)) => Incompatibility p s -> Text
reportConflict = reportConflictWith defaultReportEnv

reportConflictWith :: forall p s. (Package p, Pretty s, Pretty (Elem s))
                   => ReportEnv p s -> Incompatibility p s -> Text
-- body unchanged except:
--   in `leaf`, the NoVersions branch: `rePinnedVersion env p` -> `rePinned env p`,
--     `prettyVer v` -> `pretty v`, `prettyVS s` -> `pretty s`
--   in `summary`/`dep`/`showTerm`: every `prettyVS r` -> `pretty r`
```

Delete the `prettyVer`/`prettyVS` definitions at the bottom of the module.

- [ ] **Step 4: Update `app/HackageProvider.hs` (instantiate at `VersionSet`)**

Change only the instance head to fix `s = VersionSet`; the body is already in the
right shape (`expand` returns `(Version, Map Pkg VersionSet)`):

```haskell
instance (MonadIO m) => DependencyProvider HackageProvider Pkg VersionSet m where
  expand :: (MonadIO m) => HackageProvider -> Pkg -> VersionSet -> m (Maybe (Version, Map Pkg VersionSet))
  expand hp pkg range = …  -- unchanged
```

- [ ] **Step 5: Update `app/Solver.hs` (instantiate at `VersionSet`)**

Two changes:

1. `renderSolverMsg :: SolverMsg Pkg -> Text` → `renderSolverMsg :: SolverMsg Pkg VersionSet -> Text` (the constructors and body are unchanged).
2. In `runSolve`, rename the `ReportEnv` field `rePinnedVersion` to `rePinned`:

```haskell
      let env =
            ReportEnv
              { rePinned = \case
                  Pkg n -> Map.lookup n (hpBoot hp)
                  Root -> Nothing,
                reIsRoot = \case
                  Root -> True
                  _ -> False
              }
```

- [ ] **Step 6: Update `test/SolverSpec.hs` (instantiate at `VersionSet`)**

1. Provider instance head:

```haskell
instance Monad m => DependencyProvider Registry String VersionSet m where
    expand (Registry regMap) p range = …  -- unchanged body
```

2. The two `SolverMsg String` type annotations become `SolverMsg String VersionSet`
   (lines defining `noLog` and the `newIORef ([] :: [SolverMsg String])` refs).

The direct `Incompatibility { … }` constructions and `reportConflict`/`solve`
calls need no change — `s = VersionSet` is inferred.

- [ ] **Step 7: Build and verify no warnings**

Run: `cabal build 2>&1 | grep -iE "warning|error" | head -40`
Expected: no output (clean `-Wall` build). Fix any unused-import warnings left by
the removed `VS`/`Distribution.Pretty` imports.

- [ ] **Step 8: Run the full suite — must be unchanged**

Run: `cabal test 2>&1 | tail -30`
Expected: PASS — all Solver/Flatten/Boot/Compiler tests green and the conflict-
report tests ("report mentions text") still pass, proving identical behavior, plus
the Phase 0/Task 3 groups (Lattice, Pow, Pretty).

- [ ] **Step 9: Commit**

```bash
git add src/PubGrub/Types.hs src/PubGrub/Solver.hs app/Solver.hs app/HackageProvider.hs test/SolverSpec.hs
git commit -m "refactor: parameterise solver core over an abstract set type

Generalise Term/Incompatibility/PartialSolution/DependencyProvider/solve and
reporting over a set type s with Elem s, with VersionSet as the sole instance
(Elem = Version). Behaviour-preserving: the full suite passes unchanged.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage (Phases 0–1):**
- Lattice hierarchy `BoundedLattice`/`Heyting`/`Sets` stolen from `lattices`, no
  dependency — Task 1. ✓
- `VersionSet` instance, named API kept — Task 1. ✓
- `Pow a` second primitive instance — Task 2. ✓
- `Pretty` class for `s`/`Elem s` — Task 3. ✓
- Parameterize `Types`/`Solver`/`DependencyProvider` over `s`; `VersionSet` the
  only instance; behavior-preserving — Task 4. ✓
- Reporting genericity via `Pretty` + generalized `ReportEnv` — Task 4 (Step 3).
  The richer text-annotation API (`reAnnotate`) is intentionally deferred to the
  Phase 2–3 plan, where `Choice` provenance gives it content; Phase 1 keeps the
  faithful `rePinned :: p -> Maybe (Elem s)` so report output is identical. ✓
- Phases 2–3 (`Choice`/`ChoiceSet`, `PackageDbProvider`/`Toolchain`, combined
  provider) — **not** in this plan; deferred to a follow-up plan against the
  post-refactor code. (Noted up front.)

**Placeholder scan:** No TBD/TODO; every code step shows concrete code, signatures,
or an exact substitution rule. Function bodies governed by the substitution table
are stated as such rather than left vague.

**Type consistency:** `expand`/`solve`/`Assignment.aChoice`/`extractSolution`/
`ReportEnv.rePinned`/`SolverMsg p s` names and signatures match across the
Interfaces blocks and the Task 4 definitions. The renamed field `aVersion →
aChoice` is applied in `assignmentTerm`, `addDecision`, and `extractSolution`
consistently.
