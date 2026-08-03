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
  and `docs/flags-design.md` (a pre-reboot design doc, superseded on semantics).
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
  plus `Bridge/Cabal/{Flatten,InstalledPkg}.hs`: index reader, installed-db
  reader, flag-parametric `GenericPackageDescription` flattening, and the real
  `Provider`.
- `app/Main.hs` — executable `pubgrub`: the CLI driver.
- `test/` — `{VersionSet,InstanceSet,Solver,Paper,Flatten,FlagSolve}Spec.hs`.

Note the diagram above still describes the *intended* end state. The cabal
baseline and the harness do not exist yet: nothing in the tree depends on
`cabal-install-solver`, and the driver runs only our solver.

**Dependency boundary note.** The `../cabal-solver-plan` reference depends on
`cabal-install`, but only for *index acquisition* (`IndexUtils`, `RepoContext`,
hackage-security) plus some CLI-convenience types. We avoid `cabal-install` and
`hackage-security` entirely by writing our own minimal index reader (`tar` +
`Cabal-syntax`'s `parseGenericPackageDescription`), taking care to handle
**.cabal revisions (last wins)** and **`preferred-versions`**. The single shared
index reader feeds both solvers, making the apples-to-apples comparison structural.

## Roadmap — rung-by-rung fidelity ladder

Build the full end-to-end loop early, then add cabal-model fidelity one rung at a
time; each rung leaves a runnable solver and we measure both deliverables at each.

- **Rung 0** — ✅ plumbing: own index reader running on real Hackage data. (No cabal baseline — see the caveat below.)
- **Rung 1** — ✅ version ranges. Solver resolves real Hackage packages end to end.
- **Rung 2** — ✅ flags + conditional deps, as a search dimension. A decision is an
  *instance* (version × total flag assignment); `Bridge.Cabal.Flatten` flattens the
  conditional tree to flag-guarded groups and evaluates them at exactly the decided
  assignment; a flag leaves its default only when conflict resolution forbids the
  instance that used it. Semantics: `docs/flags-semantics.md`, with a worked trace
  in its §9. Known cost, not yet paid down: a version rejected for a
  flag-irrelevant reason is re-offered once per irrelevant assignment (2^k), which
  is what depender-range collapsing fixes — see Reporting gap 1 below.
- **Rung 3** — ✅ `base`/GHC pinning (installed db → `PreInstalled` instances, strict prefer-installed).
- **Rung 4** — setup / build-tool deps (see reference's `SetupDeps.hs`).
- **Rung 5** — public sublibraries.

**Caveat on "measure both deliverables at each rung".** We have not been doing
this, because neither deliverable has a harness yet. Rungs 0–3 are done but
unmeasured. The two workstreams below are what actually gate the deliverables,
and they are not rungs:

- **Explanations** — cause tracking is reinstated (`IncompatCause`) and
  `PubGrub.Report` renders a numbered proof. Next: `collapseNoInstances`, then
  the spec's human-friendly wording. See "Reporting" below.
- **Benchmark** — nothing exists. Needs `cabal-install-solver` wired in as a
  baseline, both solvers driven from the one index, and time + peak residency
  measured. This is the larger of the two and has not been started.

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
- `pruneCells` sorting also fixes the DNF's order (widest cell first, via the
  `Ord` on `VersionSet`), which is what makes candidate selection in
  `Bridge.Provider` deterministic — and, since a wider cell carries fewer pins,
  makes it try assignments closest to the declared defaults first.
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

Known gaps, in the order worth fixing:

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
   (`bridge/Bridge/Provider.hs:225`). ("No instances" is not affected — the solver
   raises that itself from the provider's `Nothing`, `src/PubGrub/Solver.hs:317`.)
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

   Fix at generation: group a package's instances by identical flattened
   dependency set, emit one incompatibility per group, with the depender widened
   to a cell spanning the group. Note the flag axis complicates "adjacent" — two
   instances of the *same* version under different flag assignments can have
   different deps — so the grouping key is the dep set, and the widened cell must
   retain whatever pins the whole group shares.
2. **`collapseNoInstances`** — intensional ranges mean the solver must separately
   learn that a range's *holes* are empty, so `no version for bar in >2.0.0 && <3`
   leaves clutter the proof. pubgrub-rs has a dedicated post-pass for exactly
   this: `DerivationTree::collapse_no_versions` (`references/pubgrub/src/report.rs:102`,
   with the merge rule at `:132`). Absorb the range into the sibling cause's term
   by union and drop the node.
3. **Chain collapsing** — the spec fuses "depends on X *which depends on* Y" into
   one sentence; this is most of the remaining line-count gap.
4. Cosmetic: `So,` on the final line; terminal periods on non-final lines; omit
   the synthetic root's version; number only lines actually referenced.

Do **not** chase byte-parity with pub's output: `^1.0.0` is Dart syntax and cabal
writes `>=1.0.0 && <2`. The target is the same sentences and information in
cabal's range syntax.

## Conventions

- GHC 9.x, `cabal-version: 3.8`
- `default-language: Haskell2010` (upgrade to GHC2021 when adding extensions)
- `-Wall` on all components; treat warnings as errors once the API stabilises
- No partial functions (`head`, `fromJust`, etc.) — use pattern matching or `Maybe`/`Either`
- Prefer `newtype` wrappers over type aliases for domain types (Package, Version, etc.)
