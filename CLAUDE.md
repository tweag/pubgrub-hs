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

- PubGrub algorithm spec: https://github.com/dart-lang/pub/blob/master/doc/solver.md
- PubGrub internals guide: https://pubgrub-rs-guide.pages.dev/internals/intro
- Reference Rust implementation: https://github.com/pubgrub-rs/pubgrub
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

Current core modules: `src/PubGrub/{Term,VersionSet,Relation,Incompatibility,Solver,Report,Package,Pretty}.hs`.

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

- **Rung 0** — plumbing only: `pubgrub-bridge` + own index reader + cabal baseline running on real Hackage data; define the neutral problem type. No pubgrub solving yet.
- **Rung 1** — version ranges only (flags collapsed to a fixed assignment). First head-to-head + first showcase + first benchmark.
- **Rung 2** — flags + conditional deps. Most important rung for the explanations question.
- **Rung 3** — `base`/GHC pinning (installed-package index → `PreInstalled` instances).
- **Rung 4** — setup / build-tool deps (see reference's `SetupDeps.hs`).
- **Rung 5** — public sublibraries.

## Conventions

- GHC 9.x, `cabal-version: 3.8`
- `default-language: Haskell2010` (upgrade to GHC2021 when adding extensions)
- `-Wall` on all components; treat warnings as errors once the API stabilises
- No partial functions (`head`, `fromJust`, etc.) — use pattern matching or `Maybe`/`Either`
- Prefer `newtype` wrappers over type aliases for domain types (Package, Version, etc.)
