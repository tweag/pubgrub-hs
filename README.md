# pubgrub-hs

A native Haskell implementation of the [PubGrub][] version-solving algorithm — unit
propagation plus conflict-driven clause learning — applied as a **proof-of-concept**
dependency solver for Cabal packages.

The proof of concept exists to answer two questions about PubGrub against
cabal-install's solver:

1. Can it produce **materially better explanations** of resolution failures?
2. Can it **match performance** on real problems?

On the problems measured so far we use less peak memory than cabal on every one, and
our failure proof is shorter than cabal's message on 17 of 17 real failures. cabal is
faster than us on one of the six benchmark problems. This is not an integration into
cabal-install, and it is not finished. See [`docs/STATUS.md`](docs/STATUS.md) for
the current state and [`CLAUDE.md`](CLAUDE.md) for the architecture.

[PubGrub]: https://github.com/dart-lang/pub/blob/master/doc/solver.md

## Requirements

- **GHC 9.12.x** and **cabal 3.8+**. The project builds with `base ^>=4.21`.
- **A `ghc` on your `PATH`.** The solver reads that compiler's global package database
  and treats its boot packages as installed. This is what pins `base`.
- **Network access on the first run.** The Hackage package index is downloaded and
  verified into a local `_cache/` directory through `hackage-security`. Later runs
  reuse the cache and refresh it at most weekly.

## Build

```sh
cabal build
cabal run pubgrub-index      # optional but recommended, ~200 s, once
```

`pubgrub-index` parses every release on Hackage into a derived index, after which
reading a release is a CBOR decode rather than a `.cabal` parse. It is a cache:
without it the solver parses on demand and gets the same answers, more slowly. It
does not follow the weekly index refresh, so releases published since it was built
are parsed on demand until it is run again. A non-zero `read N .cabal files` on the
last line of a solve is the tell.

## Run

```sh
cabal run pubgrub -- [-v|--verbose] [--stats] [--plan tree|lines] <package> [version-range]
```

```sh
cabal run pubgrub -- hashable          # any version
cabal run pubgrub -- aeson '>=2'       # constrained (quote ranges for the shell)
cabal run pubgrub -- -v aeson '<2'     # ... plus the solver's search trace
cabal run pubgrub -- --stats aeson     # ... plus search counts and phase timings, no trace
cabal run pubgrub -- --cabal aeson     # cabal's own solver, over the same index
```

`--cabal` runs cabal-install's modular solver instead of ours, fed from **the same
index read**. That shared read is what makes the comparison apples-to-apples rather
than arranged. It is the baseline half of both deliverables.

### A successful solve

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
read 0 .cabal files, decoded 3 from the derived index, served 23 repeat lookups from cache
```

Each node shows the decided *instance*: a source release with the flag assignment it
was decided under, or an installed unit as such. `(*)` marks a subtree already printed
higher up.

Boot packages resolve to the exact unit from your GHC and are never built from source.
Everything else resolves to the newest source release in range.

### A failed solve

The failure output is a **proof**, not a search trace:

```
Because template-haskell cannot be built from source and lens <2.4 depends on
template-haskell >=2.4 && <2.8, lens <2.4 is forbidden.
...
1. And because array >=0.4.0.1 && <0.5.0.0 depends on base >=4.2 && <4.7 and base
cannot be built from source, lens <3.10 is forbidden.

Because base cannot be built from source and lens >=3.10 && <4.0 depends on
base >=4.4 && <4.7, lens >=3.10 && <4.0 is forbidden.
And because lens <3.10 is forbidden (1), lens <4.0 is forbidden.
So, because root depends on lens <4, version solving failed.
```

That is 7 sentences where cabal prints 18 lines for the same problem. Across a corpus
of 17 real Hackage failures we are shorter on all 17: 61 sentences against cabal's 166.

## Test

```sh
cabal test                  # 165 tests
scripts/gate.sh             # every check that must not regress, over 23 real problems
cabal run pubgrub-harness   # both solvers over both problem sets; writes bench/output/
```

The suite covers the `VersionSet` laws, the instance-set algebra against an extensional
model, small end-to-end solves, and all six worked examples from the PubGrub spec. The
two error-reporting examples assert the printed proof against a golden file.

`scripts/gate.sh` is what decides whether a change is kept. `pubgrub-harness`
measures: it runs the `pubgrub` executable as a child process, three times per solver
per problem, and writes the benchmark report and the explanation showcase. See
[`docs/benchmarking.md`](docs/benchmarking.md).

## Layout

```
src/PubGrub/        core library — the pure PubGrub algorithm and types.
                    Of the cabal ecosystem it depends on Cabal-syntax only:
                    no cabal-install, no cabal-install-solver.
bridge/Bridge/      the Cabal bridge (private library): reads the Hackage index,
                    resolves the compiler and installed packages, builds the
                    Provider the core consumes, and drives cabal's own solver
                    over the same index as the baseline.
app/                the `pubgrub`, `pubgrub-index` and `pubgrub-harness` executables.
test/               the test suite, plus test/golden/.
docs/               STATUS.md first. See docs/STATUS.md §7 for what each file decides.
specification/      a Lean model of the kernel. A draft, authoritative on nothing.
```

## Status and caveats

**Working:** version ranges, boot-package pinning against the installed database,
buildability (`buildable:` and `pkgconfig-depends` against the machine's real
`pkg-config` database), Cabal flags, failure proofs, and a cabal baseline over a shared
index.

**Two deliberate limits**, and any published number has to state them:

- **Every flag is pinned to its declared default**, on both sides of the comparison.
  That is a restriction of the problem, not a property of either solver. It makes the
  comparison fair, and it makes some real failures unreachable, because cabal's
  automatic flags are exactly what it would flip to escape one.
- **We solve one version per package name.** cabal solves qualified goals and can
  legitimately plan two versions of one package, one for the library and one for a
  setup script.

**Not modelled:** setup and build-tool dependencies, public sublibraries,
`preferred-versions`, and user flag constraints.

**Reports:** `cabal run pubgrub-harness` writes `bench/output/benchmark.md` (both
solvers over `bench/problems.txt`: medians of three runs, phases, residency,
allocation, search counts and a plan diff) and `bench/output/showcase.md` (both
explanations for every comparable corpus problem, as adjacent blocks, with the
counts). Every header states the environment and the restrictions. `bench/output/` is
git-ignored; a run meant to be quoted is copied into `docs/` on purpose. The run of
2026-09-03 is in [`docs/reports/`](docs/reports/).
