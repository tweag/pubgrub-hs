# PubGrub: A Dependency Solver for Haskell Packages

> **Status: tutorial. Current on the algorithm, stale in three places.** This is the
> gentlest introduction in the repository and a good starting point — but it was
> written before the reboot, so do not take its interface or roadmap as current.
> See [STATUS.md](STATUS.md) for what is actually true.
>
> Specifically:
>
> - **§2 "The Type Class Interface"** shows the provider as two methods,
>   `chooseVersion` and `getDependencies`. They were **merged into one `expand`** on
>   2026-06-24. (Splitting them back is an open question —
>   [flags-semantics.md](flags-semantics.md) §8.)
> - **§8 "Connection to Answer Set Programming"** describes a framing that was
>   **abandoned before any code was written**. There is no ASP component and never
>   was. See [attic/](attic/) §1.
> - **§9 "Implementation Roadmap"** is superseded by the rung ladder in
>   `../CLAUDE.md` and by [STATUS.md](STATUS.md).
>
> Nothing here covers flags or the instance model, which are the parts that took the
> most work. Those are [flags-semantics.md](flags-semantics.md) and
> [decision-semantics.md](decision-semantics.md).

This document introduces the PubGrub version-solving algorithm and explains how it will be implemented in this project. All examples use Cabal package names and PVP version syntax. The goal is to give enough precision to drive implementation, not to be a formal proof.

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

**PubGrub's contract:** given a root package and an oracle that can fetch dependencies on demand, return either:
- a `Map PackageName Version` assigning exactly one version to every required package, or
- a human-readable derivation tree explaining why no such assignment exists.

> **Scope note, corrected.** Cabal already ships its own solver. This project
> reimplements PubGrub — the algorithm used by Dart's `pub`, Python's `uv` and others —
> as a proof of concept whose two questions are **explanation quality** and
> **performance** against cabal-install's solver (`../CLAUDE.md`, "Project goal").
> An earlier version of this note said the goal was "to understand the algorithm deeply
> and explore its relationship to Answer Set Programming". The ASP half of that was
> abandoned before any code existed — see the banner at the top of this file and §8.

---

## 2. The Type Class Interface

> **Stale.** The two provider methods below, `chooseVersion` and `getDependencies`,
> were **merged into a single `expand`** on 2026-06-24, and the value a decision
> takes is no longer a bare version but a whole *instance* (a version plus a total
> flag assignment, or a pre-installed unit). The split shown here is still how the
> reference Rust implementation does it, and splitting back is an open question —
> [flags-semantics.md](flags-semantics.md) §8. Read this section for the *shape* of
> the seam, not for the current API, which is `src/PubGrub/Provider.hs`.

Three abstractions anchor the entire algorithm. Every subsequent section is defined in terms of them.

```haskell
-- A package is anything with equality, ordering, and a printable name.
-- In practice: newtype PackageName = PackageName Text
class (Eq p, Ord p, Show p) => Package p

-- A version set is a lattice of version constraints.
-- Concrete instance: Cabal's VersionRange.
class VersionSet vs where
  empty        :: vs             -- no versions satisfy this
  full         :: vs             -- all versions satisfy this
  complement   :: vs -> vs
  union        :: vs -> vs -> vs
  intersection :: vs -> vs -> vs
  contains     :: vs -> Version -> Bool

-- The external oracle: knows about packages and their dependencies.
class (Package p, VersionSet vs) => DependencyProvider dp p vs where
  -- Choose the best version of p currently allowed by vs.
  -- Returns Nothing if no valid version exists.
  chooseVersion   :: dp -> p -> vs -> Maybe Version
  -- Return the dependency map for a specific resolved version.
  getDependencies :: dp -> p -> Version -> Map p vs
```

Two points about `chooseVersion`:

1. It receives the *intersection* of all current constraints on `p` — the solver has already narrowed the range. The implementation only needs to pick the best version inside that range.
2. Correctness does not depend on the choice. PubGrub will eventually find the solution (or prove none exists) regardless of which valid version is returned. The choice only affects performance: "highest satisfying version" is standard because it minimises conflicts with other packages that also want recent versions.

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

*Lives in: `src/PubGrub/Types.hs`*

---

## 4. Incompatibilities — Encoding Constraints as Nogoods

