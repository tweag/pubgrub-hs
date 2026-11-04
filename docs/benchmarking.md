# Running the tests and the benchmarks

How to reproduce every number in [STATUS.md](STATUS.md), and what each one is worth.

```sh
cabal test all                # every unit, property and golden test, and pubgrub's doctests
scripts/gate.sh               # the eight gates that decide whether a change is kept
cabal run pubgrub-harness     # both solvers over both problem sets; writes the two reports
scripts/check-stats.sh        # --stats against bench/summarise.awk, on every problem
```

**STATUS.md §2 holds the current numbers.** This file holds the method.

---

## Before you measure anything: build the derived index

```sh
cabal run pubgrub-index -- --index-state "$(cat bench/index-state)"   # a few minutes, at the pin
```

This parses every release once into `_cache/derived-index.cbor` (94.8 MB) plus a
2.5 MB index keyed by tar block. Without it, every release read is a `.cabal` parse at
about 2 ms. Every number you take is then against a different machine from the one
STATUS.md describes.

The store is a cache. Removing `_cache/derived-index.*` costs speed and never
correctness, because every miss parses instead. Raise `storeFormatVersion` in
`pubgrub-hs/src/Bridge/Hackage/Store.hs` on any encoding change.

**The cabal baseline does not use it.** `Bridge.Cabal.Baseline` parses every release it
inspects. That is one of the two reasons the index work is not the same work on the two
sides.

## Tests

```sh
cabal test all                              # everything
cabal test all --test-show-details=direct   # stream results as they run
```

Three packages have a [tasty] suite, `pubgrub-test`, `pubgrub-cabal-test` and
`pubgrub-hs-test`. A fourth suite, `pubgrub-doctests`, runs `pubgrub`'s Haddock examples
and takes no filter. In the tasty suites a substring filter selects a group or a case:

```sh
cabal run pubgrub-cabal-test -- -p InstanceSet          # one module's group
cabal run pubgrub-cabal-test -- -p isSubsetOf           # one property, in each group that has it
cabal run pubgrub-cabal-test -- -p InstanceSet --quickcheck-tests 1000 # more property cases
```

Keep a filter on these. `pubgrub-cabal-test` finds its golden files relative to
`pubgrub-cabal/` and writes one that is missing rather than failing, so the whole suite
run from the project root creates `test/golden/` there and passes. `cabal test` runs it
in the package's directory.

Three groups repay knowing about.

- **`InstanceSet`** — differential properties comparing the real set type against an
  extensional model over a small fixed universe. If you touch the set algebra, this is
  the guard.
- **`PubGrub paper examples`** — the six worked examples from
  [`references/pubgrub.md`](../references/pubgrub.md). The four satisfiable ones assert
  the solution the spec reports. The two unsatisfiable ones assert the **printed
  proof** against the wording the spec publishes at `:1005` and `:1150`, and the linear
  one matches sentence for sentence. Its provider mints release **slots**, as
  `PubGrub.Cabal.Provider` does. A harness that emits per-version dependers is not following
  `:456`, and the divergence shows up as an extra proof line that looks like ours.
- **`PubGrub.Cabal.Report.collapseNoInstances`** — the reporter's rules, on trees built
  by hand. The case that matters asserts that `collapseNoInstances` leaves a node's *terms* untouched. The
  pass re-labels a derivation step rather than recomputing it, and a printed proof
  cannot show that.

### Golden tests, and how to update them

The two proofs are [tasty-golden] tests. The expected output is a file under
[`pubgrub-cabal/test/golden/`](../pubgrub-cabal/test/golden), one per case, so it reads as the proof a user would
see rather than as a list of string literals. A failure prints the actual proof in
full.

```sh
cabal test pubgrub-cabal:test:pubgrub-cabal-test --test-options=--accept   # rewrite the golden files from the run
```

If the wording changed **on purpose**, use `--accept`. Then read the resulting `jj
diff` as the review of that change. Do not reach for it to make a red suite green.
These two files are the closest thing the reporter has to a conformance test.

There is no golden test for the *real* solver's output on Hackage problems. That would
pin an index that moves.

## The gate

```sh
scripts/gate.sh               # everything
OUT=/tmp/gate scripts/gate.sh # keep the per-problem logs
```

Eight gates over one pass of 26 problems: problem count, the 20-case failure corpus,
verdict agreement, proof length against cabal's message, the proof and no-version
totals, the golden proofs, the pkg-config modelling tests, and the whole suite.

It holds five numeric baselines. Only `EXPECT_PROBLEMS` is exact. `MIN_AGREEMENT` and
`EXPECT_CORPUS` are floors, and `MAX_PROOF` and `MAX_NOVER` are ceilings. Beating
`MIN_AGREEMENT`, `MAX_PROOF` or `MAX_NOVER` prints `IMPROVED` and still exits 0; the
corpus gate prints `ok` however many reproduce. **Tighten a baseline in the change that
earns it.**

