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

- **`ChoiceSet` is a product of two Boolean algebras, one per world.** Not a map
  with a default. Products of Boolean algebras are Boolean, so every operation is
  componentwise — no bespoke arithmetic. Extra repositories or flags later add
  *factors to the product*.

- **The installed world is keyed by `UnitId`, not version.** There can be several
  installed instances with the same name *and* version, distinguished only by their
  package-db key (`UnitId`/`InstalledPackageId`). They are genuinely distinct
  choices and the solver picks among them. So the installed component is a set *of
  unit-ids*, represented as a finite-or-cofinite set `Pow UnitId` (universe-free
  Boolean algebra over an unordered domain), while the source component stays a
  version-keyed `VersionSet`. This gives us two primitive `Sets` instances
  (`VersionSet` via intervals, `Pow` via finite/cofinite) plus the product.

- **Plain-sum `Choice`, not a GADT-indexed `Choice k`.** The solver stores choices
  whose kind is a runtime outcome (`Map p Choice`, `Decision`), so a type index
  would force existential wrapping at every storage site with no guarantee the core
  can exploit. The index only helps provider-internal code that statically knows
  the kind; the provider may use richer types internally and inject into the plain
  sum at the boundary.

- **Installed packages are a separate provider, combined as a product.** The
  compiler + its package db(s) form a `PackageDbProvider` over `Pow UnitId`,
  independent of `HackageProvider` over `VersionSet`. Both are instances of the
  same generic `DependencyProvider`; the combined provider is their product over
  `ChoiceSet`. A provider's "key" is just its `Elem s` and never reaches the solver
  — so no `Key p` is needed in the interface. The boot-package special-case
  collapses into "the db provider restricted to the global db".

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

### A second primitive: `Pow a` (finite/cofinite subsets)

For domains without a useful order (here, `UnitId`), the Boolean algebra of
subsets is represented so that complement needs no universe:

```haskell
data Pow a = Incl (Set a) | Excl (Set a)   -- Excl s = complement of finite s

bottom = Incl Set.empty;  top = Excl Set.empty
neg (Incl s) = Excl s;    neg (Excl s) = Incl s
Incl a /\ Incl b = Incl (a `Set.intersection` b)
Incl a /\ Excl b = Incl (a `Set.difference` b)         -- (and the dual cases)
member x (Incl s) = x `Set.member` s
member x (Excl s) = not (x `Set.member` s)
singleton = Incl . Set.singleton
-- type Elem (Pow a) = a;  requires Ord a;  derived Eq is canonical
```

This is universe-free: complement just swaps the constructor. Cofinite sets
(`Excl`) arise naturally from `neg` during term arithmetic (e.g. `Negative {u}`
denotes "every installed instance except `u`").

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
  , ciPackageDB :: PackageDB, ciUnitId :: UnitId }   -- ciUnitId is the identity

data ChoiceSource = ChoiceSource
  { csName :: PackageName, csVersion :: Version, csRepository :: Repository }

data Repository = Hackage           -- room for more

version :: Choice -> Version         -- total projection (provenance, reporting)

data ChoiceSet = ChoiceSet { csetInstalled :: Pow UnitId, csetSource :: VersionSet }
```

The installed component is a `Pow UnitId` (so two installed instances of the same
name+version are distinct), the source component a `VersionSet`. Instances are
derived componentwise from the two factors:

```haskell
instance BoundedLattice ChoiceSet where
  bottom = ChoiceSet bottom bottom; top = ChoiceSet top top
instance Lattice ChoiceSet where
  ChoiceSet i1 s1 \/ ChoiceSet i2 s2 = ChoiceSet (i1 \/ i2) (s1 \/ s2)   -- and /\
instance Heyting ChoiceSet where
  neg (ChoiceSet i s) = ChoiceSet (neg i) (neg s)
instance Sets ChoiceSet where
  type Elem ChoiceSet = Choice
  singleton (Installed ci) = ChoiceSet (singleton (ciUnitId ci)) bottom
  singleton (Source cs)    = ChoiceSet bottom (singleton (csVersion cs))
  member (Installed ci) cs = member (ciUnitId ci) (csetInstalled cs)
  member (Source cs')   cs = member (csVersion cs') (csetSource cs)
