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
- **Flag semantics: `docs/flags-semantics.md`.** Same role for flags that
  `references/pubgrub.md` has for the algorithm: what must be *true*, with no
  types in it. Cite it for any question about what a constraint mentioning a flag
  means, what may be approximated, and in which direction. It overrules this file
  and `docs/attic/flags-design.md` (a pre-reboot design doc, superseded on
  semantics).
- **Decision semantics: `docs/decision-semantics.md`** (drafted 2026-08-04,
  **nothing implemented**). Specifies *condition decisions*: decide the version
  first, then only the flag conditions some dependency guards. It registers its
  deviations from `references/pubgrub.md` in its §1 and defers to
  `docs/flags-semantics.md` on flags. Its §11 proposes four amendments to that file
  which are **not applied**, and its §10 notes it subsumes the `expand`-split
  question.
- **Formal kernel model: `specification/`** — Lean 4. Its own README states the Lean
  code is normative where its prose disagrees.
- PubGrub internals guide: https://pubgrub-rs-guide.pages.dev/internals/intro
- Reference Rust implementation: https://github.com/pubgrub-rs/pubgrub (a second
  implementation's choices, not a specification)
- cabal's modular solver (baseline): the `cabal-install-solver` package, `Distribution.Solver.*`
- Local reference for driving cabal's solver: `../cabal-solver-plan`

## Build & test

```sh
cabal build
cabal test
cabal run pubgrub-hs
```

## Architecture

Three components with a hard dependency boundary — the cabal-install entanglement
is quarantined so the core stays lightweight:

```
pubgrub-hs (library) ──── deps: Cabal-syntax ONLY
  native PubGrub: Term, VersionSet, Incompatibility, Relation, Solver, Report
  pure algorithm + types; no cabal-install, no cabal-install-solver
        ▲  consumes a neutral problem type
pubgrub-bridge (executable) ──── deps: cabal-install-solver, Cabal, Cabal-syntax, tar
  our own minimal index reader (read cached 01-index.tar + parse .cabal)
  builds a cabal solver `Index` (convPIs) and feeds it to BOTH:
    ├─ cabal's Distribution.Solver.Modular.Solver.solve   (baseline)
    └─ a translation into pubgrub-hs's problem input
  NB: NO cabal-install, NO hackage-security (see boundary note below)
        ▲
harness — runs both solvers, diffs verdicts, renders explanations side by side,
  measures wall-clock + peak residency
```

Current layout (4 cabal components):