An **incompatibility** is a set of terms (at most one per package) that cannot all be true simultaneously. In any valid solution, at least one term in an incompatibility must be false.

In SAT solving this would be called a *clause*. In Answer Set Programming it is a *nogood*. PubGrub uses the word incompatibility throughout.

```haskell
data IncompatCause p vs
  = RootCause
  | DependencyCause
  | Derived (Incompatibility p vs) (Incompatibility p vs)

data Incompatibility p vs = Incompatibility
  { terms :: Map p (Term vs)
  , cause :: IncompatCause p vs
  }
```

### Three canonical forms

**1. Root seed**

```
{ root: Negative empty }
```

Reads: "it is impossible for root to be absent." This is the first incompatibility added to every solve. It is immediately a unit clause, forcing the solver to select the root package.

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

Adjacent versions with identical dependency ranges can be collapsed into a single incompatibility covering the whole range — an important optimisation for large version histories.

**3. Conflict-derived incompatibility**

Created during conflict resolution (§6.2) when the solver detects a contradiction and applies the Rule of Resolution to two existing incompatibilities. These carry a `Derived i₁ i₂` cause for error reporting (§7).

### Special case: unit incompatibility

An incompatibility with a single term `{ p: Positive r }` bans all versions of `p` in range `r`. This arises naturally when `chooseVersion` returns `Nothing` (§6.3) — the solver creates `{ p: Positive currentRange }` and re-enters conflict resolution to learn why `p` has no valid version.

*Lives in: `src/PubGrub/Types.hs`*

---

## 5. The Partial Solution — State of the Solver

The **partial solution** is an ordered sequence of assignments, oldest first. It represents everything the solver currently believes about the package selection.

```haskell
data Assignment p vs
  = Decision
      { pkg           :: p
      , version       :: Version
      , decisionLevel :: Int
      }
  | Derivation
      { pkg   :: p
      , term  :: Term vs
      , cause :: Incompatibility p vs
      }

newtype PartialSolution p vs = PartialSolution
  { assignments :: [Assignment p vs] }
```

**Decisions** are guesses: "let's try version `v` for package `p`." Each decision increments a monotone counter (the decision level). A decision is equivalent to the term `Positive {v}`.

**Derivations** are consequences: "package `p` must satisfy range `r`, because incompatibility `i` forced it." Multiple derivations for the same package accumulate — their effective constraint is the intersection of all their terms.

Because a Decision can be treated as the term `Positive {v}`, both assignment kinds participate identically in the satisfiability checks used by unit propagation. The distinction only matters during conflict resolution, which needs to know "was this a guess or a consequence, and at what decision level?"

**Backtracking** is implemented by truncating `assignments` to everything before a target decision level. All derivations added after that decision are discarded; the solver is in a consistent state from before the problematic guess.

*Lives in: `src/PubGrub/Types.hs`*

---

## 6. The Three Algorithms

### 6.1 Unit Propagation

Unit propagation scans the known incompatibilities and deduces new constraints from the current partial solution.

For each incompatibility, count how many of its terms are *not* satisfied by the partial solution:

- **Zero unsatisfied** — all terms hold: this is a contradiction. Pass the incompatibility to conflict resolution and stop.
- **Exactly one unsatisfied** — all other terms hold. The unsatisfied term must be false to keep the incompatibility from becoming a contradiction. Add a derivation negating that term and restart the scan.
- **Two or more unsatisfied** — not yet actionable; move on.

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
3. Call `chooseVersion provider p allowedRange`.
   - If `Nothing`: no valid version exists in the allowed range. Add `{ p: Positive allowedRange }` as a new incompatibility (banning the entire range) and re-enter conflict resolution. This is required for completeness — without it the solver could loop indefinitely on an unsatisfiable constraint.
   - If `Just v`: record a Decision for `(p, v)`. Call `getDependencies provider p v` and add one incompatibility per dependency entry `(q, range)`:
     ```
     { p: Positive {v}, q: Negative range }
     ```
     Then return to unit propagation with the package name as the starting point.

```haskell
decideNext
  :: (Package p, VersionSet vs, DependencyProvider dp p vs)
  => dp
  -> [Incompatibility p vs]
  -> PartialSolution p vs
  -> Either SolveError ([Incompatibility p vs], PartialSolution p vs)
```

