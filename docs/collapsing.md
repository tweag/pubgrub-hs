# Depender collapsing: what runs, what it costs, and what was tried

`references/pubgrub.md:456` states identical dependencies of **adjacent releases of
the depender** as one incompatibility. The spec wants
`{foo >=1.0 && <1.3, not bar >=1.0 && <2}`, not one fact per release of `foo`. The
depender's range runs from the first release that has the dependency to the first that
does not.

The unit of emission is one *occurrence*: a guard paired with one dependency, stated
over the depender's slot, with the guard's flags as terms of their own
([DESIGN.md §3](DESIGN.md#3-a-flag-is-a-variable-and-a-decision-is-one-variables-value)).
This file is about the mechanism and its cost.

> **Two mechanisms run, and neither replaces the other.**
>
> 1. **A walk, at generation time.** `spanningOccurrenceWith` in `PubGrub.Cabal.Provider.mkExpand` reads the
>    decided release's neighbours and widens the depender's range while the occurrence
>    is identical.
> 2. **A merge, at insert time.** [`PubGrub.Store`](../pubgrub/src/PubGrub/Store.hs) unions the
>    depender terms of two facts that agree about the dependee, as they arrive.
>
> §1 and §2 describe them. §3 is the cost and who pays it. §4 is the five ways to make
> the walk cheaper, and why four are moot. §5 and §6 record two measured results.

---

## 1. The walk

`spanningOccurrenceWith` in `PubGrub.Cabal.Provider.mkExpand` walks out from the decided release in both
directions while each neighbour carries the *same* occurrence: the same guard, and the
same `Dependency`. It then emits the contiguous half-open range from the lowest such
release to the first release above the highest.

**Comparison is per dependency, not per group.** Comparing whole dependency sets
would refuse to group two releases that agree about `q` but differ on an unrelated
dependency, and the fact about `q` would stay one release wide for no reason.

**An identical guard, over the same automatic flags, is what keeps the flag axis
sound.** A flag variable is named by the owner, the flag and its declared default, so
a neighbour spanned under a guard must declare the same automatic flags with the same
defaults (`PubGrub.Cabal.Provider.sameFlags`). An unconditional occurrence does not
care.

**The walk stops at an unparseable neighbour.** Spanning it would claim a fact about a
release nobody could read.

**The walk is unbounded.** Nothing caps how far it goes. A cap stays sound, because
maximality is policy rather than a requirement (§4, Option C), but nothing has chosen
one.

## 2. The merge

Every fact the provider emits covers at least one release **slot** — the half-open
range up to the next release in the index. Slots **touch**, so `unionVersionSet`
coalesces two adjacent ones into a contiguous interval unaided.

`PubGrub.Store` looks an arriving fact up by its merge key, which the cabal domain's
`mergeRule` in `PubGrub.Cabal` defines. A dependency fact's key is the depender, the
dependee, the guard and the dependee's instance set, so a match has the same pair, the
same guard and an identical dependee term. The store replaces it with the union of the
depender terms.

Three properties make this work.

**Term equality is exact.** `InstanceSet` is canonical in both halves and has a
lawful `Eq`, so the key compares dependee terms exactly. Only `CauseDependency`,
`CauseDeclaresFlag` and `CauseUnbuildable` clauses have a key; derived clauses never
do, as in pubgrub-rs's `as_dependency`.

A clause is keyed by its cause rather than its terms. That is for the
unsatisfiable-dependency case, where `fromDependency` drops the dependee's term and
the clause becomes a unit ban on the depender. The cause still names the dependee, so
two such clauses about one dependee merge.

**Scan position is preserved.** The scan order decides which clause propagation acts
on when more than one could fire, and through it the shape of a proof. A merge
therefore rewrites the clause **where it already sits**.

Each clause has an id in insertion order, higher is newer, and `stClauses` is an
`IntMap` from id to clause. A merge key maps to the id of its clause, so finding a
merge target is a lookup, and the merged clause keeps that id.

**The merged clause is a leaf.** It is rebuilt with `fromDependency` (or `declaresFlag`
or `unbuildable`, for the other two kinds), so its cause stays a leaf cause with the
unioned range — the fact the spec wants stated.
Reaching the same range through conflict resolution instead produces `Derived`
nodes, and those nodes **are** the proof lines this exists to remove. `conduit <1.3`
was once 1061 lines of pairwise merging. Merging at insert does not shorten those
lines. It stops them existing.

## 3. The cost, and who pays it

**You cannot know whether the adjacent release carries the same dependency without
reading it.** That is intrinsic to doing this at generation time.

What is *not* intrinsic is the price of a read. Through the derived index a neighbour
read is a decode of CBOR (Concise Binary Object Representation) at **0.073 ms**.
Without it, a read is a `parseGenericPackageDescription` at **2.007 ms and about 7.7 MB
of allocation**, 27 times dearer.

**The cost falls exactly where the benefit does not.** On a problem with no search,
every walked release is one the solver would never have contested.

`pandoc` is that problem. It has one conflict, so the walk buys it nothing and it pays
for the neighbours anyway: 167 lookups become 2873. The walk-off and walk-on columns in
this section were measured as a pair, before later changes moved every count, so read
each row against itself and take today's figures from [STATUS.md](STATUS.md) §2.1.

| | walk off | walk on |
| --- | --- | --- |
| `pandoc` reads | 167 | 2873 |
| `pandoc` peak residency | 22.6 MB | **33.1 MB** |
| `pandoc` allocation | 1.53 GB | 1.54 GB |
| `pandoc` elapsed | 1.18 s | 1.16 s |

**Residency is the only column that moves.** Allocation is under 1% apart and the
elapsed times are inside the ±25% noise band, so do not read a time difference here.
The extra 2706 reads cost about 3.8 KB each in retained reduced forms.

Over parses instead of decodes, the same walk cost `pandoc` 6.6 times the elapsed
time, 17 times the reads, 81.0 MB of residency and **17.31 GB of allocation**.

**What the walk buys, on problems with search.** One conflict removes a run of releases
instead of one at a time:

| | walk off | walk on |
| --- | --- | --- |
| `futhark ==0.27.1` decisions | 4287 | **807** |
| `futhark` conflicts | 53 | **8** |
| `futhark` elapsed | 6.62 s | **2.19 s** |
| `futhark` allocation | 23.1 GB | **3.99 GB** |
| `aeson <2` decisions | 758 | **309** |
| `conduit <1.3` decisions | 137 | **16** |
| `lens <4` decisions | 106 | **60** |

`futhark` is the clearest case. Its cost was never reads: with the walk off it
re-decided **78 packages per backtrack** while each conflict removed one `regex`
release, and only **12 of the 187** packages it decided ever appeared in a learned
clause.

**`yesod` is the largest case.** With the walk off it did not finish in 90 s:
thousands of decisions, every conflict at depth 0. With it on, it resolves in about
**1.3 s** with 828 decisions and 14 conflicts. Churn is exactly what a pre-emptively
wide clause removes.

**If read-dominated problems ever matter more than search, `pandoc` is the row to
attack, and the lever is walking *less*.**

**Widening can lengthen a proof, and the reporter pays that back.** Widening clauses
changes *which* conflict surfaces first, and a different conflict has a different
explanation. `matterhorn` went from 6 to 10 proof sentences, because it began finding a
`hashable`-mediated conflict whose proof walked `hashable`'s bound history one adjacent
pair at a time. Rule 3 of the reporter ([DESIGN.md](DESIGN.md) §9) states a run of
same-pair steps once, which takes `matterhorn` to 8.

**That collapse is not `:456`'s**, and the distinction is worth keeping. It merges
facts whose dependee ranges **differ**, which is precisely why the solver had to derive
along them. `:456` merges facts whose dependee range is **identical**.

## 4. The five options, and why four are moot

The options below were weighed while the walk cost a parse per neighbour. Every one of
them **rations** that cost, and the derived index removed most of it instead.

> **Before you propose anything here, read this section.** Options B, C and E have each
> been re-derived from scratch by someone who had not read it. The analyses still hold,
> and they are where to start if the walk ever has to cost less.

### Option A — walk downward only

Drop the upward half and let the decided release's own slot be the upper bound.
Candidates are tried newest-first, so the releases the solver has not reached are
below.

**It does not halve the reads.** The provider's scan reads every newer release before
it settles on one, so the up-walk only re-treads releases that are already memoised. It
saves time, not reads, and it gives up the spec's exact upper bound
(`references/pubgrub.md:466`) to do so. The weakest of the five.

### Option B — cache the span per `(package, guard, dependency, starting version)`

The same occurrence is re-walked on every expansion of that package, and neither the
index nor the guard changes during a solve. Pure repetition. Cheap, and it buys back
the traversal and the comparisons rather than the reads.

**The key must include the version the walk starts from**, or the cache must store
the run it found and check that the new starting version lies in it. Keyed on
`(package, guard, dependency)` alone it is unsound: the same occurrence can appear in
two runs of a package's releases separated by a release that lacks it, and a cache
that remembers the first run would answer with it for a version in the second.

### Option C — bound the walk to k steps

The only one of A, B and C that caps reads. Safe in a way worth naming: **any sub-range
whose releases all carry the occurrence is sound.** Collapsing less is less general,
never wrong, so `k` is a free knob.

But the benefit comes from *long* runs. The `transformers` chains in `conduit`'s proof
were eight releases deep, so a small `k` loses most of the win and a large one keeps
most of the cost. A dial, not a fix.

### Option D — merge on insert into the store — **built**

pubgrub-rs's approach: `Incompatibility::merge_dependents`, called from
`State::merge_incompatibility`. §2 describes what was built.

It is weaker than the spec's rule, because it merges only the releases the solver
actually expanded, so it cannot stop a re-expansion the way a wide clause does (§5).

### Option E — walk, but only where there is search — **untried, and the most interesting**

Emit per-slot on a package's **first** expansion, and walk only once that package has
been refuted at least once. `pandoc` re-expands almost nothing, so it would do almost
no walking.

The bookkeeping — "has this package been refuted" — is state the provider does not
keep.

pubgrub-rs does essentially this on the *decision* side rather than the emission side.
Its `DependencyProvider::prioritize` takes a `PackageResolutionStatistics`, and the
default keys on conflict count first and fewest-versions second. Same idea, applied to
which package to decide rather than which clause to widen. **If unconditional walking
ever becomes a problem again, this is where to look.**

## 5. Merging is doing the work, and it took on a debt

The two mechanisms were measured apart, each step a full run of the benchmark set
through both solvers:

| what changed | result |
| --- | --- |
| merging on, walk still on | `aeson <2` 4.24 → 2.66 GB, `lens <4` proof 80 → 37, `conduit` decisions 51 → 28 |
| the walk removed, per-slot emission only | `pandoc` back to 167 reads and 22.6 MB |

The first row is the one to remember: **merging did the work, not the removal of the walk.**
With the walk still in place it bought a third of `aeson`'s allocation and half of
`lens`'s proof.

**The debt is decisions.** Without the walk they go up: `conduit <1.3` 51 → 137 and
`aeson <2` 392 → 758. Merging cannot prevent a re-expansion the way a pre-emptively wide
clause can. It widens the clause *after* the solver has expanded the second release.

With the walk back on those numbers reverse: `conduit <1.3` 137 → **16** and `aeson <2`
758 → **309**. That is why both run.

## 6. The no-version rise: answered

`noversion` events rose on all three unsat problems when collapsing first landed
(`conduit <1.3` 1 → 6, `lens <4` 1 → 8, `aeson <2` 0 → 9), and most are not wide clauses
opening holes in ranges. Eleven of the fourteen events read off the traces were `base`.
`base` is non-reinstallable, so the provider offers its installed units and nothing
else. Any range holding no installed unit makes `expand` answer `Nothing`, and without
more the solver learns a `noValues` clause for that range. One clause per range, all of
them the same fact. Wider clauses did not create the fact. They made the solver meet it
in more places.

The fix is to say it once, which is what `PubGrub.Cabal.onlyInstalled` and the provider
do. It is also what cabal does, as an input constraint. A proof line reads `base is
pinned to 4.21.0.0 (installed)`.

**Fifteen events remain over the 26 problems at the pin, of two kinds.** Neither prints
a `no version for` line.

- **The first query for a boot package**, when the range admits no installed unit: 13
  of the 15. The provider answers `Nothing` with the fact beside it, and the event still
  counts. Stating all eight facts up front, at level 0, closes this and takes `lens` to a
  two-line proof, but it costs `aeson` 41% more allocation and 466 more decisions.
  Measured and rejected.
- **A range holding only releases that cannot be built here**: `hpqtypes` and
  `secp256k1-haskell`. The scan's unbuildable facts ride out with the `Nothing`, so the
  proof names the reason.

Two other kinds do not occur. `widen` puts a declared bound into a term verbatim, so a
range can hold a window no release occupies, and narrowing it away was measured and
rejected ([STATUS.md](STATUS.md) §5.2), but none of the 15 is one. And a search cannot
end by finding nothing below the oldest release, because the first release's slot has
no lower bound ([DESIGN.md](DESIGN.md) §4, `references/pubgrub.md:468`): a depender term
that starts there has no `<first` complement to discover empty.
