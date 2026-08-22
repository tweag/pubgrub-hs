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
cabal test                      # 165 tests, ~0.3 s
cabal run pubgrub -- aeson      # the driver; add -v for the search trace
cabal run pubgrub -- --cabal aeson   # cabal's solver, same index (the baseline)
cabal run pubgrub-index         # build the derived index (~200 s, once)
scripts/gate.sh                 # every check that must not regress; see below
bench/compare.sh                # both solvers over bench/problems.txt
```

**`scripts/gate.sh` is what decides whether a change is kept.** Nine gates over one
pass of the problem set: the 17-case failure corpus, ours-vs-cabal verdict agreement
over all 22 problems, proof length against cabal's own message, the proof and
no-version totals, the golden proofs, the pkg-config modelling tests, the whole suite
and the Lean build. One line per gate, non-zero exit on any regression. Its three
numeric baselines are ceilings and floors, not targets — beating one prints
`IMPROVED` and still exits 0, and the rule is to tighten it in the change that earned
it. They are currently tight (62 proof sentences, 1 no-version line), so a reporting
change has to earn its way past them.

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
  `PubGrub/{Term,VersionSet,SetOps,Relation,Incompatibility,Solver,Store,Provider,Report,Pretty}.hs`,
  `Index/PreInstalled.hs` (the installed-unit model) and
  `InstanceSet{,/SourceCell}.hs` (the solver's set type). `Store` is the
  incompatibility store: clauses in scan order, with dependency facts about one
  (depender, dependee) pair and an identical dependee term **merged as they arrive**,
  which is where `references/pubgrub.md:456`'s collapsing happens (see Reporting gap 1).
  Unbuildable facts about one package merge the same way, which is `:476`'s half of it.
- `bridge/` — private library `bridge`. `Bridge/{Hackage,Installed,Provider}.hs`,
  `Bridge/Hackage/{HttpClient,Store,Unlifted}.hs`, and
  `Bridge/Cabal/{Baseline,Flatten,InstalledPkg}.hs`: index reader, installed-db
  reader, the cabal-solver baseline, flag-parametric `GenericPackageDescription`
  flattening, and the real `Provider`. `Flatten` reads two things off the same walk of
  a conditional tree (`flattenWith`): the `build-depends`, and the `BuildInfo` that
  decides buildability (`buildable:` plus `pkgconfig-depends` against the machine's
  `PkgConfigDb`, library only). `Provider.releaseReader` memoises, per release, only the *reduced*
  form the provider needs (declared flags + guarded deps + a buildable flag) — never the parsed
  description. Retaining those instead cost 27.2s / 904MB on `pandoc` against
  3.7s / 83MB uncached: ~170 parse trees pinning their slices of the index is
  enough live data to make every major GC copy it.
  **`Bridge/Hackage/Store.hs` is the derived index** (landed 2026-08-23): every
  release's `.cabal` parsed once, ahead of time, into the *pre-environment* form, so a
  read is a CBOR decode. See "The derived index" below — it is the thing that changed
  what the rest of this file used to say about the cost of reading a release.
- `app/Main.hs` — executable `pubgrub`: the CLI driver. `app/BuildIndex.hs` —
  executable `pubgrub-index`, which builds the derived index.
- `prototype/IndexBench.hs` — executable `index-bench`, **throwaway**: it priced the
  derived index (bytes per entry under `binary` vs `serialise`, and the parse:flatten
  split) so the design could be decided on numbers. Delete it and its stanza once
  nothing else needs re-pricing.
- `scripts/gate.sh` — the one gate command (see "Build & test").
- `test/` — `{VersionSet,InstanceSet,PartialSolution,Solver,Store,Stored,Paper,Report,Flatten,FlagSolve,Installed}Spec.hs`,
  plus `test/golden/` — the expected proofs for `PaperSpec`'s two error-reporting cases.

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
package→versions map, and reads one release's `.cabal` through `indexLookupCabal` +
`Cabal-syntax`'s `parseGenericPackageDescription` — on demand, and now only when the
derived index misses. (An earlier
version of this note claimed we avoid `hackage-security` too and read the tar
directly with `tar`; we do not, and there is no `tar` dependency.) Still to handle:
**`preferred-versions`**. **.cabal revisions** need no work — the index
`hackage-security` hands us already carries only the last revision of each release,
verified 2026-08-12 (152,746 entries, 152,746 distinct; 152,987 as of 2026-08-23,
across 19,419 packages). The single shared index reader feeds both solvers, making the
apples-to-apples comparison structural.

**We are not as lazy as this file used to imply, and it matters.** The `.cabal`
*bodies* are read lazily; the package→versions map is **eager and complete** — all
152,987 releases, deserialised whole at startup on every run, which is most of the
22.9 MB residency floor a trivial solve pays. Dart's pub, by contrast, has no global
index at all: it fetches one package's version listing on demand and that listing
carries every version's manifest. So the two designs are opposite — pub is lazy across
packages and eager within one, we are eager across packages and lazy within one — and
neither is simply "lazier". Any claim about our memory advantage over cabal has to
account for that floor, which is why `docs/STATUS.md` now lists establishing what the
22 MB consists of as the first thing to settle.

## The derived index

**Reading a release is a CBOR decode, not a parse** (landed 2026-08-23,
`Bridge.Hackage.Store`). `cabal run pubgrub-index` parses all 152,987 releases once —
201 s — and writes `_cache/derived-index.cbor` (62.5 MB) plus a 0.4 MB package-keyed
offset map. `Bridge.Provider` consults it first and falls back to parsing on any miss.

Four things to know before touching it:

- **It is a cache, not a source of truth.** `openStore` answers `Nothing` for a
  missing, unreadable or stale-format store, and every miss parses instead. Deleting
  `_cache/derived-index.*` costs speed and never correctness. Bump
  `storeFormatVersion` on any encoding change — a generic CBOR encoding is positional,
  so reordering a constructor silently changes meaning.
- **What is stored is the *pre-environment* form, not the flattened one.** This is the
  whole design. `Flatten.envConfVar` resolves `os`/`arch`/`impl` against this machine
  and buildability additionally resolves `pkgconfig-depends` against its `pkg-config`
  db, so a flattened store would be silently wrong after a GHC upgrade or an
  `apt install`. Parsing is **106× the cost of flattening** (2.007 ms against
  0.019 ms, measured), so caching only the parse gives up almost nothing and keeps one
  store valid across toolchains. `componentDepsAtDefaultsStored` and
  `buildableAtDefaultsStored` run the *same* `flattenWith` over the *same* trees as
  their description-taking counterparts, so the two paths agree by construction;
  `test/StoredSpec.hs` asserts it anyway, on nine `.cabal` shapes and through a
  `serialise` round-trip.
- **CBOR, not `binary`** — 410 B/release against 1040, so 62.5 MB against 159. `binary`
  decodes 2.5× faster, but at 27× cheaper than parsing decode stopped being the scarce
  resource and size did not.
- **Granularity is the package, not the release**, which is what pub does and for the
  same reason: one slice holds every version, so walking a release's neighbours touches
  data already decoded. The decoded-slice cache holds **one** package, because
  `releaseReader` already memoises the `Release` per `(package, version)`; an unbounded
  one cost `pandoc` 39.6 MB of peak residency against 26.7.

**It does not make a solve faster on its own.** Parsing was 0.3–0.6 s of runs taking
0.7–6.8 s, and measured before the walk returned, elapsed time was unchanged within
noise. Its entire value is that it changed the price of a *neighbour* read — which is
what made generation-time collapsing affordable again (Reporting gap 1).

## Roadmap — rung-by-rung fidelity ladder

Build the full end-to-end loop early, then add cabal-model fidelity one rung at a
time; each rung leaves a runnable solver and we measure both deliverables at each.

- **Rung 0** — ✅ plumbing: index reading running on real Hackage data.
- **Rung 1** — ✅ version ranges. Solver resolves real Hackage packages end to end.
- **Rung 2** — ✅ flags + conditional deps, **applied but not searched since
  2026-08-17.** `Bridge.Cabal.Flatten.componentDepsAtDefaults` resolves flag
  conditions at flatten time against the release's declared defaults, so every guard
  folds to a literal and no flag reaches the solver; `Bridge.Hackage.lookupGPD` marks
  every flag manual so cabal's `enforceManualFlags` pins it to the same value. One
  instance per release, on both sides. Read
  [`docs/STATUS.md`](docs/STATUS.md)'s "Release-1 scope" before touching this — the
  search machinery (three-state pins, `expandGuard`, `preferDefaults`, the symbolic
  `componentDeps`) is intact and unfed, and `docs/flags-semantics.md` is unchanged as
  a specification. Consequence to know: the 2^k re-offer that motivates half of
  Reporting gap 1 below **is currently zero**, and returns with the flag axis.
- **Rung 3** — ✅ `base`/GHC pinning (installed db → `PreInstalled` instances), and
  **only**-installed rather than merely *prefer*-installed for boot packages. The
  distinction was found on 2026-08-12 by the baseline: strict prefer-installed says
  what to do when an installed unit is admissible and nothing about the case where a
  constraint *excludes* it, and we fell through to a source release — `aeson <2`
  resolved by planning to build `base 4.15.1.0` from Hackage. cabal forbids that, and
  `Bridge.Installed.nonReinstallablePackages` is now the single list both solvers read
  (`base`, `ghc-bignum`, `ghc-internal`, `ghc-prim`, `ghc`, `integer-gmp`,
  `integer-simple`, `template-haskell`): the baseline as constraints, our provider as
  a rule in `expand'`. All five benchmark verdicts agree.