> **Lazy loading.** `getDependencies` is called only when a package version is actually decided. The solver never loads the full dependency graph up front. This is what makes PubGrub tractable for large registries like Hackage, where the full graph has tens of thousands of versions.

### The Main Loop

```haskell
solve
  :: (Package p, VersionSet vs, DependencyProvider dp p vs)
  => dp -> p -> Version
  -> Either SolveError (Map p Version)
solve provider root rootVersion = do
  let seed = Incompatibility
        { terms = Map.singleton root (Negative empty)
        , cause = RootCause
        }
  go [seed] (PartialSolution []) root
  where
    go incompats ps pkg = do
      ps' <- unitPropagate incompats ps   -- may trigger conflictResolution internally
      (incompats', ps'') <- decideNext provider incompats ps'
      case nextUndecided ps'' of
        Nothing   -> Right (collectDecisions ps'')
        Just next -> go incompats' ps'' next
```

*Lives in: `src/PubGrub/Solver.hs`*

---

## 7. Error Reporting — The Derivation Tree

Because every derived incompatibility carries its two parents in `Derived i₁ i₂`, the final conflict is the root of a DAG traceable back to the original dependency facts. This is what allows PubGrub to produce messages like:

> Because `aeson ^>=2.2` requires `text ^>=2.0` and `servant 0.20` requires `text ^>=1.2`, `aeson ^>=2.2` and `servant 0.20` are incompatible.

```haskell
class Reporter r p vs where
  reportConflict :: r -> Incompatibility p vs -> String
```

A default implementation performs post-order traversal of the DAG:

- **Leaf (`DependencyCause`):** "package X at version V requires Y in range R."
- **Leaf (`RootCause`):** trivial seed; usually suppressed.
- **Internal (`Derived i₁ i₂`):** "Because [render i₁] and [render i₂], therefore [render this incompatibility]."

> **Deduplication.** The derivation structure is a DAG, not a tree — the same incompatibility can appear as a parent of multiple nodes. A printer that naïvely recurses will repeat large subtrees. Assign a line number to any incompatibility that is referenced more than once and replace repeated expansions with a back-reference ("as shown on line N").

*Lives in: `src/PubGrub/Solver.hs`*

---

## 8. Connection to Answer Set Programming

> **Abandoned framing — there is no ASP component, and there never was.** The
> `ASP.hs` module this section refers to was never written; no `.lp` file was ever
> committed and Clingo was never invoked. The plan to encode solving as Answer Set
> Programming was dropped *before any code*, in favour of implementing PubGrub
> natively. See [attic/README.md](attic/README.md) §1.
>
> The *analogy* below is still accurate and still worth reading — PubGrub really is
> a CDNL algorithm, and the mapping illuminates it. Only the implied deliverable is
> gone. The role of an independent checker is now played by the Lean specification
> in [../specification/](../specification/).

PubGrub is an instance of **Conflict-Driven NoGood Learning (CDNL)**, the core algorithm in modern Answer Set Programming solvers such as Clingo. Understanding this connection motivates the `ASP.hs` module and clarifies what "Answer Set Solving" buys us.

### The Mapping

| ASP / CDNL term        | PubGrub term                    |
|------------------------|---------------------------------|
| Boolean variable       | Package (with version set)      |
| Nogood                 | Incompatibility                 |
| Unit propagation       | Unit propagation (§6.1)         |
| Conflict analysis      | Conflict resolution (§6.2)      |
| Decision               | Decision (§5, §6.3)             |
| Learned clause         | Derived incompatibility (§4)    |
| Answer set             | Resolved `Map p Version`        |

### Why PubGrub Is Not Literally an ASP Instance

Three features distinguish PubGrub from a plain SAT/ASP encoding:

1. **Infinite domain.** A package's version space is potentially unbounded. Version *ranges* represent entire intervals without enumerating individual values — impossible in a Boolean variable encoding.

2. **Lazy clause loading.** In standard ASP all nogoods are stated before solving begins. PubGrub adds dependency incompatibilities on demand as versions are decided. This is critical: for a registry the size of Hackage, loading every dependency of every version up front would be prohibitive.

3. **Implicit mutual exclusivity.** A package has exactly one version in a valid solution. Encoding this in Boolean SAT requires O(n²) "at most one" clauses per package (one clause per pair of candidate versions). PubGrub encodes it implicitly: a Decision sets a singleton positive term, and any subsequent Decision for the same package would immediately conflict via unit propagation.