```

### How `expand` populates `ChoiceSet` dependencies

This is where the product earns its place:

- **Installed package** — depends on specific recorded installed unit-ids, so each
  dependency pins the installed component to those exact ids and excludes source:
  `ChoiceSet {csetInstalled = Incl {u}, csetSource = bottom}`.
- **Source package** — `build-depends: foo >=1 && <2` can be satisfied by an
  installed *or* a freshly-built `foo`. The source part is the range `R`; the
  installed part is the set of installed unit-ids of `foo` whose version is in `R`
  (the provider enumerates the db): `ChoiceSet {csetInstalled = Incl matches, csetSource = R}`.

"Deps fixed vs deps ranged" and "installed-only vs either-world" both fall out of
*which components are populated* — no special-casing in the solver. The db→unit-id
enumeration lives entirely in the provider, keeping the set algebra universe-free.

### Provider architecture: two providers, combined as a product

The compiler and its package db(s) are an **independent source of choices** from
Hackage, so they become a separate provider. The generic `DependencyProvider`
class makes both fall out as instances *at different set types* — each provider's
"key" is simply its `Elem s`, and it never leaks past the provider boundary (the
solver only ever sees `(p, ChoiceSet, Choice)`):

| provider | `s` | `Elem s` (its key) | deps returned |
|---|---|---|---|
| `HackageProvider` (source) | `VersionSet` | `Version` (≈ `PackageId`) | `Map p VersionSet` |
| `PackageDbProvider` (installed) | `Pow UnitId` | `UnitId` (≈ `InstalledPackageId`) | `Map p (Pow UnitId)` |

So `expand` takes a *set* (constraint) and returns *one key* plus dependencies *as
sets* — the chosen instance is a key, its dependencies are sets. This is why two
different key types coexist without a `Key p` in the solver interface: it is
subsumed by `Elem s`.

```haskell
-- built from a Compiler + the package dbs it exposes
data PackageDbProvider = PackageDbProvider
  { pdbByName :: Map PackageName (Map UnitId InstalledPackageInfo) }  -- the index

data Toolchain = Toolchain
  { tcCompiler :: Compiler, tcPlatform :: Platform, tcPackageDb :: PackageDbProvider }
```

**Indexing.** Both providers key their data by package name. `HackageProvider`
already does this (`hpVersions :: Map PackageName (NonEmpty Version)`);
`PackageDbProvider` needs the installed analogue — turning the flat
`[(PackageName, Version, InstalledPackageInfo)]` into `Map PackageName (Map UnitId …)`
so it can answer "all installed instances of `bar`". An installed package's
`depends :: [UnitId]` is likewise grouped through this index into
`Map p (Pow UnitId)`.

**Combined provider.** Over `ChoiceSet = Pow UnitId × VersionSet`, the combined
provider is a *product of the two*, dispatching each component to its sub-provider:

```haskell
expandCombined p (ChoiceSet inst src) = do
  mi <- expand pdb     p inst   -- Maybe (UnitId,  Map p (Pow UnitId))
  ms <- expand hackage p src    -- Maybe (Version, Map p VersionSet)
  -- choose a winner by policy (prefer installed reuse, else newest source),
  -- then lift its deps into ChoiceSet.
