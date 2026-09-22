# The harness: a plan

> **What this is.** The plan for the harness: the command that runs both solvers over
> a problem set, repeats the timings, diffs the plans, and renders the two explanations
> side by side. Written 2026-09-03 against the tree as it stood then
> ([STATUS.md](STATUS.md) §5), and built the same day.
>
> **What this is not.** Not a specification. §6 records the choices Andrea made on
> 2026-09-03. §3 is the plan as written; §7 records what was built and where it
> differs.

---

## 1. What the harness has to produce

Two generated documents, from one command, with the caveats baked into their headers.

| deliverable | what the harness must print |
| --- | --- |
| **Benchmark report** | per problem and per solver: verdict, elapsed (index phase and solve phase separately), peak RSS, maximum residency, total allocation. Medians over repeated runs, allocation as the headline. Plus our search counts |
| **Explanation showcase** | per unsat problem: our proof and cabal's `Could not resolve dependencies:` block, next to each other, with the sentence and line counts. A summary table over the corpus |

Every header states the environment, because every number depends on it: GHC and
`base`, the pkg-config packages present and absent, the Hackage index snapshot date,
and the three restrictions STATUS.md §5 says a published number must carry. Flags are
pinned to their declared defaults on both sides. We solve one version per package
name. Setup and build-tool dependencies are unmodelled.

**What it does not do.** It does not decide whether a change is kept. That is
[`scripts/gate.sh`](../scripts/gate.sh), and it stays as it is. It does not replace
`bench/summarise.awk` as a way to read a single trace by hand.

## 2. One constraint that shapes the design

The requirement the project had stated for the comparison was "one process must run
both solvers". That cannot be literal. Peak residency and peak RSS are per-process
numbers, and the RTS reports one maximum for the whole process, so two solvers in one
process cannot be measured against each other on memory at all.

What the requirement is protecting is that both solvers see the same world. That is
already guaranteed one level down: `pubgrub` and `pubgrub --cabal` are the same
executable, and both are fed from one `Bridge.Provider.withWorld`. So the harness is
**one command that drives that executable as a child process**, once per solver, per
problem, per repetition, and reads what the child prints.

## 3. The pieces, in the order to build them

Each step leaves a runnable tree and is useful on its own.

### Step 1 — `--stats`: counted without being traced

The last open question on the list of the day, and what
[benchmarking.md](benchmarking.md) then called "the one thing that is missing". Every
count is derived by counting `-v` trace lines, so a
run cannot be both quiet and counted, and every timed run in `bench/compare.sh` pays
for rendering thousands of lines it does not need.

`app/Main.hs` already has the seam. `runApp` picks the `LogAction App SolverMsg`, and
`Normal` maps it to `mempty`. Add a third verbosity whose action folds each
`SolverMsg` into an `IORef` of counters: `Deciding`, `Chose`, `NoVersionFor`,
`Conflict`, `Resolving`, `Learned`, `Backtracked`, and the resolution-depth histogram,
which needs one bit of state (inside a resolution or not), exactly as `summarise.awk`
keeps it. The provider's read counters already exist (`lookupStats` in
`Bridge.Provider`). At the end print one line:

```
stats: deciding=309 chose=308 conflicts=58 learned=57 resolving=104 backtracked=57 noversion=1 parses=0 decoded=392 reused=20646 depth=0×40,1×9,2×5,...
```

**Acceptance.** For every problem in both sets, `pubgrub --stats` and
`pubgrub -v | awk -f bench/summarise.awk` agree on every number. Write that as a test
in `scripts/`, not in the tasty suite, because it needs the index.

**A trap.** The line must not start with `Because`, `And because`, `So, because` or
`Thus,`, and must not contain `no version for`, or the gate's proof counters will read
it.

### Step 2 — phase timings inside the child

The benchmark caveat STATUS.md §2.3 repeats is "index build is not separated from
solve". Only the child can separate them, because only it knows where the phases are.

Take `getMonotonicTime` at three points in `main`: before `withWorld`, after it
(index opened, installed db and pkg-config db read), and after the solve returns and
before the answer is rendered. On the cabal side the split is different and worth
naming: `runBaseline` builds `sourcePackageIndex` before `solveWithCabal` runs, and that
build is the "record for all ~153k releases" cost that STATUS.md §2.3 says is not
separated. Time it as its own phase. Print:

