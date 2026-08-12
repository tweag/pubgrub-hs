# pubgrub-hs

A native Haskell implementation of the PubGrub dependency version solver, applied
as a proof-of-concept dependency solver for cabal packages.

## Project goal

This is a **proof-of-concept**, not (yet) an integration into cabal-install.
Solving correctly is table stakes; the two questions the PoC actually exists to
answer are:

1. **Explanations / UX** — Can PubGrub produce materially better explanations of
   dependency-resolution *failures* than cabal-install's solver?
2. **Performance** — Can PubGrub match cabal-install's solver on elapsed time and
   peak memory, on real problems?

The deliverables are therefore two evidence artifacts: an *explanation showcase*
(real failing problems, pubgrub-hs vs cabal side by side) and a *benchmark report*
(time + peak residency on real sat/unsat problems, pubgrub-hs vs cabal).

Note: this is a **native** PubGrub implementation (unit propagation + conflict
resolution in Haskell). An earlier framing using Answer Set Solving (ASP / Clingo
via Potassco) was abandoned — there is no ASP component. (ASP could still serve
as an optional external SAT/UNSAT oracle for differential testing, but that is not
on the delivery path.)

## Key references

**Start at `docs/STATUS.md`** — the single current-state document: what works, what
is specified but not built, what is open, and which file wins when two disagree. It
is a summary and not authoritative; the documents below decide. Project history is
`docs/decision-log.md`; abandoned directions are `docs/attic/`.

