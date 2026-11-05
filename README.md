# pubgrub-hs

A native Haskell implementation of the [PubGrub][] version-solving algorithm, applied
as a **proof-of-concept** dependency solver for Cabal packages. PubGrub picks a version
of every package a request needs, working out what each known fact forces (unit
propagation) and turning each conflict into a new fact (conflict-driven clause
learning). When no choice works, those facts are a proof of why. This is not an
integration into cabal-install, and correct solving is table stakes. The project exists
to answer two questions about PubGrub against cabal-install's solver:

1. Can it produce **materially better explanations** of resolution failures?
2. Can it **match performance** on elapsed time and on peak memory, on real problems?

**The solver works.** It resolves real Hackage packages end to end: version ranges,
Cabal flags, buildability, and installed boot packages. All six worked examples from
the PubGrub spec are tests, and the two error-reporting examples assert the printed
proof against a golden file.

**Both questions are measured, and neither answer is an unqualified yes.** We are faster
than cabal, use less peak memory and allocate less on all six benchmark problems, though
that is six problems, and cabal also solves setup and build-tool dependencies there and
we do not. Our failure proof is shorter than cabal's message on all 21 real failures in
the corpus. That record holds only where every target is pinned to a version, and every
corpus target is: on a problem with an *unconstrained* target a complete proof has to
refute every release of it, where cabal's message is a search trace that stops at the
first wall it hit, and on the 23 such problems of the 2026-09-10 sweep we were the longer
text on 21. On the benchmark set too, cabal's message on `aeson <2` is shorter than our
proof.

