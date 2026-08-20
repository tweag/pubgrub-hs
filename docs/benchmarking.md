# Running the tests and the benchmarks

How to reproduce every number in [STATUS.md](STATUS.md), and what each one is worth.
The short version:

```sh
cabal test                    # 136 unit, property and golden tests, ~0.3 s
bench/compare.sh              # both solvers over bench/problems.txt
```

> **The current figures are STATUS.md's "Merge on insert"** (2026-08-17, the last
> measurement section in that file). Every table above it there is dated and against
> the tree of its own date — read those for how the project got here, not for what
> the solver does now.

---

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

Two groups repay knowing about:

- **`InstanceSet`** — differential properties comparing the real set type against an
  extensional model over a small fixed universe. It found three real bugs the first
  time it ran, and a fourth when its universe was fixed. If you touch the set algebra,
  this is the guard. Its "size control" case is the one that pins cell-count growth
  (28293 cells unpruned against 41 pruned, for a denotation of 56 instances).
- **`PubGrub paper examples`** — the six worked examples from
  [`references/pubgrub.md`](../references/pubgrub.md). The four satisfiable ones assert
  the solution the spec reports; the two unsatisfiable ones assert the **rendered
  proof**, against the wording the spec publishes at `:1005` and `:1150`. A change to
  report wording shows up here first, and should.

### Golden tests, and how to update them

The two proofs are [tasty-golden] tests: the expected output is a file under
[`test/golden/`](../test/golden), one per case, so it reads as the proof a user would
see rather than as a list of string literals. A failure prints the actual proof in
full.

```sh
cabal test --test-options=--accept       # rewrite the golden files from the run
```

Use `--accept` when the wording changed **on purpose**, and read the resulting `jj
diff` as the review of that change — it is the only place the report's output is
pinned. Do not reach for it to make a red suite green: these two files are the
closest thing the reporter has to a conformance test against the spec.

There is no golden test for the *real* solver's output on Hackage problems — that
would pin an index that moves. Those numbers are measured by hand and recorded in
STATUS.md.

## Benchmarks

```sh
bench/compare.sh                  # the whole set, both solvers
bench/compare.sh aeson '<2'       # one problem
OUT=/tmp/bench bench/compare.sh   # keep the logs
TIMEOUT=60 bench/compare.sh       # give up sooner (default 300 s)
```

It prints, per problem and per solver: verdict, elapsed, peak RSS, GC max residency,
total allocation, and — for our solver — the trace-derived counts and proof length.
Logs, RTS stats and timings for each run are left in `$OUT`.

The problem set is [`bench/problems.txt`](../bench/problems.txt), one problem per line,
with a note on each. **The distinction that matters is between the two kinds**: `vector`
and `pandoc` measure index throughput and cannot show a search improvement (`pandoc`
has exactly one conflict), while `conduit <1.3`, `lens <4` and `aeson <2` are where the
search is. A change that helps only the first two, or only the last three, is not a
change that helps — check both.

### Reading a run by hand

```sh
pubgrub aeson '<2'                     # quiet: the answer, the read counts, nothing else
pubgrub -v aeson '<2'                  # + the solver's search trace
pubgrub --cabal aeson '<2'             # cabal's solver over the same index
pubgrub -v aeson '<2' | awk -f bench/summarise.awk
```

`bench/summarise.awk` turns a trace into event counts plus the **resolution-depth
histogram** — `Resolving` events between a `Conflict` and its `Learned`, so a depth-16
entry is one clause being learned over sixteen iterations. That histogram is what makes
collapsing work visible; see STATUS.md's "Generation-time depender collapsing".

`+RTS -s` works on any run (the executable is built with `-rtsopts` for exactly this):

```sh
pubgrub aeson '<2' +RTS -s             # allocation, max residency, GC time
pubgrub aeson '<2' +RTS -s -h          # heap profile, if you have built for profiling
```

## Which numbers to trust

**Counts are deterministic; times are not.** Decisions, conflicts, backjumps,
no-version events, `.cabal` reads and proof length are the same on every run of the
same code, so a difference in any of them is a real difference. Compare those.

**Elapsed time on a desktop moves by ±25%.** Four runs of `aeson <2` at one commit came
in at 5.2, 6.5, 6.9 and 7.8 s; the same binary doing identical work has been seen at
4.23 s and 6.13 s. Never conclude from a single pair of timings.

