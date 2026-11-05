# PubGrub: A Dependency Solver for Haskell Packages

> **What this is.** An introduction to the PubGrub algorithm, and the gentlest starting
> point in the repository. To use the library, read the `PubGrub.Tutorial` module instead.
>
> **What decides.** `references/pubgrub.md` is the authority on the algorithm. Where
> this file and the spec disagree, the spec is right. This file exists to make the spec
> readable, not to replace it.
>
> **What it does not cover.** Flags, which are the part that took the most work. That
> is [DESIGN.md §3](DESIGN.md#3-a-flag-is-a-variable-and-a-decision-is-one-variables-value).

This document introduces the PubGrub version-solving algorithm and how this project implements it. All examples use Cabal package names and the version syntax of the Package Versioning Policy (PVP). The goal is to make the algorithm understandable, not to prove it correct.

---

## 1. What Is a Dependency Solver?

When you run `cabal install`, Cabal must find a single version for every package in the transitive dependency closure such that all constraints are satisfied simultaneously. (Setup scripts and build tools can differ. This introduction leaves them out.) Here is the message from cabal's solver on `dhall ==1.42.3` and `aeson ==2.3.1.0` requested together, with two long lists of versions cut short at the `…`:

```
Could not resolve dependencies:
[__0] trying: aeson-2.3.1.0 (user goal)
[__1] next goal: dhall (user goal)
[__1] rejecting: dhall-1.42.3 (conflict: aeson==2.3.1.0, dhall => aeson>=1.0.0.0 && <2.3)
[__1] skipping: dhall; 1.42.2, 1.42.1, 1.42.0, … (has the same characteristics that caused the previous version to fail: excludes 'aeson' version 2.3.1.0)
[__1] rejecting: dhall; 1.19.1, 1.19.0, 1.18.0, … (constraint from user target requires ==1.42.3)
[__1] fail (backjumping, conflict set: aeson, dhall)
After searching the rest of the dependency tree exhaustively, these were the goals I've had most trouble fulfilling: aeson, dhall
```

The fact that matters is on the fourth line. `dhall-1.42.3` needs `aeson <2.3`, the request names `aeson` 2.3.1.0, and no single version of `aeson` satisfies both.

The naive approach — enumerate every combination of versions and test consistency — is exponential in the number of packages. A solver does better by learning from conflicts: when a combination fails, record *why* it failed so the same dead end is never explored again. This is what PubGrub does.

**PubGrub's contract:** given a set of targets and a provider that can fetch dependencies on demand, return either:
- an assignment of exactly one version to every required package, or
- a derivation tree, printable as a human-readable explanation of why no such assignment exists (§7 shows the one for this failure).

> **Scope note.** Cabal already ships its own solver. This project reimplements
> PubGrub — the algorithm used by Dart's `pub` and Python's `uv` — as a proof of
> concept. Its two questions are **explanation quality** and **performance** against
> cabal-install's solver.

---

## 2. The Interface

Two abstractions anchor the algorithm, and one callback connects it to the world.

**Values.** The solver's variables are the things it assigns values to. For most of
this introduction, read a variable as a package name. In this project a package's value is
an `Instance` — one concrete way of having a package, either a pre-installed unit or a
source release. An automatic flag is a variable too, with a Boolean value (§9).

**Value sets.** The algebra needs the empty set, three operations and an emptiness test:
`empty`, `intersect`, `union`, `difference`, `isEmpty`. It needs **no complement**. A
complement requires a universe of values that nothing in the algorithm ever asks for,
and negation is needed in exactly one place — `Term`, where it is a polarity flip.

```haskell
class SetOps a where
  empty      :: a
  intersect  :: a -> a -> a
  union      :: a -> a -> a
  difference :: a -> a -> a
  isEmpty    :: a -> Bool
  -- isSubsetOf and isDisjoint have defaults in terms of these
```

**The provider** is one callback, over a variable type `v` with its values `ValueOf v`
and its sets `SetOf v`:

```haskell
newtype Provider v m = Provider
  { expand :: v -> SetOf v -> m (Maybe (ValueOf v), [Incompatibility v]) }
```

Given a package and the accumulated constraint on it, commit to one instance and report
the incompatibilities that decision entails, in one atomic step.

Four points about it:

1. It receives the *intersection* of all current constraints on the package. The solver
   has already narrowed the set.
2. The returned instance **must** be a member of that set. The solver checks, and stops
   with `BadValue` if it is not.
3. Correctness does not depend on *which* member. PubGrub finds the solution, or proves
   there is none, whatever valid instance comes back. The choice decides which plan you
   get and how long the search takes, not whether one is found. Our provider prefers an installed unit, then the newest source release.
4. The incompatibility list sits **outside** the `Maybe` deliberately. A provider that
   skips releases it cannot use must be able to answer "no decision, and here is what I
   learned".

The choice and its consequences always travel together, so the solver never holds one
without the other. The reference Rust implementation keeps them as two methods
(`choose_version` and `get_dependencies`). Whether to split ours back is an open question,
made cheaper to leave by the flag-variable model, under which a release's consequences do
not depend on an assignment.

> **PVP vs SemVer.** Cabal uses the [Package Versioning Policy](https://pvp.haskell.org/). In PVP, `^>=1.2` means `>= 1.2 && < 1.3` — the two *leftmost* version components form the major version. This differs from SemVer's `^1.2`, which means `>= 1.2.0 && < 2.0.0`. Be careful when reading Cargo or npm documentation: their version range semantics differ.

---

## 3. Terms — The Logical Building Block

A **term** pairs a package with a version-set assertion. Every constraint in the solver is expressed as a term.

```haskell
data Term a
  = Positive a   -- the selected version must lie within the set
  | Negative a   -- the package is absent, or its version lies outside the set
  deriving (Eq, Ord, Show)
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
-- Does the first imply the second? A term denotes a set of allowed versions, so this is ⊆.
isSubsetOf :: SetOps a => a -> a -> Bool

-- Combine two terms for the same package (logical AND).
intersectTerm :: SetOps s => Term s -> Term s -> Term s
```

The solver holds one accumulated term per package, the intersection of everything it
has derived about that package. Against that term, any other term `t` is in one of three
states (`references/pubgrub.md:93`, `:120`):

- **satisfied:** the accumulated term is a subset of `t`, so `t` must be true;
- **contradicted:** the accumulated term is disjoint from `t`, so `t` must be false;
- **inconclusive:** neither, so `t` could still go either way.

> **Satisfaction direction — easy to get backwards.**
> T₁ is *satisfied by* T₂ when T₂ ⊆ T₁, meaning T₂ is *more specific* than T₁.
>
> Example: if we know `text` is constrained to `¬[^>=1.0 || ^>=2.0]` (outside both ranges), that implies it is also outside `^>=1.0` alone. So `Negative (^>=1.0 || ^>=2.0)` satisfies `Negative (^>=1.0)`. The bigger exclusion zone implies the smaller one.

The intersection rules follow from the logical identities:

```
Positive r₁  ∧  Positive r₂  =  Positive (r₁ ∩ r₂)
Positive r₁  ∧  Negative r₂  =  Positive (r₁ \ r₂)
Negative r₁  ∧  Negative r₂  =  Negative (r₁ ∪ r₂)
```

*Lives in: [`pubgrub/src/PubGrub/Term.hs`](../pubgrub/src/PubGrub/Term.hs)*

---

## 4. Incompatibilities — Encoding Constraints as Nogoods

An **incompatibility** is a set of terms (at most one per package) that cannot all be true simultaneously. In any valid solution, at least one term in an incompatibility must be false.

In Boolean satisfiability (SAT) solving the same idea is a *clause*, strictly the negation of one. In Answer Set Programming (ASP) it is a *nogood*. PubGrub uses the word incompatibility throughout, and the code also says clause.

Every incompatibility records its cause, which is what a failure is later explained from. The core's `Cause` is written over any variable type `v`, and each domain supplies its own type of leaf fact. For cabal, that type is `CabalFact`.

```haskell
-- the core: the shape of a derivation, over any variable type v
data Cause v
  = Seed (FactOf v)                                -- what the solve was asked for
  | Fact (FactOf v)                                -- a fact the provider stated
  | NoValues v (SetOf v)                           -- nothing to offer in this set
  | Derived (Incompatibility v) (Incompatibility v) -- resolved from two others

data Incompatibility v = Incompatibility
  { incompTerms :: Map v (Term (SetOf v))
  , incompCause :: Cause v
  }

-- the cabal domain: what a leaf says
data CabalFact
  = CauseRequest PackageName InstanceSet
  | CauseOnlyInstalled PackageName [Version]
  | CauseUnbuildable PackageName InstanceSet Guard (NonEmpty UnbuildableReason)
  | CauseDependency PackageName InstanceSet Guard (PackageName, InstanceSet)
  | CauseDeclaresFlag PackageName InstanceSet Flag
  | CauseConstraint Var ValueSet
```

### Three canonical forms

**1. Request seed**

```
{ foo: Negative (>=1 && <2) }
```

Reads: "it is impossible for foo to be outside `>=1 && <2`", which forces `foo` into
the plan at a version in that range. These are the first incompatibilities added to
every solve, one per target. The spec opens the same way with a single root package,
`{not root 1.0.0}` (`references/pubgrub.md:251`); we state the targets directly, so no
root package has to be printed and filtered out again. Each seed has one term, which
makes it a *unit clause*: nothing else has to hold before it acts.

`--constraint` adds the other kind of seed, `{ foo: Positive forbidden }`: foo may be
left out of the plan, and if it is chosen it is not in `forbidden`.

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
incompatibility covering the whole range (`references/pubgrub.md:456`). That cuts the
number of incompatibilities, and it lets the solver reason about many versions at once
instead of learning about them one at a time. See
[DESIGN.md §5](DESIGN.md#5-dependency-facts-collapse-in-two-places) for how this project
does it.

**3. Conflict-derived incompatibility**

Created during conflict resolution (§6.2) when the solver detects a contradiction and applies the Rule of Resolution to two existing incompatibilities. These carry a `Derived` cause for error reporting (§7). Every other cause is a **leaf**: a fact about the world rather than a step of reasoning.

### Special case: unit incompatibility

An incompatibility with a single term `{ p: Positive r }` bans all versions of `p` in range `r`. This arises when `expand` returns no instance (§6.3). The solver creates `{ p: Positive currentRange }`, and the next propagation finds it violated, which starts conflict resolution to learn why `p` has no valid version.

*Lives in: [`pubgrub/src/PubGrub/Incompatibility.hs`](../pubgrub/src/PubGrub/Incompatibility.hs)*

---

## 5. The Partial Solution — State of the Solver

The **partial solution** is everything the solver currently believes about the package
selection: an ordered sequence of assignments, oldest first.

```haskell
data AssignmentKind v
  = Decision (ValueOf v)                              -- a guess
  | Derivation (Term (SetOf v)) (Incompatibility v)   -- a consequence, and its cause
```

**Decisions** are guesses: "let us try this instance of `p`." Every assignment carries a
decision level, the number of decisions at or before it (`references/pubgrub.md:178`).
A decision is equivalent to the term `Positive {that instance}`.

**Derivations** are consequences: "package `p` must satisfy range `r`, because incompatibility `i` forced it." Multiple derivations for the same package accumulate — their effective constraint is the intersection of all their terms.

Because a Decision can be treated as the term `Positive {v}`, both assignment kinds participate identically in the satisfiability checks used by unit propagation. The distinction only matters during conflict resolution, which needs to know "was this a guess or a consequence, and at what decision level?"

**Backtracking** discards every assignment above a target decision level. The solver is
then in a consistent state from before the problematic guess.

*Lives in: [`pubgrub/src/PubGrub/PartialSolution.hs`](../pubgrub/src/PubGrub/PartialSolution.hs). Note the real structure
is indexed by package name rather than being a flat list, and it caches each package's
accumulated term, so backtracking has to rebuild the caches.*

---

## 6. The Three Algorithms

### 6.1 Unit Propagation

Unit propagation scans the known incompatibilities and deduces new constraints from the current partial solution (`references/pubgrub.md:279`).

For each incompatibility, compare each of its terms with the partial solution (§3):

- **Every term satisfied** — this is a conflict. Pass the incompatibility to conflict resolution.
- **All but one satisfied, and the last inconclusive** — the incompatibility is *almost satisfied*. The last term must end up false, or every term would be true. Add a derivation negating that term.
- **Anything else** — a contradicted term means the incompatibility can no longer be violated, and two or more inconclusive terms mean it is not yet actionable. Move on.

Repeat until a fixpoint (no new derivations, no conflict).

> **Implementation note.** Scanning every incompatibility until nothing changes is correct and slow. The spec looks only at the incompatibilities that mention a package which just changed, newest first (`references/pubgrub.md:293`, `:308`). `unitPropagation` judges only those clauses, through an index per variable and a worklist of the clauses whose judgement can have changed, and acts on the newest actionable clause overall, which is the clause a full scan would pick.

### 6.2 Conflict Resolution

When unit propagation finds a fully-satisfied incompatibility, conflict resolution determines *why* the conflict happened and how far back to jump (`references/pubgrub.md:369`).

**Key definitions:**

- **Satisfier:** the earliest assignment such that the incompatibility is satisfied by the partial solution up to and including that assignment (`references/pubgrub.md:383`).
- **Previous satisfier:** the earliest assignment before the satisfier such that the incompatibility is satisfied by the partial solution up to and including that assignment, plus the satisfier (`references/pubgrub.md:388`).
- **Previous satisfier level:** the previous satisfier's decision level. This is the level we will backtrack to. The spec's lowest backtrack target is level 1, where its root package is selected (`references/pubgrub.md:398`). We have no root package, and the seeds' derivations sit at level 0, so ours is level 0.

Our search for the previous satisfier differs from that definition in one corner. Where the satisfier alone covers its term, the search takes the package's first assignment for that term, which may be the satisfier itself. It can then keep resolving where the spec would stop. Each resolvent is still a valid consequence, so this changes which clause is learned.

> **Easy to get wrong.** The target is the *previous* satisfier's level, not the satisfier's own. Backtracking there removes the satisfier and keeps everything else the incompatibility rests on, so the incompatibility is then almost satisfied and propagation acts on it at once (`references/pubgrub.md:315`).

**The loop** (`references/pubgrub.md:375`):

1. If the incompatibility is satisfied by the seeds' derivations alone, no decision took part, so nothing can be undone and version solving has failed. Report it (§7). The spec's test is the same idea for a root package: no terms, or a single positive term for the root (`references/pubgrub.md:377`).
2. Find the satisfier and the previous satisfier.
3. If the satisfier is a Decision, or the previous satisfier's level differs from the satisfier's, stop. This incompatibility is the root cause (`references/pubgrub.md:406`).
4. Otherwise apply the **Rule of Resolution** to the current incompatibility and the satisfier's cause, with `p` the satisfier's package (`references/pubgrub.md:350`):

   From `{ p: t₁, …rest₁ }` and `{ p: t₂, …rest₂ }`:

   ```
   resolvent = { …rest₁, …rest₂, p: t₁ ∪ t₂ }
   ```

   A package named in both rests takes the intersection of its two terms. If `t₁ ∪ t₂ = Negative empty` (always true), the term for `p` contributes nothing and is dropped from the resolvent.

   Replace the current incompatibility with the resolvent and loop.

**When the loop exits:** add the root-cause incompatibility to the global list, backtrack the partial solution to the previous satisfier level, and re-enter unit propagation. The new incompatibility is almost satisfied, so it immediately derives a constraint preventing the same conflict (`references/pubgrub.md:318`).

> **Why resolution works.** Each step replaces a derived assignment with the reason it was derived, one step closer to the decisions behind the conflict (`references/pubgrub.md:356`). An incompatibility holds whatever is selected (`references/pubgrub.md:131`), so the one learned at the end keeps the solver out of that dead end for the rest of the solve, however it gets there.

### 6.3 Decision Making

After unit propagation completes without conflict, the solver chooses a new package to commit to (`references/pubgrub.md:484`).

1. Find a package `p` that has a positive derivation (the solver knows it must be selected) but no Decision yet. Any such package is valid. The spec picks the one with the fewest matching versions (`references/pubgrub.md:446`), and we take the one mentioned first ([DESIGN.md](DESIGN.md) §12).
2. Compute the current allowed range for `p` (intersection of all derivation terms).
3. Call `expand provider p allowedSet`. It answers with an instance or nothing, **and** with the incompatibilities it learned on the way. The two travel together.
   - If it answers no instance: add the returned incompatibilities and `{ p: Positive allowedSet }`, which bans the whole set (`references/pubgrub.md:492`), and return to unit propagation, which finds the conflict. Where the provider's own facts about `p` already ban part of the set, only the rest is added. Termination needs this ban: without it, `p` could be offered the same set again.
   - If it answers an instance: record a decision for it, add the returned incompatibilities, and return to unit propagation. The spec withholds the decision if it would conflict with the new incompatibilities (`references/pubgrub.md:499`). We record it and let propagation find the conflict.

For a source release, the incompatibilities it returns are the release's dependencies, one per dependency entry `(q, range)`:

```
{ p: Positive {the slot of v}, q: Negative range }
```

The depender term is at least the release's **slot**, not the single version: the half-open range from `v` up to the next release that exists, with no lower bound on the first release's slot. The provider widens it across neighbours that carry the same dependency, and adjacent slots touch, so they can merge. That is
`references/pubgrub.md:456`'s adjacent-version collapsing, and
[DESIGN.md §5](DESIGN.md#5-dependency-facts-collapse-in-two-places) explains it.

> **Lazy loading.** `expand` is called only when a package is actually decided. The solver never loads the full dependency graph up front. This is what makes PubGrub tractable for a registry the size of Hackage.
>
> **Facts can arrive without a decision.** The list sits outside the answer, so a provider that skips releases it cannot use can still report why. That is how a proof says `hpqtypes >=1.10.0.2 needs pkg-config package libpq, which is not found` instead of `no version for hpqtypes in …`.

### The Main Loop

A sketch of `solve`, with its signature as it is:

```haskell
solve
  :: (Domain v, Monad m)
  => LogAction m (SolverMsg v)       -- receives each step of the search
  -> Provider v m
  -> [Incompatibility v]             -- the seeds
  -> m (Either (SolveError v) (Map v (ValueOf v)))
solve logA provider seeds = go (insertClauses seeds emptyStore)
  where
    -- each seed is { p: Negative R } for a target, or { p: Positive F } for a
    -- constraint, and its cause is Seed
    go store = do
      -- propagate; conflict resolution runs inside on a conflict
      -- then pick an undecided package and call expand
      -- until every positive term is decided, or a conflict rests on the
      -- seeds alone, which is failure
```

*Lives in: [`pubgrub/src/PubGrub/Solver.hs`](../pubgrub/src/PubGrub/Solver.hs)*

---

## 7. Error Reporting — The Derivation Tree

Because every derived incompatibility carries its two parents in `Derived`, the final conflict is the root of a directed acyclic graph (DAG) traceable back to the original dependency facts (`references/pubgrub.md:190`). This is what allows PubGrub to explain the failure from §1 like this, in the proof `pubgrub 'dhall ==1.42.3' 'aeson ==2.3.1.0'` prints with the Hackage index pinned to the moment in `bench/index-state`:

```
No solution for aeson ==2.3.1.0 and dhall ==1.42.3.

Because dhall >=1.42.1 depends on aeson >=1.0.0.0 && <2.3 and aeson ==2.3.1.0 is
    requested, dhall >=1.42.1 is forbidden.
So, because dhall ==1.42.3 is requested, version solving failed.
```

```haskell
-- the walker, over any domain; a Formatter supplies the words
reportConflict :: Domain v => Formatter v -> Incompatibility v -> Text
```

The printer walks the DAG:

- **a leaf** is a fact about the world. `CauseDependency` prints "X depends on Y R". The core's own `NoValues` prints "no version for Y in R". `CauseOnlyInstalled` prints "Y is pinned to V (installed)". `CauseUnbuildable` prints "Y needs pkg-config package M, which is not found", or "Y is marked buildable: False".
- **`CauseRequest`** is a seed, and prints "foo >=1 && <2 is requested". A proof ends on the seeds it rests on, a request or a constraint: a terminal conflict is resolved against them, so the last line reads "So, because …, version solving failed".
- **`Derived`** prints "Because [cause 1] and [cause 2], [this conclusion]".

> **Deduplication.** The derivation structure is a DAG, not a tree, so the same incompatibility can be a parent of several nodes. A printer that recurses naively repeats large subtrees. Give a line number to any incompatibility referenced more than once, and replace repeated expansions with a back-reference.

**The real reporter does more than this.** It follows the spec's own reporting algorithm (`references/pubgrub.md:504`), which skips every other derived step (`:530`) and says a chain of two facts in one sentence (`:1018`). On top of that it states a run of steps once and absorbs empty-range leaves. See [DESIGN.md](DESIGN.md) §9.

*Lives in: [`pubgrub/src/PubGrub/Report.hs`](../pubgrub/src/PubGrub/Report.hs) and [`pubgrub-cabal/src/PubGrub/Cabal/Report/`](../pubgrub-cabal/src/PubGrub/Cabal/Report/)*

---

## 8. Why PubGrub is not a SAT or ASP instance

PubGrub is based on **Conflict-Driven NoGood Learning (CDNL)**, the core algorithm in
modern Answer Set Programming solvers, and its SAT counterpart Conflict-Driven Clause
Learning (`references/pubgrub.md:49`). The vocabulary maps directly:

| CDNL term | PubGrub term |
| --- | --- |
| Boolean variable | package, with a value set |
| Nogood | incompatibility |
| Unit propagation | unit propagation (§6.1) |
| Conflict analysis | conflict resolution (§6.2) |
| Decision | decision (§5, §6.3) |
| Learned clause | derived incompatibility (§4) |
| Answer set | the resolved plan |

**Five features separate it from a plain encoding.** `references/pubgrub.md:1165` lists
the first four, and the fifth is this project's reason for existing. Each one is a
reason not to reach for an off-the-shelf solver.

1. **Version ranges.** A package's version space is potentially unbounded, and a range
   represents a whole interval without enumerating it. Expanding ranges into concrete
   version sets costs work *and* has to be undone again to talk to a user. This is why
   our set type describes a range rather than listing its members — see
   [DESIGN.md](DESIGN.md) §2.
2. **Lazy formulas.** In a standard encoding all clauses are stated before solving
   begins. PubGrub adds dependency incompatibilities on demand, as releases are
   decided. For a registry the size of Hackage, loading every dependency of every
   release up front would be prohibitive.
3. **Implicit mutual exclusivity.** A package has exactly one version in a valid
   solution. Encoding that in Boolean SAT needs O(n²) "at most one" clauses per
   package. PubGrub gets it for free: `foo ^>=1.0` and `foo ^>=2.0` contradict each
   other with no formula saying so.
4. **No unfounded-set detection.** Answer set solvers do extra work to rule out sets of
   variables that only justify one another in a cycle. PubGrub needs none, because it
   only chooses versions for packages known to be required
   (`references/pubgrub.md:1221`).
5. **Error reporting.** A general solver explains unsatisfiability in terms of its own
   internal encoding. PubGrub's derivation tree is in terms of package dependency
   chains, which is the half of this project's thesis that a SAT encoding cannot
   deliver.

> **There is no ASP component in this project, and there never was.** An early plan to
> encode solving for Clingo was dropped before any code was written.

---

## 9. Comparison to the Cabal Modular Solver

Cabal ships its own dependency solver, first described by Andres Löh and Duncan Coutts at the Haskell Implementors' Workshop 2011. Understanding its design clarifies what PubGrub does differently and why.

### The Modular Solver's Architecture

The modular solver represents the search space as an explicit lazy tree and then passes that tree through a **pipeline of independent transformations**. As the 2011 talk presents it (today's `Distribution.Solver.Modular.Solver` has more phases and the same shape):

```haskell
solve cfg idx userPrefs userConstraints userGoals =
  explorePhase    $
  heuristicsPhase $
  preferencesPhase $
  validationPhase  $
  prunePhase       $
  buildPhase
```

Each phase between building the tree and exploring it is a pure tree-to-tree function. Adding a new preference or heuristic is just writing another pass — this is the source of the "modular" name. The design is inspired by Nordin & Tolmach (2001), *Modular Lazy Search for Constraint Satisfaction Problems*.

In the talk the tree is this (today's also has stanza choices and weights):

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

However, the conflict set is **discarded once backtracking completes**. No new constraint is recorded in the global knowledge base; at most, `--count-conflicts` keeps a tally per goal that reorders later goals. If the same dead end can be reached by a different path, it will be explored again from scratch.

**PubGrub — clause learning.** When conflict resolution terminates, the derived root-cause incompatibility is **permanently added** to the global incompatibility list. It is a new constraint that will be active for the rest of the solve. Unit propagation will fire on it immediately after backtracking, preventing the solver from ever entering the same region of the search space regardless of how it got there.

In formal terms: backjumping is **non-chronological backtracking** with local pruning. Clause learning is **non-chronological backtracking with global pruning**. Clause learning subsumes backjumping — every conflict set can be derived from the learned clause — and is strictly more powerful for hard instances with many interacting constraints.

The trade-off is implementation complexity: clause learning requires the Rule of Resolution and the satisfier/previous-satisfier machinery (§6.2). Backjumping only needs to track which packages caused each failure.

### Search Strategy and Ordering

The modular solver explores depth-first, left-to-right. The order of branches matters, and the preferences and heuristics phases reorder subtrees before exploration begins. Two examples of those heuristics:

- **Prefer later versions** (reorder `PChoice` children newest-first).
- **Prefer goals with few valid choices** (the "fail-first" principle: resolve packages with tighter constraints earlier to surface conflicts sooner). In today's solver this one is behind `--reorder-goals`.

PubGrub is also effectively depth-first, because it commits to one instance at a time. The order of a package's instances is encoded in the provider. There is no explicit reordering pass: `expand` returns whichever instance it considers best. The effect is the same as the modular solver's, and the mechanism is different — a single callback rather than a composable tree transformation. Which package to decide next is the solver's choice, not the provider's (§6.3).

### Haskell-Specific Features

The modular solver handles two features of the Cabal dependency problem that the basic PubGrub specification does not:

**Boolean flags.** Cabal `.cabal` files can declare conditional dependencies gated on boolean flags (for example, `flag use-bytestring-builder`). The modular solver interleaves flag decisions with package decisions.

PubGrub as specified treats dependencies as unconditional. Handling flags needs either a pre-expansion of every flag combination, a richer value domain, or more variables. This project takes the third: an automatic flag is a solver variable of its own, decided after the release that declares it, and a guarded dependency is an incompatibility whose terms name the flags it holds under ([DESIGN.md §3](DESIGN.md#3-a-flag-is-a-variable-and-a-decision-is-one-variables-value)).

Note that flags are **fixed at their declared defaults unless `--flags search` is given**, on both sides of the comparison, and the recorded benchmark and showcase numbers were taken that way.

**Installed against new instances.** The modular solver distinguishes packages already installed in the GHC package database from new packages to be downloaded, and it prefers installed instances. Our provider does the same, in `expand`. The distinction is not built into the algorithm: it lives entirely in the provider, which is where an `Instance` can be a pre-installed unit.

**The destructive-update problem.** The old, pre-modular Cabal solver never backtracks. It resolves packages greedily and can produce install plans that overwrite installed packages, replacing `A-1` with `A-2` even though other installed packages need `A-1`. The modular solver can prune such plans when asked (`--avoid-reinstalls`).

PubGrub has no built-in notion of this either, and it does not need one here. Our provider reads the installed database, offers installed units as instances, and pins an installed unit's whole closure to the exact units it was built against. A plan that overwrites an installed package therefore cannot be constructed.

### Error Reporting

The modular solver's approach: accumulate a trace of every decision and its rationale. Error messages are excerpts of that trace with irrelevant steps removed, guided by conflict sets. As Löh put it in 2011, "all the information is there" but it "could be presented in a better/cleaner way".

PubGrub's approach: the derivation tree is structurally embedded in the `Cause` of each derived incompatibility. Rendering it is a pure recursive function over the tree structure (§7). The output takes the form of a logical proof: "Because X requires Y and Z requires ¬Y, X and Z are incompatible." This structure is always available regardless of how complex the conflict was.

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