## Benchmarks

```sh
cabal run pubgrub-harness                             # both sets, three runs each
cabal run pubgrub-harness -- --set bench              # bench/problems.txt only
cabal run pubgrub-harness -- --set corpus --reps 1    # the failure corpus, once
cabal run pubgrub-harness -- 'aeson <2'               # one problem, as one argument
cabal run pubgrub-harness -- --output "$TMPDIR/bench" # somewhere other than bench/output
```

`pubgrub-harness` drives the `pubgrub` executable as a child process, once per solver,
per problem, per repetition. A child, because peak memory is a per-process number and
one process running both solvers could not report two. Each run goes under
`/usr/bin/time -f '%e %M'` for wall-clock and peak resident set size (RSS) and
`+RTS -s` for allocation and maximum residency, with `--stats --plan lines` so the child prints its counts,
phases and plan. The first run of the session is a throwaway against the index
refresh. Per-run logs are left in `<output>/runs/`.

It writes two markdown files into `bench/output/`, which is git-ignored. A run meant
to be quoted is copied into `docs/reports/` on purpose.

- **`benchmark.md`**, from `bench/problems.txt`: the STATUS.md §2.1 table with the
  phases split out, the search-count table, and a plan diff per satisfiable problem
  over the library domain. A package cabal plans at two versions is reported as its
  qualified goals showing through, not as a disagreement.
- **`showcase.md`**, from `bench/unsat-problems.txt`: the environment, the problems
  excluded from the showcase and why, a summary table, then per problem our proof and
  cabal's `Could not resolve dependencies:` block as adjacent fenced blocks. A problem
  whose comment carries `showcase:exclude` is run and measured and not rendered.

Wall-clock, phases, RSS, residency and allocation are medians over the repetitions.
Everything deterministic — verdict, counts, read counters, plan, proof, cabal's
message — is asserted identical across repetitions, and the harness exits non-zero if
any of it varied. Both headers state the date, the index-state, the index snapshot
(the mtime of `_cache/01-index.tar`), GHC, the CPU, which pkg-config packages are
present and absent, the repetition count and the three restrictions. They carry a warning when any run parsed
a `.cabal` file, when the driver predates `--stats` and `--plan` (the harness probes
`--help`), and when anything varied.

Options: `--exe PATH` (default `$PUBGRUB_EXE`, else `cabal list-bin exe:pubgrub`),
`--reps N` (3), `--output DIR` (`bench/output`), `--timeout SECONDS` (300),
`--index-state TIMESTAMP` (the pin in `bench/index-state`), `--set bench|corpus|both`,
and positional problems.

It measures; it does not decide. `scripts/gate.sh` decides, and neither replaces the
other. The decision record `decision-0035-one-command-produces-both-deliverables`, in the
project's Hindsight bank, has why it is shaped this way.

**There are two problem sets, and they answer different questions.**

- [`bench/problems.txt`](../bench/problems.txt) — six problems for *performance*, in
  three kinds. `vector` and `pandoc` measure index throughput and cannot show a search
  improvement, because `pandoc` has exactly one conflict. `conduit <1.3`, `lens <4` and
  `aeson <2` measure search on an unsatisfiable problem. `yesod` measures search on a
  satisfiable one. A change that helps only one kind is not a change that helps. Check
  all three.
- [`bench/unsat-problems.txt`](../bench/unsat-problems.txt) — 20 real failures for
  *explanations*, every target pinned, plus four positive controls left commented out.
  See [failure-cases.md](failure-cases.md). `scripts/gate.sh` and the harness both run
  the 20; the harness renders the 16 not marked `showcase:exclude`.

### Reading a run by hand

```sh
pubgrub 'aeson <2'                     # quiet: the answer and the read counts
pubgrub --stats 'aeson <2'             # + the search counts and phase timings, still quiet
pubgrub -v 'aeson <2'                  # + the solver's search trace
pubgrub --cabal 'aeson <2'             # cabal's solver over the same index
pubgrub -v 'aeson <2' | awk -f bench/summarise.awk
```

`--stats` counts the search in-process and prints two lines after the answer, before
the provider's `read N .cabal files …` line:

```
stats: deciding=319 chose=319 conflicts=58 learned=57 resolving=89 backtracked=57 noversion=0 judged=36211 rejudged=11326 depth=0:48,2:5,3:2,5:1,23:1
phases: world=0.412 index=0.000 solve=0.331 render=0.008
```

