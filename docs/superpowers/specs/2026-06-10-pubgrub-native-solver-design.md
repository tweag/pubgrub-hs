# PubGrub Native Solver — First Implementation Design

**Date:** 2026-06-10
**Status:** Approved (pending spec review)
**Scope:** Native PubGrub solver loop, validated end-to-end against an in-memory `DependencyProvider`. No Hackage wiring, no ASP encoder this round.

This design refines the roadmap in `docs/pubgrub-intro.md` into a concrete first
milestone. Where this document and the intro doc differ, this document wins; where
it is silent, the intro doc (especially §3–§7) is the reference.

---

## 1. Goal & non-goals

**Goal.** A working native CDNL solver: given a root package and an in-memory
oracle of dependencies, return either a `Map p Version` solution or a `SolveError`
carrying a renderable derivation tree. Proven correct by QuickCheck properties on
version-set arithmetic and by hand-written solver scenarios with known outcomes.

**Non-goals (deferred to later milestones):**

- Real Hackage index wiring (`app/Database.hs`, `app/Main.hs` stay untouched).
- The ASP / Clingo cross-validation encoder (`PubGrub/ASP.hs`).
- Cabal boolean flags / conditional dependencies (treat deps as unconditional).
- Watched-literals optimisation in unit propagation.
- Derivation-tree deduplication / line-numbering in error output (only if trivial).

---

## 2. Module layout

Follow the intro doc's module map. The current flat `src/PubGrub.hs` becomes a
thin re-export module.

```
src/PubGrub.hs              -- top-level re-export: solve, SolveError, core types, VersionSet
src/PubGrub/VersionSet.hs   -- normalized interval type + arithmetic + Lattice instance
src/PubGrub/Types.hs        -- Package, DependencyProvider classes;
                               Term, Incompatibility, IncompatCause, Assignment, PartialSolution;
                               satisfies, intersectTerms, relation, smart constructors
src/PubGrub/Solver.hs       -- unitPropagate, conflictResolution, decideNext, solve, Reporter
test/                       -- QuickCheck props + solver scenarios (in-memory provider)
```

The existing `src/PubGrub/Lattice.hs` is kept as the home for the `Lattice` class;
its absorption/associativity/commutativity laws become QuickCheck properties for the
`VersionSet` instance (rather than living as an unused, untested module).

**Cabal changes (`pubgrub-hs.cabal`):**

- `library`: add `exposed-modules` `PubGrub.VersionSet`, `PubGrub.Types`,
  `PubGrub.Solver`; keep `PubGrub` exposed; add `text` to `build-depends`.
- New `test-suite` stanza (`exitcode-stdio-1.0`, `hs-source-dirs: test`) depending
  on `pubgrub-hs`, `QuickCheck`, `tasty`/`tasty-quickcheck` (or `hspec` — chosen at
  plan time; default `tasty` + `tasty-quickcheck` + `tasty-hunit`), `containers`,
  `Cabal-syntax`.
- `app/` stanza unchanged.

---

## 3. VersionSet — the foundation

```haskell
newtype VersionSet = VersionSet [Interval]   -- sorted, disjoint, non-adjacent
data Interval = Interval Version (Maybe Version)  -- half-open [lo, hi); hi = Nothing => unbounded
```

**Canonical-form invariant:** intervals are sorted ascending by `lo`, pairwise
disjoint, and non-adjacent (no two intervals that could merge into one). This makes
structural `Eq` coincide with semantic equality — the property the conflict-resolution
loop depends on. All smart constructors and operations preserve this invariant.

**Operations:**

```haskell
empty        :: VersionSet                       -- []
full         :: VersionSet                       -- [Interval v0 Nothing] where v0 = mkVersion [0]
singleton    :: Version -> VersionSet            -- [Interval v (Just (nextVersion v))]
complement   :: VersionSet -> VersionSet
union        :: VersionSet -> VersionSet -> VersionSet
intersection :: VersionSet -> VersionSet -> VersionSet
contains     :: VersionSet -> Version -> Bool
```

- `nextVersion v` appends a `0`-component bumped minimally so that `[v, nextVersion v)`
  contains exactly `v` and no other Cabal `Version`. Cabal versions are lists of
  `Int` with trailing zeros normalised; the successor is `v` with an extra component
  that no real version can fall between. (Exact encoding settled in the plan; the
  contract is: `singleton v` contains `v` and nothing else.)
- `union`/`intersection`/`complement` operate by merging the sorted interval lists in
  one pass, re-establishing the canonical invariant.
- `Lattice` instance: `(\/) = union`, `(/\) = intersection`.

**Boundary conversion.** A `fromVersionRange :: VersionRange -> VersionSet` honours
PVP `^>=` semantics once, when reading dependency constraints. The solver only ever
manipulates canonical `VersionSet`s, never raw `VersionRange`. (For this milestone the
in-memory fixture can build `VersionSet`s directly; `fromVersionRange` is provided for
the eventual Hackage path and is independently testable.)

---

## 4. Core types

Per intro doc §3–§5.

