# Bridge, problem model, and PInfo adapter

Design notes from the 2026-07-23 planning session. This records *decisions and
sketches*, not finished code. Some type names here predate the reboot and no
longer exist; flags, described below as "later", are implemented — see
[flags-semantics.md](flags-semantics.md) for their specification. See `CLAUDE.md` for the one-paragraph version and
the rung ladder.

## Goal recap

pubgrub-hs is a **proof-of-concept**: is PubGrub (a) better at *explaining*
resolution failures and (b) competitive on *time + peak memory* vs
cabal-install's solver? Correctness is table stakes. Both questions must be
answered on **real Hackage data**, which is what the bridge exists to supply.

## Three components, hard dependency boundary

```
pubgrub-hs (library) ──── deps: Cabal-syntax ONLY
  native PubGrub: Term, VersionSet, Relation, Incompatibility, Solver, Report
  pure algorithm + types; NO cabal-install-solver, NO cabal-install
        ▲  consumes: PubGrub.Package.Index + root
pubgrub-bridge (executable) ── deps: cabal-install-solver, Cabal, Cabal-syntax, tar
  own minimal index reader → cabal `Index` (convPIs) → feeds BOTH:
    ├─ cabal's Distribution.Solver.Modular.Solver.solve   (baseline)
    └─ PInfo→SourcePackage adapter → PubGrub.Package.Index (our solver)
  NO cabal-install, NO hackage-security
        ▲
harness — runs both, diffs verdicts, renders explanations side by side,
  measures wall-clock + peak residency
```

Why the core must not depend on cabal-install-solver: keeps the algorithm
lightweight and portable; all the heavy cabal machinery is quarantined in the
bridge.

## Dropping cabal-install and hackage-security

The `../cabal-solver-plan` reference depends on `cabal-install`, but tracing its
imports shows it is used for only three things:

1. **Index acquisition** (`IndexUtils`, `GlobalFlags.RepoContext`,
   `Hackage.Security.Client`) — reading `01-index.tar` into
   `PackageIndex (SourcePackage loc)`. The only substantial use.
2. **CLI-convenience types** (`UserConstraint`/`userToPackageConstraint`,
   `IndexState`, `defaultMaxBackjumps`, `Types.Repo`, `Utils.incVersion`) —
   trivially replaceable. Note most of what `Distribution.Client.Dependency`
   provides (`PackageConstraint`, `PackageProperty`, `scopeToplevel`) actually
   originates in `cabal-install-solver`'s `Distribution.Solver.Types.*`.
3. **Setup-deps types** (`ProjectPlanning.Types`, `Types.PackageLocation`) —
   only needed at Rung 4; likely reconstructible from `setupBuildInfo`.

Decision: **write our own minimal index reader** (read cached `01-index.tar`
with `tar`, parse each `<pkg>/<ver>/<pkg>.cabal` with `Cabal-syntax`'s
`parseGenericPackageDescription`, wrap into `SourcePackage`, build
`PackageIndex`). This lets us drop both `cabal-install` and `hackage-security`.

Two correctness gotchas the reader must handle (this is the non-trivial part of
what `IndexUtils` does for us):
- **`.cabal` revisions** — the index holds multiple revisions of the same
  version; **last one wins**.
- **`preferred-versions`** — honor them, or explicitly defer and log it.
- Index-state pinning + security *verification* are dropped for the PoC (read
  whatever cached tarball is on disk). Revisit if reproducibility bites.

Bonus: the same reader feeds both solvers, so the index is byte-identical on
both sides — apples-to-apples becomes structural, not policed.

## UserConstraint vs PackageVersionConstraint

- `PackageVersionConstraint` (Cabal-syntax) = `PackageName` + `VersionRange`.
  Version-only, unscoped. Within our allowed deps.
- `UserConstraint` (cabal-install: `Distribution.Client.Targets`) = a **scope** +
  a **`PackageProperty`** (version range | installed | source | **flag
  assignment** | stanzas). Scoped and richer. Lives in `cabal-install` — the
  package we drop — so we can't reuse it anyway.

Consequence: **we define our own constraint type** covering version now, flags
soon (see `SolveConfig` below).

## Two layers: config vs neutral problem type

- **Layer 1 — `SolveConfig`** (bridge input; the stripped `ProjectConfig`). The
  single source of truth both solvers derive from.
- **Layer 2 — cabal's `convPIs` output `Index`** (environment-resolved universe;
  feeds cabal directly, translated for us).
- **Layer 3 — `PubGrub.Package.Index` + root** (what the core consumes). Already
  Cabal-syntax-only; no solver types leak in.

### `SolveConfig` sketch (Layer 1)

