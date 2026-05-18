# pubgrub-hs

A Haskell implementation of the PubGrub dependency version solver, using Answer Set Solving (ASP) via the Potassco toolchain.

## Project goal

Implement the PubGrub algorithm for resolving Haskell package dependencies. The solver translates dependency constraints into ASP encodings and uses Clingo (or a Haskell ASP binding) to find consistent version assignments.

## Key references

- PubGrub algorithm spec: https://github.com/dart-lang/pub/blob/master/doc/solver.md
- PubGrub internals guide: https://pubgrub-rs-guide.pages.dev/internals/intro
- Reference Rust implementation: https://github.com/pubgrub-rs/pubgrub
- Potassco ASP book: https://potassco.org/book/
- Potassco teaching material: https://teaching.potassco.org
- ASP survey paper: https://www.sciencedirect.com/science/article/pii/S0004370212000409

## Build & test

```sh
cabal build
cabal test
cabal run pubgrub-hs
```

## Architecture (intended)

- `src/PubGrub/Types.hs` — core types: Package, Version, VersionRange, Term, Incompatibility, PartialSolution
- `src/PubGrub/Solver.hs` — main solving loop (unit propagation, conflict resolution, decision making)
- `src/PubGrub/ASP.hs` — encoding/decoding between PubGrub terms and ASP facts/rules
- `src/PubGrub/VersionSet.hs` — version range arithmetic (union, intersection, complement)
- `app/Main.hs` — CLI entry point

## Conventions

- GHC 9.x, `cabal-version: 3.8`
- `default-language: Haskell2010` (upgrade to GHC2021 when adding extensions)
- `-Wall` on all components; treat warnings as errors once the API stabilises
- No partial functions (`head`, `fromJust`, etc.) — use pattern matching or `Maybe`/`Either`
- Prefer `newtype` wrappers over type aliases for domain types (Package, Version, etc.)
