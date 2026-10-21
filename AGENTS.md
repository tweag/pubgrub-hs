# pubgrub-hs

A native Haskell implementation of the PubGrub dependency solver, applied as a
proof-of-concept solver for cabal packages.

## What this is

A **proof-of-concept**, not an integration into cabal-install. Solving correctly is
table stakes. The project exists to answer two questions:

1. **Explanations.** Can PubGrub explain a resolution *failure* better than
   cabal-install's solver?
2. **Performance.** Can PubGrub match cabal-install on elapsed time and peak memory,
   on real problems?

The deliverables are two evidence artifacts: an explanation showcase (real failing
problems, side by side) and a benchmark report (time and peak residency).

This is a **native** implementation — unit propagation and conflict resolution in
Haskell. There is no ASP component and there never was.

## Where to look first

**[`docs/STATUS.md`](docs/STATUS.md) is the current-state document.** What works,
what is out of scope, what is planned, what is settled, and which file decides a
question. Before you change anything, read it. **Why it is built that way is [`docs/DESIGN.md`](docs/DESIGN.md)**: one
design decision per section, with the evidence that earned it.

- **History** is not in the tree. The decision log is in the project's Hindsight bank
  (`coding-agent::pubgrub-hs`), one document per decision: `decision-log-index` lists
  the records in order with each era's introduction, `decision-NNNN-<slug>` is one
  record, and `decision-log-dropped-directions` lists the **abandoned directions**.
  Read one with the `hindsight-decisions` skill, and record a new decision the same way.
- **The algorithm** is `references/pubgrub.md`, a vendored copy of pub's spec. This is
  *the* authority. Is some behaviour fundamental to PubGrub, or a choice of ours?
  Answer that by citing `references/pubgrub.md` with a line number. Do not answer it
  from our haddocks, and do not answer it from CLAUDE.md.
- **Flags** are [`docs/flags-as-variables.md`](docs/flags-as-variables.md): an
  automatic flag is a solver variable of its own, keyed by its declaration. The two
  earlier specifications that put the flag inside a package's value are retired
  (Hindsight document `decision-log-dropped-directions`).
- **Cabal's build model** (components, scopes, Backpack) is
  [`docs/cabal-build-model.md`](docs/cabal-build-model.md), the reference for rungs 4
  and 5.

**Three citation rules, and all three have been broken.**

