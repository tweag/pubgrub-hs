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

Each entry is tagged with **what happened next**, not with what is true today:

- **HELD** — this decision was never undone.
- **REVERSED** — we did this, then undid it. The interesting ones.
- **ABANDONED** — built or drafted, then dropped without replacement.

**This file contains no present tense, on purpose.** It used to carry an "Open right
now" section and `STUCK` / `OPEN` tags, which were a second and unmaintained copy of
the current state. One of them ended up asserting the opposite of the code. For what is
true today, read [STATUS.md](STATUS.md).

**Record a reversal by appending a new era with a forward pointer.** Do not edit an old
verdict. The point of this file is that a decision made, reversed and remade must not
look like one that was right the first time.

---

## Era 1 — Framing (May 18 – Jun 4)

### Answer Set Programming — ABANDONED

The original plan was to encode dependency solving as Answer Set Programming and
hand it to Clingo (Potassco).

**It never had any code.** Searching the whole history for `clingo` finds it only
in `CLAUDE.md` and design docs. No `.lp` file was ever added, no solver was ever
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

### `chooseVersion` + `getDependencies` → `expand` — HELD, and still questioned

*Jun 24.* The provider had two callbacks: pick a version, then fetch that
version's dependencies. They were merged into one `expand`.

**Why:** they always fired back-to-back in the solve loop, so merging removed a
redundant traversal and let the `.cabal` read be skipped entirely when no version
was in range.

Note the date: this is **pre-reboot**. `expand` is one of the few pieces of Era 2
that survived the rewrite intact, which is why it can feel older than the code
around it. Splitting it *back* is still an open question — [TODO.md](TODO.md) §4.

---

## Era 3 — The abstraction detour (Jun 24 – Jul 3)

### Generalise the solver over a Heyting / Boolean set algebra — ABANDONED

A `Lattice` / `Boolean` / `Sets` class hierarchy, a `Pow` powerset type, and
`Choice` / `ChoiceSet` modelling a package's value as a *product of sets*
(installed units × source configurations), with flags folded into the source
component.

**Why it was dropped:** the value domain does not need a Boolean algebra. It needs
intersection, union, difference and an emptiness test — and specifically **not a
complement**, because a complement needs a universe of values that nothing in the
algorithm ever wants. Negation is needed in exactly one place, `Term`, where it is
a polarity flip that costs nothing.

Replaced in Era 4 by `SetOps`: four operations, no complement, no lattice
vocabulary. This is one of the clearest "we made it more general and that was the
wrong direction" turns in the project, and it is worth remembering before
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

### Step 2 — one whole instance (`Small.hs`, "move to whole instance") — HELD

*Jul 22.* The axes collapsed into a single value. One solver variable per package
name. Its value is one **`Instance`** — either a specific pre-installed unit, or
one source version under one *total* flag assignment.

**Why:** choosing the instance settles version, provenance and every flag at once,
so conditional dependencies are already resolved by the time the solver sees them.
The separate-axes version needed machinery to keep the coordinates consistent. The
merged one gets it for free.

This is still the model today, and it is the single most important decision in the
project. `flags-semantics.md` §1.4 is the retrospective argument for it, including
what it costs.

### Step 3 — `Small.hs` deleted, exploded into modules — HELD

*Jul 22, "rework".* 649 lines became `src/PubGrub/{Term,VersionSet,Relation,
Incompatibility,Solver,Report,Pretty,…}`, and real Cabal types replaced
`Version = Int`.

`Small.hs` never got a solver loop — it stopped at incompatibilities, with its own
header saying "unit propagation ← next". It was a modelling sketch, not a working
solver.

It is **not** in the tree. It was briefly restored on 2026-08-05 and removed the
same day — see Era 7. Recover it from history if you want to read it:
`git show bedf1210:Small.hs`.

### Step 4 — the algorithm, again, properly — HELD

*Jul 23.* Unit propagation and conflict resolution reimplemented on the new model.
Provider extracted. Partial solution stored oldest-first in a `Seq`. Real Hackage
bridge. Rung 3 (installed packages, strict prefer-installed). End-to-end tests
including the two PubGrub paper examples.

---

## Era 5 — Making the sets symbolic (Jul 29 – Jul 31)

### Extensional → intensional `InstanceSet` — HELD

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
conditions are ANDed ("version in this range, *and* `simd` on"). The cells are ORed
together to make the whole set. The term is used without expansion in `CLAUDE.md` and
the specs, so: cells-you-union is all it means here.

**What it cost**, and these are consequences of the choice, not bugs:

- no lawful `Eq`. The representation is not canonical, so use mutual containment.
- **the set cannot be enumerated**, which forced the next entry.
- emptiness became one-sided: allowed to miss that a set is empty, never allowed
  to claim emptiness wrongly.

### "Pick from a preference-ordered universe" → "complete cells from the offered set" — REVERSED in one day

*Jul 30 → Jul 31.* The provider first enumerated a universe of candidates in
preference order and took the first admissible one. A day later it instead took
the offered set's own cells and completed each cell's free flags.

**Why:** the direct consequence of the entry above. A symbolic set cannot be
enumerated, so "enumerate the universe, then filter by membership" is not
available. You have to work from the cells you were handed.

### Drop the synthetic root for seed incompatibilities — UNBUILT AT THE TIME, decided but not built

*Jul 30.* Decided: real cabal projects have **several** local packages, not one
root, so `syntheticRoot` / `rootName` is the wrong shape. `solve` must take a
list of seed incompatibilities instead, and "finished" becomes "satisfied by the
level-0 assignments alone".

**Status: not implemented** (re-checked 2026-08-12). `src/PubGrub/Solver.hs:428` still
reads `solve provider rootPkg rootV` and seeds with `notRoot`. The payoff is real —
`constraints: bar <2` is not a dependency, and as a root dependency it wrongly
*forces* `bar` into the plan, whereas a seed incompatibility bans the range
without requiring the package. Still unbuilt.

---

## Era 6 — Flags, written down (Aug 3)

This is one day, and it is the densest in the project.

### Two-state flag pins → three states — HELD, and the reason is subtle

A pin was "flag is on" / "flag is off". It became **on / off / not declared here**.

**Why:** flags are declared per *version*. `parser 1.0` may have a `simd` flag and
`parser 1.1` may have none. The opposite of "simd is on" is therefore "simd is off
**or** this version has no simd flag". With two states the negation silently
dropped every version lacking the flag, which makes set difference come out **too
small** — and too small a difference lets the solver derive a fact that is not true
and report failure for a solvable problem.

This had shipped, twice, fixed locally both times without the rule being written
down. That is why `flags-semantics.md` exists at all (its §0).

### Subsumption pruning — HELD, and load-bearing

The third state doubled how fast the DNF splits, so pruning had to arrive with it.
Measured on 24 successive instance bans over 4 flags: **28293 cells without
subsumption pruning, 41 with it**, for a denotation of 56 instances. Pruning
*between* operations is what bounds it. Pruning only at the end is too late.

### `flags-design.md` superseded by `flags-semantics.md` — HELD

The older design doc had chosen the **lenient** rule: an undeclared flag makes a
constraint vacuously true. That's the *safe* direction but still not exact, and
because it was implemented as a global rule in membership it cannot be scoped —
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

- *"O6's remedy is search. The 'never select' fact is not an alternative to it."*
  Returning "never select this instance" as a fact does **not** remove the need to
  search for an admissible flag assignment. Both are the same fact used twice. One
  does not replace the other.
- *"`expand` never needs a 'no decision, but learn this' answer."* An earlier draft
  of §10 said the split requires a new interface case. It does not — the solver
  adds returned incompatibilities unexamined and never requires them to be *about*
  the instance just decided, so what the provider learned along the way can ride
  along with the decision it settles on.