**Total allocation is the stable stand-in for time.** `+RTS -s` reports it, it barely
varies between runs, and it caught a 3.9% regression that wall-clock could not resolve.
Use it to decide whether a change costs anything.

**Peak memory has two numbers and they mean different things.** `%M` from
`/usr/bin/time` is peak RSS, which includes the RTS's own overhead and fragmentation;
`maximum residency` from `+RTS -s` is the live heap as the GC saw it. STATUS.md quotes
the second. **What the ~22 MB floor actually consists of is unestablished** — doubling
the per-element overhead of the package→versions map, long assumed to dominate it,
moved it by 0.5%. STATUS.md now does quote a memory comparison against cabal (2.2–3.5×
on the five problems), so settling this has gone from housekeeping to the weakest link
in the strongest claim the project has: a ratio whose numerator is a number nobody can
account for is not evidence, however reproducible it is.

**What sits *above* the floor is known, and it is the memoised reduced forms** —
about 21 KB per parsed release. The evidence is a regression and its removal:
generation-time collapsing took `pandoc` from 167 reads to 2871 and its residency
from 22.9 MB to 81.0, and dropping that walk took both back (167 reads, 22.6 MB).
Residency therefore tracks **how many releases were parsed**, which is a number the
solver's own strategy moves — so record it on every run, not only when it looks
interesting.

**A timed run and a counted run are different runs.** With `-v` the trace renders to
stdout — `aeson <2` prints thousands of lines — so `bench/compare.sh` deliberately runs
with `-v` and its elapsed times are upper bounds. Time without `-v` when timing is the
point.

**Warm the index.** The first run after a week bootstraps or refreshes the Hackage
index and rebuilds the version cache; `bench/compare.sh` does one throwaway run for
this. A `cacheFormatVersion` bump also forces one rebuild.

## Comparing against cabal

`--cabal` runs cabal's own modular solver (`cabal-install-solver`, no `cabal-install`
dependency) over **the same** opened index and installed db — one
`Bridge.Provider.withWorld`, so a difference between the two cannot be a difference
between two reads. See `Bridge.Cabal.Baseline`.

Three things to keep in mind when reading a comparison:

1. **The index work is not the same work.** Ours parses a `.cabal` only when it expands
   a package; cabal's resolver wants a `SourcePackage` record for all ~152k releases
   before it starts. That is most of its memory and some of its floor time, and it is
   not separated from the solve yet.
2. **cabal solves setup and build-tool depends and we do not** (`solveExecutables =
   True` against rung 4 unbuilt), so on a package with a custom setup the two are not
   solving the same problem. Its plan will carry `Cabal`, `directory`, `process` and
   friends; ours will not.
3. **cabal's plan is printed by component, and must be read that way.** cabal solves
   *qualified goals*: a setup or executable dependency is solved in its own domain, so
   `Setup.hs` may be built against a different `mtl` than the library and one plan can
   legitimately name two versions of a package. `convCP` strips the qualifiers from the
   identities on the way out, so a flat package list will mislead you — the `setup:`
   lines are the other domain.

For the explanation deliverable, the comparable quantity is **length**: our proof
against cabal's message. `bench/compare.sh` prints both (`proof=` and
`cabal-log-lines=`). cabal's stays at 16–30 lines whatever the problem, because it
reports the search rather than a derivation; ours has no bound on length yet.

**`proof=` counts by connective, not by line number.** The reporter numbers only the
conclusions it refers back to (`references/pubgrub.md:596`), which in a linear
derivation is none of them, so `summarise.awk` matches the opening words instead
(`Because`, `And because`, `So, because`, `Thus,`). The older pattern
`^[0-9]+\. ` scored a 57-line `aeson <2` proof as 9 lines. If the reporter's wording
changes, that pattern is what has to change with it.

## The one thing that is missing

Every count above is derived by **counting trace lines**, so you can have a clean
timing or the search columns, not both. A `--stats` mode that consumed `SolverMsg` into
counters and printed one summary line would fix it, and would let `bench/compare.sh`
stop running with `-v`. It does not exist.

[tasty]: https://hackage.haskell.org/package/tasty
[tasty-golden]: https://hackage.haskell.org/package/tasty-golden
