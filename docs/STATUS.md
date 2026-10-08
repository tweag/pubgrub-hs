# Status — where the project is

> **What this is.** What the repository contains now: what works, what is out of
> scope, and which document decides a question. Why the solver is built the way it
> is, with the evidence, is [DESIGN.md](DESIGN.md). What is planned is
> [TODO.md](TODO.md).
>
> **What this is not.** Not a specification. The table in
> [Which document decides](#4-which-document-decides) names the file that owns each
> question. If this file disagrees with one of those files, that file is right.
>
> **History is not here.** [decision-log.md](decision-log.md) records how the project
> got here, in order. [attic/](attic/) holds the directions we dropped.
>
> **Checked against the tree on 2026-09-22.** 233 tests pass and
> [`scripts/gate.sh`](../scripts/gate.sh) passes, at the index-state pinned in
> [`bench/index-state`](../bench/index-state), `2026-09-09T02:42:09Z`.

---

## 1. What works today

| area | state |
| --- | --- |
| Hackage index | our own reader over the cached `01-index.tar`, through `hackage-security`. No `cabal-install` dependency |
| Index-state | `--index-state T` gives both solvers the index as it was at `T`, revisions included, with cabal's semantics. A run prints the state it is really at |
| Derived index | every release parsed once into `_cache/derived-index.cbor`. A read is a CBOR decode, served only for the revision in force |
| Version ranges | full. The solver resolves real packages end to end |
| Version order | ours, not Cabal's: trailing zeros are insignificant, so `1.2` and `1.2.0.0` are one version. Cabal's type stops at the bridge ([DESIGN.md §14](DESIGN.md#14-versions-compare-with-trailing-zeros-insignificant)) |
| Flags | fixed at their declared defaults by default; `--flags search` makes every automatic flag a solver variable, on both sides ([§3.1](#31-flags-are-fixed-at-their-declared-defaults-unless-asked)) |
| Boot packages | the installed database becomes instances. A boot package offers installed units or nothing |
| Buildability | a release whose library cannot be built here is not offered, and the proof says why: the `pkg-config` module that is missing, by name, or `buildable: False` |
| Explanations | `PubGrub.Report` prints a numbered proof that follows the spec's own reporting algorithm |
| cabal baseline | `pubgrub --cabal <target>` runs cabal's modular solver over the same index |
| Regression gate | `scripts/gate.sh` runs 26 problems through both solvers and fails on any regression |
| Harness | `pubgrub-harness` measures both solvers over both sets, three runs each, and writes `bench/output/benchmark.md` and `showcase.md`. It measures; the gate decides |

**The rung ladder.** The end-to-end loop was built first, and cabal-model fidelity
is added one rung at a time; each rung leaves a runnable solver.

| rung | state |
| --- | --- |
| 0 — index reading on real Hackage data | built |
| 1 — version ranges | built |
| 2 — flags and conditional dependencies | built, behind `--flags search` ([§3.1](#31-flags-are-fixed-at-their-declared-defaults-unless-asked)) |
| 3 — `base` and GHC pinning, boot packages installed-only | built |
| — buildability (not a rung) | built |
| 4 — setup and build-tool dependencies | not started ([TODO.md §1.1](TODO.md#11-setup-and-build-tool-dependencies-rung-4)) |
| 5 — public sublibraries | not started ([TODO.md §1.2](TODO.md#12-public-sublibraries-rung-5)) |

---

## 2. The numbers

Measured by `pubgrub-harness` on 2026-10-08 at index-state `2026-09-09T02:42:09Z`:
one desktop, GHC 9.12.4, medians of three runs, no trace. The two reports as generated are in
[reports/](reports/). Read
[benchmarking.md](benchmarking.md) before you quote any figure below. The short version:
counts are deterministic, elapsed time moves by ±25% between runs, and total
allocation is the stable stand-in for time.

### 2.1 Against cabal, on the benchmark set

`pubgrub-harness` over [`bench/problems.txt`](../bench/problems.txt). Residency is
`maximum residency` from `+RTS -s`. Times are seconds, medians of three. Bold marks
the better of the two.

| problem | verdict | ours | cabal | our world / solve | cabal world / index / solve | our residency | cabal residency | our allocation | cabal allocation | our proof | cabal's message |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `vector` | both sat | **0.35** | 0.69 | 0.33 / 0.02 | 0.34 / 0.10 / 0.23 | **27.0** | 72.3 MB | **0.55** | 1.04 GB | — | — |
| `pandoc` | both sat | **0.81** | 1.14 | 0.33 / 0.47 | 0.30 / 0.10 / 0.70 | **43.8** | 103.3 MB | **1.80** | 1.97 GB | — | — |
| `conduit <1.3` | both UNSAT | **0.37** | 1.12 | 0.35 / 0.01 | 0.45 / 0.15 / 0.49 | **27.0** | 72.3 MB | **0.54** | 1.50 GB | **9** | 12 |
| `lens <4` | both UNSAT | **0.61** | 1.89 | 0.51 / 0.10 | 0.68 / 0.21 / 1.00 | **27.0** | 72.3 MB | **0.68** | 2.06 GB | **7** | 18 |
| `aeson <2` | both UNSAT | **1.06** | 2.23 | 0.64 / 0.41 | 0.42 / 0.14 / 1.61 | **27.0** | 93.1 MB | **1.18** | 5.60 GB | 38 | **26** |
| `yesod` | both sat | 2.53 | **1.61** | 0.44 / 2.06 | 0.42 / 0.13 / 1.00 | **43.5** | 100.2 MB | 5.07 | **2.10** GB | — | — |

All six verdicts agree. We use **2.3–3.4× less peak memory on all six**. We are faster
on five of six and allocate less on five of six. The host carried a load of about 2
from `lens` onwards on this run, which is why those rows are slower on both sides
than `vector`, `pandoc` and `conduit`, and than the same rows a quarter of an hour
earlier; residency and allocation did not move, and they carry the comparison.

**The phases say where our time goes, and it is not the solve.** Opening the world
(the index, the installed database and the pkg-config database) costs 0.3–0.35 s on
a quiet run, on both sides. Our solve is under 0.2 s on four of the six problems, and
`pandoc`'s half second is reads, not search. Only `yesod` has a solve phase that
matters. cabal's `index` phase is small because the work it names is lazy and lands
in its `solve` ([§2.3](#23-what-these-numbers-do-not-establish)).

**`yesod` is where we lose, and it is the most useful row in the table.** cabal is
1.6× faster on it and allocates 2.4× less. It is the only *satisfiable* problem in the
set with real search in it: `vector` and `pandoc` resolve almost straight through.
Every other row is either a walk-through or an unsatisfiable proof, so until `yesod`
was enabled the set could not report this at all.

It is diagnosed: **half its decisions re-derive a prefix that was already correct**,
because decisions are ordered by discovery rather than by the spec's heuristic. See
[DESIGN.md §12](DESIGN.md#12-decision-order-is-discovery-order-and-yesod-is-the-bill).

Our search counts on the same run:

| problem | decisions | conflicts | no-version events | releases decoded | `.cabal` parses |
| --- | --- | --- | --- | --- | --- |
| `vector` | 38 | 0 | 0 | 102 | 0 |
| `pandoc` | 265 | 1 | 0 | 2831 | 0 |
| `conduit <1.3` | 15 | 8 | 1 | 174 | 0 |
| `lens <4` | 64 | 23 | 2 | 268 | 0 |
| `aeson <2` | 319 | 58 | 0 | 367 | 0 |
| `yesod` | 828 | 14 | 0 | 3248 | 0 |

Every parse count is zero because the derived index answers every read
([DESIGN.md §6](DESIGN.md#6-the-derived-index-makes-a-read-a-decode)). That holds only
while the store holds the revision a run wants: each entry is stored at the revision
in force when the store was built and served only for that revision, so a store built
at the head of the index leaves a pinned run to parse every release revised since the
pin — 18 of them on this set, a month after the pin — and a refresh leaves every
release published since the build to be parsed. Build with
`pubgrub-index --index-state` at the pin in `bench/index-state`, as this run was, and
a non-zero `parses` is the tell that it was not.
Reading the index at an index-state costs the world phase about 0.16 GB of
allocation and 2 MB of residency on every run
([DESIGN.md §13](DESIGN.md#13-the-index-is-read-at-an-index-state)), which is visible on the smallest
rows and nowhere else. The changes that moved these counts, the first-release slot
rule ([DESIGN.md §4](DESIGN.md#4-a-release-owns-a-slot-not-a-point)), the version order
([DESIGN.md §14](DESIGN.md#14-versions-compare-with-trailing-zeros-insignificant)), the buildability
gate ([DESIGN.md §15](DESIGN.md#15-a-component-that-is-not-buildable-contributes-no-dependencies))
and the seeds ([DESIGN.md §10](DESIGN.md#10-the-request-is-a-list-of-seeds), one
decision fewer everywhere), each record their before-and-after where they are
described.

**The plan diff finds one known gap and nothing else.** On the three satisfiable
problems our plan is a *subset* of cabal's, and the two agree on every package they
share: 38, 190 and 180. cabal's plans additionally carry `Cabal`, `Cabal-syntax` and
`hsc2hs`, and for `pandoc` also `alex`, `cabal-doctest`, `happy` and `happy-lib`.
Every one is a setup or build-tool dependency, rung 4.

**We carry nothing cabal's plans do not** — until 2026-09-10 `pandoc` carried
`network-bsd`, `network-run` and `time-manager` and `yesod` five more, every one of
them out of an executable stanza marked `buildable: False`
([DESIGN.md §15](DESIGN.md#15-a-component-that-is-not-buildable-contributes-no-dependencies)).

**The three kinds of problem are not interchangeable.** `vector` and `pandoc` measure
index throughput, and `pandoc` has one conflict, so neither can show a search
improvement. `conduit <1.3`, `lens <4` and `aeson <2` measure search on an
unsatisfiable problem. `yesod` measures search on a satisfiable one. A change that
helps only one kind is not a change that helps.

### 2.2 Against cabal, on the failure corpus

20 real failures, every target pinned to one version: 17 harvested from Hackage's
build reports, and three found by solving pairs of popular packages together, each
of which resolves alone. [failure-cases.md](failure-cases.md) has the methods, the
six failure kinds, and the per-problem table.

**We are shorter than cabal on all 20: 76 proof sentences against cabal's 193.** No
`no version for …` line is left anywhere in the corpus. `scripts/gate.sh` holds both
totals as ceilings. Measured on 2026-10-08 at the pinned index-state.

`cabal-install ==3.18.1.0` is the widest margin at 2 sentences against 12. `yesod
==1.6.2.3, aeson ==2.3.1.0` is the narrowest at 9 against 11.

**What the corpus does not measure: an unconstrained target.** The three pair
problems were found by pinning *every* target to its latest release. The same
sweep with one target left unconstrained gave 23 failures, and we were the longer
text on 21 of them, at 28 to 113 sentences against cabal's 10 to 26. The cause is
structural: refuting an unconstrained target means refuting every one of its
releases, so the proof walks the target's whole version history, where cabal's
message is a search trace that may stop at the first wall it hit and reports a
backjump limit on 4 of the 23. Rule 4 of the reporter
([DESIGN.md §9](DESIGN.md#9-the-report-follows-the-specs-reporting-algorithm)) was built from that
sweep and took the three longest from 46, 65 and 63 sentences to 34, 54 and 46,
and it is not enough. Those problems are not in the corpus, so nothing gates them,
and a sentence count against cabal's trace is not the right measure for them: the
trace explains one release and the proof explains all of them. The showcase needs
a completeness column before it can render such a problem fairly.

### 2.3 What these numbers do not establish

- **The memory floor is unexplained.** Every solve pays about 27 MB before it does any
  work of its own, of which about 2 MB is the index-state read
  ([DESIGN.md §13](DESIGN.md#13-the-index-is-read-at-an-index-state)). The package-to-versions map
  was long assumed to dominate that floor. Doubling the map's per-element overhead
  moved peak residency by 0.5%. The memory claim is the strongest one the project
  has, and most of it is a number nobody can account for. Settle this first.

  What sits *above* the floor is understood: the memoised reduced forms, so residency
  tracks how many releases a solve read. That is why `pandoc` and `yesod` sit at
  about 43 MB.
- **cabal's index work is not separated from its solve, and cannot be.** The `world`
  phase — index open, installed database, pkg-config database — is separated on both
  sides. The two solvers then do different index work: ours decodes a release when it
  expands a package; cabal's resolver wants a record for all 152,987 releases before
  it starts, and its `index` phase is only the eager allocation of those records. The
  `PackageIndex` and every `.cabal` parse are lazy and land in cabal's `solve` phase.
  Forcing them earlier would make a solve pay for releases it never touches, which
  changes what is measured.
- **The times are medians of three runs**, against ±25% noise on this machine. Three
  is enough for a median and not for a spread, and the report quotes none.
- **Both solvers run with every flag pinned to its declared default**, the
  `--flags fixed` default. That is a restriction of the problem, not a property of
  either solver, and the numbers here were taken under it. See
  [§3.1](#31-flags-are-fixed-at-their-declared-defaults-unless-asked).
- **cabal solves setup and build-tool dependencies and we do not.** On a package with
  a custom `Setup.hs` the two solvers answer different questions.

---

## 3. What is deliberately out of scope

### 3.1 Flags are fixed at their declared defaults, unless asked

By default flags are parsed and applied, not searched: a release's dependencies are
the ones its own declared defaults select. `--flags search` makes every *automatic*
flag a solver variable, for both solvers; manual flags stay at their defaults either
way. The model is [flags-as-variables.md](flags-as-variables.md).

Both solvers are told, and each takes it differently:

- **ours, at flatten time.** `Bridge.Cabal.Flatten.componentDepsStored` resolves
  every manual flag — every flag, under `fixed` — against the release's defaults, so
  a guard that reaches the provider mentions automatic flags only.
- **cabal's, at the index build.** Under `fixed`, `Bridge.Cabal.Baseline.sourcePackageIndex`
  marks every flag manual, so cabal's `enforceManualFlags` prunes every branch whose
  value is neither the default nor named by a user constraint. We pass no user
  constraints. Under `search` the descriptions are left as written.

Both solvers see one index either way, which is what keeps the comparison structural.

**Two consequences for anyone reading a number taken under `fixed`.** A manual flag
is not *weak*, so cabal's `deferWeakFlagChoices` stops deferring the flags that
influence dependencies. That perturbs cabal's goal ordering, not only its flag values.
And an automatic flag is exactly what cabal would have flipped to escape an
unsatisfiable dependency, so some problems that resolve under `search` do not under
`fixed` — two of the twenty corpus cases ([flags-as-variables.md §5](flags-as-variables.md)).
Both solvers fail together, which is what makes the comparison fair. It is still a
restriction of the problem, and any published result must say which model it ran.

**What the search still owes.** Buildability is judged at the declared defaults, so a
release unbuildable only under some assignment is treated as buildable; user flag
constraints (`--flag`) do not exist; and the gate's recorded baselines are for
`fixed` ([TODO.md §3](TODO.md#3-flag-search)).

### 3.2 One version per package name

Our decisions are per package name. One solve yields one version of `mtl`.

cabal solves **qualified goals**, so each executable and each setup dependency gets
its own domain. `Setup.hs` is an executable that is never linked against the library,
so it can be built against a different `mtl`.

A cabal plan can therefore name one package twice at the same version, once installed
and once to be built. That is the two domains showing through after `convCP` strips
the qualifiers from the identities. **Read a cabal plan by component**, or a flat list
will look like a contradiction.

Qualified goals were designed and then shelved. The design is in
[decision-log.md](decision-log.md). Three points from it survive:

- the scope belongs on the **variable**, not on the instance. A release of `mtl` is
  the same release in either scope, so `incompTerms` becomes `Map QPN (Term
  InstanceSet)`.
- **override-rather-than-nest is load-bearing.** cabal limits itself to one qualifier
  because nesting "very quickly leads to infinite search trees".
- it does **not** fix self-dependencies. `qualifyDeps`'s `inheritedQ` gives a library
  dependency its depender's qualifier, so `qpn == qpn'` under any qualifier scheme.

Setup and build-tool dependencies (rung 4) and public sublibraries (rung 5) are not
built. What each owes is [TODO.md §1](TODO.md#1-the-next-rungs).

---

## 4. Which document decides

**Each row is authoritative on its own subject.** The list is not a ranking. The
specifications mostly do not overlap.

| file | authoritative on | status |
| --- | --- | --- |
| [`references/pubgrub.md`](../references/pubgrub.md) | **the algorithm.** A vendored copy of pub's spec | tracked, 1233 lines. Reference — never edit. Before you cite a line, check it: several later citations land on blank lines |
| [flags-as-variables.md](flags-as-variables.md) | **flags**: an automatic flag as a solver variable, what the provider emits, what it was measured against | current |
| [`../CLAUDE.md`](../CLAUDE.md) | build commands, architecture, conventions | current |
| [DESIGN.md](DESIGN.md) | **why the solver is built this way**: one design decision per section, with the evidence behind it | current |
| [collapsing.md](collapsing.md) | **depender collapsing**: what runs, what it costs, and the five ways to make it cheaper | current |
| [benchmarking.md](benchmarking.md) | **how to run the tests and benchmarks**, and which numbers to trust | current |
| [failure-cases.md](failure-cases.md) | **the failure corpus**: where it came from and what is in it | current |
| [harness-plan.md](harness-plan.md) | **the harness**: why it is shaped that way, and where the build differed | current |
| [reports/](reports/) | the two reports **as generated** by `pubgrub-harness`, each dated in its header | generated. Regenerate with `cabal run pubgrub-harness` and copy; do not edit |
| [cabal-build-model.md](cabal-build-model.md) | Cabal's **build model** — components, qualifiers, Backpack | reference for rungs 4 and 5. Nothing implemented |
| [pubgrub-intro.md](pubgrub-intro.md) | a tutorial introduction to PubGrub | current |
| [related-work.md](related-work.md) | external literature mapped onto our problems | a reading map. Authoritative on nothing |
| [TODO.md](TODO.md) | **what is planned**, and what is settled or rejected and is not | current |
| [decision-log.md](decision-log.md) | project history | narrative. Authoritative on nothing |
| this file | current state | a summary. The rows above decide |

### The two retired specifications

[attic/flags-semantics.md](attic/flags-semantics.md) and
[attic/decision-semantics.md](attic/decision-semantics.md) specified the earlier
model, in which a package's value carried a total flag assignment and its sets were
a DNF of cells. They were retired on 2026-10-08 when flags became variables
([flags-as-variables.md](flags-as-variables.md), [DESIGN.md §3](DESIGN.md#3-a-flag-is-a-variable-and-a-decision-is-one-variables-value)).
Their obligation letters (O1–O7, D1–D3) are still cited in older text; the one that
survives as a live requirement is O6, which now reads: the provider must never answer
"nothing available" for a set that admits a value, and under the variable model a
release has exactly one instance, so the completeness it asked for holds by
construction.

### How much of the authority is in the repo

**Only `references/pubgrub.md` is tracked.** `git ls-files references/` returns that
one path. `references/` sits in `.git/info/exclude`, which is a local and unshared
exclude, so the spec was force-added and nothing else under `references/` was.

| under `references/` | tracked? | citations |
| --- | --- | --- |
| `pubgrub.md` — pub's spec | ✅ tracked | the original 13 line numbers are exact |
| two ASP papers (PDF) | ❌ | prose only |
| `pubgrub/` — the Rust implementation | ❌ a nested git repo | 8 of 9 exact at revision `4dbe916` |
| `pubgrub-guide/` — the internals guide | ❌ a nested git repo | not cited by line |
| `pub/` — Dart's pub itself | ❌ a nested git repo | not cited |

Two rules follow, and both have been broken.

**Cite the Rust by function name, not by line.** Cloning this repository does not get
that checkout, and its line numbers move with upstream. `merge_dependents` and
`collapse_no_versions` survive a rebase. `:173` does not.

**Check a `pubgrub.md` line before you cite it.** Citations have landed on blank
lines before: `:596`, `:601`, `:640`, `:643` and `:670` are all empty. The real
anchors are `:595` (reporting case 1), `:651` (case 2.ii), `:668` and `:671` (case
3), and `:673`–`:675` (the numbering rule). Every citation in the tree was checked on
2026-09-03, and none lands on a blank line.

Still owed: vendor the Rust checkout properly, or extract the cited functions into a
note.

---

## 5. Deliverable status

| deliverable | state |
| --- | --- |
| **Explanation showcase** — real failing problems, pubgrub-hs against cabal, side by side | **the problem set exists and we win on all of it, and all of it is pinned.** 20 real failures with every target pinned, six failure kinds, five positive controls. Shorter than cabal on 20 of 20: 76 proof sentences against 193. Shorter on two of the three benchmark unsat problems. Both of the spec's published examples are golden tests, and the linear one matches sentence for sentence. `pubgrub-harness` renders the two explanations as adjacent blocks for the 16 comparable problems, and the 2026-10-08 run is [reports/showcase.md](reports/showcase.md): shorter on 16 of 16 by sentences, 59 against 150 lines; on screen lines at 80 columns 159 against 337, shorter on 15 and equal on one. **On an unconstrained target the record inverts** ([§2.2](#22-against-cabal-on-the-failure-corpus)), and no such problem is in the corpus or the showcase |
| **Benchmark report** — time and peak residency on real problems | **current numbers exist** for six problems, three sat and three unsat, both solvers. We use less peak memory on all six, and are faster and leaner in allocation on five of six. `yesod` is the exception on both. The 2026-10-08 run is [reports/benchmark.md](reports/benchmark.md). Its caveats: timings are medians of three runs against ±25% noise, cabal's lazy per-release parsing lands in its `solve` phase and cannot be separated without changing the work, and the 27 MB memory floor is unexplained |

The baseline and the shared index are done. `cabal-install-solver` drives cabal's
resolver from the same `withWorld`, which is what makes the comparison
apples-to-apples rather than arranged.

The gate decides and the harness measures, and neither replaces the other.
`scripts/gate.sh` runs both solvers over all 26 problems once and fails on any
regression in verdict agreement or proof length. `pubgrub-harness` runs them three
times, diffs the plans, separates the phases, and writes the two reports.

**One thing both deliverables must state outright.** The recorded numbers were taken
with every flag pinned to its declared default (`--flags fixed`). That makes the
comparison fair, because neither side can flip a flag to escape. It also makes some
real failures unreachable. A benchmark or a showcase that does not say which flag
model it ran is misleading, however honest its numbers are.

