# Failure cases: the unsat problem set

The explanation deliverable needs problems that **fail**. This file is that set, the
method that found it, and what it says about our proofs against cabal's messages.

Before it existed the project had three failing problems, all found by accident while
measuring something else. A small problem set chosen to measure search cannot report on
a path it never walks.

The problems themselves are [`bench/unsat-problems.txt`](../bench/unsat-problems.txt),
which carries the per-problem notes. This file is the argument around them.

## Hackage's build reports are the source

Hackage keeps the build bot's report for each release. A report whose install outcome
is `PlanningFailed` is **cabal failing to resolve** — and the page carries cabal's own
solver log, which is the baseline half of a side-by-side, free and from the horse's
mouth.

| what | URL |
| --- | --- |
| packages by last-month downloads (18,608 of them) | `/packages/top.json` |
| a package's latest version's reports | `/package/<name>/reports/` (302 → `<name>-<ver>`) |
| one report, rendered | `/package/<name>-<ver>/reports/<n>` |
| cabal's raw solver log | `/package/<name>-<ver>/reports/<n>/log` (`text/plain`, 0.4–2.7 KB) |

The hit rate for `PlanningFailed` on a package's *latest* version is about **10%**:
11 of the top 100 by downloads, 26 of the next 400, 21 of 201 newest uploads. A wider
sweep is therefore cheap, and at 6 requests/second it is polite.

**A report is a lead, not a verdict.** The builder runs ghc-9.6.3/9.8.4 with no
development libraries, so its environment is not ours and every hit has to be re-run
locally. That cuts both ways: five of the reports reproduce as *successes* here, and
they are worth as much as the failures (below).

## The six kinds, ranked by how often they occur

1. **pkg-config missing** — a C library the machine does not have. 14 hits in the top
   101–500, which is **the single most common cause** and about half of them.
   `vulkan`, `cairo`,
   `pango`, `gtk`, `gi-*`, `hruby`, `hpqtypes-extras`, `secp256k1-haskell`.
2. **base bound vs the installed base** — a bound that excludes the `base` the
   compiler provides. `purescript`, `haddock`, `futhark`, `hlint` (two hops, via
   `ghc-lib-parser`), `calamity`, `stackctl`.
3. **Dead range** — a declared bound naming a version that was never published:
   `atelier-testing`'s `tmp-postgres >=1.35 && <1.36` when the newest is 1.34.1.0.
4. **Installed-graph conflict** — the clash is with what an *installed* boot package
   requires, not with anything on Hackage: `cpsa`'s `deepseq <1.5` against the
   installed `bytestring`, which requires `deepseq ==1.5.1.0`.
5. **Unknown package** — a dependency that is not on Hackage at all: `cabal-install
   3.18.1.0` needs `hooks-exe`.
6. **Unsupported language** — `requires unknown language GHC2024` (`numhask`,
   `okf-core`). A per-release rejection of exactly the shape buildability has, but
   coming from the toolchain rather than the index. **Not reproducible here** (our
   `Cabal-syntax` knows GHC2024) and we have no model for it.

Kinds 1–5 all reproduce. Kind 6 does not, and is recorded so nobody hunts it twice.

## A second source: two targets that each resolve alone

A build report can only show a package failing against the compiler and the
machine, and every one of the 17 above turns on a boot package, a missing C library
or a dead range. A conflict *between two packages* needs two targets, so the second
method solves pairs of popular packages together after checking that each resolves
alone at the pinned index-state: if both do, a failure of the pair is a conflict
between them and nothing else.

**Pinning every target is what makes it work.** 153 pairs of unconstrained popular
packages gave 153 resolutions, because the solver is free to pick an older release
of either. With every target pinned to its latest release the same packages give
three failures, all of them `aeson 2.3.1.0` against a depender still capped below
it, and no boot package anywhere. Lowering the index-state does not help: the
un-absorbed window sits at the newest state, since a major release published long
before `T` has been caught up with by `T`.

## The 20 that reproduce, against cabal

