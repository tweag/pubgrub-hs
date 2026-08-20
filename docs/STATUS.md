# Status — where the project actually is

> **What this is.** The single current-state document. What works, what is written
> down but not built, what is not decided, and **which file wins when two
> disagree**. Written in plain language on purpose.
>
> **What this is not.** Not authoritative. It summarises; the documents in the
> table below decide. If this file contradicts one of them, that one is right and
> this file is stale — fix it.
>
> **Last checked against the tree:** 2026-08-17, 128 tests passing.
>
> **If you have been away**, three sections carry everything that changed on
> 2026-08-17: [Release-1 scope](#release-1-scope-flags-are-fixed-at-their-defaults-2026-08-17)
> (flags are no longer searched),
> [Re-measured after the scope cut](#re-measured-after-the-scope-cut-2026-08-17)
> (which found a memory regression), and
> [Merge on insert](#merge-on-insert-the-collapsing-trade-is-gone-2026-08-17)
> (which removed it, and holds the current numbers). Every other measurement
> section is dated and historical.
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
ranges, Cabal flags, buildability, and installed/boot-package pinning. 136 tests
pass, including all six worked examples from the PubGrub spec — the two
error-reporting ones now assert the __rendered proof__ against a golden file
(`test/golden/`), checked against the wording the spec publishes.

**Neither deliverable has been delivered, but the comparison has started.** cabal's
own solver runs over our index (`pubgrub --cabal`, no `cabal-install` dependency),
and the current five-problem numbers are in
[Merge on insert](#merge-on-insert-the-collapsing-trade-is-gone-2026-08-17): **all
five verdicts agree, we are faster than cabal on all five, leaner in memory on all
five (2.2–3.5×), and allocate less on four of five.** Our proofs are **shorter than
cabal's message on two of the three unsat problems** — `lens <4` 6 lines against 22,
`conduit <1.3` 12 against 16 — which is the explanation thesis with evidence under
it; `aeson <2` (83 against 30) is the outlier. What is missing is the harness — one run doing both, diffing plans,
repeating for timing — and the explanation side-by-side.

**And the problem got smaller on 2026-08-17.** Flags are no longer a search
dimension: every flag is fixed at its declared default, on *both* sides of the
comparison. That is a deliberate scope cut for a first release, not a discovery —
see [Release-1 scope](#release-1-scope-flags-are-fixed-at-their-defaults-2026-08-17).
Measured afterwards, it **barely moved this problem set at all**, which is worth
knowing before anyone credits it with a performance result.

---

## Which file wins

The question this table exists to answer is "which one is newest / which do I
believe". **Each row is authoritative on its own subject** — the list is not a
ranking, because the specs mostly do not overlap. Where two genuinely could collide,
the "authoritative on" column says who owns the question.

| file | authoritative on | status |
|---|---|---|
| [`references/pubgrub.md`](../references/pubgrub.md) | **the algorithm.** Vendored copy of pub's spec | present and now tracked (1233 lines); all cited line numbers verified 2026-08-12. Reference — never edit |
| [`flags-semantics.md`](flags-semantics.md) | **flags**, and the value/set language | spec, 2026-08-03; unchanged by the release-1 scope cut, but only its degenerate case is exercised — see its §10 |
| [`decision-semantics.md`](decision-semantics.md) | what a **decision** is (condition decisions) | spec, drafted 2026-08-04, **nothing implemented**; its motivating cost is *suspended*, not gone — see below |
| [`../specification/`](../specification/) | **nothing — it is not authoritative.** Our own draft attempt at formalising the kernel, in Lean | executable and machine-checked; **a draft.** Where it disagrees with `references/pubgrub.md` or `flags-semantics.md`, it is wrong. Lean code is normative only over its own prose |
| [`../CLAUDE.md`](../CLAUDE.md) | architecture, the rung ladder, conventions | current |
| [`specification.md`](specification.md) | Cabal's **build model** (components, scopes, Backpack) | reference for rungs 4–5, nothing implemented |
| [`bridge-and-problem-model.md`](bridge-and-problem-model.md) | why the bridge is shaped as it is | 2026-07-23 notes, partly pre-reboot |
| [`pubgrub-intro.md`](pubgrub-intro.md) | tutorial introduction to PubGrub | useful, three stale sections (flagged in it) |
| [`flags-semantics-review.md`](flags-semantics-review.md) | an independent review of the flag spec | 2026-08-05; findings folded in, kept as the record |
| [`benchmarking.md`](benchmarking.md) | **how to run the tests and benchmarks**, and which numbers to trust | current, 2026-08-12 |
| [`failure-cases.md`](failure-cases.md) | **the unsat problem set**: where it came from, the six failure kinds, ours against cabal | current, 2026-08-20 |
| [`collapsing.md`](collapsing.md) | **depender collapsing**: what landed, its cost, and the five ways to finish it | design note, 2026-08-12, **closed 2026-08-17** by merging in the store (its option 4). Kept as the record of what each option was worth; its numbers predate the release-1 scope cut and one of its two motivations was the 2^k re-offer that cut removes |
| [`decision-log.md`](decision-log.md) | project history | narrative, not authoritative |
| [`related-work.md`](related-work.md) | external literature → our problems | reading map, not authoritative |
| this file | current state | summary, not authoritative |

### `references/` — how much of the authority is actually in the repo

`references/` went missing from one machine on 2026-08-12 and was restored by hand,
which exposed that it had **never been checked in** while **60 citations across 13
documents** point into it. Current state:

| under `references/` | tracked? | citations verified |
|---|---|---|
| `pubgrub.md` — pub's spec, 1233 lines | ✅ now tracked | ✅ **all 13 line numbers exact** (2026-08-12): `:131 :169 :184 :443 :451 :456 :465 :476 :492 :499 :1005 :1150 :1172` |
| two ASP papers (PDF) | ✅ now tracked | — (prose only; see [related-work.md](related-work.md)) |
| `pubgrub/` — the Rust implementation | ❌ **nested git repo, contents not tracked** | 8 of 9 exact (`report.rs:102`, `incompatibility.rs:173,191`, `version_set.rs:29`, `core.rs:322`, `provider.rs:91,119`); `report.rs:132` was a blank line, now `:133` |
| `pubgrub-guide/` — the internals guide | ❌ **nested git repo, contents not tracked** | not cited by line |

**What this means in practice.** Citations into `pubgrub.md` are now trustworthy and
reproducible — that was the load-bearing risk (`:456` is the whole basis of depender
collapsing, `:1172` of intensional version sets) and it is discharged. Citations into
`pubgrub/src/*.rs` are **still not reproducible for anyone else**: the checkout is a
nested repo, so cloning this repository does not get it, and its line numbers move with
upstream. The revisions the current citations were checked against:

- `references/pubgrub` at `4dbe916`
- `references/pubgrub-guide` at `1be2365`

**Still owed:** vendor the Rust checkout properly (submodule, subtree, or extract just
the cited functions into a note) and record the revision alongside it. Until then, treat
a `references/pubgrub/src/…:NNN` citation as pinned to `4dbe916` and re-check it before
leaning on it. Prefer citing the *function name* over the line: `merge_dependents` and
`collapse_no_versions` will survive a rebase; `:173` will not.

**Only one document is authoritative on flags: `flags-semantics.md`.** The other
two flag documents were the confusing part and have moved to
[`attic/`](attic/) — `flags-design.md` (superseded on semantics; it chose a rule
that turned out to be wrong) and `flags-spike.hs` (the spike whose test universe
hid the bug).

**`../specification/` is a draft and settles nothing.** It is *our own attempt* at
formalising PubGrub in Lean, not an independent authority — that it builds means our
model is internally consistent, not that the model is right. Nothing proves it
faithfully renders `references/pubgrub.md` or `flags-semantics.md`, and that unproven
gap is precisely where an error would sit. So do not close a design argument by citing
it, and do not change the solver because a theorem there permits it. Its "authoritative
on" column is empty deliberately. The value is real but narrow: it is machine-checked,
and writing it forces questions the prose leaves implicit.

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
   §4.2's **flag axis is implemented** (2026-08-05) and its **version axis** landed on
   2026-08-12 — the half `references/pubgrub.md:456` actually asks for — as a
   measured trade rather than a clean win ([collapsing.md](collapsing.md)). So the
   prerequisite is paid, and the thing it was a prerequisite *for* is now dormant
   instead (see below).
3. **It is the revisit `flags-semantics.md` reserved.** §1.4 there recorded that
   putting the flag in the value costs 2^k re-offers and said "if the retry cost ever
   dominates, this is the decision to revisit." `decision-semantics.md` §0 is that
   revisit.

The division of labour on that 2^k cost is the cleanest way to see the split:
**§4.2 keeps irrelevant flags out of the learned clauses; condition decisions keep
them out of the decisions too.** Three costs survive §4.2, all because a decision is
still a single point instance.

**Both of those are about a cost that is currently zero.** With flags fixed at their
defaults there is one assignment per release, so no flag is ever a search dimension
and 2^k is 2^0. That does not retire `decision-semantics.md` — it makes it *dormant*.
It becomes live again the moment the flag axis returns, and it is the reason not to
delete the machinery in the meantime.

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
- **Rung 2** — flags and conditional dependencies, **applied but not searched**. A
  release's dependencies are the ones its declared flag defaults select, evaluated
  off the flattened conditional tree; every flag is treated as manual and no flag is
  a variable the solver may set. A decision is still a version plus a total flag
  assignment, but there is exactly one of those per release. The search machinery
  (three-state pins, `preferDefaults`, the symbolic flatten) is intact and unfed —
  see [Release-1 scope](#release-1-scope-flags-are-fixed-at-their-defaults-2026-08-17).
- **Rung 3** — `base`/GHC pinning: the installed database becomes pre-installed
  instances, with strict prefer-installed, and an installed unit pins its whole
  closure. Boot packages are **only**-installed: a non-reinstallable package offers
  installed units or nothing, never a source release.
- **Buildability** — a release whose library cannot be built here is not offered:
  `buildable: False`, and `pkgconfig-depends` resolved against the machine's real
  `pkg-config` db (cabal's own `PkgConfigDb` and predicate, read once in `withWorld`
  and handed to both solvers).
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

## Release-1 scope: flags are fixed at their defaults (2026-08-17)

**What changed.** Flags stopped being a search dimension. They are still parsed and
still applied — a release's dependencies are the ones its defaults select, not the
ones an unflagged read would give — but no flag is a variable the solver may set.

Both solvers had to be told, and each takes it differently:

- **ours, at flatten time.** `Bridge.Cabal.Flatten.componentDepsAtDefaults` resolves
  flag conditions against the release's own defaults instead of leaving them
  symbolic, so every guard folds to a literal. Nothing downstream changed shape:
  `expandGuard` already maps `Lit True` to one candidate assignment with **no pins**
  (so a dependency is emitted with its flag component unconstrained) and `Lit False`
  to none (and the provider drops a group whose expansion is empty). No pinned cell
  is ever built, `InstanceSet` degenerates to one flag-free cell per operand, and a
  release offers exactly one instance: itself under its defaults;
- **cabal's, at the index read.** `Bridge.Hackage.lookupGPD` marks every flag
  manual, so cabal's `enforceManualFlags` prunes every branch whose value is neither
  the default nor named by a user flag constraint — and we pass none. Doing it at the
  single shared read is what keeps the comparison structural: neither solver can be
  handed a different universe by accident.

**Two things to remember when reading numbers taken after this.** A manual flag is
not *weak* (`weak m = not (strfl || m)`), so `deferWeakFlagChoices` stops deferring
the flags that influence dependencies — that perturbs cabal's **goal ordering**, not
just its flag values. And an automatic flag is exactly what cabal would have flipped
to escape an unsatisfiable dependency, so some problems that resolved before will
not. Both solvers fail together, which is what makes the comparison fair, but it is a
**restriction of the problem** and any published explanation has to say so.

**What it does to the open work**, and this is the part worth checking before picking
anything up:

- the **2^k re-offer is gone by construction**, not by fix. That was one of the two
  motivations for depender collapsing (`collapsing.md`) and the whole motivation for
  condition decisions (`decision-semantics.md`). Both remain correct about a cost
  that is currently zero;
- the [trap below](#the-one-trap-worth-knowing-before-you-touch-anything) did **not**
  spring when buildability landed the same week, and the reason is this cut;
- **every measurement in this file predates it.** The collapsing trade in particular
  (`aeson <2` 4.7× faster, `pandoc` 6.6× slower) was measured with flags searched.

**What is deliberately kept.** `componentDeps` (the symbolic flatten), `expandGuard`,
`preferDefaults`, the three-state pin and its property suite are all still here and
still tested. The `flags` jj bookmark marks where that work stands. This is a scope
cut for a first release, not a retraction of the model — `flags-semantics.md` is
unchanged as a specification, and only its degenerate case is exercised.

---

## Written down but not built

Everything here has a specification and no implementation. **Do not assume any of
it exists in the code.**

| thing | spec | note |
|---|---|---|
| **Condition decisions** (its rules D1, D2, D3) | [`decision-semantics.md`](decision-semantics.md) §2–§9 | kernel-level change to what a decision is |
| ~~**§4.2's version axis**~~ — widening a depender across adjacent releases | [`flags-semantics.md`](flags-semantics.md) §4.2 | **built 2026-08-12** and unfinished: a trade, not a win. [collapsing.md](collapsing.md) has the five ways out and the measurement to take first |
| **Seed incompatibilities** instead of a synthetic root | [decision-log](decision-log.md#5-open-decisions) | decided 2026-07-30; `solve` still takes `rootPkg`/`rootV` |
| **`buildable:` as a *condition*** | [`flags-semantics.md`](flags-semantics.md) §1.5 | **half built, 2026-08-17.** `buildableCondition` returns the condition; `buildableAtDefaults` evaluates it, and the provider skips the release. Satisfying it rather than evaluating it is the flag-axis half |
| ~~**Unbuildable stated as an incompatibility**~~ | `references/pubgrub.md:476` | **built 2026-08-20.** The scan emits `unbuildable p slot` for each release it passes over and hands them out with the release it settles on; [`PubGrub.Store`](../src/PubGrub/Store.hs) unions adjacent slots into one contiguous run. As predicted, no interface change was needed and the *exhausted* case (every release in range unbuildable) still loses the facts — see [Unbuildable, stated](#unbuildable-stated-and-a-path-the-benchmarks-never-walk-2026-08-20) |
| **Manual flags** | [`flags-semantics.md`](flags-semantics.md) §1.6 | **built in its degenerate case, 2026-08-17**: *every* flag is manual and no user values exist, so the translation is "take the default" and it is applied at the index read rather than as a solver constraint |
| **User flag constraints** (`--flag`) | [`flags-semantics.md`](flags-semantics.md) §1.6 | do not exist yet — and while every flag is manual, they are the only thing that could move one |
| **Rung 4** — setup / build-tool deps | — | not started |
| **Rung 5** — public sublibraries | — | not started |
| **The benchmark harness** | — | nothing exists; the larger of the two deliverables |
| **The verdict oracle** (test) | [`flags-semantics.md`](flags-semantics.md) §6 | owed; blocks condition decisions, and is what would discharge O4's whole-loop claim |

---

## The one trap worth knowing before you touch anything

**`buildable:`, the completeness search, and a missing test are one work item** —
and the item is now *armed but not firing*, which is a worse state to misread than
either extreme.

The trap as it stood: the provider's shortcut is to try **one flag completion per
candidate region**, so if a region's default completion is unusable while another
completion of the same region is fine, the shortcut misses a valid instance. The
symptom is a confident, wrong **"no solution"** — the false `None` O6 forbids.
Nothing in the tree was unusable depending on flag values, so the shortcut was
**correct by accident**, and implementing `buildable:` was going to end the accident.

**Buildability landed on 2026-08-17 and the trap did not spring.** Not because the
analysis was wrong — because the same week removed the other half of its
precondition. With every flag fixed at its default there is exactly **one**
completion per release, so "the default completion is unusable but another is fine"
has no instances: the other completion is not in the universe at all, for us or for
cabal. Admissibility is assignment-dependent in the `.cabal` file and
assignment-independent in the problem we are solving.

Two things follow, and they pull in opposite directions:

- **you may implement and measure buildability today** without the completeness
  search, which is what happened;
- **the trap re-arms the instant the flag axis comes back**, and it will do so
  quietly, because by then `buildable:` will look like settled, tested, working code
  rather than the second half of an unfinished pair.

So the work item is unchanged in content and changed in trigger: **whoever restores
flag search owns the O6-complete search and §6's oracle**, and cannot treat
buildability as already done. The test that would catch it still cannot be built
until then — it needs a world where completions of one region disagree about
usability. And it is **written into the spec, not only the code**:
`flags-semantics.md` §5's selection recipe was itself phrased against the accident
until the 2026-08-05 review caught it; §5 is now stated as policy over an O6-complete
search, so the search and the policy have to land together.

---

## Open questions

Full arguments in the linked sections; this is the index.

0. ~~**Re-measure, before deciding anything below.**~~ **Done 2026-08-17** — see
   [Re-measured after the scope cut](#re-measured-after-the-scope-cut-2026-08-17).
   Three answers, and the middle one changes a priority: the cut barely moved this
   problem set (so flags were hardly searched on it); depender collapsing costs
   **memory** as well as time and reads, which nobody had measured — `pandoc`'s max
   residency went 22.9 → 81.0 MB and its allocation is 9.6× cabal's; and the
   `noversion` rise is not a flag artifact, because it survived. **Item 2 was then
   built** — `collapsing.md` option 4, see
   [Merge on insert](#merge-on-insert-the-collapsing-trade-is-gone-2026-08-17) — and
   the memory regression is gone. The `noversion` rise is the survivor: it has now
   outlived both the flag cut and the walk, so it belongs to wide clauses as such.
1. **Should the provider's `expand` split back into "pick" then "consequences"?**
   ([`flags-semantics.md`](flags-semantics.md) §8.) Design item, not a decision.
   **Note the interaction:** [`decision-semantics.md`](decision-semantics.md) §10 says
   the condition-decision model *inherits all three benefits* of the split, and that
   the two should be scheduled as one item.
2. ~~**Depender-range collapsing, version axis**~~ — **closed 2026-08-17**, by
   merging in the store rather than walking the index ([collapsing.md](collapsing.md)).
   What remains is a deliberate weakening of `references/pubgrub.md:456`, recorded
   there and in the results section: we collapse the releases the solver expanded, not
   every release carrying the dependency. Nothing observable depends on the
   difference, and closing it would cost exactly the reads this change removed.
3. **Should the set algebra be allowed to read flag declarations?** Would make
   emptiness exact and remove the one-sided slack, at the cost of the core/bridge
   boundary. Cost/benefit, not correctness.
4. **`collapseNoInstances` — now the top item, on two independent arguments.** Filed
   under report polish in `CLAUDE.md` (Reporting gap 2), and it is not that. The first
   argument is the measurement below: it is where all the deep conflict resolution
   goes, since the three deepest resolutions in `aeson <2` (9, 10 and 18 iterations)
   are each a gappy range being learned one hole at a time. The second arrived with
   chain collapsing on 2026-08-20 — the `no version for …` siblings are what stop the
   chain fusion from firing, so on the spec's own worked example they are the entire
   difference between its published two lines and our three
   ([Chain collapsing](#chain-collapsing-the-proofs-are-half-as-long-2026-08-20)).
   Both arguments point the same way, and chain collapsing — which used to be
   scheduled after this — is done.

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
2. ~~**Measure it on real problems.**~~ **Done 2026-08-12** — the five-problem
   comparison below, and the collapsing trade. **And invalidated on 2026-08-17** by
   the scope cut; re-running it is Open question 0.
3. Only then decide whether the kernel generalisation (condition decisions) pays for
   itself. If it does, the verdict oracle lands before or with it — not after.
   **Dormant while flags are fixed**: the cost it exists to remove is currently zero,
   so this cannot be justified by measurement until flag search returns.

Seeds before collapsing, incidentally: smaller change, and it removes a special case
collapsing would otherwise have to preserve.

---

## Measurement — first results

> **The current numbers are in
> [Re-measured after the scope cut](#re-measured-after-the-scope-cut-2026-08-17)**
> (2026-08-17). Everything between here and there is the record of how the project
> got to them, in order, and each table is against the tree at its own date — useful
> for *why* a change was made, not for what the solver does today.
>
> **To reproduce anything below, see [benchmarking.md](benchmarking.md).** It documents
> `bench/compare.sh` and `bench/summarise.awk`, the problem set and why it is those
> problems, and which of these numbers are deterministic (counts) rather than noisy
> (times).

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

> **The attribution to that map is doubtful** (2026-08-12). Doubling its per-element
> overhead — `NonEmpty Version` to `Set Version` — moved peak residency by 110 KB
> (0.5%) on `vector`, where ~2.5 MB was expected. The constant is real; *what* it
> consists of is unestablished. See "The version map is a `Set` now" below.

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

**Caveat for timing.** Tracing renders to stdout, so `aeson <2` prints thousands
of lines and the 8.5 s above includes that. The trace is now behind `-v` /
`--verbose` and **off by default**, so the numbers above were taken in what is no
longer the default mode — anything wanting them comparable should be re-run.

Two things that pass came out of adding the switch, both worth knowing before the
next measurement pass:

- **The trace is not where the time goes.** With stdout redirected to a file,
  `aeson <2` runs the same with and without it (3396 lines vs 179). The switch buys
  output hygiene and a terminal-free measurement, not a speed-up.
- **Run-to-run noise on this machine is ±25%** — four runs of `aeson <2` came in at
  5.2, 6.5, 6.9 and 7.8 s. Single unrepeated timings, including every number in the
  table above, cannot distinguish anything smaller than that.

Also unfixed: with `-v` off there is no way to get the conflict/backjump/depth
counts, because those are *derived by counting trace lines*. A `--stats` mode that
consumes `SolverMsg` into counters and prints one summary line is the missing piece
for a timed run that also wants the search columns.

### Second pass: version slots (2026-08-12)

The depender term's version component is now a release's **slot** — the half-open
range up to the next release that exists in the index — rather than the single
version (`Bridge.Provider.withSlots`, `PubGrub.VersionSet.halfOpenVersionSet`). Free,
because the package→versions map is already resident; sound, because a slot holds
exactly one real release. See `flags-semantics.md` §4.2, first bullet.

Counts are deterministic, so these are noise-free comparisons against the table
above (which is the immediately preceding commit):

| problem | decisions | conflicts | no-version | reads |
|---|---|---|---|---|
| `vector` | 39 → 39 | 0 → 0 | 0 → 0 | 13 → 13 |
| `pandoc` | 266 → 266 | 1 → 1 | 0 → 0 | 167 → 167 |
| `conduit <1.3` | 127 → 127 | 34 → 34 | 1 → 1 | 142 → 142 |
| `lens <4` | 1059 → 1059 | 63 → 63 | 1 → 1 | 557 → 557 |
| `aeson <2` | 1443 → **1376** | 98 → **92** | 6 → **0** | 350 → **250** |

`aeson <2`'s depth histogram went `0×95, 9, 10, 18` → `0×89, 8, 9, 16`. Timed with
the trace off: 4.17 / 4.89 / 5.92 s — inside the same ±25% noise band, so read count
is the honest measure of the win, not elapsed time. `yesod` still does not finish
(5988 decisions in 90 s, all conflicts depth 0 — its problem is churn, not depth).

**What changed qualitatively is the more interesting half.** Finding 3's conflict
term was a union of eleven *empty* gaps between real `bytestring` releases. It now
reads as one contiguous interval that grows by absorbing the next slot:

```
Conflict {base ¬(>=4.2 && <4.15), bytestring >=0.10.8.1 && <0.10.8.2}
  resolving at bytestring -> {base ¬(>=4.2 && <4.15), bytestring >=0.10.8.1 && <0.10.9.0}
  resolving at bytestring -> {base ¬(>=4.2 && <4.16), bytestring >=0.10.8.1 && <0.10.10.0}
  … 14 more, each absorbing one release's slot
```

That is `unionVersionSet` coalescing touching intervals, with no hole left to learn
about — which is why `no-version` fell to zero. **And it reclassifies the deep
chain**: the remaining 16 iterations are not an artifact, they are one step per real
`bytestring` release, each contributing its own `base` upper bound. Nothing but
genuine multi-release depender collapsing can shorten that, and the dependencies
here really do differ per release, so it may be irreducible. Finding 3's "this is
also a search-depth item" therefore stands only for the hole half, which is now
fixed; the depth that remains has a cause we can name.

Every multi-interval set left in the traces holds real releases (survivors of
banning, e.g. `bytestring >=0.10.9.0 && <0.10.10.0 || >=0.10.12.1 && <0.11.0.0 ||
>=0.11.1.0 && <0.11.2`), not empty regions.

### Narrowing declared ranges: tried and reverted (2026-08-12)

The other half of the same idea — `Bridge.Provider.widen` emits a *declared*
dependency range verbatim, so version space no release occupies survives into terms
— was implemented, measured, and **taken back out**. The negative result is the
useful part.

What it bought, against the slot numbers above:

| | decisions | conflicts | no-version | reads |
|---|---|---|---|---|
| `lens <4` | 1059 → **1038** | 63 → **62** | 1 → **0** | 557 → 557 |
| `vector`, `pandoc`, `conduit <1.3`, `aeson <2` | unchanged on every counter |

`lens`'s last no-version event was `integer-gmp in >=0.2 && <0.5.1.0`, and
integer-gmp's oldest release *is* 0.5.1.0 — the whole range was dead space, so
narrowing emptied it at emission instead of leaving the solver to refute it. Its
deepest resolution also went 9 → 8.

What it cost, measured by total allocation (`+RTS -s`, near-deterministic, unlike
wall clock on this machine):

| | narrowing off | narrowing on | |
|---|---|---|---|
| `aeson <2` | 22.998 GB | 23.905 GB | **+3.9%**, for identical search counts |
| `lens <4` | 14.491 GB | 14.481 GB | −0.07%, its own cost cancelled by the win |

**Where the cost is — first answer, since corrected.** The reading at the time was
that `expand'` already holds the version list of the package it is *deciding*, so a
slot costs nothing, while `widen` is about the *dependee* and must look that list up
and walk it again per emitted dependency. A deliberately cheaper formulation (clamp
the outer bounds only) measured **worse** — 23.919 GB — which seemed to place the
cost in fetching and traversing the list.

**That was wrong, and the container swap is what showed it.** With
`Map PackageName (Set Version)` and `snapToVersions` reduced to two ordered lookups
per interval — no traversal of the package's versions at all — narrowing cost
**23.878 GB against 22.987 GB, the same 3.9%**. So the price was never in finding
the bounds.

What is now known about it:

- it is not finding the bounds (O(log n) and O(n) formulations cost the same);
- it is not building the second `InstanceSet` — measured separately at ~0.005%
  (22.999 GB against a 22.998 GB baseline);
- which leaves `snapToVersions`' own `VersionSet` round trip per emitted dependency,
  or the solver doing its set algebra on differently-shaped ranges. **Those two have
  not been told apart**, and the second would be inherent to narrowing rather than
  fixable.

So it stays out for the same reason as before, but not for the reason first
recorded. Anyone picking this up should start by distinguishing those two, not by
optimising the lookup.

**Kept:** `PubGrub.VersionSet.snapToVersions` and its four properties (subset, same
members of the universe, idempotent, empty universe empties everything), so the
primitive and its contract are settled and unused rather than unwritten.

### The version map is a `Set` now (2026-08-12)

`ihVersions :: Map PackageName (Set Version)`, was `Map PackageName (NonEmpty
Version)`. Prompted by the narrowing cost above; kept because of what it fixed
regardless.

The list came straight out of `Sec.directoryEntries`, in the index's own order —
which is **neither sorted nor guaranteed unique**. Measured on the real cache:
19,393 packages, 152,746 version entries, and **14,796 packages not in ascending
order**, with local disorder rather than a clean reversal (`A-gent` runs
`…0.11.0.17, 0.11.0.18…` and `…0.11.0.4, 0.11.0.5…` out of order inside an
otherwise descending list). Every consumer wants them ordered, and `withSlots` —
which asks *which release comes next* — is silently wrong if they are not. It was
correct only because `expand'` happened to sort first. That is now a property of the
structure rather than an obligation on each caller: `withSlots` takes the `Set` and
uses `Set.lookupGT`, `expand'` drops its per-expansion `sortOn Down`.

Duplicates turn out not to occur (152,746 entries, 152,746 distinct — the index
hackage-security hands us keeps only the last revision of each release), but nothing
guaranteed it, and a duplicate would have produced a zero-width slot `[v,v)`, which
denotes nothing and would have dropped that release's dependencies in silence.

Cost, which was the open question:

| | allocation | max residency |
|---|---|---|
| `vector` (cleanest probe: 13 reads, minimal solver state) | 359.53 → 359.38 MB | 22,767,424 → 22,877,496 B, **+110 KB / +0.5%** |
| `lens <4` | 14.491 → 14.476 GB | 37.77 → 38.50 MB |
| `aeson <2` | 22.998 → 22.986 GB | 22.83 → 27.43 MB |

Allocation went slightly *down* — the removed per-expansion sort covers the
container's overhead. The cache file is the same size (1,954,523 bytes; `Binary`
encodes a `Set` as a list), at `cacheFormatVersion` 3, so existing caches rebuild
once.

**A `Set` node is ~5 words against a cons cell's 3, so ~2.5 MB of growth across
152,746 versions was the thing to watch, and it did not appear** — 110 KB on the
clean probe. That is evidence against finding 2's attribution above ("dominated by
the index's package→versions map"): doubling that map's per-element overhead moved
peak residency by 0.5%. `aeson`'s +4.6 MB is a bigger jump than `vector`'s and
`lens`'s, which points at GC sampling of transient solver state rather than at the
map, since all three hold the same map. **What actually dominates the 22 MB has not
been established** — worth settling before any memory number is quoted against
cabal.

**Reverted with it,** and needed again whenever narrowing returns: the split between
the term the solver reasons with and the range the report quotes
(`fromNarrowedDependency`, plus rendering dependency leaves from their cause in
`PubGrub.Report`). Without it a narrowed term reaches the proof, and
`base >=4.7 && <5` gets quoted back to its author as `>=4.7.0.0 && <=4.21.0.0`.
Narrowing a dependee term is not safe for reports on its own.

## First baseline comparison (2026-08-12)

`Bridge.Cabal.Baseline` drives cabal's own modular solver over our index;
`pubgrub --cabal <target> [range]` runs it. **No `cabal-install` dependency** —
`cabal-install-solver` exposes everything needed (`Distribution.Solver.Modular.*` are
all exposed modules, and its own deps are just `Cabal`/`Cabal-syntax` plus ordinary
libraries). The entry point used is `modularResolver`, which is resolver-shaped: it
runs `convPIs`, builds the constraint map and converts the log to a `Progress`, all
of which `../cabal-solver-plan` reproduces by hand because it calls
`Distribution.Solver.Modular.Solver.solve` directly. What `Distribution.Client.*`
would have supplied — CLI constraint syntax, a preference intermediate language,
`defaultSolverConfig`, and index acquisition — is either restated in ~20 lines or
ours already.

Both solvers are fed from one `Bridge.Provider.withWorld`: one index bracket, one
installed-db read — and, since 2026-08-17, one `pkg-config` db. That last one was
not a detail: passing `Nothing` reads to cabal as *no `pkg-config` executable
exists*, so it rejected every `pkgconfig-depends` and escaped by flipping `zlib`'s
automatic `pkg-config` flag, on 9 of 29 popular targets. A baseline has to agree
about the environment before agreeing about a plan is worth anything.

That symptom is no longer available to cabal — with every flag manual it cannot flip
one to escape — which makes the db *more* load-bearing, not less: on a machine
without the system library, cabal now rejects the release outright, and so do we.
Same rule, same db, same verdict.

| problem | verdict | time | peak RSS | max residency |
|---|---|---|---|---|
| `vector` | both sat | **0.53** / 0.82 | **83** / 129 MB | **22.9** / 54.0 MB |
| `pandoc` | both sat | **1.29** / 1.66 | **83** / 238 MB | **22.9** / 80.5 MB |
| `conduit <1.3` | both sat | 3.20 / **1.17** | **83** / 121 MB | **22.9** / 50.7 MB |
| `lens <4` | both sat | 4.65 / **1.32** | **100** / 185 MB | **39.1** / 75.5 MB |
| `aeson <2` | both sat | 6.57 / **1.51** | **83** / 183 MB | **28.1** / 74.5 MB |

(ours / cabal's; single unrepeated runs, ±25% machine noise, trace off, warm index
cache. Both figures include index loading, which is not the same work for the two —
see below. **These verdicts predate the non-reinstallable constraints**; with those
added, three of the five disagree — see below.)

**The shape of it, stated plainly: cabal is 2.7–4.3× faster on the three problems
with real search, we are 2–3× leaner in memory, and the verdicts agree everywhere.**
Our advantage on `vector` and `pandoc` is the lazy index, not the solve.

Two caveats that keep this from being the benchmark report:

- **The index work differs by design.** Ours parses a `.cabal` only when it expands
  a package (13 reads on `vector`); cabal's resolver needs a `SourcePackage` record
  for all ~152k releases before it starts, which is most of its memory and a chunk of
  its floor time. Descriptions are still parsed lazily
  (`unsafeInterleaveIO` + `srcpkgDescription` being documented lazy), so it is the
  *spine* that costs. Splitting index build from solve is now the first thing the
  harness must do.
- **`solveExecutables = True`** in cabal's defaults means it solves setup and
  build-tool depends; our rung 4 is unbuilt. That is visible in the plans below and
  means the two are not solving quite the same problem on any package with a custom
  setup.

### The plans agree on the interesting part, and diverge in two known ways

On `aeson <2` both pick **`aeson 1.5.6.0`**. cabal's plan carries 63 packages against
our 41, and the extra ones are exactly the two gaps we know about:

- the **setup closure** — `Cabal`, `Cabal-syntax`, `directory`, `process`, `time`,
  `unix`, `file-io`, `parsec` — which is rung 4, unbuilt here;
- boot packages our tree-renderer collapses under `(*)` rather than omits, so part of
  the 41-vs-63 gap is presentation, not resolution. A real plan diff is harness work.

### What cabal's plan for `aeson <2` actually is

Printing each entry's dependencies **by component** rather than flattening the plan
answers this. Two entries for one package is not a contradiction: cabal solves
**qualified goals**, so a setup or executable dependency is solved in its own domain
and may take a different version of a package than the library does — `Setup.hs` is an
executable that is never linked against the library, so it can be built against a
different `mtl`. `modularResolver` applies `convCP` on the way out, which strips the
qualifiers from the *identities*, so a flat list cannot tell one inconsistent plan from
two consistent domains. (An earlier note here read it as the former. Withdrawn.)

What is actually there:

```
  aeson-1.5.6.0 [-bytestring-builder -cffi -developer -fast]
      lib: attoparsec-0.14.4 base-4.15.1.0 … text-1.2.5.0 …
      setup: Cabal-3.14.1.0 base-4.21.0.0
```

- **one `setup:` line in the whole plan**, and it uses the *installed* `base-4.21.0.0`;
- the **library** domain is built against source `base-4.15.1.0`, and with it source
  `ghc-prim-0.7.0`, `ghc-bignum-1.3`, `array`, `binary`, `pretty`;
- **four packages appear twice at the same version** — `array-0.5.8.0`,
  `binary-0.8.9.3`, `ghc-bignum-1.3`, `pretty-1.1.3.6` — once installed, once to be
  built. That is the two domains showing through after the qualifiers are stripped.

So the plan is coherent, and the duplicates are the qualified-goal structure rather
than a fault. **We have no model for this at all**: our decisions are per package
name, so one solve yields one version of `mtl`, full stop. It needs specifying before
rung 4 — see the rung 4 note in `CLAUDE.md`.

### Non-reinstallable boot packages — and three verdict disagreements

The rendering above showed cabal planning to **build `base`, `ghc-prim` and
`ghc-bignum` from source**, which cabal-install never does: it constrains boot
packages as non-reinstallable. Those constraints live in `cabal-install`, so the
baseline lacked them and was **more permissive than the thing it is a baseline for**.

Added as `Bridge.Cabal.Baseline.nonReinstallableConstraints` — cabal-install's own
shape (`ScopeAnyQualifier` so it binds in every qualified domain,
`PackagePropertyInstalled` meaning "an installed instance or nothing") over a
baked-in copy of its eight names (`base`, `ghc-bignum`, `ghc-internal`, `ghc-prim`,
`ghc`, `integer-gmp`, `integer-simple`, `template-haskell`). A list of names rather
than a derivation on purpose: how cabal decides reinstallability is itself in flux, so
a snapshot that is obviously a snapshot beats tracking a moving target. Note `rts` is
not on cabal's list although it is equally unbuildable.

**It changes three of five verdicts:**

| problem | ours | cabal | time | max residency |
|---|---|---|---|---|
| `vector` | sat | sat | 0.55 / 1.01 | 22.9 / 54.0 MB |
| `pandoc` | sat | sat | 1.34 / 1.58 | 22.9 / 80.5 MB |
| `conduit <1.3` | sat | **UNSAT** | 3.36 / 1.18 | 22.9 / 50.7 MB |
| `lens <4` | sat | **UNSAT** | 5.07 / 1.56 | 39.1 / 76.0 MB |
| `aeson <2` | sat | **UNSAT** | 6.85 / 1.94 | 22.9 / 75.1 MB |

**The disagreement is ours, not cabal's.** We answer sat by planning to build a boot
package from source. Rung 3 is "strict prefer-installed", which says what to do when
an installed unit is admissible and nothing about the case where a constraint excludes
it — and there we fall through to a source release of `base`. cabal treats that as
impossible, and it is. So the `base 4.15.1.0` oddity was a real bug in our model all
along, and the baseline is what surfaced it. Until our provider carries the same rule,
these three problems are not comparable: we are answering a laxer question.

### Both solvers now carry the rule, and all five verdicts agree

`Bridge.Installed.nonReinstallablePackages` is now the single list both solvers read —
the baseline as constraints, our provider as a rule in `expand'`: a non-reinstallable
package offers installed units only, and when none is admissible there are no instances
at all rather than a fall-through to Hackage. That is the difference between
*prefer*-installed and *only*-installed, and it was the whole content of the
`base 4.15.1.0` oddity.

| problem | verdict | time (ours / cabal) | max residency |
|---|---|---|---|
| `vector` | both sat | 0.63 / 0.96 | 22.9 / 54.0 MB |
| `pandoc` | both sat | 1.59 / 1.84 | 22.9 / 80.5 MB |
| `conduit <1.3` | **both UNSAT** | 1.62 / 1.06 | 22.9 / 50.7 MB |
| `lens <4` | **both UNSAT** | 1.84 / 1.49 | 26.5 / 75.9 MB |
| `aeson <2` | **both UNSAT** | 11.12 / 1.90 | 28.3 / 75.1 MB |

Two of the three unsat problems now run *faster* than when we wrongly answered sat
(`conduit` 3.36 → 1.62, `lens` 5.07 → 1.84) and land within 1.2–1.5× of cabal.
`aeson <2` goes the other way: **11.12 s against cabal's 1.90 s**, 5.9× slower, and
worse than the 6.85 s it took to produce the wrong answer. Proving unsat is where we
are weakest.

### The explanation deliverable is currently losing, and now we know why

This is the first time the two explanations can be put side by side, and the result is
the opposite of the project's thesis:

| problem | our proof | cabal's message |
|---|---|---|
| `lens <4` | **9 lines** | 22 lines |
| `conduit <1.3` | **1061 lines** | 16 lines |
| `aeson <2` | **2833 lines** | 30 lines |

`lens <4` is the shape we promised. The other two are unusable, and the causes are all
already-known gaps, now with evidence behind them:

1. **Reporting gap 1's version axis, in the proof.** Long runs of lines do nothing but
   merge adjacent releases of one package pairwise:

   ```
   13. Because transformers >=0.4.3.0 && <0.5.0.0 depends on base >=2 && <4.9 and
       transformers >=0.4.2.0 && <0.4.3.0 depends on base >=2 && <4.9,
       transformers >=0.4.2.0 && <0.5.0.0 depends on base >=2 && <4.9
   14. Because (13) and transformers >=0.4.1.0 && <0.4.2.0 +applicativeinbase …
   ```

   That is `references/pubgrub.md:456`'s collapsing happening **at derivation time, one
   release per line**, because we do not do it at generation time. Every such line
   would not exist if the incompatibility had been emitted over the adjacent range in
   the first place. This is now the top item for both deliverables: it is also most of
   why `aeson <2` takes 11 s.

2. **Flag cells that cover every state, unsimplified.** *(Gone for now: with flags
   fixed at their defaults no cell is ever pinned, so no proof line can print one.
   Kept because it returns with the flag axis, and because the fix — a `mergeCells`
   sibling — is cheap and independent of when that happens.)* Terms like

   ```
   aeson >=1.2.2.0 && <1.4.2.0 -bytestring-builder
     or >=1.2.2.0 && <1.4.2.0 +bytestring-builder
     or >=1.2.2.0 && <1.4.2.0 (no bytestring-builder flag)
   ```

   are three cells over one range covering all three pin states — semantically "any
   instance of `aeson` in that range", and printable as such. A cell set that exhausts a
   flag's states at identical version sets should collapse to the flag being
   unconstrained. That is a `mergeCells` sibling and cheap; nothing about it needs the
   report layer.

3. **Chain collapsing (gap 3), unstarted**, which is what turns "A depends on B" +
   "B depends on C" into one sentence.

**What cabal does better, stated honestly.** Its message is not a proof and its closing
"goals I've had most trouble fulfilling" is a heuristic list rather than a cause — but
it is 16–30 lines whatever the problem, because it reports the search it did rather
than a derivation. Ours is a genuine proof and on `lens <4` reads far better; it just
has no bound on length. Fixing (1) and (2) is what makes the comparison the one the
project claims.

### Generation-time depender collapsing: landed, and it is a trade (2026-08-12)

`Bridge.Provider.spanningOccurrence` implements `references/pubgrub.md:456` where the
spec asks for it. For each guarded dependency occurrence of the chosen release, walk
neighbouring releases in both directions while each carries the *same* occurrence
(same guard, same `Dependency` — compared per dependency, not per group, which is
`flags-semantics.md` §4.2's unit), then emit one incompatibility over the contiguous
half-open range. Requiring an identical guard is what keeps the flag axis sound: every
release in the span declares the flags the guard mentions, so no third pin state is
needed and unmentioned flags stay free.

| problem | time | reads | proof lines | decisions |
|---|---|---|---|---|
| `vector` | 0.63 → 0.90 | 13 → **108** | — | 39 → 39 |
| `pandoc` | 1.59 → **10.57** | 167 → **2834** | — | 266 → 266 |
| `conduit <1.3` | 1.62 → **0.99** | 142 → 287 | 1061 → **74** | 127 → 60 |
| `lens <4` | 1.84 → 2.25 | 557 → **317** | 9 → **80** | — → 93 |
| `aeson <2` | 11.12 → **2.37** | 250 → 423 | 2833 → **277** | 1376 → 438 |

**What it bought.** Exactly what it was for, on the two problems that were unusable:
`aeson <2` is **4.7× faster** with a proof **10× shorter** and a third of the decisions;
`conduit <1.3`'s proof is **14× shorter**. cabal's `aeson <2` message is 30 lines, so
277 is still far off — but 2833 was not a starting point, and the remaining lines are
now mostly chain-collapsing (gap 3) and flag-cell (gap 5) work rather than
release-by-release merging.

**What it cost, and this is not small.** The walk is O(#releases of the depender) per
expansion, and it pulls in releases the solver never needed. `pandoc` — the
index-throughput case with one conflict — went **1.59 s to 10.57 s and 167 reads to
2834**. `vector` went 13 reads to 108. Read-dominated problems are hurt badly, and
`lens <4`'s proof got *longer* (9 → 80) because the search takes a different path.

So it is a genuine trade, not a win: **conflict-heavy problems get much better,
read-heavy problems get much worse.** Four ways out, none tried:

1. **Walk downward only.** The solver tries newest-first, so the older direction is
   where the useful span is; halves the reads at some loss of span.
2. **Cache the span** per `(package, guard, dependency)`. The same occurrence is
   re-walked on every expansion of that package, which is pure repetition.
3. **Bound the walk** to k steps. Cheap, but the benefit came from long runs.
4. **Merge on insert into the store instead** (pubgrub-rs's `merge_dependents`,
   `references/pubgrub/src/internal/core.rs:322`): keep per-slot emission and union
   adjacent clauses as they arrive, which needs **no extra reads at all** because slots
   touch. It only merges releases actually expanded, so it is weaker than the spec's
   rule, but it is the variant with no downside on `pandoc`. Needs the store keyed by
   (depender, dependee), which our list-shaped store is not — and clause position
   dominates propagation cost here, so it wants measuring rather than assuming.

**All of this is written up properly in [collapsing.md](collapsing.md)**, which is
self-contained and is where to start: the five options with what each actually fixes
(option 1's "halves the reads" was wrong and is corrected there), why term equality
turns out to be *exact* for the terms option 4 would compare, the three possible store
shapes, and the one measurement that is the only open question — price the store change
with no merging in it, and see what the indirection costs on `pandoc` against `aeson`.

Before any of it: `noversion` events rose on all three unsat problems (`conduit` 1 → 6,
`lens` 1 → 8, `aeson` 0 → 9), which is unexplained and might be a hole the collapsing
opened.

**Re-measured on 2026-08-17** (next section). The prediction was longer spans, because
`spanningOccurrence` extends while neighbours carry the same guard and every guard is
now a literal — so two releases declaring the same dependency under differently-written
conditions compare equal where they used to break the span. That is what happened, and
it is a few per cent: proofs 13–15% shorter on two problems, reads slightly *up*. **The
table above still describes the tree.** What the re-measurement did add is the column
this one lacks — `pandoc`'s residency tripled — which makes option 4 more urgent, not
less.

### Re-measured after the scope cut (2026-08-17)

Open question 0, discharged. `bench/compare.sh` over the whole set, one machine, warm
index, `-v` on for our solver (so our elapsed figures are upper bounds); quiet
two-run timings for ours in the second column.

| problem | verdict | ours, `-v` / quiet ×2 | cabal | ours res | cabal res | ours alloc | cabal alloc |
|---|---|---|---|---|---|---|---|
| `vector` | both sat | 1.00 / 0.90, 1.06 | 1.24 | **22.6** | 49.9 MB | **0.84** | 0.86 GB |
| `pandoc` | both sat | 8.62 / 6.51, 6.84 | **1.95** | 81.0 | 80.1 MB | 17.31 | **1.80** GB |
| `conduit <1.3` | both UNSAT | 1.23 / 1.10, 1.15 | 1.24 | **22.6** | 49.9 MB | **1.23** | 1.32 GB |
| `lens <4` | both UNSAT | 2.28 / 1.79, 1.80 | 1.79 | **34.1** | 76.2 MB | 3.25 | **1.88** GB |
| `aeson <2` | both UNSAT | 2.63 / 2.05, 2.26 | 3.51 | **30.7** | 80.4 MB | **4.24** | 5.43 GB |

Our search counts, against the same run of 2026-08-12 (counts are deterministic, so
these differences are real):

| problem | decisions | conflicts | no-version | reads | proof |
|---|---|---|---|---|---|
| `vector` | 39 → 39 | 0 → 0 | 0 → 0 | 108 → **116** | — |
| `pandoc` | 266 → 266 | 1 → 1 | 0 → 0 | 2834 → **2871** | — |
| `conduit <1.3` | 60 → **51** | — → 22 | 6 → **5** | 287 → 289 | 74 → **62** |
| `lens <4` | 93 → **90** | — → 49 | 8 → **7** | 317 → 317 | 80 → 80 |
| `aeson <2` | 438 → **392** | — → 78 | 9 → **7** | 423 → 423 | 277 → **241** |

(A `—` is a figure the 2026-08-12 table did not record, so the cell is today's value
alone. `vector` and `pandoc`'s conflict counts come from the pre-collapsing table,
where they were also 0 and 1.)

**Finding 1: the scope cut barely moved this problem set, and that is informative.**
Proofs are 13–16% shorter on `conduit` and `aeson`, decisions a few per cent down,
reads up very slightly, `lens <4` identical to the line. The predicted direction was
right — longer spans, so shorter proofs and marginally more reads — but the magnitude
says something the prediction did not: **flags were hardly a search dimension on these
five problems in the first place.** The 2^k cost was real in
`test/FlagSolveSpec.hs` and theoretical here. Anyone tempted to argue that removing
flag search is what makes the solver competitive should read this table first: it did
not, and it was not why the cut was made.

**Finding 2: depender collapsing is a worse trade than recorded, and the missing
column was memory.** `pandoc` at the pre-collapsing commit was 167 reads, 1.59 s and
**22.9 MB** max residency. It is now 2871 reads, 6.5–8.6 s and **81.0 MB** — our
memory advantage on that problem is gone, and it is the metric the deliverable leans
on hardest. The arithmetic is consistent with the obvious cause: ~2700 extra retained
reduced forms over ~58 MB is ~21 KB each, and `vector`'s 103 extra reads at that rate
would be ~2 MB, which is inside its floor and indeed invisible. Allocation says it
loudest: **17.31 GB against cabal's 1.80 GB, 9.6×**, on the one problem in the set
that has no search to win.

**The attribution is clean on `pandoc` and only there.** Its verdict, decisions and
conflicts are identical across every tree in this file; the sole thing that moved is
reads, 167 → 2834 measured against the immediately preceding commit. Nothing else can
be responsible.

The other direction cannot be quantified from what is recorded. The last allocation
figures for `aeson <2` and `lens <4` are 22.998 GB and 14.491 GB from the narrowing
experiment above, and they now allocate **4.24 GB** and **3.25 GB** — but that
interval contains the non-reinstallable-boot rule *as well as* collapsing, and those
two problems answered **sat** then and **UNSAT** now. Different question, different
search: a ~5× drop that cannot be handed to either change. Recording allocation on
both sides of a commit, which nobody did for collapsing, is what would have settled
it.

So `collapsing.md`'s recommendation stands and gets more urgent. Option 4 (merge on
insert, zero extra reads) is the only one of the five that removes `pandoc`'s cost
without giving back whatever collapsing is worth on the search problems, because it
does not walk.

**It was built the same day** — see the next section. The regression is gone, and the
search problems kept their win, so the "unclear parentage" above stops mattering: the
current tree is better than either tree being compared.

**Finding 3: the `noversion` rise survives the cut**, and is therefore not a flag
artifact: `conduit` 1 → 6 → 5, `lens` 1 → 8 → 7, `aeson` 0 → 9 → 7 across
pre-collapsing, post-collapsing, today. Still unexplained, still the thing to
understand before optimising the mechanism that produced it.

**One thing to watch, not yet a finding.** cabal's `aeson <2` went 1.90 s → 3.51 s and
its allocation is 5.43 GB against our 4.24 GB — the first problem where we allocate
less than cabal. Single unrepeated runs at ±25% do not stretch to 1.8×, so this is
probably real, and the likely cause is ours: a manual flag is not *weak*, so
`deferWeakFlagChoices` no longer defers the flags that influence dependencies and
cabal's goal ordering changed. If so, we made the baseline slower by constraining it,
which is fair but has to be said out loud in any published comparison.

### Merge on insert: the collapsing trade is gone (2026-08-17)

[`collapsing.md`](collapsing.md)'s option 4, built. The provider no longer walks
neighbouring releases to find out what they declare; it emits one dependency fact per
release **slot**, and the new [`PubGrub.Store`](../src/PubGrub/Store.hs) unions the
depender terms of two facts that agree about the dependee as they arrive. Slots are
what makes that free: adjacent slots touch, so their union is one contiguous interval
and no `.cabal` is read to discover it.

Against the walk, on the same machine and index:

| problem | reads | allocation | max residency | proof | decisions |
|---|---|---|---|---|---|
| `vector` | 116 → **13** | 0.84 → **0.38** GB | 22.6 MB | — | 39 |
| `pandoc` | 2871 → **167** | 17.31 → **1.53** GB | 81.0 → **22.6** MB | — | 266 → 270 |
| `conduit <1.3` | 289 → **174** | 1.23 → **1.20** GB | 22.6 MB | 62 → **43** | 51 → **137** |
| `lens <4` | 317 → **178** | 3.25 → **2.55** GB | 34.1 → **26.1** MB | 80 → **9** | 90 → **106** |
| `aeson <2` | 423 → **261** | 4.24 → **3.15** GB | 30.7 → **22.6** MB | 241 → **178** | 392 → **758** |

**Both halves of the trade moved the right way at once**, which the walk by
construction could not do. `pandoc`'s regression is not reduced, it is gone: reads,
allocation and residency are back to their pre-collapsing values, and the proofs are
*shorter* than the walk made them rather than longer.

And against cabal, which is the comparison that matters:

| problem | ours, `-v` / quiet ×2 | cabal | ours res | cabal res | ours alloc | cabal alloc | our proof | cabal's message |
|---|---|---|---|---|---|---|---|---|
| `vector` | 0.77 / 0.78, 0.86 | 1.00 | **22.6** | 49.9 MB | **0.38** | 0.86 GB | — | 55 |
| `pandoc` | 1.18 / 1.32, 1.38 | 1.99 | **22.6** | 80.1 MB | **1.53** | 1.80 GB | — | 385 |
| `conduit <1.3` | 1.24 / 1.06, 1.16 | 1.60 | **22.6** | 49.9 MB | **1.20** | 1.32 GB | 43 | **16** |
| `lens <4` | 1.49 / 1.52, 1.57 | 1.53 | **26.1** | 76.2 MB | 2.55 | **1.88** GB | **9** | 22 |
| `aeson <2` | 1.66 / 1.66, 1.75 | 2.60 | **22.6** | 80.4 MB | **3.15** | 5.43 GB | 178 | **30** |

**We are now faster than cabal on all five, leaner in memory on all five (2.2–3.5×),
and allocate less on four of five.** `lens <4` is the exception on allocation, and it
is also the problem where our proof is **9 lines against cabal's 22** — the first
side-by-side that looks like the thing the project set out to demonstrate. `conduit`
and `aeson` are still 2.7× and 5.9× longer than cabal's message; that is chain
collapsing (Reporting gap 3), which nothing here touches.

**Three things to know before building on this.**

- **The rule is weaker than the spec's.** `references/pubgrub.md:456` wants the range
  to run from the first release that has the dependency to the first that does not;
  we merge only the releases the solver actually expanded. Those are the only ones
  whose clauses ever existed, so propagation and the proof cannot tell — but a
  statement about an unvisited release is not being made, and if something ever needs
  one, this is not where it comes from.
- **Decisions went up, sharply on two problems** (`conduit` 51 → 137, `aeson`
  392 → 758). Merging cannot prevent a re-expansion the way a pre-emptively wide
  clause could; it widens the clause after the second release has been expanded. The
  extra decisions are cheap here — every other metric improved — but a change that
  makes re-expansion expensive again should look at this first.
- **The store change itself was free**, measured with merging disabled: counts
  identical, allocation within 0.002%. That is because the shape used avoids the
  per-clause indirection all three candidate shapes in `collapsing.md` §4 would have
  added — the clauses stay a plain list in scan order and only a merge pays anything.

### Where the no-version events came from (2026-08-17)

`collapsing.md` §6 had carried an unexplained rise in `noversion` events since
generation-time collapsing landed, with a standing guess that wide clauses were
opening holes in ranges. Read off the traces, that is wrong. Of the fourteen events
across the three unsat problems, **eleven were `base`** — one was a dead-space range
in `transformers`, two were the solver reaching the bottom of a version list.

The eleven are one fact, discovered repeatedly. `base` is non-reinstallable, so the
provider offers installed units and nothing else; any range holding no installed unit
makes `expand` answer `Nothing`, and the solver learns `noInstances base <range>` —
once per distinct range, five times on `aeson <2`. Nothing about that is a hole:
the ranges are fine, the only-installed rule is what empties them.

So the provider now states it once, when it first commits to an installed unit of
such a package: **`base` cannot be built from source**, the whole source side banned
in one clause. As a unit clause it propagates at level 0, so a dependency on a
source-only range of `base` contradicts immediately rather than after a decision and
a provider call. It is what the baseline has always had — cabal takes the same rule
as an input constraint (`PackagePropertyInstalled`) — so this closes an asymmetry
rather than adding a rule of ours.

| problem | no-version | proof | resolving steps | allocation |
|---|---|---|---|---|
| `conduit <1.3` | 5 → **3** | 43 → **12** | 189 → **18** | 1.20 → **1.00** GB |
| `lens <4` | 3 → **2** | 9 → **6** | 170 → **13** | 2.55 → **2.45** GB |
| `aeson <2` | 6 → **1** | 178 → **83** | 283 → 173 | 3.15 → 3.16 GB |

**Two of the three unsat proofs are now shorter than cabal's message** — `conduit`
12 against 16, `lens` 6 against 22 — where before only `lens` was. `aeson <2` is 83
against 30 and remains the outlier.

It needed a cause of its own. Rendered as `CauseNoInstances` the new fact reads *"no
version for base in >=0"*, which is false-sounding and unhelpful — there are plenty of
versions of `base`, and the reason none may be used is that the compiler provides it.
`CauseOnlyInstalled` renders as *"base cannot be built from source"*, which is what
`PubGrub.Report`'s own comment had claimed we did since it was written. `lens <4`'s
whole proof is now:

```
1. Because lens ==1.7 is required and lens >=1.7 && <3.10 depends on array >=0.3.0.2 && <0.5, array >=0.3.0.2 && <0.5 is required
2. Because (1) and array >=0.4.0.1 && <0.5.0.0 depends on base >=4.2 && <4.7, array not >=0.3.0.2 && <0.4.0.1 and base not >=4.2 && <4.7 are incompatible
3. Because (2) and array >=0.4.0.0 && <0.4.0.1 depends on base >=4.2 && <4.6, array not >=0.3.0.2 && <0.4.0.0 and base not >=4.2 && <4.7 are incompatible
4. Because (3) and array >=0.3.0.3 && <0.4.0.0 depends on base >=4.2 && <4.5, array not >=0.3.0.2 && <0.3.0.3 and base not >=4.2 && <4.7 are incompatible
5. Because (4) and array >=0.3.0.2 && <0.3.0.3 depends on base >=4.2 && <4.4, base >=4.2 && <4.7 is required
6. Because (5) and base cannot be built from source, version solving failed.
```

**What is left, and each residue is now named rather than counted.** The *first*
query for a boot package still pays, because the fact rides along with a decision and
there has not been one yet — stating all eight at the root fixes that and takes
`lens` to a two-line proof, but costs `aeson` 41% more allocation and 466 more
decisions, so it was measured and rejected (see `Bridge.Provider.onlyInstalled`). The
`transformers >=0.2.2 && <0.2.2.0` event is Reporting gap 2's other half — a declared
bound put into a term verbatim by `widen`, leaving a window no release occupies — and
it is, at last identified, the one conflict that narrowing removed when it was tried
and reverted twice. Reaching the bottom of a version list is not a defect.

### Chain collapsing: the proofs are half as long (2026-08-20)

Reporting gap 3, and it turned out to be __two__ rules rather than one — both from the
spec's own reporting algorithm (`references/pubgrub.md:504`), which
[`PubGrub.Report`](../src/PubGrub/Report.hs) now follows instead of replaying the
derivation tree one node per line:

- **a chain of two external facts is one sentence.** "foo depends on bar ^2.0.0 *which
  depends on* baz ^3.0.0" (`:1018`), and its sibling form "depends on *both* X and Y"
  where two facts share a depender. Each is guarded by a subset test, so a fused
  sentence cannot say more than the two facts do; `isEmpty` is one-sided on an
  `InstanceSet`, and it fails in the safe direction — the guard can only decline to
  fuse where it could have;
- **every other derived step is skipped.** "This tends to end up a little verbose. You
  can skip every other derived incompatibility without losing clarity" (`:528`; the
  algorithm's case 2.ii at `:643`). Where a step's derived cause has a single derived
  cause of its own, that intermediate *conclusion* goes unsaid and both external facts
  are named in one line. This is the half that does the work, because these derivation
  graphs are mostly linear chains.

Line numbers went with it: the spec numbers only the conclusions it refers back to
(`:596`), which in a linear chain is none of them, so a number is now minted in exactly
one place — where the derivation branches.

| problem | proof before | proof after | cabal's message |
|---|---|---|---|
| `conduit <1.3` | 12 | **7** | 16 |
| `lens <4` | 6 | **4** | 22 |
| `aeson <2` | 83 | **57** | 30 |

**Nothing else moved, by construction**: the change is confined to rendering, and
reads, allocation, max residency and every trace count are identical either side of it
(`aeson <2`: 261 reads, 3.22 GB, 22.9 MB, 871 decisions, 173 resolving steps, both
before and after). Two of the three unsat proofs are now shorter than cabal's message
and `aeson` remains the outlier at 57 against 30.

One tooling change came with it. `bench/summarise.awk` counted proof lines by matching
a leading number, which after this counts 9 of `aeson`'s 57 lines; it matches the
opening connective now (`docs/benchmarking.md`).

#### What the spec's own examples then showed, which was not the plan

The two error-reporting examples in `test/PaperSpec.hs` now assert the rendered proof
against a golden file (`test/golden/`, via `tasty-golden` — `cabal test
--test-options=--accept` to update one deliberately), and the spec publishes the exact
wording it expects for both (`:1005`, `:1150`). Our output has the same *shape* as both — one line per step,
"depends on both", a number minted only for the conclusion referred to later, the
back-reference on the joining line, "So," on the conclusion.

Where it differs, on the linear example, the spec writes two lines and we write three.
**The whole difference is Reporting gap 2**, and it is not the cosmetic difference it
was filed as: because our ranges are intensional, the solver separately learns that a
range's *holes* are empty, so each dependency fact is paired with a
`no version for …` sibling — and a dependency fact whose sibling is a hole-is-empty
fact is never adjacent to the next dependency fact. **The clutter is what stops the
chain fusion from firing.** Absorb the siblings (pubgrub-rs's
`collapse_no_versions`) and the two dependency facts become each other's neighbours,
which is precisely the "which depends on" line the spec writes.

That is now the top reporting item, and it is the one to do before any more effort goes
into `aeson`'s 57 lines.

### Unbuildable, stated — and a path the benchmarks never walk (2026-08-20)

`references/pubgrub.md:476` — "if a package version can't be selected […] we just add
an incompatibility indicating that it (as well as any adjacent versions that are also
incompatible) should never be selected". Until now a release whose library cannot be
built here was simply not offered, so the solver learned only that the range it had
narrowed to was empty and said so: *no version for foo in >=2*. The versions exist;
what is missing is a C library on this machine, or the release says
`buildable: False`.

What landed:

- `PubGrub.Incompatibility.unbuildable` — a unit clause banning the instances, with its
  own cause so the proof line can be the reason. It bans the release's whole **slot**,
  unpinned, which is every instance of it while flags are fixed at their defaults; when
  the flag axis returns the term becomes the region where `buildableCondition` is
  false and nothing else changes;
- the provider's candidate scan accumulates one per release it passes over and hands
  them out with whichever release it settles on. No interface change: incompatibilities
  are context-independent, so the solver never requires them to be about the instance
  just decided ([flags-semantics.md](flags-semantics.md) §10);
- `PubGrub.Store` merges them on the same rule it already used for dependency facts.
  Adjacent slots touch, so a run of unbuildable releases is one contiguous clause —
  which is the "as well as any adjacent versions" half of `:476`, for free;
- a proof line now reads `foo >=2.0.0 cannot be built here`.

**Two caveats, and the first of them was wrong within the day.** As landed, the
*exhausted* case still lost the facts: if every release in range was unbuildable the
provider answered `Nothing`, and with no instance to return there was nowhere to put
them short of changing what `expand` returns. This section called that a corner. It is
not — it is the commonest way a popular Hackage package fails to plan, and it is fixed:
see [Reporting why a range is unbuildable](#reporting-why-a-range-is-unbuildable-2026-08-20).

The second caveat stands and is why the first went unnoticed: **none of the five
benchmark problems meets an unbuildable release at all.** Instrumenting the scan counted
zero on all five, so on *that* problem set both the skip and the clause are dead code,
with a measured cost and benefit of nil. The lesson is about the problem set rather than
the code — a five-problem set chosen to measure search cannot report on a path it never
walks, which is what [`failure-cases.md`](failure-cases.md) exists to fix.

### Reporting why a range is unbuildable (2026-08-20)

`references/pubgrub.md:476` had been half implemented since earlier the same day: the
provider stated "this release cannot be built here" for each release its scan passed
over, but when the offered range held nothing *but* unbuildable releases the scan
exhausted, there was no instance to carry the facts out with, and they were dropped.

**The clause was being emitted exactly when it could not help, and dropped exactly when
it would.** A plain `pubgrub hpqtypes` skips five releases and resolves to 1.10.0.1, so
the facts land in a solve that succeeds and no proof ever shows them. Constrain into the
skipped region and the scan exhausts:

| | |
|---|---|
| before | `no version for hpqtypes in >=1.13` |
| after | `hpqtypes >=1.10.0.2 cannot be built here` |
| cabal | `pkg-config package libpq-any, not found in the pkg-config database` |

`expand` now answers `(Maybe Instance, [Incompatibility])` — what it chose, and what it
learned, the second independent of the first. That was the interface change this file
had flagged as the price and deferred; the harvested problem set is what made it worth
paying, because pkg-config failures are **14 of the 28** planning failures among the top
101–500 packages by downloads.

The solver keeps its own progress guarantee rather than trusting the provider to be
thorough. On `Nothing` it inserts the facts and then bans whatever part of the offered
range they do not cover: nothing said → `noInstances` over the whole range exactly as
before; facts covering it → no `noInstances` at all, so the proof cites the reason;
facts covering part → `noInstances` over the remainder only. Either way the whole range
is banned, so the same set cannot be offered twice — the property termination rested on
when `noInstances` was unconditional.

**Measured: identical on all five benchmark problems** — same decisions, reads,
allocation, residency, no-version events and proof lengths, because none of them meets
an unbuildable release. The gain is on the harvested set: `hpqtypes-extras ==1.20.0.0`
is 2 proof sentences against cabal's 8 and names `libpq`; `haskoin-store-data ==1.6.0`
went 6 sentences to 4.

A second wording fix landed with it. A dependency whose dependee range the solver has
already found empty used to print that range twice in one sentence — `haddock ==2.29.1`
printed base's seven-window bound at both ends of the same line. It now reads
"… depends on base >=4.13.0.0 && <4.14 || …, which has no versions", guarded by a subset
test so it cannot claim more than the two facts do. Three of the harvested problems lost
their `no version for` lines to it, which is why gap 2's instance count is 9 of 17 and
not 12.

### The explanation target, now concrete

cabal's `aeson <2` failure is 25 lines of search trace ending in a list of suspects:

```
[__5] rejecting: template-haskell-2.23.0.0/installed-41f7 (conflict: aeson => template-haskell>=2.9.0.0 && <2.18)
[__5] skipping: template-haskell; 2.24.0.0, … (has the same characteristics …)
[__5] rejecting: template-haskell; 2.17.0.0, 2.16.0.0, … (constraint from non-reinstallable package requires installed instance)
[__5] fail (backjumping, conflict set: aeson, template-haskell)
After searching the rest of the dependency tree exhaustively, these were the goals
I've had most trouble fulfilling: base, template-haskell, ghc-boot-th, pretty, aeson,
primitive, time, tagged, vector, tagged:template-haskell, tasty, text, regex-posix,
regex-base, th-abstraction
Try running with --minimize-conflict-set to improve the error message.
```

The actual cause is two facts: `aeson <2` forces `aeson 1.5.6.0`, which needs
`template-haskell <2.18`; the only `template-haskell` that may be used is the installed
2.23.0.0. Everything else in those 25 lines is the search that found it, and the
closing list of fifteen "goals I've had most trouble fulfilling" is a heuristic, not a
cause. **This is the side-by-side the explanation deliverable exists to produce**, and
it is the first real specimen — see `memory/demo-showcase-failure-cases.md`. It only
becomes a fair comparison once our solver reports the same failure rather than a plan.

### One incidental oddity — still open

`aeson <2` resolves with **`base 4.15.1.0`** in the plan — a *source* release of
`base`, not the installed 4.21.0.0. Rung 3 is **strict prefer-installed**, so this
looks like it might be outside the intended model.

cabal's solver, on the same problem and index, also emits a source `base 4.15.1.0`.
That is suggestive but not conclusive, for two reasons, both open: cabal may be
placing it in a *different qualified domain* than ours is (see "First baseline
comparison"), and our baseline does not add cabal-install's constraints against
reinstalling boot packages, which is what would normally stop a source `base` being
chosen at all. Still unsettled; retitled from "settled" once those were noticed.

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
| **Explanation showcase** — real failing problems, pubgrub-hs vs cabal side by side | **the problem set now exists**: 17 real failures harvested from Hackage's build reports, six failure kinds, five positive controls ([`failure-cases.md`](failure-cases.md)). We are shorter than cabal's message on **16 of 17**, and on the two benchmark unsat problems too (`lens <4` 4 lines against 22, `conduit <1.3` 7 against 16; `aeson <2` 57 against 30 is the outlier). Both of the spec's published examples are pinned as golden tests. Still missing: the harness, side-by-side rendering, and gap 2 — which stays the top reporting item because it is also what blocks the last fusion |
| **Benchmark report** — time + peak residency on real sat/unsat problems | **current numbers exist** for five problems, two sat and three unsat, both solvers ([Merge on insert](#merge-on-insert-the-collapsing-trade-is-gone-2026-08-17)), and they are now favourable on every problem. Not a report: index build still not separated from solve, timings are one or two runs against ±25% noise, and what the ~22 MB memory floor consists of is unestablished — which is the next thing to settle, since a memory claim is now the strongest one we have |

The baseline and the shared index are done — `cabal-install-solver` drives cabal's
resolver from the same `withWorld`, which is what makes the comparison
apples-to-apples rather than arranged. What remains for both deliverables is the
**harness**: one process running both solvers per problem, diffing plans rather than
eyeballing them, separating index build from solve, repeating runs, and rendering the
two failure explanations side by side. Plus an unsat problem set, which neither
deliverable can be evidenced without and which does not exist yet.

**One thing the deliverables now have to state outright.** Both solvers run with
every flag pinned to its declared default, which is a restriction of the problem, not
a property of either solver. It makes the comparison fair — neither side may flip a
flag to escape — and it makes some real-world failures unreachable, because cabal's
automatic flags are exactly what it would have flipped. A benchmark or showcase that
does not say so is misleading, however honest its numbers are.