- **PubGrub algorithm spec: `references/pubgrub.md`** (vendored copy of
  https://github.com/dart-lang/pub/blob/master/doc/solver.md). This is *the*
  authority on what PubGrub requires. When a question is "is this fundamental to
  PubGrub or a choice of ours?", answer it by citing this file with a line number —
  not from our own haddocks or from this CLAUDE.md, both of which describe our
  encoding of the spec and have been wrong about which is which.

  It had **never been checked in** until 2026-08-12, when it went missing from one
  machine and had to be restored by hand. `pubgrub.md` is now tracked and all 13 line
  numbers cited across the docs were verified exact. **The Rust checkout is not**:
  `references/pubgrub` and `references/pubgrub-guide` are nested git repos, so cloning
  this repository does not get them, and their line numbers move with upstream. Cite
  Rust by **function name**, not line — `merge_dependents`, not `:173`. Current
  revisions and what is still owed: `docs/STATUS.md`, "`references/` — how much of the
  authority is actually in the repo".
- **Flag semantics: `docs/flags-semantics.md`.** Same role for flags that
  `references/pubgrub.md` has for the algorithm: what must be *true*, with no
  types in it. Cite it for any question about what a constraint mentioning a flag
  means, what may be approximated, and in which direction. It overrules this file
  and `docs/attic/flags-design.md` (a pre-reboot design doc, superseded on
  semantics).
- **Decision semantics: `docs/decision-semantics.md`** (drafted 2026-08-04,
  **nothing in §2–§9 implemented**). Specifies *condition decisions*: decide the version
  first, then only the flag conditions some dependency guards. It registers its
  deviations from `references/pubgrub.md` in its §1 and defers to
  `docs/flags-semantics.md` on flags. Its §11 lists five amendments to other files, and
  **all five were applied 2026-08-05** — this file claimed for a week that there were
  four and that none were applied. Its §10 notes it subsumes the `expand`-split
  question, and its **prerequisite (§4.2 guarded emission) is now built**, so it is no
  longer inert; §0's three costs are the live argument for or against building it.
- **Formal kernel model: `specification/`** — Lean 4, and **a draft that is not
  authoritative.** It is *our own attempt* at specifying PubGrub, so it never settles a
  question: where it disagrees with `references/pubgrub.md` or `docs/flags-semantics.md`,
  those are right and it is wrong. A theorem there is evidence about that model, and
  nothing proves the model renders either source faithfully. Do not cite it to win an
  argument, and do not change the solver on its authority. (Within the directory, the
  Lean code is normative over its own prose — an internal tie-break only.)
- **Related work: `docs/related-work.md`** — external literature (Potassco/ASP) mapped
  onto specific problems in this repo, with what each paper does *not* settle. A
  reading map; authoritative on nothing.
- PubGrub internals guide: https://pubgrub-rs-guide.pages.dev/internals/intro
- Reference Rust implementation: https://github.com/pubgrub-rs/pubgrub (a second
  implementation's choices, not a specification)
- cabal's modular solver (baseline): the `cabal-install-solver` package, `Distribution.Solver.*`
- Local reference for driving cabal's solver: `../cabal-solver-plan`

## Build & test

```sh
cabal build
cabal test                      # 103 tests, ~0.3 s
cabal run pubgrub -- aeson      # the driver; add -v for the search trace
cabal run pubgrub -- --cabal aeson   # cabal's solver, same index (the baseline)
bench/compare.sh                # both solvers over bench/problems.txt
```

**[`docs/benchmarking.md`](docs/benchmarking.md) is the reference for measuring
anything** — how to run a subset of the tests, what `bench/compare.sh` and
`bench/summarise.awk` report, how to reproduce the numbers in `docs/STATUS.md`, and
which of those numbers are trustworthy. The short version of the last part: counts are
deterministic and times are not (±25% on this desktop), total allocation from
`+RTS -s` is the stable stand-in for time, and a run cannot be both quiet and counted
because every count is derived by counting trace lines.

## Architecture

Three components with a hard dependency boundary — the cabal-install entanglement
is quarantined so the core stays lightweight:

```
pubgrub-hs (library) ──── no cabal-install, no cabal-install-solver
  native PubGrub: Term, VersionSet, Incompatibility, Relation, Solver, Report
  pure algorithm + types; of the cabal ecosystem it needs Cabal-syntax only
  (plus base, containers, text, co-log)
        ▲  consumes a neutral problem type
bridge (private library) ──── cabal-install-solver, Cabal, Cabal-syntax,
                              hackage-security, http-client
  index acquisition + lazy .cabal reads via hackage-security's random-access index
  builds a cabal solver `Index` (convPIs) and feeds it to BOTH:
    ├─ cabal's modularResolver, via Bridge.Cabal.Baseline   (baseline)
    └─ a translation into pubgrub-hs's problem input
  NB: NO cabal-install (see boundary note below)
        ▲
app/Main.hs — the `pubgrub` driver: runs either solver (`--cabal` picks the baseline)
        ▲
harness — NOT BUILT. One run doing both, diffing plans, repeating for timing
```

Current layout (4 cabal components):

- `src/` — library. `PubGrub.hs` (umbrella) plus
  `PubGrub/{Term,VersionSet,SetOps,Relation,Incompatibility,Solver,Provider,Report,Pretty}.hs`,
  `Index/PreInstalled.hs` (the installed-unit model) and
  `InstanceSet{,/SourceCell}.hs` (the solver's set type).
- `bridge/` — private library `bridge`. `Bridge/{Hackage,Installed,Provider}.hs`,
  `Bridge/Hackage/{HttpClient,Unlifted}.hs`, and
  `Bridge/Cabal/{Baseline,Flatten,InstalledPkg}.hs`: index reader, installed-db
  reader, the cabal-solver baseline, flag-parametric `GenericPackageDescription`
  flattening, and the real `Provider`. `Provider.releaseReader` memoises, per release, only the *reduced*
  form the provider needs (declared flags + flag-guarded deps) — never the parsed
  description. Retaining those instead cost 27.2s / 904MB on `pandoc` against
  3.7s / 83MB uncached: ~170 parse trees pinning their slices of the index is
  enough live data to make every major GC copy it.
- `app/Main.hs` — executable `pubgrub`: the CLI driver.
- `test/` — `{VersionSet,InstanceSet,Solver,PartialSolution,Paper,Flatten,FlagSolve,Installed}Spec.hs`.

The cabal baseline landed 2026-08-12: `bridge` depends on `cabal-install-solver`
(and **not** `cabal-install`), `Bridge.Cabal.Baseline` drives
`Distribution.Solver.Modular.modularResolver` over our index, and `Bridge.Provider`'s
`withWorld` opens the index and compiler world once so both solvers are fed from one
read. The *harness* is what is still missing: a single run that does both, diffs the
plans, and repeats for timing.

**Dependency boundary note.** The `../cabal-solver-plan` reference depends on
`cabal-install`, but only for *index acquisition* (`IndexUtils`, `RepoContext`) plus
some CLI-convenience types. We avoid `cabal-install` — including for the baseline,
see `Bridge.Cabal.Baseline` — by talking to `hackage-security` ourselves:
`Bridge.Hackage` bootstraps and refreshes the index, keeps a disk-cached
package→versions map, and reads one release's `.cabal` on demand through
`indexLookupCabal` + `Cabal-syntax`'s `parseGenericPackageDescription`. (An earlier
version of this note claimed we avoid `hackage-security` too and read the tar
directly with `tar`; we do not, and there is no `tar` dependency.) Still to handle:
**`preferred-versions`**. **.cabal revisions** need no work — the index
`hackage-security` hands us already carries only the last revision of each release,
verified 2026-08-12 (152,746 entries, 152,746 distinct). The single shared index
reader feeds both solvers, making the apples-to-apples comparison structural.

## Roadmap — rung-by-rung fidelity ladder

Build the full end-to-end loop early, then add cabal-model fidelity one rung at a
time; each rung leaves a runnable solver and we measure both deliverables at each.

- **Rung 0** — ✅ plumbing: index reading running on real Hackage data.
- **Rung 1** — ✅ version ranges. Solver resolves real Hackage packages end to end.
- **Rung 2** — ✅ flags + conditional deps, as a search dimension. A decision is an
  *instance* (version × total flag assignment); `Bridge.Cabal.Flatten` flattens the
  conditional tree to flag-guarded groups and evaluates them at exactly the decided
  assignment; the provider tries the all-default assignment of a release first and
  considers deviations only once the accumulated constraint excludes it, fewest
  deviations first. Semantics: `docs/flags-semantics.md`, with a worked trace in
  its §9. **The cost that trace describes has been paid** (flag axis of §4.2,
  2026-08-05): a version rejected for a flag-irrelevant reason is no longer re-offered
  per irrelevant assignment, because the depender term carries the guard rather than
  the assignment. What survives is smaller and differently shaped — Reporting gap 1
  below, and `docs/decision-semantics.md` §0.
- **Rung 3** — ⚠️ `base`/GHC pinning (installed db → `PreInstalled` instances, strict
  prefer-installed). **Incomplete, found 2026-08-12 by the baseline.** Strict
  prefer-installed says what to do when an installed unit is admissible; it says
  nothing about the case where a constraint *excludes* it, and there we fall through to
  a source release — so `aeson <2` resolves by planning to build `base 4.15.1.0` from
  Hackage. cabal forbids that (its non-reinstallable list: `base`, `ghc-bignum`,
  `ghc-internal`, `ghc-prim`, `ghc`, `integer-gmp`, `integer-simple`,
  `template-haskell`, mirrored in `Bridge.Cabal.Baseline.nonReinstallablePackages`) and
  reports no plan. Three of the five benchmark problems disagree for exactly this
  reason, and they are not comparable until the provider carries the same rule: a
  non-reinstallable package must offer installed units only, never a source release.
- **Rung 4** — setup / build-tool deps (see reference's `SetupDeps.hs`). Note what
  cabal does here that we have no model for at all: it solves **qualified goals**, so
  each executable and setup dependency gets its **own domain**. `Setup.hs` is an
  executable that is never linked against the library, so it may be built against a
  different `mtl` than the library uses, and cabal's plan can legitimately contain two
  versions of one package. Our decisions are per package name, full stop — one version
  of `mtl` per solve. This has to be specified before rung 4 is built; the immediate
  job is to understand what cabal actually emits (its plan loses the qualifiers to
  `convCP` on the way out, so reading a flat plan will mislead).
- **Rung 5** — public sublibraries.

**Caveat on "measure both deliverables at each rung".** We did not do this for
rungs 0–3, which were built unmeasured; measurement only started 2026-08-12, once the
baseline existed, and it immediately found rung 3 incomplete (above) — which is the
argument for the discipline rather than against it. There is still no harness. The two
workstreams below are what actually gate the deliverables, and they are not rungs:

- **Explanations** — cause tracking is reinstated (`IncompatCause`) and
  `PubGrub.Report` renders a numbered proof. Next: `collapseNoInstances`, then
  the spec's human-friendly wording. See "Reporting" below.
- **Benchmark** — the baseline exists as of 2026-08-12: `Bridge.Cabal.Baseline`
  drives cabal's own modular solver over *our* index, and `pubgrub --cabal <target>`
  runs it. **Without `cabal-install`** — see the module haddock for what the
  `Distribution.Client.*` modules would have supplied and why none of it is needed.
  First numbers, verdict agreement, and the two plan divergences are in
  `docs/STATUS.md` ("First baseline comparison"). What is still missing is the
  harness proper: one process running both, diffing plans rather than eyeballing
  them, and repeating runs.

## The set representation (`InstanceSet`)

The solver's variables are package names; its values are `Instance`es (one
concrete way of having a package: a pre-installed unit, or a source version under
a total flag assignment). `InstanceSet` is the set type the algebra runs on:

```haskell
data InstanceSet = InstanceSet
    { isInstalled :: Set PreInstalledPackage   -- extensional: the db is small and known
    , isSource    :: [SourceCell]              -- DNF, NOT canonicalised
    }
data SourceCell = SourceCell VersionSet (Map FlagName FlagPin)  -- range × pinned flags
data FlagPin    = PinnedTo Bool | NotDeclared
```

**DNF** is *disjunctive normal form* — an OR of ANDs. Here: within one `SourceCell`
the conditions are ANDed (version in this range **and** `simd` pinned on), and the
list of cells is ORed (the set is their **union**). "NOT canonicalised" means nothing
reduces that list to a unique representative, which is why there is no lawful `Eq`
— two different lists can denote the same set.

It is **intensional on the source side**: a dependency's declared range becomes
*one* cell, not one entry per in-range version. That is what makes reports able
to say `>=1.0 && <2`, and what keeps the cell count O(1) per dependency instead
of O(#versions on Hackage).

Intensionality is not a local preference — the spec makes it one of the four
things separating PubGrub from CDCL/answer-set solving (`references/pubgrub.md:1172`,
"Version Ranges"): expanding ranges into concrete version sets costs overhead
*and* has to be reversed again to talk to users. An extensional `Set Instance`
would not be a cheaper variant of PubGrub, it would be the encoding PubGrub
exists to avoid. The awkward consequences (no lawful `Eq`, no enumeration) are
the invoice for that, not for a choice of ours. What *is* ours is the second
coordinate: the flag axis is only ∩-closed *per cell* where `VersionSet` is closed
under all of `∩ ∪ \`, and every `SourceCell` complication below follows from
adding a coordinate whose own algebra is weaker. What that axis has to be able to
say is fixed by `docs/flags-semantics.md` §2, not by convenience: three states per
flag (`PinnedTo True`, `PinnedTo False`, `NotDeclared`) plus absence-from-the-map
for unconstrained, because a two-state pin is not closed under negation and
silently loses instances from a `difference`.

Things worth knowing before touching it:

- **What the core actually requires** is only `SetOps` (`intersect`/`union`/
  `difference`/`isEmpty`) plus `emptyInstanceSet`/`singletonInstance`/
  `memberInstance`. **No complement** (`Term` absorbs negation as a polarity
  flip), **no `Eq`/`Ord`**, and per `PubGrub.Relation`, *no canonical form* — the
  solver only ever asks emptiness questions. So non-canonical DNF is correct by
  construction; pruning is purely a size optimisation.
- **Emptiness is one-sided, by design.** `isEmpty` may answer "not empty" for a
  set that is empty in fact — a cell can pin a flag no version in its range
  declares, and seeing that needs the index. Claiming emptiness wrongly is
  forbidden; failing to notice it is allowed. All the slack lands on
  `Relation.Inconclusive`, which costs work and never a wrong verdict
  (`docs/flags-semantics.md` O3, O4). Consequence for tests: assert
  `isEmpty ⟹ model empty`, never `⟺`.
- Do **not** add `Eq`/`Ord` to `InstanceSet`. A non-canonical representation has
  no lawful structural equality. Use `SetOps.equivalent` (mutual `isSubsetOf`)
  if you need semantic equality.
- `SourceCell` deliberately has **no** `SetOps` instance: cells are closed under
  intersection but *not* under union or difference, so `SetOps` lives one layer
  up, at the DNF. `differenceCell` is disjunction-valued for exactly this reason.
- **Size control is load-bearing.** `union` appends, `intersect` cross-products,
  `difference` multiplies — one cell into up to `1 + 2·|pins|`. Three prunings
  exist and all matter: `differenceCell` drops null cells, `union` calls
  `mergeCells` (join cells with identical pins), and every `SetOps` operation ends
  in `pruneCells` (drop cells subsumed by another, then order deterministically).
  Measured on 24 successive instance bans over 4 flags: **28293 cells with the
  first two alone, 41 with all three**, for a denotation of 56 instances. Pruning
  *between* operations is what bounds it; pruning at the end would be too late.
  `test/InstanceSetSpec.hs`'s "size control" case is the guard.
- `pruneCells` also makes the DNF's order **deterministic** — but note the order
  is ascending (narrowest cell first): it sorts descending and then folds with a
  prepend, which reverses it. Determinism is all it gives. It is *not* a
  preference order, and an earlier version of this file claimed it implied
  "assignments closest to the defaults first", which was false in both directions.
  Flag preference is now stated and implemented explicitly, in
  `Bridge.Provider.preferDefaults`: rank *completed assignments* by how many flags
  deviate from the release's declared defaults (`docs/flags-semantics.md` §5).
  Ranking cells by pin count is not the same thing and is wrong — a one-pin
  `f = False` beats a two-pin `f = True, g = True` on pin count while being the
  deviation rather than the default.
- `widen` admits versions the index does not have. This is fine: the algebra
  never needs the instance universe, and `Bridge.Provider`'s `expand'` is the
  only place reality is consulted — it enumerates candidates from the index and
  filters by `memberInstance`. A symbolic set **cannot be enumerated**, which is
  why every provider must enumerate from its own index instead.

`test/InstanceSetSpec.hs` is the guard: differential properties comparing the
implementation against an extensional model over a small fixed universe, plus the
`Term`-level laws. It found three real bugs when first run, and a fourth when its
universe was fixed. Two things about it are load-bearing, and both were once
wrong:

- keep its ADAPTER pointed at the **intensional** constructor — with an
  extensional adapter the flag-splitting paths go untested *and* the suite OOMs;
- keep its universe **non-uniform**: versions must differ in which flags they
  declare, including one declaring none. A uniform universe cannot distinguish
  the three possible readings of a pin, which is exactly how a wrong `difference`
  passed these properties for weeks (`docs/flags-semantics.md` §6).

## Reporting

`PubGrub.Report.reportConflict` walks the `IncompatCause` tree of the terminal
incompatibility and emits a numbered proof with backward references. The two
unsatisfiable `PaperSpec` examples are the reference cases; the spec publishes
their exact expected English (`references/pubgrub.md:1005` and `:1150`).

Known gaps, in the order worth fixing. **The order is now evidence-backed** (2026-08-12,
first side-by-side against cabal): our proof for `lens <4` is 9 lines against cabal's
22, but `conduit <1.3` is **1061** against 16 and `aeson <2` is **2833** against 30.
Gap 1's version axis is most of that — whole runs of proof lines do nothing but merge
adjacent releases pairwise at derivation time, which is the collapsing
`references/pubgrub.md:456` asks for at generation time — followed by unsimplified flag
cells (see 5 below) and then chain collapsing. See `docs/STATUS.md`, "The explanation
deliverable is currently losing".

1. **Depender-range collapsing** — the one gap that is a *spec divergence*, not a
   cosmetic choice, and the only one fixed outside the report layer. The spec
   requires identical dependencies of **adjacent versions of the depender** to
   collapse into a single incompatibility — `{foo >=1.0 && <1.3, not bar >=1.0 && <2}`
   rather than one per version of `foo` — with the depender's range running from
   the first version that has the dependency to the first that doesn't
   (`references/pubgrub.md:456`). The same adjacency collapsing applies to
   unbuildable instances (`:476`).

   **Both axes have now landed** (flag axis 2026-08-05, version axis 2026-08-12), so
   the paragraphs below are the *history* of the divergence, not its current state.
   The live emission path is `Bridge.Provider.dependencyInc` — the depender term is
   `sourceInstances <span> <guard disjuncts>`, so it pins only the flags the guard
   mentions and spans adjacent releases carrying the same occurrence. There is no
   `depIncs` and no `singletonInstance chosen` any more. ("No instances" was never
   affected — the solver raises that itself from the provider's `Nothing`.)

   *What it was.* We emitted the per-version form the spec tells us not to, with
   `singletonInstance chosen` as the depender. That cost *both* deliverables — more
   incompatibilities to propagate, and proof lines reading `foo 1.2.3 depends on …`
   where the spec's own examples read `foo >=1.0 && <1.3 depends on …`. `mergeCells`
   recovered some of it incidentally, but only after unions during derivation, never
   at generation time, which is where the spec puts it.

   *And it was a performance bug, not only a wording one.* Because the depender was
   one instance, refuting a version taught the solver nothing about that version
   under a different assignment, so a version rejected for a flag-irrelevant reason
   was re-offered once per irrelevant flag assignment — the "2^k" cost. The accurate
   name for the defect is an **over-specific learned clause**: the term named a point
   in the version × assignment space, so a refutation failed to generalise to the
   sibling assignments. `test/FlagSolveSpec.hs` records the k=1 case and
   `docs/flags-semantics.md` §9 traces it; the flag axis fixed it (measured: 2
   expansions where it was 3 with one irrelevant flag, 5 with two).

   **What survives, and it is no longer 2^k in the declared flags.** Three costs
   remain, all because a decision is still a *point instance* — see
   `docs/decision-semantics.md` §0: whole-instance backjumps re-offer a version the
   conflict never questioned; the provider re-derives outside the store what
   guard-shaped terms would narrow inside it; and decisions still name inert flags in
   every trace. The residue is bounded by the number of **guard regions** (cells over
   the flags guards actually mention), not by 2^k over every declared flag. Do not
   call it "the 2^k blow-up" — that name now overstates it.

   *The shape that was built*, fixed by `docs/flags-semantics.md` §4.2, which
   overrules this file: the unit is **one guarded dependency occurrence**
   `C ⇒ q ∈ R`, read straight off the flattened conditional tree. Emit
   `{p ∈ V × C, not q ∈ R}` with the guard `C` used **verbatim** as the depender's
   flag component. That is what keeps flags the guard never mentions out of the
   term, which is the entire point — and it needs no enumeration of assignments and
   no per-assignment dependency sets. Where several occurrences constrain the same
   `q` (an unconditional `q >=1`, a guarded `q <3`), they are emitted as separate facts
   and propagation intersects them.

   **Do not group instances by identical flattened dependency *set*.** §4.2 rejects
   that explicitly, as "a serious mistake, not a conservative one": two assignments
   that agree on `q` but differ on an unrelated dependency fail to group, so the
   depender term still names the irrelevant flag and the 2^k cost survives intact.
   (This file prescribed the rejected form until 2026-08-05.)

   **Landed 2026-08-12, and unfinished — see [`docs/collapsing.md`](docs/collapsing.md)
   before touching it.** `Bridge.Provider.spanningOccurrence` now emits over adjacent
   releases carrying the same occurrence, which cut `aeson <2` from 11.1s to 2.4s and its
   proof from 2833 lines to 277, but cost `pandoc` 6.6× in time and 17× in reads. That
   file has the five ways out, the settled term-equality question, and the one
   measurement to take first.

   On the **version** axis, the free half landed 2026-08-12: the depender's version
   component is a release's **slot** — `halfOpenVersionSet v next`, reaching up to
   the next release *present in the index* — instead of the single version
   (`Bridge.Provider.withSlots`). This costs no `.cabal` read (the package→versions
   map is already resident and is what dominates peak residency) and asserts nothing
   about an unread release, since a slot holds exactly one real release. The point is
   that adjacent slots **touch**, so `unionVersionSet` coalesces them and
   `difference` stops manufacturing empty between-releases holes. Measured on
   `aeson <2`: reads 350 → 250, no-version events 6 → 0, and the gappy eleven-way
   conflict term became one contiguous interval (`docs/STATUS.md`, "Second pass").

   Widening across *distinct* releases — the part that requires reads — then landed on
   top of slots later the same day, as `spanningOccurrence` above. Slots made it
   cheaper, not harder: two adjacent slots already union into a contiguous range, so
   only dependency-identity was left to establish, and that is the read. Note the
   third pin state turned out **not** to be needed on this path: requiring the guard to
   be *identical* means every release in the span declares the flags the guard mentions,
   since one that did not could not have produced that guard
   (`docs/collapsing.md` §1). See also `docs/decision-semantics.md`, which builds on
   this emission shape and treated it as its prerequisite — now paid.
2. **`collapseNoInstances`** — intensional ranges mean the solver must separately
   learn that a range's *holes* are empty, so `no version for bar in >2.0.0 && <3`
   leaves clutter the proof. pubgrub-rs has a dedicated post-pass for exactly
   this: `DerivationTree::collapse_no_versions` (`references/pubgrub/src/report.rs:102`
   at rev `4dbe916`), with the merge rule in `merge_no_versions` (`:133` — this said
   `:132`, which is a blank line). Absorb the range into the sibling cause's term
   by union and drop the node.

   Mostly overtaken by slots (gap 1): holes *between* releases no longer form, and
   `aeson <2`'s no-version events went 6 → 0. What is left comes from the other
   direction — `Bridge.Provider.widen` puts a **declared** dependency range into a
   term verbatim, so dead space (e.g. above a package's newest release) still
   survives.

   Narrowing that against the version map was tried twice on 2026-08-12 and
   **reverted twice**: it removes one conflict on one of five problems and costs 3.9%
   of total allocation. The second attempt was after `ihVersions` became a
   `Set Version`, which made finding an interval's bounds two ordered lookups instead
   of a traversal — and it cost **the same** 3.9%, so the first attempt's diagnosis
   (that the price was fetching and walking the dependee's version list) was wrong.
   What is left unexplained is `snapToVersions`' own `VersionSet` round trip per
   emitted dependency versus the solver working on differently-shaped ranges; the
   second would be inherent. Numbers, and the report-prose split narrowing also needs
   (`fromNarrowedDependency`), are in `docs/STATUS.md` ("Narrowing declared ranges").
   `PubGrub.VersionSet.snapToVersions` is kept, tested, and unused.
3. **Chain collapsing** — the spec fuses "depends on X *which depends on* Y" into
   one sentence; this is most of the remaining line-count gap.
4. Cosmetic: `So,` on the final line; terminal periods on non-final lines; omit
   the synthetic root's version; number only lines actually referenced.
5. **Collapse cells that exhaust a flag's states.** Real proof lines read
   `aeson >=1.2.2.0 && <1.4.2.0 -bytestring-builder or … +bytestring-builder or …
   (no bytestring-builder flag)` — three cells over one version range covering all
   three pin states, which denotes "any instance in that range" with the flag
   unconstrained. A `mergeCells` sibling: where cells share a version set and their
   pins for one flag exhaust `PinnedTo True`, `PinnedTo False` and `NotDeclared`, drop
   that flag from the pin map and merge. Not a report-layer fix, and it shortens the
   terms the solver carries as well as the ones it prints.

Do **not** chase byte-parity with pub's output: `^1.0.0` is Dart syntax and cabal
writes `>=1.0.0 && <2`. The target is the same sentences and information in
cabal's range syntax.

## Conventions

- GHC 9.12.x (`base ^>=4.21`), `cabal-version: 3.8`
- `default-language: GHC2021` on all four components, with
  `default-extensions: ImportQualifiedPost` (this said `Haskell2010` long after the
  tree moved to GHC2021)
- `-Wall` on all components; treat warnings as errors once the API stabilises
- No partial functions (`head`, `fromJust`, etc.) — use pattern matching or `Maybe`/`Either`
- Prefer `newtype` wrappers over type aliases for domain types (Package, Version, etc.)