```haskell
data SolveConfig = SolveConfig
  { scLocalPackages :: [FilePath]    -- .cabal files to read; these ARE the targets
  , scConstraints   :: [Constraint]  -- our own type (UserConstraint is in cabal-install)
  , scIndex         :: IndexSource   -- e.g. IndexTarball FilePath
  , scEnv           :: SolveEnv      -- NOT optional (see note)
  }

data SolveEnv = SolveEnv                 -- convPIs AND our env-conditional
  { seCompiler :: CompilerInfo           -- flattening both need compiler+platform
  , seOS       :: OS
  , seArch     :: Arch
  }

newtype IndexSource = IndexTarball FilePath

data Constraint = Constraint PackageName ConstraintProperty
data ConstraintProperty
  = CVersion VersionRange              -- Rung 1
  | CFlags   FlagAssignment            -- Rung 2 (reuse PubGrub.Package.FlagAssignment)
  -- CInstalled | CSource | CStanzas   -- later rungs
```

`scEnv` is required because both `convPIs` and our "resolve os()/arch()/impl()
in the bridge" step need the compiler + platform to flatten env conditionals
down to the flag-only conditionals the core understands. **The bridge owns
"which environment are we solving for"; the core only ever sees flag conditions.**

## convPIs: reuse vs rewrite

Decision (provisional, reversible): **reuse `convPIs`**, write a thin
`PInfo → SourcePackage` adapter, and derive *both* solvers from the same
`PInfo`.

Rationale:
- **Fair comparison (Q2).** If cabal solves from `convPIs` but we solve from an
  independent `.cabal` flattening, any perf/explanation difference is
  contaminated by "you flattened conditionals differently." Sharing `convPIs`
  makes identical-input structural.
- `convPIs` does two fiddly things for free: resolves os/arch/impl conditionals
  against the platform (our exact bridge boundary), and the
  `finalizePD`/cond-tree flattening that is historically a bug farm to
  reimplement.
- Reversible per-slice; and it is the fastest way to *empirically* find where
  `PInfo` doesn't fit (Rung 1 runs and shows us) instead of guessing before the
  core is finished.

Andrea's counter-preference (noted): would rather **avoid `finalizePD` and
flatten conditionals in our own Provider**. Accepted tension — the confound risk
above is why we start with reuse; may revisit once the core is complete and we
can validate our own flattening matches cabal's.

## How PInfo maps to our model

Grounded against cabal-install-solver 3.17 source:

```haskell
data PInfo = PInfo (FlaggedDeps PN)                     -- conditional dep tree
                   (Map ExposedComponent ComponentInfo)  -- lib / sublib / exe
                   FlagInfo                             -- flag defaults + manual
                   (Maybe FailReason)                   -- globally unbuildable
data FlaggedDep qpn
  = Flagged (FN qpn) FInfo (FlaggedDeps qpn) (FlaggedDeps qpn) -- if-flag: true / false
  | Stanza  (SN qpn) (FlaggedDeps qpn)                         -- test/bench
  | Simple  (LDep qpn) Component                               -- real dep, tagged with OUR needing component
-- Simple payload: LDep _ (Dep (PkgComponent qpn ExposedComponent) CI)
```

Note: at the *index* level deps are `FlaggedDeps PN` — **unqualified**.
Qualifiers (setup scope etc.) are introduced by the solver during search, not
stored in the index; the adapter deals with plain `PN`.

### Maps cleanly (was designed for it)
- `FlagInfo → spFlags` (name + default + manual) — direct.
- `Flagged`/`Simple` tree → `spDependencies :: [Dependency]` with
  `Condition FlagName`: fold the tree, pushing `Var f` onto the true branch and
  `CNot (Var f)` onto the false branch, nesting via `CAnd`. Our
  `Condition FlagName` is exactly this target. `Dep`'s `CI` (version range) →
  `VersionSet`.

### Doesn't map — and the gaps ARE the rung ladder
| PInfo feature | Our model today | Rung |
|---|---|---|
| `Simple` target `ExposedExe` | `Dependency` has no target-component axis | Rung 4 (build-tools) |
| `Simple` target `ExposedLib <named>` | same | Rung 5 (public sublibraries) |
| `Simple` own-`Component` (test/bench/setup) + `Stanza` | no stanza concept | Rung 4 (setup); test/bench off-ladder |
| `Dep = Ext` / `Lang` | none | compiler satisfies — drop |
| `Dep = Pkg` (pkg-config) | none | deferred — drop |
| qualified names (`FN`/`SN`/`qpn`) | flat names | solver-search concern, not adapter; Rung 4 for setup scope |
| `FailReason` / `IsBuildable` | `spBuildable :: Condition FlagName` | partial; mostly `Lit True` at Rung 1 |

**Concrete future core change:** `Dependency PackageName VersionSet (Condition
FlagName)` will need a **target-component axis** at Rung 4/5.