```
phases: world=0.41 index=0.00 solve=0.33 render=0.01
```

with `index` being cabal's `sourcePackageIndex` build and zero for ours.

**Acceptance.** `world + index + solve + render` is within a few percent of the
wall-clock the parent measures.

### Step 3 — a plan in a diffable shape

Today ours prints a tree and cabal's prints components. Both are for people. Add
`--plan lines`: one line per resolved package, sorted by name.

```
plan: aeson 2.2.3.0 source
plan: base 4.21.0.0 installed
```

For cabal, prefix each line with the qualifier so the domains stay apart:

```
plan: lib  mtl 2.3.1 installed
plan: setup mtl 2.2.2 source
```

The diff compares the **library** domain only, since that is the only one we solve
(STATUS.md §3.2). It reports three things: packages in one plan and not the other,
packages resolved to different versions, and cabal's non-library domains as a list,
not as a disagreement.

**Acceptance.** On the six benchmark problems the harness prints the same two plan
divergences that were found by hand when the baseline landed
([decision-log.md](decision-log.md) Era 8), and no others that are not real.

### Step 4 — the harness executable

`app/Harness.hs`, a seventh cabal component, `pubgrub-harness`. Depends on `process`,
`bridge` for the problem-file parser and nothing else new. No JSON library: the child's
output is three kinds of prefixed line (`stats:`, `phases:`, `plan:`) plus free text,
and that is a ten-line parser.

Per problem, per solver, it runs the child three times (§6), under
`/usr/bin/time -f '%e %M'` for wall-clock and peak RSS,
with `+RTS -s<file>` for allocation and maximum residency, exactly as
`bench/compare.sh` does now. The first run of the whole session is a throwaway warm-up
against the index refresh. It records, per run: verdict, wall-clock, the four phase
times, RSS, residency, allocation, stats, and the plan lines. It reports the median
of times and the single value of everything that is deterministic, and it asserts that
the deterministic values did not vary across repetitions, because if they did, the run
is not what it claims to be.

The problem sets are the two files that exist. `bench/problems.txt` feeds the
benchmark report. `bench/unsat-problems.txt` feeds the showcase. The parser is the
same three lines of `sed` logic, ported.

**Acceptance.** `cabal run pubgrub-harness` reproduces the STATUS.md §2.1 and §3.2
tables from one command, and `bench/compare.sh` can be deleted.

### Step 5 — the two reports

Markdown, because the deliverables are documents and the numbers already live in
markdown tables. Two files, written to `bench/output/` by default and never committed
from there; a run that is meant to be quoted gets copied into `docs/` deliberately.
Add `bench/output/` to `.gitignore` in the same change.

**The benchmark report** is STATUS.md §2.1 with the phases split out and the medians
labelled as medians, plus the search-count table, plus a header stating the machine,
the index snapshot date, and the three restrictions.

**The showcase** is one section per corpus problem: the target, the failure kind from
`failure-cases.md`'s table, then our proof and cabal's block as two fenced blocks, then
one line: "8 sentences against 22 lines". A summary table at the top. The header
repeats the environment.

**Four corpus problems are left out of the showcase**: `atelier-testing`,
`cabal-install`, `futhark` and `haskoin-store-data` are unsatisfiable for more than one
reason, and each solver explains whichever reason its search met first, so on those
four the two explanations are about different facts and their lengths do not compare
([failure-cases.md](failure-cases.md), "Caveats"). They stay in the corpus and the
gate. The showcase names them in its header as excluded, and why, so the count it
quotes is 13 comparable problems and not a silent subset of 17. The harness takes the
exclusion list from a marker in `bench/unsat-problems.txt`, not from a table in the
code, so the list moves with the corpus.

Side by side in a terminal is not worth doing: proofs are prose at 80 columns and two
columns of it are unreadable. Side by side in the document means adjacent, and that is
what a slide takes.

**Acceptance.** Someone who has not seen the project can read the showcase and see,
for every problem, what each solver said and which restrictions applied.

### Step 6 — retire what it replaces

`bench/compare.sh` goes. `bench/summarise.awk` stays, as the hand tool. STATUS.md §2
becomes "generated by the harness on `<date>`; see `bench/output/`", with the tables
pasted in. [benchmarking.md](benchmarking.md) loses its "one thing that is missing"
section and gains a short "running the harness" one. `scripts/gate.sh` is unchanged.