The benchmark report and the explanation showcase in [`docs/reports/`](docs/reports/)
are the evidence, each dated in its header. [Documentation](#documentation) lists the
rest.

[PubGrub]: https://github.com/dart-lang/pub/blob/master/doc/solver.md

## Install

Releases ship the `pubgrub` executable, and the source distribution and the
documentation of `pubgrub` and `pubgrub-cabal`. Building from the checkout is
[Build](#build) below.

### Pre-built binaries

Download the archive for your platform from the [latest release](https://github.com/tweag/pubgrub-hs/releases/latest) and unpack it. It contains the `pubgrub` executable. There are archives for x86_64 and aarch64 Linux, x86_64 and aarch64 macOS, and x86_64 Windows.

- Linux binaries need glibc 2.34 or newer (e.g. Ubuntu 22.04, Debian 12, RHEL 9), libgmp and zlib.
- macOS binaries are not notarised. Remove the quarantine attribute before running one: `xattr -d com.apple.quarantine pubgrub`.

Each release also has `SHA256SUMS`, and a GitHub attestation for every file. To check an archive:

```
sha256sum --check --ignore-missing SHA256SUMS
gh attestation verify ARCHIVE --repo tweag/pubgrub-hs
```

### With mise

[mise](https://mise.jdx.dev/) installs the release archive for your platform with its [GitHub backend](https://mise.jdx.dev/dev-tools/backends/github.html), and checks its checksum and attestation:

```
mise use -g github:tweag/pubgrub-hs
```

Add `@VERSION` to pin a version, for example `github:tweag/pubgrub-hs@0.1.0.0`. Without `-g`, the tool is added to the current project's `mise.toml`.

### From source

Each release has the source distributions of `pubgrub` and `pubgrub-cabal`, `PACKAGE-VERSION.tar.gz`, which are what goes to Hackage. The `pubgrub` executable is in `pubgrub-cli`, which is not published and has no source distribution there: build it from a checkout of the release's tag, as in [Build](#build) below, with `cabal install exe:pubgrub`.

## Requirements

- **GHC 9.12 or 9.14** and **cabal**. The project builds with `base >=4.21 && <4.23`; CI builds with GHC 9.12.2 and 9.14.1, and cabal 3.18.1.0.
- **A `ghc` on your `PATH`.** The solver reads that compiler's global package database
  and treats its boot packages as installed. This is what pins `base`.
- **Network access on the first run.** The Hackage package index is downloaded and
  verified into a local `_cache/` directory through `hackage-security`. Later runs
  reuse the cache and refresh it at most weekly.

## Build

```sh
cabal build all
cabal test all                                                        # see Test below
cabal run pubgrub-index -- --index-state "$(cat bench/index-state)"   # optional but recommended, a few minutes, once per pin
```

`pubgrub-index` parses every release on Hackage into a derived index, after which
reading a release is a CBOR (Concise Binary Object Representation) decode rather than a
`.cabal` parse. It is a cache: without it the solver parses on demand and gets the same
answers, more slowly. It serves a release only at the revision in force at the
index-state it was built at, so a run parses on demand whatever was published or revised
after that. The command above builds at the pin the gate and the harness run at. For
solves against the head of the index, leave out `--index-state`, and run it again after
a weekly refresh. A non-zero `read N .cabal files` on the last line of a solve is the
tell.

## Run

```sh
cabal run exe:pubgrub -- [-v|--verbose] [--stats] [--plan tree|lines] [--cabal]
                         [--index-state TIMESTAMP] [--flags fixed|search]
                         [--constraint 'PKG RANGE'] TARGET...
```

A **target** is a package name with an optional version range, as *one* argument. Give
more than one to solve for them together.

```sh
cabal run exe:pubgrub -- hashable            # any version
cabal run exe:pubgrub -- 'aeson >=2'         # constrained (one argument: quote it)
cabal run exe:pubgrub -- hlint 'aeson <2'    # two targets, solved together
cabal run exe:pubgrub -- -v 'aeson <2'       # ... plus the solver's search trace
cabal run exe:pubgrub -- --stats aeson       # ... plus search counts and phase timings, no trace
cabal run exe:pubgrub -- --cabal aeson       # cabal's own solver, over the same index
cabal run exe:pubgrub -- --constraint 'aeson <2' pandoc   # a range aeson must be in if it is chosen
cabal run exe:pubgrub -- --index-state 2026-09-03T00:00:00Z aeson   # the index as it was then
```

`--cabal` runs cabal's modular solver, from `cabal-install-solver`, instead of ours, fed
through **the same `withWorld`**, which opens the index, the installed database and the
`pkg-config` database for either solver. That is what makes the comparison
apples-to-apples rather than arranged.

### A successful solve

```
Solving for hashable
Solution:
hashable 1.5.1.0
├─ base 4.21.0.0 (installed)
│  ├─ ghc-internal 9.1202.0 (installed)
│  ...
├─ bytestring 0.12.2.0 (installed) (*)
...
read 0 .cabal files, decoded 3 from the derived index, served 23 repeat lookups from cache
```

Each target is a root of the tree, and each node shows the decided *instance*: an
installed unit as such, or a source release, with the automatic flags it was decided
under when `--flags search` is on. `(*)` marks a subtree already printed higher up.

The search tries the installed unit first, then the newest source release in range that
can be built here. `base`, `template-haskell` and the other packages tied to the compiler
are never built from source.

### A failed solve

The failure output is a **proof**, not a search trace:

```
No solution for lens <4: template-haskell is pinned to 2.23.0.0 (installed);
    base is pinned to 4.21.0.0 (installed).
No version of array suits lens <3.10 unless base >=4.2 && <4.7.

Because template-haskell is pinned to 2.23.0.0 (installed) and lens <2.4
    depends on template-haskell >=2.4 && <2.8, lens <2.4 is forbidden.
And because lens >=1.4 && <3.10 depends on array >=0.3.0.2 && <0.5, lens <3.10
    requires array >=0.3.0.2 && <0.5.
And because array >=0.3.0.1 && <0.4.0.1 depends on base >=4.2 && <4.6,
    lens <3.10 requires array >=0.4.0.1 && <0.5 or base >=4.2 && <4.6.
1. And because array >=0.4.0.1 && <0.5.0.0 depends on base >=4.2 && <4.7 and
    base is pinned to 4.21.0.0 (installed), lens <3.10 is forbidden.

Because base is pinned to 4.21.0.0 (installed) and lens >=3.10 && <4.0
    depends on base >=4.4 && <4.7, lens >=3.10 && <4.0 is forbidden.
And because lens <3.10 is forbidden (1), lens <4.0 is forbidden.
So, because lens <4 is requested, version solving failed.
```

That is 7 sentences where cabal prints 18 lines for the same problem. Across a corpus
of 21 real Hackage failures, every target pinned, we are shorter on all 21: 77
sentences against cabal's 198.

## Test

```sh
cabal test all              # the suites of the three packages that have them, and pubgrub's doctests
scripts/gate.sh             # every check that must not regress, over 27 real problems
cabal run pubgrub-harness   # both solvers over both problem sets; writes bench/output/
```

The suite covers the `VersionSet` laws, the instance-set algebra against an extensional
model, small end-to-end solves, and all six worked examples from the PubGrub spec.

`scripts/gate.sh` is what decides whether a change is kept. `pubgrub-harness`
measures: it runs the `pubgrub` executable as a child process, three times per solver
per problem, and writes the benchmark report and the explanation showcase. See
[`docs/benchmarking.md`](docs/benchmarking.md).

## Documentation

The API documentation of the latest release is at
<https://tweag.github.io/pubgrub-hs/>.

Each [release](https://github.com/tweag/pubgrub-hs/releases) also has the
documentation of `pubgrub` and `pubgrub-cabal`, as
`PACKAGE-VERSION-docs.tar.gz`, in the format Hackage takes.

In this repository:

- [`docs/reports/`](docs/reports/): the benchmark report and the explanation showcase,
  as `pubgrub-harness` generated them.
- [`docs/DESIGN.md`](docs/DESIGN.md): why the solver is built this way, one decision per
  section, with the evidence and what was measured and rejected.
- [`docs/benchmarking.md`](docs/benchmarking.md): how to run the tests and the benchmarks,
  and which numbers to trust.
- [`docs/failure-cases.md`](docs/failure-cases.md): where the failure corpus came from
  and what it does not measure.
- [`docs/pubgrub-intro.md`](docs/pubgrub-intro.md): an introduction to the algorithm, and
  how it differs from cabal's modular solver.
- [`docs/solving-problem.md`](docs/solving-problem.md): the problem cabal's solver
  answers, stated as a specification, including what public sublibraries would need.
- [`references/pubgrub.md`](references/pubgrub.md): a copy of pub's specification of
  PubGrub, the authority on the algorithm.
- [`CONTRIBUTING.md`](CONTRIBUTING.md): how to change the project and make a release.

## Layout

Six packages in one `cabal.project`. `pubgrub` and `pubgrub-cabal` are meant for Hackage.

```
pubgrub/            the solver, written once over any domain: the algorithm, the
                    derivation views, the spec's reporting walker over a Formatter,
                    and version sets. Depends on base, containers, text, co-log-core.
pubgrub-doctest/    pubgrub's doctests, unpublished: a package of their own so that
                    doctest-parallel's Cabal bound stays out of pubgrub.
pubgrub-cabal/      the cabal domain: packages and flags as variables, the facts a
                    .cabal file states, the proof renderer, the .cabal flatten and
                    the rule that picks an instance of a package, over any index and
                    installed set. Of the cabal ecosystem, Cabal-syntax only.
pubgrub-hs/         the Cabal bridge, unpublished: reads the Hackage index, resolves
                    the compiler and installed packages on this machine, feeds them
                    to the provider, and drives cabal's own solver over the same
                    index as the baseline. Its tests are the ones that need it.
pubgrub-cli/        the `pubgrub` driver and the `pubgrub-index` builder, unpublished.
pubgrub-harness/    the `pubgrub-harness` executable, unpublished.
docs/               see Documentation above.
```

## Caveats

**Three deliberate limits**, and any published number has to state them:

- **Every flag is pinned to its declared default** by default, on both sides of the
  comparison. That is a restriction of the problem, not a property of either solver.
  It makes the comparison fair, and it makes some real failures unreachable, because
  cabal's automatic flags are exactly what it would flip to escape one. `--flags
  search` lifts it for automatic flags, in both solvers; the recorded numbers were
  taken without it.
- **We solve one version per package name.** cabal solves qualified goals and can
  legitimately plan two versions of one package, one for the library and one for a
  setup script.
- **The driver does not solve setup and build-tool dependencies, and cabal does.** Each
  release's are read for a caller to solve separately, so on a package with a custom
  `Setup.hs` the two solvers answer different questions.

**Not modelled:** public sublibraries, `preferred-versions`, and a driver option for
user flag constraints (`--constraint 'p +f'`; the library has the seed).

**Reports:** `cabal run pubgrub-harness` writes `bench/output/benchmark.md` (both
solvers over `bench/problems.txt`: medians of three runs, phases, residency,
allocation, search counts and a plan diff) and `bench/output/showcase.md` (both
explanations for every comparable corpus problem, as adjacent blocks, with the
counts). Every header states the environment and the restrictions. `bench/output/` is
git-ignored; a run meant to be quoted is copied into
[`docs/reports/`](docs/reports/) on purpose.
