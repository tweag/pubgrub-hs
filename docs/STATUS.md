# Status — where the project actually is

> **What this is.** The single current-state document. What works, what is written
> down but not built, what is not decided, and **which file wins when two
> disagree**. Written in plain language on purpose.
>
> **What this is not.** Not authoritative. It summarises; the documents in the
> table below decide. If this file contradicts one of them, that one is right and
> this file is stale — fix it.
>
> **Last checked against the tree:** 2026-08-05, 95 tests passing.
>
> History lives in [decision-log.md](decision-log.md) (how we got here);
> abandoned ideas live in [attic/](attic/) (what we tried and dropped).

---

## The 60-second version

pubgrub-hs is a **proof-of-concept**, not a cabal-install integration. Solving
correctly is table stakes. It exists to answer two questions:

1. Can PubGrub **explain resolution failures** better than cabal-install's solver?
2. Can it **match cabal-install on time and peak memory** on real problems?

**The solver works.** It resolves real Hackage packages end to end, with version
ranges, Cabal flags, and installed/boot-package pinning. 95 tests pass, including
both worked examples from the PubGrub spec.

**Neither deliverable has been delivered.** There is no benchmark harness and no
cabal baseline wired in, so nothing has been *compared* to anything. A first cut of
our own numbers exists — see [Measurement](#measurement--first-results) — and its
main result is about the apparatus rather than the solver: the standing stress case
has one conflict in it, and peak residency currently measures the index reader.
The interesting half of the project has barely started.

---

## Which file wins

The question this table exists to answer is "which one is newest / which do I
believe". **Each row is authoritative on its own subject** — the list is not a
ranking, because the specs mostly do not overlap. Where two genuinely could collide,
the "authoritative on" column says who owns the question.

| file | authoritative on | status |
|---|---|---|
| [`references/pubgrub.md`](../references/pubgrub.md) | **the algorithm.** Vendored copy of pub's spec | reference — never edit |
| [`flags-semantics.md`](flags-semantics.md) | **flags**, and the value/set language | spec, 2026-08-03, largely implemented |
| [`decision-semantics.md`](decision-semantics.md) | what a **decision** is (condition decisions) | spec, drafted 2026-08-04, **nothing implemented** |
| [`../specification/`](../specification/) | the formal kernel model, in Lean | executable; **Lean code is normative over its own prose** |
| [`../CLAUDE.md`](../CLAUDE.md) | architecture, the rung ladder, conventions | current |
| [`specification.md`](specification.md) | Cabal's **build model** (components, scopes, Backpack) | reference for rungs 4–5, nothing implemented |
| [`bridge-and-problem-model.md`](bridge-and-problem-model.md) | why the bridge is shaped as it is | 2026-07-23 notes, partly pre-reboot |
| [`pubgrub-intro.md`](pubgrub-intro.md) | tutorial introduction to PubGrub | useful, three stale sections (flagged in it) |
| [`flags-semantics-review.md`](flags-semantics-review.md) | an independent review of the flag spec | 2026-08-05; findings folded in, kept as the record |
| [`decision-log.md`](decision-log.md) | project history | narrative, not authoritative |
| this file | current state | summary, not authoritative |

**Only one document is authoritative on flags: `flags-semantics.md`.** The other
two flag documents were the confusing part and have moved to
[`attic/`](attic/) — `flags-design.md` (superseded on semantics; it chose a rule
that turned out to be wrong) and `flags-spike.hs` (the spike whose test universe
hid the bug).

### The one-sentence version of each spec

- **`flags-semantics.md`** — flags are declared per *version*, so a statement about
  a flag needs **three** states (on / off / not declared here), because negation
  must keep the versions that lack the flag.
- **`decision-semantics.md`** — a decision should not have to name every flag. Decide
  the *version* first, then decide only the flag conditions some dependency actually
  guards, and resolve the rest to defaults at the end. It opens with a **"Plain
  version"** section — an informal analogy plus a vocabulary table — so start there
  rather than at its §0.

### How those two relate

They are **layered, not competing**, and it is worth being precise because the names
sound like rivals:

- `flags-semantics.md` defines the **language**: what a value is, what a constraint
  mentioning a flag means, which set operations must be exact.
- `decision-semantics.md` defines what the **solver does** with that language: what a
  decision is, and when a solve may declare success.

Three consequences:

1. **`decision-semantics.md` defers to `flags-semantics.md` on flags** (it says so in
   its own Authority block) and amends it only where its §11 lists. It never overrules
   it. It deviates from `references/pubgrub.md` only where its §1 registers.
2. **It has a hard prerequisite** — per-fact guarded emission,
   `flags-semantics.md` §4.2 — and says of itself that it *"is inert without"* it.
   §4.2's **flag axis is implemented** (2026-08-05); its **version axis is not**, and
   that is the half `references/pubgrub.md:456` actually asks for. So the prerequisite
   is half paid.
3. **It is the revisit `flags-semantics.md` reserved.** §1.4 there recorded that
   putting the flag in the value costs 2^k re-offers and said "if the retry cost ever
   dominates, this is the decision to revisit." `decision-semantics.md` §0 is that
   revisit.

The division of labour on that 2^k cost is the cleanest way to see the split:
**§4.2 keeps irrelevant flags out of the learned clauses; condition decisions keep
them out of the decisions too.** Three costs survive §4.2, all because a decision is
still a single point instance.

They also split the flag algebra by role, which sounds like a contradiction and is not:

> **Two-valued where you decide, three-valued where you collapse.**

Two releases are enough to see why. Say:

```
parser 1.0    has a flag called simd
parser 1.1    has no flags at all
```

**Deciding — two states are enough.** Suppose the solver has already settled on
version `1.0`. Now it wants to try `simd` on. If that turns out badly, the opposite of
"`1.0` with simd on" is just "`1.0` with simd off". Two cases, because we already know
`1.0` *has* a `simd` flag — the question doesn't arise. So a decision never needs a
third state.

**Collapsing — two states lose a release.** Now the term covers a *range* instead of
one release, which is what dependency collapsing produces. Compare:

- `A` = "any parser from 1.0 up to 2" — that's `1.0` and `1.1`
- `B` = "any parser from 1.0 up to 2, with simd on" — that's only `1.0 +simd`

What is in `A` but not in `B`? Two things:

1. `1.0` with simd **off**
2. `1.1` — which is in the range, and certainly isn't "simd on", so it must survive

With only on/off, you can express (1) but not (2): `1.1` has no `simd` to be *off*.
It silently disappears — and the solver then believes a release is ruled out when it
isn't, which is how it can report "no solution" for a problem that has one. The third
state, "this release has no such flag", is what keeps `1.1`.

**The difference in one sentence:** deciding fixes a single release, so the flag's
existence is known; collapsing spans releases, so *whether the flag exists at all*
varies across the term and has to be sayable.

**This is checkable without running the solver, and it checks out.** Evaluated against
the real `InstanceSet` on 2026-08-05, `A ∖ B` comes out as exactly two cells:

```
[(simd, PinnedTo False)]     -- keeps 1.0 -simd
[(simd, NotDeclared)]        -- keeps 1.1        ← only this one does
```

and membership confirms `1.0 -simd` ✓, `1.1` ✓, `1.0 +simd` ✗ (correctly excluded).
Dropping the second cell — which is what a two-state pin gives you — leaves `1.1` a
non-member, i.e. silently excluded from a set it belongs to. That is the whole bug, in
one line of output. It is the acceptance test in
[`flags-semantics.md`](flags-semantics.md) §9.

**A note on the labels.** These specs name their rules with letters and numbers —
`flags-semantics.md` has **O1–O7** ("O" for *obligation*: things the code must
guarantee) and `decision-semantics.md` has **D1–D3** ("D" for *decision*: rules about
when a decision may be made or success declared). They are just names, so you can look
one up; there is no hierarchy implied by the numbers. The ones cited most often here
are **O6** (the provider must never report "nothing available" when something is) and
**D1** (when a solve is allowed to declare success).

---

## What works today

- **Rung 0** — our own Hackage index reader, on real cached `01-index.tar`, handling
  `.cabal` revisions (last wins) and `preferred-versions`.
- **Rung 1** — version ranges. Resolves real packages end to end.
- **Rung 2** — flags and conditional dependencies as a search dimension. A decision
  is a version plus a total flag assignment; the provider tries the all-defaults
  assignment first and deviates only when forced, fewest deviations first.
- **Rung 3** — `base`/GHC pinning: the installed database becomes pre-installed
  instances, with strict prefer-installed, and an installed unit pins its whole
  closure.
- **Explanations, partly** — cause tracking exists and `PubGrub.Report` prints a
  numbered proof. Both unsatisfiable examples from the PubGrub spec are tests.
- **Output** — the solution renders as a dependency tree.

### Performance work already done, with numbers

These are measured, and two of them are counter-intuitive enough to be worth
remembering before "optimising" in the same area again.

| change | effect |
|---|---|
| index the partial solution by package; cache each package's term | **3.7–4.5× faster** |
| memoise a release's *reduced* form, never its parsed description | uncached 3.7 s / 83 MB; **caching descriptions was 27.2 s / 904 MB** on `pandoc` |
| subsumption pruning between set operations | 24 bans over 4 flags: **28293 cells without it, 41 with** |

The middle row is the trap: caching *more* was 7× slower and 10× bigger, because
retained parse trees each pin their slice of the index, and every major garbage
collection then copies the lot.

---

## Written down but not built

Everything here has a specification and no implementation. **Do not assume any of
it exists in the code.**

| thing | spec | note |
|---|---|---|
| **Condition decisions** (its rules D1, D2, D3) | [`decision-semantics.md`](decision-semantics.md) §2–§9 | kernel-level change to what a decision is |
| **§4.2's version axis** — widening a depender across adjacent releases | [`flags-semantics.md`](flags-semantics.md) §4.2 | the flag axis landed 2026-08-05; this half needs `NotDeclared` and is what `pubgrub.md:456` asks for |
| **Seed incompatibilities** instead of a synthetic root | [decision-log](decision-log.md#5-open-decisions) | decided 2026-07-30; `solve` still takes `rootPkg`/`rootV` |
| **`buildable:`** | [`flags-semantics.md`](flags-semantics.md) §1.5 | ignored entirely today — see the trap below |
| **Manual flags** | [`flags-semantics.md`](flags-semantics.md) §1.6 | rule now settled and locally checkable against cabal's `enforceManualFlags`; it is *input translation*, not admissibility |
| **User flag constraints** (`--flag`) | [`flags-semantics.md`](flags-semantics.md) §1.6 | do not exist yet |
| **Rung 4** — setup / build-tool deps | — | not started |
| **Rung 5** — public sublibraries | — | not started |
| **The benchmark harness** | — | nothing exists; the larger of the two deliverables |
| **The verdict oracle** (test) | [`flags-semantics.md`](flags-semantics.md) §6 | owed; blocks condition decisions, and is what would discharge O4's whole-loop claim |

---

## The one trap worth knowing before you touch anything

**`buildable:`, the completeness search, and a missing test are one work item.**

It looks like three separate gaps. It is not:

- Nothing in the tree is currently unusable *depending on flag values*. So the
  provider's shortcut — try one flag completion per candidate region — cannot
  currently miss a valid instance. It is **correct by accident**.
- The moment `buildable:` is implemented, that accident ends, and the shortcut can
  miss a valid instance. The symptom is a confident, wrong **"no solution"**.
- The test that would catch it needs a world where the *default* flag completion is
  unusable but another completion of the same region is fine — and that world cannot
  be built until `buildable:` exists.
- And it is **written into the spec, not only the code**: `flags-semantics.md` §5's
  selection recipe was itself phrased against the accident until the 2026-08-05
  review caught it. §5 is now stated as policy over an O6-complete search, so the
  search and the policy have to land together.

So: implement buildability, the search, and the oracle together. Doing the first
alone introduces the bug. `flags-semantics.md` §10 states this; it is repeated here
because it is the easiest expensive mistake available.

---

## Open questions

Full arguments in the linked sections; this is the index.

1. **Should the provider's `expand` split back into "pick" then "consequences"?**
   ([`flags-semantics.md`](flags-semantics.md) §8.) Design item, not a decision.
   **Note the interaction:** [`decision-semantics.md`](decision-semantics.md) §10 says
   the condition-decision model *inherits all three benefits* of the split, and that
   the two should be scheduled as one item.
2. **Depender-range collapsing, version axis** — the remaining half of the outright
   **divergence from the PubGrub spec** (`references/pubgrub.md:456`). The flag axis
   landed on 2026-08-05: the 2^k re-offer is gone (measured — 2 expansions where it
   was 3 with one irrelevant flag and 5 with two), and depender terms now carry the
   guard rather than the whole assignment. What remains is widening a depender across
   *adjacent releases* — see the notes below before starting it.
3. **Should the set algebra be allowed to read flag declarations?** Would make
   emptiness exact and remove the one-sided slack, at the cost of the core/bridge
   boundary. Cost/benefit, not correctness.
4. **`collapseNoInstances`, and it may not be cosmetic.** Filed under report polish
   in `CLAUDE.md` (Reporting gap 2), but the measurement below found it is where all
   the deep conflict resolution goes: the three deepest resolutions in `aeson <2`
   (9, 10 and 18 iterations) are each a gappy range being learned one hole at a time.
   That is an argument for weighing it against the version axis rather than after the
   cosmetics — both are about ranges, and this one has measured depth behind it. Then
   chain collapsing, then wording.

### Notes on the version axis, before anyone starts it

**What changes.** If `foo` 1.0, 1.1 and 1.2 all depend on `bar >=1.0 && <2` and 1.3
dropped it, three facts become one:

```
{foo 1.0, not bar >=1.0 && <2}
{foo 1.1, not bar >=1.0 && <2}     ⟶     {foo >=1.0 && <1.3, not bar >=1.0 && <2}
{foo 1.2, not bar >=1.0 && <2}
```

The bounds rule is exact in the spec: inclusive lower bound at the first version
that **has** the dependency, exclusive upper bound at the first that **doesn't**,
each omitted when the run reaches the oldest or newest published version.

**Why it is the harder half.** The flag axis needed no new information — the guard
was already in `GuardedDeps` and `depsAt` was discarding it. This one does: the
provider is asked about *one* version and must establish what its **neighbours**
declare, which means reading their `.cabal` files. That is in direct tension with
the laziness the same spec paragraph asks for ("lazily when each package version is
first chosen, to avoid flooding the solver"), and this is a measured-expensive area
— retaining parsed descriptions once cost 27.2 s / 904 MB on `pandoc` against
3.7 s / 83 MB uncached. Any walk must stay in reduced form and memoised.

**What `NotDeclared` is actually for here, which is narrower than it first looks.**
[Two-valued where you decide, three-valued where you collapse](#how-those-two-relate)
above shows why the third state is *necessary* when a run spans releases that
disagree about whether a flag exists: dropping it loses `parser 1.1` unsoundly.

The narrower point, which that section does not cover: when every release in the
run **does** declare the flag, the negation still produces that cell and it is
simply empty. Same two worlds, measured against the real `InstanceSet`:

```
cells in A∖B: 2                            ← identical in both worlds
isEmpty (NotDeclared cell alone) = False   ← even when nothing can inhabit it

both releases declare simd:  2 members, 0 of them via the NotDeclared cell
1.1 declares no flags:       2 members, 1 of them via the NotDeclared cell
```

So the collapsed fact and its complement are **syntactically identical** in both
worlds; only the denotation differs. The algebra cannot tell them apart because
telling them apart needs `D(ρ)` — which flags each release declares — and
`flags-semantics.md` §1.1 puts that firmly on the bridge: *"the core algebra cannot,
and per the architecture boundary must not try."* The surviving-but-empty cell is
**O3's one-sided emptiness being exercised**, exactly as specified, and the cost
lands on `Inconclusive`: work, never a wrong verdict (O4).

The dead cell dies at the **provider**, the one place reality is consulted:
`expand'` enumerates real releases and filters by `memberInstance`, so an
uninhabitable cell yields no candidate. Same shape as `widen` admitting versions
Hackage does not have.

Two consequences for the work:

- **a simplification** — emission needs no declaration-checking at negation time,
  because one complement is correct for both worlds;
- **a cost for the ledger** — when a run does *not* span a declaration change, you
  carry one redundant cell per collapsed guarded fact. Small, real, and it belongs
  in the measurement below rather than being assumed away.

**The trade, which is why measurement comes first.** Fewer clauses to rescan (clause
count and position dominate propagation cost here) and one refutation killing a
whole run, against new `.cabal` reads that happen even when the run is never
refuted, plus the redundant cells above. Which side wins is empirical, and the flag
axis already took the cost that motivated most of this.

**The concrete work.** A range-taking cell constructor (`pinnedCell` pins one
version via `singletonVersionSet`; `SourceCell` already holds a `VersionSet`, so
only the smart constructor is missing); run detection in the provider over
`rsVersionsOf`/`rsReadRelease`, extending while a *guarded occurrence* is identical —
same guard and same dependency, **not** the whole dependency set, per §4.2; and the
report wording change to `foo >=1.0 && <1.3 depends on …`.

**Two things genuinely undecided.** How far to walk — unbounded widening reads the
whole version list in the worst case, and a cap stays sound because §4.2 makes
maximality *policy* rather than a requirement, but nothing has chosen one. And what
an **unparseable** release does to a run: per §1.5 it is not in the universe at all,
so spanning it would claim a fact about a release nobody could read, while breaking
on it lets index noise fragment otherwise-collapsible runs. Neither document answers
this; the version axis creates the question rather than inheriting it.

### Recommended order

From [`decision-semantics.md`](decision-semantics.md)'s own sequencing note, which is
the most recent thinking on this:

1. ~~Per-fact guarded emission (§4.2), flag axis.~~ **Done 2026-08-05.** It removed
   the 2^k re-offer on its own, as predicted.
2. **Measure it on real problems.** This is the step now due, and nothing above it in
   the list should start before it: the sequencing note's whole point is that the
   kernel change is justified by measurement, not by argument.
3. Only then decide whether the kernel generalisation (condition decisions) pays for
   itself. If it does, the verdict oracle lands before or with it — not after.

Seeds before collapsing, incidentally: smaller change, and it removes a special case
collapsing would otherwise have to preserve.

---

## Measurement — first results

First cut, 2026-08-05, one machine, warm cached index. Not a benchmark report: no
cabal baseline, no repetition, no controlled environment. Enough to decide what to
do next, which is what it was for.

### There is now a set of problems with real search in it

Constraining a package to an **older** release is what forces conflicts: the old
bounds have to be reconciled against everything else. Unconstrained popular
packages mostly do not conflict at all.

| problem | time | decisions | conflicts | backjumps | no-version | reads |
|---|---|---|---|---|---|---|
| `aeson <2` | 8.5 s | 1443 | **98** | 98 | 6 | 350 |
| `lens <4` | 4.8 s | 1059 | **63** | 63 | 1 | 557 |
| `conduit <1.3` | 3.2 s | 127 | **34** | 34 | 1 | 142 |
| `yesod` | >60 s | 4635+ | — | — | — | — |
| `pandoc` | 1.1 s | 266 | **1** | 1 | 0 | 167 |
| `vector` | 0.6 s | 39 | **0** | 0 | 0 | 13 |

Use the top three for anything about search. `yesod` does not finish in 60 s and is
worth understanding on its own.

### Three findings that change what to do next

**1. `pandoc` is an index-throughput benchmark, not a search one.** It has *one*
conflict, resolved immediately (`{cassava ==0.5.5.0}`, backjump to level 65). Its
266 decisions are nearly all first-time expansions. It has been this project's
standing stress case, and it cannot see a search improvement.

Concretely: the A/B for §4.2's flag axis showed **identical `.cabal` read counts** on
`vector`, `aeson` and `pandoc` — 13/13, 47/47, 167/167 — with the only difference
being the depender term. That is not evidence the change did nothing; the 2^k cost
only materialises when a version is *refuted*, and none of those three refutes
anything. **A benchmark set of cleanly-resolving packages would have reported the
fix as worthless.**

**2. Peak residency is currently a constant, and half the deliverable rests on it.**
About 22 MB whether a run does 13 reads or 557 — it is dominated by the index's
package→versions map, not by the solve. Comparing this number against cabal would
compare index readers. Either measure the solve separately from index loading, or
subtract a no-op baseline, before quoting peak memory at all.

(Also: the 27.2 s / 904 MB and 3.7 s / 83 MB figures recorded for the memoisation
experiment are stale as absolutes — `pandoc` now runs at 1.1 s / 22 MB. The *ratio*
lesson about retaining parse trees stands; the numbers no longer describe this tree.)

**3. Resolution depth is concentrated, and where it is deep the cause is
`collapseNoInstances`.** Over `aeson <2`'s 98 conflicts:

```
depth 0   x95      ← resolved in one step
depth 9   x1
depth 10  x1
depth 18  x1
```

The deep ones are all the same shape — a gappy range being learned one hole at a
time:

```
Conflict {bytestring >0.10.8.1 && <0.10.8.2 || >0.10.8.2 && <0.10.9.0 || … 9 more gaps}
  resolving at bytestring -> {base ¬(>=4.2 && <4.15), bytestring …}
  resolving at bytestring -> {base ¬(>=4.2 && <4.16), bytestring …}
  … 8 more, each absorbing one gap
Learned {base ¬(>=4.2 && <4.20), bytestring >=0.10.8.1 && <0.11.2}
```

Eighteen iterations to learn one clause, walking `base`'s bound up one release at a
time. That is exactly what `CLAUDE.md`'s Reporting gap 2 describes: intensional
ranges make the solver learn separately that each *hole* in a range is empty.

**It is filed as report clutter. This is evidence it is also a search-depth item**,
and that is an argument for reordering it against the version axis — both are about
ranges rather than flags, and this one has measured depth behind it.

### What made these visible

`SolverMsg` declared five events and the solver emitted **one** (`Deciding`).
`Chose`, `NoVersionFor`, `Conflict` and `Backtracked` were dead, and `app/Main.hs`
rendered all five, so the plumbing existed with nothing feeding it. A first sweep
here reported `conflicts=0 backtracks=0` for every package and it meant nothing.

All are now emitted, plus two new ones: **`Resolving`** (one per same-level
resolution iteration, so counting them between a `Conflict` and its `Learned` gives
the depth) and **`Learned`** (the root cause, as distinct from the conflict that
started it). `conflictResolution` became monadic for `Resolving` only; the algorithm
is unchanged.

**Caveat for timing.** Tracing renders to stdout, so `aeson <2` prints ~1500 lines
and the 8.5 s above includes that. A timed run should discard the log, or the CLI
needs a verbosity switch. There isn't one.

### One incidental oddity, unexplained

`aeson <2` resolves with **`base 4.15.1.0`** in the plan — a *source* release of
`base`, not the installed 4.21.0.0. Rung 3 is described as **strict
prefer-installed**, so this may be outside the intended model, or may be correct
because the constraint excludes the installed unit and a source `base` is then the
only option. Not investigated. Worth settling before a benchmark set bakes it in.

## Resolved contradictions

All fixed 2026-08-05. Kept as a record, because each was a case of two documents
disagreeing where one had authority and the other had not been updated.

1. **`CLAUDE.md` Reporting gap 1 prescribed a rejected approach** — grouping a
   package's instances "by identical flattened dependency **set**".
   `flags-semantics.md` §4.2 rejects exactly that as *"a serious mistake, not a
   conservative one"*: two assignments agreeing on the relevant dependency but
   differing on an unrelated one fail to group, so the depender term still names the
   irrelevant flag and the 2^k cost survives. **Fixed:** gap 1 now specifies one
   **guarded dependency occurrence** `C ⇒ q ∈ R`, with the guard verbatim as the
   depender's flag component.
2. **`decision-semantics.md` §11's five amendments were drafted but unapplied.**
   **Fixed:** all five applied — `flags-semantics.md` §1.2 (totality is a property of
   the instance, demanded of the witness), §1.4 Status (the reserved revisit has
   happened), §8 (the split's three benefits are inherited — one scheduling decision,
   not two), §10 (rows for D1/D2/D3 and condition-decision emission), plus the
   `CLAUDE.md` fix above. §11 now records them as applied.
3. **`pubgrub-intro.md` taught a superseded interface and a dead framing.**
   **Fixed:** inline notes at §2 (the two provider methods were merged into `expand`),
   §8 (there is no ASP component and never was — the `ASP.hs` it refers to was never
   written), and §9 (roadmap superseded), plus a banner at the top.
4. **`Small.hs` claimed the extensional set was transparently swappable.** Wrong
   twice: the symbolic form was not optional, and the swap was not invisible (no
   lawful `Eq`, no enumeration, one-sided emptiness — all changed callers).
   **Resolved by removing the file**: it was briefly restored on 2026-08-05 and
   removed again, because a second model of the same concepts building alongside
   `src/` confuses more than it teaches. The lesson is kept in prose at
   [attic/](attic/) §7.

5. **Four claims in `flags-semantics.md` overreached their own arguments**, found by
   [`flags-semantics-review.md`](flags-semantics-review.md) and all folded in:
   - **manual flags sat in §1.5's *admissibility*** while §1.6 said user flag values
     are translated once and never re-checked. Both cannot hold — `Adm` would be
     parameterised by user input, so the same instance would change admissibility
     depending on what the user typed. Now stated as input translation. Behaviour
     unchanged; the owner changed.
   - **§5's selection recipe contradicted O6.** "Complete each candidate cell, drop
     inadmissible completions" discards a cell after its *default* completion fails,
     which is the false `None` O6 forbids. Now phrased as policy over an O6-complete
     search — see the trap above.
   - **O4 concluded "no wrong solution either"**, which its own local argument does
     not support. Now limited to per-query soundness, with the whole-loop claim marked
     owed to §6's oracle.
   - **§2.5 cited `pubgrub.md:1172` to exclude version-keyed flags.** That citation
     forbids expanding version ranges into per-version atoms; it does not settle the
     flag-variable question. Now a project design decision, argued from §1.4.

   The review also found the manual-flag rule is **no longer memory-only** (there is an
   adjacent Cabal checkout with `enforceManualFlags`) and that §1.2 should write
   `D(ρ)` rather than `D(p, v)`. Both applied.

### Stale line references, also fixed

Cited code locations had drifted. `CLAUDE.md`: `depIncs` `:225`→`:332`, no-instances
`:317`→`:416`. `decision-semantics.md` §12: `depIncs` `:320`→`:330`,
`undecidedPositive` `:222`→`:225`, `usableAssignments` `:285`→`:287`,
`preferDefaults` `:305`→`:307`, decision loop `:394`→`:397`.

**These will drift again.** Both files say they expect to be re-checked when the tree
moves; treat a cited line number as a hint, and grep for the identifier.

---

## Deliverable status, plainly

| deliverable | state |
|---|---|
| **Explanation showcase** — real failing problems, pubgrub-hs vs cabal side by side | solver produces numbered proofs; no side-by-side, no cabal baseline, wording gaps open |
| **Benchmark report** — time + peak residency on real sat/unsat problems | **not started** as a comparison. Our own first numbers exist ([Measurement](#measurement--first-results)); peak residency is not yet a usable metric |

Both need `cabal-install-solver` wired in as a baseline and both solvers driven from
the one shared index. That structural sharing is the point of the bridge design, and
it is the piece that makes the comparison apples-to-apples.