```

**Cross-world lookup lives in the combiner.** The one place the worlds touch: a
source dependency `(bar, R)` may also be satisfied by an installed `bar` in range
`R`. The combiner holds the db and fills the installed component when lifting a
source dep into `ChoiceSet`; the sub-providers stay pure to their own world. (The
existing boot-package pinning becomes "the db provider restricted to the global
db" — the `hpBoot`/`hpCompiler` special-cases in `HackageProvider` go away.)

### Reporting (a core goal — must not regress)

Conflict reporting is a primary feature, so generalisation must not weaken it.
Today `reportConflictWith` renders an `Incompatibility p` with `prettyPackage`,
`prettyVer :: Version -> Text`, and `prettyVS :: VersionSet -> Text`, and uses a
`ReportEnv` with two bespoke hooks (`rePinnedVersion`, `reIsRoot`) to say e.g.
"provided by the compiler as 4.21.0.0". Two mechanisms preserve and extend this
once the types are generic:

**(a) A `Pretty`-style rendering class.** So any set/element can always be shown —
a report can never silently drop the concrete constraint:

```haskell
class Pretty a where pretty :: a -> Text
-- instances: Version, VersionSet, UnitId, Pow UnitId, Choice, ChoiceSet
```

`reportConflictWith` gains `(Pretty s, Pretty (Elem s))` constraints; `prettyVer`
becomes `pretty @(Elem s)` and `prettyVS` becomes `pretty @s`. `Choice` carries
its provenance, so `Pretty Choice` renders the distinction intrinsically, e.g.
`foo-1.5 (installed: global-db)` vs `foo-1.5 (source: hackage)` — exactly the
information a generic version-only report would have lost. (We define our own
lightweight `Pretty` to `Text` rather than reuse Cabal's `Distribution.Pretty`,
which targets `Doc`/`String`; `Package` keeps `prettyPackage` for `p`.)

**(b) Annotations.** Generalise `ReportEnv`'s bespoke `rePinnedVersion` into a
uniform annotation capability — extra context the caller/provider knows that isn't
in the bare terms (e.g. "provided by the compiler", "from the global package db").
The guarantee we want is that we can *always attach an annotation* to the things a
report names — packages, chosen elements (`Choice`), and decisions:

```haskell
data ReportEnv p s = ReportEnv
  { reIsRoot   :: p -> Bool
  , reAnnotate :: p -> Maybe Text          -- package-level provenance
  , reAnnotateElem :: Elem s -> Maybe Text -- chosen-instance provenance (optional)
  }
```

Annotations are supplied at report time and stay out of the solver's hot data
structures (`Decision`/`Incompatibility` gain no reporting-only fields). The
existing "compiler-provided as X, which does not satisfy R" leaf is reconstructed
as `reAnnotate p` (the provenance phrase) composed with `pretty s` (the
unsatisfied set). Open detail for implementation: the exact annotation key set
(package vs element vs decision) — the principle is that all are annotatable.

## Staging

Each phase keeps the test suite green before the next begins.

Chosen ordering: **generalise first, then split providers**. Each phase keeps the
test suite green before the next begins.

- **Phase 0** — add `BoundedLattice`/`Heyting`/`Sets` to `PubGrub.Lattice`; make
  `VersionSet` an instance (keep its named API as thin wrappers); add `Pow a` as a
  second primitive instance, with tests. Behaviour unchanged.
- **Phase 1** — parameterise `PubGrub.Types`, `PubGrub.Solver`, **and the
  `DependencyProvider` class** over `s`/`Elem s`, with `VersionSet` still the only
  instance in use (`Elem = Version`). Add the `Pretty` class and convert reporting
  to it + the generalised `ReportEnv` annotations. **Behaviour-preserving**;
  existing tests prove identical report output. This is the large mechanical
  refactor (type-param churn through every signature).
- **Phase 2** — add `PubGrub.Choice` with `Choice`/`ChoiceSet` and their derived
  instances (unit-test the algebra: product laws, membership, multiple installed
  instances per name+version). Extract `PackageDbProvider`/`Toolchain` from
  `Compiler` + package dbs (with the package-name index); `HackageProvider` becomes
  the source provider over `VersionSet`, `PackageDbProvider` the installed provider
  over `Pow UnitId` — each a clean instance of the generic class.
- **Phase 3** — the combined provider over `ChoiceSet` (product of the two,
  cross-world lookup in the combiner); fold the existing boot-package pinning into
  the db provider (the global db); wire into `Main`.

## Out of scope

- **Flags.** Designed-for (another product factor / source-choice payload) but not
  implemented.
- **Multiple source repositories.** `Repository` has room; the source component
  stays a single `VersionSet` until a second source world is actually needed (at
  which point it becomes a product over repositories, same pattern as the installed
  world). Multiple installed instances per name+version *are* supported (keyed by
  `UnitId`).