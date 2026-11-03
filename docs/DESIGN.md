# Design — why the solver is built this way

> **What this is.** The design decisions behind pubgrub-hs, one per section, each with
> the evidence that earned it. These are the decisions that are expensive to reverse,
> or that were reversed once already.
>
> **What this is not.** Not a status and not a specification. What the repository
> contains now is [STATUS.md](STATUS.md); the specifications it names overrule this
> file; how the project got here is the decision log in the project's
> Hindsight bank, one document per decision, indexed by `decision-log-index`.

---

## 1. The core knows nothing about Cabal

`pubgrub`, the solver, depends on `base`, `containers`, `text` and `co-log-core`, and
nothing from the cabal ecosystem. `pubgrub-cabal`, the cabal domain, adds
`Cabal-syntax` and no more. Neither depends on `cabal-install` or on
`cabal-install-solver`; the bridge holds that entanglement, and the bridge is the
unpublished `pubgrub-hs` package. The three are separate
packages in one `cabal.project`, the first two with `cabal check` clean, so the split
is a `build-depends` line rather than a sublibrary's visibility flag.

The seam is one callback, `PubGrub.Provider.expand`. It takes a package name and the
accumulated constraint on it. It answers with one instance and the incompatibilities
that decision entails.

There is no neutral problem type handed over up front. Building one means reading every
candidate's `.cabal` file, including the ones the search discards.

**The algorithm is written once, over a domain it reads through a class.**
`PubGrub.Incompatibility.Domain` fixes four types together — the variables, their
values, the sets a term ranges over, and the facts a leaf can state — and the solver
uses variables only through `Ord`, sets only through `SetOps`, and asks the class for
two things besides: the singleton set of a decision, and which clauses the store may
merge. This is the shape of pubgrub-rs's `DependencyProvider`, where one type fixes
the package, version-set and metadata types. The instance is on the variable type,
which names the domain everywhere else: there is no phantom type for it, since the
variable type determines the domain anyway, and an empty type standing for "this
choice of four types" was one more thing to explain and one more type family
annotation to carry. The cabal instantiation is `PubGrub.Cabal`: the instance is on
`Var`, a package or a flag, so a clause of ours is an `Incompatibility Var`, and the
module holds `Var` and `Flag`, the fact type, the six constructors a `.cabal` fact or a
request is stated through, and the merge rule. `Solver`, `Store`, `Provider` and
`Incompatibility` mention nothing of it; `Report` is the cabal renderer and is written
over `Var` on purpose.

**The derivation tree is the core's, and only its leaves are the domain's.** The spec
partitions incompatibilities into the external ones, which state a fact, and the
derived ones, which the solver resolved from two others (`references/pubgrub.md:136`
and `:143`), and its reporting algorithm walks that structure without looking inside
a fact (`:586`, cases at `:595`, `:641` and `:668`). So `PubGrub.Incompatibility.Cause`
fixes the shape — `Seed`, `Fact`, `NoValues` and `Derived` — and the domain supplies
only what a `Seed` or `Fact` says (`FactOf`). Before 2026-10-19 the whole cause was the
domain's, and the core built resolvents and bans through two class methods it could
never read back; every view of the tree was then written over `Cabal`, and the
reporter could not ship with the core. The views are now `PubGrub.Derivation`, written
once, and `conflictSet` with them. pubgrub-rs reached the same shape
(`DerivationTree` is `External | Derived`); unlike it, a dependency fact is not built
into the core, because a dependency of ours carries a guard and a slot, and both are
cabal's.

The variable type is declared injective — a variable type belongs to one domain — so
that a variable alone tells the compiler its domain, and `singleton`, which needs only
a variable and a value, takes nothing else. The empty set needs no variable: it is
`SetOps.empty`, one per set type, because a set of values of a sum type is a product
(§3).

Nothing observable changed when this was done: the gate came out identical, the
goldens unchanged, and the suite at the same count. What it buys is that the solver
module states its own assumptions, and can be read or tested against a toy domain
without `Cabal-syntax` in sight. `pubgrub/test/Toy.hs` is that domain — a package is
a name, a value an `Int`, a set a `Set Int`, a fact one of two sentences — and it
imports nothing from `PubGrub.Cabal`, so the core leaning on cabal again is a compile
error there before it is anything else. It is also the code of `PubGrub.Tutorial`, line
for line, and `ToyDomainSpec` holds the tutorial to it.

## 2. Version sets are intensional

A dependency's declared range becomes **one** set, not one entry per matching
release. The source half of an `InstanceSet` is a single `VersionSet`: canonical
intervals over all of version space, tagged with the spelling the author used.

This is not a local preference. `references/pubgrub.md:1172` makes it one of the four
things that separate PubGrub from CDCL and from answer-set solving. Expanding a range
into concrete versions costs work, and the result has to be turned back into a range
to talk to a user.

The invoice for that choice is smaller than it used to be, because the flag axis no
longer lives in the set (§3):

- **`Eq` and `Ord` are lawful.** Both halves are canonical — a `Data.Set` of
  installed units and an interval list — so two sets denote the same thing iff they
  are equal. `SetOps.equivalent` is kept where a test wants to say what it is asking.
- **Every operation is exact, and `isEmpty` answers both ways.** The one-sidedness
  the earlier cell representation carried came from pins over flags a release might
  not declare; with flags elsewhere, difference is interval arithmetic.