- **Buildability** (not a rung; landed 2026-08-17) — a release whose library cannot be
  built here is not offered: `buildable: False`, and `pkgconfig-depends` against the
  machine's real `pkg-config` db, which `withWorld` reads once and hands to *both*
  solvers. `buildableCondition` returns a `Condition FlagName` and
  `buildableAtDefaults` evaluates it, so the flag axis can come back and *satisfy* the
  condition rather than redo the analysis. **Stated as an incompatibility since
  2026-08-20** (`references/pubgrub.md:476`): the provider's scan emits
  `unbuildable p slot` for each release it passes over and hands those out with
  whichever release it settles on, `PubGrub.Store` unions adjacent slots into the
  contiguous run the spec asks for, and a proof line reads `foo >=2.0.0 cannot be
  built here` instead of leaving the solver to report the range as empty. Two things
  to know: the *exhausted* case — every release in range unbuildable — still loses the
  facts, because with no instance to return there is nowhere to put them without
  changing what `expand` returns; and **none of the five benchmark problems meets an
  unbuildable release at all**, so the whole path is exercised only by
  `test/FlagSolveSpec.hs` and `test/StoreSpec.hs`, never by a measurement.
- **Rung 4** — setup / build-tool deps (see reference's `SetupDeps.hs`). Note what
  cabal does here that we have no model for at all: it solves **qualified goals**, so
  each executable and setup dependency gets its **own domain**. `Setup.hs` is an
  executable that is never linked against the library, so it may be built against a
  different `mtl` than the library uses, and cabal's plan can legitimately contain two
  versions of one package. Our decisions are per package name, full stop — one version
  of `mtl` per solve. This has to be specified before rung 4 is built; the immediate
  job is to understand what cabal actually emits (its plan loses the qualifiers to
  `convCP` on the way out, so reading a flat plan will mislead).

  **Qualified goals were designed 2026-08-21 and shelved, and the reason matters.** We
  reached for them to fix a self-dependency bug and they do not fix it: `qualifyDeps`'s
  `inheritedQ` gives a **library** dependency its depender's qualifier — only
  `setup-depends` and `build-tool-depends` override it — so an executable's dependency
  on its own library is `qpn == qpn'` under any qualifier scheme. The scope also belongs
  on the **variable**, not the instance: cabal qualifies `QPN` (the goal) and leaves `I`
  unqualified, a release of `mtl` is the same release in either scope, and putting it in
  `Instance` would give `InstanceSet` a third coordinate whose intersection is only ever
  equal-or-empty. So `incompTerms` becomes `Map QPN (Term InstanceSet)` and the partial
  solution follows — it cannot live in the partial solution alone, since the whole point
  is two versions of one name decided at once. Copy `Qualifier` from
  `Distribution.Solver.Types.PackagePath`, dropping `Namespace` (`--independent-goals`
  only) and `QualBase` (`qoBaseShim` is False unless an *installed* `base` depends on
  `base`). **Override-rather-than-nest is load-bearing, not a simplification** — cabal
  limits itself to one qualifier because nesting "very quickly leads to infinite search
  trees". The bulk of the work comes first and touches no solver code:
  `Bridge.Cabal.Flatten.componentDeps` merges library, sublibs and executables into one
  `GuardedDeps` and discards which component each occurrence came from, which is exactly
  the label qualification needs — and it reads neither `setup-depends` nor
  `build-tool-depends` at all.

  **This rung owes the setup self-dependency case.** `Bridge.Provider` drops a
  dependency of `p` on `p` (see below); cabal's `Builder.extendOpen` makes one
  exception, adding a reverse-dependency edge for a *setup* self-dependency so the
  cycle forces a different setup script. There are no setup deps yet, so there is
  nothing to keep an edge for — when they arrive, the exception comes with them.
- **Rung 5** — public sublibraries.

**Intra-package dependencies** (not a rung; landed 2026-08-21) — a dependency of `p` on
`p` is **not emitted**. Real packages declare them constantly, because an executable or
sublibrary of `p` is built against `p`'s library; it is an intra-package edge resolved
inside the package, not a version constraint on `p`. Stated as a fact it says something
far stronger and false, and it did: `Map.fromList` keeps the last binding for a
duplicate key, so with depender and dependee equal the `Positive` depender term was
dropped and `lens 1.7`'s `lens ==1.7` became the unconditional `{lens: Negative ==1.7}`
— "lens must be exactly 1.7", asserted of *every* instance — which pinned a whole solve
and became the unexplained first premise of its proof. `fromDependency` now uses
`Map.fromListWith intersectTerm`, so two entries about one variable are intersected
rather than overwritten (`Positive (V \ R)`, the honest clause), and `Bridge.Provider`
filters the occurrence out so no such clause is minted at all. **Both are needed**: the
constructor fix alone makes the clause honest, and an honest clause correctly *bans* the
release — because its self-dependency genuinely cannot be met — which is still the wrong
answer. The rule is **cabal's**, not a shortcut: `Builder.extendOpen` on `qpn == qpn'`
adds no goal and no edge, and `not $ isInternal pkg exeDep` in `IndexConversion` does
the same for build-tools; `Bridge.Installed.closureEdges` had always done it on the
installed side, and only the source path let one through. Tests: `StoreSpec`
"self-dependencies" and `FlagSolveSpec` "self-dependencies", each verified to fail
without its own half. Consequence to know: `lens <4`'s proof stopped opening on the bogus
`lens ==1.7 is required` and now ends on `root ==0 depends on lens <4`, so it answers the
question that was asked. Four lines answering the wrong question were not a win. (The
counts recorded here at the time — decisions 317 → 225, reads 178 → 274, proof 4 → 7 —
have all been overtaken since; `lens <4` is currently 60 decisions, 0 parses and an
8-line proof against cabal's 22. Current figures for all five are `docs/STATUS.md`,
"A derived index".)

**Caveat on "measure both deliverables at each rung".** We did not do this for
rungs 0–3, which were built unmeasured; measurement only started 2026-08-12, once the
baseline existed, and it immediately found rung 3 incomplete (fixed above) — which is
the argument for the discipline rather than against it. They are measured now:
current figures are `docs/STATUS.md`, **"A derived index, and collapsing at generation
time again"** (2026-08-23, five problems, both solvers). **Quote that section, not the
dated ones above it** — each of those is against the tree of its own date, and most
were taken when reading a release meant parsing its `.cabal`. There is still no
harness, though `scripts/gate.sh` now does its regression half. The two
workstreams below are what actually gate the deliverables, and they are not rungs:

- **Explanations** — cause tracking is reinstated (`IncompatCause`) and
  `PubGrub.Report` renders a numbered proof. Every reporting gap but the cosmetics
  (gap 4) is now closed, and we are shorter than cabal on all 17 harvested problems.
  See "Reporting" below.
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

**Only the degenerate case runs today.** Since 2026-08-17 no pin is ever created —
guards fold to literals, so every cell has an empty pin map and the DNF is a list of
plain ranges. The flag machinery below is therefore *unexercised by the real bridge
and still fully exercised by the tests*: `test/InstanceSetSpec.hs` for the algebra,
and `test/FlagSolveSpec.hs` for the provider rule, which feeds `mkExpand` hand-built
releases whose guards are real `Condition`s. That is the only reason it is safe to
leave in. Do not simplify it away on the evidence of a trace; read "Release-1 scope"
in `docs/STATUS.md` first.

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

**Status, 2026-08-23: gaps 1, 2 and 3 are closed and gap 5 is dormant; gap 4 (the
cosmetics) is the only one open.** On the harvested corpus we are shorter than cabal
on all 17, 62 proof sentences against its 152, with one `no version` line left in the
whole set. `scripts/gate.sh` holds both totals as ceilings. What follows is the list
as it was worked, kept because each entry records why the fix is shaped the way it is
— read the dated notes inside each one, not the ordering.

Known gaps, in the order they were worth fixing. **The order was evidence-backed**
(2026-08-12, first side-by-side against cabal): our proof for `lens <4` is 9 lines against cabal's
22, but `conduit <1.3` is **1061** against 16 and `aeson <2` is **2833** against 30.
Gap 1's version axis is most of that — whole runs of proof lines do nothing but merge
adjacent releases pairwise at derivation time, which is the collapsing
`references/pubgrub.md:456` asks for at generation time — followed by unsimplified flag
cells (see 5 below) and then chain collapsing. See `docs/STATUS.md`, "The explanation
deliverable is currently losing".

**Those line counts are historical, several times over.** With gap 1 done and the
boot-package rule stated once rather than per range (2026-08-17) they became `lens
<4` 6 lines, `conduit <1.3` 12 and `aeson <2` 83; gap 3 landed 2026-08-20 and made
them 4, 6 and 56. **As of 2026-08-23** — the walk restored, and a run of same-pair
steps stated once — they are `lens <4` **8** lines against cabal's 22,
`conduit <1.3` **10** against 16, and `aeson <2` **64** against 30. Two clear wins and
one outlier, still. (`lens` and `conduit` went *up* slightly because widening surfaces
a different conflict, and `aeson` fell from 178 by the same change.) Those three are a
poor sample, though: on the 17 harvested problems
([`docs/failure-cases.md`](docs/failure-cases.md)) **we are shorter on all 17**, 62
proof sentences against cabal's 152. Nothing else moved: the change is pure rendering, so reads, allocation,
residency and decision counts are identical either side of it.

**Gap 2 is now the top item, and it is no longer only about clutter.** Pinning the
spec's own two worked examples as tests (`test/PaperSpec.hs`) showed that the
`no version for …` siblings are what *prevent* gap 3's chain fusion from firing: each
dependency fact is paired with a hole-is-empty fact instead of with the next
dependency fact, so "depends on X which depends on Y" never gets the chance to form.
On the spec's linear example that is the whole difference between our three lines and
its published two. Absorbing the siblings does two things at once.

Gap 5's symptom is also gone for now: a proof with no pinned cells cannot print one,
and no cell is pinned while flags are fixed at their defaults.

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
   expansions where it was 3 with one irrelevant flag, 5 with two). **Since
   2026-08-17 it cannot arise at all**: with one assignment per release, k is 0 and
   there is nothing to re-offer.

   **What survives, and it is no longer 2^k in the declared flags.** Three costs
   remain, all because a decision is still a *point instance* — see
   `docs/decision-semantics.md` §0: whole-instance backjumps re-offer a version the
   conflict never questioned; the provider re-derives outside the store what
   guard-shaped terms would narrow inside it; and decisions still name inert flags in
   every trace. The residue is bounded by the number of **guard regions** (cells over
   the flags guards actually mention), not by 2^k over every declared flag. Do not
   call it "the 2^k blow-up" — that name now overstates it. While flags are fixed at
   their defaults there are no guard regions and the residue is zero; it returns with
   the flag axis.

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

   **Both mechanisms are live, and the history is worth knowing because this file got
   it wrong twice.** Doing it at generation time means the provider walking out from
   the decided release and reading its neighbours to learn what they declare
   (`Bridge.Provider.spanningOccurrence`). That was built 2026-08-12, **deleted
   2026-08-17**, and **restored 2026-08-23**.

   It was deleted because a neighbour read meant a `.cabal` parse — 2.0 ms and ~7.7 MB
   each — so it cost `pandoc`, a problem with one conflict, 167 reads → 2834,
   22.9 → 81.0 MB of residency and 17.31 GB of allocation, to widen clauses no search
   ever contested. What replaced it: the provider emits one fact per release **slot**,
   and `PubGrub.Store` unions the depender terms of two facts that agree about the
   dependee **as they arrive**. Slots touch, so the union is one contiguous interval
   and nothing is read to discover it.

   It was restored because **the derived index changed the price of the thing it was
   deleted for**. `pandoc` still does 167 → 2873 lookups, but they are decodes:
   **+0.17 s and +6% allocation, against 17.31 GB before.** Both mechanisms now run —
   the walk widens up front, the store still merges what arrives.

   **What that bought, and it is the largest search win the project has recorded.**
   One conflict now eliminates a *run* of releases rather than one at a time:

   | | before | after |
   |---|---|---|
   | `futhark ==0.27.1` decisions | 4287 | **805** |
   | `futhark` conflicts | 53 | **8** |
   | `futhark` elapsed | 6.62 s | **2.19 s** |
   | `aeson <2` decisions | 758 | **309** |
   | `conduit <1.3` decisions | 137 | **16** |

   That last pair is the debt the merge-on-insert change knowingly took on — its own
   note said "a change that makes re-expansion expensive again should look at this
   first" — being paid back.

   Two things to carry forward. The rule is **weaker than the spec's** in one
   direction and not the other: the walk establishes the run by *reading* every
   release in it, so the span is real, but a release the walk stopped at is still
   only bounded by what was read. And **`pandoc` is the row that got worse** —
   1.18 → 1.39 s, 22.6 → 33.2 MB — because with one conflict the walk buys it nothing
   and it pays for the neighbours anyway. If read-dominated problems ever matter more
   than search, that is the row to attack, and the lever is walking *less*, not
   reading more cheaply. The full account of the five options, including the two
   rejected store shapes, is in [`docs/collapsing.md`](docs/collapsing.md).

   On the **version** axis, the free half landed 2026-08-12: the depender's version
   component is a release's **slot** — `halfOpenVersionSet v next`, reaching up to
   the next release *present in the index* — instead of the single version
   (`Bridge.Provider.withSlots`). This costs no `.cabal` read (the package→versions
   map is already resident) and asserts nothing
   about an unread release, since a slot holds exactly one real release. The point is
   that adjacent slots **touch**, so `unionVersionSet` coalesces them and
   `difference` stops manufacturing empty between-releases holes. Measured on
   `aeson <2`: reads 350 → 250, no-version events 6 → 0, and the gappy eleven-way
   conflict term became one contiguous interval (`docs/STATUS.md`, "Second pass").

   Widening across *distinct* releases — the part that required reads — landed on top
   of slots later the same day, as the `spanningOccurrence` walk described above; it
   went away with the walk on 2026-08-17 and came back with it on 2026-08-23. Slots
   made it cheaper, not harder: two adjacent slots already
   union into a contiguous range, so only dependency-identity was left to establish,
   and that was the read. Note the third pin state turned out **not** to be needed on
   that path: requiring the guard to be *identical* means every release in the span
   declares the flags the guard mentions, since one that did not could not have
   produced that guard (`docs/collapsing.md` §1). While flags are fixed at their
   defaults it does not arise from the other direction either — guards are literals,
   so there is no flag to be inapplicable and only dependency-identity is compared;
   the question comes back with the flag axis. See also
   `docs/decision-semantics.md`, which builds on this emission shape and treated it
   as its prerequisite — now paid.
2. **`collapseNoInstances` — done, 2026-08-20.** Intensional ranges mean the solver
   must separately learn that a range's *holes* are empty, so
   `no version for bar in >2.0.0 && <3` used to clutter the proof. pubgrub-rs has a
   dedicated post-pass for exactly this:
   `DerivationTree::collapse_no_versions` (`references/pubgrub/src/report.rs:102`
   at rev `4dbe916`), with the merge rule in `merge_no_versions` (`:133` — this said
   `:132`, which is a blank line). Absorb the range into the sibling cause's term
   and drop the node — `PubGrub.Report.collapseNoInstances`.

   **The pass recomputes nothing, and that is the soundness argument.** Resolving a
   unit clause `{p ∈ r}` against a dependency fact on the pivot `p` unions the two
   terms about `p` and leaves the other side alone, so the step's conclusion *already
   is* that dependency with `p`'s term adjusted. The node therefore keeps its terms
   exactly and is re-labelled as the leaf it is equivalent to; nothing in the proof
   gets wider or narrower. `test/ReportSpec.hs` asserts that property directly,
   because a rendered proof cannot show it.

   Three cases are left alone deliberately, and the middle one is the one to know:
   two holes as both causes (nothing to absorb into); a dependee range that is
   *wholly* empty, where the union over the pivot is ⊤ so the dependee entry drops out
   of the resolvent and rebuilding would produce a dependency fact with no dependee
   range in it — `pair` renders that as "depends on …, which has no versions" instead,
   which keeps the range; and a *derived* sibling, where dropping the hole would print
   a conclusion wider than the two named causes justify (pubgrub-rs leaves that one
   too, with a `TODO`).

   Measured: on the harvested corpus the `no version for` lines went 30 → 22 and four
   proofs with them (`cpsa` 5 → 4, `atelier-testing` 4 → 3, `hjsonschema` 7 → 6,
   `scion-browser` 16 → 14); on `bench/problems.txt`, `conduit <1.3` 7 → 6 and
   `aeson <2` 57 → 56. Solver counts are untouched — the pass runs between the solver
   and the renderer.

   **It was not only clutter, which is why it outranked the cosmetics it used to sit
   beside.** The siblings were *blocking* the chain fusion: a dependency fact whose
   sibling cause is a hole-is-empty fact is never adjacent to the next dependency
   fact, so "depends on X which depends on Y" could not form. Absorbing them freed it
   — the fusion now appears in **13 of the 17** harvested problems, having only ever
   been seen in the spec's own worked example. That is also why it looked like a rule
   that never fires on real input.

   Mostly overtaken by slots (gap 1): holes *between* releases no longer form. What
   is left comes from the other direction — `Bridge.Provider.widen` puts a
   **declared** dependency range into a term verbatim, so dead space still survives.

   **The count has collapsed twice since, and this file was wrong about it twice.** It
   claimed until 2026-08-20 that there was exactly one known instance
   (`transformers >=0.2.2 && <0.2.2.0` in `conduit <1.3`), which was an artifact of
   measuring five problems; against the harvested set it was **7 of 17, 22 lines**.
   Two later changes removed nearly all of it without targeting it: stating *why* a
   boot package has no source release (2026-08-22) and restoring the walk
   (2026-08-23). **As of 2026-08-23 the whole corpus carries one such line**, in
   `futhark` (`time-locale-compat >=0.1 && <0.1.0.0`). `matterhorn` used to carry 11 —
   about half its proof — and now carries none.

   The surviving shape is still worth knowing, because it is what the pass leaves
   alone by design and it will come back with any change that widens declared ranges:
   a declared bound naming a version never published. `scripts/gate.sh` holds the
   count at a ceiling of 1, so a regression here fails the gate rather than being
   noticed later.

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
3. **Chain collapsing — done, 2026-08-20**, and it was two rules rather than one.
   `PubGrub.Report` now follows the spec's own reporting algorithm
   (`references/pubgrub.md:504`) instead of replaying the derivation tree one node per
   line:

   - **a chain of two external facts is one sentence** — "foo depends on bar ^2.0.0
     *which depends on* baz ^3.0.0" (`:1018`), plus its sibling form "depends on
     *both* X and Y" where two facts share a depender. Both are in `pair`, and both
     are guarded by a subset test so a fused sentence cannot claim more than the two
     facts do. `isEmpty` being one-sided means the guard can only fail to fuse, never
     fuse wrongly;
   - **every other derived step is skipped** — "you can skip every other derived
     incompatibility without losing clarity" (`:528`, the algorithm's case 2.ii at
     `:643`). Where a step's derived cause has a single derived cause of its own, the
     intermediate *conclusion* goes unsaid and both external facts are named in one
     line. Most derivation graphs here are linear chains, so this is the half that
     halves them.

   Measured when it landed: `lens <4` 6 → **4** lines, `conduit <1.3` 12 → **7**,
   `aeson <2` 83 → **57**. (Current figures are 8, 10 and 64 — the walk's return moved
   them; see the note under gap 1.) Two of three are shorter than cabal's message
   (22 and 16); `aeson` against 30 is still the outlier. `test/PaperSpec.hs` pins the
   rendered proof of both of the spec's published examples as **golden files** under
   `test/golden/` (`cabal test --test-options=--accept` rewrites them; the diff is the
   review) — the closest thing to a conformance test the reporter has, and what turned
   gap 2 from a cosmetic item into the top one.

   **A third rule landed 2026-08-23: a run of same-pair steps is one sentence.** Where
   a proof walked a dependency's bound history one adjacent pair at a time —
   "`hashable >=1.4 && <1.4.0.2` depends on `base` …", then the next range, then the
   next — `oneDerived` now finds the maximal run of chain steps whose external facts
   are all dependency facts about the **same `(depender, dependee)` pair** and states
   them once, as their union. This is *not* `:456`'s collapsing, which merges facts
   with an **identical** dependee range; here the ranges differ, which is exactly why
   the solver had to derive along them.

   Sound because each fact says `p ∈ Sᵢ` requires `q ∈ Rᵢ`, so `p ∈ ⋃S` requires
   `q ∈ ⋃R` — weaker than any of them, hence implied by all. Two guards keep it
   honest, in the module's existing style: the step's conclusion must really be
   "p requires q", and the collapsed depender range must be one that conclusion
   covers, so a line never claims to justify more of `p` than the step it is attached
   to concluded. Measured: `happstack-hsp` 7 → **4**, `matterhorn` 10 → **8**, corpus
   total **62**. Pure rendering, so decisions, reads, allocation and residency are
   identical either side of it. This was the shape `docs/failure-cases.md` had called
   the remaining outlier.
4. Cosmetic, and *two of these came for free with gap 3*: `So,` on the final line
   ✅ and numbering only the lines actually referenced ✅ (a linear proof now carries
   no numbers at all, per `:596`). Still open: terminal periods on non-final lines;
   omit the synthetic root's version — which also emits the NUL in
   `Bridge.Provider.rootName` as **a real `\0` byte, not the "stray space" this file
   used to call it**. GNU `grep` therefore treats every proof as binary and silently
   reports no matches without `-a`: `grep -c because` finds nothing where
   `grep -ac because` finds it. `bench/compare.sh` passes `-a` everywhere and
   `summarise.awk` is unaffected, so no measurement is wrong, but new tooling that
   greps a proof will read zero and look like it passed. Also open: "every version of
   foo" where the spec says that rather than `foo >=0`; and the blank line the spec
   puts between branches.
   Note `bench/summarise.awk` counts proof lines by their opening connective now,
   *because* numbering went sparse — see `docs/benchmarking.md`.
5. **Collapse cells that exhaust a flag's states.** *Dormant since 2026-08-17: no
   cell is ever pinned, so no proof line can show this. Keep it on the list — it
   returns with the flag axis, and the fix is independent of everything else.* Real
   proof lines read
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
