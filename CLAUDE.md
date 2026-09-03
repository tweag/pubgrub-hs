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

**[`docs/STATUS.md`](docs/STATUS.md) is the current-state document.** What works, why
it is built that way, what is out of scope, and which file decides a question. Before
you change anything, read it.

- **History** is [`docs/decision-log.md`](docs/decision-log.md). **Abandoned
  directions** are [`docs/attic/`](docs/attic/).
- **The algorithm** is `references/pubgrub.md`, a vendored copy of pub's spec. This is
  *the* authority. Is some behaviour fundamental to PubGrub, or a choice of ours?
  Answer that by citing `references/pubgrub.md` with a line number. Do not answer it
  from our haddocks, and do not answer it from CLAUDE.md.
- **Flags** are [`docs/flags-semantics.md`](docs/flags-semantics.md): what must be
  *true*, with no types in it. It overrules this file.
- **Decisions** are [`docs/decision-semantics.md`](docs/decision-semantics.md).
  Nothing in its §2–§9 is implemented.
- **The Lean model** in `specification/` is **a draft and settles nothing.** It is our
  own attempt at formalising PubGrub. Where it disagrees with `references/pubgrub.md`
  or `docs/flags-semantics.md`, those are right and it is wrong.
- **Cabal's build model** (components, scopes, Backpack) is
  [`docs/cabal-build-model.md`](docs/cabal-build-model.md), the reference for rungs 4
  and 5.

**Two citation rules, and both have been broken.**

- **Cite `references/pubgrub.md` by line.** Check the line first. `:596`, `:601`,
  `:640`, `:643` and `:670` are blank, and each has been cited before. As of
  2026-09-03 no citation in the tree lands on a blank line.
- **Cite the Rust reference by function name, not by line.** `references/pubgrub` and
  `references/pubgrub-guide` are nested git repos, so cloning this repository does not
  get them, and their line numbers move with upstream. Write `merge_dependents`, not
  `:173`.

## Build, test, measure

```sh
cabal build
cabal test                           # 177 tests, ~0.3 s
cabal run pubgrub -- aeson           # the driver; add -v for the search trace
cabal run pubgrub -- --stats aeson   # + search counts and phase timings, no trace
cabal run pubgrub -- --cabal aeson   # cabal's solver, same index (the baseline)
cabal run pubgrub-index              # build the derived index (~200 s, once)
scripts/gate.sh                      # every check that must not regress
cabal run pubgrub-harness            # both solvers, both sets; writes bench/output/{benchmark,showcase}.md
scripts/check-stats.sh               # --stats against bench/summarise.awk, every problem
```

**`scripts/gate.sh` decides whether a change is kept.** Nine gates over one pass of
the problem set: problem count, the 17-case failure corpus, verdict agreement over all
23 problems, proof length against cabal's own message, the proof and no-version
totals, the golden proofs, the pkg-config modelling tests, the whole suite, and the
Lean build. One line per gate, non-zero exit on any regression.

It holds five numeric baselines. Only the problem count is exact. The other four are
floors or ceilings rather than targets, and beating one prints `IMPROVED` and still
exits 0. **Move a baseline in the change that earns it.** The two proof ceilings are
currently tight — 61 sentences and 0 no-version lines — so a reporting change has to
earn its way past them.

**[`docs/benchmarking.md`](docs/benchmarking.md) is the reference for measuring
anything.** The short version: counts are deterministic, times are not (±25% on this
desktop), total allocation from `+RTS -s` is the stable stand-in for time, and
`--stats` counts the search in-process, so a quiet run is also a counted one.
`scripts/check-stats.sh` holds it to `bench/summarise.awk`, number for number.

## Architecture

Three layers with a hard dependency boundary. The cabal-install entanglement is
quarantined so the core stays lightweight.

```
pubgrub-hs (library) ──── no cabal-install, no cabal-install-solver
  native PubGrub: Term, VersionSet, Incompatibility, Relation, Solver, Store, Report
  pure algorithm and types. Of the cabal ecosystem it needs Cabal-syntax only
  (plus base, containers, text, co-log)
        ▲  one callback: Provider.expand
bridge (private library) ──── cabal-install-solver, Cabal, Cabal-syntax,
                              hackage-security, http-client
  index acquisition, the derived index, and the translation into the solver's input
  builds a package index and feeds it to BOTH:
    ├─ cabal's modularResolver, via Bridge.Cabal.Baseline   (the baseline)
    └─ our own Provider
        ▲
app/Main.hs — the `pubgrub` driver: --cabal picks the baseline,
              --stats prints counts and phases, --plan lines prints a diffable plan
        ▲
app/Harness.hs — `pubgrub-harness`: runs `pubgrub` as a child process per solver,
                 problem and repetition; writes bench/output/benchmark.md and showcase.md
```