- **No enumeration, still.** A range admits versions the index does not have. Only
  `PubGrub.Cabal.Provider` consults reality, and it enumerates from the index and filters by
  `memberInstance`. So "non-empty" means non-empty in version space, which is why a
  test over a finite sample of versions can check the predicates only one way.
- **Subset and disjointness are answered without building a set.** `relation` asks
  them of every term of every clause on every visit, which is most of what a solve
  does, and the `SetOps` defaults (`isEmpty` of the difference, of the intersection)
  built two sets per term: a fifth of a large solve's time and two fifths of its
  allocation in latti's profile of `haskell-language-server` under flag search
  (2026-10-19). They are class methods now. A version set answers each by one sweep
  over its intervals, an instance set and a value set by halves, a term by cases on
  polarity, and `VersionSetSpec` and `InstanceSetSpec` hold every direct form to the
  default it replaces as an equality. With the version normal form stored once
  ([§14](#14-versions-compare-with-trailing-zeros-insignificant)), the store's
  merge keys computed once (since superseded by the clause index,
  [§5](#5-dependency-facts-collapse-in-two-places)) and
  `incompRelation` a strict fold over the clause's terms rather than a walk over
  their list, HLS under `--flags search` went from 8.92 GB allocated to 2.84 GB and
  `yesod` from 6.23 GB to 2.15 GB, with mutator time down 42% and 41% in
  interleaved runs and every search count and the gate unchanged. Five commits on
  2026-10-19, prompted by latti's profile.

**A version set remembers how it was spelled.** `VersionSet` carries the declared
`VersionRange` it was built from beside its canonical intervals. Only
`fromVersionRange` sets that tag, every operation drops it, `Eq` and `Ord` cannot see
it, and `toVersionRange` hands it back. So a dependency's term prints as its author
wrote it, `^>=4.13.0.0` and not `>=4.13.0.0 && <4.14`, while a derived term, which
nobody wrote, prints canonically. Cabal itself never re-sugars: `fromVersionIntervals`
rebuilds `==v` and nothing else. This is pub_semver's caret class, a plain range that
knows its own spelling; there too the sugar survives exactly as far as the declared
constraint is passed along unchanged. The solver's algebra still runs on intervals.

**What was here before.** Until 2026-10-08 the source half was a disjunctive normal
form: a list of cells, each a version range crossed with pinned flags, with three
states per pin and subsumption pruning between operations, measured at 28,293 cells
without pruning against 41 with. That representation, its non-canonicity and its
one-sided emptiness are recorded in the decision records `decision-0010` to
`decision-0019` and `decision-0054` to `decision-0056`, and in
`decision-log-dropped-directions`. It was removed
when flags became variables.

## 3. A flag is a variable, and a decision is one variable's value

The solver's variables are `Var`: a package name, or an automatic flag of a package.
A package takes an `Instance` — a pre-installed unit or a source release — and a flag
takes a `Bool`. A decision on a package is a release; the flags that release declares
are decided after it, each on its own.

**A set of values is a product, not a sum.** `Value` is `PackageValue Instance |
FlagValue Bool`, and the subsets of `Instance + Bool` are the pairs of an
`InstanceSet` and a `BoolSet`, so `ValueSet` is that pair. Every set operation is
componentwise and total; a package variable's set has an empty flag component and a
flag variable's an empty instance component, which is simply true of them. The empty
set is one constant, `SetOps.empty`, and the ⊤ term `anyTerm` needs no variable.
`InstanceSet` has the same shape one level down: the installed units and the source
range are the two halves of a set over `PreInstalled + Version`. Until 2026-10-08
`ValueSet` was the sum `PackageSet InstanceSet | FlagSet BoolSet`, which gave every
binary operation an unreachable mixed case to answer, an `emptyValueSetLike` that
asked a set its kind, and an `emptySet` in the domain class that took the variable.

**A flag's identity is its declaration.** `Flag` is a name together with its declared
default. Two releases that declare `fast` with the same default share the variable,
so a guarded dependency they both carry is one clause over both
(`references/pubgrub.md:456` applied to the flag axis); a release that changed the
default declares a different flag and gets a variable of its own. At most one
release of a package is ever in a plan, so the shared variable is always that
release's flag. The default rides in the identity so that the provider can offer it
first without knowing which release was decided: `expand (FlagVar _ (Flag _ d))`
reads the variable and nothing else.

**How a flag becomes a goal.** When a release is decided the provider emits, per
automatic flag, `declaresFlag`: `{p: Positive slot, p:f: Negative {False, True}}`.
Propagation derives a positive term for the flag the moment its owner is decided,
and the solver then asks for it. Nothing else ever derives a positive term for a
flag, so a flag is only decided while a release declaring it is decided, and a
learned clause that mentions it under a wider term about the owner is inert for the
owner's other releases. No clause tying the flag back to the versions declaring it
is needed.

**How a guard is stated.** A dependency that holds under a flag condition is
`fromDependency` with a `Guard`: `{p: Positive slot, p:f₁: Positive {b₁}, …, q:
Negative range}`, one clause per disjunct of the `.cabal` condition. The guard's
terms are positive because they are antecedents. With the depender decided and the
dependee out of range, propagation derives `Negative {b}` for the one open flag
("absent or the other value"), and the owner's `declaresFlag` narrows that to the
other value; with the flags in place it derives the dependee's range, as an
unguarded dependency would. A learned clause that widens the flag's two values back
to `{False, True}` is still positive, so "the owning release is in the plan" is never
lost: a flag has no value when its owner is absent, and a representation that dropped
the widened term as universal would forget that the owner is required.

**Manual flags are not variables.** They are resolved at their defaults when the
release is flattened, which is what every flag was before the axis was searched;
`--flags fixed` treats every flag that way and is the default.

**Why not the flag inside the value.** The earlier design put a total flag
assignment into each instance and the pins into each set, so that one variable per
package sufficed. It bought that with the DNF of §2 and with three states per pin,
and conflict resolution had to learn "this release with this flag" one assignment
at a time unless facts were collapsed per guard. The retired specification's §1.4
recorded the argument for it and the price (decision records `decision-0013` to
`decision-0019`, and `decision-log-dropped-directions`);
[flags-as-variables.md](flags-as-variables.md) records the measurement that moved it.

## 4. A release owns a slot, not a point

`PubGrub.Cabal.Provider.withSlots` gives each release the half-open range up to the next
release **present in the index**. A dependency fact names that slot as its depender
term, not the single version.

This costs nothing. The package-to-versions map is already resident, and a slot holds
exactly one real release, so the fact asserts nothing about a release nobody read.

The point is that adjacent slots **touch**. `unionVersionSet` coalesces them, so
`difference` stops manufacturing empty holes between published releases.

**The first release's slot has no lower bound.** `references/pubgrub.md:467` omits
the lower bound when the first published version has the dependency, and
`PubGrub.Cabal.Provider.slotRange` does the same for the first release's slot and for a
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

## 5. Dependency facts collapse in two places

`references/pubgrub.md:456` requires identical dependencies of adjacent releases of
the depender to be one incompatibility. It asks for
`{foo >=1.0 && <1.3, not bar >=1.0 && <2}`, not one fact per release of `foo`. Two
mechanisms deliver that, and both run.

**At generation time.** `spanningOccurrenceWith` in `PubGrub.Cabal.Provider.mkExpand` walks out from the
decided release and reads its neighbours. It extends the depender's range while the
*guarded occurrence* is identical — same guard and same dependency, not the whole
dependency set.

**At insert time.** [`PubGrub.Store`](../pubgrub/src/PubGrub/Store.hs) unions the depender
terms of two facts that agree about the dependee, as they arrive. Unbuildable facts
about one package that give the same reasons merge the same way, which is
`references/pubgrub.md:476`'s half of the rule. Two runs ruled out for different
reasons stay two facts, so a proof never puts one release's missing module on the
other's range. Which facts qualify, and what the merged clause is, is the cabal
domain's `mergeRule` in [`PubGrub.Cabal`](../pubgrub-cabal/src/PubGrub/Cabal.hs); the store only
compares keys.

Merging is sound because the two clauses `¬(p ∈ A ∧ q ∉ R)` and `¬(p ∈ B ∧ q ∉ R)`
together give `¬(p ∈ A∪B ∧ q ∉ R)`. Each half was established separately, so the
union claims nothing new.

**The merged clause is rebuilt as a leaf**, with `fromDependency` or with
`unbuildable`. The alternative is to let conflict resolution reach the same range by
resolving the narrow facts against each other. That produces derived nodes, and those
nodes *are* the proof lines this exists to remove. `conduit <1.3` was once 1061 lines
of pairwise merging.

**A merge replaces the existing clause where it already sits.** The scan order
decides *which* clause propagation acts on when more than one could fire, and
through it which derivation is recorded first, which satisfier a conflict finds,
and so the shape of a proof. New knowledge goes to the front, and a merge keeps the
position of the clause it merged into, so learning that two facts were one does not
reorder anything the search has already settled on. Every count the gate holds
rests on that order being what it was.

**Propagation judges what changed, not the store.** A clause's relation to the
partial solution depends only on the accumulated terms of the variables it mentions,
and a propagation call starts from a fixpoint, so after an assignment to `v` only the
clauses that mention `v` can change their relation, and after a merge only the
merged clause. Until 2026-10-20 `unitPropagation` re-judged every clause after every
assignment, restarting from the front: 1.9 million clause judgements for 1,009
propagation rounds on `haskell-language-server` under flag search, 12.7 million in
latti's larger problem, and more than half of a large solve's time either way. The
store now gives each clause an id in insertion order, keeps the index from a variable
to the clauses that mention it, and answers an insert with the id the clause landed
at. Propagation is handed the clauses inserted, merged or assigned since it last
looked, re-judges them, keeps the set of actionable ones, and acts on the newest —
the clause the full scan found first, every time. Which clauses are still to be
judged is propagation's state, not the store's.

**After a backtrack, the clauses of the variables it moved are re-judged**, and the
whole store only when those are most of it. A backtrack changes the term of every
variable with an assignment above the level it goes back to and of no other, so
re-judging only those variables' clauses, the learned clause, the conflict and the
clauses of the variable the learned clause derives gives the same actionable set,
and `backtrack` answers with the variables it moved. That was first built on
2026-10-20 and not kept: it cut the post-backtrack judgements from 68,271 to 52,348
over the 26 problems at the pin and on `haskell-language-server` from 74,857 to
40,313, with every count identical, but allocation moved by under 0.1% either way,
because the corpus's backjumps go far enough that the moved variables mention most
of the store, and collecting their clauses cost about what judging them saved. The
2026-10-21 review measured the other regime, which the corpus does not have: a
synthetic chain of N packages whose newer versions each need a package with no
versions, so that every package costs V−1 one-level backjumps. There the full
re-judge is conflicts × store, quadratic in N: 2.6 million judgements and 0.6 s at
N=100, 249 million and 58 s at N=1000. Re-judging the moved variables' clauses
takes N=300 from 22.6 million judgements, 3.4 s and 3.3 GB to 0.5 million, 0.45 s and
1.7 GB, and N=1000 from 58 s to 4.7 s. How the set is collected is a cost choice
between two equal results, and the first two ways tried both lost somewhere: a
union per variable rebuilds its accumulator because clause ids interleave, which
cost 5% on a far-backjump chain and 14% on a problem whose duplicate facts give a
few variables thousands of clauses; one set from every id listed cost that second
problem 80%. So the mentions are counted first, which allocates nothing, and the
store is read whole when they are at least its size. On the corpus every count is
identical, yesod's judgements fall from 36,409 to 33,731, pandoc's single far
backjump still reads the whole store, and allocation moves by under 0.02%.

The merge key names a
clause id, so a merge is a lookup rather than a walk down the list comparing keys
(9 million comparisons for 14,088 inserts on HLS before). The search trace on HLS
is byte-identical, every `stats:` count is unchanged, the judgements fell from
1,906,033 to 36,123, and `solve` went from 2.9–3.3 s to 0.94 s with allocation
2.83 → 1.91 GB; `yesod` 2.03 → 1.58 GB, `pandoc` 1.41 →
1.34 GB, the smaller gains where the provider's reads were already the larger
share. With propagation at 6% of the solve, the provider is now two thirds of it:
the derived index's decode, and the neighbour walk's membership test over a
release's dependency list. This is `references/pubgrub.md:302`'s "index them by the names of the
packages they refer to", with one difference: the spec iterates the clauses of a
`changed` set and acts as it goes, which may act on an older clause while a newer
one is also actionable; ours keeps the newest-first choice the scan made, so the
proofs do not move.

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

## 6. The derived index makes a read a decode

`cabal run pubgrub-index` parses all 153,496 releases once, in about 4 minutes, and
writes `_cache/derived-index.cbor` (94.8 MB) plus a 2.5 MB index keyed by tar block.
`Bridge.Provider` consults it first and falls back to parsing on any miss.

Four properties to know before you touch
[`Bridge.Hackage.Store`](../pubgrub-hs/src/Bridge/Hackage/Store.hs):

- **It is a cache, not a source of truth.** `openStore` answers `Nothing` for a
  missing, unreadable or stale-format store, and every miss parses instead. Removing
  `_cache/derived-index.*` costs speed and never correctness. Raise
  `storeFormatVersion` on any encoding change, because a generic CBOR encoding is
  positional.
  The version cache in `Bridge.Hackage` has the same rule under
  `cacheFormatVersion`, and one more: a `Revision` occupies `revisionBytes` on disk
  and the reader skips by that arithmetic, so a change to its encoding must change
  both.
- **It follows the index by block.** Each stored release carries the tar block of
  the `.cabal` it was parsed from, and `srLookup` serves it only when that is the
  block of the revision in force at the run's index-state
  ([§13](#13-the-index-is-read-at-an-index-state)). The Hackage index refreshes
  itself at most weekly, and every release published or revised since the store was
  built is then a miss that parses. The answers stay right, and `parses` stops being
  zero until `cabal run pubgrub-index` runs again.
- **What is stored is the pre-environment form.** `Flatten.envConfVar` resolves
  `os`, `arch` and `impl` against this machine, and buildability additionally
  resolves `pkgconfig-depends` against its `pkg-config` database. A flattened store
  is silently wrong after a GHC upgrade. Parsing is **106× the cost of flattening**
  (2.007 ms against 0.019 ms). So caching only the parse gives up almost nothing, and
  one store stays valid across toolchains.
  `componentDepsAtDefaultsStored` and `buildableAtDefaultsStored` run the *same*
  `flattenWith` over the *same* trees as their description-taking counterparts, so
  the two paths agree by construction, and `pubgrub-hs/test/StoredSpec.hs` asserts it anyway.
- **The trees are ours, not Cabal-syntax's.** `Flatten.Tree` is Cabal-syntax's
  `CondTree` with each node reduced to what is ever read, and a node's dependencies
  are read off its `BuildInfo` (`targetBuildDepends`) rather than off the tree.
  Cabal-syntax 3.18 removed `CondTree`'s constraints parameter, which was only ever
  a copy of that field (the 3.14 parser filled it from there, and 3.18's
  `convCondTree` reads the field where it read the copy), so the one place the
  Cabal-syntax version is consulted is `fromCondTree`, and the stored form does not
  change shape with that package. `storeFormatVersion` went to 7 with this change.
- **CBOR, not `binary`.** 410 B per release against 1040, so 62.5 MB against 159 MB.
  `binary` decodes 2.5× faster, but decode stopped being the scarce resource.
- **Granularity is the release, and the key is the block.** The index is a sorted
  table of fixed-width `(block, offset, length)` records, searched in place, and a
  lookup reads and decodes one entry. The block is what the caller already holds and
  names one revision, so finding it is the validity check. Each entry also carries its
  package and version, compared on read, so a store built against another tar misses
  rather than answers wrongly. A record occupies `recordBytes`, and the reader finds
  one by that arithmetic. Until format 9 the granularity was the package, decoded
  whole on first touch for the neighbour walk's sake. On `haskell-language-server`
  that decoded 6,292 releases to serve 3,612. Keying by block cut allocation by 16% on
  `haskell-language-server`, `yesod` and `pandoc`, and peak residency at `-A256k` by
  11%, 28% and 29%, with the search unchanged.
- **Test suites and benchmarks are deferred.** Each is a CBOR byte string holding its
  own encoding, so decoding an entry steps over it by its length, and the field is a
  thunk that decodes when forced. The driver reads no stanzas, and they are 29% of
  the store's bytes. A thunk cannot fall back to parsing, so bytes that fail to decode
  there throw `StoreCorrupt`, which only damage to the file can cause. Deferring them
  cut allocation by a further 12%, 15% and 16% on the same three problems.

**The derived index does not make a solve faster on its own.** Parsing was 0.3–0.6 s
of runs taking 0.7–6.8 s. Its whole value is that it changed the price of a
*neighbour* read, which is what made [§5](#5-dependency-facts-collapse-in-two-places)'s
walk affordable.

**The baseline does not use the store.** `Bridge.Cabal.Baseline` parses every release
it inspects.

## 7. Boot packages are installed-only

`base`, `ghc-bignum`, `ghc-internal`, `ghc-prim`, `ghc`, `integer-gmp`,
`integer-simple` and `template-haskell` are non-reinstallable.
`PubGrub.Cabal.Installed.nonReinstallablePackages` is the single list both solvers read: our
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

Stating all eight facts up front, at level 0, would take `lens <4` to a two-line
proof. It was
measured and rejected: it costs `aeson <2` 41% more allocation and 466 more decisions.

## 8. A dependency of `p` on `p` is dropped

Real packages declare these constantly, because an executable or sublibrary of `p` is
built against `p`'s library. It is an intra-package edge resolved inside the package.
It is not a version constraint on `p`.

The rule is cabal's. `Builder.extendOpen` adds no goal and no edge when
`qpn == qpn'`, and `not $ isInternal pkg exeDep` does the same for build tools.

Two changes were needed and both are load-bearing:

- `PubGrub.Cabal.Provider` filters the occurrence out, so no such clause is minted.
- `fromDependency` uses `Map.fromListWith intersectTerm`, so two entries about one
  variable are intersected rather than overwritten.

The second one alone makes the clause honest, and an honest clause correctly *bans*
the release, which is still the wrong answer. Without it, `Map.fromList` kept the
last binding, and `lens 1.7`'s `lens ==1.7` became the unconditional
`{lens: Negative ==1.7}` — "lens must be exactly 1.7", asserted of every instance.
That pinned a whole solve and became the unexplained first premise of its proof.
`test/StoreSpec.hs` and `test/FlagSolveSpec.hs` each hold a "self-dependencies" case,
and each was verified to fail without its own half.

Rung 4 owes the one exception. cabal's `Builder.extendOpen` keeps a reverse-dependency
edge for a *setup* self-dependency, so the cycle forces a different setup script.
There are no setup dependencies yet, so there is no edge to keep.

## 9. The report follows the spec's reporting algorithm

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
   bound history one adjacent pair at a time, `samePairRun` finds the maximal run of
   chain steps about the same `(depender, dependee)` pair and states them once, as
   their union. This is sound because each fact says `p ∈ Sᵢ` requires `q ∈ Rᵢ`, so
   `p ∈ ⋃S` requires `q ∈ ⋃R`.
4. **A run collected by depender alone is one sentence.** Rule 3 needs one dependee
   for the whole run; on a problem with an *unconstrained* target there is no such
   run, because refuting one walks the target's version history and consecutive
   releases rarely fail over the same dependee. So `wideningRun` finds the
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

**Every rule is written in one language.** A rule is a partial function from a piece
of the derivation tree to what it makes of it, written as a `do` block in `Maybe`
whose lines each read a view of the tree (`chainStep`, `asDependency`, `runWhile`),
state a guard (`isSubsetOf`, `sameTerms`) or, last, say the sentence. The vocabulary
is the core's `PubGrub.Derivation` (the views of the tree) and the cabal side's
`PubGrub.Cabal.Report.Rule` (the views of a cabal fact), the sentences are
`PubGrub.Cabal.Report.Wording`, and a table of rules is tried in order by `firstOf`,
so the order of a table is part of its meaning and is written next to it. The spec's
own cases live in the core's `PubGrub.Report`, and the cabal rules reach it through a
`Formatter`: its `lineRules` choose the premise of a proof line and the sub-derivation
it continues (rules 3 and 4, tried before the spec's cases 2.ii and 2.iii), its
`clauseRules` join two external facts into one premise (rule 1, the seeds, a
dependency on an empty range, and the spec's own chain and shared-depender
sentences, which name a dependency and so cannot be the core's); and the headline's
two stories are tried as a table of their own. Rule 5 is a pre-pass over the tree and
not a table, and the spec's branching case is the walker's own structure, since it
mints the line number. The views are read-only and the guards are predicates, so a
rule can choose how a step is said and cannot change what the proof claims; adding
a rule is adding a `do` block and a line in a table.

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
the blank line between two branches (`:632`). The request is a seed per target, with
no depender in front of it: a seed reads "foo >=1 is requested", two of them "foo
>=1 and bar are
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

**A second headline line says what the proof is about.** The proof's last line
names the request and its first names the deepest fact, and what a reader wants is
in between: which package ran out of versions, who wanted it, and what it ran into.
On `matterhorn ==90000.1.1` the proof has all three, apart — the window in two
dependency leaves, the refutation in a middle line, the wall on the headline — so
the second line joins them: `matterhorn >=50200.18.0 and mattermost-api >=90000.1.0
leave only aeson >=2.0.1.0 && <2.2, and no aeson there builds on base 4.21.0.0
(installed).` That says what to do, which no single proof line does. Two rules
produce it, tried in that order, and each is a derived step read out rather than a
summary written over the proof.

*The wall rule.* Where the proof rests on a pinned package, the step that does
the work has the shape "x in W is incompatible with base 4.21.0.0 (installed)" —
one positive term on `x`, the rest positive terms on pinned packages — or "x in W
is forbidden" with the pinned leaf among its premises. It is taken nearest the
root. The window is what the seeds force: a dependency leaf is in play when its
depender's range covers a seed's range, or the dependee range of a leaf already in
play, so the chain from the request is forced and `x` must sit in the intersection
of the in-play ranges for it. The line is printed only when that window lies inside
the union of the ranges the wall steps refute, so "no x there builds" is exactly
what those steps say. With one depender it reads "hjsonschema >=1.9.0 needs aeson
>=0.11 && <1.4, and no aeson there builds on base 4.21.0.0 (installed)"; the
declared range is the leaf's, verbatim. The wall is always spelled with its
installed version, since a step's own term for it may be its whole source side.

*The pivot rule*, for a proof with no wall to name. A step resolves on one package
and either keeps a narrowed term for it or drops it when its two terms union to ⊤
(`references/pubgrub.md:418`, `:425`); the step that drops `p` is the proof's own
statement that, with its remaining terms in force, no version of `p` is left. The
one worth a line is the package refuted a piece at a time — narrowed at a step
below, dropped at a step above — nearest the root. The dependers come first, so no
pronoun reaches back: `lsp-types >=2.0.0.0 needs regex, and no version of regex is
compatible with ghcide >=2.15.0.0, lsp-types >=2.0.0.0 and regex-tdfa >=1.3.1.0
together.` A negative term is a way out, "unless aeson >=1.3 && <2.3", since
¬(A ∧ B ∧ q ∉ R) is A ∧ B → q ∈ R; where the only things present are the dependers
the shape is "no version of deriving-aeson suits hlint >=3.4.1 unless aeson >=1.3
&& <2.3". This rule names survivors of a step, and which packages survive is the
order the solver eliminated things — `ghcide` stands where `time` would be read —
which is why the wall rule goes first wherever it applies.

Neither names a seed, since the headline has just said it, nor a pinned package as
the culprit, since the wall says it in fewer words. Over the corpus the line
appears on 14 of 20 problems, ten by the wall rule and four by the pivot rule; the
six without it are the proofs of two sentences, where the proof is already the
summary. `isSubsetOf` and `equivalent` are one-sided, and every guard fails the
safe way: doubt means no line, never a wrong one. The harness carries the whole
block, wrapped lines included, and the gate is untouched because the line opens
with no connective.

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
the declared range with its spelling attached (§2), and the store merge keeps that
term intact, so the proof quotes `base ^>=4.13.0.0 || ^>=4.14.0.0 || … ||
^>=4.19.0.0` where the author wrote that — byte for byte the constraint cabal's own
message quotes. A range the solver derived has no author and prints canonically.
`fillGaps` is in reserve for derived terms only: filling a declared range would
discard its spelling.

**Three more rules of the wording.** An unbuildable release's fact names what rules
it out, "needs pkg-config package libpq, which is not found" or "is marked
buildable: False", and never "cannot be built because": the chain form already opens
with "Because". The module is spelled as Cabal-syntax prints the field, `libpq` and
not cabal's `libpq-any`. And byte-parity with pub's output is not a goal: `^1.0.0`
is Dart syntax and cabal writes `>=1.0.0 && <2`, so the target is the same sentences
and information in cabal's range syntax.

The linear example matches `:1005` sentence for sentence. The branching one differs
from `:1150` only in which facts the derivation happened to pair.

## 10. The request is a list of seeds

`PubGrub.Solver.solve` takes a list of incompatibilities. Each target `p R` is
`request p R`, the unit clause `{p: Negative R}` with cause `CauseRequest`, built by
`Bridge.Provider.withProvider` because widening a range to instances needs the
installed db. They are the spec's opening incompatibility
(`references/pubgrub.md:252`) with the request stated directly, so no package stands
in front of the targets to be decided, printed or filtered out of a plan. Decided on
2026-07-30, built on 2026-09-22 (decision record
`decision-0051-the-request-is-a-list-of-incompatibilities`).

The seeds propagate to derivations at decision level 0 before anything is decided,
and three things follow:

- **Terminal is "satisfied by the seed derivations alone"**, checked before the
  satisfier search (`satisfiedBySeeds`). It is `:377` stated over the seeds: the
  empty incompatibility is satisfied by anything, and one whose every term is
  subsumed by a seed's derivation is satisfied before anything is decided. A
  conflict satisfied at level 0 by a *learned* derivation is
  not terminal and resolves on through that derivation's cause, so the proof still
  says why the fact was forced.
- **The backtrack floor is level 0.** The spec's `max 1` (`:399`) protects a level-1
  decision no conflict undoes, and it says level 0 is safe (`:402`). Here the first
  decision at level 1
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
proof the same length with "X is requested" as its last fact, the paper's two
golden proofs changed on their last line only, and every problem has one decision
fewer. No proof carries a NUL byte; the `-a` in the scripts is a precaution.

**The other seed is a constraint** (2026-10-14): "if `p` is chosen, it is in `R`",
the unit clause `{p: Positive ¬R}` with cause `CauseConstraint`, built by
`PubGrub.Cabal.constraint` from the allowed set and its complement, because the core
has no complement ([STATUS.md §5.1](STATUS.md#51-settled--not-planned-do-not-reopen))
and a package's universe includes the compiler's installed units, which only the
provider side knows: `PubGrub.Cabal.Provider.constrainTo` computes it from the
`InstalledDb`. A flag held at a value is the two-valued case, `flagConstraint`, over
the flag's own variable. A constraint forces nothing into the plan: its level-0
derivation is `Negative ¬R`, "absent or in `R`", and `undecidedPositive` never picks
it up on its own. It is a seed for everything above: a conflict resting on it and the
requests is terminal, and the closing line names it as the proof's own words put it,
"because aeson is constrained to <2 and pandoc is requested, version solving
failed". The driver's `--constraint 'p R'` feeds the same ranges to cabal's solver as
`PackagePropertyVersion` constraints labelled from the command line, so the two
agree on constrained problems too. What a planner reads off a failure is
`conflictSet`: every variable in the derivation, root to leaves, which is cabal's
conflict set in the sense a lock needs — the held packages in it are the ones worth
releasing before solving again.

## 11. Memoise the reduced form, never the parse tree

`Bridge.Provider.releaseReader` memoises, per release, only the form the provider
needs: declared flags, guarded dependencies, and a buildable flag.

Retaining the parsed descriptions instead cost **27.2 s and 904 MB** on `pandoc`,
against 3.7 s and 83 MB uncached. About 170 parse trees each pin their slice of the
index, and every major garbage collection then copies the lot.

Caching more was 7× slower and 10× bigger. Remember this before optimising in the
same area again.

## 12. Decision order is discovery order, and `yesod` is the bill

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
| propagation and term intersection (`intersectTerm`, `termIntersectionFor`, `incompRelation`, `isEmptyTerm`) | 27.7% | 23.1% |
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
  `InstanceSet` cannot be enumerated ([§2](#2-version-sets-are-intensional)), so the
  count has to come from the provider.
- **Make a re-decision cheap.** The incompatibilities a decided instance entails are a
  pure function of that instance, and today they are rebuilt — walk included — on every
  one of the 6 or 7 re-decisions. Memoising them per instance does not remove the
  redundant propagation, which is the larger half, so this is the smaller lever.

**What is not the cause**, each checked: the walk (8% of allocation), the derived index
(a read is 0.073 ms), the number of conflicts (11 is small), and proof rendering
(`yesod` is satisfiable and prints no proof).

## 13. The index is read at an index-state

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
2026-10-08 table in [STATUS.md §2.1](STATUS.md#21-against-cabal-on-the-benchmark-set) carries cabal's
higher figures for that reason, not because cabal changed.
[benchmarking.md](benchmarking.md) records the check.

---

## 14. Versions compare with trailing zeros insignificant

`PubGrub.Version` is the solver's version type. A version is spelled as Hackage names
the release, and `Eq` and `Ord` compare the spelling with its trailing zeros dropped,
so `1.2`, `1.2.0` and `1.2.0.0` are one version. Cabal's `Version` orders them
`1.2 < 1.2.0 < 1.2.0.0`. The spelling is kept for display only, the way a
`VersionSet` keeps its declared range ([§2](#2-version-sets-are-intensional)): the
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
([§9](#9-the-report-follows-the-specs-reporting-algorithm)) absorbed it.

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
read. The `impl(ghc …)` guard in `PubGrub.Cabal.Flatten` keeps Cabal's `withinRange`:
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
versions produced on 2026-09-03 ([STATUS.md §5.2](STATUS.md#52-measured-and-rejected)),
now for free: the user's own `<2` and the slot bound `2.0.0.0` are one cut. `yesod`
pays twelve decisions and three conflicts, the search-path luck
[§4](#4-a-release-owns-a-slot-not-a-point) records for a wider depender term, and
it is the only row that got worse. The proofs kept their 61 sentences.
`scion-browser` lost its phantom interval, and `hjsonschema`'s proof took a different
route through `aeson` at the same length.

**The normal form is computed once, at `mkVersion`.** `Eq` and `Ord` read it on
every comparison, and a solve compares versions far more often than it makes them:
every cut of every version set, every slot, every installed unit. Deriving it per
comparison (`reverse . dropWhile (== 0) . reverse`) was a fifth of a large solve's
time and a third of its allocation in latti's profile of `haskell-language-server`
under flag search (2026-10-19). Storing it beside the spelling cut allocation by
30–36% and mutator time by 40–55% on every problem measured, with the search counts
and the gate unchanged: `yesod` 6.23 → 4.04 GB and 3.04 → 1.81 s, HLS under
`--flags search` 8.92 → 5.73 GB and 4.25 → 2.29 s.

## 15. A component that is not buildable contributes no dependencies

`PubGrub.Cabal.Flatten.componentDeps` puts each sub-library's, each foreign
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
([STATUS.md §2.1](STATUS.md#21-against-cabal-on-the-benchmark-set)).

**The library's buildability is deliberately not gated here.** It is a stronger fact
— an unbuildable library makes the whole release unusable, not merely
dependency-free — and `unbuildableAtDefaults` already carries it to the solver with
the reason attached, which is what lets a proof name the missing `pkg-config` module
([§9](#9-the-report-follows-the-specs-reporting-algorithm)).

**A library unbuildable only under some flag value bans the value, not the release.**
`Flatten.unbuildableStored` resolves each unusable library node's guard under the flag
model, and `Release.relUnbuildable` keeps the guard with the reasons. A node whose
guard holds under every assignment rules the release out as before: `mkExpand` skips
it and states the unit clause over its slot. A node under a guard naming automatic
flags does not: the release is offered, and with it one clause per disjunct of the
guard, `{foo: slot, foo:sys: {True}}` with the reasons as its cause
(`PubGrub.Cabal.unbuildable` with a guard, the shape of a guarded dependency fact).
With the release decided, propagation derives the other value of the one open flag,
so zlib's `if flag(pkg-config) pkgconfig-depends: zlib` on a machine without `zlib`
flips the flag rather than losing every release of zlib — which is what cabal does,
by pruning the flag's branch in validation. The store merges two such facts only
under the same guard, and the proof says "every version of foo with +sys is marked
buildable: False". Under `fixed` every guard is a literal and nothing changes; the
gate's numbers did not move. Built on 2026-10-19, for latti's flag search: a release
buildable at its defaults and not under the chosen assignment was the one way
`--flags search` could hand a planner a plan that does not build.

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
problem has one, so `pubgrub-hs/test/FlattenSpec.hs` is the only thing holding them. The two
that stay out of a dependency's reduction, test-suites and benchmarks, are the two
cabal itself puts behind a `Stanza` that a plain `cabal build` never enables.

**The optional stanzas are the caller's choice, per release.** cabal's planner enables
a stanza per *package*: `cabal test` resolves the test suites of the local packages
and never those of their dependencies. So the choice is an argument of the reduction,
`Flatten.Stanzas` on `releaseOf`, rather than a property of the index: a planner passes
`allStanzas` for a local package and `noStanzas` for everything else, and the driver,
which compares build plans, passes `noStanzas` throughout. When read, a test suite or
benchmark is a component like any other — flag-guarded, gated on its own `buildable:`
through the same `addBuildableCondition`, its build tools in `relTools` — and its
dependency on its own package's library is the self-dependency
[§8](#8-a-dependency-of-p-on-p-is-dropped) drops, so enabling the stanzas pins
nothing. The derived index stores both trees beside the others (`srTests`,
`srBenchmarks`; `storeFormatVersion` 8), and `test/ReleaseSpec.hs` solves a local
package with its tests on over a world of dependencies with theirs off.

`storeFormatVersion` went to 4 with this change: the stored trees are gated before they are written, so a
store from before this serves ungated ones — and one from before the foreign
libraries went in is missing a component outright.

## 16. Build tools and setup dependencies are another namespace's

`build-tool-depends` and `setup-depends` are read, carried and not solved. A release's
`Release` holds them beside its dependencies — `relTools`, flag-guarded like
`relGuarded` and gated on buildability the same way, and `relSetup` — and the provider
rule reads neither. The main solve's plan is the library closure, which is what
`cabal build` would link.

**Why not goals of the main solve.** cabal solves every scope in one run with qualified
goals (`QualExe`, `QualSetup`) and then links instances across scopes so one build
serves both; that is the most intricate part of its solver, and it exists because its
instances are keyed by scope. The planner this solver was built for keys units by
content, so when two solves pick the same version, flags and dependencies they are one
build with no solver cooperation, and nothing needs identity across scopes: a
`Setup.hs` never links against the project's libraries, a build tool's dependencies
never reach the code it generates, and what does need one instance — Template Haskell
and plugins — is `build-depends` in the main namespace. Decided by latti on 2026-10-14
(`latti/DESIGN.md` §5, "one solve per namespace, linked by preference"); the
one-version-per-name model this solver already has is exactly one namespace, so
nothing qualified is needed here, which is also why the qualified-goals design stays
shelved ([STATUS.md §3.2](STATUS.md#32-one-version-per-package-name)).

**What links the namespaces is a preference, never an incompatibility.**
`PubGrub.Cabal.Provider.Preference` is a map from package name to a version and an
automatic-flag assignment, and `mkExpand` tries it first: a preferred release the
offered set admits goes through the same scan as the rule, over a list of one, so one
that cannot be built here states why and falls through to installed-then-newest with
its facts; a preferred flag value is offered before the declared default. A
preference changes which value is chosen and never what is learned, so it cannot
make a solve fail — a tool that genuinely needs another version gets it without
touching the main plan. The main solve passes `noPreference`.

**What the list holds is what cabal's conversion keeps**
(`Distribution.Solver.Modular.IndexConversion.convCondTree`: `getAllToolDependencies`
minus `isInternal`): `build-tool-depends` as written; the legacy `build-tools` names
cabal translates to a package of the same name — `hscolour`, `haddock`, `happy`,
`alex`, `hsc2hs`, `c2hs`, `cpphs`, `hspec-discover` (Cabal 3.16 dropped `greencard`,
haskell/cabal#10908), restated from
`Distribution.Simple.BuildToolDepends.desugarBuildToolSimple` because that module is
in `Cabal` and `pubgrub-cabal` is Cabal-syntax only — and never a tool that is one
of the release's own executables, which is internal. Test suites and benchmarks
contribute theirs exactly when they contribute dependencies, under the same
`Stanzas` ([§15](#15-a-component-that-is-not-buildable-contributes-no-dependencies)). A tool the compiler ships, such
as `hsc2hs`, is in the list like any other: cabal solves it from Hackage too, and
whether an installed program satisfies it is the planner's call.

**The derived index carries both.** The stored node data, which was `()` for every
component but the library, is now the node's tools (`Node`, and `lnTools` on
`LibNode`), and `srSetup` is the release's `setup-depends`; `storeFormatVersion` went
from 5 to 6 and the store was rebuilt at the pin. The gate's numbers did not move: no
main-solve clause changed.