- `src/` — library. `PubGrub/{Term,VersionSet,SetOps,Relation,Incompatibility,Solver,Provider,Report,Pretty}.hs`,
  plus `Index/PreInstalled.hs` (the installed-unit model) and
  `InstanceSet{,/SourceCell}.hs` (the solver's set type).
- `bridge/` — private library `bridge`. `Bridge/{Hackage,Installed,Provider}.hs`
  plus `Bridge/Cabal/{Baseline,Flatten,InstalledPkg}.hs`: index reader, installed-db
  reader, the cabal-solver baseline, flag-parametric `GenericPackageDescription`
  flattening, and the real `Provider`. `Provider.releaseReader` memoises, per release, only the *reduced*
  form the provider needs (declared flags + flag-guarded deps) — never the parsed
  description. Retaining those instead cost 27.2s / 904MB on `pandoc` against
  3.7s / 83MB uncached: ~170 parse trees pinning their slices of the index is
  enough live data to make every major GC copy it.
- `app/Main.hs` — executable `pubgrub`: the CLI driver.
- `test/` — `{VersionSet,InstanceSet,Solver,Paper,Flatten,FlagSolve}Spec.hs`.

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

- **Rung 0** — ✅ plumbing: own index reader running on real Hackage data. (No cabal baseline — see the caveat below.)
- **Rung 1** — ✅ version ranges. Solver resolves real Hackage packages end to end.
- **Rung 2** — ✅ flags + conditional deps, as a search dimension. A decision is an
  *instance* (version × total flag assignment); `Bridge.Cabal.Flatten` flattens the
  conditional tree to flag-guarded groups and evaluates them at exactly the decided
  assignment; the provider tries the all-default assignment of a release first and
  considers deviations only once the accumulated constraint excludes it, fewest
  deviations first. Semantics: `docs/flags-semantics.md`, with a worked trace in
  its §9. Known cost, not yet paid down: a version rejected for a
  flag-irrelevant reason is re-offered once per irrelevant assignment (2^k), which
  is what depender-range collapsing fixes — see Reporting gap 1 below.
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

**Caveat on "measure both deliverables at each rung".** We have not been doing
this, because neither deliverable has a harness yet. Rungs 0–3 are done but
unmeasured. The two workstreams below are what actually gate the deliverables,
and they are not rungs:

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

   We emit the per-version form the spec tells us not to: `Bridge.Provider.depIncs`
   uses `singletonInstance chosen` as the depender
   (`bridge/Bridge/Provider.hs:332`). ("No instances" is not affected — the solver
   raises that itself from the provider's `Nothing`, `src/PubGrub/Solver.hs:416`.)
   This costs *both* deliverables — more incompatibilities to propagate, and proof
   lines reading `foo 1.2.3 depends on …` where the spec's own examples read
   `foo >=1.0 && <1.3 depends on …`. `mergeCells` recovers some of it incidentally,
   but only after unions during derivation, never at generation time, which is
   where the spec puts it.

   With flags in the value it is also the fix for a *performance* bug, not only a
   wording one: because the depender is one instance, refuting a version teaches
   the solver nothing about that version under a different assignment, so a
   version rejected for a flag-irrelevant reason is re-offered once per irrelevant
   flag assignment — 2^k. `test/FlagSolveSpec.hs` records the k=1 case (three
   expansions of a package with one dead version), and
   `docs/flags-semantics.md` §9 traces it.

   Fix at generation, and the shape is fixed by `docs/flags-semantics.md` §4.2,
   which overrules this file: the unit is **one guarded dependency occurrence**
   `C ⇒ q ∈ R`, read straight off the flattened conditional tree. Emit
   `{p ∈ V × C, not q ∈ R}` with the guard `C` used **verbatim** as the depender's
   flag component. That is what keeps flags the guard never mentions out of the
   term, which is the entire point — and it needs no enumeration of assignments and
   no per-assignment dependency sets. Where several occurrences constrain the same
   `q` (an unconditional `q >=1`, a guarded `q <3`), emit them as separate facts and
   let propagation intersect them.

   **Do not group instances by identical flattened dependency *set*.** §4.2 rejects
   that explicitly, as "a serious mistake, not a conservative one": two assignments
   that agree on `q` but differ on an unrelated dependency fail to group, so the
   depender term still names the irrelevant flag and the 2^k cost survives intact.
   (This file prescribed the rejected form until 2026-08-05.)

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

   What still requires reads is widening across *distinct* releases — that needs to
   know they share the dependency, and whether each declares the guard's flag at all,
   since where it does not the guard is not merely false but *inapplicable*, which is
   the third pin state's job. Slots make it cheaper, not harder: two adjacent slots
   already union into a contiguous range, so only dependency-identity is left. See
   also `docs/decision-semantics.md`, which builds on this emission shape and treats
   it as its prerequisite.
2. **`collapseNoInstances`** — intensional ranges mean the solver must separately
   learn that a range's *holes* are empty, so `no version for bar in >2.0.0 && <3`
   leaves clutter the proof. pubgrub-rs has a dedicated post-pass for exactly
   this: `DerivationTree::collapse_no_versions` (`references/pubgrub/src/report.rs:102`,
   with the merge rule at `:132`). Absorb the range into the sibling cause's term
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

- GHC 9.x, `cabal-version: 3.8`
- `default-language: Haskell2010` (upgrade to GHC2021 when adding extensions)
- `-Wall` on all components; treat warnings as errors once the API stabilises
- No partial functions (`head`, `fromJust`, etc.) — use pattern matching or `Maybe`/`Either`
- Prefer `newtype` wrappers over type aliases for domain types (Package, Version, etc.)