ghc-9.12.2, base-4.21.0.0, and this machine's pkg-config database. Absent there:
`libpq`, `libzmq`, `blas`, `lapack`. Present: `cairo`, `pango`, `gtk+-2.0`, `gtk+-3.0`,
`gtk4`, `gio-2.0`, `zlib`, `libsodium`, `libgit2`. Every problem runs in under 3 s.
Measured on 2026-09-22 at index-state `2026-09-09T02:42:09Z`. cabal's message
lengths move with the index when it is not pinned: `haskoin-store-data` and
`atelier-testing` each grew by two lines between the 2026-08-20 and 2026-09-03
snapshots. Ours did not move.

`ours` counts proof sentences. `cabal` counts the non-blank lines of its
`Could not resolve dependencies:` block — its actual explanation, not the whole log.
`noVer` counts our `no version for …` lines. Those say a range holds no release, which
is true but not a cause, so a proof carrying one is explaining less than it could.

| target | kind | ours | cabal | noVer |
| --- | --- | --- | --- | --- |
| `cabal-install ==3.18.1.0` | Cabal / hackage-security | **2** | 12 | 0 |
| `haddock ==2.29.1` | base bound, seven windows | **2** | 7 | 0 |
| `hadolint ==2.15.1` | `time` vs language-docker | **2** | 9 | 0 |
| `hpqtypes-extras ==1.20.0.0` | pkg-config `libpq` | **2** | 7 | 0 |
| `liquidhaskell ==0.9.14.1.1` | installed `ghc` | **2** | 7 | 0 |
| `purescript ==0.15.15` | base bound | **2** | 7 | 0 |
| `stackctl ==1.7.3.7` | base via amazonka | **2** | 7 | 0 |
| `atelier-testing ==0.2.0.0` | dead range | **3** | 8 | 0 |
| `calamity ==0.12.1.0` | base via aeson-optics | **3** | 10 | 0 |
| `cpsa ==4.4.9` | installed `deepseq` | **3** | 9 | 0 |
| `happstack-hsp ==7.3.7.8` | `template-haskell` history | **4** | 8 | 0 |
| `scion-browser ==0.5.0` | haskeline / tar chain | **4** | 11 | 0 |
| `haskoin-store-data ==1.6.0` | pkg-config `libsecp256k1` | **5** | 13 | 0 |
| `hjsonschema ==1.10.0` | aeson / bytestring chain | **4** | 13 | 0 |
| `language-puppet ==1.5.1` | `ghc-prim` via aeson | **5** | 11 | 0 |
| `futhark ==0.27.1` | regex / time chain | **7** | 10 | 0 |
| `matterhorn ==90000.1.1` | hashable / bytestring chain | **8** | 17 | 0 |
| `dhall ==1.42.3, aeson ==2.3.1.0` | two targets: dhall caps aeson | **2** | 7 | 0 |
| `hlint ==3.10, aeson ==2.3.1.0` | two targets, via deriving-aeson | **5** | 9 | 0 |
| `yesod ==1.6.2.3, aeson ==2.3.1.0` | two targets, via yesod-persistent and persistent | **9** | 11 | 0 |

**Shorter on all 20: 76 proof sentences against cabal's 193**, and no `no version`
line left in the whole set. The margin is narrowest on the `yesod` pair (9 against
11) and widest on `cabal-install` (2 against 12). Our longest is the `yesod` pair at
9, against cabal's longest message at 17 on `matterhorn`.

[`scripts/gate.sh`](../scripts/gate.sh) re-runs every row and holds both totals as
ceilings, so a regression here fails the gate rather than being noticed later.

Two things this table is evidence for beyond length:

- **The chain fusion fires in the wild.** `depends on X which depends on Y` appears in
  14 of the first 17. It had only ever been seen in the spec's own worked example, so it
  looked like a rule that never fires on real input. That is also what made the empty-range
  clutter look cosmetic ([DESIGN.md](DESIGN.md) §9, rule 5): those holes were what
  kept the fusion from pairing.