### Performance work — HELD, all measured

Four changes, and the numbers are the point:

| change | effect |
|---|---|
| index the partial solution by package, cache each package's term | **3.7–4.5× faster** |
| memoise a release's *reduced* form, never its parsed description | uncached 3.7 s / 83 MB. Caching descriptions cost **27.2 s / 904 MB** on `pandoc` |
| version-set algebra on intervals, not on `VersionRange` syntax | — |
| test the cheap half of subsumption first | — |

The second is the counter-intuitive one: caching *more* was 7× slower and 10×
bigger, because ~170 retained parse trees each pin their slice of the index and
every major garbage collection copies the lot. If you ever think "why not just cache the
descriptions" — that was measured, and it was much worse.

### A Lean specification — HELD (as an artifact)

`specification/` — a Lean formalisation. Unrelated to the abandoned Alloy model
from Era 3.

---

## Era 7 — Recent (Aug 4 – Aug 5)

- **Solution rendered as a dependency tree**, not a flat alphabetical list.
- **An installed unit pins its whole closure**, not just its direct dependencies.
- **`Small.hs` restored, then removed again the same day** (Aug 5). Recovered from
  `bedf1210` and wired as `library small`. Removed within hours because **a second
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

### Condition decisions specified — UNBUILT AT THE TIME, specified and not implemented

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

**Why it is more than an optimisation.** It changes what a decision *is* — from "the
answer for this package" to "a term narrowing this package" — with the answer moving
to a *witness* the provider exhibits. Its §1 is a deviation register listing exactly
which lines of `references/pubgrub.md` it departs from and why the algorithm
tolerates it (a decision need only be cause-less and removable. Neither property
mentions being a single point).

**Two things to know before picking it up:**

- **It collects the `expand`-split's benefits for free.** Its §10 states that the
  three arguments for splitting the provider all fall out of §2–§3 — so the two
  items must be scheduled as one, not raced.
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

### cabal's own solver, over our index — HELD

*Aug 12.* `Bridge.Cabal.Baseline` drives `Distribution.Solver.Modular.modularResolver`
over the same index our solver reads, with **no `cabal-install` dependency**.
`pubgrub --cabal <target>` runs it. One `withWorld` opens the index, the installed db
and (from Aug 17) the `pkg-config` db, so both solvers are fed from one read — which
is what makes the comparison structural rather than arranged. First five-problem
results and the two plan divergences are in [STATUS.md](STATUS.md).

Its first act was to find a bug in *us*: cabal constrains boot packages as
non-reinstallable, we only *preferred* installed units, and `aeson <2` was resolving
by planning to build `base 4.15.1.0` from Hackage. Three of five verdicts disagreed
until our provider carried the same rule. **A baseline earns its cost by disagreeing.**

### Depender collapsing at generation time — UNBUILT AT THE TIME, landed and unfinished

*Aug 12.* `spanningOccurrence` emits one incompatibility per guarded occurrence over
adjacent releases, which is what `references/pubgrub.md:456` asks for. It is a
**trade, not a win**: `aeson <2` 4.7× faster with a 10× shorter proof, `pandoc` 6.6×
slower with 17× the reads, because knowing whether the neighbour carries the same
dependency means parsing its `.cabal`. Five ways out, one measurement to take first,
all in [collapsing.md](collapsing.md).

### Flags fixed at their declared defaults — the first-release scope cut

*Aug 17.* **Flags stop being a search dimension.** They are still parsed and applied —
dependencies are the ones the defaults select — but no flag is a variable the solver
may set. Ours resolves flag conditions at flatten time (`componentDepsAtDefaults`).
cabal's is told at the shared index read (`lookupGPD` marks every flag manual, so
`enforceManualFlags` pins it to the same value). One instance per release, both sides.

Three things worth having on the record, because each is easy to misread later:

- **It is a scope cut, not a retraction.** [flags-semantics.md](flags-semantics.md) is
  unchanged as a specification and its property suite still exercises the full
  three-state algebra. Only the degenerate case runs. The machinery stays, and the
  `flags` jj bookmark marks where the axis stands.
- **It silently disarmed the project's worst trap.** Buildability landed the same week
  — the thing that must not land alone, without the O6-complete search — and the
  completeness bug did not
  appear, because with one completion per release the bad case has no instances. The
  trap re-arms when flag search returns, and by then `buildable:` will look finished.
- **It invalidates every measurement taken before it**, including the whole of Era 8's
  first two entries. Re-running `bench/compare.sh` is the precondition for acting on
  any of them.

It also restricts the *problem*: an automatic flag is exactly what cabal would flip to
escape an unsatisfiable dependency, so some problems that resolved will now fail. Both
solvers fail together, which is fair — but any published benchmark or showcase has to
say so.

### Merge on insert, and the walk deleted — REVERSED in Era 11

*Aug 17.* The collapsing trade above was resolved by moving the collapsing from
generation time to insert time. `PubGrub.Store` — new, and the first structure the
core has kept beyond a list of clauses — unions the depender terms of two dependency
facts that agree about the dependee, as they arrive. The provider emits per release
**slot**, so adjacent facts touch and their union is contiguous without reading
anything. `spanningOccurrence` and its `.cabal` walk were deleted.

**The walk came back on 2026-08-23 — see Era 11.** The store merge stayed. What
changed was the price of a neighbour read, not the analysis below.

Every metric improved at once, which the walk could not do: `pandoc` 2871 reads → 167,
17.31 → 1.53 GB allocated, 81.0 → 22.6 MB resident. `lens <4`'s proof went 80 → 9 lines
against cabal's 22. At that point we were faster than cabal on all five problems and
leaner in memory on all five. (The set has since grown to six, and `yesod` is where
cabal wins — [STATUS.md](STATUS.md) §2.1.)

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

### The no-version rise, explained — HELD

*Aug 17.* An unexplained counter had been sitting in the collapsing notes since the
walk landed: `noversion` events up from 1, 1, 0 to 6, 8, 9 on the three unsat
problems. The standing guess was that wide clauses were opening holes in ranges.

