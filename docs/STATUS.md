# Status — where the project is

> **What this is.** The current state of pubgrub-hs. What works, why it is built
> this way, what is out of scope, and which document decides a question.
>
> **What this is not.** Not a specification. The table in
> [Which document decides](#7-which-document-decides) names the file that owns each
> question. If this file disagrees with one of those files, that file is right.
>
> **History is not here.** [decision-log.md](decision-log.md) records how the project
> got here, in order. [attic/](attic/) holds the directions we dropped.
>
> **Checked against the tree on 2026-09-03.** 165 tests pass and
> [`scripts/gate.sh`](../scripts/gate.sh) passes, on the Hackage index refreshed that
> day.

---

## 1. The project in 60 seconds

pubgrub-hs is a proof-of-concept. It is not an integration into cabal-install.
Correct solving is table stakes. The project exists to answer two questions:

1. Can PubGrub explain a resolution failure better than cabal-install's solver?
2. Can PubGrub match cabal-install on elapsed time and on peak memory?

**The solver works.** It resolves real Hackage packages end to end. It handles
version ranges, Cabal flags, buildability, and installed boot packages. All six
worked examples from the PubGrub spec are tests. The two error-reporting examples
assert the printed proof against a golden file.

**Both deliverables are measured and neither is delivered.** We use less peak memory
than cabal on every problem we measure, and our proof is shorter than cabal's message
on 17 of the 17 harvested failures.

Two rows go the other way, and both are worth knowing. cabal is faster on `yesod` and
allocates less there. cabal's message on `aeson <2` is shorter than our proof.

The harness exists. `pubgrub-harness` runs both solvers over both problem sets as
child processes, repeats the runs, diffs the plans, and writes the benchmark report
and the explanation showcase. The two reports it generated on 2026-09-03 are in
[reports/](reports/), and they are the deliverables in their current form.

---

## 2. What works today

| area | state |
| --- | --- |
| Hackage index | our own reader over the cached `01-index.tar`, through `hackage-security`. No `cabal-install` dependency |
| Derived index | every release parsed once into `_cache/derived-index.cbor`. A read is a CBOR decode |
| Version ranges | full. The solver resolves real packages end to end |
| Flags | applied, not searched. Every flag takes its declared default on both sides |
| Boot packages | the installed database becomes instances. A boot package offers installed units or nothing |
| Buildability | a release whose library cannot be built here is not offered, and the solver is told why |
| Explanations | `PubGrub.Report` prints a numbered proof that follows the spec's own reporting algorithm |
| cabal baseline | `pubgrub --cabal <target>` runs cabal's modular solver over the same index |
| Regression gate | `scripts/gate.sh` runs 23 problems through both solvers and fails on any regression |
| Harness | `pubgrub-harness` measures both solvers over both sets, three runs each, and writes `bench/output/benchmark.md` and `showcase.md`. It measures; the gate decides |

Not built: setup and build-tool dependencies (rung 4) and public sublibraries
(rung 5).

---

## 3. The numbers

Measured on 2026-09-03 by `pubgrub-harness`: one desktop, the derived index rebuilt
on the Hackage index refreshed that day, medians of three runs, no trace. The two
reports as generated are in [reports/](reports/). Read
[benchmarking.md](benchmarking.md) before you quote any figure below. The short version:
counts are deterministic, elapsed time moves by ±25% between runs, and total
allocation is the stable stand-in for time.

### 3.1 Against cabal, on the benchmark set

`pubgrub-harness` over [`bench/problems.txt`](../bench/problems.txt). Residency is
`maximum residency` from `+RTS -s`. Times are seconds, medians of three. Bold marks
the better of the two.

| problem | verdict | ours | cabal | our world / solve | cabal world / index / solve | our residency | cabal residency | our allocation | cabal allocation | our proof | cabal's message |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `vector` | both sat | **0.74** | 1.04 | 0.71 / 0.02 | 0.66 / 0.09 / 0.28 | **22.8** | 51.2 MB | **0.41** | 0.86 GB | — | — |
| `pandoc` | both sat | **1.15** | 1.41 | 0.64 / 0.50 | 0.58 / 0.06 / 0.74 | **33.0** | 80.6 MB | **1.49** | 1.79 GB | — | — |
| `conduit <1.3` | both UNSAT | **0.59** | 0.85 | 0.57 / 0.01 | 0.52 / 0.05 / 0.32 | **22.8** | 51.2 MB | **0.39** | 1.33 GB | **10** | 12 |
| `lens <4` | both UNSAT | **0.61** | 1.08 | 0.56 / 0.04 | 0.54 / 0.05 / 0.43 | **22.8** | 76.7 MB | **0.50** | 1.89 GB | **7** | 18 |
| `aeson <2` | both UNSAT | **0.80** | 1.71 | 0.65 / 0.14 | 0.55 / 0.05 / 1.09 | **22.8** | 81.2 MB | **1.01** | 5.43 GB | 62 | **26** |
| `yesod` | both sat | 1.56 | **1.28** | 0.55 / 0.99 | 0.55 / 0.06 / 0.63 | **50.4** | 80.4 MB | 4.35 | **1.93** GB | — | — |

All six verdicts agree. We use **1.6–3.6× less peak memory on all six**. We are faster
on five of six and allocate less on five of six.

**The phases say where our time goes, and it is not the solve.** Opening the world
(the index, the installed database and the pkg-config database) costs 0.55–0.71 s on
every run, on both sides. Our solve is under 0.15 s on five of the six problems. Only
`yesod` has a solve phase that matters. cabal's `index` phase is small because the
work it names is lazy and lands in its `solve`
([§3.3](#33-what-these-numbers-do-not-establish)).

**`yesod` is where we lose, and it is the most useful row in the table.** cabal is
1.2× faster on it and allocates 2.3× less. It is the only *satisfiable* problem in the
set with real search in it: `vector` and `pandoc` resolve almost straight through.
Every other row is either a walk-through or an unsatisfiable proof, so until `yesod`
was enabled the set could not report this at all.

It is diagnosed: **half its decisions re-derive a prefix that was already correct**,
because decisions are ordered by discovery rather than by the spec's heuristic. See
[§4.11](#411-decision-order-is-discovery-order-and-yesod-is-the-bill).

Our search counts on the same run:

| problem | decisions | conflicts | no-version events | releases decoded | `.cabal` parses |
| --- | --- | --- | --- | --- | --- |
| `vector` | 39 | 0 | 0 | 114 | 0 |
| `pandoc` | 270 | 1 | 0 | 2882 | 0 |
| `conduit <1.3` | 19 | 9 | 2 | 182 | 0 |
| `lens <4` | 65 | 23 | 2 | 268 | 0 |
| `aeson <2` | 400 | 68 | 0 | 389 | 0 |
| `yesod` | 827 | 11 | 1 | 3411 | 0 |

Every parse count is zero because the derived index answers every read
([§4.6](#46-the-derived-index-makes-a-read-a-decode)). That holds only while the
store is newer than the index: after the weekly refresh, releases published since are
parsed until `pubgrub-index` is re-run, and a non-zero `parses` is the tell. The
index refresh of 2026-09-03 moved no search count; the decode counts rose by a few,
which is the walk reading releases published since. What did move the three
unsatisfiable rows is the first-release slot rule
([§4.4](#44-a-release-owns-a-slot-not-a-point)), and its cost is recorded there.

**The plan diff finds two known gaps and nothing else.** On the three satisfiable
problems the two plans agree on every package they share: 38, 190 and 180. cabal's
plans additionally carry `Cabal`, `Cabal-syntax` and `hsc2hs`, and for `pandoc` also
`alex`, `happy`, `happy-lib` and `cabal-doctest`. Those are setup and build-tool
dependencies, rung 4. Ours additionally carry packages cabal's do not: on `pandoc`,
`network-bsd`, `network-run` and `time-manager`. Each traces to an executable stanza
of a dependency that is marked `buildable: False` (`tls-server`, `tls-client`,
`crypton-socks-example`). `Bridge.Cabal.Flatten.componentDeps` merges every
executable's dependencies into the package's and reads `buildable:` for the library
only, where cabal plans only the library of a dependency
([§5.3](#53-setup-and-build-tool-dependencies)). `yesod`'s five extra packages have
not each been traced.

**The three kinds of problem are not interchangeable.** `vector` and `pandoc` measure
index throughput, and `pandoc` has one conflict, so neither can show a search
improvement. `conduit <1.3`, `lens <4` and `aeson <2` measure search on an
unsatisfiable problem. `yesod` measures search on a satisfiable one. A change that
helps only one kind is not a change that helps.

### 3.2 Against cabal, on the failure corpus

17 real failures harvested from Hackage's build reports.
[failure-cases.md](failure-cases.md) has the method, the six failure kinds, and the
per-problem table.

**We are shorter than cabal on all 17: 61 proof sentences against cabal's 166.** No
`no version for …` line is left anywhere in the corpus. `scripts/gate.sh` holds both
totals as ceilings. Measured on 2026-09-03. cabal's total moves with the index (it
was 162 on the 2026-08-20 snapshot, and two of its messages grew), ours did not.

`cabal-install ==3.18.1.0` is the widest margin at 2 sentences against 12. `futhark`
is the narrowest at 7 against 10.

### 3.3 What these numbers do not establish

- **The memory floor is unexplained.** Every solve pays about 22 MB before it does any
  work of its own. The package-to-versions map was long assumed to dominate that floor.
  Doubling the map's per-element overhead moved peak residency by 0.5%. The memory
  claim is the strongest one the project has, and most of it is a number nobody can
  account for. Settle this first.

  What sits *above* the floor is understood: the memoised reduced forms, so residency
  tracks how many releases a solve read. That is why `pandoc` is at 33.0 MB and `yesod`
  at 50.4 MB.
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
- **Both solvers run with every flag pinned to its declared default.** That is a
  restriction of the problem, not a property of either solver. See
  [§5.1](#51-flags-are-fixed-at-their-declared-defaults).
- **cabal solves setup and build-tool dependencies and we do not.** On a package with
  a custom `Setup.hs` the two solvers answer different questions.

---

## 4. Why the solver is built this way

Each subsection states a design decision and the evidence behind it. These are the
decisions that are expensive to reverse, or that were reversed once already.

### 4.1 The core knows nothing about Cabal

`pubgrub-hs` depends on `Cabal-syntax`, `base`, `containers`, `text` and `co-log`.
It does not depend on `cabal-install` or on `cabal-install-solver`. The bridge holds
that entanglement, and the bridge is a private library.

The seam is one callback, `PubGrub.Provider.expand`. It takes a package name and the
accumulated constraint on it. It answers with one instance and the incompatibilities
that decision entails.

There is no neutral problem type handed over up front. Building one means reading every
candidate's `.cabal` file, including the ones the search discards.

### 4.2 Version sets are intensional

A dependency's declared range becomes **one** set, not one entry per matching
release. `InstanceSet` is a disjunctive normal form: a list of cells, each a version
range crossed with pinned flags.

This is not a local preference. `references/pubgrub.md:1172` makes it one of the four
things that separate PubGrub from CDCL and from answer-set solving. Expanding a range
into concrete versions costs work, and the result has to be turned back into a range
to talk to a user.

The invoice for that choice:

- **No lawful `Eq`.** Two different cell lists can denote the same set. Use
  `SetOps.equivalent` when you need semantic equality.
- **No enumeration.** `widen` admits versions the index does not have. Only
  `Bridge.Provider.expand'` consults reality, and it enumerates from the index and
  filters by `memberInstance`.
- **Emptiness is one-sided.** `isEmpty` can answer "not empty" for a set that is
  empty in fact. Claiming emptiness wrongly is forbidden. Failing to notice emptiness
  is allowed. The slack lands on `Relation.Inconclusive`, which costs work and never
  a wrong verdict.

**Size control is load-bearing.** `union` appends, `intersect` cross-products, and
`difference` multiplies one cell into up to `1 + 2·|pins|`. Three prunings run:
`differenceCell` drops null cells, `union` merges cells with identical pins, and
`pruneCells` drops cells that another cell subsumes.

Measured over 24 successive instance bans across 4 flags: **28,293 cells with
null-dropping alone, and 41 once `pruneCells` runs too**, for a denotation of 56
instances. Those figures were 1797 and 21 while a pin was a plain `Bool`. Three states
per flag doubled the split factor, so pruning went from useful to the only thing
keeping this tractable.

Pruning **between** operations is what bounds the growth. Pruning at the end is too
late. `test/InstanceSetSpec.hs` is the guard, and it gates the maximum at 48 cells
to leave headroom.

**A version set remembers how it was spelled.** `VersionSet` carries the declared
`VersionRange` it was built from beside its canonical intervals. Only
`fromVersionRange` sets that tag, every operation drops it, `Eq` and `Ord` cannot see
it, and `toVersionRange` hands it back. So a dependency's term prints as its author
wrote it, `^>=4.13.0.0` and not `>=4.13.0.0 && <4.14`, while a derived term, which
nobody wrote, prints canonically. Cabal itself never re-sugars: `fromVersionIntervals`
rebuilds `==v` and nothing else. This is pub_semver's caret class, a plain range that
knows its own spelling; there too the sugar survives exactly as far as the declared
constraint is passed along unchanged. The solver's algebra still runs on intervals.

### 4.3 A decision is a whole instance

The solver's variables are package names. Its values are instances. An instance is
one concrete way of having a package: a pre-installed unit, or a source release under
a total flag assignment.

The flag component needs **three** states per flag, not two: pinned on, pinned off,
and not declared by this release. A two-state pin is not closed under negation.

Two releases show why. `parser 1.0` declares a `simd` flag and `parser 1.1` declares
no flags. Take `A` = "any parser in `>=1.0 && <2`" and `B` = "the same range with
`simd` on". What is in `A` and not in `B`? Two things: `1.0` with `simd` off, and
`1.1`. With only on and off you can say the first and not the second, so `1.1`
silently disappears. The solver then rules out a release that is not ruled out, and
reports "no solution" for a problem that has one.

The rule is: **two states are enough where you decide, three are needed where you
collapse.** A decision fixes one release, so whether the flag exists is already
known. A collapsed term spans releases that disagree about whether the flag exists.

### 4.4 A release owns a slot, not a point

`Bridge.Provider.withSlots` gives each release the half-open range up to the next
release **present in the index**. A dependency fact names that slot as its depender
term, not the single version.

This costs nothing. The package-to-versions map is already resident, and a slot holds
exactly one real release, so the fact asserts nothing about a release nobody read.

The point is that adjacent slots **touch**. `unionVersionSet` coalesces them, so
`difference` stops manufacturing empty holes between published releases.

**The first release's slot has no lower bound.** `references/pubgrub.md:467` omits
the lower bound when the first published version has the dependency, and
`Bridge.Provider.slotRange` does the same for the first release's slot and for a
walk that reaches it. Nothing is published below it, so the range holds the same
releases. What changes is the complement: banning `lens <2.4` leaves nothing, where
banning `lens >=0.1 && <2.4` left `lens <0.1` for the solver to discover empty and
print as `no version for lens in <0.1`.

**Measured over all 23 problems, same binary either side of the rule.** Twenty are
unchanged in every count. It removed the last `no version for` line in the corpus and
shortened `lens <4` and `futhark` by a sentence each. It is a search change too, and
the trade is not one-sided:

| | decisions | conflicts | allocation |
| --- | --- | --- | --- |
| `futhark ==0.27.1` | 807 → **624** | 8 → **6** | 4.02 → **3.14 GB** |
| `atelier-testing ==0.2.0.0` | 9 → **6** | 2 → 2 | 0.39 → 0.38 GB |
| `conduit <1.3` | 16 → 19 | 9 → 9 | 0.39 → 0.39 GB |
| `lens <4` | 60 → 65 | 24 → **23** | 0.50 → 0.50 GB |
| `aeson <2` | 309 → 400 | 58 → 68 | 0.79 → 1.03 GB |

`aeson <2` pays 30% more allocation for a proof two sentences shorter. A wider
depender term changes which conflict the search meets first, and on that problem the
new order is worse. The rule is the spec's and it is kept; the row is here so the
cost is not rediscovered as a regression.

### 4.5 Dependency facts collapse in two places

`references/pubgrub.md:456` requires identical dependencies of adjacent releases of
the depender to be one incompatibility. It asks for
`{foo >=1.0 && <1.3, not bar >=1.0 && <2}`, not one fact per release of `foo`. Two
mechanisms deliver that, and both run.

**At generation time.** `Bridge.Provider.spanningOccurrence` walks out from the
decided release and reads its neighbours. It extends the depender's range while the
*guarded occurrence* is identical — same guard and same dependency, not the whole
dependency set.

**At insert time.** [`PubGrub.Store`](../src/PubGrub/Store.hs) unions the depender
terms of two facts that agree about the dependee, as they arrive. Unbuildable facts
about one package merge the same way, which is `references/pubgrub.md:476`'s half of
the rule.

Merging is sound because the two clauses `¬(p ∈ A ∧ q ∉ R)` and `¬(p ∈ B ∧ q ∉ R)`
together give `¬(p ∈ A∪B ∧ q ∉ R)`. Each half was established separately, so the
union claims nothing new.

**The merged clause is rebuilt as a leaf**, with `fromDependency` or with
`unbuildable`. The alternative is to let conflict resolution reach the same range by
resolving the narrow facts against each other. That produces derived nodes, and those
nodes *are* the proof lines this exists to remove. `conduit <1.3` was once 1061 lines
of pairwise merging.

**A merge replaces the existing clause where it already sits.** Clause position
dominates propagation cost here, so prepending new knowledge is load-bearing.

**The rule is weaker than the spec's, in one direction.** The walk establishes a run
by reading every release in it, so the span is real. A release the walk stopped at is
bounded only by what was read. Propagation cannot tell the difference, because a
release nobody expanded has no clause either way.

**What the walk bought.** One conflict now removes a run of releases instead of one
release at a time:

| | walk off | walk on |
| --- | --- | --- |
| `futhark ==0.27.1` decisions | 4287 | **807** |
| `futhark` conflicts | 53 | **8** |
| `futhark` elapsed | 6.62 s | **2.19 s** |
| `futhark` allocation | 23.1 GB | **3.99 GB** |
| `aeson <2` decisions | 758 | **309** |
| `conduit <1.3` decisions | 137 | **16** |
| `yesod` elapsed | did not finish in 90 s | **2.49 s** |

**What it costs, and who pays.** `pandoc` has one conflict, so the walk buys it
nothing and it pays for the neighbours anyway: 167 reads become 2873. The cost lands on
memory, at 22.6 → 33.1 MB of peak residency. Allocation moves by under 1% and the
elapsed times are inside the noise band. If read-dominated problems ever matter more than search,
`pandoc` is the row to attack, and the lever is walking *less*.
[collapsing.md](collapsing.md) §4 holds the five ways to walk less and what each is
worth.

### 4.6 The derived index makes a read a decode

`cabal run pubgrub-index` parses all 152,987 releases once, in 201 s, and writes
`_cache/derived-index.cbor` (62.5 MB) plus a 0.4 MB package-keyed offset map.
`Bridge.Provider` consults it first and falls back to parsing on any miss.

Four properties to know before you touch
[`Bridge.Hackage.Store`](../bridge/Bridge/Hackage/Store.hs):

- **It is a cache, not a source of truth.** `openStore` answers `Nothing` for a
  missing, unreadable or stale-format store, and every miss parses instead. Removing
  `_cache/derived-index.*` costs speed and never correctness. Raise
  `storeFormatVersion` on any encoding change, because a generic CBOR encoding is
  positional.
- **It does not follow the index.** `openStore` checks the format version and
  nothing else. The Hackage index refreshes itself at most weekly, and every release
  published since the store was built is then a miss that parses. The answers stay
  right, and `parses` stops being zero until `cabal run pubgrub-index` runs again.
- **What is stored is the pre-environment form.** `Flatten.envConfVar` resolves
  `os`, `arch` and `impl` against this machine, and buildability additionally
  resolves `pkgconfig-depends` against its `pkg-config` database. A flattened store
  is silently wrong after a GHC upgrade. Parsing is **106× the cost of flattening**
  (2.007 ms against 0.019 ms). So caching only the parse gives up almost nothing, and
  one store stays valid across toolchains.
- **CBOR, not `binary`.** 410 B per release against 1040, so 62.5 MB against 159 MB.
  `binary` decodes 2.5× faster, but decode stopped being the scarce resource.
- **Granularity is the package, not the release.** One slice holds every version, so
  walking a release's neighbours touches data already decoded. The decoded-slice
  cache holds **one** package. Measured when the walk was off, an unbounded cache cost
  `pandoc` 39.6 MB of peak residency where holding one cost 23.0 MB.

**The derived index does not make a solve faster on its own.** Parsing was 0.3–0.6 s
of runs taking 0.7–6.8 s. Its whole value is that it changed the price of a
*neighbour* read, which is what made [§4.5](#45-dependency-facts-collapse-in-two-places)'s
walk affordable.

### 4.7 Boot packages are installed-only

`base`, `ghc-bignum`, `ghc-internal`, `ghc-prim`, `ghc`, `integer-gmp`,
`integer-simple` and `template-haskell` are non-reinstallable.
`Bridge.Installed.nonReinstallablePackages` is the single list both solvers read: our
provider takes it as a rule in `expand'`, and the baseline takes it as constraints.

It is **a list of names, not a derivation**, and copied verbatim from cabal. How cabal
decides reinstallability is itself in flux, so a snapshot that is obviously a snapshot
is easier to check than a moving target. Note that `rts` is not on cabal's list even
though it is equally unbuildable. We keep the list faithful rather than corrected,
because the baseline has to agree.

Such a package offers installed units or no instances at all. It never falls through
to a source release.

**Prefer-installed is not enough**, and the baseline is what found that. Strict
prefer-installed says what to do when an installed unit is admissible. It says
nothing about a constraint that *excludes* the installed unit, and there we fell
through to Hackage: `aeson <2` resolved by planning to build `base 4.15.1.0` from
source. cabal forbids that, and it is right.

The provider states the rule once, as a unit clause, when it first commits to an
installed unit of such a package. A proof line then reads `base cannot be built from
source`. Before that, the solver rediscovered the same fact once per distinct range,
five times on `aeson <2`, and printed it as `no version for base in >=4.5 && <4.7`.

Stating all eight facts at the root would take `lens <4` to a two-line proof. It was
measured and rejected: it costs `aeson <2` 41% more allocation and 466 more decisions.

### 4.8 A dependency of `p` on `p` is dropped

Real packages declare these constantly, because an executable or sublibrary of `p` is
built against `p`'s library. It is an intra-package edge resolved inside the package.
It is not a version constraint on `p`.

The rule is cabal's. `Builder.extendOpen` adds no goal and no edge when
`qpn == qpn'`, and `not $ isInternal pkg exeDep` does the same for build tools.

Two changes were needed and both are load-bearing:

- `Bridge.Provider` filters the occurrence out, so no such clause is minted.
- `fromDependency` uses `Map.fromListWith intersectTerm`, so two entries about one
  variable are intersected rather than overwritten.

The second one alone makes the clause honest, and an honest clause correctly *bans*
the release, which is still the wrong answer. Without it, `Map.fromList` kept the
last binding, and `lens 1.7`'s `lens ==1.7` became the unconditional
`{lens: Negative ==1.7}` — "lens must be exactly 1.7", asserted of every instance.
That pinned a whole solve and became the unexplained first premise of its proof.

Rung 4 owes the one exception. cabal's `Builder.extendOpen` keeps a reverse-dependency
edge for a *setup* self-dependency, so the cycle forces a different setup script.
There are no setup dependencies yet, so there is no edge to keep.

### 4.9 The report follows the spec's reporting algorithm

`PubGrub.Report.reportConflict` walks the cause tree and prints a numbered proof. It
follows `references/pubgrub.md:504` rather than replaying the derivation tree one node
per line. Four rules do the work.

1. **A chain of two external facts is one sentence** (`:1018`): "foo depends on bar
   ^2.0.0 *which depends on* baz ^3.0.0". Its sibling form is "depends on *both* X and
   Y", where two facts share a depender.
2. **Every other derived step is skipped** (`:530`, case 2.ii at `:651`). Where a
   step's derived cause has a single derived cause of its own, the intermediate
   conclusion goes unsaid. Most derivation graphs here are linear chains, so this rule
   halves them.
3. **A run of same-pair steps is one sentence.** Where a proof walked a dependency's
   bound history one adjacent pair at a time, `oneDerived` finds the maximal run of
   chain steps about the same `(depender, dependee)` pair and states them once, as
   their union. This is sound because each fact says `p ∈ Sᵢ` requires `q ∈ Rᵢ`, so
   `p ∈ ⋃S` requires `q ∈ ⋃R`.
4. **Empty-range leaves are absorbed** (`collapseNoInstances`). Intensional ranges
   mean the solver separately learns that a range's holes are empty, and
   `no version for bar in >2.0.0 && <3` used to clutter the proof. pubgrub-rs runs the
   same post-pass as `DerivationTree::collapse_no_versions`.

Every fusion is guarded by a subset test, so a fused sentence cannot claim more than
the two facts do. One-sided `isEmpty` means a guard can only decline to fuse. It can
never fuse wrongly.

**Rule 4 looks cosmetic and is not.** The `no version for …` siblings were what
*stopped* rule 1 from firing.
Each dependency fact was paired with a hole-is-empty fact instead of with the next
dependency fact. Once the siblings were absorbed, rule 1 appeared in **14 of the 17**
harvested problems. It had only ever been seen in the spec's own worked example.

**Rule 4 recomputes nothing, and that is its soundness argument.** Resolving a unit
clause `{p ∈ r}` against a dependency fact on the pivot `p` unions the two terms about
`p` and leaves the other side alone. The step's conclusion already *is* that
dependency with `p`'s term adjusted, so the node keeps its terms and is re-labelled.
`test/ReportSpec.hs` asserts that property directly, because a printed proof cannot
show it.

Three cases are left alone on purpose: two holes as both causes, a wholly empty
dependee range, and a *derived* sibling. Dropping a derived sibling's hole would print
a conclusion wider than the two named causes justify.

**The wording is pub's, in cabal's range syntax.** The spec leaves the sentences to
the implementation (`:677`) and lists pub's special cases (`:1010`–`:1030`), and
every one of them is in: "every version of foo" for a set that admits every version,
the root by name alone, "So," on the last line, "version solving failed" instead of
"root is forbidden", a period on every line, and the blank line between two branches
(`:632`). A negative term is never printed as "not …": the sentence carries the
negation, as pub's do. Two positive terms read "X is incompatible with Y", two
negative ones "either X or Y", and a clause with several terms reads "P requires N1
or N2" or "if P1 and P2 then N1 or N2". A boot package's fact names the version it
is pinned to, `base is pinned to 4.21.0.0 (installed)`: the bound that failed is only
legible against that version, and nothing else in the proof states it — 11 of the
13 showcase proofs turn on it. An installed unit is written by version,
`base 4.21.0.0 (installed)`, never by unit id, and not at all when a source range
in the same set already admits its version.

**A headline stands above the proof.** The proof is read bottom-up — its first line
is the deepest fact and the root appears only on the last — so `reportHeadline`
says first what the proof will conclude: the request, as the root's dependency facts
in the proof name it, and the world facts the proof rests on, verbatim:
`No solution for matterhorn ==90000.1.1: base is pinned to 4.21.0.0 (installed).`
It claims nothing the proof does not, since every named fact is a premise of the
derivation below it. The driver prints it, then a blank line, then the proof. It is
not a proof sentence: the gate counts by connective and the harness keeps it apart,
which is the footing of cabal's own `Could not resolve dependencies:` line, left out
of its count too. The golden proofs are the spec's and carry no headline.

**The driver wraps, the reporter does not.** A proof sentence runs to 400
characters on `hjsonschema`, and a terminal that wraps it by itself breaks inside a
range. `wrapProof` wraps every line at the terminal's width, or 80 columns off a
terminal, with a four-space hanging indent and a range kept whole: a token that
opens with a comparison, `&&`, `||`, `(installed)` or a bare version sticks to the
token before it, and a break falls only between such atoms. An atom too long for a
line of its own breaks before a `||`, the one seam a range has. `reportConflict`
itself is unwrapped, so the golden proofs stay the spec's sentences one per line,
and a continuation line starts with the indent, which neither the gate nor the
harness counts as a sentence. The harness keeps the proof as the driver printed it,
continuation lines and the blank line between two branches included; the showcase
had been dropping that blank line, the one visual device the spec has.

**Colour is a terminal-only layer.** `styleProof` dims every range token, so the
package names stand out by contrast and a reader can skim the names and skip the
bounds; bolds the connective that opens a sentence, so sentences can be told from
their continuation lines; and bolds the headline and the `So,` line throughout.
Stripping the escapes gives the input back. The driver applies it only when stdout
is a terminal, `NO_COLOR` is unset and `TERM` is not `dumb`, so the gate, the
harness and every log read plain text. There is no `--color` flag.

**A declared range is quoted as written.** The dependee term of a dependency fact is
the declared range with its spelling attached (§4.2), and the store merge keeps that
term intact, so the proof quotes `base ^>=4.13.0.0 || ^>=4.14.0.0 || … ||
^>=4.19.0.0` where the author wrote that — byte for byte the constraint cabal's own
message quotes. A range the solver derived has no author and prints canonically.

The linear example matches `:1005` sentence for sentence. The branching one differs
from `:1150` only in which facts the derivation happened to pair.

> **One trap for tooling.** The synthetic root's name carries a real NUL byte, so GNU
> `grep` treats a proof as binary and reports no matches without `-a`.
> `scripts/gate.sh` passes `-a` everywhere, and the harness reads every child log as
> bytes. New tooling that greps a proof will read zero and look like it passed.

### 4.10 Memoise the reduced form, never the parse tree

`Bridge.Provider.releaseReader` memoises, per release, only the form the provider
needs: declared flags, guarded dependencies, and a buildable flag.

Retaining the parsed descriptions instead cost **27.2 s and 904 MB** on `pandoc`,
against 3.7 s and 83 MB uncached. About 170 parse trees each pin their slice of the
index, and every major garbage collection then copies the lot.

Caching more was 7× slower and 10× bigger. Remember this before optimising in the
same area again.

### 4.11 Decision order is discovery order, and `yesod` is the bill

`PubGrub.Solver.undecidedPositive` picks the next package to decide by **first
mention**, oldest first. It is deterministic and it has no relation to where the
conflicts are.

`references/pubgrub.md:446` prescribes something else: decide "the package with the
fewest versions that match the outstanding constraint", because that "tends to find
conflicts earlier if any exist". We do not do that, and `yesod` is what it costs.

**What happens on `yesod`**, read off the trace:

| | |
| --- | --- |
| distinct packages in the plan | 186 |
| decisions made | 827 (4.45 per package) |
| conflicts | 11 |
| `aeson` decided at position | **4** |
| `persistent` decided at position | **126, last** |
| packages decided between `yesod-persistent` and `persistent` | 101 |

`yesod-persistent` is decided 24th and introduces `persistent >=2.8`. `persistent`
then queues behind 101 packages that were first mentioned by decisions 1–23, so it is
decided last. Its conflict is with `aeson`, which was decided 4th.

Finding that conflict at position 126 and backjumping to `aeson`'s level discards 103
decisions the learned clause never mentions. Each `persistent` release carries a
different `aeson` bound, so each conflict eliminates exactly one release and the cycle
repeats.

**The four repeated segments are byte-identical**: the same 103 packages, decided in
the same order, four times. **412 of 827 decisions — 50% — re-derive a prefix that was
already correct.**

`pandoc` is the control. Same size plan (194 packages), 270 decisions, 1.39 per
package.

**Where the cost lands.** A profiled run (`+RTS -p`, 4.64 GB, matching the normal
4.44 GB) puts it in the solver, not the provider:

| | time | allocation |
| --- | --- | --- |
| propagation and term intersection (`intersectTerm`, `termIntersectionForPackage`, `incompRelation`, `isEmptyTerm`) | 27.7% | 23.1% |
| the clause store (`insertClause`) | 7.0% | 16.3% |
| the cell algebra | 6.8% | 5.2% |
| derived-index decode, which is the walk's reads | 8.0% | 8.4% |
| the provider itself | 1.8% | 1.0% |

Every decision pays a propagation pass over a clause store that grows with the solve.
So cost tracks decisions, and 4.4× the decisions is 4.4× the propagation. **The walk is
not the problem** — it is 8% of allocation, and it is what took `futhark` from 4287
decisions to 807.

**Two ways out, and neither is free.**

- **Order decisions by fewest matching versions**, as the spec prescribes. This was
  built and reverted once: it cut `futhark` decisions 5.2× and lengthened the corpus
  proofs from 66 to 95 sentences. `yesod` is new evidence, because it is satisfiable
  and has no proof at all, so on this problem the heuristic has no cost to pay. That
  makes "one order for everything" the wrong frame — the trade differs between sat and
  unsat problems. Note the core cannot compute "fewest versions" on its own: an
  `InstanceSet` cannot be enumerated ([§4.2](#42-version-sets-are-intensional)), so the
  count has to come from the provider.
- **Make a re-decision cheap.** The incompatibilities a decided instance entails are a
  pure function of that instance, and today they are rebuilt — walk included — on every
  one of the 6 or 7 re-decisions. Memoising them per instance does not remove the
  redundant propagation, which is the larger half, so this is the smaller lever.

**What is not the cause**, each checked: the walk (8% of allocation), the derived index
(a read is 0.073 ms), the number of conflicts (11 is small), and proof rendering
(`yesod` is satisfiable and prints no proof).

---

## 5. What is deliberately out of scope

### 5.1 Flags are fixed at their declared defaults

Flags are parsed and applied. They are not a search dimension. A release's
dependencies are the ones its own declared defaults select. No flag is a variable the
solver can set.

Both solvers are told, and each takes it differently:

- **ours, at flatten time.** `Bridge.Cabal.Flatten.componentDepsAtDefaults` resolves
  flag conditions against the release's defaults, so every guard folds to a literal.
  No pinned cell is ever built, and a release offers exactly one instance.
- **cabal's, at the index read.** `Bridge.Hackage.lookupGPD` marks every flag manual,
  so cabal's `enforceManualFlags` prunes every branch whose value is neither the
  default nor named by a user constraint. We pass no user constraints.

Doing it at the single shared read is what keeps the comparison structural. Neither
solver can be handed a different universe by accident.

**Two consequences for anyone reading a number taken under this scope.** A manual flag
is not *weak*, so cabal's `deferWeakFlagChoices` stops deferring the flags that
influence dependencies. That perturbs cabal's goal ordering, not only its flag values.
And an automatic flag is exactly what cabal would have flipped to escape an
unsatisfiable dependency, so some problems that resolved before will not. Both solvers
fail together, which is what makes the comparison fair. It is still a restriction of
the problem, and any published result must say so.

**The machinery is kept and still tested.** `componentDeps`, `expandGuard`,
`preferDefaults`, the three-state pin and its property suite are all here.
[flags-semantics.md](flags-semantics.md) is unchanged as a specification, and only its
degenerate case runs. `test/InstanceSetSpec.hs` exercises the algebra and
`test/FlagSolveSpec.hs` exercises the provider rule on hand-built releases with real
guards. That is the only reason it is safe to leave in.

**One trap is armed and not firing.** The provider tries one flag completion per
candidate region. If a region's default completion is unusable while another
completion of the same region is fine, the shortcut misses a valid instance. The
symptom is a confident, wrong "no solution", which
[flags-semantics.md](flags-semantics.md)'s O6 forbids. With one completion per release
that case has no instances. **Whoever restores flag search owns the O6-complete search
and the verdict oracle**, and cannot treat buildability as already done.

### 5.2 One version per package name

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

### 5.3 Setup and build-tool dependencies

Rung 4, not started. `Bridge.Cabal.Flatten.componentDeps` merges library, sublibraries
and executables into one `GuardedDeps` and discards which component each occurrence
came from. It reads neither `setup-depends` nor `build-tool-depends`.

The merge shows in the plans. cabal plans only the library of a dependency, so an
executable stanza's dependencies never enter its plan, and `buildable: False` on that
stanza is read only for the library here. That is why our `pandoc` plan carries
`network-run` and cabal's does not ([§3.1](#31-against-cabal-on-the-benchmark-set)).

Recovering the component label is the bulk of the work, and it touches no solver code.

### 5.4 Public sublibraries

Rung 5, not started.

---

## 6. Specified, not built

Everything here has a specification and no implementation. **Do not assume any of it
exists in the code.**

| thing | specification | note |
| --- | --- | --- |
| **Condition decisions** (rules D1, D2, D3) | [decision-semantics.md](decision-semantics.md) §2–§9 | a kernel-level change to what a decision is. Dormant: the cost it removes is currently zero |
| **Seed incompatibilities** instead of a synthetic root | [decision-log.md](decision-log.md) | decided 2026-07-30. `solve` still takes `rootPkg` and `rootV` |
| **`buildable:` as a condition** | [flags-semantics.md](flags-semantics.md) §1.5 | half built. `buildableCondition` returns the condition and `buildableAtDefaults` evaluates it. Satisfying it rather than evaluating it is the flag-axis half |
| **User flag constraints** (`--flag`) | [flags-semantics.md](flags-semantics.md) §1.6 | do not exist. While every flag is manual, they are the only thing that can move one |
| **The verdict oracle** (test) | [flags-semantics.md](flags-semantics.md) §6 | owed. It blocks condition decisions, and it is what would discharge O4's whole-loop claim |
| **`preferred-versions`** | — | the index reader does not read it |

---

## 7. Which document decides

**Each row is authoritative on its own subject.** The list is not a ranking. The
specifications mostly do not overlap.

| file | authoritative on | status |
| --- | --- | --- |
| [`references/pubgrub.md`](../references/pubgrub.md) | **the algorithm.** A vendored copy of pub's spec | tracked, 1233 lines. Reference — never edit. Before you cite a line, check it: several later citations land on blank lines |
| [flags-semantics.md](flags-semantics.md) | **flags**, and the value and set language | a specification. Only its degenerate case runs |
| [decision-semantics.md](decision-semantics.md) | what a **decision** is | a specification. Nothing in §2–§9 is implemented |
| [`../specification/`](../specification/) | **nothing.** Our own draft attempt at formalising the kernel, in Lean | a draft. Where it disagrees with `references/pubgrub.md` or `flags-semantics.md`, it is wrong. Its theorems are kernel-checked. 17 of its worked examples use `native_decide`, which trusts the Lean compiler instead |
| [`../CLAUDE.md`](../CLAUDE.md) | build commands, architecture, conventions | current |
| [collapsing.md](collapsing.md) | **depender collapsing**: what runs, what it costs, and the five ways to make it cheaper | current |
| [benchmarking.md](benchmarking.md) | **how to run the tests and benchmarks**, and which numbers to trust | current |
| [failure-cases.md](failure-cases.md) | **the failure corpus**: where it came from and what is in it | current |
| [harness-plan.md](harness-plan.md) | **the harness**: why it is shaped that way, and where the build differed | current |
| [reports/](reports/) | the two reports **as generated** by `pubgrub-harness` on 2026-09-03 | generated. Regenerate with `cabal run pubgrub-harness` and copy; do not edit |
| [cabal-build-model.md](cabal-build-model.md) | Cabal's **build model** — components, qualifiers, Backpack | reference for rungs 4 and 5. Nothing implemented |
| [pubgrub-intro.md](pubgrub-intro.md) | a tutorial introduction to PubGrub | current |
| [related-work.md](related-work.md) | external literature mapped onto our problems | a reading map. Authoritative on nothing |
| [decision-log.md](decision-log.md) | project history | narrative. Authoritative on nothing |
| this file | current state | a summary. The rows above decide |

### How the two specifications relate

They are layered, not competing.

- **flags-semantics.md defines the language**: what a value is, what a constraint
  mentioning a flag means, and which set operations must be exact.
- **decision-semantics.md defines what the solver does** with that language: what a
  decision is, and when a solve may declare success.

decision-semantics.md defers to flags-semantics.md on flags and never overrules it. It
deviates from `references/pubgrub.md` only where its §1 registers the deviation. Its
prerequisite — per-fact guarded emission, flags-semantics.md §4.2 — is built, so it is
no longer inert. It is dormant instead, because the cost it removes is zero while
flags take their defaults.

Both specifications name their rules with letters: **O1–O7** for obligations the code
must guarantee, and **D1–D3** for rules about decisions. The two cited most often are
**O6** (the provider must never report "nothing available" when something is
available) and **D1** (when a solve may declare success).

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

## 8. Open questions

1. **What does the 22 MB memory floor consist of?** It is the first thing to settle,
   because the memory claim is the strongest one the project has and the floor is most
   of it. See [§3.3](#33-what-these-numbers-do-not-establish).
2. **Should `expand` split back into "pick" then "consequences"?**
   ([flags-semantics.md](flags-semantics.md) §8.) A design item, not a decision.
   [decision-semantics.md](decision-semantics.md) §10 says the condition-decision model
   inherits all three benefits of the split, so schedule the two as one item.
3. **Should the set algebra be allowed to read flag declarations?** It would make
   emptiness exact and remove the one-sided slack. It costs the core-bridge boundary.
   A cost question, not a correctness one.
4. **Decision order is chosen by discovery, and on `yesod` that costs 4.4× the
   decisions.** Diagnosed, not fixed — see
   [§4.11](#411-decision-order-is-discovery-order-and-yesod-is-the-bill).
5. **How far can the walk go?** It is unbounded today, so widening reads the whole
   version list in the worst case. A cap stays sound, because flags-semantics.md §4.2
   makes maximality policy rather than a requirement. Nothing has chosen one.

Three questions once open here are now **answered**.

**What does the walk do at an unparseable neighbour?** It stops
(`Bridge.Provider.spanningOccurrence`). Spanning it would claim a fact about a release
nobody could read.

**Does `yesod` finish?** Yes. It never finished before: over 90 s and thousands of
decisions, every conflict at depth 0. It now resolves in **2.49 s** with 827 decisions
and 11 conflicts, and it is in the benchmark set. It is also the one problem where
cabal beats us — see [§3.1](#31-against-cabal-on-the-benchmark-set).

**Can a quiet run also be a counted run?** Yes. `pubgrub --stats` folds each
`SolverMsg` into counters in-process and prints one `stats:` line after the answer,
with the phase timings on a `phases:` line. `scripts/check-stats.sh` holds it to
`bench/summarise.awk`, number for number, on all 23 problems.

### Settled — please stop re-litigating

Each of these was decided with reasons recorded, and revisiting it has already cost
time.

- **No complement in the value algebra.** Four operations plus emptiness. Negation
  lives in `Term` as a polarity flip. A complement needs a universe of values that
  nothing in the algorithm ever asks for.
- **No `Eq` or `Ord` on `InstanceSet`.** The representation is not canonical, so
  structural equality would be unlawful. Use mutual containment.
- **Sets stay intensional.** An extensional `Set Instance` is not a cheaper PubGrub. It
  is the encoding PubGrub exists to avoid.
- **Emptiness stays one-sided.** Missing an empty set costs time. Claiming emptiness
  wrongly gives wrong answers. Test `isEmpty ⟹ empty`, never `⟺`.
- **Flags live in the value, not as solver variables.** A flag variable would need
  conditional existence, which PubGrub has no notion of. The price is the 2^k re-offer,
  and the answer to that price is condition decisions, not a change of model. While
  flags take their defaults the price is not being paid, because the search is not
  being done. That is a scope cut, not a third answer.
- **The property suite's universe must be non-uniform.** Releases must differ in which
  flags they declare, including one declaring none. A uniform universe cannot tell the
  three flag readings apart, which is exactly how a wrong `difference` passed for weeks.
- **Do not chase byte-parity with pub's output.** `^1.0.0` is Dart. cabal writes
  `>=1.0.0 && <2`. Same sentences, cabal's syntax.

### Two things that were measured and rejected

Both are recorded so nobody re-derives them.

**Narrowing declared ranges to published versions.** `Bridge.Provider.widen` puts a
declared range into a term verbatim, so version space no release occupies survives.
Narrowing it with `snapToVersions` was tried twice in August, reverted twice on cost,
and re-measured on 2026-09-03 on the current tree, where the cost argument no longer
applies: it moves the search in both directions (`aeson <2` 400 to 320 decisions and
11.6% less allocation, `yesod` 827 to 839 decisions and 11.7% more) and it rewrites
every quoted range in a closed form nobody wrote, down to the user's own `lens <4`
printing as `lens >=0.1 && <=3.10.3` on the proof's last line. The second is the
objection, and it holds at any price. Pub never narrows; pubgrub-rs offers
`Ranges::simplify` and applies it only in the report. `snapToVersions` is kept, tested
and unused.

Its interior half, `PubGrub.VersionSet.fillGaps`, merges the holes between a range's
intervals that hold no published release and never moves an outer bound. Measured the
same day: every search counter identical on eight problems, allocation within noise,
one proof line changed (`haddock`'s seven `^>=` windows into `>=4.13.0.0 && <4.20`).
It is kept in reserve for *derived* terms, which nobody wrote. Applying it to a
declared range would discard the author's spelling, which §4.2 now keeps.

**The fewest-versions decision heuristic.** `references/pubgrub.md:446` suggests
deciding the package with the fewest versions first. It cuts `futhark` decisions by
5.2× and lengthens proofs from 66 to 95 sentences. Measured and reverted.

**Reopened by `yesod`**, which is satisfiable and therefore prints no proof at all, so
the reason for reverting does not apply to it. See
[§4.11](#411-decision-order-is-discovery-order-and-yesod-is-the-bill).

---

## 9. Deliverable status

| deliverable | state |
| --- | --- |
| **Explanation showcase** — real failing problems, pubgrub-hs against cabal, side by side | **the problem set exists and we win on all of it.** 17 real failures, six failure kinds, five positive controls. Shorter than cabal on 17 of 17: 61 proof sentences against 166. Shorter on two of the three benchmark unsat problems. Both of the spec's published examples are golden tests, and the linear one matches sentence for sentence. Every reporting gap but the cosmetics is closed. `pubgrub-harness` renders the two explanations as adjacent blocks for the 13 comparable problems, and the 2026-09-03 run is [reports/showcase.md](reports/showcase.md): shorter on 13 of 13, 44 sentences against 123 lines |
| **Benchmark report** — time and peak residency on real problems | **current numbers exist** for six problems, three sat and three unsat, both solvers. We use less peak memory on all six, and are faster and leaner in allocation on five of six. `yesod` is the exception on both. The 2026-09-03 run is [reports/benchmark.md](reports/benchmark.md). Its caveats: timings are medians of three runs against ±25% noise, cabal's lazy per-release parsing lands in its `solve` phase and cannot be separated without changing the work, and the 22 MB memory floor is unexplained |

The baseline and the shared index are done. `cabal-install-solver` drives cabal's
resolver from the same `withWorld`, which is what makes the comparison
apples-to-apples rather than arranged.

The gate decides and the harness measures, and neither replaces the other.
`scripts/gate.sh` runs both solvers over all 23 problems once and fails on any
regression in verdict agreement or proof length. `pubgrub-harness` runs them three
times, diffs the plans, separates the phases, and writes the two reports.

**One thing both deliverables must state outright.** Both solvers run with every flag
pinned to its declared default. That makes the comparison fair, because neither side
can flip a flag to escape. It also makes some real failures unreachable. A benchmark
or a showcase that does not say so is misleading, however honest its numbers are.
