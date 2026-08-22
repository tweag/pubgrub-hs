# Running the tests and the benchmarks

How to reproduce every number in [STATUS.md](STATUS.md), and what each one is worth.

```sh
cabal test                    # 165 unit, property and golden tests, ~0.3 s
scripts/gate.sh               # the nine gates that decide whether a change is kept
bench/compare.sh              # both solvers over bench/problems.txt
```

**STATUS.md §3 holds the current numbers.** This file holds the method.

---

## Before you measure anything: build the derived index

```sh
cabal run pubgrub-index       # ~200 s, once
```

This parses all 152,987 releases into `_cache/derived-index.cbor` (62.5 MB) plus a
0.4 MB offset map. Without it, every release read is a `.cabal` parse at about 2 ms. Every number you
take is then against a different machine from the one STATUS.md describes.

The store is a cache. Removing `_cache/derived-index.*` costs speed and never
correctness, because every miss parses instead. Raise `storeFormatVersion` in
`bridge/Bridge/Hackage/Store.hs` on any encoding change.

**The cabal baseline does not use it.** `Bridge.Cabal.Baseline` parses every release it
inspects. That is one of the two reasons the index work is not the same work on the two
sides.

## Tests

```sh
cabal test                                  # everything
cabal test --test-show-details=direct       # stream results as they run
```

The suite is [tasty], so a substring filter selects a group or a single case:

```sh
cabal run pubgrub-hs-test -- -p InstanceSet          # one module's group
cabal run pubgrub-hs-test -- -p 'size control'       # one case
cabal run pubgrub-hs-test -- --quickcheck-tests 1000 # more property cases
```

Three groups repay knowing about.

- **`InstanceSet`** — differential properties comparing the real set type against an
  extensional model over a small fixed universe. It found three real bugs the first
  time it ran, and a fourth when its universe was fixed. If you touch the set algebra,
  this is the guard. Its "size control" case pins cell-count growth: 28,293 cells with
  null-dropping alone against 41 with subsumption pruning, for a denotation of 56
  instances. The case gates at 48 to leave headroom.
- **`PubGrub paper examples`** — the six worked examples from
  [`references/pubgrub.md`](../references/pubgrub.md). The four satisfiable ones assert
  the solution the spec reports. The two unsatisfiable ones assert the **printed
  proof** against the wording the spec publishes at `:1005` and `:1150`, and the linear
  one matches sentence for sentence. Its provider mints release **slots**, as
  `Bridge.Provider` does. A harness that emits per-version dependers is not following
  `:456`, and the divergence shows up as an extra proof line that looks like ours.
- **`PubGrub.Report`** — the reporter's four rules, on trees built by hand. The case
  that matters asserts that `collapseNoInstances` leaves a node's *terms* untouched. The
  pass re-labels a derivation step rather than recomputing it, and a printed proof
  cannot show that.

### Golden tests, and how to update them

The two proofs are [tasty-golden] tests. The expected output is a file under
[`test/golden/`](../test/golden), one per case, so it reads as the proof a user would
see rather than as a list of string literals. A failure prints the actual proof in
full.

```sh
cabal test --test-options=--accept       # rewrite the golden files from the run
```

If the wording changed **on purpose**, use `--accept`. Then read the resulting `jj
diff` as the review of that change. Do not reach for it to make a red suite green.
These two files are the closest thing the reporter has to a conformance test.

There is no golden test for the *real* solver's output on Hackage problems. That would
pin an index that moves.

## The gate

```sh
scripts/gate.sh               # everything
SKIP_LEAN=1 scripts/gate.sh   # skip the Lean build
```

Nine gates over one pass of 23 problems: problem count, the 17-case failure corpus,
verdict agreement, proof length against cabal's message, the proof and no-version
totals, the golden proofs, the pkg-config modelling tests, the whole suite, and the
Lean build.

It holds five numeric baselines. Only `EXPECT_PROBLEMS` is exact. `MIN_AGREEMENT` and
`EXPECT_CORPUS` are floors, and `MAX_PROOF` and `MAX_NOVER` are ceilings. Beating a
floor or a ceiling prints `IMPROVED` and still exits 0. **Tighten a baseline in the
change that earns it.**

## Benchmarks

```sh
bench/compare.sh                  # the whole set, both solvers
bench/compare.sh aeson '<2'       # one problem
OUT=/tmp/bench bench/compare.sh   # keep the logs
TIMEOUT=60 bench/compare.sh       # give up sooner (default 300 s)
```

It prints, per problem and per solver: verdict, elapsed, peak RSS, GC max residency,
total allocation, and — for our solver — the trace-derived counts and proof length.
Logs, RTS stats and timings are left in `$OUT`.

**There are two problem sets, and they answer different questions.**

- [`bench/problems.txt`](../bench/problems.txt) — six problems for *performance*, in
  three kinds. `vector` and `pandoc` measure index throughput and cannot show a search
  improvement, because `pandoc` has exactly one conflict. `conduit <1.3`, `lens <4` and
  `aeson <2` measure search on an unsatisfiable problem. `yesod` measures search on a
  satisfiable one. A change that helps only one kind is not a change that helps. Check
  all three.
- [`bench/unsat-problems.txt`](../bench/unsat-problems.txt) — 17 real failures for
  *explanations*, plus five positive controls. See
  [failure-cases.md](failure-cases.md). `scripts/gate.sh` runs these. `compare.sh` does
  not.

