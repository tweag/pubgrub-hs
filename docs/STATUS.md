# Status — where the project is, and what is planned

> **What this is.** What the repository contains now: what works, what is out of
> scope, what is planned, what is settled, and which document decides a question. Why
> the solver is built the way it is, with the evidence, is [DESIGN.md](DESIGN.md).
>
> **What this is not.** Not a specification. The table in
> [Which document decides](#6-which-document-decides) names the file that owns each
> question. If this file disagrees with one of those files, that file is right.
>
> **History is not here, and not in the tree.** The decision log is in the project's
> Hindsight bank, one document per decision: `decision-log-index` lists the records in
> order, and `decision-log-dropped-directions` lists the directions that were dropped.
>
> **Last run on 2026-11-04.** The test suites and
> [`scripts/gate.sh`](../scripts/gate.sh) passed, at the index-state pinned in
> [`bench/index-state`](../bench/index-state), `2026-09-09T02:42:09Z`.

---

## 1. What works today

| area | state |
| --- | --- |
| Packages | `pubgrub` (the solver, over any domain) and `pubgrub-cabal` (the cabal domain) are separate packages with `cabal check` clean, ready for Hackage and not yet uploaded. `pubgrub` exports its API and none of the solver's machinery (decision 0068), and its documentation is a tutorial (`PubGrub.Tutorial`), how-to guides (`PubGrub.Cookbook`) and a reference with no Haddock warning, whose code and examples the tests run; four unpublished packages keep the doctests (`pubgrub-doctest`), the bridge (`pubgrub-hs`), the driver (`pubgrub-cli`) and the harness (`pubgrub-harness`) ([DESIGN.md §1](DESIGN.md#1-the-core-knows-nothing-about-cabal)) |
| Hackage index | our own reader over the cached `01-index.tar`, through `hackage-security`. No `cabal-install` dependency |
| Index-state | `--index-state T` gives both solvers the index as it was at `T`, revisions included, with cabal's semantics. A run prints the state it is really at |
| Derived index | every release parsed once into `_cache/derived-index.cbor`. A read is a decode of CBOR (Concise Binary Object Representation), served only for the revision in force |
| Version ranges | full. The solver resolves real packages end to end |
| Constraints | `--constraint 'p R'`, repeatable, for both solvers: a range `p` must be in if it is chosen. A second seed kind in the core (`constraint`, and `flagConstraint` for a flag held at a value), and `conflictSet` reads the variables of a failed solve's derivation ([DESIGN.md §10](DESIGN.md#10-the-request-is-a-list-of-seeds)) |
| Version order | ours, not Cabal's: trailing zeros are insignificant, so `1.2` and `1.2.0.0` are one version. Cabal's type stops at the bridge ([DESIGN.md §14](DESIGN.md#14-versions-compare-with-trailing-zeros-insignificant)) |
| Flags | fixed at their declared defaults by default; `--flags search` makes every automatic flag a solver variable, on both sides ([§3.1](#31-flags-are-fixed-at-their-declared-defaults-unless-asked)) |
| Boot packages | the installed database becomes instances. A non-reinstallable package, such as `base` or `template-haskell`, offers installed units or nothing; any other tries its installed unit first and can fall back to source ([DESIGN.md §7](DESIGN.md#7-boot-packages-are-installed-only)) |
| Buildability | a release whose library cannot be built here is not offered, and the proof says why: the `pkg-config` module that is missing, by name, or `buildable: False`. Under `--flags search` a library unbuildable only under some flag value is offered, and that value is banned by a guarded clause the proof states as "foo with +sys needs pkg-config package zlib, which is not found" ([DESIGN.md §15](DESIGN.md#15-a-component-that-is-not-buildable-contributes-no-dependencies)) |
| Test suites and benchmarks | read only when the reduction is asked, per release (`releaseOf` takes a `Stanzas`): a planner enables them for a local package and never for a dependency, as cabal's does; the driver passes none ([DESIGN.md §15](DESIGN.md#15-a-component-that-is-not-buildable-contributes-no-dependencies)) |
| Explanations | `PubGrub.Report` prints a proof that follows the spec's own reporting algorithm |
| cabal baseline | `pubgrub --cabal <target>` runs cabal's modular solver over the same index |
| Regression gate | `scripts/gate.sh` runs 27 problems through both solvers and fails on any regression |
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
| 4 — setup and build-tool dependencies | built as what a release owes to another namespace, not as goals of the main solve ([§4.1](#41-setup-and-build-tool-dependencies-rung-4)) |
| 5 — public sublibraries | not started ([§4.2](#42-public-sublibraries-rung-5)) |

---

## 2. The numbers

Measured by `pubgrub-harness` on 2026-11-04 at index-state `2026-09-09T02:42:09Z`:
one desktop, GHC 9.12.4, medians of three runs, no trace. The two reports as generated are in
[reports/](reports/). Read
[benchmarking.md](benchmarking.md) before you quote any figure below. The short version:
counts are deterministic, elapsed time moves by ±25% between runs, and total
allocation is the stable stand-in for time.

### 2.1 Against cabal, on the benchmark set

`pubgrub-harness` over [`bench/problems.txt`](../bench/problems.txt). Residency is
`maximum residency` from `+RTS -s`. Times are seconds, medians of three. Bold marks
the better of the two. `sat` means a plan exists, and `UNSAT` that none does.

| problem | verdict | ours | cabal | our world / solve | cabal world / index / solve | our residency | cabal residency | our allocation | cabal allocation | our proof | cabal's message |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `vector` | both sat | **0.87** | 1.31 | 0.82 / 0.02 | 0.80 / 0.16 / 0.32 | **29.2** | 75.6 MB | **0.49** | 1.05 GB | — | — |
| `pandoc` | both sat | **1.25** | 1.98 | 0.85 / 0.37 | 0.82 / 0.15 / 0.95 | **50.4** | 93.8 MB | **0.93** | 1.99 GB | — | — |
| `conduit <1.3` | both UNSAT | **0.86** | 1.52 | 0.81 / 0.01 | 0.80 / 0.16 / 0.51 | **29.2** | 75.6 MB | **0.50** | 1.52 GB | **9** | 12 |
| `lens <4` | both UNSAT | **0.93** | 1.71 | 0.84 / 0.04 | 0.80 / 0.17 / 0.62 | **29.2** | 75.6 MB | **0.55** | 2.08 GB | **7** | 18 |
| `aeson <2` | both UNSAT | **0.90** | 2.70 | 0.77 / 0.11 | 0.80 / 0.18 / 1.68 | **29.2** | 95.6 MB | **0.57** | 5.62 GB | 38 | **26** |
| `yesod` | both sat | **1.34** | 2.13 | 0.78 / 0.54 | 0.88 / 0.19 / 1.04 | **50.1** | 96.3 MB | **1.10** | 2.12 GB | — | — |

All six verdicts agree. We use **1.9–3.3× less peak memory on all six**, are 1.5–3×
faster and allocate 1.9–9.9× less.

**The phases say where our time goes, and it is not the solve.** Opening the world
(the index, the installed database and the pkg-config database) costs about 0.8 s on
both sides, which is most of our elapsed time on every row. Our solve is under 0.2 s on
four of the six problems, `pandoc`'s 0.37 s is reads rather than search, and `yesod`'s
0.54 s is the only one with real search in it. cabal's `index` phase is small because the work it names is lazy and lands
in its `solve` ([§2.3](#23-what-these-numbers-do-not-establish)).

**`yesod` is where we have the most left to gain, and it is the most useful row in the
table.** It is the only *satisfiable* problem in the set with real search in it:
`vector` and `pandoc` resolve almost straight through. Our lead there is the smallest
on allocation, at 1.9×.

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
in force at the index-state the store was built at and served only for that revision,
so a store built at the head of the index leaves a pinned run to parse every release
revised since the pin — 18 of them on this set, a month after the pin — and a run at the
head parses everything published or revised after the store's state. Pinned runs are
unaffected by a refresh. Build with
`pubgrub-index --index-state` at the pin in `bench/index-state`, as this run was, and
a non-zero `parses` is the tell that it was not.
Reading the index at an index-state costs the world phase about 0.16 GB of
allocation and 2 MB of residency on every run
([DESIGN.md §13](DESIGN.md#13-the-index-is-read-at-an-index-state)), which is visible on the smallest
rows and nowhere else.

**The plan diff finds one known gap and nothing else.** On the three satisfiable
problems our plan is a *subset* of cabal's, and the two agree on every package they
share: 38, 190 and 180. cabal's plans for `pandoc` and `yesod` additionally carry
`Cabal`, `Cabal-syntax` and `hsc2hs`, and for `pandoc` also `alex`, `cabal-doctest`,
`happy` and `happy-lib`. Every one is a setup or build-tool dependency, rung 4.

**We carry nothing cabal's plans do not.**

**The three kinds of problem are not interchangeable.** `vector` and `pandoc` measure
index throughput, and `pandoc` has one conflict, so neither can show a search
improvement. `conduit <1.3`, `lens <4` and `aeson <2` measure search on an
unsatisfiable problem. `yesod` measures search on a satisfiable one. A change that
helps only one kind is not a change that helps.

### 2.2 Against cabal, on the failure corpus

21 real failures, every target pinned to one version: 17 harvested from Hackage's
build reports, three found by solving pairs of popular packages together, each of
which resolves alone, and one from a scan of the index for a release its own dependency
excludes. [failure-cases.md](failure-cases.md) has the methods, the
six failure kinds, and the per-problem table.

**We are shorter than cabal on all 21: 77 proof sentences against cabal's 198.** No
`no version for …` line is left anywhere in the corpus. `scripts/gate.sh` holds both
totals as ceilings. Measured on 2026-11-04 at the pinned index-state.

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

- **The memory floor is unexplained.** Every solve pays about 29 MB before it does any
  work of its own, of which about 2 MB is the index-state read
  ([DESIGN.md §13](DESIGN.md#13-the-index-is-read-at-an-index-state)). The package-to-versions map
  does not explain it: doubling the map's per-element overhead moved peak residency
  by 0.5%. The memory claim is the strongest one the project
  has, and most of it is a number nobody can account for. Settle this first
  ([§4.5](#45-open-questions)).

  What sits *above* the floor is understood: the memoised reduced forms, so residency
  tracks how many releases a solve read. That is why `pandoc` and `yesod` sit at
  about 50 MB.
- **cabal's index work is not separated from its solve, and cannot be.** The `world`
  phase — index open, installed database, pkg-config database — is separated on both
  sides. The two solvers then do different index work: ours decodes a release when it
  expands a package; cabal's resolver wants a record for all of about 153,500 releases before
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
- **Verdict agreement covers these 27 problems, not every package.**

---

## 3. What is deliberately out of scope

### 3.1 Flags are fixed at their declared defaults, unless asked

By default flags are parsed and applied, not searched: a release's dependencies are
the ones its own declared defaults select. `--flags search` makes every *automatic*
flag a solver variable, for both solvers; manual flags stay at their defaults either
way. The model is [flags-as-variables.md](flags-as-variables.md).

Both solvers are told, and each takes it differently:

- **ours, at flatten time.** `PubGrub.Cabal.Flatten.componentDepsStored` resolves
  every manual flag — every flag, under `fixed` — against the release's defaults, so
  a guard that reaches the provider mentions automatic flags only.
- **cabal's, at the index build.** Under `fixed`, `Bridge.Cabal.Baseline.sourcePackageIndex`
  marks every flag manual, so cabal's `enforceManualFlags` prunes every branch whose
  value is neither the default nor named by a user flag constraint. We pass no flag
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

**What the search still owes** is [§4.4](#44-what-flag-search-still-owes).

### 3.2 One version per package name

Our decisions are per package name. One solve yields one version of `mtl`.

cabal solves **qualified goals**, so each executable and each setup dependency gets
its own domain. `Setup.hs` is an executable that is never linked against the library,
so it can be built against a different `mtl`.

A cabal plan can therefore name one package twice at the same version, once installed
and once to be built. That is the two domains showing through after `convCP` strips
the qualifiers from the identities. **Read a cabal plan by component**, or a flat list
will look like a contradiction.

Qualified goals were designed and then shelved. The finding that shelved it is
the decision record `decision-0029-a-package-depending-on-itself-pinned-a-whole-solve`.
Three points from the design survive:

- the scope belongs on the **variable**, not on the instance. A release of `mtl` is
  the same release in either scope, so `incompTerms` becomes `Map QPN (Term
  InstanceSet)`.
- **override-rather-than-nest is load-bearing.** cabal limits itself to one qualifier
  because nesting "very quickly leads to infinite search trees".
- it does **not** fix self-dependencies. `qualifyDeps`'s `inheritedQ` gives a library
  dependency its depender's qualifier, so `qpn == qpn'` under any qualifier scheme.

Setup and build-tool dependencies (rung 4) are read but not solved, and public
sublibraries (rung 5) are not built. What each owes is [§4](#4-what-is-planned).

---

## 4. What is planned

What rungs 4 and 5 still owe, what is specified and not built, and the questions
still open. **Beyond what [§4.1](#41-setup-and-build-tool-dependencies-rung-4) and
[§4.3](#43-specified-not-built) say exists, assume none of it is in the code.**

### 4.1 Setup and build-tool dependencies (rung 4)

Built in a shape decided by the planner that consumes this solver rather than by
cabal's: **a build tool or a `Setup.hs` is another namespace's problem,
and the main solve reads neither.** `PubGrub.Cabal.Flatten.componentTools` reads
`build-tool-depends` and the legacy `build-tools` cabal knows how to translate off the
same four component trees as `componentDeps`, flag-guarded and gated on buildability
the same way, minus the release's own executables; `setupDeps` reads
`setup-depends`. Both ride in `Release` (`relTools`, `relSetup`) and in the derived
index, and `GuardedDeps` does not contain them. A planner
seeds a solve of its own from them, with the main plan's choices as a
`PubGrub.Cabal.Provider.Preference`, tried before installed and newest
([DESIGN.md §16](DESIGN.md#16-build-tools-and-setup-dependencies-are-another-namespaces)).

What this leaves: the driver solves neither namespace, so our plan still lacks the
`alex`, `happy`, `hsc2hs` and `Cabal` cabal's plans carry ([§2.1](#21-against-cabal-on-the-benchmark-set)),
and the comparison on that point is of two different questions. Qualified goals stay
shelved ([§3.2](#32-one-version-per-package-name)): nothing here needs them. The setup
self-dependency exception cabal keeps
([DESIGN.md §8](DESIGN.md#8-a-dependency-of-p-on-p-is-checked-not-solved)) belongs to whoever solves
the setup namespace.

### 4.2 Public sublibraries (rung 5)

Not started. [cabal-build-model.md](cabal-build-model.md) is the reference, and
[solving-problem.md](solving-problem.md) §1.2 and §1.4 state named libraries and the
dependencies that select them.

### 4.3 Specified, not built

| thing | specification | note |
| --- | --- | --- |
| **User flag constraints** (`--constraint 'p +f'`) | [flags-as-variables.md](flags-as-variables.md) §6 | the seed exists, `PubGrub.Cabal.flagConstraint`, a level-0 constraint on the flag variable. No driver option parses one yet, and the baseline is passed none |
| **`preferred-versions`** | — | the index reader does not read it. Its entries are in the tar with timestamps, so an index-state would apply to it unchanged |

### 4.4 What flag search still owes

Flag search is built, behind `--flags search` ([§3.1](#31-flags-are-fixed-at-their-declared-defaults-unless-asked),
[flags-as-variables.md](flags-as-variables.md)): every automatic flag is a solver
variable, both solvers search them, and the gate agrees 27/27 under either model.
What is left is in [flags-as-variables.md §6](flags-as-variables.md): user flag
constraints, a dedicated sentence for a derived step that names a flag, and a
measured answer to whether flags should be decided right after their owner. The gate's recorded baselines are for `fixed`; moving them to `search`
means re-measuring the corpus, where two problems become solvable.

### 4.5 Open questions

1. **What does the 29 MB memory floor consist of?** It is the first thing to settle,
   because the memory claim is the strongest one the project has and the floor is most
   of it. See [§2.3](#23-what-these-numbers-do-not-establish).
2. **Should `expand` split back into "pick" then "consequences"?** The reference Rust
   implementation keeps them as two methods. A design item, not a decision; the
   flag-variable model made it cheaper to leave as is, since a release's consequences
   do not depend on an assignment.
3. **Decision order is chosen by discovery, and on `yesod` that costs about 4.6
   decisions per package, against 1.4 on `pandoc`.** Diagnosed, not fixed — see
   [DESIGN.md §12](DESIGN.md#12-decision-order-is-discovery-order-and-yesod-is-the-bill).
4. **How far can the walk go?** It is unbounded today, so widening reads the whole
   version list in the worst case. A cap stays sound, because maximality of the span
   is policy rather than a requirement. Nothing has chosen one
   ([collapsing.md](collapsing.md)).

Still owed on the documentation side: vendor the Rust checkout properly, or extract
the cited functions into a note ([§6](#6-which-document-decides)).

---

## 5. Settled and rejected

A list of what not to do only works where it is re-read, so both lists live here.

### 5.1 Settled — not planned, do not reopen

Each of these was decided with reasons recorded, and revisiting it has already cost
time.

- **No complement in the value algebra.** Four operations plus emptiness. Negation
  lives in `Term` as a polarity flip. A complement needs a universe of values that
  nothing in the algorithm ever asks for.
- **Sets stay intensional.** An extensional `Set Instance` is not a cheaper PubGrub. It
  is the encoding PubGrub exists to avoid.
- **A flag is a variable keyed by its declaration, and the value carries no flags.**
  The conditional existence a flag variable needs is one clause from its owner
  (`declaresFlag`), not machinery; what putting flags in the value bought with a
  disjunctive normal form of cells and three pin states, this gets from `VersionSet`
  and a `Bool`. Do not key a flag variable by release: that loses the cross-release
  merge for nothing.
- **The provider never answers "nothing available" for a set that admits a value.**
  The one obligation of the retired flag-in-value specification that survives as a
  live requirement. Under the variable model a release has exactly one instance, so
  the completeness it asked for holds by construction.
- **Emptiness over a finite sample is one-sided.** A range is non-empty in version
  space while holding none of a test universe's versions, so a sampled property can
  only check `isEmpty ⟹ empty`. The algebra itself is exact.
- **Do not chase byte-parity with pub's output.** `^1.0.0` is Dart. cabal writes
  `>=1.0.0 && <2`. Same sentences, cabal's syntax.
- **No answer-set programming (ASP) component.** An early plan to encode solving for Clingo was dropped before
  any code existed. A generic solver's explanations are not PubGrub's explanations,
  and explanation quality is half the point ([related-work.md](related-work.md) §6).

### 5.2 Measured and rejected

Each is recorded so nobody re-derives it.

**Narrowing declared ranges to published versions.** `PubGrub.Cabal.Provider.widenTo` puts a
declared range into a term verbatim, so version space no release occupies survives.
Narrowing it with `snapToVersions`, measured on 2026-09-03, moves the search in both
directions (`aeson <2` 400 to 320 decisions and
11.6% less allocation, `yesod` 827 to 839 decisions and 11.7% more) and it rewrites
every quoted range in a closed form nobody wrote, down to the user's own `lens <4`
printing as `lens >=0.1 && <=3.10.3` on the proof's last line. The second is the
objection, and it holds at any price. Pub never narrows; pubgrub-rs offers
`Ranges::simplify` and its solver never calls it. `snapToVersions` is kept, tested
and unused.

Its interior half, `PubGrub.VersionSet.fillGaps`, merges the holes between a range's
intervals that hold no published release and never moves an outer bound. Measured the
same day: every search counter identical on eight problems, allocation within noise,
one proof line changed (`haddock`'s seven `^>=` windows into `>=4.13.0.0 && <4.20`; since [DESIGN.md §14](DESIGN.md#14-versions-compare-with-trailing-zeros-insignificant) those windows coalesce on construction, and the declared spelling is what prints).
It is kept in reserve for *derived* terms, which nobody wrote. Applying it to a
declared range would discard the author's spelling, which [DESIGN.md](DESIGN.md) §2 keeps.

**The fewest-versions decision heuristic.** `references/pubgrub.md:446` suggests
deciding the package with the fewest versions first. It cuts `futhark` decisions by
5.2× and lengthens proofs from 66 to 95 sentences. Measured and reverted.

**Reopened by `yesod`**, which is satisfiable and therefore prints no proof at all, so
the reason for reverting does not apply to it. See
[DESIGN.md §12](DESIGN.md#12-decision-order-is-discovery-order-and-yesod-is-the-bill).

**Testing the range before reading the release in the provider's scan.** `scan`
reads each release of a package, newest first, and tests whether the offered range
admits it only after the read, so a target pinned to an old release reads every
newer one on its first scan. Reading only the admitted releases was proposed by the
2026-10-27 external review and measured the same day at the pin: decodes over the 26
problems and `haskell-language-server` under flag search went 21,663 to 21,481,
−0.8%, and none at all on the three large problems, because a later scan's
out-of-range reads are memo hits already. The gate passed, and it was still
rejected: the first scan of a package states the unbuildable fact of *every* release
it reads, and the store merges those into one clause over the whole run.
`haskoin-store-data` lost that — its headline went from `secp256k1-haskell >=0.1.6
needs pkg-config package libsecp256k1` once to the same reason three times, one per
slot the solver then had to ask about, and the search went 123 to 219 decisions. The
eager read is explanation work, not waste.

**Indexing a release's occurrences for the neighbour walk.** `carries`, the test
the walk puts to each neighbour, searches every guarded group's list for the
dependency, and `Eq Dependency` compares the whole range. The 2026-10-20 profile put
those comparisons at 19% of `haskell-language-server`'s time, and the 2026-10-27
external review proposed a per-release index. Built as a lazy map from package name
to occurrences on `Release`, measured the same day at the pin over ten interleaved
runs: search identical; mutator time median 0.723 → 0.735 s on HLS under flag search
(0%), 0.615 → 0.596 s on `yesod` (−3%), 0.421 → 0.371 s on `pandoc` (−12%); and
allocation +2.8%, +3.9% and +4.9%, for the map each neighbour builds. Not kept: the
one problem that gains is the one that is nearly all walk, HLS gains nothing, and
allocation is the metric that holds still. **The 19% was the profiler's.** The same
cost-centre profile taken on 2026-10-27 shows `Eq Dependency` with `elem` at 13% of
HLS's profiled time and 16% of `yesod`'s, in a run whose profiled time is 2.8× its
real mutator time; the clock puts the comparisons under 5% on HLS. A share of a tiny
function read off a cost-centre profile is an upper bound, and not a close one.

**Re-judging only what a backtrack moved** is in the solver, and the corpus alone
would not justify it (decision 0070). After a conflict, propagation re-judges the
clauses of the variables the backtrack moved, the learned clause and the clauses of
the variable it derives, or the whole store when those variables mention as many
clauses as it holds. Over the problem set that gives the same search and cuts the
post-backtrack judgements by 23% (46% on `haskell-language-server`), and allocation
moves by under 0.1%: a judgement is too cheap for the count to matter. What justifies
it is a synthetic chain of shallow backjumps, the regime the corpus lacks: there a
whole-store re-judge is quadratic in the number of conflicts. The numbers for both
regimes are in [DESIGN.md §5](DESIGN.md#5-dependency-facts-collapse-in-two-places).

---

## 6. Which document decides

**Each row is authoritative on its own subject.** The list is not a ranking. The
specifications mostly do not overlap.

| file | authoritative on | status |
| --- | --- | --- |
| [`references/pubgrub.md`](../references/pubgrub.md) | **the algorithm.** A vendored copy of pub's spec | tracked, 1233 lines. Reference — never edit. Before you cite a line, check it: citations have landed on blank lines |
| [flags-as-variables.md](flags-as-variables.md) | **flags**: an automatic flag as a solver variable, what the provider emits, what it was measured against | current |
| [`../CLAUDE.md`](../CLAUDE.md) | build commands, architecture, conventions | current |
| [`../CONTRIBUTING.md`](../CONTRIBUTING.md) | formatting, commit messages, the release process | current |
| [DESIGN.md](DESIGN.md) | **why the solver is built this way**: one design decision per section, with the evidence behind it | current |
| [collapsing.md](collapsing.md) | **depender collapsing**: what runs, what it costs, and the five ways to make it cheaper | current |
| [benchmarking.md](benchmarking.md) | **how to run the tests and benchmarks**, and which numbers to trust | current |
| [failure-cases.md](failure-cases.md) | **the failure corpus**: where it came from and what is in it | current |
| [reports/](reports/) | the two reports **as generated** by `pubgrub-harness`, each dated in its header | generated. Regenerate with `cabal run pubgrub-harness` and copy; do not edit |
| [solving-problem.md](solving-problem.md) | **cabal's dependency solving problem**, stated: inputs, solutions, validity, and the three extensions | specification of cabal's problem, not of our code. Reference for rungs 4 and 5 |
| [cabal-build-model.md](cabal-build-model.md) | Cabal's **build model** — components, qualifiers, Backpack | reference for rungs 4 and 5. Qualifiers, public sublibraries and Backpack are not implemented |
| [pubgrub-intro.md](pubgrub-intro.md) | a tutorial introduction to PubGrub | current |
| [related-work.md](related-work.md) | external literature mapped onto our problems | a reading map. Authoritative on nothing |
| the decision records in the Hindsight bank (`decision-log-index`) | project history, and the directions that were dropped | narrative. Authoritative on nothing |
| this file | current state, what is planned, what is settled | a summary. The rows above decide |

### How much of the authority is in the repo

**Only `references/pubgrub.md` is tracked.** `jj file list references` returns that
one path. `references/` sits in `.git/info/exclude`, which is a local and unshared
exclude, so the spec was force-added and nothing else under `references/` was.

| under `references/` | tracked? | citations |
| --- | --- | --- |
| `pubgrub.md` — pub's spec | ✅ tracked | by line |
| seven documents on answer-set solving and package management (PDF, five with a `.md` transcription) | ❌ | prose only, from [related-work.md](related-work.md) and [flags-as-variables.md](flags-as-variables.md) |
| `pubgrub/` — the Rust implementation | ❌ a nested git repo | by function name |
| `pubgrub-guide/` — the internals guide | ❌ a nested git repo | not cited by line |
| `pub/` — Dart's pub itself | ❌ a nested git repo | not cited |

Two rules follow, and both have been broken.

**Cite the Rust by function name, not by line.** Cloning this repository does not get
that checkout, and its line numbers move with upstream. `merge_dependents` and
`collapse_no_versions` survive a rebase. `:173` does not.

**Check a `pubgrub.md` line before you cite it.** Citations have landed on blank
lines before: `:596`, `:601`, `:640`, `:643` and `:670` are all empty. The real
anchors are `:595` (reporting case 1), `:651` (case 2.ii), `:668` and `:671` (case
3), and `:673`–`:675` (the numbering rule).

---

## 7. Deliverable status

| deliverable | state |
| --- | --- |
| **Explanation showcase** — real failing problems, pubgrub-hs against cabal, side by side | **the problem set exists and we win on all of it, and all of it is pinned.** 21 real failures with every target pinned, six failure kinds, four positive controls. Shorter than cabal on 21 of 21: 77 proof sentences against 198. Shorter on two of the three benchmark unsat problems. Both of the spec's published examples are golden tests, and the linear one matches sentence for sentence. `pubgrub-harness` renders the two explanations as adjacent blocks for the 17 comparable problems, and the 2026-11-04 run is [reports/showcase.md](reports/showcase.md): shorter on 17 of 17 by sentences, 60 against 155 lines; on screen lines at 80 columns 161 against 346, shorter on 16 and equal on one. **On an unconstrained target the record inverts** ([§2.2](#22-against-cabal-on-the-failure-corpus)), and no such problem is in the corpus or the showcase |
| **Benchmark report** — time and peak residency on real problems | **current numbers exist** for six problems, three sat and three unsat, both solvers. We use less peak memory, are faster and allocate less on all six. The 2026-11-04 run is [reports/benchmark.md](reports/benchmark.md). Its caveats: timings are medians of three runs against ±25% noise, cabal's lazy per-release parsing lands in its `solve` phase and cannot be separated without changing the work, and the 29 MB memory floor is unexplained |

The baseline and the shared index are done. `cabal-install-solver` drives cabal's
resolver from the same `withWorld`, which is what makes the comparison
apples-to-apples rather than arranged.

The gate decides and the harness measures, and neither replaces the other.
`scripts/gate.sh` runs both solvers over all 27 problems once and fails on any
regression in verdict agreement or proof length. `pubgrub-harness` runs them three
times, diffs the plans, separates the phases, and writes the two reports. The harness
drives the `pubgrub` executable as a child process, once per solver, problem and
repetition, because peak residency is a per-process number and two solvers in one
process could not be compared on memory; how it was planned and where the build
differed is the decision record `decision-0035-one-command-produces-both-deliverables`.

**One thing both deliverables must state outright.** The recorded numbers were taken
with every flag pinned to its declared default (`--flags fixed`). That makes the
comparison fair, because neither side can flip a flag to escape. It also makes some
real failures unreachable. A benchmark or a showcase that does not say which flag
model it ran is misleading, however honest its numbers are.