### Two Implementation Strategies

**Encode to ASP.** Translate the dependency problem into a Clingo ground program and decode the answer set. This is straightforward to implement and useful for validating solver results:

```prolog
% Candidate versions (loaded from Hackage index)
version(aeson, "2.2.1.0"). version(aeson, "2.1.0.0"). ...
version(text,  "2.0.2").   version(text,  "1.2.5.0"). ...

% Select exactly one version per required package
1 { selected(P, V) : version(P, V) } 1 :- required(P).

% Dependency constraint: if P@V is selected, Q must satisfy range R
:- selected(P, V), dep(P, V, Q, R), not satisfies_range(Q, R).

% Prefer newer versions
#minimize { 1@1, P, V : selected(P, V) }.
```

This approach cannot produce derivation-tree error messages — Clingo explains unsatisfiability in terms of its internal encoding, not in terms of package dependency chains.

**Native CDNL with range arithmetic.** Implement PubGrub's loop directly in Haskell (§6), with Clingo used only in `ASP.hs` for independent cross-validation. This is the primary approach and is what the architecture (`Solver.hs` separate from `ASP.hs`) reflects.

Suggested use: implement the native solver first, then use the ASP encoding as a test oracle — run both on the same inputs and assert they agree on satisfiability.

*Lives in: `src/PubGrub/ASP.hs`*

---

## 9. Implementation Roadmap

> **Superseded.** The module map and phasing below describe the pre-reboot tree.
> For what exists now see `../CLAUDE.md` (architecture and the rung ladder) and
> [STATUS.md](STATUS.md) (what is built, what is specified, what is open).

### Module Map

| Concept | Module |
|---------|--------|
| `Package`, `VersionSet`, `DependencyProvider` type classes | `src/PubGrub/Types.hs` |
| `Term`, `Incompatibility`, `IncompatCause`, `Assignment`, `PartialSolution` | `src/PubGrub/Types.hs` |
| Range arithmetic over Cabal `VersionRange` | `src/PubGrub/VersionSet.hs` |
| `unitPropagate`, `conflictResolution`, `decideNext`, main loop, `Reporter` | `src/PubGrub/Solver.hs` |
| ASP encoder and Clingo interface | `src/PubGrub/ASP.hs` |
| CLI, Hackage integration | `app/Main.hs` |

### Suggested Build Order

1. **`VersionSet.hs`** — implement all range arithmetic over Cabal's `VersionRange`. Write `QuickCheck` properties first:
   - `complement (complement r) == r`
   - De Morgan's laws: `complement (union a b) == intersection (complement a) (complement b)`
   - `contains (intersection a b) v == contains a v && contains b v`

2. **`Types.hs`** — define all data types with `Eq`/`Show` instances. Add smart constructors: `mkDependency :: p -> vs -> p -> vs -> Incompatibility p vs`.

3. **`Solver.hs`** — implement unit propagation first (testable with hand-constructed incompatibilities), then conflict resolution, then the full loop.

4. **`ASP.hs`** — write the encoder and decoder for cross-validation of solver results.

5. **`Main.hs`** — wire everything to a local fixture or the Hackage index API.

### Cabal Dependencies to Add

```cabal
build-depends:
    base         ^>=4.21
  , Cabal        ^>=3.12    -- for VersionRange, Version
  , containers   ^>=0.7     -- for Map, Set
  , text         ^>=2.0
  , QuickCheck   ^>=2.15    -- for property tests
```

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

Nodes represent choices; edges represent assignments. This is **not** the dependency tree — it is the solver's search tree, built lazily so that validation and pruning passes only materialise nodes they actually visit.

PubGrub has **no explicit search tree**. Its state is a flat partial solution plus a set of incompatibilities. The "tree" is implicit in the sequence of decisions and derivations.

### Conflict Handling: Backjumping vs Clause Learning

This is the most important algorithmic difference.

**Modular solver — backjumping.** Every `Fail` node carries a `ConflictSet`: the set of past choice points (package names) that contributed to the conflict. When the solver backtracks, it propagates the conflict set upward through the tree. If an ancestor choice node is *not* in the conflict set, all its remaining branches are pruned immediately — there is no point exploring them, because the failure did not involve that choice. The solver jumps over them in one step.

