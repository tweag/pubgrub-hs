# Specification: flag semantics

> **Status:** specification. It says what must be *true*, not how to represent
> anything. No types, no data structures, no functions — those are derived work.
>
> **Implemented by:** `src/PubGrub/InstanceSet/SourceCell.hs` (`FlagPin`, the cell
> algebra), `src/PubGrub/InstanceSet.hs` (membership), `bridge/Bridge/Provider.hs`
> and `bridge/Bridge/Cabal/Flatten.hs` (the O6 provider obligations). The guards
> for §3 and §6 are in `test/InstanceSetSpec.hs`; the end-to-end cases are in
> `test/FlagSolveSpec.hs`. §1.5's manual-flag rule and §4.3's report wording are
> the parts not yet implemented.
>
> **Authority:** on the questions it answers, this file wins over
> [flags-design.md](flags-design.md) (which chose a different rule — see §2.3)
> and over `CLAUDE.md`. It does not overrule
> [references/pubgrub.md](../references/pubgrub.md); where PubGrub already
> decides something, this file cites it.

## 0. Why this exists

We have now paid twice for the same missing sentence. A constraint can mention a
flag that some version in its range does not declare, and nothing ever said what
that means. Each time it surfaced it looked like a fresh bug in a different
place — first in candidate selection, then in set difference — and each time it
was fixed locally without the rule being written down. The rule is stated once
here, and everything else is meant to follow from it.

## 1. The domain

### 1.1 Flags are declared per version

A `.cabal` file declares flags: each has a name, a default value, and a
manual/automatic marking. Because a `.cabal` file belongs to one release,
**the set of declared flags is a property of a `(package, version)` pair**, not
of a package. Write it `D(p, v)`. Two versions of one package may declare
different flags, and either may declare none.

`D` is index data. Only the bridge can answer it; the core algebra cannot, and
per the architecture boundary must not try.

### 1.2 An instance

The value of a solver variable is an **instance**: one concrete way of having a
package. Either a pre-installed unit, or a source release together with a flag
assignment α where

> **dom α = D(p, v), exactly.**

Totality is the load-bearing half (no conditional is left unresolved); exactness
is the half we keep forgetting (α never mentions a flag the version does not
declare, so "α has no value for `f`" is meaningful and observable).

### 1.3 Flags of different versions are unrelated

`foo-1.2`'s flag `f` and `foo-1.3`'s flag `f` share a *name* and nothing else.
This is a fact about Cabal, not a choice: each is declared by its own `.cabal`
file, with its own default, and at most one of the two is ever live, since a plan
contains at most one version of `foo`.

### 1.4 The flag lives in the value — the one modelling choice

A flag is **not** a solver variable in its own right. The variable is the package
name; the flag is part of the value. Everything downstream in this document —
in particular the three-case atom of §2.3 — follows from this, so it is worth
saying why, and what it costs.