```haskell
class (Eq p, Ord p, Show p) => Package p

class Package p => DependencyProvider dp p where
  chooseVersion   :: dp -> p -> VersionSet -> Maybe Version
  getDependencies :: dp -> p -> Version -> Map p VersionSet

data Term = Positive VersionSet | Negative VersionSet
  deriving (Eq, Show)

data IncompatCause p
  = RootCause
  | DependencyCause
  | Derived (Incompatibility p) (Incompatibility p)

data Incompatibility p = Incompatibility
  { terms :: Map p Term
  , cause :: IncompatCause p
  }

data Assignment p
  = Decision   { pkg :: p, version :: Version, decisionLevel :: Int }
  | Derivation { pkg :: p, term :: Term, cause :: Incompatibility p }

newtype PartialSolution p = PartialSolution { assignments :: [Assignment p] }  -- oldest first
```

`VersionSet` is concrete (not a class parameter) since we settled on one
representation; this simplifies every signature relative to the intro doc's `vs`
type variable.

**Helpers implemented here:**

- `satisfies :: Term -> Term -> Bool` — `t2` satisfies `t1` iff `t2 ⊆ t1` (t2 more
  specific). Implemented via term-to-VersionSet semantics.
- `intersectTerms :: Term -> Term -> Term` — the three identities from the doc
  (`P∧P`, `P∧N`, `N∧N`).
- `relation :: Map p Term -> Term -> p -> Relation` where
  `data Relation = Satisfied | Contradicted | Inconclusive` — relation of a single
  package's term to the accumulated terms in the partial solution. Unit propagation
  is built on this.
- Smart constructors: `mkDependency :: p -> VersionSet -> p -> VersionSet -> Incompatibility p`
  producing `{ p: Positive r_p, q: Negative r_q }` with `DependencyCause`; `rootSeed`.

---

## 5. Solver loop

Direct implementation of intro doc §6.

```haskell
unitPropagate
  :: Package p
  => [Incompatibility p] -> PartialSolution p
  -> Either (Incompatibility p) (PartialSolution p)
```
Naïve O(n²) fixpoint: for each incompatibility count unsatisfied terms; 0 ⇒ conflict
(return `Left`), exactly 1 ⇒ add negating derivation and restart scan, ≥2 ⇒ skip.

```haskell
conflictResolution
  :: Package p
  => Incompatibility p -> [Incompatibility p] -> PartialSolution p
  -> (Int, Incompatibility p)   -- (backtrack level, root cause)
```
Satisfier / **previous-satisfier-level** machinery (note the off-by-one warning in the
doc: backtrack to the level *before* the satisfier). Apply the Rule of Resolution,
dropping any term that becomes `Negative empty` (always true).

```haskell
decideNext
  :: DependencyProvider dp p
  => dp -> [Incompatibility p] -> PartialSolution p
  -> Either SolveError ([Incompatibility p], PartialSolution p)
```
Pick a package with a positive derivation but no decision; intersect its derivation
terms; `chooseVersion`. `Nothing` ⇒ add `{ p: Positive allowedRange }` and re-enter
conflict resolution (required for completeness). `Just v` ⇒ record `Decision`, add one
dependency incompatibility per `getDependencies` entry, return to propagation.

```haskell
data SolveError p = NoSolution (Incompatibility p)   -- carries the derivation tree

solve
  :: DependencyProvider dp p
  => dp -> p -> VersionSet
  -> Either (SolveError p) (Map p Version)
```
Main loop per doc §6 "The Main Loop": seed with `{ root: Negative empty }`, alternate
`unitPropagate` / `decideNext`, terminate when no undecided package remains.

```haskell
class Reporter p where
  reportConflict :: Incompatibility p -> String
```
Post-order traversal of the `Derived` DAG producing the proof-style message
(intro doc §7). Deduplication/line-numbering deferred unless it falls out trivially.

---

## 6. Testing strategy

**VersionSet (QuickCheck, properties first):**

- `complement (complement r) == r`
- De Morgan: `complement (union a b) == intersection (complement a) (complement b)`
- `contains (intersection a b) v == (contains a v && contains b v)`
- `contains (union a b) v == (contains a v || contains b v)`
- `contains (complement a) v == not (contains a v)`
- `singleton v` contains `v` and (sampled) nothing else
- Lattice laws (associativity, commutativity, idempotency, absorption) for `\/`/`/\`
- Canonical-form invariant holds after every operation (sorted, disjoint, non-adjacent)

**Solver (unit/scenario tests, in-memory provider):**

An in-memory `DependencyProvider` backed by
`Map p (Map Version [(p, VersionSet)])`, with `chooseVersion` returning the highest
version in range. Scenarios with asserted outcomes:

1. **Trivial** — root depends on nothing ⇒ `{root}`.
2. **Transitive resolve** — root → a → b, all single-version ⇒ all three selected.
3. **Backtracking** — a choice that must be revised after a later conflict; assert the
   final assignment and that resolution terminates.
4. **Unsat conflict** — the doc's `aeson ^>=2.2` / `servant 0.20` / `text` clash ⇒
   `NoSolution`, and `reportConflict` mentions both `text` constraints.
5. **No valid version** — a package whose allowed range is empty ⇒ `NoSolution` via the
   `chooseVersion = Nothing` path (proves completeness path is exercised).

**Build order (TDD per layer):** `VersionSet` (props) → `Types` (helper unit tests) →
`Solver` (scenarios). Each layer's tests pass before the next begins.

---

## 7. Open items deferred to the plan

- Exact `nextVersion` encoding (must satisfy the `singleton` contract).
- Test framework choice (default `tasty` family).
- Whether `VersionSet` carries a pretty-printer or renders from intervals on demand.