`depth=K:C,…` is the resolution-depth histogram. `phases:` is the child's own clock,
in seconds: `world` opens the index, the installed database and the pkg-config
database; `index` is cabal's `sourcePackageIndex` build, zero for ours; `solve` is
the search; `render` is printing the answer. Under `--cabal` the stats line is
`stats: steps=N`, cabal's log-step count. `-v` and `--stats` compose.

`judged` and `rejudged` count propagation's work rather than the search. `judged` is
every clause propagation judged against the partial solution, one per clause per
round; `rejudged` is the part of it judged in the round right after a backtrack.
Neither has a trace line, so the awk cannot count them and `check-stats.sh` does not
compare them, and a `-v` trace is the same with or without them. On the 26 problems at
the pin, `rejudged` is 57,597 of 199,766 judgements, 29%. Read either next to
allocation: a judgement costs about 50 bytes, so even a large cut in `judged` can be
noise in the run ([DESIGN.md](DESIGN.md) §5).

`bench/summarise.awk` turns a `-v` trace into the same event counts plus the
**resolution-depth histogram**. The histogram counts the `Resolving` events between a `Conflict` and its
`Learned`. A depth-16 entry is one clause learned over sixteen iterations. That
histogram is what makes collapsing work visible.

It reports three separate read counters, and they mean different things:

| counter | meaning |
| --- | --- |
| `parses` | releases whose `.cabal` was parsed. **Zero** while the derived index holds the revision the run reads: anything else parses on demand |
| `decoded` | releases decoded out of the derived index |
| `reused` | repeat lookups served from the in-memory cache |

The lookup figures STATUS.md quotes (2831 on `pandoc`) are `decoded`.

The decision figures STATUS.md quotes are `deciding`: every time the solver asked the
provider for a decision. `chose` is the subset that produced an instance, and the two
differ by the `noversion` events. On `lens <4` that is 64 against 62. Quote `deciding`.

`summarise.awk` matches the read counters by name, because a match by field position
turns silently into 0 when the provider's line gains a clause, and a 0 looks like a
measurement. **If you add a counter, add it by name.**

`+RTS -s` works on any run (the executable is built with `-rtsopts`):

```sh
pubgrub 'aeson <2' +RTS -s             # allocation, max residency, GC time
```

## Which numbers to trust

**Counts are deterministic. Times are not.** Decisions, conflicts, backjumps,
no-version events, reads and proof length are the same on every run of the same code,
so a difference in any of them is a real difference. Compare those.

**Elapsed time on a desktop moves by ±25%.** Four runs of `aeson <2` at one commit came
in at 5.2, 6.5, 6.9 and 7.8 s. Never conclude from a single pair of timings.

**Total allocation is the stable stand-in for time.** `+RTS -s` reports it, it barely
varies between runs, and it caught a 3.9% regression that wall-clock could not resolve.

**Peak memory has two numbers and they mean different things.** `%M` from
`/usr/bin/time` is peak RSS, which includes the runtime system's own overhead and
fragmentation.
`maximum residency` from `+RTS -s` is the live heap as the garbage collector saw it.
STATUS.md quotes the second.

**The ~29 MB floor is unexplained**, and it is the weakest link in the strongest claim
the project has. Doubling the per-element overhead of the package-to-versions map, long
assumed to dominate it, moved the floor by 0.5%. A ratio whose numerator nobody can
account for is not evidence, however reproducible it is.

**What sits above the floor is known: the memoised reduced forms.** Residency tracks
**how many releases were read**, which is a number the solver's own strategy moves.
`pandoc` sits above the floor because the collapsing walk reads 2831 releases where
the solve needs about 170 ([collapsing.md](collapsing.md) §3). Record residency on
every run, not only when it looks interesting.

**Pin the index-state, or the problem moves.** The Hackage index refreshes itself at
most weekly, and each refresh changes the set of releases and, through revisions,
their bounds: on 2026-09-03 two of cabal's corpus messages grew while our proofs did
not. `pubgrub --index-state 2026-09-03T00:00:00Z <target>` gives both solvers the
index as it was then, and every run prints the state it is really at on an
`index-state:` line. The gate, `check-stats.sh` and `pubgrub-harness` all read the
pin in `bench/index-state` and pass it to every run, and the harness records it in
the reports' environment header. `PUBGRUB_INDEX_STATE=<timestamp>` overrides the pin
for the two scripts and `pubgrub-harness --index-state <timestamp>` for the harness;
`head` runs against everything the local index holds. Move the pin in the change that re-measures, and
never to a moment the index does not have: a pin newer than Hackage's latest entry
is an error on every run until Hackage catches up. A number quoted without its
index-state cannot be reproduced after the next refresh.

