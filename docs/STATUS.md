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
> **Checked against the tree on 2026-09-22.** 232 tests pass and
> [`scripts/gate.sh`](../scripts/gate.sh) passes, at the index-state pinned in
> [`bench/index-state`](../bench/index-state), `2026-09-09T02:42:09Z`.

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
on all 20 failures in the corpus.

**That record holds only where every target is pinned to a version, and every corpus
target is.** On a problem with an *unconstrained* target it inverts: a complete proof
has to refute every release of that target, where cabal's message is a search trace
that stops at the first wall it hit, and on the 23 such problems of the 2026-09-10
sweep we were the longer text on 21 ([§3.2](#32-against-cabal-on-the-failure-corpus)).

Two more rows go the other way. cabal is faster on `yesod` and allocates less there.
cabal's message on `aeson <2` is shorter than our proof.

The harness exists. `pubgrub-harness` runs both solvers over both problem sets as
child processes, repeats the runs, diffs the plans, and writes the benchmark report
and the explanation showcase. The reports in [reports/](reports/) are the
deliverables in their current form, each dated in its header.

---

## 2. What works today

| area | state |
| --- | --- |
| Hackage index | our own reader over the cached `01-index.tar`, through `hackage-security`. No `cabal-install` dependency |
| Index-state | `--index-state T` gives both solvers the index as it was at `T`, revisions included, with cabal's semantics. A run prints the state it is really at |
| Derived index | every release parsed once into `_cache/derived-index.cbor`. A read is a CBOR decode, served only for the revision in force |
| Version ranges | full. The solver resolves real packages end to end |
| Version order | ours, not Cabal's: trailing zeros are insignificant, so `1.2` and `1.2.0.0` are one version. Cabal's type stops at the bridge ([§4.13](#413-versions-compare-with-trailing-zeros-insignificant)) |
| Flags | applied, not searched. Every flag takes its declared default on both sides |
| Boot packages | the installed database becomes instances. A boot package offers installed units or nothing |
| Buildability | a release whose library cannot be built here is not offered, and the proof says why: the `pkg-config` module that is missing, by name, or `buildable: False` |
| Explanations | `PubGrub.Report` prints a numbered proof that follows the spec's own reporting algorithm |
| cabal baseline | `pubgrub --cabal <target>` runs cabal's modular solver over the same index |
| Regression gate | `scripts/gate.sh` runs 26 problems through both solvers and fails on any regression |
| Harness | `pubgrub-harness` measures both solvers over both sets, three runs each, and writes `bench/output/benchmark.md` and `showcase.md`. It measures; the gate decides |

Not built: setup and build-tool dependencies (rung 4) and public sublibraries
(rung 5).

---

## 3. The numbers

Measured by `pubgrub-harness` on 2026-09-22 at index-state `2026-09-09T02:42:09Z`:
one desktop, medians of three runs, no trace. The two reports as generated are in
[reports/](reports/). Read
[benchmarking.md](benchmarking.md) before you quote any figure below. The short version:
counts are deterministic, elapsed time moves by ±25% between runs, and total
allocation is the stable stand-in for time.

### 3.1 Against cabal, on the benchmark set

`pubgrub-harness` over [`bench/problems.txt`](../bench/problems.txt). Residency is
`maximum residency` from `+RTS -s`. Times are seconds, medians of three. Bold marks
the better of the two.

| problem | verdict | ours | cabal | our world / solve | cabal world / index / solve | our residency | cabal residency | our allocation | cabal allocation | our proof | cabal's message |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `vector` | both sat | **0.66** | 1.01 | 0.63 / 0.02 | 0.64 / 0.11 / 0.24 | **25.4** | 68.2 MB | **0.55** | 1.03 GB | — | — |
| `pandoc` | both sat | **1.07** | 1.43 | 0.58 / 0.49 | 0.63 / 0.10 / 0.65 | **41.8** | 96.7 MB | **1.83** | 1.97 GB | — | — |
| `conduit <1.3` | both UNSAT | **0.58** | 0.99 | 0.56 / 0.01 | 0.53 / 0.10 / 0.34 | **25.4** | 68.2 MB | **0.54** | 1.50 GB | **9** | 12 |
| `lens <4` | both UNSAT | **0.68** | 1.09 | 0.63 / 0.05 | 0.58 / 0.11 / 0.39 | **25.4** | 68.2 MB | **0.68** | 2.06 GB | **7** | 18 |
| `aeson <2` | both UNSAT | **0.75** | 1.76 | 0.57 / 0.18 | 0.56 / 0.12 / 1.04 | **25.4** | 91.4 MB | **1.23** | 5.60 GB | 38 | **26** |
| `yesod` | both sat | 2.00 | **1.48** | 0.57 / 1.42 | 0.58 / 0.13 / 0.72 | **41.7** | 97.2 MB | 5.51 | **2.10** GB | — | — |

All six verdicts agree. We use **2.3–3.6× less peak memory on all six**. We are faster
on five of six and allocate less on five of six.

**The phases say where our time goes, and it is not the solve.** Opening the world
(the index, the installed database and the pkg-config database) costs 0.5–0.7 s on
every run, on both sides. Our solve is under 0.2 s on four of the six problems, and
`pandoc`'s half second is reads, not search. Only `yesod` has a solve phase that
matters. cabal's `index` phase is small because the work it names is lazy and lands
in its `solve` ([§3.3](#33-what-these-numbers-do-not-establish)).

**`yesod` is where we lose, and it is the most useful row in the table.** cabal is
1.4× faster on it and allocates 2.6× less. It is the only *satisfiable* problem in the
set with real search in it: `vector` and `pandoc` resolve almost straight through.
Every other row is either a walk-through or an unsatisfiable proof, so until `yesod`
was enabled the set could not report this at all.

It is diagnosed: **half its decisions re-derive a prefix that was already correct**,
because decisions are ordered by discovery rather than by the spec's heuristic. See
[§4.11](#411-decision-order-is-discovery-order-and-yesod-is-the-bill).

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
([§4.6](#46-the-derived-index-makes-a-read-a-decode)). That holds only while the
store is newer than the index: after the weekly refresh, releases published or revised
since are parsed until `pubgrub-index` is re-run, and a non-zero `parses` is the tell.
Reading the index at an index-state costs the world phase about 0.16 GB of
allocation and 2 MB of residency on every run
([§4.12](#412-the-index-is-read-at-an-index-state)), which is visible on the smallest
rows and nowhere else. The changes that moved these counts, the first-release slot
rule ([§4.4](#44-a-release-owns-a-slot-not-a-point)), the version order
([§4.13](#413-versions-compare-with-trailing-zeros-insignificant)), the buildability
gate ([§4.14](#414-a-component-that-is-not-buildable-contributes-no-dependencies))
and the seeds ([§4.15](#415-the-request-is-a-list-of-seeds-not-a-root-package), one
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
([§4.14](#414-a-component-that-is-not-buildable-contributes-no-dependencies)).

**The three kinds of problem are not interchangeable.** `vector` and `pandoc` measure
index throughput, and `pandoc` has one conflict, so neither can show a search
improvement. `conduit <1.3`, `lens <4` and `aeson <2` measure search on an
unsatisfiable problem. `yesod` measures search on a satisfiable one. A change that
helps only one kind is not a change that helps.

### 3.2 Against cabal, on the failure corpus

20 real failures, every target pinned to one version: 17 harvested from Hackage's
build reports, and three found by solving pairs of popular packages together, each
of which resolves alone. [failure-cases.md](failure-cases.md) has the methods, the
six failure kinds, and the per-problem table.

**We are shorter than cabal on all 20: 76 proof sentences against cabal's 193.** No
`no version for …` line is left anywhere in the corpus. `scripts/gate.sh` holds both
totals as ceilings. Measured on 2026-09-22 at the pinned index-state.

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
([§4.9](#49-the-report-follows-the-specs-reporting-algorithm)) was built from that
sweep and took the three longest from 46, 65 and 63 sentences to 34, 54 and 46,
and it is not enough. Those problems are not in the corpus, so nothing gates them,
and a sentence count against cabal's trace is not the right measure for them: the
trace explains one release and the proof explains all of them. The showcase needs
a completeness column before it can render such a problem fairly.

### 3.3 What these numbers do not establish

- **The memory floor is unexplained.** Every solve pays about 25 MB before it does any
  work of its own, of which about 2 MB is the index-state read
  ([§4.12](#412-the-index-is-read-at-an-index-state)). The package-to-versions map
  was long assumed to dominate that floor. Doubling the map's per-element overhead
  moved peak residency by 0.5%. The memory claim is the strongest one the project
  has, and most of it is a number nobody can account for. Settle this first.

  What sits *above* the floor is understood: the memoised reduced forms, so residency
  tracks how many releases a solve read. That is why `pandoc` and `yesod` sit at
  about 42 MB.
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
about one package that give the same reasons merge the same way, which is
`references/pubgrub.md:476`'s half of the rule. Two runs ruled out for different
reasons stay two facts, so a proof never puts one release's missing module on the
other's range.

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
- **It follows the index by block.** Each stored release carries the tar block of
  the `.cabal` it was parsed from, and `srLookup` serves it only when that is the
  block of the revision in force at the run's index-state
  ([§4.12](#412-the-index-is-read-at-an-index-state)). The Hackage index refreshes
  itself at most weekly, and every release published or revised since the store was
  built is then a miss that parses. The answers stay right, and `parses` stops being
  zero until `cabal run pubgrub-index` runs again.
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
per line. Five rules do the work.

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
4. **A run collected by depender alone is one sentence.** Rule 3 needs one dependee
   for the whole run; on a problem with an *unconstrained* target there is no such
   run, because refuting one walks the target's version history and consecutive
   releases rarely fail over the same dependee. So `oneDerived` also finds the
   maximal run of chain steps sharing a *depender*, whatever they depend on, and
   states it as `p ∈ ⋃S requires q₁ ∈ ⋃R₁ or … or qₙ ∈ ⋃Rₙ`. Sound for the same
   reason as rule 3: if `p` is in the union it is in some `Sᵢ`, and that fact's own
   dependee is one of the disjuncts.
5. **Empty-range leaves are absorbed** (`collapseNoInstances`). Intensional ranges
   mean the solver separately learns that a range's holes are empty, and
   `no version for bar in >2.0.0 && <3` used to clutter the proof. pubgrub-rs runs the
   same post-pass as `DerivationTree::collapse_no_versions`.

Every fusion is guarded, so a fused sentence cannot claim more than the facts do.
Rules 1 to 3 use a subset test, and one-sided `isEmpty` means such a guard can only
decline to fuse — never fuse wrongly.

**Rule 4's guard is the operation itself.** A line standing for a run has to arrive
where the run arrived, so `PubGrub.Incompatibility.priorCauseTerms` — the term algebra
`priorCause` runs, split out for this — is applied once to the run's merged fact,
pivoting on the depender, and the collapse is taken only when the result is term for
term the conclusion the line is attached to. That is why the rule needs no subset
side-condition and no case analysis over what the run did. It covers both shapes a
single proof walks: a depender that **accumulates**, `aeson` climbing from `<0.8.0.1`
to `<2.2.5.0` one dependency at a time, and one that is **eliminated**, `directory`
losing a slot per fact until nothing is left. `mergeFacts` refuses a run where some
package is a depender in one fact and a dependee in another, because the union
argument is about one depender and holds for nothing else.

Rule 4 needs three facts. Two already fit one line with both named, and naming both
says strictly more than naming their union, so the union has to buy a line to be worth
taking.

**Rule 5 looks cosmetic and is not.** The `no version for …` siblings were what
*stopped* rule 1 from firing.
Each dependency fact was paired with a hole-is-empty fact instead of with the next
dependency fact. Once the siblings were absorbed, rule 1 appeared in **14 of the 17**
harvested problems. It had only ever been seen in the spec's own worked example.

**Rule 5 recomputes nothing, and that is its soundness argument.** Resolving a unit
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
"So," on the last line, "version solving failed" on it, a period on every line, and
the blank line between two branches (`:632`). Where pub names its root package
("myapp depends on foo ^1.0.0") there is no root here: the request is a seed per
target, and a seed reads "foo >=1 is requested", two of them "foo >=1 and bar are
requested", one whose range holds nothing "foo >9 is requested, which has no
versions". A negative term is never printed as "not …": the sentence carries the
negation, as pub's do. Two positive terms read "X is incompatible with Y", two
negative ones "either X or Y", and a clause with several terms reads "P requires N1
or N2" or "if P1 and P2 then N1 or N2". A boot package's fact names the version it
is pinned to, `base is pinned to 4.21.0.0 (installed)`: the bound that failed is only
legible against that version, and nothing else in the proof states it — 13 of the
16 showcase proofs turn on it. An installed unit is written by version,
`base 4.21.0.0 (installed)`, never by unit id, and not at all when a source range
in the same set already admits its version. An unbuildable release's fact names what
rules it out, `hpqtypes >=1.10.0.2 needs pkg-config package libpq, which is not
found`, where cabal's message reads `pkg-config package libpq-any, not found in the
pkg-config database`. Several modules share one "needs", `buildable: False` reads
`is marked buildable: False`, and the two join with "and". It is not "cannot be
built because …": the chain form puts this leaf after a "Because" of its own. The
module is spelled as Cabal-syntax prints the `pkgconfig-depends` field, `libpq`
unbounded and `zlib >=1.2` with its range; cabal's `-any` is its spelling of the
empty range and is not copied.

**A headline stands above the proof.** The proof is read bottom-up — its first line
is the deepest fact and the request appears only on the last — so `reportHeadline`
says first what the proof will conclude: the request, as the seeds the proof rests
on name it, and the world facts the proof rests on, verbatim:
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
token before it, a preposition joins what is before it to its object, so "depends
on bytestring >=0.10.4 && <0.11" is one atom, and a break falls only between such
atoms. An atom too long for a line of its own breaks before a `||`, the one seam a
range has. `reportConflict`
itself is unwrapped, so the golden proofs stay the spec's sentences one per line,
and a continuation line starts with the indent, which neither the gate nor the
harness counts as a sentence. The harness keeps the proof as the driver printed it,
continuation lines and the blank line between two branches included; the showcase
had been dropping that blank line, the one visual device the spec has.

**The showcase counts screen lines as well as sentences.** A sentence can run to
400 characters and cabal's lines are unwrapped, so a count of sentences against
lines flatters neither side honestly. The showcase therefore also gives our proof's
non-blank lines as printed, wrapped at 80, against cabal's lines at 80 columns, each
counted as the rows it fills. The gate still counts sentences.

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

### 4.15 The request is a list of seeds, not a root package

`PubGrub.Solver.solve` takes a list of incompatibilities. Each target `p R` is
`request p R`, the unit clause `{p: Negative R}` with cause `CauseRequest`, built by
`Bridge.Provider.withProvider` because widening a range to instances needs the
installed db. The spec's synthetic root (`references/pubgrub.md:252`) is these
clauses with a package in front of them, and that package then had to be decided,
printed, filtered out of every plan, and named with a NUL byte so it could not
collide with a real one. Decided on 2026-07-30, built on 2026-09-22.

The seeds propagate to derivations at decision level 0 before anything is decided,
and three things follow:

- **Terminal is "satisfied by the seed derivations alone"**, checked before the
  satisfier search (`satisfiedBySeeds`). It is `:377` with the root's one derivation
  replaced by the seeds': the empty incompatibility is satisfied by anything, and
  `{root: Positive s}` with the root's instance in `s` is exactly "satisfied by the
  seed `{not root}`". A conflict satisfied at level 0 by a *learned* derivation is
  not terminal and resolves on through that derivation's cause, so the proof still
  says why the fact was forced.
- **The backtrack floor is level 0.** The spec's `max 1` (`:399`) protects its root
  decision and it says level 0 is safe (`:402`). Here the first decision at level 1
  is an ordinary target, and a learned unit clause on it has to be able to undo it;
  with the floor kept, that case loops.
- **A terminal conflict is closed against the seeds** (`closeWithSeeds`): one
  `priorCause` per seed it rests on, in a pass repeated while a pass removes
  something, so two seeds on one package both take part. The reported
  incompatibility is empty, the last line reads "So, because …, version solving
  failed", and the request is the last fact named: "aeson ==2.3.1.0 is requested".
  The emptiness test that drops a seed's term is the one `relation` answered
  "satisfied" with, so the two agree; if a term survived anyway the line would still
  read as failure, because that is what it is.

What it changed, measured on the 26 gate problems: every verdict the same, every
proof the same length with "root depends on X" become "X is requested", the
paper's two golden proofs changed on their last line only, and every problem has
one decision fewer. There is no `root` in any proof and no NUL byte anywhere; the
`-a` in the scripts is now a precaution.

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

### 4.12 The index is read at an index-state

`pubgrub --index-state 2016-09-24T17:47:48Z <target>` gives both solvers the index as
it was at that moment, with cabal's semantics, and every run prints the state it is
really at on an `index-state:` line. It is what makes a number reproducible: the
Hackage index refreshes itself at most weekly, and each refresh moves the set of
releases and, through revisions, their bounds. On 2026-09-03 the refresh grew two of
cabal's corpus messages while our proofs stood still. A pinned state holds the whole
problem fixed. The gate, `check-stats.sh` and the harness are all pinned to the
state in [`bench/index-state`](../bench/index-state), currently
`2026-09-09T02:42:09Z`, the head of the index on the day the pin was set; the
harness records the state in its environment header. `PUBGRUB_INDEX_STATE` and
`pubgrub-harness --index-state` override the pin, and `head` means everything the
local index holds. A pin newer than the local index refreshes it, and a pin newer
than Hackage itself is an error, so the pin is always a state that exists.

**What an index-state means.** The index tar is append-only, and every entry
carries the time it was added. A release exists at `T` if its first entry is at or
before `T`, and the `.cabal` it has there is its __last__ entry at or before `T`.
That second half is revisions, and it is the half that decides verdicts: a revision
mostly tightens a bound to record breakage. `aeson ==2.2.3.0` is the demonstration.
At `2024-07-01` its original `ghc-prim <0.12` is in force and both solvers reject it
under GHC 9.12; at `2025-07-01` its fourth revision is in force and both plan it.

**How it is done, and it is cabal's design.** cabal keeps a flat cache with one
entry per tar entry, filters it by time (`filterCache`), and folds the survivors
last-writer-wins by package id (`packageListFromCache`), so the revision in force
falls out of the two composing. Our version cache is the same flat list in our shape:
per package, per release, every revision's time and tar block. It is index-state
agnostic and is rebuilt only when the index is; the filter runs on every read. Three
choices on top of that:

- **`.cabal` files are read by block, never by name.** `hackage-security`'s lookup
  by name answers with the last revision in the whole tar, which is the right
  answer only at the head. `ihLookupGPD` reads the block the filter chose, for the
  baseline and for our provider alike, from one `IndexHandle`.
- **The derived index is keyed on the block too.** Each stored release carries the
  block it was parsed from, and is served only on a match. This also closed a hole
  that predates index-states: a release revised in the weekly refresh was served in
  its pre-revision form until the next `pubgrub-index`.
- **The refresh rule is cabal's.** With no state requested the index is refreshed
  when it is a week old, as before. With one requested it is refreshed only if the
  request is newer than the latest entry held locally, and if it still is after
  that, the run stops with an error rather than solving in a silently smaller
  universe. A request that falls between two entries is answered with the previous
  one, and the line says so.

**What it costs, measured on `vector` without the derived index**, against the
committed tree on the same index. Per run the cache is decoded and filtered one
package at a time, into a map of version sets plus one unboxed array of blocks, four
bytes per release. The sets are lazy over their ascending lists, deliberately: a solve
asks about a few hundred of ~19k packages, and a list is 24 bytes a release where a
set node is 40. Peak residency under the default nursery was 22.9 MB and is 23.0 MB.
Under a 256 KB nursery, which samples the heap often enough to catch the read's
transient, it was 22.5 MB and is 26.0 MB. Allocation went from 819 MB to 971 MB, all
of it in the world phase, whose elapsed time did not move: decoding through
`Data.Binary`'s `Get` allocates about 0.2 GB for the 5.8 MB file. On `pandoc` the same
cost is under 1%. A hand-rolled fixed-layout decoder would remove most of it; it is
not written.

**cabal's residency column moved more, and not because cabal changed.** The baseline
builds ~150k lazy descriptions before it solves, and each now carries the block of
its revision in force so that none of them keeps the version map alive. Under the
default nursery cabal's peak on `vector` reads 50.7 MB on the committed tree and 65.8
MB here; under the 256 KB nursery it reads 64.3 MB and 66.0 MB. The first pair is the
sampling moving, not the heap: `maximum residency` is the largest heap at any major
collection, and with a 4 MB nursery there are six of them in a short run. The
2026-09-22 table in [§3.1](#31-against-cabal-on-the-benchmark-set) carries cabal's
higher figures for that reason, not because cabal changed.
[benchmarking.md](benchmarking.md) records the check.

---

### 4.13 Versions compare with trailing zeros insignificant

`PubGrub.Version` is the solver's version type. A version is spelled as Hackage names
the release, and `Eq` and `Ord` compare the spelling with its trailing zeros dropped,
so `1.2`, `1.2.0` and `1.2.0.0` are one version. Cabal's `Version` orders them
`1.2 < 1.2.0 < 1.2.0.0`. The spelling is kept for display only, the way a
`VersionSet` keeps its declared range ([§4.2](#42-version-sets-are-intensional)): the
lawful part of the type ignores it.
Where two spellings of one version meet at one cut, in an intersection or a union,
the shorter is kept: a declared `aeson >=2.0` against the slot of the release
`2.0.0.0` derives a term that reads `>=2.0`, as the author wrote it.

**Why.** Cabal's order puts version space between spellings of one version, and
nothing published occupies it. The set algebra cannot see that it is empty, so it
carries it. Two shapes reached the proofs. A declared `>=0.3` met the slot of the
release `0.3.0.0`, and the difference left `>=0.3 && <0.3.0.0`, an interval the
search had to discover empty and `scion-browser` printed. And
`^>=4.13.0.0 || ^>=4.14.0.0` stayed two intervals, because `majorUpperBound` keeps
two components and `4.14` sits below `4.14.0.0`. Measured on 2026-09-09 over the 23
gate problems, before the change: 24 no-version incompatibilities were minted, and 8
of them were such holes, of the form `[a, a.0)`. Each cost a decision, a conflict and
a learned clause, and then rule 5 of the reporter
([§4.9](#49-the-report-follows-the-specs-reporting-algorithm)) absorbed it.

**What it deviates from, measured.** The whole index at head on 2026-09-09, 153,495
releases and 2,252,290 dependency mentions, every range compared against the
published versions it admits under each order:

| | count |
| --- | --- |
| packages publishing two spellings of one version | 44 of 19,458 (81 pairs; 15 packages are one author's 2011–2016 family) |
| dependency mentions admitting a different set of versions | 15,725 (0.7%) |
| of those, in the depender's latest release | 1,404, in 943 packages |
| of those, flipping the dependee's newest release | 19 |

Every common shape is one where Cabal's order contradicts the author: `time >=1.8.0`
against the release `time 1.8`, which Cabal excludes; `lens <5.0` against `lens 5`,
which Cabal admits; `base <=4.21` against `4.21.0.0`, which Cabal excludes. On this
machine three latest releases flip their verdict on base 4.21.0.0: `curryer-rpc` and
`double-x-encoding`, which write `<=4.21`, solve here and fail under cabal;
`ghc-debugger`, which writes `>4.21`, the reverse. None is in the problem set, so the
gate's verdict agreement holds at 26/26. **This is the one place the two solvers read
the same index differently, and it is by decision.** The baseline keeps cabal's
order, because that is what cabal does.

**Where the boundary is.** The core knows only `PubGrub.Version`. `Bridge.Hackage`
keeps Cabal's type for the index, the version cache, the derived store and the
baseline, and converts once, lazily per package, into `pkgSolverVersions`: where two
spellings name one version, the later tar entry, which is the later upload, is the
release the solver is offered, and its spelling is kept so the conversion back finds
its `.cabal`. `Bridge.Provider` reads that set and converts back on every release
read. The `impl(ghc …)` guard in `Bridge.Cabal.Flatten` keeps Cabal's `withinRange`:
that is cabal's rule for the compiler guard and the baseline uses the same one.

**What it did to the search, same machine, same index-state, either side of the
change.**

Nine of the 23 problems moved and fourteen did not. The eight phantom no-version
incompatibilities are gone, and the sixteen real ones are untouched:

| | decisions | conflicts | no-version events |
| --- | --- | --- | --- |
| `conduit <1.3` | 19 → **16** | 9 → **8** | 2 → **1** |
| `aeson <2` | 400 → **320** | 68 → **58** | 0 → 0 |
| `yesod` | 827 → 839 | 11 → 14 | 1 → **0** |
| `language-puppet ==1.5.1` | 10 → **9** | 6 → **5** | 1 → **0** |
| `cpsa ==4.4.9` | 11 → **9** | 4 → **3** | 2 → **1** |
| `cabal-install ==3.18.1.0` | 65 → **61** | 5 → 5 | 1 → **0** |
| `futhark ==0.27.1` | 686 → 688 | 7 → 7 | 0 → 0 |
| `scion-browser ==0.5.0` | 186 → **169** | 23 → **21** | 3 → **1** |
| `matterhorn ==90000.1.1` | 584 → **581** | 30 → 30 | 2 → **1** |

`aeson <2` is the same 400 to 320 that narrowing declared ranges to published
versions produced on 2026-09-03 ([§8](#two-things-that-were-measured-and-rejected)),
now for free: the user's own `<2` and the slot bound `2.0.0.0` are one cut. `yesod`
pays twelve decisions and three conflicts, the search-path luck
[§4.4](#44-a-release-owns-a-slot-not-a-point) records for a wider depender term, and
it is the only row that got worse. The proofs kept their 61 sentences.
`scion-browser` lost its phantom interval, and `hjsonschema`'s proof took a different
route through `aeson` at the same length.

### 4.14 A component that is not buildable contributes no dependencies

`Bridge.Cabal.Flatten.componentDeps` puts each sub-library's, each foreign
library's and each executable's dependencies under the condition that the component
is buildable, using Cabal-syntax's own `addBuildableCondition`. That is the function
`Distribution.Solver.Modular.IndexConversion.convGPD` pipes **every** component
through before converting it, so taking it rather than restating it is the same rule
the `pkg-config` predicate follows: a paraphrase is a second implementation to keep
in step.

It rewrites a tree to `if <buildable> then <tree>`, to the empty tree where
`buildable:` is statically `False`, and leaves it untouched where it is statically
`True`. So the condition simply joins the guards already being accumulated, and
costs nothing where nothing is conditional.

**Not applying it rejected plans cabal accepts.** `http2-5.4.4`'s `hpack-encode`
executable declares `aeson >=2, aeson-pretty` and closes with

```
    if flag(devel)

    else
        buildable: False
```

`devel` defaults to `False`, so cabal drops the stanza and never sees `aeson`; we
read `condTreeConstraints` and ignored the node's `buildable:`, so we did. That alone
made `optparse-applicative ==0.15.1.0` alongside `warp` unsolvable here and solvable
for cabal. The same fault put `network-bsd`, `network-run` and `time-manager` in our
`pandoc` plan and five extra packages in our `yesod` plan, through the
`buildable: False` stanzas of `tls-server`, `tls-client` and `crypton-socks-example`
([§3.1](#31-against-cabal-on-the-benchmark-set)).

**The library's buildability is deliberately not gated here.** It is a stronger fact
— an unbuildable library makes the whole release unusable, not merely
dependency-free — and `unbuildableAtDefaults` already carries it to the solver with
the reason attached, which is what lets a proof name the missing `pkg-config` module
([§4.9](#49-the-report-follows-the-specs-reporting-algorithm)).

**There is no target/dependency distinction, and there must not be.** cabal's solver
includes every package's library, sub-libraries, foreign libraries and executables
unconditionally (`convGPD`, the four `concatMap` lines); only test-suites and
benchmarks are gated, by stanza. A target-only rule was tried on 2026-09-10 and
rejected on the evidence: it fixed `warp` but made `futhark ==0.27.1` resolve here
while cabal still failed it, because `lsp-types-2.4.0.0`'s `generator` executable is
genuinely buildable and its `regex` dependency is a real constraint. `solveExecutables`
is not the knob either — it governs `build-tool-depends`, and setting it `False`
changed cabal's plans but left `futhark` failing exactly as before.

**All four unconditional components are covered**: library, sub-libraries, foreign
libraries and executables, the last three gated. Foreign libraries were the last one
in, added on 2026-09-10 for completeness rather than to fix anything — no corpus
problem has one, so `test/FlattenSpec.hs` is the only thing holding them. The two
that stay out, test-suites and benchmarks, are the two cabal itself puts behind a
`Stanza` that a plain `cabal build` never enables.

`storeFormatVersion` is 4: the stored trees are gated before they are written, so a
store from before this serves ungated ones — and one from before the foreign
libraries went in is missing a component outright.

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

Rung 4, not started. `Bridge.Cabal.Flatten.componentDeps` merges library,
sublibraries and executables into one `GuardedDeps` and discards which component each
occurrence came from. It reads neither `setup-depends` nor `build-tool-depends`.

Each component is now gated on its own buildability first, which is what removed the
plan divergence the merge used to cause
([§4.14](#414-a-component-that-is-not-buildable-contributes-no-dependencies)).

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
| **`buildable:` as a condition** | [flags-semantics.md](flags-semantics.md) §1.5 | half built. `buildableCondition` returns the condition and `buildableAtDefaults` evaluates it. Satisfying it rather than evaluating it is the flag-axis half |
| **User flag constraints** (`--flag`) | [flags-semantics.md](flags-semantics.md) §1.6 | do not exist. While every flag is manual, they are the only thing that can move one |
| **The verdict oracle** (test) | [flags-semantics.md](flags-semantics.md) §6 | owed. It blocks condition decisions, and it is what would discharge O4's whole-loop claim |
| **`preferred-versions`** | — | the index reader does not read it. Its entries are in the tar with timestamps, so an index-state would apply to it unchanged |

---

## 7. Which document decides

**Each row is authoritative on its own subject.** The list is not a ranking. The
specifications mostly do not overlap.

| file | authoritative on | status |
| --- | --- | --- |
| [`references/pubgrub.md`](../references/pubgrub.md) | **the algorithm.** A vendored copy of pub's spec | tracked, 1233 lines. Reference — never edit. Before you cite a line, check it: several later citations land on blank lines |
| [flags-semantics.md](flags-semantics.md) | **flags**, and the value and set language | a specification. Only its degenerate case runs |
| [decision-semantics.md](decision-semantics.md) | what a **decision** is | a specification. Nothing in §2–§9 is implemented |
| [`../CLAUDE.md`](../CLAUDE.md) | build commands, architecture, conventions | current |
| [collapsing.md](collapsing.md) | **depender collapsing**: what runs, what it costs, and the five ways to make it cheaper | current |
| [benchmarking.md](benchmarking.md) | **how to run the tests and benchmarks**, and which numbers to trust | current |
| [failure-cases.md](failure-cases.md) | **the failure corpus**: where it came from and what is in it | current |
| [harness-plan.md](harness-plan.md) | **the harness**: why it is shaped that way, and where the build differed | current |
| [reports/](reports/) | the two reports **as generated** by `pubgrub-harness`, each dated in its header | generated. Regenerate with `cabal run pubgrub-harness` and copy; do not edit |
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

1. **What does the 25 MB memory floor consist of?** It is the first thing to settle,
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
decisions, every conflict at depth 0. It now resolves in about two seconds, and it is
in the benchmark set with its counts in
[§3.1](#31-against-cabal-on-the-benchmark-set). It is also the one problem where
cabal beats us.

**Can a quiet run also be a counted run?** Yes. `pubgrub --stats` folds each
`SolverMsg` into counters in-process and prints one `stats:` line after the answer,
with the phase timings on a `phases:` line. `scripts/check-stats.sh` holds it to
`bench/summarise.awk`, number for number, on all 26 problems.

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
one proof line changed (`haddock`'s seven `^>=` windows into `>=4.13.0.0 && <4.20`; since [§4.13](#413-versions-compare-with-trailing-zeros-insignificant) those windows coalesce on construction, and the declared spelling is what prints).
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
| **Explanation showcase** — real failing problems, pubgrub-hs against cabal, side by side | **the problem set exists and we win on all of it, and all of it is pinned.** 20 real failures with every target pinned, six failure kinds, five positive controls. Shorter than cabal on 20 of 20: 76 proof sentences against 193. Shorter on two of the three benchmark unsat problems. Both of the spec's published examples are golden tests, and the linear one matches sentence for sentence. `pubgrub-harness` renders the two explanations as adjacent blocks for the 16 comparable problems, and the 2026-09-22 run is [reports/showcase.md](reports/showcase.md): shorter on 16 of 16 by sentences, 59 against 150 lines; on screen lines at 80 columns 159 against 337, shorter on 15 and equal on one. **On an unconstrained target the record inverts** ([§3.2](#32-against-cabal-on-the-failure-corpus)), and no such problem is in the corpus or the showcase |
| **Benchmark report** — time and peak residency on real problems | **current numbers exist** for six problems, three sat and three unsat, both solvers. We use less peak memory on all six, and are faster and leaner in allocation on five of six. `yesod` is the exception on both. The 2026-09-22 run is [reports/benchmark.md](reports/benchmark.md). Its caveats: timings are medians of three runs against ±25% noise, cabal's lazy per-release parsing lands in its `solve` phase and cannot be separated without changing the work, and the 25 MB memory floor is unexplained |

The baseline and the shared index are done. `cabal-install-solver` drives cabal's
resolver from the same `withWorld`, which is what makes the comparison
apples-to-apples rather than arranged.

The gate decides and the harness measures, and neither replaces the other.
`scripts/gate.sh` runs both solvers over all 26 problems once and fails on any
regression in verdict agreement or proof length. `pubgrub-harness` runs them three
times, diffs the plans, separates the phases, and writes the two reports.

**One thing both deliverables must state outright.** Both solvers run with every flag
pinned to its declared default. That makes the comparison fair, because neither side
can flip a flag to escape. It also makes some real failures unreachable. A benchmark
or a showcase that does not say so is misleading, however honest its numbers are.
