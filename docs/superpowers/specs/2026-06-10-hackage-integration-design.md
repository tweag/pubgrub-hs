# Wiring the PubGrub Solver into the Real Hackage Index — Design

**Date:** 2026-06-10
**Status:** Approved (pending spec review)
**Scope:** Make `cabal run pubgrub-hs -- <package> [version-range]` resolve a real Hackage package's dependency closure using the native PubGrub solver, against the bootstrapped Hackage index.

Builds on the completed native-solver milestone
(`docs/superpowers/specs/2026-06-10-pubgrub-native-solver-design.md`).

---

## 1. Goal & non-goals

**Goal.** A working end-to-end resolution: given a target package and an optional
version range, produce either a concrete install plan (`package => version` for the
whole transitive closure) or a rendered derivation tree explaining why none exists —
driven by the verified PubGrub core over live Hackage `.cabal` data, with lazy,
memoized loading.

**Non-goals (deferred):**

- Cabal flag *solving* (we flatten at default flag values).
- Components other than the main library (no exe/test/bench deps).
- Reinstallable boot packages / multiple GHC targets (boot set is pinned to the
  installed GHC).
- `preferred-versions` / deprecation handling, revisions beyond what the index
  lookup returns.
- Per-version skipping on parse failure (a parse failure of a *selected* version
  aborts the solve with an error).
- ASP cross-validation; prettier (deduped/numbered) error reports.

---

## 2. Module layout

```
src/PubGrub/Solver.hs        -- MODIFIED: DependencyProvider + solve generalized to a monad m
test/SolverSpec.hs           -- MODIFIED: in-memory provider instanced at Identity
library  cabal-bridge        -- NEW internal sub-library (deps: base, containers, Cabal, Cabal-syntax, pubgrub-hs)
  app-lib/PubGrub/Cabal/Flatten.hs  -- pure flattening: GenericPackageDescription -> dep set
test/FlattenSpec.hs          -- NEW: unit tests for flattening (parse inline .cabal, assert deps)
app/BootPackages.hs          -- NEW: query + parse `ghc-pkg list --global --simple-output`
app/HackageProvider.hs       -- NEW: IO DependencyProvider over the index + boot pins
app/Solver.hs                -- REWRITE stub: build provider, run solve, render result
app/Main.hs                  -- MODIFIED: CLI (package name + optional version range)
```

**Why the sub-library split.** The pure flattening (the most error-prone part — correct
`finalizePD` usage) goes in an internal sub-library so the test-suite can import and
unit-test it with only `Cabal`/`Cabal-syntax`. The IO provider and index wiring stay in
the executable (they need `hackage-security` and the live index, verified by an
integration run). The clean core `library` keeps its `Cabal-syntax`-only footprint.

**Cabal changes:**
- New `library cabal-bridge` stanza (`hs-source-dirs: app-lib`, exposes
  `PubGrub.Cabal.Flatten`, depends on `pubgrub-hs`, `Cabal`, `Cabal-syntax`,
  `containers`, `base`).
- `executable pubgrub-hs`: add `other-modules` `HackageProvider`, `BootPackages`; add
  `build-depends` on `cabal-bridge` and `process` (for `ghc-pkg`). `pubgrub-hs`,
  `Cabal`, and `Cabal-syntax` are already present.
- `test-suite pubgrub-hs-test`: add `other-modules` `FlattenSpec`; add `build-depends`
  on `cabal-bridge`. (`Cabal-syntax` is already present for parsing inline `.cabal`;
  `finalizePD` is reached only through `cabal-bridge`, so the test-suite needs no direct
  `Cabal` dependency.)

---

## 3. Monadic solver generalization (library)

The only change to the verified core. `unitPropagation` and `conflictResolution`
remain pure; only `solve` and the provider class become monadic.