**Seven cabal components:**

| component | what it is |
| --- | --- |
| library `pubgrub-hs` | `src/` — the solver. `PubGrub.hs` plus `PubGrub/{Term,VersionSet,SetOps,Relation,Incompatibility,Solver,Store,Provider,Report,Pretty}.hs`, `PubGrub/Index/PreInstalled.hs`, `PubGrub/InstanceSet{,/SourceCell}.hs` |
| library `bridge` | `bridge/` — `Bridge/{Hackage,Installed,Provider}.hs`, `Bridge/Hackage/{HttpClient,Store,Unlifted}.hs`, `Bridge/Cabal/{Baseline,Flatten,InstalledPkg}.hs` |
| executable `pubgrub` | `app/Main.hs` — the CLI driver |
| executable `pubgrub-index` | `app/BuildIndex.hs` — builds the derived index |
| executable `pubgrub-harness` | `app/Harness.hs` — the harness. Depends on neither library: it drives the `pubgrub` executable as a child, parses its `stats:`, `phases:` and `plan:` lines, and writes the two reports |
| test-suite | `test/` — 11 spec modules plus `test/golden/` |
| executable `index-bench` | `prototype/IndexBench.hs`, **throwaway**. It priced the derived index. Once nothing needs re-pricing, remove it and its stanza |

**What each bridge module does.**

- `Bridge.Hackage` — bootstraps and refreshes the index through `hackage-security`,
  keeps a disk-cached package-to-versions map, and reads one release's `.cabal`
  through `indexLookupCabal` plus `parseGenericPackageDescription`. It marks every
  flag manual on the way out.
- `Bridge.Hackage.Store` — the derived index. Every release parsed once, ahead of
  time, into the pre-environment form.
- `Bridge.Cabal.Flatten` — reads two things off one walk of a conditional tree
  (`flattenWith`): the `build-depends`, and the `BuildInfo` that decides buildability
  (`buildable:` plus `pkgconfig-depends` against the machine's `PkgConfigDb`, library
  only).
- `Bridge.Cabal.Baseline` — drives `Distribution.Solver.Modular.modularResolver` over
  our index. It builds a `PackageIndex (SourcePackage ())`. `modularResolver` runs
  `convPIs` itself.
- `Bridge.Provider` — the real `Provider`. `withWorld` opens the index, the installed
  database and the `pkg-config` database **once**, and both solvers are fed from it.
  That is what makes the comparison structural rather than arranged.

**Dependency boundary.** We avoid `cabal-install` entirely, including for the
baseline. We do depend on `hackage-security`, and there is no `tar` dependency.
`cabal-install-solver` is a dependency of `bridge`, of the `pubgrub` executable and of
the test-suite. It is **not** a dependency of the core library.

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

**`.cabal` revisions need no work.** The index `hackage-security` hands us carries
only the last revision of each release: 152,987 entries, 152,987 distinct, across
19,419 packages.

## Invariants you can break by accident

This is the list of places where the code is not self-evident and a plausible edit is
wrong.

### `InstanceSet` is intensional and non-canonical

The solver's variables are package names. Its values are `Instance`s — one concrete
way of having a package, either a pre-installed unit or a source release under a total
flag assignment.

```haskell
data InstanceSet = InstanceSet
    { isInstalled :: Set PreInstalledPackage   -- extensional: the db is small and known
    , isSource    :: [SourceCell]              -- DNF, NOT canonicalised
    }
data SourceCell = SourceCell VersionSet (Map FlagName FlagPin)
data FlagPin    = PinnedTo Bool | NotDeclared
```

- **Do not add `Eq` or `Ord`.** A non-canonical representation has no lawful
  structural equality. Use `SetOps.equivalent` for semantic equality.
- **`isEmpty` is one-sided.** It can answer "not empty" for a set that is empty in
  fact, because seeing that needs the index. Claiming emptiness wrongly is forbidden.
  Failing to notice it is allowed. Assert `isEmpty ⟹ model empty`, never `⟺`.
- **`SourceCell` has no `SetOps` instance on purpose.** Cells are closed under
  intersection but not under union or difference, so `SetOps` lives one layer up.
- **Pruning between operations is load-bearing.** `differenceCell` drops null cells,
  `union` merges cells with identical pins, and `pruneCells` drops subsumed cells.
  Over 24 instance bans across 4 flags: **28,293 cells with null-dropping alone, 41
  once `pruneCells` runs too.** `test/InstanceSetSpec.hs` is the guard.
- **`pruneCells` gives determinism only.** It is not a preference order. Flag
  preference is `Bridge.Provider.preferDefaults`, which ranks completed assignments by
  how many flags deviate from the declared defaults.
