# Decision log

> **What this is.** Every significant turn the project has taken, in order, in
> plain language: what changed, why, and whether it stuck. It exists because the
> other documents describe *where we are* and say little about *how we got here* —
> so a decision that was made, reversed, and remade looks the same as one that was
> right the first time.
>
> **What this is not.** Not a specification and not authoritative on anything. If
> this file and [flags-semantics.md](flags-semantics.md) or
> [references/pubgrub.md](../references/pubgrub.md) disagree, they win. This is
> narrative only.
>
> **Siblings.** [STATUS.md](STATUS.md) is the current state (what works, what is
> open, which file wins). [attic/](attic/) holds the abandoned directions and the
> documents that described them. This file is the *history* only.
>
> **Dates** are author dates. The repo is `jj`, and history rewrites have reset
> committer dates in bulk — several rounds of them landed on 2026-07-28 and
> 2026-07-31 — so committer dates mean nothing here.

---

## How to read this

Each entry is tagged:

- **STUCK** — still true today.
- **REVERSED** — we did this, then undid it. The interesting ones.
- **ABANDONED** — built or drafted, then dropped without replacement.
- **OPEN** — decided but not built, or not decided.

If you only read one section, read **[Open right now](#open-right-now)** at the
bottom. That's the actionable part.

---

## Era 1 — Framing (May 18 – Jun 4)

### Answer Set Programming — ABANDONED

The original plan was to encode dependency solving as Answer Set Programming and
hand it to Clingo (Potassco).

**It never had any code.** Searching the whole history for `clingo` finds it only
in `CLAUDE.md` and design docs; no `.lp` file was ever added, no solver was ever
called. The framing was dropped in favour of implementing PubGrub natively in
Haskell before implementation started.

Worth knowing because ASP still shows up in old docs, and it can read as though a
component was removed. Nothing was removed. `CLAUDE.md` now says so explicitly.

---

## Era 2 — First implementation (Jun 10 – Jun 18)

### A complete, working solver — ABANDONED (rewritten from scratch in Era 4)

In roughly one burst: `VersionSet` over Cabal intervals, `Term` and its algebra,
`Incompatibility`, `PartialSolution`, unit propagation, satisfier search and
conflict resolution, a Hackage-backed provider, lazy index loading, a CLI, and
conflict reporting. Plus `--with-compiler`, boot-package parsing, and progress
tracing via `co-log`.

This **worked end to end on real Hackage data**. It was not a failure, and it was
not abandoned because it was broken. Era 4 restarted it for modelling reasons, not
correctness ones.

### `chooseVersion` + `getDependencies` → `expand` — STUCK (but see [Open](#1-should-expand-split-back-into-two-functions))

*Jun 24.* The provider had two callbacks: pick a version, then fetch that
version's dependencies. They were merged into one `expand`.

**Why:** they always fired back-to-back in the solve loop, so merging removed a
redundant traversal and let the `.cabal` read be skipped entirely when no version
was in range.

Note the date: this is **pre-reboot**. `expand` is one of the few pieces of Era 2
that survived the rewrite intact, which is why it can feel older than the code
around it. It is now under discussion to split *back* — see Open #1.

---

## Era 3 — The abstraction detour (Jun 24 – Jul 3)

### Generalise the solver over a Heyting / Boolean set algebra — ABANDONED

A `Lattice` / `Boolean` / `Sets` class hierarchy, a `Pow` powerset type, and
`Choice` / `ChoiceSet` modelling a package's value as a *product of sets*
(installed units × source configurations), with flags folded into the source
component.

**Why it was dropped:** the value domain doesn't need a Boolean algebra. It needs
intersection, union, difference and an emptiness test — and specifically **not a
complement**, because a complement needs a universe of values that nothing in the
algorithm ever wants. Negation is needed in exactly one place, `Term`, where it's
a polarity flip that costs nothing.

Replaced in Era 4 by `SetOps`: four operations, no complement, no lattice
vocabulary. This is one of the clearest "we made it more general and that was the
wrong direction" turns in the project, and it's worth remembering before
generalising anything again.

### An Alloy model of Cabal build-plan structure — ABANDONED

*Jun 26 – Jun 30.* A formal model of build-plan structure in Alloy, revised once,
then dropped. Left no trace in the tree. The later Lean specification
(`specification/`, Aug 3) is a separate, unrelated attempt at the same instinct.

---

## Era 4 — The reboot (Jul 9 – Jul 23)

The whole solver was restarted from scratch in a single file, `Small.hs`, with
plain concrete types and `Version = Int`, to get the model right before the
plumbing came back.

### Step 1 — separate axes (`Small.hs`, "my version") — REVERSED within two weeks

*Jul 9.* A package's value had **separate coordinates**: a version, a provenance
(source or a specific installed unit), and per-flag terms. Each got its own term
type and its own negation helpers (`notVersion`, `notProvenance`, `notFlag`).

### Step 2 — one whole instance (`Small.hs`, "move to whole instance") — STUCK

*Jul 22.* The axes collapsed into a single value. One solver variable per package
name; its value is one **`Instance`** — either a specific pre-installed unit, or
one source version under one *total* flag assignment.

**Why:** choosing the instance settles version, provenance and every flag at once,
so conditional dependencies are already resolved by the time the solver sees them.
The separate-axes version needed machinery to keep the coordinates consistent; the
merged one gets it for free.

This is still the model today, and it's the single most important decision in the
project. `flags-semantics.md` §1.4 is the retrospective argument for it, including
what it costs (see Open #2).

### Step 3 — `Small.hs` deleted, exploded into modules — STUCK

*Jul 22, "rework".* 649 lines became `src/PubGrub/{Term,VersionSet,Relation,
Incompatibility,Solver,Report,Pretty,…}`, and real Cabal types replaced
`Version = Int`.

`Small.hs` never got a solver loop — it stopped at incompatibilities, with its own
header saying "unit propagation ← next". It was a modelling sketch, not a working
solver.

It is **not** in the tree. It was briefly restored on 2026-08-05 and removed the
same day — see Era 7. Recover it from history if you want to read it:
`git show bedf1210:Small.hs`.

### Step 4 — the algorithm, again, properly — STUCK

*Jul 23.* Unit propagation and conflict resolution reimplemented on the new model.
Provider extracted. Partial solution stored oldest-first in a `Seq`. Real Hackage
bridge. Rung 3 (installed packages, strict prefer-installed). End-to-end tests
including the two PubGrub paper examples.

---

## Era 5 — Making the sets symbolic (Jul 29 – Jul 31)

### Extensional → intensional `InstanceSet` — STUCK

*Jul 29.* `Small.hs` had stored a set of instances literally
(`Set Instance`), with a comment saying a symbolic representation could replace it
later "without the algorithm noticing". It was replaced.

**Why it had to change:** a dependency's declared range must cost **one** entry,
not one per matching version on Hackage. Expanding ranges into concrete versions
is precisely what PubGrub exists to avoid (`references/pubgrub.md:1172`), *and* it
has to be undone again to show a user a range. So `InstanceSet` became a list of
**cells**, each one a version range together with some pinned flag values, with the
set being the *union* of its cells.

That shape is **disjunctive normal form** (DNF) — an OR of ANDs. Within one cell the
conditions are ANDed ("version in this range, *and* `simd` on"); the cells are ORed
together to make the whole set. The term is used without expansion in `CLAUDE.md` and
the specs, so: cells-you-union is all it means here.

**What it cost**, and these are consequences of the choice, not bugs:

- no lawful `Eq` (the representation isn't canonical — use mutual containment);
- **the set cannot be enumerated**, which forced the next entry;
- emptiness became one-sided: allowed to miss that a set is empty, never allowed
  to claim emptiness wrongly.

### "Pick from a preference-ordered universe" → "complete cells from the offered set" — REVERSED in one day

*Jul 30 → Jul 31.* The provider first enumerated a universe of candidates in
preference order and took the first admissible one. A day later it instead took
the offered set's own cells and completed each cell's free flags.

**Why:** the direct consequence of the entry above. A symbolic set can't be
enumerated, so "enumerate the universe, then filter by membership" is not
available. You have to work from the cells you were handed.

### Drop the synthetic root for seed incompatibilities — OPEN, decided but not built

*Jul 30.* Decided: real cabal projects have **several** local packages, not one
root, so `syntheticRoot` / `rootName` is the wrong shape. `solve` should take a
list of seed incompatibilities instead, and "finished" becomes "satisfied by the
level-0 assignments alone".

**Status: not implemented** (re-checked 2026-08-12). `src/PubGrub/Solver.hs:428` still
reads `solve provider rootPkg rootV` and seeds with `notRoot`. The payoff is real —
`constraints: bar <2` is not a dependency, and as a root dependency it wrongly
*forces* `bar` into the plan, whereas a seed incompatibility bans the range
without requiring the package. See Open #3.

---

## Era 6 — Flags, written down (Aug 3)

This is one day, and it's the densest in the project.

### Two-state flag pins → three states — STUCK, and the reason is subtle

A pin was "flag is on" / "flag is off". It became **on / off / not declared here**.

**Why:** flags are declared per *version*. `parser 1.0` may have a `simd` flag and
`parser 1.1` may have none. The opposite of "simd is on" is therefore "simd is off
**or** this version has no simd flag". With two states the negation silently
dropped every version lacking the flag, which makes set difference come out **too
small** — and too small a difference lets the solver derive a fact that isn't true
and report failure for a solvable problem.

This had shipped, twice, fixed locally both times without the rule being written
down. That is why `flags-semantics.md` exists at all (its §0).

### Subsumption pruning — STUCK, and load-bearing

The third state doubled how fast the DNF splits, so pruning had to arrive with it.
Measured on 24 successive instance bans over 4 flags: **28293 cells without
subsumption pruning, 41 with it**, for a denotation of 56 instances. Pruning
*between* operations is what bounds it; pruning only at the end is too late.

### `flags-design.md` superseded by `flags-semantics.md` — STUCK

The older design doc had chosen the **lenient** rule: an undeclared flag makes a
constraint vacuously true. That's the *safe* direction but still not exact, and
because it was implemented as a global rule in membership it couldn't be scoped —
it applied equally to constraints the solver derives itself, where the strict
reading is the required one.

The fix was to separate them: three-case atoms make both readings expressible, so
each boundary states which it means. Leniency survives, but only for **user
input**, translated once, at one boundary.

`flags-design.md` is kept, in [attic/](attic/), and is still wrong on this point.
It is superseded on semantics, not deleted — `flags-semantics.md` cites it four
times as the position it argues against.

### Two same-day self-corrections in the spec — worth knowing

Both are cases where a draft asserted something stronger than the truth:

- *"O6's remedy is search; the 'never select' fact is not an alternative to it."*
  Returning "never select this instance" as a fact does **not** remove the need to
  search for an admissible flag assignment. Both are the same fact used twice; one
  doesn't replace the other.
- *"`expand` never needs a 'no decision, but learn this' answer."* An earlier draft
  of §10 said the split would require a new interface case. It doesn't — the solver
  adds returned incompatibilities unexamined and never requires them to be *about*
  the instance just decided, so what the provider learned along the way can ride
  along with the decision it settles on.

### Performance work — STUCK, all measured

Four changes, and the numbers are the point:

| change | effect |
|---|---|
| index the partial solution by package, cache each package's term | **3.7–4.5× faster** |
| memoise a release's *reduced* form, never its parsed description | uncached 3.7 s / 83 MB; caching descriptions **27.2 s / 904 MB** on `pandoc` |
| version-set algebra on intervals, not on `VersionRange` syntax | — |
| test the cheap half of subsumption first | — |

The second is the counter-intuitive one: caching *more* was 7× slower and 10×
bigger, because ~170 retained parse trees each pin their slice of the index and
every major garbage collection copies the lot. If you ever think "why not just cache the
descriptions" — that was measured, and it was much worse.

### A Lean specification — STUCK (as an artifact)

`specification/` — a Lean formalisation. Unrelated to the abandoned Alloy model
from Era 3.

---

## Era 7 — Recent (Aug 4 – Aug 5)

- **Solution rendered as a dependency tree**, not a flat alphabetical list.
- **An installed unit pins its whole closure**, not just its direct dependencies.
- **`Small.hs` restored, then removed again the same day** (Aug 5). Recovered from
  `bedf1210` and wired as `library small`; removed within hours because **a second
  model of the same concepts, sitting in the tree and building, is confusing rather
  than clarifying** — it shows an extensional `InstanceSet` and a two-field
  `Provider` that the real code deliberately rejected.

  Recorded so it is not proposed a third time. The file is a good *historical* read
  and its lesson is worth keeping, so the lesson now lives in prose —
  [attic/](attic/) §7 — rather than in compilable code that competes with `src/`.
  Recover the file with `git show bedf1210:Small.hs` when you want it.
- **Docs reorganised** (Aug 5): [STATUS.md](STATUS.md) is now the single
  current-state entry point, abandoned directions moved to [attic/](attic/), and the
  three competing flag documents reduced to one live authority.

### Condition decisions specified — OPEN, specified and not implemented

*Aug 4.* [decision-semantics.md](decision-semantics.md), 26 KB, and the most
consequential unimplemented thing in the project. **This is the revisit that
`flags-semantics.md` §1.4 explicitly reserved** ("if the retry cost ever dominates,
this is the decision to revisit").

**The problem it attacks.** A decision today is a *whole instance*: a version plus a
value for **every** flag the release declares. Three costs follow, all from the
decision being a single point:

1. Refuting a flag choice throws away the version decision with it, so the provider
   re-offers a version that was never in question.
2. The provider searches candidate flag assignments *outside* the constraint store,
   redoing narrowing that propagation could do inside it.
3. Every trace, log and report of a decision names flags no conflict involved.

**The idea.** A `.cabal` file's conditional structure is a small set of guarded
additive blocks, so the real search dimension for a release is **its guards** — not
the `2^N` corners of the flag hypercube. So: decide the *version* first, decide a
flag condition only when some dependency's guard needs it, and resolve the remaining
flags to their defaults at the very end.

**Why it's more than an optimisation.** It changes what a decision *is* — from "the
answer for this package" to "a term narrowing this package" — with the answer moving
to a *witness* the provider exhibits. Its §1 is a deviation register listing exactly
which lines of `references/pubgrub.md` it departs from and why the algorithm
tolerates it (a decision need only be cause-less and removable; neither property
mentions being a single point).

**Two things to know before picking it up:**

- **It collects the `expand`-split's benefits for free.** Its §10 states that the
  three arguments for splitting the provider all fall out of §2–§3 — so the two
  items should be scheduled as one, not raced.
- **The sequencing note is the actionable part**, and it argues *against* starting
  here: per-fact guarded emission (`flags-semantics.md` §4.2) is the prerequisite,
  is independently valuable, and alone removes the 2^k re-offer and the depender
  wording gap. **Implement that, measure on real problems, and only then decide**
  whether the kernel change pays. If it does, the verdict oracle lands before or with
  it.

It also has a *hazard* worth remembering, D1: once guarded facts can lie dormant, a
solve can "succeed" while a guard whose dependencies never propagated is then fired
by the final flag assignment — a false *plan*, the exact dual of the false "no
solution" that O6 forbids. That's why the spec spends a section on when success may
be declared.

---

## Era 8 — The baseline, and the first-release scope (Aug 12 – Aug 17)

### cabal's own solver, over our index — STUCK

*Aug 12.* `Bridge.Cabal.Baseline` drives `Distribution.Solver.Modular.modularResolver`
over the same index our solver reads, with **no `cabal-install` dependency**;
`pubgrub --cabal <target>` runs it. One `withWorld` opens the index, the installed db
and (from Aug 17) the `pkg-config` db, so both solvers are fed from one read — which
is what makes the comparison structural rather than arranged. First five-problem
results and the two plan divergences are in [STATUS.md](STATUS.md).

Its first act was to find a bug in *us*: cabal constrains boot packages as
non-reinstallable, we only *preferred* installed units, and `aeson <2` was resolving
by planning to build `base 4.15.1.0` from Hackage. Three of five verdicts disagreed
until our provider carried the same rule. **A baseline earns its cost by disagreeing.**

### Depender collapsing at generation time — OPEN, landed and unfinished

*Aug 12.* `spanningOccurrence` emits one incompatibility per guarded occurrence over
adjacent releases, which is what `references/pubgrub.md:456` asks for. It is a
**trade, not a win**: `aeson <2` 4.7× faster with a 10× shorter proof, `pandoc` 6.6×
slower with 17× the reads, because knowing whether the neighbour carries the same
dependency means parsing its `.cabal`. Five ways out, one measurement to take first,
all in [collapsing.md](collapsing.md).

### Flags fixed at their declared defaults — the first-release scope cut

*Aug 17.* **Flags stop being a search dimension.** They are still parsed and applied —
dependencies are the ones the defaults select — but no flag is a variable the solver
may set. Ours resolves flag conditions at flatten time (`componentDepsAtDefaults`);
cabal's is told at the shared index read (`lookupGPD` marks every flag manual, so
`enforceManualFlags` pins it to the same value). One instance per release, both sides.

Three things worth having on the record, because each is easy to misread later:

- **It is a scope cut, not a retraction.** [flags-semantics.md](flags-semantics.md) is
  unchanged as a specification and its property suite still exercises the full
  three-state algebra; only the degenerate case runs. The machinery stays, and the
  `flags` jj bookmark marks where the axis stands.
- **It silently disarmed the project's worst trap.** Buildability landed the same week
  — the thing Open #2 says must not land alone — and the completeness bug did not
  appear, because with one completion per release the bad case has no instances. The
  trap re-arms when flag search returns, and by then `buildable:` will look finished.
- **It invalidates every measurement taken before it**, including the whole of Era 8's
  first two entries. Re-running `bench/compare.sh` is the precondition for acting on
  any of them.

It also restricts the *problem*: an automatic flag is exactly what cabal would flip to
escape an unsatisfiable dependency, so some problems that resolved will now fail. Both
solvers fail together, which is fair — but any published benchmark or showcase has to
say so.

### Merge on insert, and the walk deleted — STUCK

*Aug 17.* The collapsing trade above was resolved by moving the collapsing from
generation time to insert time. `PubGrub.Store` — new, and the first structure the
core has kept beyond a list of clauses — unions the depender terms of two dependency
facts that agree about the dependee, as they arrive; the provider emits per release
**slot**, so adjacent facts touch and their union is contiguous without reading
anything. `spanningOccurrence` and its `.cabal` walk are gone.

Every metric improved at once, which the walk could not do: `pandoc` 2871 reads → 167,
17.31 → 1.53 GB allocated, 81.0 → 22.6 MB resident; `lens <4`'s proof 80 → 9 lines
against cabal's 22. We are now faster than cabal on all five problems and leaner in
memory on all five.

Three lessons worth the entry:

- **A cheaper place can beat a more faithful one.** The spec puts collapsing at
  generation time and we followed it there first. Insert time gives a weaker rule —
  only the releases the solver expanded — and every observable is better for it.
- **Measure the container change separately from the change it enables.** The store
  went in with merging disabled first: counts identical, allocation within 0.002%. Had
  that cost 20%, the merge would have been evaluated against a moving floor.
- **The obvious shape was not the right one.** All three shapes considered
  (`IntMap` + id order, `IORef` cells, prepend-and-leave) add work to the propagation
  loop, which is the hot path. Keeping the clauses a plain list in scan order and
  paying `O(position)` only on an actual merge costs nothing where it matters.

### Buildability, and the pkg-config db — STUCK

*Aug 17.* A release whose library cannot be built here is no longer offered:
`buildable: False`, plus `pkgconfig-depends` checked against the machine's real
`PkgConfigDb` with cabal's own predicate. `buildableCondition` returns a *condition*
over flags rather than a boolean, so the flag axis can come back and satisfy it
instead of redoing the analysis.

The baseline had been passing `Nothing` for that db with the comment "we do not model
pkgconfig-depends", which is not the neutral value it looks like: cabal reads it as
*no `pkg-config` executable exists* and rejects every `pkgconfig-depends`, then
escapes by flipping `zlib`'s automatic flag — 9 of 29 popular targets taking a flag
flip they did not need. **A stub that looks like an omission can be an assertion.**

---

## Open right now

Four things are genuinely undecided or unbuilt. In roughly the order the existing
docs suggest.

### 1. Should `expand` split back into two functions?

**Status: design item, not a decision.** Written up at
[flags-semantics.md §8](flags-semantics.md) (lines 571–614).

> **Read this alongside condition decisions.**
> [decision-semantics.md](decision-semantics.md) §10 says the condition-decision
> model **inherits all three benefits below** — completeness dissolving into the
> loop, propagation running between attempts, and reasons becoming first-class — so
> the two questions should be scheduled as **one item**. Deciding this one in
> isolation risks paying for it twice.

The provider is one function today: pick an instance *and* report what it entails,
in one step. The reference Rust implementation keeps them separate —
`choose_version` for policy, `get_dependencies` returning
`Available | Unavailable(reason)`, where a rejection adds a "never select this"
fact and **goes back to propagation without deciding anything**.

Three arguments for splitting:

1. A correctness obligation gets much easier. Today the provider must never say
   "nothing available" when something is — a delicate property of code *inside* the
   provider. Split, the solver's own loop does that searching, and terminates
   because each rejection shrinks the set.
2. Propagation would run *between* candidate attempts. A provider looping
   internally works against a snapshot its own discovery has already invalidated.
3. **Rejection reasons become first-class.** Right now an unusable release can only
   appear in a failure report as "no instances in range". The doc calls this a
   *deliverable #1 problem, not cosmetic* — and since explanation quality is half
   of why this project exists, this is the strongest argument.

The sharpest counter-argument to the original merge: its rationale was that the
choice and its consequences must travel together. That requires **ordering**, not
merging — the decision is recorded only after `Available`.

**Cost:** the picker needs a total flag assignment, so it must read the package
description, and the consequences step reads it again. That's already paid for by
`releaseReader`'s memoised reduced form.

### 2. `buildable:`, the completeness search, and a missing test are ONE work item

The most important trap in the project.

**Still open, and the trigger moved.** `buildable:` landed on 2026-08-17 without the
completeness search and nothing broke — see Era 8: fixing every flag at its default
leaves one completion per release, so the bad case has no instances. The item below
now belongs to whoever restores flag search, who will find buildability looking like
finished work. Read it as written and then read that caveat again.

The argument as it stood, when `buildable:` was ignored entirely:

- Nothing in the tree is currently un-buildable *depending on flag values*. So the
  provider's "try one completion per cell" shortcut cannot currently miss a valid
  instance — it's correct **by accident**.
- The moment `buildable:` is implemented, that accident ends, and the shortcut can
  miss a valid instance — which produces a confident **wrong "no solution"**.
- The test that would catch this needs a world where a cell's *default* completion
  is unusable but another completion of the same cell is fine. That world is
  unconstructible until `buildable:` exists.

So: buildability, the completeness search, and the test are **one item, not three**.
Doing the first alone introduces the bug. Splitting `expand` (Open #1) makes this
item *smaller*, which is why the doc schedules them together.

### 3. Seed incompatibilities instead of a synthetic root

Decided 2026-07-30, **not built**. See Era 5. Agreed ordering: do this *before*
depender-range collapsing, because it's the smaller change and it removes a special
case that collapsing would otherwise have to preserve.

### 4. Depender-range collapsing

The one outright **divergence from the PubGrub spec** rather than a choice.

**Largely closed since this was written** — flag axis Aug 5, version axis Aug 12 (Era
8) — and still open in the sense that matters: what landed is a trade, and choosing
how to finish it needs a fresh measurement. [collapsing.md](collapsing.md) is the live
document. The 2^k argument below is also *currently* moot, since flags are fixed.

The case as it stood, when we emitted the per-version form:

The spec requires identical dependencies of adjacent versions to collapse into one
incompatibility — `foo >=1.0 && <1.3 depends on bar >=1.0 && <2`, not one per
version of `foo` (`references/pubgrub.md:456`).

It costs **both** deliverables:

- *Explanations:* proof lines read `foo 1.2.3 depends on …` where the spec's own
  examples read `foo >=1.0 && <1.3 depends on …`.
- *Performance:* and this is the part that's easy to miss. Because the depender is a
  single instance, refuting one version teaches the solver nothing about that
  version under a *different* flag assignment. So a version rejected for a reason
  that has nothing to do with flags gets re-offered once per irrelevant flag
  assignment — **2^k**. `test/FlagSolveSpec.hs` records the k=1 case.

This is the fix for the price Era 4's whole-instance model charges — which is why
`flags-semantics.md` §1.4 names collapsing, rather than a change of model, as the
answer.

**Two corrections worth carrying, because the obvious approach is wrong:**

- **Do not group a package's instances by identical flattened dependency *set*.**
  `flags-semantics.md` §4.2 rejects that as *"a serious mistake, not a conservative
  one"*: two assignments that agree on the dependency in question but differ on an
  unrelated one fail to group, so the depender term still names the irrelevant flag
  and the 2^k cost survives intact. The unit is one **guarded dependency
  occurrence** — `C ⇒ q ∈ R`, with the guard used verbatim as the depender's flag
  component. `CLAUDE.md`'s Reporting gap 1 still prescribes the rejected form; see
  [STATUS.md](STATUS.md)'s contradictions section.
- **This is the recommended next implementation step.** Per
  [decision-semantics.md](decision-semantics.md)'s sequencing note, per-fact emission
  is the prerequisite for the kernel change, is valuable on its own, and should be
  built and *measured* before anything larger is decided.

### Smaller, also open

- ~~**Manual flags**~~ — **settled, and now implemented in its degenerate case.** The
  rule was verified against `cabal-install-solver` on 2026-08-05
  (`Preference.enforceManualFlags`, reading `flagManual` off each `PackageFlag`) and
  owned by input translation, not admissibility (`flags-semantics.md` §1.6). Since
  2026-08-17 *every* flag is marked manual at the index read, so the rule is what both
  solvers run on. What is still unbuilt is the general case: some flags manual, some
  values user-supplied.
- **Give the set algebra access to flag declarations?** Would make emptiness exact
  and delete the one-sided slack, at the cost of the core/bridge boundary. A
  cost/benefit call, not a correctness one.
- **A brute-force verdict oracle** for testing is owed. The current one-sided
  properties are necessary but not sufficient.
- **`collapseNoInstances`** in reports, then chain collapsing, then cosmetics.

---

## Settled — please stop re-litigating

Things decided with reasons recorded, where revisiting has already cost time:

- **No complement in the value algebra.** Four operations plus emptiness. Negation
  lives in `Term` as a polarity flip. (Era 3 tried the Boolean-algebra version.)
- **No `Eq` / `Ord` on `InstanceSet`.** The representation isn't canonical, so
  structural equality would be unlawful. Use mutual containment.
- **Sets stay intensional.** An extensional `Set Instance` isn't a cheaper PubGrub,
  it's the encoding PubGrub exists to avoid.
- **Emptiness stays one-sided.** Missing an empty set costs time. Claiming emptiness
  wrongly gives wrong answers. Test `isEmpty ⟹ empty`, never `⟺`.
- **Flags live in the value, not as solver variables.** A flag variable would need
  conditional existence, which PubGrub has no notion of. The price is the 2^k
  re-offer, and the answer to that price is Open #4, not a change of model. (Since
  2026-08-17 the price is not being paid, because the search is not being done —
  Era 8. That is a scope cut, not a third answer.)
- **The property suite's universe must be non-uniform** — versions must differ in
  which flags they declare, including one declaring none. A uniform universe cannot
  tell the three flag readings apart, which is exactly how a wrong `difference`
  passed for weeks.
- **Don't chase byte-parity with pub's output.** `^1.0.0` is Dart; cabal writes
  `>=1.0.0 && <2`. Same sentences, cabal's syntax.

---

## A known hazard

- **`jj` history rewrites corrupt this repo when run inside the agent sandbox** —
  tracked dotfiles get masked to `/dev/null` and concurrent snapshots interleave.
  The `.jjconflict-base-0/` trees and the bulk-reset committer dates in this history
  are the damage. Run rewrites outside the sandbox.
