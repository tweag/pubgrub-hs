# Failure cases: where the unsat problem set comes from, and what is in it

The explanation deliverable needs problems that **fail**, and until 2026-08-20 the
project had three, all found by accident while measuring something else. This is the
set that was found on purpose, the method that found it, and what it says about our
proofs against cabal's messages.

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

1. **pkg-config missing** — a C library the machine does not have. 14 of the 28 hits
   in the top 101–500, making it **the single most common cause**. `vulkan`, `cairo`,
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

ghc-9.12.2, base-4.21.0.0, this machine's pkg-config db (`libpq`, `libzmq`, `blas`,
`lapack` absent; `cairo`, `pango`, `gtk+-2.0`, `gtk+-3.0`, `gtk4`, `gio-2.0`, `zlib`,
`libsodium`, `libgit2` present). Every one runs in under 3 s.

`ours` counts proof sentences. `cabal` counts the non-blank lines of its
`Could not resolve dependencies:` block — its actual explanation, not the whole log.
`noVer` counts our `no version for …` lines, which is Reporting gap 2's clutter.

| target | kind | ours | cabal | noVer |
| --- | --- | --- | --- | --- |
| `hadolint ==2.15.1` | `time` vs language-docker | **2** | 10 | 0 |
| `liquidhaskell ==0.9.14.1.1` | installed `ghc` | **2** | 8 | 0 |
| `purescript ==0.15.15` | base bound | **2** | 8 | 0 |
| `haddock ==2.29.1` | base bound, seven windows | **2** | 8 | 0 |
| `hpqtypes-extras ==1.20.0.0` | pkg-config `libpq` | **2** | 8 | 0 |
| `stackctl ==1.7.3.7` | base via amazonka | **3** | 8 | 0 |
| `atelier-testing ==0.2.0.0` | dead range | **3** | 7 | 1 |
| `cabal-install ==3.18.1.0` | Cabal / hackage-security | **4** | 13 | 0 |
| `calamity ==0.12.1.0` | base via aeson-optics | **4** | 11 | 1 |
| `haskoin-store-data ==1.6.0` | pkg-config `libsecp256k1` | **4** | 12 | 0 |
| `language-puppet ==1.5.1` | `ghc-prim` via aeson | **5** | 12 | 0 |
| `cpsa ==4.4.9` | installed `deepseq` | **4** | 10 | 2 |
| `hjsonschema ==1.10.0` | aeson / bytestring chain | **6** | 14 | 1 |
| `happstack-hsp ==7.3.7.8` | `template-haskell` history | **7** | 9 | 0 |
| `futhark ==0.27.1` | regex / time chain | **8** | 11 | 2 |
| `scion-browser ==0.5.0` | haskeline / tar chain | 14 | 12 | 5 |
| `matterhorn ==90000.1.1` | hashable / bytestring chain | **16** | 18 | 10 |

**Shorter on 16 of 17.** The one loss, `scion-browser`, has the shape `aeson '<2'`
has: the proof walks a dependency's bound history release by release, one sentence per
adjacent pair. That is the outlier left to fix.

These numbers are **after Reporting gap 2** (2026-08-20), which absorbed the
`no version for …` leaves into the sibling they were resolved against. It took the
`noVer` column from 30 lines to 22 across the set and four proofs with it — `cpsa`
5 → 4, `atelier-testing` 4 → 3, `hjsonschema` 7 → 6, `scion-browser` 16 → 14 — and
`matterhorn`, the longest, is still 10 lines of hole out of 16.

Two things this table is evidence for beyond length:

- **The chain fusion fires in the wild.** `depends on X which depends on Y` appears in
  13 of the 17. It had only ever been seen in the spec's own worked example, and on
  the strength of that it looked like a rule that never fires on real input — which is
  also what made gap 2 look cosmetic, since the holes were what kept it from pairing.
- **`:476` now pays.** `hpqtypes-extras` says `hpqtypes >=1.10.0.2 cannot be built
  here` where cabal says `pkg-config package libpq-any, not found in the pkg-config
  database`; both name the cause, and ours takes two lines against eight. Before the
  exhausted case was fixed, ours said `no version for hpqtypes in >=1.13` — the
  symptom, and false-sounding.

### The positive controls

`vulkan ==3.27`, `dataframe-csv ==2.3.0.0`, `xmobar ==0.51.1`, `timeplot ==1.0.33`
and `gloss ==1.13.2.2` all failed on Hackage's builder and **resolve here** (verified
2026-08-20). `vulkan` is the clearest: the builder had no pkg-config `vulkan`, this
machine does. A problem set for explanations needs these, or it cannot show that the
failures in it are real rather than an artefact of the environment.

## Caveats for anything built on this

- **Environment-pinned.** Four of the six kinds depend on the compiler's own packages
  or on the local pkg-config db. Install `libpq` and `hpqtypes-extras` resolves. Any
  published figure has to state the environment.
- **Both solvers run with every flag pinned to its declared default** (the release-1
  scope cut). That is a restriction of the problem, and it removes exactly the escape
  cabal's *automatic* flags would provide.
- **cabal solves setup and build-tool depends and we do not.** On a package with a
  custom `Setup.hs` the two are answering different questions. None of the 17 has one.
- **Four of them fail for different reasons on the two sides** (`atelier-testing`,
  `cabal-install`, `futhark`, `haskoin-store-data`) — both correctly unsat, but a
  side-by-side slide must either pick reason-matching cases or say so out loud.

## What is still missing

The harness. These 17 are run one at a time, by hand, and the numbers above were
counted by grep. One process that runs both solvers per problem, renders the two
explanations side by side and diffs the verdicts is what turns this table into the
deliverable — see [STATUS.md](STATUS.md), "Deliverable status".

One trap for whoever writes it: **our proofs contain a NUL byte** (the synthetic
root's name), so GNU `grep` treats them as binary and silently reports no matches
without `-a`. `bench/compare.sh` passes `-a` everywhere; new tooling must too, or the
proof-line count will read zero and look like a passing measurement.
