# Depender collapsing: how it was done, and what it cost

Started 2026-08-12 as a plan for finishing generation-time collapsing; **finished
2026-08-17 by option 4, and by deleting the generation-time walk it was written
about.** Self-contained on purpose — nothing here needs the conversation it came
from.

Subject: stating **one** dependency incompatibility per guarded occurrence over a
range of adjacent releases, instead of one per release, as
`references/pubgrub.md:456` requires. Authority on the emission *shape* remains
[`flags-semantics.md`](flags-semantics.md) §4.2; this file is about the mechanism
and its cost.

> **Outcome, so nobody re-derives it.** The walk
> (`Bridge.Provider.spanningOccurrence`, §1) is gone. The provider emits one fact
> per release **slot**, and [`PubGrub.Store`](../src/PubGrub/Store.hs) unions the
> depender terms of two facts that agree about the dependee as they arrive (§4).
> Against the walk it measured:
>
> | | reads | allocation | max residency | proof |
> |---|---|---|---|---|
> | `vector` | 116 → **13** | 0.84 → **0.38** GB | 22.6 MB | — |
> | `pandoc` | 2871 → **167** | 17.31 → **1.53** GB | 81.0 → **22.6** MB | — |
> | `conduit <1.3` | 289 → **174** | 1.23 → **1.20** GB | 22.6 MB | 62 → **43** |
> | `lens <4` | 317 → **178** | 3.25 → **2.55** GB | 34.1 → **26.1** MB | 80 → **9** |
> | `aeson <2` | 423 → **261** | 4.24 → **3.15** GB | 30.7 → **22.6** MB | 241 → **178** |
>
> Both sides of the trade §1 describes went the right way at once, which the walk
> could never do: reads and memory came back to where they were before collapsing
> existed, and the proofs got *shorter* than the walk made them. Full table, and
> the comparison against cabal, in [STATUS.md](STATUS.md).
>
> What is given up against the spec's rule is the releases the solver never
> expanded. Those have no clause either way, so propagation cannot tell, and a
> proof can only cite what was derived.
>
> **§§1–3 are kept as the record of what was tried.** §4 is what was built, §5
> answers its own measurement, and §6 — the no-version rise, unexplained since
> 2026-08-12 — is answered too, by something that turned out to have nothing to do
> with collapsing. **Nothing in this file is open.**

---

## 1. Where it stands

`Bridge.Provider.spanningOccurrence` walks out from the decided release in both
directions while each neighbour carries the *same* occurrence — same guard, and the
same `Dependency` (compared per dependency, not per group; comparing whole groups is
the mistake §4.2 calls out) — then emits the contiguous half-open range from the lowest
such release to the first release above the highest.

Requiring an **identical guard** is what keeps the flag axis sound: every release in the
span declares the flags the guard mentions, since one that did not could not have
produced that guard. So the third pin state is not needed here, and flags the guard
never mentions stay free in the cell.

Measured against the commit before it:

| problem | time | reads | proof lines | decisions |
|---|---|---|---|---|
| `vector` | 0.63 → 0.90 | 13 → **108** | — | 39 |
| `pandoc` | 1.59 → **10.57** | 167 → **2834** | — | 266 |
| `conduit <1.3` | 1.62 → **0.99** | 142 → 287 | 1061 → **74** | 127 → 60 |
| `lens <4` | 1.84 → 2.25 | 557 → **317** | 9 → **80** | — → 93 |
| `aeson <2` | 11.12 → **2.37** | 250 → 423 | 2833 → **277** | 1376 → 438 |

Re-run on 2026-08-17 (see the banner): `vector` 116 reads, `pandoc` 2871, `conduit`
289 reads / 62 proof lines, `lens` 317 / 80, `aeson` 423 / 241. The right-hand column
moved by a few per cent and nothing here changed sign.

**A trade, not a win.** `aeson <2` is 4.7× faster with a proof 10× shorter;
`conduit <1.3`'s proof is 14× shorter. But `pandoc` — one conflict, reads dominate — is
6.6× slower with 17× the reads, and `lens <4`'s proof got *longer* because its search
takes a different path.

**And the column this table is missing is memory**, which turned out to be where it
hurts most: `pandoc`'s max residency went **22.9 MB → 81.0 MB**, level with cabal's
80.1 MB, because ~2700 extra retained reduced forms at ~21 KB each is ~58 MB. On
`vector` the same rate predicts ~2 MB, which is inside its floor and duly invisible.
Measured 2026-08-17; the mechanism is unchanged since 2026-08-12.