Reading the traces instead of theorising: **eleven of the fourteen events were
`base`**, and none was a hole. A non-reinstallable package offers installed units and
nothing else, so any range holding no installed unit makes the provider answer
`Nothing` and the solver learn `noInstances base <that range>` — once per range, five
times on `aeson <2`, all the same fact. Stating it once (`CauseOnlyInstalled`, "base
cannot be built from source") cut `conduit <1.3`'s proof 43 → 12 lines, `aeson <2`'s
178 → 83, and conflict-resolution steps 189 → 18 and 170 → 13 on `conduit` and `lens`.
Two of the three unsat proofs are now shorter than cabal's message.

Three lessons, and the first is the reason this entry exists:

- **A counter is not a diagnosis.** "Unexplained rise in X" survived three sessions
  and two changes that each could have explained it away. Fifteen minutes of reading
  the actual events answered it, and the answer was in a different subsystem than the
  one the counter was filed under.
- **The fix was to state a rule we were already enforcing.** The provider had refused
  source releases of boot packages since 2026-08-12. What was missing was *saying* so.
  Our own baseline had it right all along, as an input constraint.
- **A cause type is part of the fix, not a decoration.** Rendered through the existing
  `CauseNoInstances`, the new fact reads "no version for base in >=0" — false-sounding
  to anyone who knows Hackage has hundreds of them.

### Buildability, and the pkg-config db — HELD

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

## Era 9 — Conformance in the reporter (Aug 20)

### The report follows the spec's algorithm, and one gap turns out to gate another

*Aug 20.* Two changes, both spec conformance, both landing in the explanation
deliverable.

`PubGrub.Report` stopped replaying the derivation tree one node per line and started
following `references/pubgrub.md:504` — fusing a chain of two external facts into one
sentence, and **skipping every other derived step**, which the spec offers in as many
words ("you can skip every other derived incompatibility without losing clarity",
`:528`). Proofs: `lens <4` 6 → 4 lines, `conduit <1.3` 12 → 7, `aeson <2` 83 → 57,
against cabal's 22, 16 and 30. Line numbers are now minted only where the derivation
branches, as `:673` asks.

The transferable part is what pinning the spec's two published examples as tests then
revealed. **The `no version for …` clutter is not clutter — it is load-bearing in the
wrong direction.** Because our ranges are intensional the solver separately learns that
a range's holes are empty, so every dependency fact is paired with a hole-is-empty
sibling, and a fact so paired is never adjacent to the next dependency fact. The chain
fusion therefore cannot fire, and on the spec's own linear example that single effect
is the entire difference between its two published lines and our three.
`collapseNoInstances` had been filed as report polish and scheduled *after* chain
collapsing. It is now the top item, on two independent arguments. **A gap can be
someone else's blocker, and the way we found out was writing down what the spec says
the output must be.**

Alongside it, `references/pubgrub.md:476`: an unbuildable release is now *stated* as an
incompatibility rather than silently skipped, so a proof says `foo >=2.0.0 cannot be
built here` instead of reporting the range as empty. It rides out with the release the
scan settles on (no interface change — incompatibilities are context-independent), and
`PubGrub.Store` merges adjacent slots into one contiguous run, which is `:476`'s
"as well as any adjacent versions" for free.

And a caveat worth more than the change: instrumenting the scan found **zero**
unbuildable releases across all five benchmark problems, so both the new clause and the
skip it replaces are dead code on the current problem set. The buildability rung has
never been exercised by a measurement — only by tests. **A problem set that never walks
a path cannot report anything about it**, which is a requirement on the unsat problem
set the deliverables still need, not on the code.

### Hackage's build reports are where the failures were, and one of them moved a corner into the middle

*Aug 20.* The explanation deliverable had three unsat problems, all found by accident.
Hackage keeps the build bot's report per release, and `PlanningFailed` means cabal
failed to *resolve* — with its solver log attached, which is the baseline half of a
side-by-side for free. About 10% of latest versions are `PlanningFailed`, so the supply
was never the constraint. Nobody had looked. 17 reproduce here, over six failure kinds,
plus five that reproduce as *successes* and are kept as controls
([failure-cases.md](failure-cases.md)).

The finding that cost the most to have been wrong about: **pkg-config failures are the
most common kind** — 14 of 28 among the top 101–500 by downloads — and they arrive in
the shape we had just decided was a corner. `references/pubgrub.md:476` had been
implemented that morning for the case where the scan passes over an unbuildable release
and settles on an older one. The case where the *whole range* is unbuildable dropped the
facts, and this log's own entry called that acceptable. It is the reachable shape, every
time. So the clause was emitted exactly when it could not help and dropped exactly when
it would, and `pubgrub hpqtypes '>=1.13'` said "no version for hpqtypes in >=1.13" where
cabal said "pkg-config package libpq-any, not found in the pkg-config database".

**A five-problem set chosen to measure search cannot report on a path it never walks.**
Zero of the five meets an unbuildable release, which is why the hole survived a
measurement, a test suite and a written caveat on the same day. The lesson is not about
buildability: it is that "measured, no change" means nothing until you know the problem
set exercises the thing. Two other claims in `CLAUDE.md` fell to the same set. The
empty-range clutter was said to have "exactly one known instance", where 9 of 17 carried
those lines. And the synthetic root's name was called a "stray space", where it is a
real NUL byte that makes GNU `grep` silently treat every proof as binary.

### The last non-cosmetic reporting gap, and a harness that was not following the spec

*Aug 20.* `collapseNoInstances` — absorb every "no version for p in r" leaf into the
sibling it was resolved against, and drop the step. It had sat on the list as report
polish since July.

The implementation is smaller than the write-up because of one observation:
**resolving a unit clause against a dependency fact on the pivot unions the two terms
about that package and leaves the other side alone, so the step's conclusion already
IS the dependency with the pivot's term adjusted.** So the pass recomputes nothing. It
keeps the node's terms and re-labels them as the leaf they are equivalent to, which is
why it cannot weaken a proof — and why the test that matters asserts
terms-preservation rather than any wording.

Then the interesting part. With the pass in, the spec's own linear example still came
out three lines against its published two, and the extra line was not the reporter's
fault: `PaperSpec`'s toy provider used the decided release as the depender term, which
is the per-version emission `references/pubgrub.md:456` tells us not to do and which
the bridge stopped doing eight days earlier. **The conformance test was diverging from
the spec in the harness, and reporting it as our divergence.** Given release slots, the
example matches sentence for sentence.

Two lessons, and the second is the reusable one. A gap can be another gap's blocker —
the holes sat between dependency facts, so the chain fusion could not pair them, and
freeing it took the fusion from "seen once, in the spec's example" to 13 of 17 real
problems. And **a test harness that paraphrases the system under test will eventually
be measuring the paraphrase**: this is the second time that has bitten here, after
`FlagSolveSpec`'s hand-written provider went on passing while the real emission
changed under it.

---

## Era 10 — Intra-package dependencies are not constraints (Aug 21)

### A package depending on itself pinned a whole solve, and the report was innocent

*Aug 21.* Found by reading `lens <4`'s proof, whose first line was
*"lens ==1.7 is required"* — a premise with nothing behind it, and the reason every
line below it reasoned about lens 1.7 rather than about all of `lens <4`.

The clause was real and in the store: `{lens: Negative ==1.7}`, a lone negative term,
which nothing in the tree was able to mint. Instrumenting the trace with
each clause's cause named it `CauseDependency`. `lens 1.7` declares a dependency on
`lens ==1.7` — a component of it is built against its own library — and

```haskell
Map.fromList [(pkgName, Positive pkgSet), (depName, Negative depSet)]
```

keeps the **last** binding for a duplicate key. With `pkgName == depName` the
`Positive` depender term was silently dropped, and the conditional fact
"lens ∈ slot(1.7) ⇒ lens ∈ ==1.7" became the unconditional "lens must be exactly
1.7", asserted of every instance of `lens`. It forced the version for the rest of the
solve, and it was the clause whose conflict *terminated* the search.

**Two fixes, and reverting them separately is what shows why both are needed.**
`fromDependency` now uses `Map.fromListWith intersectTerm`, so two entries about one
variable are intersected rather than overwritten —
`intersectTerm (Positive V) (Negative R) = Positive (V \ R)`, which `Term`'s algebra
already had. And `Bridge.Provider` no longer emits the fact at all. With only the
first, the clause becomes *honest* — and an honest clause correctly bans the release,
because its self-dependency genuinely cannot be met. Still the wrong answer, now for
a defensible reason. The second fix is the one that says the constraint was never
real.

**The rule is cabal's, not a shortcut.**
`Distribution.Solver.Modular.Builder.extendOpen` matches `qpn == qpn'` and adds no
goal and no edge, *except* for a setup dependency, where it adds a reverse-dependency
edge alone so the cycle makes the solver pick a different setup script. Its own
comment says the general case waits on component-based solving. There is a second
filter for build-tools — `not $ isInternal pkg exeDep` in `IndexConversion` — because
a `build-tool-depends` on your own executable is internal too. The installed side here
had always done this: `closureEdges` emits no edge for a self-dependency. Only the
source path let one through.

Three things worth carrying forward.

**An intra-package edge is not a version constraint.** It is resolved inside the
package. This is a category error the types permitted: depender and dependee are both
`PackageName`, so nothing distinguished "two packages" from "one package twice".

**Qualified goals will not subsume it.** This was the reason we reached for them, and
it is wrong: `qualifyDeps`'s `inheritedQ` gives library dependencies their depender's
qualifier — only `setup-depends` and `build-tool-depends` override it — so an
executable's dependency on its own library is `qpn == qpn'` under any qualifier
scheme. Qualified goals were shelved on that finding, with the design written up but
unbuilt.

**Rung 4 owes the setup case.** We have no setup or build-tool dependencies yet, so
there is no setup self-dependency to keep an edge for. When they arrive, cabal's
exception has to come back with them.

Regression tests were checked by reverting each half: `StoreSpec`'s three cases fail
without the constructor fix, `FlagSolveSpec`'s three without the emission filter. The
`FlagSolveSpec` world also asserts that `p`'s *other* dependencies are still stated —
dropping too much is as wrong as stating too much.

**Re-measured.** `lens <4`: decisions 317 → **225**, reads 178 → **274**, proof
4 → **7** lines against cabal's 22. The proof got longer and much better — it used to
open on the bogus premise and reason about lens 1.7. It now ends on
`root ==0 depends on lens <4`, so the derivation reaches the root fact and explains the
question that was asked. Four lines answering the wrong question were never a win. Reads
rose and decisions fell for one reason: the bad clause stopped the search early *and*
made the solver work around a constraint that was never real.

---

## Era 11 — A derived index, and the walk restored (Aug 22 – Aug 23)

### A boot package says once why it has no source release — HELD

*Aug 22.* `base` is non-reinstallable, so any range holding no installed unit made
`expand` answer `Nothing`, and the solver learned `noInstances base <that range>` once
per distinct range. The provider now states the fact once, when it first commits to an
installed unit of such a package, and a proof line reads `base cannot be built from
source`.

This removed nearly every `no version for …` line in the failure corpus without
targeting them.

### Every release parsed once, ahead of time — HELD

*Aug 23.* `Bridge.Hackage.Store`. `cabal run pubgrub-index` parses all 152,987 releases
into `_cache/derived-index.cbor` (62.5 MB) plus a 0.4 MB offset map, and a read became
a CBOR decode: **2.007 ms → 0.073 ms**.

Four choices, each with its reason:

- **cache, not source of truth.** Every miss parses instead, so removing the store
  costs speed and never correctness.
- **the pre-environment form, not the flattened one.** `envConfVar` resolves `os`,
  `arch` and `impl` against this machine, so a flattened store would be silently wrong
  after a GHC upgrade. Parsing is 106× the cost of flattening, so caching only the parse
  gives up almost nothing.
- **CBOR, not `binary`.** 410 B per release against 1040. `binary` decodes 2.5× faster,
  but decode had stopped being the scarce resource.
- **the package is the granularity, not the release.** One slice holds every version,
  which is what makes walking a release's neighbours cheap.

**It made no solve faster on its own.** Parsing was 0.3–0.6 s of runs taking 0.7–6.8 s,
and elapsed time was unchanged within noise. Its whole value was that it changed the
price of the thing the next entry needed.

### The walk came back — REVERSES Era 8's deletion

*Aug 23.* `spanningOccurrence` was restored unchanged in shape: no `k`, no gating, no
span cache. Both mechanisms now run — the walk widens at generation time, and the store
still merges on insert.

`pandoc` still does 167 lookups → 2873, the same explosion that got the walk deleted.
It now costs that problem 22.6 → 33.1 MB of residency and under 1% of allocation,
against 17.31 GB before.

**The largest search win the project has recorded:** `futhark ==0.27.1` 4287 → **805**
decisions and 6.62 → **2.19 s**, `aeson <2` 758 → **309**, `conduit <1.3` 137 → **16**.

**The lesson is the one worth keeping.** Era 8's entry named the debt it was taking on
— "a change that makes re-expansion expensive again should look at this first" — and
that is exactly the sentence that came due. Every option weighed in
[collapsing.md](collapsing.md) §4 was a way of *rationing* the walk's cost. The cheaper
move was to remove the cost.

### `yesod` finishes — a consequence, not a change

*Aug 23.* `yesod` had never resolved. It ran past 90 s with thousands of decisions and
every conflict at depth 0, so it was commented out of the benchmark set and kept only
so that it was not forgotten. Its problem was churn, not depth.

It now resolves in **2.49 s**, with 827 decisions and 11 conflicts. Nothing was done to
it. The generation-time walk is what changed, and churn is exactly what a
pre-emptively wide clause removes.

**Worth the entry because of what it says about benchmark sets.** A problem parked as
"does not finish" stops being re-run, so the change that fixes it went unnoticed.

It was then enabled, and the gate re-baselined to 23 problems. It immediately earned
its place: it is the only *satisfiable* problem in the set with real search in it, and
it is the first problem on which cabal beats us — 1.72 s against our 2.49 s, and 1.94 GB
of allocation against our 4.44 GB. The set could not report that before, because every
other row was a walk-through or an unsatisfiable proof.

### A run of same-pair steps is one sentence — HELD

*Aug 23.* Widening clauses changes which conflict surfaces first, and `matterhorn`'s new
one was explained by walking `hashable`'s bound history one adjacent pair at a time.
`PubGrub.Report` now states such a run once, as the union of its facts.

Pure rendering, so every solver count is identical either side of it. `happstack-hsp`
7 → 4, `matterhorn` 10 → 8, corpus total 66 → 62 sentences.

**This is not `references/pubgrub.md:456`'s collapsing.** That merges facts whose
dependee range is *identical*. This one merges facts whose ranges *differ*, which is
exactly why the solver had to derive along them.

---

## Era 12 — The harness (Sep 3)

### One command produces both deliverables — HELD

*Sep 3.* [harness-plan.md](harness-plan.md) was written in the morning and built in
the afternoon. `pubgrub --stats` counted the search in-process and printed the phase
timings; `--plan lines` printed a plan one package per line; `app/Harness.hs` became
`pubgrub-harness`, which ran the driver over both problem sets, three times per solver
per problem, took medians, asserted that every deterministic value agreed across the
repetitions, and wrote `bench/output/benchmark.md` and `showcase.md` with the
environment and the three restrictions in their headers. `scripts/check-stats.sh` held
`--stats` to `bench/summarise.awk` on all 23 problems, and `bench/compare.sh` was
deleted.

**The one constraint that shaped it.** STATUS.md had said one process must run both
solvers. Peak residency and peak RSS are per-process numbers, so that could not be
literal. What the sentence protected — both solvers see one world — was already
guaranteed by `withWorld`, so the harness drove the `pubgrub` executable as a child
process and read what it printed.

**Three places the build differed from the plan.** cabal's plan lines carried no
`lib`/`setup` qualifier, because a `ResolverPackage` has none by then; a package
planned twice was reported as qualified goals showing through. The read counters
stayed on the provider's own closing line instead of joining `stats:`. And the
snapshot date became the mtime of `_cache/01-index.tar`, not `timestamp.json`.

**The lesson worth the entry.** The plan expected the `index` phase to discharge
"index build is not separated from solve". It could not. cabal's `sourcePackageIndex`
build is only the eager allocation of ~153k records; the `PackageIndex` and every
`.cabal` parse are lazy and happen inside the solve. Forcing them earlier would have
made a solve pay for releases it never touched, so the phase would have measured work
the solve does not do. The `world` phase is separated on both sides, and cabal's
per-release parsing stays in `solve` by design.

### The proofs read as sentences — HELD

*Sep 3.* Reading the corpus proofs rather than counting them found three things the
counts had hidden: installed units printed as unit ids (`base base-4.21.0.0-5b43 or
>=0`), negative terms printed raw (`hashable not >=1.4.0.0 && <1.4.0.2 || …`), and the
cosmetics that had sat open since July — the root's synthetic version, `foo >=0` for
"every version of foo", no terminal periods, no blank line between branches.

`PubGrub.Report` took pub's wording (`references/pubgrub.md:677` leaves it to the
implementation; `:1010`–`:1030` lists pub's special cases): a negative term is never
written as "not …", the sentence carries the negation — "P requires N1 or N2", "if P1
and P2 then N1 or N2", "either X or Y", "X is incompatible with Y". `Pretty
InstanceSet` dropped the unit id, printed an installed unit by version, and omitted it
where a source range in the same set already admitted that version. The linear golden
came out matching `:1005` sentence for sentence. Pure rendering: every count was
identical either side.

Then one rule that is not rendering. `:467` omits a depender's lower bound when the
first published version has the dependency. `Bridge.Provider.slotRange` did that for
the first release's slot and for a walk that reaches it. Nothing is published below
the first release, so the range denotes the same instances; its complement no longer
has a `<first` piece for the solver to discover empty. That removed the last `no
version for` line in the corpus (`futhark`, `regex <0.0.0.1`) and one sentence from
`lens <4`. The gate's ceilings moved to 61 sentences and 0 no-version lines.

**The lesson.** "Shorter than cabal on 17 of 17" had been true for weeks while five
of the proofs were unreadable, because a count of sentences cannot see what is in
them. The fixes were a day's work once someone read the output.

### A declared range is quoted as written — HELD

*Sep 3.* Andrea asked whether Cabal's major bound, `^>=`, survived into our output.
Semantically nothing was lost: cabal-install-solver 3.14 made no reference to
`MajorBoundVersion`, so both solvers saw the same interval, and the one consumer of
the distinction was `removeUpperBound` for `--allow-newer`, outside the solver and
unimplemented here. Syntactically it was lost at `fromVersionRange`, and Cabal never
brought it back: `fromVersionIntervals` rebuilt `==v` and nothing else. In the
committed showcase, 16 of our 144 bounded ranges were major-bound shaped, against
15 `^>=` on cabal's side.

**The haddock line was the case.** `^>=4.13.0.0 || … || ^>=4.19.0.0` printed as
seven `>=a && <b` windows that did not coalesce, because `majorUpperBound` keeps two
components: `^>=4.13.0.0` stops at `<4.14`, the next window starts at `>=4.14.0.0`,
and `4.14` and `4.14.0` sit between them in Cabal's order. The hole was real in Cabal's
semantics and empty on Hackage. Nobody added the `.0.0`; haddock's author wrote it.

**Snapping was re-evaluated, with fresh numbers.** The August attempts had measured
`aeson <2` at 23 GB of allocation; the same problem allocated 1.0 GB now. Two variants
ran on eight problems. The closed snap moved the search in both directions and
rewrote every quoted range, the user's own `lens <4` included. Gap-filling, which
merged interior holes no release occupied and never moved an outer bound, left every
counter identical and changed one proof line. The reference implementations
disagreed with each other and agreed on the placement: pub never narrowed a dependee
range, and pubgrub-rs offered `Ranges::simplify` to the reporter only.

**What was built.** pub_semver's move: its `^1.0.0` was a subclass of the plain range
with the same fields and its own `toString`, and `intersect` and `union` never
constructed it. `VersionSet` gained a `declaredRange` beside its intervals, set only
by `fromVersionRange`, dropped by every operation, invisible to `Eq` and `Ord`, and
handed back by `toVersionRange`. The proof then quoted the declared range as its
author wrote it, `base ^>=4.13.0.0 || … || ^>=4.19.0.0`, byte for byte the constraint
cabal's own message quoted, and derived terms went on printing canonically. Every
search counter was identical. `fillGaps` landed tested and unused, in reserve for
derived terms; a filled set has no author's spelling to keep.

### The boot-package fact names the installed version — HELD

*Sep 3.* Andrea asked for a critical reading of how the proofs communicated, wording
and layout both, and whether tree lines or colour would help. The reading found two
content gaps ahead of any formatting: 11 of the 13 showcase proofs turned on a
boot package, and none of them said which version of it was installed. "Because base
cannot be built from source and purescript >=0.15.3 depends on base >=4.16.2.0 &&
<4.17" left the reader to know that the machine had 4.21, while cabal's own line
named it, `base-4.21.0.0/installed-5b43`. The two proofs that did name `base
4.21.0.0 (installed)` did so only because ghc-prim had dragged the unit in.

**What was built.** `CauseOnlyInstalled` gained the installed versions, supplied by
the provider from the installed database at the point it minted the fact, newest
first and one per version. The clause's term was untouched: it still banned the
source side and nothing else, and the versions were for the proof alone. The leaf
then read "base is pinned to 4.21.0.0 (installed)", or "is not installed and cannot
be built from source" for a boot package with no unit. Sentence counts did not move,
so the proof ceiling stayed at 61. The rest of the reading — a headline above the
proof, wrapping with a hanging indent that never breaks inside a range, the branch
blank line the harness dropped, and colour as a TTY-only layer in the driver — was
left for later, in that order.

### A headline stands above the proof — HELD

*Sep 3.* The second content gap from the same reading. The proof was read bottom-up:
its first line was the deepest fact, and the root appeared only on the last, so the
reader of the matterhorn proof met `hashable` before learning that `base` was the
wall. cabal, for all its noise, named the goal on its first line.

**What was built.** `reportHeadline` rendered one line from the same cause tree the
proof was rendered from: the request, as the root's dependency facts in the proof
named it, and the proof's world-fact leaves — only-installed and unbuildable —
verbatim: `No solution for matterhorn ==90000.1.1: base is pinned to 4.21.0.0
(installed).` A pure version conflict carried no colon. The line claimed nothing the
proof did not, since every fact it named was a premise of the derivation below it.
The driver printed it above the proof with a blank line between; the golden proofs
were the spec's and stayed without one. The harness kept the line apart from the
sentences it counted and rendered it above each proof in the showcase, and the gate,
which counted by connective, never saw it — the footing of cabal's own `Could not
resolve dependencies:` line, left out of its count too. Every gate counter stayed
where it was.

### The driver wraps, the reporter does not — HELD

*Sep 3.* The formatting half of the same reading. The showcase counted sentences,
and a sentence ran to 286 characters on `matterhorn` and about 400 on
`hjsonschema`; in an 80-column terminal one such sentence wrapped to five lines with
breaks inside ranges, `>=0.10.8.1 &&` at one end and `<0.10.9.0 ||` at the other.
Compared line for line, "5 sentences against 13" was closer to 20 against 13.

**What was built.** `wrapProof` in the core, applied by the driver: the terminal's
width from `COLUMNS` when stdout was one, 80 columns otherwise, a four-space hanging
indent, and a range kept whole. A token opening with a comparison, `&&`, `||`,
`(installed)` or a bare version stuck to the token before it, so a break fell only
between such atoms; an atom too long for a line of its own broke before a `||`, the
one seam a range had, and one with no seam overflowed rather than break inside.
`reportConflict` was left unwrapped, so the golden proofs stayed the spec's
sentences one per line, and a continuation line started with the indent, which
neither the gate nor the harness counted. The harness stopped filtering the proof
down to its sentences and kept it as printed, which also restored the blank line
between two branches that the showcase had been dropping. Every gate counter stayed
where it was.

Tree lines for the proof were considered and declined: the spec's algorithm
linearises the derivation on purpose and skips every other step, and a tree would
put back what the reporter’s rules removed. A dependency path from the root to the wall,
cargo's "required by" shape, was left as a possible companion.

### Colour is a terminal-only layer — HELD

*Sep 3.* The last item of the reading, and the one placed last: a proof sentence was
a dense mixture of names, ranges and connective prose, and once wrapped, what a
reader still could not do was skim the names and skip the bounds.

**What was built.** `styleProof` in the core, a pure function over the wrapped text:
every range token dimmed — the same predicate `wrapProof` used to keep a range
whole — so the package names stood out by contrast; the connective opening a
sentence bold, so a sentence could be told from its continuation lines; the headline
and the `So,` line bold throughout. Stripping the escapes gave the input back, and a
test said so. The driver applied it only when stdout was a terminal, `NO_COLOR` was
unset and `TERM` was not `dumb`; there was no flag. The gate, the harness and every
log went on reading plain text, and no counter moved. Package names were not
coloured on their own: the rendered text carries no structure that names them, and a
heuristic that guessed would colour "depends" one day. Contrast did the job.

### Two items from the reading were declined, and one metric was added — HELD

*Sep 3.* The dependency path from the root to the wall, cargo's "required by"
shape, was not built. The shortest path is not the reason: on `matterhorn` the
shortest path to `base` was one edge, "every version of matterhorn depends on base
>=4.8 && <5", and installed `base 4.21` satisfied it. The route that conflicted ran
through `mattermost-api`, `aeson` and `hashable`, and picking it out meant replaying
the derivation, which was the proof. A tree that showed the wrong route would have
misled. The back-reference on a join line, which restated the whole cited conclusion
before its "(1)", was left as pub's rule: every reporter in the family restated it,
and a shorter line would have traded a lookup for it.

The wrap learnt to keep a preposition with what was before it and its object, so
"depends on bytestring >=0.10.4 && <0.11" was one atom and neither "depends" nor
"on" ended a line. And the showcase started counting screen lines beside sentences:
ours as printed at 80 columns, cabal's lines as the 80-column rows each filled. A
sentence could run to 400 characters and cabal's lines were unwrapped, so a count
of sentences against lines had flattered neither side honestly. The gate went on
counting sentences.

---

## Era 13 — The index at an index-state (Sep 9)

### A run is pinned to a moment of the index — HELD

*Sep 9.* The weekly refresh had moved cabal's message lengths on 2026-09-03 while
our proofs stood still, and the reports recorded only the tarball's mtime, so no
number in the tree could be reproduced after the next refresh. Andrea proposed
cabal's `--index-state`: a timestamp on the command line, a refresh only when none
was given or the request was newer than the local index, an error when the request
was still newer after that, and only entries at or before the request reaching the
solvers. The mechanism was checked against `cabal-install`'s `IndexUtils.hs` before
anything was written, because neither of us could remember which function filtered
the `.cabal` files by time. The answer was that none did: `filterCache` dropped cache
entries by timestamp and `packageListFromCache` folded the survivors last-writer-wins
by package id, and the revision in force was what the two composed to.

**Revisions were the half the proposal had not covered.** The version cache had been
built from `hackage-security`'s `directoryEntries`, which listed each path once at
its last occurrence, and every `.cabal` was read by name, which answered with the
last revision in the whole tar. Filtering versions by that timestamp would have made
a 2019 release revised in 2025 vanish before 2025, and reading by name would have
solved a 2020 problem with 2025 bounds. So the cache was rebuilt from the full entry
stream, revisions included, each with its time and tar block, and every `.cabal`
read went by block. `aeson ==2.2.3.0` was the demonstration: at `2024-07-01` its
original `ghc-prim <0.12` was in force and both solvers rejected it under GHC 9.12,
and at `2025-07-01` its fourth revision was in force and both planned it.

**The derived index was found to be serving stale revisions.** It had been keyed on
name and version only, so a release revised in a refresh was served in its
pre-revision form until the next `pubgrub-index`. Each stored release gained the
block it was parsed from, and `srLookup` served an entry only on a match. The
store's format went to 2 and the cache's to 6.

**Memory was designed for, then measured, then designed again.** Per run, the
filtered view was one map of version sets plus one unboxed array of blocks, four bytes
per release, with a package holding an offset into it; the cache was decoded and
filtered one package at a time so nothing bigger than a package was ever live, and its
revisions were kept newest first so that the revision in force was the first at or
before the cutoff and the rest were skipped by arithmetic. The first measurement, on
`vector` without the derived index against the committed tree on the same index, put
peak residency at 24.4 MB against 22.3, and a heap profile by closure type found the
2 MB: every version set was now built, where the old cache had left them as lists
behind `Data.Binary`'s lazy `Set` decoder, and a set node is 40 bytes to a list
cell's 24. The sets were made lazy over their lists on purpose, and the number came
back to 23.0 MB against 22.9. Allocation went from 819 MB to 971 MB, all of it in the
world phase and none of it in its elapsed time; an instrumented run put 231 MB of it
in `Get` alone, for a 5.8 MB file, guarding the zero-length `skip` that most releases
hit took 21 MB back, and the rest was left as the price of not writing a decoder by
hand. A first attempt that decoded whole records into lists before filtering was
measured at 1022 MB and dropped.

**cabal's column moved, and the reason was the sampler.** The baseline's ~150k lazy
descriptions had each closed over the index handle, and through the new handle that
was the whole version map for the length of cabal's solve; each was given the block
of its revision in force instead. cabal's peak on `vector` still read 65.8 MB against
50.7 under the default nursery, and 66.0 against 64.3 under a 256 KB one. The
default-nursery pair was the major collections landing elsewhere, not the heap, and
benchmarking.md gained the check. The 2026-09-03 table had under-reported cabal's peak
by about 14 MB on the small problems.

**What else moved.** The driver gained `--index-state` and an `index-state:` line
naming the state a run was really at, with cabal's fallback to the previous entry
when the request fell between two; the harness gained the same flag and an
`index-state` line in the environment header, with a warning if the state varied
across runs; the gate and `check-stats.sh` read `PUBGRUB_INDEX_STATE`. A request
newer than the local index after a refresh ended the run with one line on stderr.
Andrea then asked for the gate and the harness to be pinned at about that moment,
`2026-09-09T06:43:29Z`; Hackage's latest entry was `cryptol-3.6.0` at
`02:42:09Z` and its snapshot was signed a minute later, so the request was one the
index could not honour and the driver refused it exactly as designed. The pin went
into `bench/index-state` as `2026-09-09T02:42:09Z`, the same universe, and the gate,
`check-stats.sh` and the harness all read that file.
Rebuilding the version cache, which now walked the whole tar, cost 2.5 s from the
page cache. The gate passed on the refreshed index of 2026-09-09 with the same 61
sentences, and the test count went from 177 to 205.

---

## Era 14 — The version order is ours (Sep 9)

### Trailing zeros are insignificant — HELD

*Sep 9.* Andrea recalled that a simplification had been declined because Cabal
treated `1.2` and `1.2.0.0` as distinct versions, called that a bug in the semantics,
and asked how many packages on Hackage actually published both spellings. The count
over the index tarball was 44 of 19,458 packages, 81 pairs, 15 of the packages one
author's hoodle and xournal family from 2011 to 2016, the newest pair `gf 3.12` and
`3.12.0` from 2025 with identical `.cabal` files, and `Win32 2.1` and `2.1.0.0` on the
boot list. Asked whether the PVP could improve the output instead, the reading was
that it could not: the spec never mentioned semantic versioning, pubgrub-rs shipped
`SemanticVersion` as a convenience, pub's one semver-aware report step,
`reformat_ranges`, tidied pre-release bounds, and dependencies changed within a PVP
major, so a major could not merge depender slots. The `^>=` sugar was already parsed
by Cabal on the way in and quoted verbatim on the way out.

**The bound side was measured before deciding.** A throwaway program over the
derived index compared, for every dependency range in every release, the published
versions it admitted under Cabal's order with those under trailing-zero
normalisation: 15,725 of 2,252,290 mentions differed, 1,404 of them in a depender's
latest release, 19 flipping the dependee's newest release. The shapes were all Cabal
footguns in the author's disfavour: `time >=1.8.0` against the release `time 1.8`,
`lens <5.0` against `lens 5`, `base <=4.21` against `4.21.0.0`, `mtl >2` against
`2.0.0.0`. Three latest releases flipped their verdict on this machine's base
4.21.0.0, none of them in the problem set.

**The search side decided it.** Over the 23 gate problems at the pinned index-state,
24 no-version incompatibilities were minted and 8 were holes of the form `[a, a.0)`:
`tar >=0.3 && <0.3.0.0`, `hashable >=1.4 && <1.4.0.0`, `aeson >=2.0 && <2.0.0.0`,
one each in conduit, yesod, language-puppet, cpsa, cabal-install and matterhorn and
two in scion-browser. The scion-browser proof printed one. Andrea chose to deviate,
and asked for our own version type rather than a wrapper over Cabal's.

**What was built.** `PubGrub.Version`, spelled as the release was named and compared
on the normal form. `VersionSet` moved its representation onto its own cut pairs,
built a declared range with Cabal's `foldVersionRange` and its own union and
intersection so that every bound comparison was made in our order, kept the shorter
spelling where two equal cuts met, and rendered back to a `VersionRange` from the
cuts. Cabal's type stopped at the bridge:
`Bridge.Hackage` gained a lazy per-package `pkgSolverVersions`, keeping the later tar
entry where two spellings named one version, and the provider converted back on each
read. The property suite's oracle, Cabal's own range algebra, was no longer one, and
the membership properties were named as the semantic oracle instead; seven
trailing-zero properties and two tie-break cases were added, 205 tests to 214. The
measurement program was deleted once its numbers were in `DESIGN.md` §14.

**What it did.** Nine of the 23 problems moved, same machine and same index-state
either side: the eight phantom no-version events were gone, `aeson <2` went 400 to
320 decisions and 68 to 58 conflicts, `scion-browser` 186 to 169, `conduit <1.3` 19
to 16, and `yesod` paid 827 to 839 decisions and 11 to 14 conflicts, the one row that
got worse. The gate passed at 23/23 agreement, 61 sentences and 0 no-version lines,
and `check-stats.sh` agreed on all 23 problems.

## Era 15 — The unbuildable fact names its reason (Sep 9)

### A missing pkg-config module is named — HELD

*Sep 9.* Andrea noticed that a release ruled out by a missing `pkg-config` module was
reported only as `cannot be built here`, where cabal's own message named the module.
The reason had been decided in `Bridge.Cabal.Flatten` and folded to a `Bool` before
the solver saw it; the comment on `wPkgConfig` had admitted as much, "same verdict,
weaker explanation". `CauseUnbuildable` gained a non-empty list of reasons, either
`buildable: False` or a `pkgconfig-depends` the machine's `pkg-config` could not
satisfy, kept whole as Cabal-syntax parsed it. `unbuildableAtDefaults` and its stored
twin returned the reasons instead of a verdict, with `null` of the result equal to
the old boolean by construction, the provider carried them into the fact, and
`PubGrub.Store` keyed the merge of unbuildable facts on the reasons as a set, so two
runs ruled out for different reasons stayed two facts rather than one that put one
release's module on the other's range.

Andrea chose the sentence, twice. First `hpqtypes >=1.10.0.2 cannot be built because
pkg-config package libpq is not found`, over a parenthetical; then, once the real
proof showed "Because … cannot be built because …" in one line, `hpqtypes
>=1.10.0.2 needs pkg-config package libpq, which is not found`, with `is marked
buildable: False` for the other reason and the two joined with "and". The headline
carried the leaf verbatim. The module was spelled as Cabal-syntax printed the field, `libpq` rather
than cabal's `libpq-any`, whose `-any` was its spelling of the empty range. Two
corpus problems carried the leaf, `hpqtypes-extras` and `haskoin-store-data`, and
both named their module. The sentence counts did not move, so the gate's ceilings
held at 61 and 0, and the suite went from 214 tests to 222.

---

## Era 16 — More than one target, and what it exposed (Sep 10)

### The driver takes several targets — HELD

*Sep 10.* Andrea judged the failure corpus unrepresentative: it had been harvested by
running old packages against GHC 9.12, so eleven of its seventeen entries bottomed out
in a boot package, and asked for the driver to solve for more than one package at a
time. Everything below the CLI already did. `Bridge.Provider.withProvider` took a list
of root targets, `Bridge.Cabal.Baseline.solveWithCabal` took a list and derived
`targetNames` from it, and `PubGrub.Report`'s headline already joined several root
requests with "and"; only `Options` and two log lines were single-target.

Andrea chose one constraint per argument, cabal's own `PackageVersionConstraint`
syntax — `pubgrub 'aeson <2' dhall` — over a comma-joined argv that would have kept
`pubgrub aeson '<2'` working. That broke the two-word form deliberately, so
`scripts/gate.sh`, `scripts/check-stats.sh` and `app/Harness.hs` stopped word-splitting
a problem line and split it on commas instead, one argument per target. All 23 problem
lines were unchanged, none having a comma, and the gate held every baseline: 23
problems, 17/17, 23/23, 61 sentences, 0 no-version lines.

### The first multi-target sweep inverted the record — MEASURED

*Sep 10.* The harvesting method was to require every target to resolve *alone* and
then solve them together: if each resolves alone the boot-package wall cannot be the
sole cause, so a failure of the group is a conflict between the targets. Unconstrained
pairs were worthless — 153 pairs of popular packages, 153 resolutions — so one target
had to be pinned back. 18 apps against 83 pins that resolved alone gave 1411 runs and
23 failures, in about three distinct shapes, 19 of them `optparse-applicative` pins.

We lost 21 of the 23, at 28–113 sentences against cabal's 10–26, against 17/17 wins on
the single-target corpus. The one clean win was `aeson ==2.3.x` alongside `dhall`, four
sentences against cabal's sixteen with no boot package in it at all. The cause of the
losses looked structural rather than reparable: an *unconstrained* target obliges a
complete proof to show that every one of its releases fails, so it walks the whole
version history, where cabal's message is a search trace and may stop at the first wall
it hit. Every target in the old corpus is pinned to one version, which is why the walk
had never appeared.

### A component that is not buildable contributes no dependencies — HELD

*Sep 10.* Two of the 23 were verdict disagreements rather than long proofs:
`optparse-applicative ==0.15.1.0` alongside `warp`, where cabal found a plan and we did
not. `Bridge.Cabal.Flatten.componentDepsWith` walked `condLibrary`, `condSubLibraries`
and `condExecutables` and read each tree's `condTreeConstraints` while ignoring its
node's `buildable:`, so `http2 ==5.4.4` pulled `aeson` and `aeson-pretty` in through
`hpack-encode`, a stanza that ends `if flag(devel) … else buildable: False` and that
cabal therefore never sees. STATUS.md §2.1 and §4.3 had recorded the effect since
Sep 3, but only as extra packages in a *satisfiable* plan — `network-run` under
`pandoc` — which read as cosmetic. It was not: it rejected plans cabal accepts.

Andrea first gave the rule as executables of requested targets always included and
dependencies bringing in libraries only, and that was built and measured before being
rejected on its own evidence. It fixed `warp` and broke `futhark ==0.27.1`, which
began resolving here while cabal still failed it: `lsp-types-2.4.0.0`'s `generator`
executable is genuinely buildable and its `regex` dependency is a real constraint, so
the gate fell to 16/17 on the corpus and 22/23 on agreement. `solveExecutables` was
not the knob either — set to `False` it dropped `alex`, `happy`, `happy-lib` and
`hsc2hs` from cabal's plans and left `futhark` failing exactly as before, because it
governs `build-tool-depends` and nothing else.

Andrea pointed at cabal-install's own planning code, and
`Distribution.Solver.Modular.IndexConversion.convGPD` settled it: library,
sub-libraries, foreign libraries and executables are all included unconditionally,
with only test-suites and benchmarks gated by stanza, and every one of them is piped
through Cabal-syntax's `addBuildableCondition` first. So the rule was not about which
components but about which are built. `componentDeps` began applying that same
function to sub-libraries and executables, `toStored` applied it before writing so
both paths agree by construction, and `storeFormatVersion` went to 3 because a store
written before it holds ungated trees. The library stayed ungated on purpose:
`unbuildableAtDefaults` already carries its buildability with the reason attached,
which is what lets a proof name the missing `pkg-config` module. The suite went from
223 tests to 226.

### Foreign libraries are read too — HELD

*Sep 10.* Andrea asked for foreign libraries as well, to have all the simple cases
covered rather than to fix anything. They are the third of `convGPD`'s four
unconditional `concatMap` lines and the one component we had left out; they went in
gated exactly like sub-libraries and executables, `storeFormatVersion` went to 4, and
the two that stay out are the two cabal itself puts behind a `Stanza` a plain
`cabal build` never enables. No corpus problem has a foreign library and no number
moved, so `test/FlattenSpec.hs` is the only thing holding it: one case asserting the
dependency arrives and its `buildable: False` twin asserting it does not. The suite
went to 227.

---

## Era 17 — A run collected by depender alone (Sep 10)

### Rule 4 of the reporter: the widening run — HELD

*Sep 10.* The multi-target sweep left us losing on proof length to cabal on 21 of 23
problems, and Andrea asked what to do about it. Two things were true at once.

The comparison was measuring different objects. On `optparse-applicative ==0.15.1.0,
criterion` cabal prints 26 lines of which 20 are `trying:` — a witness path of
*successful* assignments — two carry the whole reason, and the last is an apology
naming 26 goals it "had most trouble fulfilling"; it explains `criterion-1.6.5.0` and
never says why 1.6.4 and below fail. Four of the 23 end at `Backjump limit reached`,
so cabal reports a resource limit where we report a refutation. Counting its lines
against our sentences only looks fair because every problem in the old corpus pins
its targets.

But the proofs were also too long, and the shape was specific. Dumping the derivation
tree for `optparse-applicative ==0.15.1.0, aeson` showed thirteen consecutive steps
folding in one `aeson` dependency each — `base`, `deepseq`, `template-haskell`,
`ghc-prim` six times, `semialign` — with every other term standing still, and
fourteen more striking `directory`'s slots off one at a time. Rule 3 could not touch
either: it collects by `(depender, dependee)` and these runs change dependee at almost
every step. Collecting by **depender alone** and stating the run as
`p ⋃S requires q₁ ⋃R₁ or … or qₙ ⋃Rₙ` is sound for rule 3's own reason — if `p` is in
the union it is in some `Sᵢ`, whose dependee is one of the disjuncts.

**The guard is the operation.** The first attempt described the step instead of taking
it: a hand-written term algebra that unioned matching polarities. It collapsed the
`aeson` walk and refused the `directory` one, because there the depender is *negative*
in the conclusion — the solver is eliminating it slot by slot, not accumulating it.
Rather than add cases, `priorCauseTerms` was split out of `priorCause` and is now
applied once to the run's merged fact; the collapse is taken only when it lands term
for term on the conclusion the line is attached to. That covers both shapes without
naming either, and it cannot drift from the solver, since it *is* the solver's
arithmetic. Doing it that way also found a third case the paraphrase had refused.

Three facts minimum. Two already fit one line with both named, and naming both says
strictly more than naming their union.

Corpus 61 → 60 sentences with the golden proofs unchanged, and on the multi-target
problems 46 → 34, 65 → 54, 63 → 46, 33 → 30. `mergeFacts` refuses a run where some
package is a depender in one fact and a dependee in another, which is what stopped the
remaining `process`/`directory` interleaving — correctly: the union argument is about
one depender. The suite went to 232.

**We still lose to cabal on an unconstrained target**, and the residue is not a run:
the remaining sentences each name a different depender. What is left is a genuinely
broad refutation against a message that reports one path.

---

## Era 18 — Seeds instead of a synthetic root (Sep 22)

### The request is a list of incompatibilities — HELD, decided Jul 30, built Sep 22

*Sep 22.* Andrea asked for the July decision to be built. `solve` took a root
package and its instance, seeded the store with `{not root}`, and the bridge answered
the root's expansion with one dependency fact per target. The root then had to be
decided, printed at the top of every tree, deleted from every plan, filtered out of
the harness's diffs, and named `"\0root"` so it could not collide with a real
package, which put a NUL byte in every proof and a `-a` on every grep.

`solve` now takes a list of seeds, one `request p R` per target, the unit clause
`{p: Negative R}` with cause `CauseRequest`. The bridge builds them in
`withProvider`, since widening a range to instances needs the installed db. Three
things in the kernel moved with it, each checked against the spec:

- the terminal test became "satisfied by the seed derivations alone", the spec's
  `:377` with the root's derivation replaced by the seeds'. A conflict satisfied at
  level 0 by a *learned* derivation is not terminal and resolves on through that
  derivation's cause, so the proof still says why the fact was forced;
- the backtrack floor `max 1` went. The spec keeps level 1 because that is where its
  root was decided and says level 0 is safe (`:399`–`:404`). With the seeds at level
  0 the first decision at level 1 is an ordinary target, and a learned unit clause on
  it had to be able to undo it; with the floor kept, that case looped;
- a terminal conflict is closed against the seeds it rests on, one `priorCause` per
  seed, so the reported incompatibility is empty and the last line keeps the spec's
  shape, "So, because …, version solving failed", with the request as its last fact.

The wording of a seed is "aeson ==2.3.1.0 is requested", two of them "baz >=1.0.0
&& <2 and foo >=1.0.0 && <2 are requested", one with an empty range "aeson >9 is
requested, which has no versions". The paper's two golden proofs changed on their
last line only, and the paper's root is no longer a package of those worlds: its
dependencies are the seeds, which is what `:252` says the root stands for.

Measured on the 26 gate problems: every verdict the same, every proof the same
length, 76 sentences, and every problem one decision fewer. The driver renders a
forest, one tree per target. The `-a` in the scripts stayed as a precaution.

---

## What is open, and what is settled

Not here. [TODO.md](TODO.md) §5 and §6 carry both lists, where they are re-read.

---


## A known hazard

- **`jj` history rewrites corrupt this repo when run inside the agent sandbox** —
  tracked dotfiles get masked to `/dev/null` and concurrent snapshots interleave.
  The `.jjconflict-base-0/` trees and the bulk-reset committer dates in this history
  are the damage. Run rewrites outside the sandbox.