- **Cite nothing external in a Haddock.** The Haddocks of `pubgrub` and
  `pubgrub-cabal` are read on Hackage, where none of this repository can be opened.
  They name no other project (pubgrub-rs, latti, pub, cabal-install's internals), cite
  no spec line, and point at nothing in the harness (`Bridge.*`, `docs/`, the gate,
  test files, decision records). State the rule or the reason itself. The two rules
  below are for plain comments and for answers.
- **Cite `references/pubgrub.md` by line.** Check the line first. `:596`, `:601`,
  `:640`, `:643` and `:670` are blank, and each has been cited before. As of
  2026-09-03 no citation in the tree lands on a blank line.
- **Cite the Rust reference by function name, not by line.** `references/pubgrub` and
  `references/pubgrub-guide` are nested git repos, so cloning this repository does not
  get them, and their line numbers move with upstream. Write `merge_dependents`, not
  `:173`.

## Build, test, measure

```sh
cabal build all
cabal test all                       # 295 tests over the three packages that have them, and pubgrub's doctests
cabal run exe:pubgrub -- aeson              # the driver; add -v for the search trace
cabal run exe:pubgrub -- 'aeson <2'         # a target is ONE argument: package and range
cabal run exe:pubgrub -- hlint 'aeson <2'   # several targets, solved together
cabal run exe:pubgrub -- --stats aeson      # + search counts and phase timings, no trace
cabal run exe:pubgrub -- --cabal aeson      # cabal's solver, same index (the baseline)
cabal run exe:pubgrub -- --flags search aeson   # search the automatic flags, either solver (default: fixed at defaults)
cabal run exe:pubgrub -- --constraint 'aeson <2' pandoc   # a range aeson must be in if chosen, either solver; repeatable
cabal run exe:pubgrub -- --index-state 2026-09-03T00:00:00Z aeson   # the index as it was then, either solver
cabal run pubgrub-index -- --index-state "$(cat bench/index-state)"   # the derived index at the pin (~120 s, once per refresh)
scripts/gate.sh                      # every check that must not regress
cabal run pubgrub-harness            # both solvers, both sets; writes bench/output/{benchmark,showcase}.md
scripts/check-stats.sh               # --stats against bench/summarise.awk, every problem
scripts/check-haddock.sh pubgrub     # no Haddock warning, every export documented (CI runs it)
```

**A target is one argument.** `pubgrub 'aeson <2'`, not `pubgrub aeson '<2'` — the
range holds spaces, and several targets are several arguments. Both problem files
spell a multi-target problem with commas (`hlint, hadolint ==2.15.1`) and the
readers split on commas, never on whitespace. Solving for more than one package is
the only way to reach a conflict *between* two packages rather than between one
package and the compiler. **Every corpus target is pinned to one version**, and the
proof-length record holds only there: an unconstrained target obliges a complete
proof to refute every one of its releases, where cabal prints a search trace that
stops at the first wall, and on such problems our proof is the longer text
(`docs/STATUS.md` §2.2).

**`scripts/gate.sh` decides whether a change is kept.** Eight gates over one pass of
the problem set: problem count, the 20-case failure corpus, verdict agreement over all
26 problems, proof length against cabal's own message, the proof and no-version
totals, the golden proofs, the pkg-config modelling tests, and the whole suite. One
line per gate, non-zero exit on any regression.

Every run in it, and every harness run, is pinned to the index-state in
`bench/index-state`, so the numbers stop moving with the weekly index refresh.
`PUBGRUB_INDEX_STATE=head` (or `pubgrub-harness --index-state head`) runs against
everything the local index holds. **Move the pin in the change that re-measures.**

It holds five numeric baselines. Only the problem count is exact. The other four are
floors or ceilings rather than targets, and beating one prints `IMPROVED` and still
exits 0. **Move a baseline in the change that earns it.** The two proof ceilings are
currently tight — 76 sentences and 0 no-version lines — so a reporting change has to
earn its way past them.

**[`docs/benchmarking.md`](docs/benchmarking.md) is the reference for measuring
anything.** The short version: counts are deterministic, times are not (±25% on this
desktop), total allocation from `+RTS -s` is the stable stand-in for time, and
`--stats` counts the search in-process, so a quiet run is also a counted one.
`scripts/check-stats.sh` holds it to `bench/summarise.awk`, number for number.

## Architecture

Five packages in one `cabal.project`, with a hard dependency boundary. The first two
are meant for Hackage; the other three are this repository's research harness and stay
here. The cabal-install entanglement is quarantined in the third, `pubgrub-hs`, so the solver and its cabal
instantiation stay lightweight, and another tool can drive the solver over its own
index with the two published packages alone.

```
pubgrub (package) ──── base, containers, text, co-log-core. Nothing from the cabal ecosystem
  native PubGrub, written once over a Domain: SetOps, Term, Relation, Incompatibility
  (the Domain class and the core-owned Cause), Store, Provider, Solver, Derivation (the
  views of a derivation), Report (the spec's walker over a Formatter), Pretty, and
  Version/VersionSet as batteries. test: a toy domain that imports none of cabal
        ▲  one callback: Provider.expand; one instance: Domain Cabal
pubgrub-cabal (package) ──── pubgrub, Cabal-syntax, base, containers, text, co-log-core
  the cabal domain (PubGrub.Cabal: Var, Flag, Value, InstanceSet, the facts), the
  renderer (PubGrub.Cabal.Report: the words, the headline, the five rules), the .cabal
  flatten (PubGrub.Cabal.Flatten) with the machine passed in as plain data, the
  installed set (PubGrub.Cabal.Installed), and the provider rule
  (PubGrub.Cabal.Provider.mkExpand) over a ReleaseSource
        ▲  a ReleaseSource and an InstalledDb
pubgrub-hs (package, unpublished) ──── cabal-install-solver, Cabal, hackage-security, http-client
  the bridge: index acquisition, the derived index, the compiler's world on this machine
  builds a package index and feeds it to BOTH:
    ├─ cabal's modularResolver, via Bridge.Cabal.Baseline   (the baseline)
    └─ our own Provider
        ▲
pubgrub-cli (package, unpublished)
  app/Main.hs — the `pubgrub` driver: --cabal picks the baseline,
                --stats prints counts and phases, --plan lines prints a diffable plan,
                --index-state pins the index to a moment, for both solvers
  app/BuildIndex.hs — `pubgrub-index`: builds the derived index
        ▲  a child process
pubgrub-harness (package, unpublished)
  app/Harness.hs — `pubgrub-harness`: runs `pubgrub` as a child process per solver,
                   problem and repetition; writes bench/output/benchmark.md and showcase.md
```

**Five packages, ten components:**

| component | what it is |
| --- | --- |
| `pubgrub` library | `pubgrub/src/` — the solver. `PubGrub.hs` (the public surface) plus `PubGrub/{SetOps,Term,Incompatibility,Provider,Solver,Derivation,Report,Pretty,Version,VersionSet}.hs`, and `PubGrub/Tutorial.hs` and `PubGrub/Cookbook.hs`, modules of documentation only (the tutorial and the how-to guides). The solver's machinery, `PubGrub/{PartialSolution,Relation,Store}.hs`, is not exposed (decision 0068), and `PubGrub.Solver` exports `solve`, `SolveError` and `SolverMsg` only. `cabal check` clean |
| `pubgrub` test-suite | compiles the library's sources itself, so it can test the hidden modules (`PartialSolutionSpec`, `StoreInvariantsSpec`). `pubgrub/test/ToyDomainSpec.hs` — the solver and the walker over `Toy`, a domain that is not cabal's; it imports nothing from `PubGrub.Cabal`, so the core leaning on cabal is a compile error here first. `Toy.hs` is the tutorial's code and `Cookbook.hs` the guides', and `ToyDomainSpec` and `CookbookSpec` fail if a documentation module's code blocks or printed results drift from them (`DocCode.codeMatches`). |
| `pubgrub` test-suite `pubgrub-doctests` | `pubgrub/doctest/Main.hs` — runs the library's `>>>` Haddock examples through `doctest-parallel` (decision 0069). It finds the library through the GHC environment file that `write-ghc-environment-files: always` in `cabal.project` writes, so on a clean tree build before testing |
| `pubgrub-cabal` library | `pubgrub-cabal/src/` — `PubGrub/Cabal.hs` and `PubGrub/Cabal/{Variable,Value,InstanceSet,PreInstalled,Version,VersionSet,Pretty,Flatten,Installed,Provider,Report}.hs`, `PubGrub/Cabal/Report/{Rule,Wording,Headline,Layout}.hs`. Cabal-syntax only. `cabal check` clean |
| `pubgrub-cabal` test-suite | `pubgrub-cabal/test/` — 10 spec modules plus `test/golden/` |
| `pubgrub-hs` library | `pubgrub-hs/src/` — the bridge: `Bridge/{Hackage,Provider}.hs`, `Bridge/Hackage/{HttpClient,Store,Unlifted}.hs`, `Bridge/Cabal/{Baseline,InstalledPkg}.hs` |
| `pubgrub-hs` test-suite | `pubgrub-hs/test/` — the 3 spec modules that need the bridge or `cabal-install-solver` |
| `pubgrub-cli` executable `pubgrub` | `pubgrub-cli/app/Main.hs` — the CLI driver. Name it `exe:pubgrub` to cabal: plain `pubgrub` is the solver package |
| `pubgrub-cli` executable `pubgrub-index` | `pubgrub-cli/app/BuildIndex.hs` — builds the derived index |
| `pubgrub-harness` executable | `pubgrub-harness/app/Harness.hs` — the harness. Depends on neither library: it drives the `pubgrub` executable as a child, parses its `stats:`, `phases:` and `plan:` lines, and writes the two reports |

**What each cabal and bridge module does.**

- `Bridge.Hackage` — bootstraps and refreshes the index through `hackage-security`,
  keeps a disk-cached package-to-versions map, and reads one release's `.cabal`
  through `indexLookupCabal` plus `parseGenericPackageDescription`. Under
  `--flags fixed` the baseline marks every flag manual before cabal sees it.
- `Bridge.Hackage.Store` — the derived index. Every release parsed once, ahead of
  time, into the pre-environment form.
- `PubGrub.Cabal.Flatten` — reads two things off one walk of a conditional tree
  (`flattenWith`): the `build-depends`, and the `BuildInfo` that decides buildability
  (`buildable:` plus `pkgconfig-depends` against a `PkgConfigPresent` predicate, library
  only). The machine is an argument — `Platform`, `CompilerInfo`, the predicate — never
  read here. `componentTools` and `setupDeps` read what a release owes to other
  namespaces off the same walk, and keep it out of `GuardedDeps`. Dependencies come from the four components cabal includes unconditionally —
  library, sublibraries, foreign libraries, executables — and the last three are gated
  on their own `buildable:` through Cabal-syntax's `addBuildableCondition`. Test suites
  and benchmarks are read only when the caller's `Stanzas` ask, per release, the way a
  planner enables them for a local package. The trees are our own `Tree`, and
  `fromCondTree` is the one function that depends on the Cabal-syntax version.
- `Bridge.Cabal.Baseline` — drives `Distribution.Solver.Modular.modularResolver` over
  our index. It builds a `PackageIndex (SourcePackage ())`. `modularResolver` runs
  `convPIs` itself.
- `PubGrub.Cabal.Provider` — the rule: `mkExpand` picks an instance of a package
  (installed first, then the newest buildable source release) and states what it
  entails, over an `InstalledDb` and a `ReleaseSource` (which versions exist, and the
  `Release` of one). `releaseOf` is the reduction of a `GenericPackageDescription` to a
  `Release` (flag model, stanzas, platform, compiler, `pkg-config` predicate), and
  `releaseOfStored` the same over the derived index's form; another tool with its own
  descriptions calls the first, and the bridge's `releaseReader` memoises them over an
  index entry. `PubGrub.Cabal.Installed` is the installed set and its unit graph.
- `Bridge.Provider` — the world on this machine. `withWorld` opens the index, the
  installed database and the `pkg-config` database **once**, and both solvers are fed
  from it. That is what makes the comparison structural rather than arranged.
  `releaseReader` turns an index entry into a `Release`, through the derived index
  where there is one, and `pkgConfigPresent` is the predicate from cabal's own db.

**Dependency boundary.** We avoid `cabal-install` entirely, including for the
baseline. We do depend on `hackage-security`, and there is no `tar` dependency.
`cabal-install-solver` is a dependency of `pubgrub-hs` (the bridge) and its
test-suite, and of the `pubgrub` executable. It is **not** a dependency of `pubgrub` or of
`pubgrub-cabal`, which is what lets latti depend on those two and nothing else, and
what lets them go to Hackage.

**Why `cabal-install` is avoidable.** The `../cabal-solver-plan` reference depends on
it, and tracing its imports shows three uses:

1. **index acquisition** (`IndexUtils`, `RepoContext`) — the only substantial one, and
   we do it ourselves through `hackage-security`.
2. **CLI-convenience types** (`UserConstraint`, `IndexState`, `defaultMaxBackjumps`) —
   trivially replaceable, and most of what `Distribution.Client.Dependency` provides
   actually originates in `cabal-install-solver`'s `Distribution.Solver.Types.*`.
3. **setup-deps types** — needed only at rung 4, and likely reconstructible from
   `setupBuildInfo`.

`UserConstraint` is the one that forces our hand. It is a scope plus a
`PackageProperty`, it lives in `cabal-install`, and it is richer than Cabal-syntax's
version-only `PackageVersionConstraint`. So we define our own constraint type.

**Still to handle: `preferred-versions`.** Neither solver reads it.

**`.cabal` revisions are decided by the index-state.** The version cache
(`Bridge.Hackage`) records every `.cabal` entry in the tar, revisions included, with
its time and block, and a run at `--index-state T` reads each release's last entry at
or before `T` by block. `hackage-security`'s own lookup by name answers with the last
revision in the whole tar, which is right only at the head, so nothing reads through
it any more.

## Invariants you can break by accident

Each of these is a design decision whose argument and evidence are in
[`docs/DESIGN.md`](docs/DESIGN.md). The line here is a reminder of what the plausible
wrong edit is, not the argument. Read the section before you touch the code.

- **A flag is a solver variable, and the value carries no flags** — DESIGN §2 and
  §3. `InstanceSet` is an installed set plus one version range, canonical and
  exact; `Var` is a package name or a `(package, Flag)` pair, and `Flag` is a name
  *with its declared default*. Do not put flags back into the value, and do not key
  a flag variable by release.
- **`PubGrub.Store` merges on insert and keeps scan position** — DESIGN §5. A merge
  replaces the clause where it sits, and the merged clause stays a leaf. Propagation
  judges only the dirty clauses and acts on the newest actionable one; mark every
  change to a variable's term or a clause's terms dirty, or the search changes.
- **The derived index is a cache that follows the index by block** — DESIGN §6. It
  stores the pre-environment form; raise `storeFormatVersion` on any encoding change.
- **Memoise the reduced form, never the parse tree** — DESIGN §11.
- **A dependency of `p` on `p` is dropped**, in two load-bearing halves — DESIGN §8.
- **An unbuildable component contributes no dependencies**, through Cabal-syntax's
  own `addBuildableCondition`; the library is not gated — DESIGN §15.
- **Build tools and `setup-depends` are not dependencies** — DESIGN §16. They ride in
  `Release` as `relTools` and `relSetup` for a planner to solve in a namespace of its
  own, and `mkExpand` tries a `Preference` before installed and newest. Do not fold
  them into `GuardedDeps`.
- **Boot packages are installed-only** — DESIGN §7.
- **A depender term names a slot, not a version**, and the first slot has no lower
  bound — DESIGN §4.
- **A guarded dependency's flag terms are positive and name the depender's own
  flags**, and a fact merges only with one under the same guard — DESIGN §3 and §5.
- **Versions compare with trailing zeros insignificant**, and Cabal's type stops at
  the bridge — DESIGN §14.
- **The request is a list of seeds**: the terminal test, the level-0 backtrack floor
  and the closing step all rest on it — DESIGN §10.
- **Decision order is discovery order**, measured against the spec's — DESIGN §12.

## Current scope limits

[`docs/STATUS.md`](docs/STATUS.md) §3 states each one and why: flags fixed at their
declared defaults unless `--flags search` is given (§3.1), and one version per
package name (§3.2, where the shelved qualified-goals design is). Setup and
build-tool dependencies, public sublibraries, `preferred-versions`, user flag
constraints and buildability under a flag are not built; §4 says what each owes, and
§5 lists what is settled or was measured and rejected. The rung ladder is STATUS.md
§1.

## Reporting

`PubGrub.Report.reportConflict` is the spec's own reporting algorithm
(`references/pubgrub.md:504`), written once over any domain and given its words by a
`Formatter`; `PubGrub.Cabal.Report` is the cabal `Formatter` and the entry point the
driver uses. [`docs/DESIGN.md`](docs/DESIGN.md) §9 states the five
rules with their soundness arguments, the headline, the wrapping and colour layers,
and the wording: pub's sentences in cabal's range syntax, a declared range quoted as
its author wrote it, no byte-parity with pub. Two things there matter to every
change in this area: the gate and the harness count sentences by connective, so a
new line must open with none of them; and the golden proofs are the spec's own
examples, so a wording change earns its way past them.

## Conventions

- GHC 9.12 or 9.14 (`base >=4.21 && <4.23`, CI on 9.14.1); `cabal-version: 3.0` in every package
- `default-language: GHC2021` on every component, with
  `default-extensions: ImportQualifiedPost`. The test-suite is the one stanza that
  lacks the extension.
- `-Wall` everywhere. Once the API stabilises, treat warnings as errors.
- No partial functions (`head`, `fromJust`). Use pattern matching or `Maybe`/`Either`.
- Prefer `newtype` wrappers over type aliases for domain types.
- stylish-haskell formats every Haskell file (`.stylish-haskell.yaml`, version pinned
  in `mise.toml`). Run `mise run format` before committing; CI's `format` job fails
  on an unformatted file.
- Commit messages are Conventional Commits, and releases come from them:
  [`CONTRIBUTING.md`](CONTRIBUTING.md) has the types, the version rule and
  `mise run release-pr`.
