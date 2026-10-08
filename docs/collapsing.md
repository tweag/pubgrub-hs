# Depender collapsing: what runs, what it costs, and what was tried

`references/pubgrub.md:456` requires identical dependencies of **adjacent releases of
the depender** to be stated as one incompatibility. The spec wants
`{foo >=1.0 && <1.3, not bar >=1.0 && <2}`, not one fact per release of `foo`. The
depender's range runs from the first release that has the dependency to the first that
does not.

The unit of emission is one *occurrence*: a guard paired with one dependency, stated
over the depender's slot, with the guard's flags as terms of their own
([DESIGN.md §3](DESIGN.md#3-a-flag-is-a-variable-and-a-decision-is-one-variables-value)).
This file is about the mechanism and its cost. It is self-contained on purpose.

> **Two mechanisms run, and neither replaces the other.**
>
> 1. **A walk, at generation time.** `Bridge.Provider.spanningOccurrence` reads the
>    decided release's neighbours and widens the depender's range while the occurrence
>    is identical.
> 2. **A merge, at insert time.** [`PubGrub.Store`](../src/PubGrub/Store.hs) unions the
>    depender terms of two facts that agree about the dependee, as they arrive.
>
> §1 and §2 describe them. §3 is the cost and who pays it. §4 records the five options
> that were weighed when the walk looked unaffordable, and why four are now
> unnecessary. §5 and §6 record two measured results.

---

## 1. The walk

`Bridge.Provider.spanningOccurrence` walks out from the decided release in both
directions while each neighbour carries the *same* occurrence: the same guard, and the
same `Dependency`. It then emits the contiguous half-open range from the lowest such
release to the first release above the highest.

**Comparison is per dependency, not per group.** Comparing whole dependency sets
would refuse to group two releases that agree about `q` but differ on an unrelated
dependency, and the fact about `q` would stay one release wide for no reason.

**An identical guard, over the same automatic flags, is what keeps the flag axis
sound.** A flag variable is named by the owner, the flag and its declared default, so
a neighbour that declares the guard's flags with a different default has different
variables and is not spanned (`Bridge.Provider.sameFlags`).

**The walk stops at an unparseable neighbour.** Spanning it would claim a fact about a
release nobody could read.

**The walk is unbounded.** Nothing caps how far it goes. A cap stays sound, because
§4.2 makes maximality policy rather than a requirement, but nothing has chosen one.

## 2. The merge

The provider emits one fact per release **slot** — the half-open range up to the next
release in the index. Slots **touch**, so `unionVersionSet` coalesces two adjacent
ones into a contiguous interval unaided. That is what the slot change was for.

`PubGrub.Store` finds an existing clause with the same `(depender, dependee)` pair and
an identical dependee term, and replaces it with the union of the depender terms.

Three properties make this work.

**Term equality is exact.** `InstanceSet` is canonical in both halves and has a
lawful `Eq`, so the dependee term and the guard are compared with it. Only
`CauseDependency` and `CauseDeclaresFlag` clauses are merge candidates; derived
clauses never are, as in pubgrub-rs's `as_dependency`.

One detail copied from pubgrub-rs: *both* clauses lacking a term for the dependee
counts as equal. That is the unsatisfiable-dependency case, where the term was dropped
and the clause became a unit ban on the depender. The key must treat "absent" as a
value.

**Scan position is preserved.** Clause position dominates propagation cost here.
Prepending new knowledge is load-bearing, and an earlier dedup memo cost 22%. A merge
therefore rewrites the clause **where it already sits**.

The shape used is values in scan order plus a `Set` of merge keys. `stClauses` stays a
plain `[Incompatibility]`, so propagation walks it exactly as it walked the list it
replaced. Finding a merge target is an `O(position)` rebuild of the list's prefix, paid
only on an actual merge, and the key set stops that walk from happening when it would
find nothing. Most dependency facts are the first of their kind.

**The merged clause is a leaf.** It is rebuilt with `fromDependency`, so its cause
stays `CauseDependency` with the unioned range — the fact the spec wants stated.
Reaching the same range through conflict resolution instead produces `CauseDerivedFrom`
nodes, and those nodes **are** the proof lines this exists to remove. `conduit <1.3`
was once 1061 lines of pairwise merging. Merging at insert does not shorten those
lines. It stops them existing.

## 3. The cost, and who pays it

**You cannot know whether the adjacent release carries the same dependency without
reading it.** That is intrinsic to doing this at generation time.

What is *not* intrinsic is the price of a read. Until the derived index landed, a
neighbour read meant a `parseGenericPackageDescription` at **2.007 ms and about 7.7 MB
of allocation**. It is now a CBOR decode at **0.073 ms**, 27 times cheaper.

**The cost falls exactly where the benefit does not.** On a problem with no search,
every walked release is one the solver would never have contested.

`pandoc` is that problem. It has one conflict, so the walk buys it nothing and it pays
for the neighbours anyway: 167 lookups become 2873.

| | walk off | walk on |
| --- | --- | --- |
| `pandoc` reads | 167 | 2873 |
| `pandoc` peak residency | 22.6 MB | **33.1 MB** |
| `pandoc` allocation | 1.53 GB | 1.54 GB |
| `pandoc` elapsed | 1.18 s | 1.16 s |

**Residency is the only column that moves.** Allocation is under 1% apart and the
elapsed times are inside the ±25% noise band, so do not read a time difference here.
The extra 2706 reads cost about 3.8 KB each in retained reduced forms.

That is the same explosion that once got the walk deleted, at a small fraction of the
price. Before the derived index it cost `pandoc` 6.6 times the elapsed time, 17 times
the reads, 81.0 MB of residency and **17.31 GB of allocation**.

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

`futhark` is the clearest case. Its cost was never reads: it re-decided **78 packages
per backtrack** while each conflict removed one `regex` release, and only **12 of the
187** packages it decided ever appeared in a learned clause.

**`yesod` is the largest case, and it was not being measured.** It had never resolved:
over 90 s, thousands of decisions, every conflict at depth 0. It now resolves in
**2.49 s** with 827 decisions and 11 conflicts, and nothing was done to it. Churn is
exactly what a pre-emptively wide clause removes.

It was parked as "does not finish" and therefore stopped being re-run, so nobody
noticed when it started working. It is in `bench/problems.txt` now, and it is the one
benchmark problem where cabal beats us.

**If read-dominated problems ever matter more than search, `pandoc` is the row to
attack, and the lever is walking *less*.** Reading is already as cheap as it is going
to get.

**One proof got longer, and it was fixed in the reporter.** Widening clauses changes
*which* conflict surfaces first, and a different conflict has a different explanation.
`matterhorn` went from 6 to 10 proof sentences, because it began finding a
`hashable`-mediated conflict whose proof walked `hashable`'s bound history one adjacent
pair at a time. `PubGrub.Report` now states a run of same-pair steps once, which took
`matterhorn` to 8 and `happstack-hsp` from 7 to 4.

**That collapse is not `:456`'s**, and the distinction is worth keeping. It merges
facts whose dependee ranges **differ**, which is precisely why the solver had to derive
along them. `:456` merges facts whose dependee range is **identical**.

## 4. The five options, and why four are moot

The options below were weighed while the walk cost a parse per neighbour. Every one of
them **rations** that cost. The cheaper move turned out to be removing it.

> **Before you propose anything here, read this section.** Options B, C and E have each
> been re-derived from scratch by someone who had not read it. The analyses still hold.
> They are moot for a reason none of them anticipated.

### Option A — walk downward only

Drop the upward half and let the decided release's own slot be the upper bound.
Candidates are tried newest-first, so the releases the solver has not reached are
below.

**It does not halve the reads.** On a package's first expansion we pick the newest
release, so the up-walk terminates immediately. On later expansions the up-walk
re-treads releases that are already memoised. It saves time, not reads, and it gives up
the spec's exact upper bound (`references/pubgrub.md:466`) to do so. The weakest of the five.

### Option B — cache the span per `(package, guard, dependency)`

The same occurrence is re-walked on every expansion of that package, and neither the
index nor the guard changes during a solve. Pure repetition. Cheap and obviously
correct, and it buys back the traversal and the comparisons rather than the reads.

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
actually expanded. Those are the only ones whose clauses ever existed, so propagation
and the proof cannot tell.

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

The store change was priced in isolation before anything was built on it, because all
three candidate store shapes added an indirection to the hot loop. Three steps, each a
full run of the benchmark set through both solvers:

| step | what changed | result |
| --- | --- | --- |
| A | the store type in, **merging off** | counts identical, allocation within 0.002%. The store change is **free** |
| B | merging on, walk still on | `aeson <2` 4.24 → 2.66 GB, `lens <4` proof 80 → 37, `conduit` decisions 51 → 28 |
| C | the walk removed, per-slot emission only | `pandoc` back to 167 reads and 22.6 MB |

Step B is the one to remember: **merging did the work, not the removal of the walk.**
With the walk still in place it bought a third of `aeson`'s allocation and half of
`lens`'s proof.

**And the debt was named when it was taken on.** Removing the walk sent decisions up:
`conduit <1.3` 51 → 137 and `aeson <2` 392 → 758. Merging cannot prevent a re-expansion
the way a pre-emptively wide clause can. It widens the clause *after* the solver has
expanded the second release.

Restoring the walk reversed exactly those numbers: `conduit <1.3` 137 → **16** and
`aeson <2` 758 → **309**.

## 6. The no-version rise: answered

`noversion` events rose on all three unsat problems when collapsing first landed
(`conduit <1.3` 1 → 6, `lens <4` 1 → 8, `aeson <2` 0 → 9). The standing guess was that
wide clauses were opening holes in ranges.

**The guess was wrong**, and it survived three rounds of being repeated rather than
checked. Read off the traces, the fourteen events then outstanding were:

| | `base` | dead-space range | bottom of the version list |
| --- | --- | --- | --- |
| `conduit <1.3` | 3 | 1 | 1 |
| `lens <4` | 3 | — | — |
| `aeson <2` | 5 | — | 1 |

Eleven of fourteen are `base`, and they are not holes. `base` is non-reinstallable, so
the provider offers its installed units and nothing else. Any range holding no
installed unit makes `expand` answer `Nothing`, and the solver learns
`noInstances base <that range>`. One clause per range, all of them the same fact. Wider
clauses did not create the fact. They made the solver meet it in more places.

The fix is to say it once, which is what `PubGrub.Incompatibility.onlyInstalled` and
the provider now do. It is also what cabal has always done, as an input constraint.
A proof line now reads `base cannot be built from source`.

**Three residues remain, and each is named rather than counted.**

- **The first query for a boot package**, when it is already source-only. The fact
  rides out with a decision, and there has been no decision yet. Stating all eight
  facts up front, at level 0, closes this and takes `lens` to a two-line proof, but
  it costs
  `aeson` 41% more allocation and 466 more decisions. Measured and rejected.
- **A dead-space range.** `widen` puts a declared bound into a term verbatim, so
  `>=0.2.2` against an index whose oldest matching release is `0.2.2.0` leaves a window
  with nothing in it. This is the one conflict that narrowing removed when it was tried
  and reverted twice. **No instance of this kind is left in the failure corpus.**
- **The bottom of a version list.** A downward search used to end by establishing
  that nothing below the oldest release exists, and the last `no version` line in
  the corpus was this kind, in `futhark`: `no version for regex in <0.0.0.1`. It is
  gone since the first release's slot lost its lower bound
  ([DESIGN.md](DESIGN.md) §4, `references/pubgrub.md:467`): a depender term that
  starts at the first release now has no `<first` complement to discover empty.
