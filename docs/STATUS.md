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

**Neither deliverable has been measured.** There is no benchmark harness and no
cabal baseline wired in. That is the honest headline: the interesting half of the
project has not started.

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
   *adjacent releases*, which is what `:456` literally asks for and what would make a
   proof line read `foo >=1.0 && <1.3 depends on …`. It needs `NotDeclared`, because a
   term spanning releases that differ in what they declare is exactly where the third
   pin state earns its place.
3. **Should the set algebra be allowed to read flag declarations?** Would make
   emptiness exact and remove the one-sided slack, at the cost of the core/bridge
   boundary. Cost/benefit, not correctness.
4. **Report polish** — `collapseNoInstances`, then chain collapsing, then cosmetics.
   See `CLAUDE.md`'s Reporting section.

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
| **Benchmark report** — time + peak residency on real sat/unsat problems | **not started.** No harness, no baseline |

Both need `cabal-install-solver` wired in as a baseline and both solvers driven from
the one shared index. That structural sharing is the point of the bridge design, and
it is the piece that makes the comparison apples-to-apples.