**Why.** The set of flags depends on the version (§1.1). As an independent
variable, `foo:fast` would exist only when the chosen version of `foo` declares
`fast`, and PubGrub has no notion of a conditionally-existent variable. The
domain would have to be tied down with explicit incompatibilities — "if
`foo 1.3` then `foo:fast` is absent", one per version × flag — which is exactly
the bookkeeping PubGrub builds in for the version axis rather than encoding
(`references/pubgrub.md:1193` implicit mutual exclusivity, `:1207` lazy
formulas). Putting the flag in the value gets it for free: the domain dependence
becomes part of what an instance *is*, and PubGrub's "at most one value per
variable" delivers "at most one instance per package name" unchanged
(`:1193` already extends it to "packages with the same name from different
sources").

**What it costs.** The dependence is not removed, only relocated: out of explicit
clauses and into the constraint language, which is what makes §2.3 a real
question instead of a triviality. Under the alternative, a clause
`{foo 1.2, foo:fast, not vector >=0.12}` names the flag as a literal, so conflict
resolution generalises — it learns that `fast` is the problem, for every version.
Here, each `(version, assignment)` pair is its own atom, so a version rejected
for a reason unrelated to any flag is re-offered once per irrelevant assignment,
and nothing learned about one version's `f` transfers to another's. The intended
answer to that cost is dependency collapsing (§4.2), not a change of model.

**Status.** Nothing in §2 or §3 depends on this choice being the right one; if
the retry cost ever dominates, this is the decision to revisit, and §2.3 largely
dissolves when it is. It is recorded here as a decision with a price, because the
previous record of it (see [flags-design.md](flags-design.md) §1) gave a reason
that does not hold — invasiveness of a type substitution — and omitted the price
entirely.

**Consequence for the rest of this document.** A constraint that mentions `f` is
evaluated **per instance, against that instance's own α**. Sharing a name across
versions is syntax, not identity.

### 1.5 Not every instance is admissible

The universe of instances is smaller than the product of versions and
assignments. An instance is **admissible** only if:

- it agrees with the user's explicit flag constraints, read leniently (§1.6);
- every **manual** flag takes its declared default, unless the user set it
  (see §8 — the precise cabal rule is unverified here);
- the components in scope are buildable under α. A `buildable: False` reachable
  only under some assignments makes exactly those instances inadmissible, and
  PubGrub asks for that to be expressed as "never select this" rather than as
  dependencies (`references/pubgrub.md:476`).

Admissibility depends on the index and on user input. It restricts what may be
*chosen*; it is not a property the constraint algebra is expected to know.

### 1.6 User flag constraints are lenient

A user-supplied flag value applied to a package version that does not declare
that flag is **not** an error and excludes nothing. `--flag=+fast` against a
version with no `fast` flag simply says nothing about it. Only versions that
declare `fast` and set it `False` are excluded. This is a deliberate
input-handling decision, inherited from
[flags-design.md](flags-design.md) §5, and this specification does not change it.

What it *does* change is where the leniency comes from. It is a property of how
user input is **translated**, not of how a constraint is interpreted: for a user
value `f = b`, the constraint is the disjunction

> `(f is b)  ∨  (f is not declared)`

in the atoms of §2.2 — the leniency written out, rather than smuggled into the
meaning of a single atom.

That distinction is the point. §5 of the earlier design intended leniency to
apply to **user constraints only**, but obtained it from a global rule in
membership ("a constrained-but-undeclared flag is vacuously satisfied"), and a
global rule cannot be scoped: it applies equally to constraints the solver
derives itself, where the strict reading is the required one — negating a
decision must exclude exactly that instance and nothing else. One rule was
serving two masters, which is how the strict/lenient confusion started. With a
three-case atom (§2.3) both readings are expressible, so each boundary states the
one it means, and a strict mode for user flags stays available if it is ever
wanted.

A package's own conditional branches are *not* affected by any of this: they are
never solver-level flag constraints. They are evaluated at the chosen assignment
(§4.1), where every declared flag has a value and the question does not arise.

## 2. The constraint language

### 2.1 Terms and relations are PubGrub's, unchanged

`references/pubgrub.md:84`–`:121` defines terms, satisfies/contradicts/
inconclusive, and the identities `S satisfies t ⟺ ⋂S ⊆ t` and
`S contradicts t ⟺ ⋂S ∩ t = ∅`. All of it applies verbatim with "set of
versions" read as "set of instances". Nothing about flags changes the algorithm;
flags change only what a *set of values* has to be able to say.

### 2.2 Atoms

A constraint on one package denotes a set of that package's instances. Because
the flag is part of the value rather than a variable of its own (§1.4), such a
constraint has to be able to talk about flags, and it is built from two kinds of
atom:

1. **version**: the version lies in a version range;
2. **flag**: a statement about one flag name.

A flag atom must be able to express all three mutually exclusive cases:

| atom | true of instance `(v, α)` when |
|---|---|
| `f` is on | `f ∈ dom α` and `α(f) = True` |
| `f` is off | `f ∈ dom α` and `α(f) = False` |
| `f` is not declared | `f ∉ dom α` |

### 2.3 Why three cases, and not two

**Requirement: the language must be closed under negation.** Difference is not
optional — PubGrub computes contradiction and satisfaction from set difference
and intersection (§2.1), and a negation that is not exact is a wrong answer.

Negating a flag atom needs all three cases:

```
¬(f is on)  =  (f is off) ∨ (f is not declared)
```

Both two-case readings fail, in opposite directions, and we have now shipped
each of them:

- **Strict** — "undeclared makes the atom false", with no way to say
  "not declared". Then `¬(f is on)` collapses to `(f is off)`, which silently
  drops every instance that lacks `f`. Difference comes out **too small**. This
  is unsound: too small a difference reports satisfaction that does not hold, so
  the solver can derive an incompatibility that is not entailed and report a
  failure for a solvable problem. This is what the implementation did, and it is
  observable — a version declaring no flags vanished from `A ∖ B` while being in
  `A` and not in `B`.
- **Lenient** — "undeclared makes the atom vacuously true", the rule
  [flags-design.md §2 "Domain-freedom principle"](flags-design.md) chose. Then
  the atom `f is on` also covers instances lacking `f`, and its negation covers
  them again. Difference comes out **too big**. That is the safe direction
  (§3, O4) but it is still not exact, and it makes two different constraints
  denote the same set for reasons no operation can see.

The three-case atom is the Boolean closure of either reading. It is the only one
under which every set operation is exact, and it needs no knowledge of `D`:
whether `f ∈ dom α` is a question about the *instance*, and §1.2 guarantees the
instance answers it.

What is rejected here is the lenient *atom*, not lenient *behaviour*. Both
readings above remain expressible — strictly, as `f is b`; leniently, as
`(f is b) ∨ (f is not declared)` — so each boundary says which it means. §1.6 is
where the lenient one is still required.

### 2.4 Closure and canonicity

The set language must be closed under intersection, union and difference. It is
**not** required to have a canonical form: the solver only ever asks emptiness
questions (§2.1), never equality of representations. Semantic equality, where
needed, is mutual containment.

### 2.5 Intensionality

A constraint over a range of versions must not cost one entry per version.
PubGrub names this as one of the things separating it from CDCL and answer-set
solving (`references/pubgrub.md:1172`): expanding a range into concrete versions
costs overhead *and* has to be undone to talk to users.

The same requirement applies to the flag axis: a constraint mentioning `f` over
N versions must not become N constraints, one per version's own `f`. Keying
flags by version is therefore excluded — not as a matter of taste, but because
it is the enumeration §2.5 forbids and because the version axis is open (naming
"every version except this one" is required, and a per-version keying cannot).

## 3. Obligations

Let `⟦X⟧` be the set of instances a constraint `X` denotes under the actual `D`.
Call `X` **vacuously empty** if `⟦X⟧ = ∅` for *every* possible `D` — that is,
empty for reasons internal to the constraint (an empty version range, or a flag
required to be two different things at once), not because of what some version
happens to declare.

- **O1 — membership is exact.** Whether a given instance satisfies a given
  constraint is decidable from the instance alone, and must be answered exactly.
- **O2 — intersection, union and difference are exact.**
  `⟦A ∩ B⟧ = ⟦A⟧ ∩ ⟦B⟧`, and likewise for `∪` and `∖`. No slack. §2.3 exists to
  make this achievable.
- **O3 — emptiness is one-sided.**
  - *(a, soundness)* if the emptiness test says empty, then `⟦X⟧ = ∅`;
  - *(b, completeness where it must be)* if `X` is vacuously empty, the test
    must say empty.

  Between (a) and (b) there is deliberate slack: a constraint pinning a flag
  that no version in its range declares is empty under the actual `D`, and the
  test is permitted not to notice, because noticing requires `D` (§1.1). *Being
  wrong in the other direction is forbidden.*
- **O4 — imprecision may only produce "inconclusive".** From §2.1, satisfaction
  and contradiction are emptiness questions about `⋂S ∖ t` and `⋂S ∩ t`. Under
  O2 those sets are exact, so an emptiness test that only ever *under*-claims
  emptiness (O3a) can only fail to report Satisfied or Contradicted — never
  report one wrongly. Therefore no incompatibility is ever derived that is not
  entailed: no wrong "no solution", and no wrong solution either.
- **O5 — progress.** O3b is what keeps O4 from meaning "the solver may do
  nothing". In particular, when the provider reports that a package has no
  admissible instance in the offered set, the resulting incompatibility must be
  detected as satisfied — which it is, because that question reduces to
  `R ∖ R`, vacuously empty. Every derivation the solver performs on its own
  output must rest on vacuous emptiness, never on `D`.
- **O6 — the provider is the only thing that knows reality.** It must offer only
  admissible instances that the index really has; the assignment it offers must
  be total per §1.2; it must report "none" rather than inventing one; and the
  dependencies it reports must be the dependencies **at exactly the assignment
  the offered instance pins**. Nothing else may consult `D`.
- **O7 — no query may enumerate a package's instances.** Follows from §2.5, and
  is why O6 is a provider obligation rather than something the algebra could do
  for itself.

## 4. Dependencies

### 4.1 What an instance depends on

For an instance `(v, α)`, resolve the fixed environment (OS, architecture,
compiler) concretely, evaluate every flag condition at α, take the dependencies
of the components in scope, and intersect duplicate constraints on the same
dependency. The result is a function of `(p, v, α)` alone.

### 4.2 What an incompatibility may claim

"`D` depends on `q` in range `R`" is valid exactly when **every** instance in
`D` has that same constraint on `q`. This is what licenses collapsing: PubGrub
requires identical dependencies of adjacent versions to become one
incompatibility, with the depender's range running from the first version that
has the dependency to the first that does not
(`references/pubgrub.md:456`, and `:476` for the inadmissible case).

Flags make the grouping two-dimensional: the same version under different
assignments may have different dependencies, so the group is defined by the
dependency set, and the depender constraint must be one that denotes exactly
(or at most) that group. §2.3 is what makes the natural group expressible —
"these versions with `f` off, together with the versions that never declared
`f`" is a constraint, not an enumeration.

### 4.3 Reports

A depender constraint appears verbatim in the explanation, so it must render as
something a user can act on: cabal range syntax plus a readable statement of the
flag conditions. "Some flag is not declared" is part of the language and can
appear in a report; it should read as such rather than as an internal marker.

## 5. Choice policy is not semantics

Any admissible instance may be chosen. Which one is preferred is **policy**:
changing it changes the solution found and the time taken, never whether a
problem is solvable. Two policy statements this project adopts, both revisable
without touching anything above:

- an instance's assignment defaults to the declared defaults of its version;
- a flag is only moved off its default when a conflict forces it — no
  speculative exploration of the assignment space.

## 6. Testing obligations

The semantics above is only worth writing down if a test can fail when it is
violated. Two rules, both learned the hard way:

- **A model-based test must use a universe in which versions differ in which
  flags they declare, including a version that declares none.** Both this
  project's property suite and the earlier design spike validated their laws on
  a universe where every version declared the same two flags — which is exactly
  why the same gap survived being "validated" twice. A uniform universe cannot
  distinguish any of the three readings in §2.3.
- **Test emptiness one-sided.** `isEmpty ⟹ model empty` (O3a), plus a separate
  property that vacuously empty constructions *are* detected (O3b). Asserting
  `isEmpty ⟺ model empty` asserts something this specification does not
  promise, and will fail on correct code.

Everything derived from emptiness (containment, disjointness, and the
term-relation) must likewise be tested in the direction O4 permits: never
wrongly Satisfied or Contradicted, allowed to be Inconclusive.

## 7. Non-goals

- flag preference heuristics beyond §5;
- any relationship between flags of different versions (§1.3) or of different
  packages — there is no global flag;
- exploring manual flags (§1.5);
- setup/build-tool dependency scopes, sublibraries, Backpack — other rungs, and
  none of them change §2 or §3.

## 8. To verify or decide

- **Manual flags.** cabal's solver does not treat a manual flag as freely
  choosable, but the exact rule (default only? user value only? interaction with
  `--flag`?) is asserted from memory in §1.5 and must be checked against
  `cabal-install-solver` before we implement it. The source is not vendored
  here.
- **Whether to give the algebra access to `D`.** It would make emptiness exact
  and delete the O3 slack, at the cost of the boundary in §1.1 and of O7. The
  slack is believed harmless (O4); this is a cost/benefit decision, not a
  correctness one.
- **Sub-library and component-level flags** interact with §4.1's "components in
  scope"; deferred with the rung that introduces them.

## 9. Worked example: learning that a flag must leave its default

`references/pubgrub.md` carries an Examples section for the same reason this
exists — a trace pins down what the prose means. This one also serves as the
**acceptance criterion**: if it cannot be reproduced, the semantics above is not
implemented.

Note what the example is *not*. There is no flag preference beyond §5's
"default first", no search over assignments, and no code that knows about flags
at all beyond the provider. The flip is the negation of something the solver
learned.

### The world

```
myapp (local)     depends on  parser >=1.0 && <2

parser 1.0        flag simd (default: True)
                  when +simd:  depends on simd-utils ==0.3
                  when -simd:  no extra dependencies
                  — the only version of parser on the index

simd-utils 0.3    depends on  base >=4.22
                  — the only version

base 4.21.0.0     pre-installed, boot package: the only base obtainable
```

`base` bounds elsewhere are omitted: they would be satisfied immediately and add
nothing to the trace.

### The trace

| # | incompatibility | source |
|---|---|---|
| (1) | `{myapp 0.1, not parser >=1.0 && <2}` | myapp's dependency |
| (2) | `{parser 1.0 +simd, not simd-utils ==0.3}` | dependency of the decided instance (§4.1) |
| (3) | `{simd-utils 0.3, not base >=4.22}` | dependency of the decided instance |
| (4) | `{base >=4.22}` | provider reports no instance (O6) |
| (5) | `{simd-utils 0.3}` | conflict resolution, (4) + (3) |
| (6) | `{parser 1.0 +simd}` | conflict resolution, (5) + (2) |

**Level 1.** Decide `myapp 0.1`. (1) becomes almost satisfied, so derive
`parser >=1.0 && <2`.

**Level 2.** Decision making for `parser`. The accumulated constraint pins no
flag, so the provider completes the assignment from the version's declared
default — `simd` defaults to `True` — and offers `parser 1.0 +simd`. Its
dependencies are read at *exactly* that assignment (O6), giving (2). Derive
`simd-utils ==0.3`.

**Level 3.** Decide `simd-utils 0.3`, giving (3). Derive `base >=4.22`.

**Conflict.** Decision making for `base`: the accumulated constraint is
`base >=4.22`, and the only obtainable `base` is the pre-installed 4.21.0.0,
which is not in it. The provider reports no instance, so (4) is added — and (4)
is *satisfied* by a derivation already in the partial solution. Resolve: (4)
with (3) gives (5), and (5) with (2) gives **(6)**.

**Backjump to level 1**, discarding the `parser` and `simd-utils` decisions while
keeping (6) and the derivation `parser >=1.0 && <2`.

**The learning step.** (6) is a unit incompatibility, so propagation derives its
negation, which in the atoms of §2.2 is a three-way disjunction:

```
not (parser 1.0 +simd)
  =  parser ≠ 1.0                     ∨    (no such version on the index)
     parser 1.0 with simd off         ∨    ← the live one
     parser 1.0 not declaring simd         (empty here: 1.0 does declare it)
```

intersected with `parser >=1.0 && <2`. Decision making runs again; the provider
enumerates `parser`'s versions, finds 1.0, and completes the assignment from the
surviving constraint — which now **pins `simd` to False**. Decide
`parser 1.0 -simd`, whose dependency set at that assignment is empty. The solve
succeeds.

### What the trace establishes

**The flip is learned, not preferred.** The solver decided instances, derived
`{parser 1.0 +simd}` by ordinary conflict resolution, and read the flip off that
unit incompatibility. Remove §5's default-first policy and the same trace runs
with a different starting instance; the *verdict* is unchanged, as §5 claims.

**Where the third case of §2.3 earns its place.** Two of the three disjuncts are
empty in this world, which is exactly why a two-valued pin looks adequate. Add a
`parser 1.1` that dropped the `simd` flag: the third disjunct is what admits it,
and under a two-valued pin the propagation of (6) would silently exclude
`parser 1.1` from a range it belongs to. This step is the one to reproduce when
testing §2.3 — and per §6 it needs a world where versions differ in what they
declare, which is precisely this one.

**The price from §1.4, made concrete.** Give `parser 1.0` a second, irrelevant
flag `docs`. Then (2) and (6) name `parser 1.0 +simd +docs`, so propagation
leaves `+simd -docs` open: the solver offers it, re-reads the same dependency,
fails identically, learns `{parser 1.0 +simd -docs}`, and only then reaches
`-simd`. Two flags, two wasted rounds; k irrelevant flags, 2^k. Dependency
collapsing (§4.2) is what removes it — the depender term becomes "1.0 with simd
on, any `docs`" — which is why §1.4 names collapsing as the answer to this cost
rather than a change of model.

**If `-simd` also failed**, the same machinery yields the failure report and the
flag appears in both polarities, as separate causes. That shape is already
observable today.
