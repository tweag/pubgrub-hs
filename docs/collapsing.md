# Depender collapsing: where it stands and how to finish it

Written 2026-08-12, at the end of the session that landed it. Self-contained on
purpose — nothing here needs the conversation it came from.

Subject: emitting **one** dependency incompatibility per guarded occurrence spanning
adjacent releases, instead of one per release, as `references/pubgrub.md:456` requires.
Authority on the emission *shape* remains [`flags-semantics.md`](flags-semantics.md)
§4.2; this file is about the mechanism and its cost.

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

**A trade, not a win.** `aeson <2` is 4.7× faster with a proof 10× shorter;
`conduit <1.3`'s proof is 14× shorter. But `pandoc` — one conflict, reads dominate — is
6.6× slower with 17× the reads, and `lens <4`'s proof got *longer* because its search
takes a different path.

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

## 5. Do this first

**Price the store change in isolation.** Change the store to shape (a) with **no
merging at all**, then run `bench/compare.sh` (see [benchmarking.md](benchmarking.md)).
That separates the indirection cost from the merge benefit. `pandoc` (scan- and
read-dominated) and `aeson <2` (search-dominated) will disagree and both numbers matter.
If the indirection is free, the merge is a small addition on top; if it costs 20%, we
know before building anything and (b) comes into play.

Everything else about option 4 is settled — term equality, the key, the bucket size, the
cause shape. This measurement is the only open question.

## 6. And before any of it

`noversion` events rose on all three unsat problems when collapsing landed:
`conduit <1.3` 1 → 6, `lens <4` 1 → 8, `aeson <2` 0 → 9. **Unexplained.** It may be a
hole the wider clauses opened, in which case some of the numbers in §1 move again.
Understand that before optimising the mechanism that produced it.