**In allocation — the metric to trust — only the cost side is attributable.**
`pandoc` now allocates **17.31 GB against cabal's 1.80 GB**, and since its verdict,
decisions and conflicts have never moved, the walk is the only candidate. On the
benefit side the last recorded figures (`aeson <2` 22.998 GB, `lens <4` 14.491 GB)
predate *both* collapsing and the non-reinstallable-boot rule, and both problems
answered sat then and UNSAT now; they are 4.24 GB and 3.25 GB today, which is a real
improvement of unclear parentage. Take allocation on both sides of the next commit
here — that omission is why this file cannot state its own benefit in its best metric.

## 2. Why the cost exists at all

**You cannot know whether the adjacent release carries the same dependency without
parsing its `.cabal`.** The read cost is intrinsic to doing this at generation time.
Options 1–3 below only trim it; only option 4 avoids it, by merging what has already
been read rather than going to look.

And the cost falls exactly where the benefit does not: on a problem with no search,
every walked release is one the solver would never have contested.

## 3. The options

### 1. Walk downward only

Drop the `Set.lookupGT` half; the upper bound stays the decided release's own slot.
Candidates are tried newest-first, so the releases the solver has not yet reached are
below, and that is where a wider clause prevents future work.

**Correction to what STATUS first claimed about this.** It does *not* halve the reads.
On a package's first expansion we pick the newest release, so the up-walk terminates
immediately and costs nothing — the 2834 reads on `pandoc` are almost entirely the
down-walk already. On later expansions the up-walk re-treads releases that are already
memoised, so it costs traversal and comparisons, not parses. It saves **time, not
reads**, and gives up the spec's exact upper bound (`references/pubgrub.md:465`) to do
it. Weakest of the four.

### 2. Cache the span per `(package, guard, dependency)`

The same occurrence is re-walked on every expansion of that package, and neither the
index nor the guard changes during a solve. Pure repetition.

Same limitation — reads are already memoised per release, so this buys back the
traversal, the `Set` lookups and the `Dependency` comparisons, not the parses. Cheap,
obviously correct, and worth keeping whichever of the others wins.

### 3. Bound the walk to k steps

The only one of 1–3 that caps parses. Safe in a way worth naming: **any sub-range whose
releases all carry the occurrence is sound** — collapsing less is less general, never
wrong — so `k` is a free knob.

But the benefit came from *long* runs (the `transformers` chains in `conduit`'s proof
were eight-plus releases deep), so a small `k` loses most of the win and a large one
keeps most of the cost. A dial, not a fix.

### 4. Merge on insert into the store

pubgrub-rs's approach: `Incompatibility::merge_dependents`
(`references/pubgrub/src/internal/incompatibility.rs:173` at rev `4dbe916`), called from
`State::merge_incompatibility` (`internal/core.rs:322`, the call itself at `:328`).
Keep per-slot emission — **zero extra reads** — and when a
dependency incompatibility enters the store, find an existing one with the same
(depender, dependee) and an identical dependee term, and replace it with the union of
the depender terms. Because slots are half-open they **touch**, so `unionVersionSet`
coalesces them into a contiguous range unaided. That is the property the slot commit
bought and this is what it was for.

Weaker than the spec's rule: it only merges releases the solver actually expanded. But
those are the only ones whose clauses ever existed, so for **proof size** it should be
nearly as good — `conduit`'s 1061 lines were merges of clauses that did exist.

See §4 for the two things it needs, both now settled except one measurement.

### 5. Walk, but only where there is search

Follows from §2: emit per-slot on a package's **first** expansion, and walk only once
that package has been refuted at least once. `pandoc` re-expands almost nothing, so it
would do almost no walking; `aeson <2` and `conduit <1.3` re-offer the same packages
repeatedly, so they would. Keeps the spec's stronger rule exactly where it pays for
itself.

Untried, and the bookkeeping ("has this package been refuted") is state the provider
does not currently keep.

**Recommendation: 2 + 4 as the durable pair** (memoised, no extra reads, no arbitrary
constant), with 5 as the way to keep the stronger rule where it earns its cost.

## 4. Option 4 in detail

### Term equality is settled, and it is exact

pubgrub-rs requires `Eq` on its version-set type as a **trait bound**
(`references/pubgrub/src/version_set.rs:29`):