### Reading a run by hand

```sh
pubgrub aeson '<2'                     # quiet: the answer and the read counts
pubgrub -v aeson '<2'                  # + the solver's search trace
pubgrub --cabal aeson '<2'             # cabal's solver over the same index
pubgrub -v aeson '<2' | awk -f bench/summarise.awk
```

`bench/summarise.awk` turns a trace into event counts plus the **resolution-depth
histogram**. The histogram counts the `Resolving` events between a `Conflict` and its
`Learned`. A depth-16 entry is one clause learned over sixteen iterations. That
histogram is what makes collapsing work visible.

It reports three separate read counters, and they mean different things:

| counter | meaning |
| --- | --- |
| `parses` | releases whose `.cabal` was parsed. **Zero** once the derived index is built |
| `decoded` | releases decoded out of the derived index |
| `reused` | repeat lookups served from the in-memory cache |

The lookup figures STATUS.md quotes (167 against 2873 on `pandoc`) are `decoded`.

> **A warning that cost this project real numbers.** `summarise.awk` used to read those
> counters by field position. The provider's log line gained a clause, so `parses` and
> `reused` silently reported 0 for months while looking like measurements. The script
> now matches by name. **If you add a counter, add it by name.**

`+RTS -s` works on any run (the executable is built with `-rtsopts`):

```sh
pubgrub aeson '<2' +RTS -s             # allocation, max residency, GC time
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
`/usr/bin/time` is peak RSS, which includes the RTS's own overhead and fragmentation.
`maximum residency` from `+RTS -s` is the live heap as the garbage collector saw it.
STATUS.md quotes the second.

**The ~22 MB floor is unexplained**, and it is the weakest link in the strongest claim
the project has. Doubling the per-element overhead of the package-to-versions map, long
assumed to dominate it, moved the floor by 0.5%. A ratio whose numerator nobody can
account for is not evidence, however reproducible it is.

**What sits above the floor is known: the memoised reduced forms.** Residency tracks
**how many releases were read**, which is a number the solver's own strategy moves.
`pandoc` sits at 33.1 MB against the 22.7 MB floor, because the collapsing walk reads
2873 releases where the solve needs 167. That is about 3.8 KB per extra release.

The same measurement gave about 21 KB per release when a read meant a `.cabal` parse.
Record residency on every run, not only when it looks interesting.

**A timed run and a counted run are different runs.** With `-v` the trace prints to
stdout, and `aeson <2` prints thousands of lines. `bench/compare.sh` deliberately runs
with `-v`, so its elapsed times are upper bounds. If timing is the point, run without
`-v`.

**Warm the index.** The first run after a week bootstraps or refreshes the Hackage
index and rebuilds the version cache. `bench/compare.sh` does one throwaway run for
this. A `cacheFormatVersion` bump also forces one rebuild.

## Comparing against cabal

`--cabal` runs cabal's own modular solver (`cabal-install-solver`, no `cabal-install`
dependency) over **the same** opened index, installed database and `pkg-config`
database — one `Bridge.Provider.withWorld`, so a difference between the two cannot be a
difference between two reads.

Four things to keep in mind when reading a comparison.

1. **The index work is not the same work.** We decode a release when we expand a
   package. cabal's resolver wants a `SourcePackage` record for all ~153k releases
   before it starts, and it parses each one it inspects. That is most of its memory and
   some of its floor time, and it is not separated from the solve yet.
2. **cabal solves setup and build-tool dependencies and we do not** (`solveExecutables
   = True` against rung 4 unbuilt). On a package with a custom setup the two are not
   solving the same problem.
3. **cabal's plan is printed by component, and must be read that way.** cabal solves
   *qualified goals*, so a setup or executable dependency is solved in its own domain.
   `Setup.hs` can be built against a different `mtl` than the library, and one plan can
   legitimately name two versions of a package. `convCP` strips the qualifiers from the
   identities on the way out, so a flat package list will mislead you.
4. **Every flag is pinned to its declared default on both sides.** That is a
   restriction of the problem. It also perturbs cabal's goal ordering, because a manual
   flag is not *weak*, so `deferWeakFlagChoices` stops deferring the flags that
   influence dependencies.

For the explanation deliverable the comparable quantity is **length**: our proof
against cabal's message. `bench/compare.sh` prints both (`proof=` and
`cabal-log-lines=`). Over the 17-case corpus cabal's message runs 6 to 17 lines. Ours
has no bound on length yet.

**`proof=` counts by connective, not by line number.** The reporter numbers only the
conclusions it refers back to (`references/pubgrub.md:673`). In a linear derivation that
is none of them. So `summarise.awk` matches the opening words instead: `Because`,
`And because`, `So, because`, `Thus,`. The older pattern `^[0-9]+\. ` scored a 57-line
`aeson <2` proof as 9 lines.

## The one thing that is missing

Every count above is derived by **counting trace lines**, so you can have a clean
timing or the search columns, not both. A `--stats` mode that consumed `SolverMsg` into
counters and printed one summary line would fix it, and would let `bench/compare.sh`
stop running with `-v`. It does not exist.

[tasty]: https://hackage.haskell.org/package/tasty
[tasty-golden]: https://hackage.haskell.org/package/tasty-golden
