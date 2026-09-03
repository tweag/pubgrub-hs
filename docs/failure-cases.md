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

## The 17 that reproduce, against cabal

ghc-9.12.2, base-4.21.0.0, and this machine's pkg-config database. Absent there:
`libpq`, `libzmq`, `blas`, `lapack`. Present: `cairo`, `pango`, `gtk+-2.0`, `gtk+-3.0`,
`gtk4`, `gio-2.0`, `zlib`, `libsodium`, `libgit2`. Every problem runs in under 3 s.
Measured on 2026-09-03, on the Hackage index refreshed that day. cabal's message
lengths move with the index: `haskoin-store-data` and `atelier-testing` each grew by
two lines between the 2026-08-20 and 2026-09-03 snapshots. Ours did not move.

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
| `hjsonschema ==1.10.0` | aeson / bytestring chain | **5** | 13 | 0 |
| `language-puppet ==1.5.1` | `ghc-prim` via aeson | **5** | 11 | 0 |
| `futhark ==0.27.1` | regex / time chain | **8** | 10 | 1 |
| `matterhorn ==90000.1.1` | hashable / bytestring chain | **8** | 17 | 0 |

**Shorter on all 17: 62 proof sentences against cabal's 166**, and one `no version`
line left in the whole set. The margin is narrowest on `futhark` (8 against 10) and
widest on `cabal-install` (2 against 12). `matterhorn` is our longest at 8, against
cabal's longest message at 17.

[`scripts/gate.sh`](../scripts/gate.sh) re-runs every row and holds both totals as
ceilings, so a regression here fails the gate rather than being noticed later.

Two things this table is evidence for beyond length:

- **The chain fusion fires in the wild.** `depends on X which depends on Y` appears in
  14 of the 17. It had only ever been seen in the spec's own worked example, so it
  looked like a rule that never fires on real input. That is also what made the empty-range
  clutter look cosmetic ([STATUS.md](STATUS.md) §4.9, rule 4): those holes were what
  kept the fusion from pairing.
- **`references/pubgrub.md:476` pays.** `hpqtypes-extras` says
  `hpqtypes >=1.10.0.2 cannot be built here` where cabal says `pkg-config package
  libpq-any, not found in the pkg-config database`. Both name the cause, and ours takes
  two lines against eight. Our solver used to say `no version for hpqtypes in >=1.13`,
  which is the symptom and sounds false.

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
  ([STATUS.md](STATUS.md) §5.1). That is a restriction of the problem, and it removes
  exactly the escape cabal's *automatic* flags would provide.
- **cabal solves setup and build-tool depends and we do not.** On a package with a
  custom `Setup.hs` the two are answering different questions. None of the 17 has one.
- **Four of them fail for different reasons on the two sides** (`atelier-testing`,
  `cabal-install`, `futhark`, `haskoin-store-data`) — both correctly unsat, but a
  side-by-side slide must either pick reason-matching cases or say so out loud.

## What is still missing

The harness. `scripts/gate.sh` does the regression half: it runs both solvers over
every row and fails on any regression in verdict agreement or proof length. It does not
render the two explanations side by side, and side-by-side rendering is what turns this
table into the deliverable. See [STATUS.md](STATUS.md) §9.

One trap for whoever writes it: **our proofs contain a NUL byte** (the synthetic root's
name), so GNU `grep` treats them as binary and silently reports no matches without
`-a`. `bench/compare.sh` passes `-a` everywhere. New tooling must too, or the
proof-line count will read zero and look like a passing measurement.
