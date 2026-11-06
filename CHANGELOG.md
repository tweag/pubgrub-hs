# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow the [Haskell PVP](https://pvp.haskell.org/), as described in
[CONTRIBUTING.md](https://github.com/tweag/pubgrub-hs/blob/main/CONTRIBUTING.md).
Every package of the repository has the version of the release; a package's own
changelog lists the changes under its directory.

## [0.1.0.0] - 2026-11-06

### Added

- VersionSet over canonical Cabal intervals
- Term type and term algebra
- Incompatibility, relations, and rule of resolution
- PartialSolution, assignments, and relation
- Satisfier search and conflict resolution
- Naive unit propagation
- Solve loop with in-memory provider scenario tests
- Derivation-tree conflict reporting
- Flatten GenericPackageDescription to dependency set
- Parse ghc-pkg boot-package list
- Hackage IO dependency provider and boot-package query
- CLI resolves a Hackage package via the solver
- Emit decision-level SolverMsg progress via co-log
- Stream solver progress to stderr via co-log sinks
- Simplify version ranges in progress output
- Stream Conflict/Backtracked events from monadic unitPropagation
- Trace conflicts and backtracks; accept a name-version target
- Locate the ghc-pkg that belongs to a given GHC
- Query a GHC executable for its version and boot packages
- Parse args with optparse-applicative; add --with-compiler
- Human-readable conflict reports
- Lattice/Boolean/Sets class hierarchy with VersionSet and Pow
- Choice/ChoiceSet and Compiler scaffolding (phase 2)
- ChoiceSet as a Sets instance (installed x source product)
- Parse ghc-pkg dump into installed package records
- Add a provider for packages in the installed package db
- Pretty instances for Choice and ChoiceSet
- Combine installed and source providers over ChoiceSet
- Solve over installed and source packages together
- Add SourceConfigSet, a set algebra over versions and flags
- Fold flags into ChoiceSet's source component
- Read dependencies from the conditional tree, keeping flag guards
- Port the PubGrub algorithm to the whole-instance model
- Run the solver in a logging monad, and feed it from a Hackage index
- Add the pubgrub driver, and warn on an unparseable .cabal
- Offer the compiler's installed packages, preferring them
- Readable conflict reports, on a symbolic InstanceSet
- Render the solution as a dependency tree, not an alphabetical list
- Emit the solver traces that were declared but never logged
- Put the solver trace behind -v, so a timed run has no terminal in it
- Make a release's depender term its version slot
- Add snapToVersions, unused while narrowing costs too much
- Run cabal's modular solver over our index as a baseline
- Print cabal's plan grouped by component
- Collapse dependers over adjacent identical releases
- Add the benchmark problem set, scripts and docs
- Skip releases whose library cannot be built here
- Fix every flag at its declared default, in both solvers
- Merge dependency facts in the store, drop the walk
- State once that a boot package cannot be built
- Render proofs with the spec's reporting algorithm
- State an unbuildable release as an incompatibility
- Name an empty dependee range once in a proof sentence
- Add a failure corpus of 17 problems from Hackage reports
- Parse the command line with optparse-applicative
- Absorb empty-range facts into the dependency they qualify
- Add scripts/gate.sh, one pass/fail check for every change
- Add a derived index, so reading a release is a decode
- Restore the generation-time neighbour walk
- State a run of same-pair chain steps as one sentence
- Add pubgrub-harness, and --stats and --plan lines to the driver
- Word proofs in pub's sentences, in cabal's range syntax
- Quote a declared range as its author wrote it
- Name the installed version in a boot package's fact
- Print a headline above the proof
- Wrap the proof in the driver, not in the reporter
- Colour the proof on a terminal
- Keep a preposition with its object, and count screen lines
- Read the index at an index-state, and pin the gate
- Compare versions with trailing zeros insignificant
- Name the missing pkg-config module in an unbuildable fact
- Solve for several targets, and skip unbuildable components
- Read foreign libraries' dependencies, gated like the rest
- Collapse a run of facts with one depender into one sentence
- Seed the solve with the request, not a synthetic root
- Add a headline line naming the package the search gave up on
- Make an automatic flag a solver variable of its own
- Build the derived index at an index-state; name the CPU
- Add constraint seeds, conflictSet and --constraint
- Carry build tools and setup-depends in Release; add a Preference
- The driver answers --version
- Build with Cabal-syntax 3.18 and cabal-install-solver 3.18
- Export releaseOf and releaseOfStored from PubGrub.Cabal.Provider
- A reduction reads a release's test suites and benchmarks when asked
- Ban only the flag value under which a library is unbuildable
- Count the clauses propagation judges, and those after a backtrack
- State the merge rule's law and hold the store to it
- **Breaking:** Propagation owns its worklist, and an insert says where the clause landed
- Eq and Show on Incompatibility, Cause, SolveError and SolverMsg
- Add mkFormatter, a Formatter from three functions
- Incompatibility, seed and fact build a clause in the shape the solver expects
- **Breaking:** A merge rule combines parts with <>

### Changed

- Refresh the Hackage index at most once a week
- Read the index in one pure pass and parse .cabal files on demand
- Cache the package-version map on disk; log through co-log
- Test the cheap half of subsumption first, and enable -rtsopts
- Compute version-set algebra on intervals, not VersionRange syntax
- Index the partial solution by package, and cache each package's term
- Pin an installed unit's whole closure, not just its direct deps
- Emit one incompatibility per guarded dependency, not per instance
- **Breaking:** Split the solver and its cabal domain into the pubgrub and pubgrub-cabal packages
- Compute a version's normal form once, at mkVersion
- Subset and disjointness tests that build no set
- The store keeps each clause's merge key beside it
- Find the merge target in one pass over keys and clauses
- Judge a clause by a strict fold over its terms
- Propagation judges the dirty clauses and acts on the newest
- Key the derived index by tar block, one entry per release
- Decode a stored release's test suites and benchmarks only when forced
- **Breaking:** Export the API and none of the solver's machinery
- **Breaking:** Re-export the SetOps class from PubGrub, not its methods
- INLINABLE on every function that takes a domain dictionary
- Re-judge the moved variables' clauses after a backtrack, not the store
- **Breaking:** The domain is the variable type, not a phantom

### Fixed

- Drop redundant foldl' import (now in Prelude)
- Call checkForUpdates so the index is readable before withIndex
- Add text dependency to executable (Solver uses Data.Text)
- ToVersionRange no longer appends spurious '|| noVersion'
- Name ghc-pkg, not the compiler, when ghc-pkg cannot be run
- Reject a ghc-pkg whose global db lists no base
- Number conflict-report steps; rebuild a stale version cache
- Clearer conflict reports for boot packages and derivation steps
- List installed unit-ids in ChoiceSet rendering
- Pick a flag assignment from the offered set's cells
- Three-state flag pins, and subsumption pruning to pay for them
- Prefer default flag assignments, and revise the flag spec
- Constrain the baseline's boot packages to installed ones
- Never build a non-reinstallable package from source
- Give cabal's solver the machine's pkg-config database
- Explain an exhausted unbuildable range
- Drop a package's dependency on itself
- Explain why a boot package has no source instance
- Count the no-version trace line by its current wording
- Drop greencard from the build-tools allowlist
- Give a test pattern to the tasty suites only
- **Breaking:** Check the seeds and the provider's value at the boundary
- Ban the rest of the set when the reasons name other variables
- Send the Cache-Control headers hackage-security asks for
- Drop installed edges between two units of one package
- Bold the connective of a numbered line that opens with "Because"
- Index a repeated unit id once, by name as by id
- Name a problem's logs without a trailing "-"
- Stop calling --flags search a spike, and name the pin in the harness warning
- Rule out a release whose dependency on itself excludes it

[0.1.0.0]: https://github.com/tweag/pubgrub-hs/releases/tag/v0.1.0.0

<!-- generated by git-cliff -->