## 4. What is deliberately left out

- **Fixing `yesod`.** The harness reports it as the row where cabal wins. The
  decision-order fix is a solver change with its own trade (DESIGN.md §12) and does
  not belong in a measurement tool.
- **Explaining the 22 MB floor.** The harness measures it more carefully, with the
  world phase separated, which is a prerequisite for explaining it. It does not explain
  it.
- **Heap profiles.** `+RTS -p` runs need a profiled build. Out of scope for a tool
  whose job is to produce the report, not to diagnose it.
- **Any change to what either solver does.** If a number moves when the harness lands,
  the harness is wrong.

## 5. Risks and the guard for each

| risk | guard |
| --- | --- |
| the index refreshes between two runs of the harness | the warm-up run happens first, and the report header records the snapshot date read from `_cache/timestamp.json`. A refresh mid-run is detected by the deterministic counts varying, which the harness asserts on |
| the derived index is behind the index | the header states `parses` for every problem. Non-zero means re-run `pubgrub-index` before quoting anything |
| the proof contains a NUL byte | the harness reads `Text`. Any shell it spawns to grep gets `-a` |
| `--stats` and the awk disagree | Step 1's acceptance test, kept in `scripts/`, run before the awk is retired |
| noise read as signal | medians, allocation as the headline, and the `±25%` warning printed in the report itself |
| the gate's text parsers read the new lines | the new lines are prefixed and open with none of the connectives the gate counts. Run the gate after Step 1 |

## 6. Decisions

All decided 2026-09-03.

1. **A separate executable**, `pubgrub-harness`, not a subcommand. The measuring code
   does not sit inside the thing being measured.
2. **Three repetitions.** Each corpus problem is under 3 s, so the whole corpus on
   both sides is around six minutes. Three is enough to take a median and to see the
   deterministic counts agree; it is not enough to quote a spread, and the report
   does not.
3. **Reports go to `bench/output/`**, ignored by git. A run meant to be quoted is
   copied into `docs/` on purpose.
4. **The four reason-mismatched problems are left out of the showcase.** They stay
   in the corpus and the gate, and the showcase header names them and says why. Every
   rendered pair is then a like-for-like comparison, and the headline is 13 of 13
   rather than 17 of 17. Step 5 has the mechanism.
5. **Order as written.** Steps 1 and 2 are small and independently useful. Steps 3
   and 4 are the bulk. Step 5 is where the deliverables appear.

## 7. What was built, and where it differs from the plan

Built 2026-09-03. [`app/Harness.hs`](../app/Harness.hs) is the executable
`pubgrub-harness`. `--stats`, the `phases:` line and `--plan lines` landed in
`app/Main.hs`; `-v` and `--stats` compose. [`scripts/check-stats.sh`](../scripts/check-stats.sh)
is Step 1's acceptance test, and it passed on all 23 problems. `bench/compare.sh` was
deleted and `bench/summarise.awk` stayed. The four excluded corpus problems carry
`showcase:exclude` in their comment in `bench/unsat-problems.txt`; they are run and
measured and not rendered, and the showcase headline read "shorter on 13 of 13
comparable problems" on the 17-problem corpus of that day.

Where the build differed from §3:

- **No `lib`/`setup` qualifier on cabal's plan lines** (Step 3). A `ResolverPackage`
  carries none by the time the driver sees it, so cabal's lines have the same shape as
  ours, and a package that appears twice is reported by the diff as qualified goals
  showing through rather than as a disagreement.
- **The read counters stayed on the provider's `read N .cabal files …` line** (Step 1)
  instead of joining `stats:`. That line is printed with or without `--stats`, and the
  harness reads it by name.
- **The snapshot date is the mtime of `_cache/01-index.tar`**, not `timestamp.json`
  (§5).
- **The harness probes the driver** (`--help`) for `--stats` and `--plan`, and runs
  without them against an older build, saying so in the report's warnings.
- **Step 2's `index` phase separates less than the plan said.** cabal's
  `sourcePackageIndex` build is only the eager allocation of ~153k `SourcePackage`
  records. The `PackageIndex` itself and every `.cabal` parse are lazy and land in
  `solve`, and forcing them into `index` would make a solve pay for releases it never
  touches, which changes what is measured. So `world` is separated on both sides, and
  cabal's per-release parsing is not.