- **The three pin states are required**, not defensive. A two-state pin is not closed
  under negation and silently loses the releases that do not declare the flag. See
  `docs/STATUS.md` §4.3.
- **`test/InstanceSetSpec.hs` needs its universe non-uniform** — releases must differ
  in which flags they declare, including one declaring none. A uniform universe hid a
  wrong `difference` for weeks. Keep its adapter pointed at the **intensional**
  constructor.

### `PubGrub.Store` merges on insert and keeps scan position

Dependency facts about one `(depender, dependee)` pair with an identical dependee term
merge as they arrive. Unbuildable facts about one package merge the same way.

A merge **replaces the existing clause where it already sits**. Clause position
dominates propagation cost here, and prepending new knowledge is load-bearing. An
earlier dedup memo cost 22%.

The merged clause is rebuilt with its own constructor, so its cause stays a **leaf**.
Letting conflict resolution reach the same range instead produces derived nodes, and
those nodes are the proof lines this exists to remove.

### The derived index is a cache

`openStore` answers `Nothing` for a missing, unreadable or stale-format store, and
every miss parses instead. Removing `_cache/derived-index.*` costs speed and never
correctness.

**It does not follow the index.** The Hackage index refreshes itself at most weekly,
and the store checks only its format version, so every release published since it was
built is a miss that parses. Re-run `cabal run pubgrub-index` after a refresh, or
`parses` stops being zero.

**Raise `storeFormatVersion` on any encoding change.** A generic CBOR encoding is
positional, so reordering a constructor silently changes meaning.

**What is stored is the pre-environment form, not the flattened one.** `envConfVar`
resolves `os`, `arch` and `impl` against this machine, and buildability resolves
`pkgconfig-depends` against its `pkg-config` database. If either changes, a flattened
store is silently wrong. `componentDepsAtDefaultsStored` and
`buildableAtDefaultsStored` run the *same* `flattenWith` over the *same* trees as their
description-taking counterparts, so the two paths agree by construction.
`test/StoredSpec.hs` asserts it anyway.

**Note the baseline does not use the store.** `Bridge.Cabal.Baseline` still parses
every release it inspects.

### Memoise the reduced form, never the parse tree

`Bridge.Provider.releaseReader` memoises only what the provider needs: declared flags,
guarded dependencies, and a buildable flag.

Retaining parsed descriptions cost **27.2 s and 904 MB** on `pandoc`, against 3.7 s
and 83 MB uncached. Retained parse trees each pin their slice of the index, and every
major garbage collection copies the lot. **Caching more was 7× slower and 10×
bigger.**

The decoded-slice cache holds **one** package for the same reason.

### A dependency of `p` on `p` is dropped

