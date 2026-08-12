# pubgrub-hs

A native Haskell implementation of the [PubGrub][] version-solving algorithm
(unit propagation + conflict-driven clause learning), applied as a
**proof-of-concept** dependency solver for Cabal packages.

The PoC exists to answer two questions about PubGrub versus cabal-install's
solver: can it produce **materially better explanations** of resolution
failures, and can it **match performance** on real problems? See `CLAUDE.md`
for the full design and roadmap.

[PubGrub]: https://github.com/dart-lang/pub/blob/master/doc/solver.md

## Requirements

- **GHC 9.12.x** and **cabal 3.8+** (the project builds with `base ^>=4.21`).
- A **`ghc` on your `PATH`**: the solver reads that compiler's global package
  database and prefers those installed (boot) packages — this is what pins
  `base` and the rest of the boot libraries.
- **Network access on first run**: the Hackage package index is downloaded and
  verified into a local `_cache/` directory (via `hackage-security`).
  Subsequent runs reuse the cache and refresh it at most weekly.

## Build

```sh
cabal build
```

## Run

The `pubgrub` executable resolves a package's dependency closure against
Hackage plus your installed GHC:

```sh
cabal run pubgrub -- [-v|--verbose] <package> [version-range]
```

Examples:

```sh
cabal run pubgrub -- hashable          # any version
cabal run pubgrub -- aeson '>=2'       # constrained (quote ranges for the shell)
cabal run pubgrub -- -v aeson '<2'     # ... plus the solver's search trace
cabal run pubgrub -- --cabal aeson     # cabal's own solver, over the same index
```

`--cabal` runs cabal-install's modular solver instead of ours, fed from the very
same index read — that shared read is what makes the comparison apples-to-apples.
It is the baseline half of both deliverables.

On the first run you'll see the index being bootstrapped/updated; then the
resolved plan:

```
Solving for hashable
Solution:
 root 0
└─ hashable 1.5.1.0 -arch-native -random-initial-seed
   ├─ base 4.21.0.0 (installed)
   │  ├─ ghc-internal 9.1202.0 (installed)
   │  ...
   ├─ bytestring 0.12.2.0 (installed) (*)
   ...
read 1 .cabal files, served 1 repeat lookups from cache
```

Each node shows the decided *instance*: a source release with the flag
assignment it was decided under, or an installed unit as such. `(*)` marks a
subtree already printed higher up.

Installed/boot packages resolve to the exact unit from your GHC (strict
prefer-installed); everything else resolves to the newest source release in
range, whose dependencies are read lazily from its `.cabal`.

## Test

```sh
cabal test
```

The suite covers the `VersionSet` lattice laws, small end-to-end solves
(satisfiable / unsatisfiable / backtracking), and all six worked examples from
the PubGrub paper (`references/pubgrub.md`).

## Layout

```
src/PubGrub/        core library — the pure PubGrub algorithm and types
                    (Term, VersionSet, Incompatibility, Solver, …). Of the
                    cabal ecosystem it depends on Cabal-syntax only — no
                    cabal-install, no cabal-install-solver.
bridge/Bridge/      the Cabal bridge (private sublibrary): reads the Hackage
                    index, resolves the compiler + installed packages, builds
                    a Provider the core solver consumes, and drives cabal's
                    own solver over the same index as the baseline.
app/Main.hs         the `pubgrub` executable that wires it together.
test/               the test suite.
```

## Status & caveats

This is an early proof of concept. Working today: version ranges, `base`/GHC
pinning via the installed package db, lazy index reading, and Cabal **flags** —
a decision is a version *together with* a total flag assignment, conditional
dependencies are evaluated at exactly that assignment, and a flag leaves its
declared default when conflict resolution rules out the instance that used it
(the semantics is specified in `docs/flags-semantics.md`). Not yet modelled:
setup / build-tool dependencies, public sublibraries, and `manual:` flags (which
should be pinned to their defaults and currently are not distinguished).
Targets that pull in only already-installed boot packages resolve quickly; a
target requiring source-only builds of heavily-versioned packages may explore a
large space.

Also working, as of 2026-08-12: the **baseline**. `--cabal` runs cabal's own solver
over our index, so verdicts and plans can be compared directly. Two things that
comparison immediately found, and that are open: boot-package handling is not yet
strict enough (we will plan to *build* `base` where cabal refuses to), and our failure
proofs are far longer than cabal's on some problems. The harness that would run both
and diff them automatically does not exist yet. `docs/STATUS.md` has the numbers.

The solver trace is currently a raw dump of internal events — readable enough
to follow, not yet polished.