**Warm the index.** With no index-state, the first run after a week refreshes the
Hackage index and rebuilds the version cache, which walks the whole tar (about 2.5 s
from the page cache). With an index-state older than the local index nothing is
refreshed, and with one newer the index is refreshed and the run then fails if the
request is still newer. The harness, the gate and `check-stats.sh` each do one throwaway
run (`vector`, not recorded), so a refresh or a version-cache rebuild lands outside the
numbers. A `cacheFormatVersion` bump also forces one rebuild.

**A run ahead of the derived index or behind it parses what the store does not hold.**
Each stored release carries the tar block it was parsed from and is served only for
that revision. A run at the head parses every release published or revised since the
state the store was built at, and a store built at the head holds each release at its head revision, so a run
pinned behind it parses every release revised in between (18 of them on the benchmark
set on 2026-10-08, a month after the pin). The tar is append-only, so a refresh moves no
block and leaves a store built at the pin good for pinned runs. The answers stay right
either way. Build with `pubgrub-index --index-state` at the pin in `bench/index-state`,
or the `parses` column stops being zero.

**Reading the index at an index-state has a fixed price.** The version cache is
decoded and filtered on every run, and that allocates about 0.15 GB inside the `world`
phase, on every problem alike (DESIGN.md §13). It moves the allocation of the
smallest rows of the benchmark table and nothing else.

**`maximum residency` is a sample, and the sample can move.** It is the largest heap
seen at any major collection, and a short run under the default 4 MB nursery has about
six of them. A change that only shifts allocation shifts where they land: on `vector`
the cabal baseline read 50.7 MB before the index-state work and 65.8 MB after, while
under `+RTS -A256k`, which collects often enough to see the real peak, it read 64.3 MB
and 66.0 MB. Before attributing a residency change to the code, re-run both sides
with `-A256k`; if the two agree there, the default-nursery number moved by sampling.
The STATUS.md §2.1 table carries the default-nursery numbers.

## Comparing against cabal

`--cabal` runs cabal's own modular solver (`cabal-install-solver`, no `cabal-install`
dependency) over **the same** index, installed database and `pkg-config` database, each
opened by the same `Bridge.Provider.withWorld`, so a difference between the two cannot be
a difference between two reads.

Four things to keep in mind when reading a comparison.

1. **The index work is not the same work.** We decode a release when we expand a
   package. cabal's resolver wants a `SourcePackage` record for all ~153k releases
   before it starts, and it parses each one it inspects. That is most of its memory and
   some of its floor time. The `world` phase (index open, installed db, pkg-config db)
   is separated on both sides. cabal's `index` phase is only the eager allocation of
   those records; the `PackageIndex` and every `.cabal` parse are lazy and land in its
   `solve` phase, and forcing them earlier would make a solve pay for releases it never
   touches, which changes what is measured.
2. **cabal solves setup and build-tool dependencies and we do not** (`solveExecutables
   = True`, against a driver that solves neither namespace, STATUS.md §4.1). On a
   package with a custom setup the two are not solving the same problem.
3. **cabal's plan is printed by component, and must be read that way.** cabal solves
   *qualified goals*, so a setup or executable dependency is solved in its own domain.
   `Setup.hs` can be built against a different `mtl` than the library, and one plan can
   legitimately name two versions of a package. `convCP` strips the qualifiers from the
   identities on the way out, so a flat package list will mislead you.
4. **Every flag is pinned to its declared default on both sides**, under the default
   `--flags fixed`. That is a restriction of the problem. It also perturbs cabal's goal ordering, because a manual
   flag is not *weak*, so `deferWeakFlagChoices` stops deferring the flags that
   influence dependencies.

For the explanation deliverable the comparable quantity is **length**: our proof
against cabal's message. The harness's `showcase.md` prints both per problem, and
`scripts/gate.sh` holds the corpus totals as ceilings. Over the 20-case corpus cabal's
message runs 7 to 17 lines. Ours has no bound on length, and on an unconstrained
target it is the longer text (STATUS.md §2.2).

**A proof is counted by connective, not by line number.** The reporter numbers only
the conclusions it refers back to (`references/pubgrub.md:673`). In a linear
derivation that is none of them. So `summarise.awk`, the gate and the harness match
the opening words instead: `Because`, `And because`, `So, because`, `Thus,`.

## Quiet and counted

A quiet run is also a counted run: `--stats` folds the solver's messages into counters
in-process and prints two lines after the answer, so timing and the search columns come
from the same run, and the harness times such runs. `scripts/check-stats.sh` holds those
counters to `bench/summarise.awk`, number for number, on all 26 problems.

`-v` is different: the trace prints to stdout, `aeson <2` prints thousands of lines, and
an elapsed time taken with `-v` is an upper bound.

[tasty]: https://hackage.haskell.org/package/tasty
[tasty-golden]: https://hackage.haskell.org/package/tasty-golden
