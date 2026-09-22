# PubGrub: A Dependency Solver for Haskell Packages

> **What this is.** A tutorial introduction to the PubGrub algorithm, and the gentlest
> starting point in the repository.
>
> **What decides.** `references/pubgrub.md` is the authority on the algorithm. Where
> this file and the spec disagree, the spec is right. This file exists to make the spec
> readable, not to replace it.
>
> **What it does not cover.** Flags and the instance model, which are the parts that
> took the most work. Those are [flags-semantics.md](flags-semantics.md) and
> [decision-semantics.md](decision-semantics.md). For the current state of the code,
> see [STATUS.md](STATUS.md).

This document introduces the PubGrub version-solving algorithm and how this project implements it. All examples use Cabal package names and PVP version syntax. The goal is enough precision to drive implementation, not a formal proof.

---

## 1. What Is a Dependency Solver?

When you run `cabal install`, Cabal must find a single version for every package in the transitive dependency closure such that all constraints are satisfied simultaneously. When it fails, you get output like:

```
Resolving dependencies...
cabal: Could not resolve dependencies:
• aeson-2.2.1.0 requires text ^>=2.0
• servant-0.20.1 requires text ^>=1.2
```

Two packages, each requiring an incompatible range of `text`. No assignment of a single version to `text` satisfies both constraints.

The naive approach — enumerate every combination of versions and test consistency — is exponential in the number of packages. A real solver must learn from conflicts: when a combination fails, record *why* it failed so the same dead end is never explored again. This is what PubGrub does.

**PubGrub's contract:** given a set of targets and an oracle that can fetch dependencies on demand, return either:
- a `Map PackageName Version` assigning exactly one version to every required package, or
- a human-readable derivation tree explaining why no such assignment exists.

> **Scope note.** Cabal already ships its own solver. This project reimplements
> PubGrub — the algorithm used by Dart's `pub` and Python's `uv` — as a proof of
> concept. Its two questions are **explanation quality** and **performance** against
> cabal-install's solver.

---

## 2. The Interface

Two abstractions anchor the algorithm, and one callback connects it to the world.

**Values.** The solver's variables are package names. Its values are whatever the
provider hands back. In this project a value is an `Instance` — one concrete way of
having a package, either a pre-installed unit or a source release under a total flag
assignment.

**Value sets.** The algebra needs four operations plus an emptiness test:
`intersect`, `union`, `difference`, `isEmpty`. It needs **no complement**. A complement
requires a universe of values that nothing in the algorithm ever asks for, and negation
is needed in exactly one place — `Term`, where it is a polarity flip.

```haskell
class SetOps a where
  intersect  :: a -> a -> a
  union      :: a -> a -> a
  difference :: a -> a -> a
  isEmpty    :: a -> Bool
```

**The provider** is one callback:

```haskell
newtype Provider m = Provider
  { expand :: PackageName -> InstanceSet -> m (Maybe Instance, [Incompatibility]) }
```

Given a package and the accumulated constraint on it, commit to one instance and report
the incompatibilities that decision entails, in one atomic step.

Four points about it:

1. It receives the *intersection* of all current constraints on the package. The solver
   has already narrowed the set.
2. The returned instance **must** be a member of that set. This is a precondition, not
   a hint.
3. Correctness does not depend on *which* member. PubGrub finds the solution, or proves
   there is none, whatever valid instance comes back. The choice affects performance
   only. "Newest satisfying" is standard because it minimises conflicts with other
   packages that also want recent releases.
4. The incompatibility list sits **outside** the `Maybe` deliberately. A provider that
   skips releases it cannot use must be able to answer "no decision, and here is what I
   learned".

The choice and its consequences always travel together, so the solver never holds one
without the other. The reference Rust implementation keeps them as two methods, and
splitting ours back is an open question ([flags-semantics.md](flags-semantics.md) §8).