However, the conflict set is **discarded once backtracking completes**. No new constraint is recorded in the global knowledge base. If the same dead end can be reached by a different path, it will be explored again from scratch.

**PubGrub — clause learning.** When conflict resolution terminates, the derived root-cause incompatibility is **permanently added** to the global incompatibility list. It is a new constraint that will be active for the rest of the solve. Unit propagation will fire on it immediately after backtracking, preventing the solver from ever entering the same region of the search space regardless of how it got there.

In formal terms: backjumping is **non-chronological backtracking** with local pruning; clause learning is **non-chronological backtracking with global pruning**. Clause learning subsumes backjumping — every conflict set can be derived from the learned clause — and is strictly more powerful for hard instances with many interacting constraints.

The trade-off is implementation complexity: clause learning requires the Rule of Resolution and the satisfier/previous-satisfier machinery (§6.2); backjumping only needs to track which packages caused each failure.

### Search Strategy and Ordering

The modular solver explores depth-first, left-to-right. The order of branches matters; the preferences and heuristics phases reorder subtrees before exploration begins. Two standard heuristics:

- **Prefer later versions** (reorder `PChoice` children newest-first).
- **Prefer goals with fewer valid choices** (the "fail-first" principle: resolve packages with tighter constraints earlier to surface conflicts sooner).

PubGrub is also effectively depth-first — it commits to one version at a time — but the "order" is encoded in `chooseVersion`. There is no explicit reordering pass; the `DependencyProvider` implementation simply returns whichever version it considers best, and `prioritize` (in the Rust API) selects which package to resolve next. The effect is the same but the mechanism is different: a single callback rather than a composable tree transformation.

### Haskell-Specific Features

The modular solver handles two features of the Cabal dependency problem that the basic PubGrub specification does not:

**Boolean flags.** Cabal `.cabal` files can declare conditional dependencies gated on boolean flags (e.g., `flag use-bytestring-builder`). The modular solver interleaves flag decisions (`FChoice` nodes) with package decisions. PubGrub as specified treats dependencies as unconditional; handling flags requires either pre-expanding all flag combinations or extending the value domain. This project does the latter — a solver variable's value is an *instance* (version × total flag assignment) rather than a version — and `docs/flags-semantics.md` specifies what that costs and requires.

**Installed vs. new instances.** The modular solver distinguishes packages already installed in the GHC package database from new packages to be downloaded. It prefers installed instances to avoid unnecessary reinstalls. PubGrub's `chooseVersion` can implement this preference, but the distinction is not built into the algorithm.

**The destructive-update problem.** The old (pre-modular) Cabal solver never backtracks. It resolves packages greedily and can produce install plans that destructively overwrite existing installed packages (replacing `A-1` with `A-2` even though other installed packages depend on `A-1`). The modular solver can detect and refuse such plans. PubGrub is unaffected by this issue because it is invoked without knowledge of the installed package database, but a real Hackage integration would need to thread installed-instance information through `DependencyProvider`.

### Error Reporting

The modular solver's approach: accumulate a trace of every decision and its rationale; error messages are excerpts of the trace with irrelevant steps removed, guided by conflict sets. As Löh noted, "all the information is there" but the presentation is not yet polished.

PubGrub's approach: the derivation tree is structurally embedded in the `IncompatCause` of each derived incompatibility. Rendering it is a pure recursive function over the tree structure (§7). The output takes the form of a logical proof: "Because X requires Y and Z requires ¬Y, X and Z are incompatible." This structure is always available regardless of how complex the conflict was.

Both approaches aim at the same goal. PubGrub's advantage is that the derivation tree is a first-class value produced by the algorithm itself, not a post-hoc reconstruction from logs.

### Summary Table

| Property | Old solver (pre-2011) | Modular solver | PubGrub |
|---|---|---|---|
| Backtracking | None | Backjumping (configurable limit) | Clause learning (always) |
| Conflict knowledge | Discarded | Discarded after jump | Permanently retained |
| Search structure | Greedy, linear | Explicit lazy tree | Implicit (partial solution) |
| Boolean flags | Yes | Yes (FChoice nodes) | Not in base spec |
| Installed packages | Yes | Yes (preferred) | Via DependencyProvider |
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