```haskell
class (Package p, Monad m) => DependencyProvider dp p m | dp -> p where
  chooseVersion   :: dp -> p -> VersionSet -> m (Maybe Version)
  getDependencies :: dp -> p -> Version   -> m (Map p VersionSet)

solve :: DependencyProvider dp p m
      => dp -> p -> Version -> m (Either (SolveError p) (Map p Version))
```

- Functional dependency `dp -> p` is retained; `m` is resolved by the call site
  (return type). This requires no fundep on `m`.
- The `solve` `go` loop threads `m`: it `>>=`s `chooseVersion`/`getDependencies` and
  `pure`s the pure results. `unitPropagation`'s signature and body are unchanged.
- Pragmas: the existing `MultiParamTypeClasses`/`FunctionalDependencies` already cover
  the 3-parameter class.

**Test impact.** `test/SolverSpec.hs`: `instance DependencyProvider Registry String
Identity`, and each `solve r ...` call becomes `runIdentity (solve r ...)`. All 18
existing tests must still pass (behavioral equivalence). Add `import Data.Functor.Identity (Identity, runIdentity)`.

---

## 4. Package type & synthetic root (executable)

To avoid a real Hackage package colliding with the root goal:

```haskell
data Pkg = Root | Pkg PackageName
  deriving (Eq, Ord, Show)
instance Package Pkg
```

Resolution is `solve provider Root (mkVersion [0])`. The synthetic root (version `[0]`)
depends on the target package within the user-supplied range (default `full`).

---

## 5. Hackage provider (IO, executable)

```haskell
data HackageProvider = HackageProvider
  { hpVersions :: Map PackageName [Version]           -- eager, from indexDirectory
  , hpLookup   :: PackageIdentifier -> IO (Either ParseError GenericPackageDescription)
  , hpBoot     :: Map PackageName Version             -- pinned GHC boot packages
  , hpTarget   :: PackageName
  , hpRange    :: VersionSet                          -- target range from CLI
  }

instance DependencyProvider HackageProvider Pkg IO
```

- `hpVersions` is derived once from the index directory listing (same source the
  existing `mkDatabase` uses to build its `Index`). `hpLookup` reuses `mkDatabase`'s
  memoized per-`PackageIdentifier` parse.

- `chooseVersion hp pkg range`:
  - `Root` → `pure (Just (mkVersion [0]))`
  - `Pkg n` where `n` in `hpBoot` → pinned version if `VS.contains range v`, else `Nothing`
  - `Pkg n` otherwise → highest `v` in `hpVersions ! n` with `VS.contains range v`
    (`Nothing` if none / package absent)

- `getDependencies hp pkg v`:
  - `Root` (any v) → `Map.singleton (Pkg (hpTarget hp)) (hpRange hp)`
  - `Pkg n` boot → `pure Map.empty` (boot packages treated as leaves)
  - `Pkg n` otherwise → `hpLookup (PackageIdentifier n v)` then:
    - `Right gpd` → `Map.mapKeys Pkg (flattenDeps platform compiler gpd)`,
      with boot/self entries kept (boot deps will pin; a self-dep is harmless)
    - `Left _`   → throw `ResolveError` (caught at top level → "failed to parse n-v")

`platform = Platform X86_64 Linux`; `compiler = unknownCompilerInfo (CompilerId GHC
(mkVersion [9,12,4])) NoAbiTag`.

---

## 6. Boot packages (executable)

`BootPackages.queryBootPackages :: IO (Map PackageName Version)`:

- Run `ghc-pkg list --global --simple-output` via `System.Process.readProcess`.
- Parse the space-separated `name-version` tokens (the last `-`-segment that parses as
  a version is the version; the rest is the name) into `Map PackageName Version`.
- A pure helper `parseBootList :: String -> Map PackageName Version` is exported for
  unit testing the parser without invoking the process. (Lives in `BootPackages`; if a
  unit test is desired it can move to `cabal-bridge`, but the integration run covers it.)