> **PVP vs SemVer.** Cabal uses the [Package Versioning Policy](https://pvp.haskell.org/). In PVP, `^>=1.2` means `>= 1.2 && < 1.3` — the two *leftmost* version components form the major version. This differs from SemVer's `^1.2`, which means `>= 1.2.0 && < 2.0.0`. Be careful when reading Cargo or npm documentation: their version range semantics differ.

---

## 3. Terms — The Logical Building Block

A **term** pairs a package with a version-set assertion. Every constraint in the solver is expressed as a term.

```haskell
data Term vs
  = Positive vs   -- the selected version must lie within vs
  | Negative vs   -- the package is absent, or its version lies outside vs
  deriving (Eq, Show)
```

The four canonical cases:

| Term | Meaning |
|------|---------|
| `Positive r` | A version in `r` is selected |
| `Negative r` | No version, or a version outside `r`, is selected |
| `Positive empty` | Always false — no version satisfies an empty range |
| `Negative empty` | Always true — every assignment satisfies this |

Two operations are used throughout the algorithm:

```haskell
-- Does t2 imply t1? (Is t2 at least as constraining as t1?)
satisfies :: VersionSet vs => Term vs -> Term vs -> Bool

-- Combine two terms for the same package (logical AND).
intersectTerms :: VersionSet vs => Term vs -> Term vs -> Term vs
```

> **Satisfaction direction — easy to get backwards.**
> T₁ is *satisfied by* T₂ when T₂ ⊆ T₁, meaning T₂ is *more specific* than T₁.
>
> Example: if we know `text` is constrained to `¬[^>=1.0 || ^>=2.0]` (outside both ranges), that implies it is also outside `^>=1.0` alone. So `Negative (^>=1.0 || ^>=2.0)` satisfies `Negative (^>=1.0)`. The bigger exclusion zone implies the smaller one.

The intersection rules follow from the logical identities:

```
Positive r₁  ∧  Positive r₂  =  Positive (r₁ ∩ r₂)
Positive r₁  ∧  Negative r₂  =  Positive (r₁ ∩ complement r₂)
Negative r₁  ∧  Negative r₂  =  Negative (r₁ ∪ r₂)
```

*Lives in: [`src/PubGrub/Term.hs`](../src/PubGrub/Term.hs)*

---

## 4. Incompatibilities — Encoding Constraints as Nogoods

An **incompatibility** is a set of terms (at most one per package) that cannot all be true simultaneously. In any valid solution, at least one term in an incompatibility must be false.

In SAT solving this would be called a *clause*. In Answer Set Programming it is a *nogood*. PubGrub uses the word incompatibility throughout.

```haskell
data IncompatCause
  = CauseRequest PackageName InstanceSet
  | CauseNoInstances PackageName InstanceSet
  | CauseOnlyInstalled PackageName
  | CauseUnbuildable PackageName InstanceSet (NonEmpty UnbuildableReason)
  | CauseDependency PackageName InstanceSet (PackageName, InstanceSet)
  | CauseDerivedFrom Incompatibility Incompatibility

data Incompatibility p vs = Incompatibility
  { terms :: Map p (Term vs)
  , cause :: IncompatCause p vs
  }
```

### Three canonical forms

**1. Request seed**

```
{ foo: Negative (>=1 && <2) }
```

Reads: "it is impossible for foo to be outside `>=1 && <2`", which forces `foo` into
the plan at a version in that range. One per target (`references/pubgrub.md:252`).
These are the first incompatibilities added to every solve. Each is immediately a
unit clause, so it forces the target into the plan.

Note the term is `Negative` of the **singleton**, not of the empty set. `Negative empty`
is the always-true term, which would make the clause vacuous.

**2. Dependency incompatibility**

Suppose `aeson-2.2.1.0` depends on `text ^>=2.0`. This is encoded as:

```
{ aeson: Positive (^>=2.2), text: Negative (^>=2.0) }
```

Reads: "it is impossible that aeson is selected in range `^>=2.2` AND text is NOT selected in range `^>=2.0`." In other words: if aeson 2.2.x is chosen, text must satisfy `^>=2.0`.

More precisely, for a specific version `v` of `aeson`:

```
{ aeson: Positive {v}, text: Negative (^>=2.0) }
```

Adjacent versions with identical dependency ranges are collapsed into a single
incompatibility covering the whole range. The spec **requires** this
(`references/pubgrub.md:456`). It is not an optimisation you can skip. See
[collapsing.md](collapsing.md) for how this project does it.

**3. Conflict-derived incompatibility**

Created during conflict resolution (§6.2) when the solver detects a contradiction and applies the Rule of Resolution to two existing incompatibilities. These carry a `CauseDerivedFrom` cause for error reporting (§7). Every other constructor is a **leaf**: a fact about the world rather than a step of reasoning.

### Special case: unit incompatibility

An incompatibility with a single term `{ p: Positive r }` bans all versions of `p` in range `r`. This arises when `expand` returns no instance (§6.3). The solver creates `{ p: Positive currentRange }` and re-enters conflict resolution to learn why `p` has no valid version.

*Lives in: [`src/PubGrub/Incompatibility.hs`](../src/PubGrub/Incompatibility.hs)*

---

## 5. The Partial Solution — State of the Solver

The **partial solution** is everything the solver currently believes about the package
selection: an ordered sequence of assignments, oldest first.

```haskell
data AssignmentKind
  = Decided Instance                     -- a guess
  | Derived (Term InstanceSet) Incompatibility   -- a consequence, and its cause
```

**Decisions** are guesses: "let us try this instance of `p`." Each decision increments a
monotone counter, the decision level. A decision is equivalent to the term
`Positive {that instance}`.

**Derivations** are consequences: "package `p` must satisfy range `r`, because incompatibility `i` forced it." Multiple derivations for the same package accumulate — their effective constraint is the intersection of all their terms.

Because a Decision can be treated as the term `Positive {v}`, both assignment kinds participate identically in the satisfiability checks used by unit propagation. The distinction only matters during conflict resolution, which needs to know "was this a guess or a consequence, and at what decision level?"

**Backtracking** discards everything after a target decision level. The solver is then
in a consistent state from before the problematic guess.

*Lives in: [`src/PubGrub/Solver.hs`](../src/PubGrub/Solver.hs). Note the real structure
is indexed by package name rather than being a flat list, and it caches each package's
accumulated term. That change made the solver 3.7–4.5× faster, and backtracking has to
rebuild the caches.*

---

## 6. The Three Algorithms

### 6.1 Unit Propagation

Unit propagation scans the known incompatibilities and deduces new constraints from the current partial solution.

For each incompatibility, count how many of its terms are *not* satisfied by the partial solution:

- **Zero unsatisfied** — all terms hold: this is a contradiction. Pass the incompatibility to conflict resolution and stop.
- **Exactly one unsatisfied** — all other terms hold. The unsatisfied term must be false to keep the incompatibility from becoming a contradiction. Add a derivation negating that term and restart the scan.
- **Two or more unsatisfied** — not yet actionable. Move on.

Repeat until a fixpoint (no new derivations, no conflict).

```haskell
unitPropagate
  :: (Package p, VersionSet vs)
  => [Incompatibility p vs]
  -> PartialSolution p vs
  -> Either (Incompatibility p vs) (PartialSolution p vs)
```

> **Implementation note.** A naïve O(|incompatibilities|²) fixpoint loop is correct. The Rust reference uses a watched-literals scheme for O(1) amortised re-checks, but that is an optimisation, not a correctness concern. Start simple.

### 6.2 Conflict Resolution

When unit propagation finds a fully-satisfied incompatibility, conflict resolution determines *why* the conflict happened and what the earliest safe backtrack point is.

**Key definitions:**

- **Satisfier of term T:** the earliest assignment in the partial solution that, when added, first made T true. Found by scanning from oldest to newest.
- **Previous satisfier level:** the decision level of the partial solution at the moment *just before* the satisfier was added. This is the level we will backtrack to.

> **Off-by-one warning.** Previous satisfier level is the level *before* the satisfier, not the satisfier's own decision level. Getting this wrong is the most common bug in conflict resolution implementations.

**The loop:** while the satisfier of the "pivoting" term is a Derivation and has the same decision level as the previous satisfier level:

1. Apply the **Rule of Resolution** to merge the current incompatibility with the satisfier's cause:

   From `{ p: t₁, …rest₁ }` and `{ p: t₂, …rest₂ }`:

   ```
   resolvent = { …rest₁, …rest₂, p: t₁ ∪ t₂ }
   ```

   If `t₁ ∪ t₂ = Negative empty` (always true), the term for `p` contributes nothing and is dropped from the resolvent.

2. Replace the current incompatibility with the resolvent and loop.

**When the loop exits:** backtrack the partial solution to `previousSatisfierLevel`, add the root-cause incompatibility to the global list, and re-enter unit propagation. The new incompatibility is a unit clause that will immediately derive a constraint preventing the same conflict.

```haskell
conflictResolution
  :: (Package p, VersionSet vs)
  => Incompatibility p vs          -- the conflict
  -> [Incompatibility p vs]        -- all known incompatibilities
  -> PartialSolution p vs
  -> (Int, Incompatibility p vs)   -- (backtrack level, root cause)
```

> **Why resolution works.** Each application of the Rule of Resolution replaces a derivation-caused assignment with the logical combination of the two incompatibilities that produced it. Working backwards through the derivation chain eventually reaches either a Decision (which gives us the backtrack target) or an external incompatibility (which gives us a root cause that does not involve any guess). Once we stop, the root-cause incompatibility is guaranteed to prevent the same path from being explored again.

### 6.3 Decision Making

After unit propagation completes without conflict, the solver chooses a new package to commit to.

1. Find a package `p` that has a positive derivation (the solver knows it must be selected) but no Decision yet.
2. Compute the current allowed range for `p` (intersection of all derivation terms).
3. Call `expand provider p allowedSet`. It answers with an instance or nothing, **and** with the incompatibilities it learned on the way. The two travel together.
   - If it answers no instance: add `{ p: Positive allowedSet }` as a new incompatibility, which bans the whole set, and re-enter conflict resolution. This is required for completeness. Without it the solver can loop indefinitely on an unsatisfiable constraint.
   - If it answers an instance: record a decision for it, add the returned incompatibilities, and return to unit propagation.

The incompatibilities it returns are the instance's dependencies, one per dependency entry `(q, range)`:

```
{ p: Positive {the slot of v}, q: Negative range }
```

The depender term is the release's **slot**, not the single version. That is
`references/pubgrub.md:456`'s adjacent-version collapsing, and
[collapsing.md](collapsing.md) explains it.

> **Lazy loading.** `expand` is called only when a package is actually decided. The solver never loads the full dependency graph up front. This is what makes PubGrub tractable for a registry the size of Hackage.
>
> **Facts can arrive without a decision.** The list sits outside the answer, so a provider that skips releases it cannot use can still report why. That is how a proof says `foo >=2.0.0 needs pkg-config package libfoo, which is not found` instead of `no version for foo in >=2`.

### The Main Loop

```haskell
solve :: Provider m -> [Incompatibility] -> m (Either SolveError Solution)
solve provider seeds = go (insertClauses seeds emptyStore)
  where
    -- each seed is { p: Negative R }, cause CauseRequest: one per target
    go store = do
      -- propagate; conflict resolution runs inside on a conflict
      -- then pick an undecided package and call expand
      -- until every positive term is decided, or a conflict rests on the
      -- seeds alone, which is failure
```

*Lives in: [`src/PubGrub/Solver.hs`](../src/PubGrub/Solver.hs)*

---

## 7. Error Reporting — The Derivation Tree

Because every derived incompatibility carries its two parents in `CauseDerivedFrom`, the final conflict is the root of a DAG traceable back to the original dependency facts. This is what allows PubGrub to produce messages like:

> Because `aeson ^>=2.2` requires `text ^>=2.0` and `servant 0.20` requires `text ^>=1.2`, `aeson ^>=2.2` and `servant 0.20` are incompatible.

```haskell
reportConflict :: Incompatibility -> [Text]
```

The printer walks the DAG:

- **a leaf** is a fact about the world. `CauseDependency` prints "X depends on Y in range R". `CauseNoInstances` prints "no version for Y in R". `CauseOnlyInstalled` prints "Y cannot be built from source". `CauseUnbuildable` prints "Y needs pkg-config package M, which is not found", or "Y is marked buildable: False".
- **`CauseRequest`** is a seed, and prints "foo >=1 && <2 is requested". It is the last fact of every proof: a terminal conflict is resolved against the seeds it rests on, so the last line reads "So, because …, version solving failed".
- **`CauseDerivedFrom`** prints "Because [cause 1] and [cause 2], [this conclusion]".

> **Deduplication.** The derivation structure is a DAG, not a tree, so the same incompatibility can be a parent of several nodes. A printer that recurses naively repeats large subtrees. Give a line number to any incompatibility referenced more than once, and replace repeated expansions with a back-reference.

**The real reporter does more than this.** It follows the spec's own reporting algorithm (`references/pubgrub.md:504`), which fuses chains, skips every other derived step, states a run of steps once, and absorbs empty-range leaves. That is what takes a proof from hundreds of lines to a handful. See [DESIGN.md](DESIGN.md) §9.

*Lives in: [`src/PubGrub/Report.hs`](../src/PubGrub/Report.hs)*

---

## 8. Why PubGrub is not a SAT or ASP instance

PubGrub is an instance of **Conflict-Driven NoGood Learning**, the core algorithm in
modern SAT and Answer Set Programming solvers. The vocabulary maps directly:

| CDNL term | PubGrub term |
| --- | --- |
| Boolean variable | package, with a value set |
| Nogood | incompatibility |
| Unit propagation | unit propagation (§6.1) |
| Conflict analysis | conflict resolution (§6.2) |
| Decision | decision (§5, §6.3) |
| Learned clause | derived incompatibility (§4) |
| Answer set | the resolved plan |

**Four features separate it from a plain encoding**, and `references/pubgrub.md:1165`
lists them. Each one is a reason not to reach for an off-the-shelf solver.

1. **Version ranges.** A package's version space is potentially unbounded, and a range
   represents a whole interval without enumerating it. Expanding ranges into concrete
   version sets costs work *and* has to be undone again to talk to a user. This is why
   our set type is intensional — see [DESIGN.md](DESIGN.md) §2.
2. **Lazy formulas.** In a standard encoding all clauses are stated before solving
   begins. PubGrub adds dependency incompatibilities on demand, as releases are
   decided. For a registry the size of Hackage, loading every dependency of every
   release up front would be prohibitive.
3. **Implicit mutual exclusivity.** A package has exactly one version in a valid
   solution. Encoding that in Boolean SAT needs O(n²) "at most one" clauses per
   package. PubGrub gets it for free: a decision sets a singleton positive term, and a
   second decision for the same package conflicts immediately.
4. **Error reporting.** A general solver explains unsatisfiability in terms of its own
   internal encoding. PubGrub's derivation tree is in terms of package dependency
   chains, which is the half of this project's thesis that a SAT encoding cannot
   deliver.

> **There is no ASP component in this project, and there never was.** An early plan to
> encode solving for Clingo was dropped before any code was written. See
> [attic/README.md](attic/README.md) §1.

---

## 9. Where the code is

For the current layout, the rung ladder and the invariants, read
[`../CLAUDE.md`](../CLAUDE.md). For what is built, what is specified and what is open,
read [STATUS.md](STATUS.md).

---


## 10. Comparison to the Cabal Modular Solver

Cabal ships its own dependency solver, first described by Andres Löh and Duncan Coutts at the Haskell Implementors' Workshop 2011. Understanding its design clarifies what PubGrub does differently and why.

### The Modular Solver's Architecture

The modular solver represents the search space as an explicit lazy tree and then passes that tree through a **pipeline of independent transformations**:

```haskell
solve cfg idx userPrefs userConstraints userGoals =
  explorePhase    $
  heuristicsPhase $
  preferencesPhase $
  validationPhase  $
  prunePhase       $
  buildPhase
```

Each phase is a pure `Tree a -> Tree a` function. Adding a new preference or heuristic is just writing another pass — this is the source of the "modular" name. The design is inspired by Nordin & Tolmach (2001), *Modular Lazy Search for Constraint Satisfaction Problems*.

The tree itself is defined as:

```haskell
data Tree a
  = PChoice    QPN  a (PSQ I       (Tree a))  -- pick a package instance
  | FChoice    QFN  a Bool (PSQ Bool (Tree a)) -- pick a boolean flag value
  | GoalChoice      (PSQ OpenGoal  (Tree a))  -- pick which goal to solve next
  | Done       RevDepMap                       -- solution found
  | Fail       (ConflictSet QPN) FailReason    -- explicit failure
```

Nodes represent choices. Edges represent assignments. This is **not** the dependency tree — it is the solver's search tree, built lazily so that validation and pruning passes only materialise nodes they actually visit.

PubGrub has **no explicit search tree**. Its state is a flat partial solution plus a set of incompatibilities. The "tree" is implicit in the sequence of decisions and derivations.

### Conflict Handling: Backjumping vs Clause Learning

This is the most important algorithmic difference.

**Modular solver — backjumping.** Every `Fail` node carries a `ConflictSet`: the set of past choice points (package names) that contributed to the conflict. When the solver backtracks, it propagates the conflict set upward through the tree. If an ancestor choice node is *not* in the conflict set, all its remaining branches are pruned immediately — there is no point exploring them, because the failure did not involve that choice. The solver jumps over them in one step.

However, the conflict set is **discarded once backtracking completes**. No new constraint is recorded in the global knowledge base. If the same dead end can be reached by a different path, it will be explored again from scratch.

**PubGrub — clause learning.** When conflict resolution terminates, the derived root-cause incompatibility is **permanently added** to the global incompatibility list. It is a new constraint that will be active for the rest of the solve. Unit propagation will fire on it immediately after backtracking, preventing the solver from ever entering the same region of the search space regardless of how it got there.

In formal terms: backjumping is **non-chronological backtracking** with local pruning. Clause learning is **non-chronological backtracking with global pruning**. Clause learning subsumes backjumping — every conflict set can be derived from the learned clause — and is strictly more powerful for hard instances with many interacting constraints.

The trade-off is implementation complexity: clause learning requires the Rule of Resolution and the satisfier/previous-satisfier machinery (§6.2). Backjumping only needs to track which packages caused each failure.

### Search Strategy and Ordering

The modular solver explores depth-first, left-to-right. The order of branches matters, and the preferences and heuristics phases reorder subtrees before exploration begins. Two standard heuristics:

- **Prefer later versions** (reorder `PChoice` children newest-first).
- **Prefer goals with fewer valid choices** (the "fail-first" principle: resolve packages with tighter constraints earlier to surface conflicts sooner).

PubGrub is also effectively depth-first, because it commits to one instance at a time. The order is encoded in the provider. There is no explicit reordering pass: `expand` returns whichever instance it considers best. The effect is the same as the modular solver's, and the mechanism is different — a single callback rather than a composable tree transformation.

### Haskell-Specific Features

The modular solver handles two features of the Cabal dependency problem that the basic PubGrub specification does not:

**Boolean flags.** Cabal `.cabal` files can declare conditional dependencies gated on boolean flags (for example, `flag use-bytestring-builder`). The modular solver interleaves flag decisions with package decisions.

PubGrub as specified treats dependencies as unconditional. Handling flags needs either a pre-expansion of every flag combination, or a richer value domain. This project takes the second option: a solver variable's value is an *instance*, which is a version together with a total flag assignment. [flags-semantics.md](flags-semantics.md) specifies what that costs and requires.

Note that flags are **not currently searched**. Every flag takes its declared default, so a release has exactly one instance. See [STATUS.md](STATUS.md) §3.1.

**Installed against new instances.** The modular solver distinguishes packages already installed in the GHC package database from new packages to be downloaded, and it prefers installed instances. Our provider does the same, in `expand`. The distinction is not built into the algorithm: it lives entirely in the provider, which is where an `Instance` can be a pre-installed unit.

**The destructive-update problem.** The old, pre-modular Cabal solver never backtracks. It resolves packages greedily and can produce install plans that overwrite installed packages, replacing `A-1` with `A-2` even though other installed packages need `A-1`. The modular solver detects and refuses such plans.

PubGrub has no built-in notion of this either, and it does not need one here. Our provider reads the installed database, offers installed units as instances, and pins an installed unit's whole closure to the exact units it was built against. A plan that overwrites an installed package therefore cannot be constructed.

### Error Reporting

The modular solver's approach: accumulate a trace of every decision and its rationale. Error messages are excerpts of that trace with irrelevant steps removed, guided by conflict sets. As Löh noted, "all the information is there" but the presentation is not yet polished.

PubGrub's approach: the derivation tree is structurally embedded in the `IncompatCause` of each derived incompatibility. Rendering it is a pure recursive function over the tree structure (§7). The output takes the form of a logical proof: "Because X requires Y and Z requires ¬Y, X and Z are incompatible." This structure is always available regardless of how complex the conflict was.

Both approaches aim at the same goal. PubGrub's advantage is that the derivation tree is a first-class value produced by the algorithm itself, not a post-hoc reconstruction from logs.

### Summary Table

| Property | Old solver (pre-2011) | Modular solver | PubGrub |
|---|---|---|---|
| Backtracking | None | Backjumping (configurable limit) | Clause learning (always) |
| Conflict knowledge | Discarded | Discarded after jump | Permanently retained |
| Search structure | Greedy, linear | Explicit lazy tree | Implicit (partial solution) |
| Boolean flags | Yes | Yes (FChoice nodes) | Not in base spec |
| Installed packages | Yes | Yes (preferred) | Yes, through the provider |
| Modularity | Low | High (pipeline of passes) | Medium (single provider callback) |
| Error messages | Poor | Good (trace-based) | Principled (derivation tree) |
| Inspiration | Ad-hoc | Modular Lazy Search (2001) | CDNL / ASP (2012) |

*Reference: Löh, Coutts, "A new, modular dependency solver for cabal-install", HIW 2011. <https://wiki.haskell.org/wikiupload/b/b4/HIW2011-Talk-Loeh.pdf>*

---

## References

- PubGrub algorithm specification: <https://github.com/dart-lang/pub/blob/master/doc/solver.md>
- PubGrub internals guide: <https://pubgrub-rs-guide.pages.dev/internals/intro>
- Reference Rust implementation: <https://github.com/pubgrub-rs/pubgrub>
- Rust crate docs: <https://docs.rs/pubgrub/latest/pubgrub/>
- CDNL and ASP: Gebser, Kaufmann, Schaub (2012), *Conflict-Driven Answer Set Solving: From Theory to Practice*, Artificial Intelligence 187–188, 52–89. <https://www.sciencedirect.com/science/article/pii/S0004370212000409>
- Potassco book: <https://potassco.org/book/>
- Potassco teaching: <https://teaching.potassco.org>
- Löh, Coutts (2011), *A new, modular dependency solver for cabal-install*, Haskell Implementors' Workshop. <https://wiki.haskell.org/wikiupload/b/b4/HIW2011-Talk-Loeh.pdf>
- Nordin, Tolmach (2001), *Modular Lazy Search for Constraint Satisfaction Problems*, Journal of Functional Programming 11(5), 527–552.