```rust
pub trait VersionSet: Debug + Display + Clone + Eq {
```

`Term` derives it (`term.rs:20`) and the merge compares directly
(`internal/incompatibility.rs:191`):

```rust
        let dep_term = self.get(p2);
        // The dependency range for p2 must be the same in both case
        // to be able to merge multiple p1 ranges.
        if dep_term != other.get(p2) {
            return None;
        }
```

They can afford that because their value domain is versions only and `Ranges<V>` is
canonical, so structural equality coincides with semantic equality. Our
`PubGrub.VersionSet` has the same property for the same reason. `InstanceSet` does
**not** — non-canonical DNF on the flag axis, which is why `CLAUDE.md` forbids adding
`Eq` to it.

**But the general problem never arises here**, and this is the part not to re-derive
tomorrow:

- a dependee term is minted by `Bridge.Provider.widen` and never rewritten. Its shape is
  `isInstalled = <a Data.Set, canonical>` and `isSource = [SourceCell vs Map.empty]` —
  *one* cell, *empty* pin map, canonical `VersionSet`. No DNF freedom, so structurally
  equal ⟺ semantically equal;
- non-canonicity only arises for terms that have been through the algebra, and those
  incompatibilities carry `CauseDerivedFrom`, not `CauseDependency`, so they are never
  merge candidates. pubgrub-rs restricts the same way, via `as_dependency()`.

So the merge key can be a **structural** key — `(isInstalled, sort (isSource))`, both
components having `Ord` — and it is exact for the terms it will actually compare.

One detail to copy: they compare `Option<&Term>`, so *both lacking* a term for `p2`
counts as equal. That is the unsatisfiable-dependency case where the term was dropped
and the clause became a unit ban on the depender; our `fromDependency` drops it in the
same circumstance, so the key must treat "absent" as a value rather than skipping those
clauses.

### The key is free; the store is the constraint

`(PackageName, PackageName)` is already in `CauseDependency p1 _ (p2, _)`, and buckets
hold ~1 entry (one declared range per pair, occasionally a few) — pubgrub-rs uses a
`SmallVec` for that reason.

The store is the problem. `src/PubGrub/Solver.hs:431` threads a plain
`[Incompatibility]`, prepended at `go (depIncs ++ incompats')` and
`go (noInstances p range : incompats')`. Replacing an element in a list is O(n) and
moves things — and clause **position** dominates propagation cost here: prepending is
load-bearing, and a dedup memo once cost 22%.

**The property that makes this tractable:** give clauses stable ids and keep the scan
order as ids, and a merged clause keeps its predecessor's id and therefore its place.
Merging then disturbs nothing. That is better than pubgrub-rs, which `retain`s the old
id out of its per-package lists and pushes the new one, moving the clause.

Three shapes:

- **(a) `IntMap Incompatibility` + scan-order `[Int]` + `Map (PackageName, PackageName)
  [Int]`.** Pure, so it fits the core's current constraints — the solver is
  `Monad m, WithLog env SolverMsg m` with no `MonadIO` (`Solver.hs:321`). Cost: one
  `IntMap` lookup per clause per scan, which is exactly the indirection that cost 22%
  before.
- **(b) `[IORef Incompatibility]`.** O(1) replacement, order untouched, one read per
  clause. But it puts `MonadIO` into the core solver, which is deliberately effect-free
  apart from logging. A boundary change, not a detail.
- **(c) Prepend the merged clause and leave the old one.** No store surgery, but the
  narrow clauses stay live and conflict resolution can still pick them — which is the
  proof-size problem we are trying to fix. Buys little.

### The bonus that makes it worth more than it looks

Merging at insert makes the merged clause a **leaf**: `CauseDependency` with the unioned
depender range, which is exactly the fact the spec wants stated. Merging via
`priorCause` instead makes a *derived* node — and those derived nodes **are**
`conduit`'s 1061 proof lines. Option 4 does not shorten them, it stops them existing.

## 5. The measurement it asked for, and its answer

This section used to say: price the store change in isolation before building
anything, because the three candidate shapes all add an indirection to the hot loop
and clause position dominates propagation cost here. That was done, in three steps,
each a full `bench/compare.sh`:

| step | what changed | result |
|---|---|---|
| A | store type in, **merging off**, walk still on | counts identical, allocation within 0.002% — the store change is **free** |
| B | merging on, walk still on | `aeson <2` 4.24 → 2.66 GB, `lens <4` proof 80 → 37, `conduit` decisions 51 → 28; `pandoc` unchanged, since the walk still owns its reads |
| C | walk removed, per-slot emission | the table in the banner |