Rationale: the installed global packages are exactly GHC's boot libraries, pinned by the
compiler. A dependency range not satisfiable by the pinned version yields a normal
`NoSolution` conflict (correct: boot libs can't be changed without changing GHC here).

---

## 7. Dependency flattening (pure, `cabal-bridge`)

```haskell
module PubGrub.Cabal.Flatten (flattenDeps) where

flattenDeps
  :: Platform
  -> CompilerInfo
  -> GenericPackageDescription
  -> Map PackageName VersionSet
```

Implementation:

- Call `Distribution.PackageDescription.Configuration.finalizePD`:
  ```
  finalizePD mempty                      -- default flag assignment
             (ComponentRequestedSpec { testsRequested = False, benchmarksRequested = False })
             (const True)                -- assume all deps satisfiable (we resolve later)
             platform compiler
             []                          -- no extra constraints
             gpd
  ```
- On `Right (pd, _flags)`: take the library component
  (`Distribution.Types.PackageDescription.library pd`), read its `targetBuildDepends`
  (via `Distribution.Types.BuildInfo.targetBuildDepends . libBuildInfo`), and fold each
  `Dependency name range _libs` into `Map.insertWith VS.intersection name
  (VS.fromVersionRange range)` (intersect duplicates).
- On `Left _missing` (finalize couldn't satisfy under defaults): for a first cut, fall
  back to `Map.empty`. (Documented limitation; rare under `const True`.)
- If `pd` has no library, return `Map.empty`.

Exact `finalizePD` arity/argument order will be confirmed against the installed `Cabal`
during implementation; the contract above is fixed.

---

## 8. CLI & output (executable)

- `pubgrub-hs <package> [version-range]`
  - `<package>`: a Hackage package name (`mkPackageName`).
  - `[version-range]`: optional Cabal version range string (e.g. `>=2.0 && <3`),
    parsed with `Distribution.Parsec` (`eitherParsec`); default `full`.
- Flow (in `app/Solver.hs`, called from `Main` inside the existing `withIndex`):
  1. Build `hpVersions` from `indexDirectory`; `hpLookup` from `mkDatabase`.
  2. `queryBootPackages`.
  3. Assemble `HackageProvider`; `solve provider Root (mkVersion [0])`.
  4. `Right plan` → print sorted `name => version` lines, omitting `Root`.
     `Left (NoSolution i)` → print `reportConflict i`.
  - Wrap in `try`/handler for the `ResolveError` parse-failure case → friendly message.

`Main` is adjusted to parse argv (package + optional range) instead of the hardcoded
`lens` lookup, then delegate to the integration entry point.

---

## 9. Testing & verification

| Layer | How | Where it runs |
|-------|-----|---------------|
| Monadic solver refactor | `-Wall` offline typecheck + existing 18 tasty tests at `Identity` | In-sandbox (agent) |
| `flattenDeps` | `FlattenSpec`: parse inline `.cabal` snippets (incl. one with a `flag`/`if` conditional and a no-library package), assert the dep `Map` | `cabal test` — user machine (needs `Cabal`) |
| Boot parser | optional unit on `parseBootList`; otherwise covered by integration | user machine |
| End-to-end | `cabal run pubgrub-hs -- lens` (and an unsatisfiable case) yields a plan / derivation tree | manual, user machine (needs `hackage-security`, live index) |

**Verification constraint.** The sandbox cannot fetch `Cabal`/`hackage-security` or hit
the live index, so only the library change is agent-verifiable. Everything touching
`Cabal` or the index is built and run by the user. Code is written against the documented
APIs; the flattening unit test and the integration run are the gates.

---

## 10. Risks

- **`finalizePD` signature drift** across Cabal versions — confirmed at implementation
  time against the installed `Cabal` (the executable already depends on `Cabal`).
- **Index size / performance** — lazy memoized loading keeps work proportional to the
  explored closure; acceptable for a first integration. No watched-literals yet.
- **Boot-pinned conflicts** — a target needing a newer boot lib than installed yields
  `NoSolution`; correct given the non-reinstallable-boot scope, but may surprise users.
  Documented in CLI output context.