### Divergence to watch (about us, not the mapping)
cabal keeps flags as **first-class solver variables** (each `FN` is a goal); our
model **enumerates** flag assignments into `Instance`s (2^flags per package, in
the Provider). `PInfo → SourcePackage` is faithful, but our Provider then
explodes what cabal keeps symbolic. Invisible to the adapter, very visible to
the **performance question** on flag-heavy packages. `InstanceSet` hides behind
`SetOps`, so a symbolic representation could replace the explicit set later
without the algorithm noticing.

## PInfo → SourcePackage adapter (SKETCH — not compiled)

Exact cabal field/ctor names TBC. Three spots to verify against real types:
`toFlag`/`FInfo`'s manual field, `ciToVersionSet` (`CI`'s `Constrained VR` vs
`Fixed I`), and the whole-Index `Loc` split (`Inst _` → `PreInstalledPackage`,
else source).

```haskell
adaptSourcePackage :: Version -> PInfo -> P.SourcePackage
adaptSourcePackage ver (PInfo fdeps _components flagInfo mFail) =
  P.SourcePackage
    { P.spVersion      = ver
    , P.spFlags        = map adaptFlag (Map.toList flagInfo)
    , P.spDependencies = flatten (P.Lit True) fdeps
    , P.spBuildable    = maybe (P.Lit True) (const (P.Lit False)) mFail   -- NB crude
    }

flatten :: P.Condition P.FlagName -> [FlaggedDep PN] -> [P.Dependency]
flatten guard = concatMap go
  where
    go (Flagged (FN _ f) _finfo ts fs) =
         flatten (guard `cand`       P.Var (toFlag f)) ts
      ++ flatten (guard `cand` P.CNot (P.Var (toFlag f))) fs
    go (Stanza _ _)              = []                 -- NB test/bench stanzas -> later
    go (Simple (LDep _ dep) comp)
      | comp == ComponentLib     = depTerms guard dep -- keep only our main-lib deps
      | otherwise                = []                 -- NB our test/bench/setup/exe -> Rung 4+

    depTerms g (Dep (PkgComponent pn (ExposedLib _)) ci) =
        [ P.Dependency (toPN pn) (ciToVersionSet ci) g ]
    depTerms _ (Dep (PkgComponent _ (ExposedExe _)) _) = []  -- NB build-tools -> Rung 4
    depTerms _ Ext{}  = []   -- compiler satisfies
    depTerms _ Lang{} = []
    depTerms _ Pkg{}  = []   -- NB pkg-config -> deferred

cand :: P.Condition a -> P.Condition a -> P.Condition a   -- drop (Lit True)
cand (P.Lit True) c = c ; cand c (P.Lit True) = c ; cand a b = P.CAnd a b
```

The whole-`Index` wrapper `Map PN (Map I PInfo) → P.Index` branches on the
instance `Loc`: `Inst _` → `PreInstalledPackage` (Rung 3), else
`adaptSourcePackage`.

## Core frontier (as of 2026-07-23)

`Solver.hs`: storage layer (`Assignment`, `PartialSolution`, queries) is
complete and instance-based. The three algorithm functions
(`unitPropagation`, `conflictResolution`, `solve`) are `error "TODO"` stubs, and
the **old generic implementation is preserved commented at the bottom as a
near-line-for-line porting template**. "Keep going" is mostly a *port*, not
fresh design.

Porting the reference means: specialize `p → PackageName`,
`s → InstanceSet`, `Elem s → Instance`; drop the co-log monad (new stubs are
pure `Either`); plus:
- **Bring `satisfierOf` + `satisfierSearch` along** — needed by
  `conflictResolution`, not currently stubbed.
- **Naming deltas:** `incompTerms i` → pattern-match `Incompatibility m` (newtype
  exports `(..)`); `noVersions` → `noInstances`; `singleton v` →
  `singletonInstance i`; `exactTerm v` → `Positive (singletonInstance i)`.
- **The one real fix (not a port): the `Provider` is still version-shaped.**
  `undecidedPositive` returns an `InstanceSet` and the loop decides an
  `Instance`, but the record still has `preferredVersion :: PackageName ->
  VersionSet -> Maybe Version` / `consequences :: PackageName -> Version ->
  [Incompatibility]`. Its own doc comment says it should become:
  ```haskell
  preferredInstance :: PackageName -> InstanceSet -> Maybe Instance
  consequences      :: PackageName -> Instance    -> [Incompatibility]
  ```
  The `Provider` is the seam where instance enumeration + flag flattening live —
  i.e. it is the ultimate consumer of the adapter above, and the place Andrea's
  "flatten in the Provider" preference would materialize.

Suggested port order (dependency-first): `Provider` → `satisfierOf` →
`satisfierSearch` → `conflictResolution` → `unitPropagation` → `solve`.

Cause tracking (for the Report renderer / explanations deliverable) is still not
reinstated: `Incompatibility` dropped its `IncompatCause`, and `priorCause`
forgets its parents. This must be designed back *into* conflict resolution.
```
