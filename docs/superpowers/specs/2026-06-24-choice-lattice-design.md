# Generalising the solver over a Heyting set algebra (installed vs source choices)

**Date:** 2026-06-24

## Problem

Today the solver only chooses **versions**. `expand` returns a `Version` and a
`Map Pkg VersionSet`, a `Decision` records a `Version`, and the whole constraint
language (`Term`, `Incompatibility`, conflict learning) is hardwired to
`VersionSet`. This cannot express the choice we actually need to make during
resolution: a package may be available *both* as a pre-installed package (with a
fixed unit-id and dependencies already frozen) and as a buildable source package
(whose dependencies are version ranges). These two realizations of the *same
version* can have *different* dependencies, so a bare `Version` is no longer a
sufficient key — and the solver must be able to **decide between them and learn
from that decision** (e.g. ban `installed-1.5` while still trying `source-1.5`).

The current boot-package handling (`hpBoot`, pinning a package to one version and
returning no dependencies) is a degenerate special case of "installed package"
and should eventually be subsumed by the general mechanism.

## Goal

Make installed-vs-source a **genuine choice axis** the solver decides and learns
from, without reimplementing PubGrub's conflict-learning machinery. Achieve this
by generalising the solver to work over an abstract **set algebra** (a Heyting —
in fact Boolean — algebra with a notion of elements), keeping `VersionSet` as one
instance and introducing `ChoiceSet` as another. Dependency edges remain naturally
version-ranged; the installed/source distinction is captured by the *structure of
the set type*, not by special cases in the solver.

Flags are **out of scope** for this work, but the types are designed so a flag
assignment can be added later (as another factor of the `ChoiceSet` product)
without reworking the core.

## Key decisions (and why)

- **Genuine choice axis, not realization metadata.** Because installed-1.5 and
  source-1.5 can differ and the solver must learn `Negative {installed-1.5}`
  independently of `source-1.5`, the *term* language must distinguish instances at
  the same version. A version-only term language cannot.

- **Generalise over a lattice abstraction rather than hardcode `ChoiceSet`.**
  Mirrors `pubgrub-rs`, which is generic over a `VersionSet` trait with an
  associated element type. The solver stops mentioning `Version`/`VersionSet` at
  all; `ChoiceSet` becomes "just another instance". This is less special-casing,
  not more, and it cleanly accommodates flags later.

- **`Heyting`, not just `Lattice`.** Complement/negation is essential
  (`intersectTerms` computes complements). `Lattice` only has `\/`/`/\`. Negation
  lives in a Heyting algebra. Our instances are in fact **Boolean** (true
  complement, `s \/ neg s = top`), which is what set-based conflict learning
  assumes, but Heyting's `neg` is all the machinery calls for. Definitions are
  stolen from the `lattices` package's `Algebra.Heyting`; we do **not** depend on
  `lattices`.

- **`ChoiceSet = VersionSet × VersionSet` (a product), not a map with a default.**
  With worlds fixed to {installed, source}, the set is a literal two-component
  product. Products of Boolean algebras are Boolean, so every operation is the
  `VersionSet` operation applied componentwise — no bespoke arithmetic. Extra
  repositories or flags later add *factors to the product*.

- **Plain-sum `Choice`, not a GADT-indexed `Choice k`.** The solver stores choices
  whose kind is a runtime outcome (`Map p Choice`, `Decision`), so a type index
  would force existential wrapping at every storage site with no guarantee the core
  can exploit. The index only helps provider-internal code that statically knows
  the kind; the provider may use richer types internally and inject into the plain
  sum at the boundary.

## Design

### The lattice/set abstraction (`PubGrub.Lattice`)

Extend the existing `Lattice` class (currently just `\/`/`/\`) with bounds,
negation, and an orthogonal element-membership class:

```haskell
class Lattice a where            -- exists today
  (\/), (/\) :: a -> a -> a

class Lattice a => BoundedLattice a where
  bottom, top :: a

class BoundedLattice a => Heyting a where
  (==>) :: a -> a -> a
  neg   :: a -> a
  neg a = a ==> bottom           -- Boolean instances: a ==> b = neg a \/ b

-- Links a set type to its elements. (pubgrub-rs bundles this into its
-- VersionSet trait; we keep it separate from the pure lattice structure.)
class Heyting s => Sets s where
  type Elem s
  singleton :: Elem s -> s
  member    :: Elem s -> s -> Bool
```

Derivable helpers (given `Eq s`): `isEmpty = (== bottom)`,
`isFull = (== top)`, `subsetOf a b = (a /\ neg b) == bottom`,
`isDisjoint a b = (a /\ b) == bottom`.

> Naming: the membership class is shown as `Sets`; `SetLike`/`Atomic` are
> alternatives, or it could be folded into a single `VersionSet`-style class as
> `pubgrub-rs` does. To be settled in implementation.

### `VersionSet` becomes an instance

`VersionSet` gains `BoundedLattice`/`Heyting`/`Sets` instances mapping onto its
existing functions; `Elem VersionSet = Version`. Its named API
(`VS.empty`, `VS.complement`, …) is kept as thin wrappers so existing call sites
keep compiling during the refactor.

| today | abstraction |
|---|---|
| `VS.empty` / `VS.full` | `bottom` / `top` |
| `VS.complement` | `neg` |
| `VS.union` / `VS.intersection` | `\/` / `/\` |
| `VS.singleton` / `VS.contains` | `singleton` / `flip member` |
| `VS.subsetOf a b` | `(a /\ neg b) == bottom` |
| `VS.isDisjoint a b` | `(a /\ b) == bottom` |

### Generalised core (`PubGrub.Types`, `PubGrub.Solver`)

`Term` and the incompatibility types are parameterised by the set type `s`:

```haskell
data Term s = Positive s | Negative s