Real packages declare these constantly, because an executable or sublibrary of `p` is
built against `p`'s library. It is an intra-package edge, not a version constraint.
The rule is cabal's: `Builder.extendOpen` adds no goal and no edge when `qpn == qpn'`.

Two changes are needed and **both** are load-bearing:

- `Bridge.Provider` filters the occurrence out, so no such clause is minted.
- `fromDependency` uses `Map.fromListWith intersectTerm`, so two entries about one
  variable are intersected rather than overwritten.

The second alone makes the clause honest, and an honest clause correctly *bans* the
release, which is still the wrong answer. Tests: `StoreSpec` and `FlagSolveSpec`,
"self-dependencies", each verified to fail without its own half.

### Boot packages are installed-only

`Bridge.Installed.nonReinstallablePackages` is the single list both solvers read.
Such a package offers installed units or nothing. It never falls through to a source
release. Prefer-installed alone let `aeson <2` plan to build `base 4.15.1.0` from
source.

### A depender term names a slot, not a version

`Bridge.Provider.withSlots` gives each release the half-open range up to the next
release present in the index. Adjacent slots **touch**, so unions coalesce and
`difference` stops manufacturing empty holes between published releases. The
**first** release's slot has no lower bound (`references/pubgrub.md:467`), and so
does a walk that reaches it: `slotRange` decides, for both. Nothing is published
below the first release, so the range is the same; its complement has no `<first`
hole to discover and print.

### The synthetic root's name carries a NUL byte

`rootName = mkPackageName "\0root"`. GNU `grep` therefore treats every proof as binary
and reports no matches without `-a`. `scripts/gate.sh` and `scripts/check-stats.sh`
pass `-a` everywhere; the harness reads every child log as bytes. New tooling that
greps a proof will read zero and look like it passed.

## Current scope limits

- **Flags are fixed at their declared defaults.** They are applied, not searched.
  `componentDepsAtDefaults` folds every guard to a literal on our side, and
  `lookupGPD` marks every flag manual on cabal's. One instance per release, on both
  sides. The search machinery is intact, unfed, and still tested. Before you
  touch it, read `docs/STATUS.md` §5.1.
- **One version per package name.** cabal solves qualified goals and can legitimately
  plan two versions of one package. We cannot. This has to be specified before rung 4.
- **No setup or build-tool dependencies** (rung 4) and **no public sublibraries**
  (rung 5).
- **No `preferred-versions`.**
- **No user flag constraints** (`--flag`).

### The rung ladder

Build the end-to-end loop early, then add cabal-model fidelity one rung at a time.
Each rung leaves a runnable solver.

| rung | state |
| --- | --- |
| 0 — index reading on real Hackage data | ✅ |
| 1 — version ranges | ✅ |
| 2 — flags and conditional dependencies | ✅ applied, not searched |
| 3 — `base` and GHC pinning, boot packages installed-only | ✅ |
| — buildability (not a rung) | ✅ |
| 4 — setup and build-tool dependencies | not started |
| 5 — public sublibraries | not started |

**Rung 4 owes two things.** Qualified goals, which were designed and shelved — the
design and why it does not fix self-dependencies are in `docs/STATUS.md` §5.2. And the
setup self-dependency exception: cabal keeps a reverse-dependency edge for a *setup*
self-dependency, so the cycle forces a different setup script.

## Reporting

`PubGrub.Report.reportConflict` walks the cause tree and prints a numbered proof
following the spec's own reporting algorithm (`references/pubgrub.md:504`). Four rules
run, and `docs/STATUS.md` §4.9 states each one with its soundness argument:

1. A chain of two external facts is one sentence.
2. Every other derived step is skipped.
3. A run of steps about the same `(depender, dependee)` pair is one sentence.
4. Empty-range leaves are absorbed into the sibling they were resolved against
   (`collapseNoInstances`).

**The wording is pub's, in cabal's range syntax**, including every special case the
spec lists at `references/pubgrub.md:1010`–`:1030`: "every version of foo", the root
by name alone, "So," on the last line, a period per line, the blank line between
branches. A negative term is never printed as "not …"; the sentence carries the
negation ("P requires N1 or N2", "if P1 and P2 then N1 or N2", "either X or Y").
Installed units print by version, never by unit id, and a boot package's fact names
the version it is pinned to: "base is pinned to 4.21.0.0 (installed)".

**A headline stands above the proof**, from `reportHeadline`: the request as the
proof names it, and the world-fact leaves verbatim — "No solution for matterhorn
==90000.1.1: base is pinned to 4.21.0.0 (installed)." It is not a proof sentence.
The gate and the harness count by connective, so it is never counted, on the same
footing as cabal's "Could not resolve dependencies:" line.

**The driver wraps; the reporter does not.** `wrapProof` wraps at the terminal's
width, or 80 columns off a terminal, with a four-space hanging indent, and never
breaks inside a range (before a `||` only when the range alone overflows the line).
`reportConflict` stays one sentence per line for the golden proofs, and a
continuation line starts with the indent, so the gate and the harness never count it.

**The showcase counts screen lines as well as sentences**: ours as printed at 80
columns, cabal's lines as the 80-column rows each fills. The gate counts sentences.

**Colour is a terminal-only layer.** `styleProof` dims ranges and bolds the
connectives, the headline and the `So,` line; stripping the escapes gives the input
back. The driver applies it only on a terminal with `NO_COLOR` unset and `TERM` not
`dumb`. Every log, the gate and the harness read plain text.

**Do not chase byte-parity with pub's output.** `^1.0.0` is Dart syntax and cabal
writes `>=1.0.0 && <2`. The target is the same sentences and information, in cabal's
range syntax.

**A declared range is quoted as its author wrote it.** `VersionSet` carries the
declared `VersionRange` as a display tag that only `fromVersionRange` sets, every
operation drops, and `Eq`/`Ord` ignore. So `^>=4.13.0.0` prints as `^>=4.13.0.0`, and
a derived range prints canonically. `fillGaps` is in reserve for derived terms only:
filling a declared range would discard its spelling.

**One item is dormant, not closed.** Where cells share a version set and their pins
for one flag exhaust all three states, that flag must drop out of the pin map. No
cell is pinned while flags take their defaults, so no proof can show this. It returns
with the flag axis.

## Conventions

- GHC 9.12.x (`base ^>=4.21`), `cabal-version: 3.8`
- `default-language: GHC2021` on every component, with
  `default-extensions: ImportQualifiedPost`. The test-suite is the one stanza that
  lacks the extension.
- `-Wall` everywhere. Once the API stabilises, treat warnings as errors.
- No partial functions (`head`, `fromJust`). Use pattern matching or `Maybe`/`Either`.
- Prefer `newtype` wrappers over type aliases for domain types.