- **`references/pubgrub.md:476` pays.** `hpqtypes-extras` says
  `hpqtypes >=1.10.0.2 needs pkg-config package libpq, which is not found` where
  cabal says `pkg-config package libpq-any, not found in the pkg-config database`. Both name the module, and ours takes two sentences against eight lines.
  Our solver used to say `no version for hpqtypes in >=1.13`, which is the symptom
  and sounds false, and then `cannot be built here`, which is the verdict without
  the module.

### The positive controls

`vulkan ==3.27`, `dataframe-csv ==2.3.0.0`, `xmobar ==0.51.1`, `timeplot ==1.0.33`
and `gloss ==1.13.2.2` all failed on Hackage's builder and **resolve here**.
`vulkan` is the clearest: the builder had no pkg-config `vulkan`, this
machine does. A problem set for explanations needs these, or it cannot show that the
failures in it are real rather than an artefact of the environment.

## Caveats for anything built on this

- **Environment-pinned.** Four of the six kinds depend on the compiler's own packages
  or on the local pkg-config db. Install `libpq` and `hpqtypes-extras` resolves. Any
  published figure has to state the environment.
- **Both solvers run with every flag pinned to its declared default**
  ([STATUS.md](STATUS.md) §3.1). That is a restriction of the problem, and it removes
  exactly the escape cabal's *automatic* flags would provide.
- **cabal solves setup and build-tool depends and we do not.** On a package with a
  custom `Setup.hs` the two are answering different questions. None of the 20 has one.
- **Every target is pinned to one version**, and the length record holds only there.
  See the next section.
- **Four of them fail for different reasons on the two sides** (`atelier-testing`,
  `cabal-install`, `futhark`, `haskoin-store-data`) — both correctly unsat, but the
  two explanations are about different facts, so their lengths do not compare. They
  are excluded from the showcase: each carries `showcase:exclude` in its comment in
  `bench/unsat-problems.txt`, and stays in the corpus and the gate.

## What the corpus does not measure: an unconstrained target

The pair sweep was also run with one target of each pair left unconstrained. That
gave 23 failures, and **we were the longer text on 21 of them**, at 28 to 113
sentences against cabal's 10 to 26. The cause is structural. Refuting an
unconstrained target means refuting every one of its releases, so a complete proof
walks the target's whole version history, and consecutive releases rarely fail over
the same dependee, so the same-pair fusion never fires. cabal's message is a search
trace instead: on `optparse-applicative ==0.15.1.0, criterion` it prints 26 lines, 20
of them `trying:`, explains `criterion-1.6.5.0` only and never why 1.6.4 and below
fail, and 4 of the 23 end at `Backjump limit reached`, a resource limit where we
print a refutation. Rule 4 of the reporter ([DESIGN.md](DESIGN.md) §9) was built
from that sweep and took the three longest from 46, 65 and 63 sentences to 34, 54 and
46. It is not enough: each remaining sentence names a different depender.

Those problems are not in the corpus and nothing gates them. A sentence count against
cabal's trace is not the right measure for them, since the trace explains one release
and the proof explains all of them, so the showcase needs a completeness column
before it can render such a problem fairly. Until then, every number quoted from this
corpus is a number about pinned targets.

## How this is rendered

`cabal run pubgrub-harness -- --set corpus` runs both solvers over every row and
writes `bench/output/showcase.md`: the environment and the three restrictions, the
excluded problems and why, a summary table, then per problem our proof and cabal's
`Could not resolve dependencies:` block as adjacent fenced blocks, with the counts.
The four reason-mismatched problems are run and measured and not rendered, so the
headline it prints is "shorter on 16 of 16 comparable problems", by sentences; by
screen lines at 80 columns it is shorter on 15 and equal on the `hlint` pair.
`scripts/gate.sh`
does the deciding half: it fails on any regression in verdict agreement or proof
length. See [STATUS.md](STATUS.md) §5 and [harness-plan.md](harness-plan.md).

One habit worth keeping in any tool over this corpus: read a child's output as
bytes and pass `-a` to `grep`. A tool that reads a proof as text and meets a byte
it cannot decode counts zero lines and looks like a passing measurement.