data IncompatCause p s
  = NotRoot p (Elem s)
  | NoVersions p s
  | FromDependencyOf p s p s
  | DerivedFrom (Incompatibility p s) (Incompatibility p s)

data Incompatibility p s = Incompatibility
  { incompTerms :: Map p (Term s), incompCause :: IncompatCause p s }
```

`Term` is unchanged in spirit: a *symbolic-negation-plus-intent* wrapper over any
`Sets s`. `Negative s` denotes `neg s` lazily; the `Positive`/`Negative` tag
carries solver intent (asserted membership vs. asserted avoidance). The Boolean
operations (`intersectTerms`, `unionTerms`, `negateTerm`, `relationWith`, …) are
the same, now written against `Heyting`/`Sets` methods instead of `VS.*`.

In `Solver`:

```haskell
data Assignment p s = Decision { … , aChoice :: Elem s } | Derivation { … }
extractSolution :: … -> Map p (Elem s)

class (Package p, Monad m) => DependencyProvider dp p s m | dp -> p s where
  expand :: dp -> p -> s -> m (Maybe (Elem s, Map p s))
```

`expand`'s contract (documented today) is unchanged: return an element satisfying
the given set, with its dependency map; `Nothing` iff the set is unsatisfiable.

### `Choice` and `ChoiceSet` (new, e.g. `PubGrub.Choice`)

```haskell
data Choice = Installed ChoiceInstalled | Source ChoiceSource

data ChoiceInstalled = ChoiceInstalled
  { ciName :: PackageName, ciVersion :: Version
  , ciPackageDB :: PackageDB, ciUnitId :: UnitId }

data ChoiceSource = ChoiceSource
  { csName :: PackageName, csVersion :: Version, csRepository :: Repository }

data Repository = Hackage           -- room for more

version :: Choice -> Version         -- total projection
loc     :: Choice -> Loc             -- Installed | Source
data Loc = LocInstalled | LocSource

data ChoiceSet = ChoiceSet { csetInstalled :: VersionSet, csetSource :: VersionSet }
```

`ChoiceSet` instances are derived componentwise from `VersionSet`:

```haskell
instance BoundedLattice ChoiceSet where
  bottom = ChoiceSet bottom bottom; top = ChoiceSet top top
instance Lattice ChoiceSet where
  ChoiceSet i1 s1 \/ ChoiceSet i2 s2 = ChoiceSet (i1 \/ i2) (s1 \/ s2)   -- and /\
instance Heyting ChoiceSet where
  neg (ChoiceSet i s) = ChoiceSet (neg i) (neg s)
instance Sets ChoiceSet where
  type Elem ChoiceSet = Choice
  singleton c = case loc c of
    LocInstalled -> ChoiceSet (singleton (version c)) bottom
    LocSource    -> ChoiceSet bottom (singleton (version c))
  member c (ChoiceSet i s) = case loc c of
    LocInstalled -> member (version c) i
    LocSource    -> member (version c) s
```

### How `expand` populates `ChoiceSet` dependencies

This is where the product earns its place:

- **Installed package** — depends on specific recorded installed unit-ids, so each
  dependency pins the installed component to an exact version and excludes source:
  `ChoiceSet {csetInstalled = singleton v, csetSource = bottom}`.
- **Source package** — `build-depends: foo >=1 && <2` can be satisfied by an
  installed *or* a freshly-built `foo`, so it spans both components with the same
  range: `ChoiceSet {csetInstalled = R, csetSource = R}`.

"Deps fixed vs deps ranged" and "installed-only vs either-world" both fall out of
*which components are populated* — no special-casing in the solver.

### Reporting

Conflict reports currently render concrete versions/ranges. Generic over
`s`/`Elem s`, `reportConflictWith` needs a way to render them — either `Pretty`-style
constraints on `s` and `Elem s`, or renderer functions carried in `ReportEnv`
(which already abstracts root/pinned). Minor but it touches the reporting code.

## Staging

Each phase keeps the test suite green before the next begins.

- **Phase 0** — add `BoundedLattice`/`Heyting`/`Sets` to `PubGrub.Lattice`; make
  `VersionSet` an instance; keep its named API as thin wrappers. Behaviour
  unchanged.
- **Phase 1** — parameterise `PubGrub.Types` and `PubGrub.Solver` over `s`/`Elem s`,
  with `VersionSet` still the only instance (`Elem = Version`). **Behaviour-preserving**;
  existing tests prove it. This is the large mechanical refactor (type-param churn
  through every signature) and the reporting-genericity change.
- **Phase 2** — add `PubGrub.Choice` with `Choice`/`ChoiceSet` and their derived
  instances; unit-test the `ChoiceSet` algebra (product laws, membership).
- **Phase 3** — `HackageProvider` emits `Choice`/`ChoiceSet`; introduce an
  installed-package-DB source; fold the existing boot-package pinning into the
  general installed-package mechanism.

## Out of scope

- **Flags.** Designed-for (another product factor / source-choice payload) but not
  implemented.
- **Multiple source repositories.** `Repository` has room; `ChoiceSet` stays a
  two-component product until a second source world is actually needed.
- **>1 installed instance per (package, version).** Assumed not to occur; the
  installed component is keyed by version, with unit-id/db carried as payload on the
  concrete `Choice`.
```