**The indirection turned out to be avoidable**, which is why A cost nothing. None of
the three shapes in §4 was used. A fourth one is what the code does:

- **(d) values in scan order, plus a `Set` of merge keys.** `stClauses` stays a
  plain `[Incompatibility]`, so propagation walks it exactly as it walked the list
  it replaced — no lookup per clause, which is the whole cost the other shapes were
  trying to buy their way out of. Finding a merge target is an `O(position)` rebuild
  of the list's prefix, paid only on an actual merge, and the key set is what stops
  that walk from ever happening when it would find nothing (the common case: most
  dependency facts are the first of their kind). The merged clause is written back
  in place, so §4's "keeps its predecessor's position" property holds without ids.

Step B is worth keeping in mind separately from C: **merging is doing the work, not
the removal of the walk.** With the walk still in place it already bought a third of
`aeson`'s allocation and half of `lens`'s proof. Removing the walk is what returned
`pandoc` and the memory.

One thing the tables do not show, and it is the honest cost of the weaker rule:
**decisions went up** — `conduit <1.3` 51 → 137, `aeson <2` 392 → 758. Merging
cannot prevent a re-expansion the way a pre-emptively wide clause could; it widens
the clause after the solver has expanded the second release. Those extra decisions
are cheap (no walk, no reads beyond the ones the solver wanted anyway), and every
other metric improved, but a future change that makes re-expansion expensive again
should look here first.

## 6. The no-version rise: answered

`noversion` events rose on all three unsat problems when collapsing landed
(`conduit <1.3` 1 → 6, `lens <4` 1 → 8, `aeson <2` 0 → 9) and this section spent
three sessions calling it unexplained, with a standing guess that wide clauses were
opening holes in ranges the solver then had to refute one at a time.

**The guess was wrong.** Read off the traces on 2026-08-17, the fourteen events then
outstanding were:

| | `base` | dead-space range | bottom of the version list |
|---|---|---|---|
| `conduit <1.3` | 3 | 1 (`transformers >=0.2.2 && <0.2.2.0`) | 1 |
| `lens <4` | 3 | — | — |
| `aeson <2` | 5 | — | 1 |

Eleven of fourteen are `base`, and they are not holes at all. `base` is
non-reinstallable, so the provider offers its installed units and nothing else; any
range holding no installed unit — because it excludes 4.21.0.0 outright, or because a
learned clause has banned it — makes `expand` answer `Nothing`, and the solver learns
`noInstances base <that range>`. One clause per range, all of them the same fact.
Wider clauses did not create the fact; they made the solver meet it in more places.

The fix is to say it once, which is what
[`PubGrub.Incompatibility.onlyInstalled`](../src/PubGrub/Incompatibility.hs) and the
provider now do — and it is what cabal has always done, as an input constraint
(`PackagePropertyInstalled`). Measured:

| | no-version | proof | resolving steps | allocation |
|---|---|---|---|---|
| `conduit <1.3` | 5 → **3** | 43 → **12** | 189 → **18** | 1.20 → **1.00** GB |
| `lens <4` | 3 → **2** | 9 → **6** | 170 → **13** | 2.55 → **2.45** GB |
| `aeson <2` | 6 → **1** | 178 → **83** | 283 → 173 | 3.15 → 3.16 GB |

What is left is exactly the residue the diagnosis predicts, and it is worth keeping
straight:

- **the first query for a boot package**, when it is already source-only. The fact
  rides along with a decision, and there has been no decision yet. Stating all eight
  facts at the root closes this — `lens` goes to a **two-line** proof and zero
  no-version events — but costs `aeson` 41% more allocation and 466 more decisions,
  because eight extra level-0 derivations change which satisfier conflict resolution
  picks. Measured and rejected; see the haddock on `Bridge.Provider.onlyInstalled`.
- **the dead-space range**, which is Reporting gap 2's other half: `widen` puts a
  declared bound into a term verbatim, so `>=0.2.2` against an index whose oldest
  matching release is `0.2.2.0` leaves a window with nothing in it. This is the one
  conflict that narrowing removed when it was tried and reverted twice
  (STATUS.md, "Narrowing declared ranges") — now identified, rather than counted.
- **the bottom of a version list**, which is not a defect: a downward search ends by
  establishing that nothing below the oldest release exists.
