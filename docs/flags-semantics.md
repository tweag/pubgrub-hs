# Specification: flag semantics

> **Status:** specification. It says what must be *true*, not how to represent
> anything. No types, no data structures, no functions — those are derived work.
>
> **Implemented by:** `src/PubGrub/InstanceSet/SourceCell.hs` (`FlagPin`, the cell
> algebra), `src/PubGrub/InstanceSet.hs` (membership), `bridge/Bridge/Provider.hs`
> and `bridge/Bridge/Cabal/Flatten.hs` (the O6 provider obligations). The guards
> for §3 and §6 are in `test/InstanceSetSpec.hs`; the end-to-end cases are in
> `test/FlagSolveSpec.hs`. **§10 records which obligations actually hold today**,
> which are satisfied only accidentally, and what is coupled to what — check it
> before relying on any of them.
>
> **Authority:** on the questions it answers, this file wins over
> [flags-design.md](attic/flags-design.md) (which chose a different rule — see §2.3)
> and over `CLAUDE.md`. It does not overrule
> [references/pubgrub.md](../references/pubgrub.md); where PubGrub already
> decides something, this file cites it.
>
> **Reviewed** 2026-08-05 —
> [flags-semantics-review.md](flags-semantics-review.md). Its verdict was that the
> core three-state model is sound, and that four claims overreached their own
> arguments. All four are now folded in: §1.5 and §1.6 (who owns the manual-flag
> rule), §2.5 (a project decision, not a PubGrub requirement), §5 (the recipe must
> consume an O6-complete search), and O4 (a local result, not a whole-solver one).
> The review is kept as the record of why those changed.

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
of a package. Two versions of one package may declare different flags, and either
may declare none.

Write it `D(ρ)`, where ρ is a **source release identity**: enough to fix one
package description, which is the package name, the version, *and* whichever
source or index revision the description was read from. `(p, v)` is not a
sufficient key — the same name and version can come from different sources, and
this project's index reader resolves `.cabal` revisions last-wins, so ρ is
`(name, version, chosen revision)` in practice. The distinction is dormant while
a solve reads one index, and stops being dormant the moment local packages or a
second source enter.

`D` is index data. Only the bridge can answer it; the core algebra cannot, and
per the architecture boundary must not try.

### 1.2 An instance

The value of a solver variable is an **instance**: one concrete way of having a
package. Either a pre-installed unit, or a source release together with a flag
assignment α where

> **dom α = D(ρ), exactly.**

`D(ρ)`, not `D(p, v)`: ρ is the release identity of §1.1, and the distinction is
the one §1.1 just made — the same name and version from a different source or
revision is a different description with different declared flags. It is dormant
while a solve reads one index and stops being dormant with local packages or a
second source, at which point **the instance value must also retain ρ**, since a
version plus a flag assignment cannot tell two such releases apart.

Totality is the load-bearing half (no conditional is left unresolved); exactness
is the half we keep forgetting (α never mentions a flag the version does not
declare, so "α has no value for `f`" is meaningful and observable).

Totality is a property of an **instance**, and is demanded wherever an instance is
produced — under condition decisions
([decision-semantics.md](decision-semantics.md)) that is the witness of D1, not any
decision: decisions there are terms and pin only what a guard made relevant.

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
question instead of a triviality.

The alternative's advantage is narrower than it first looks, and worth stating
precisely. Under a clause `{foo 1.2, foo:fast, not vector >=0.12}` the flag is a
literal, so **flags the failure does not involve never enter the clause at all** —
that is the whole of the win. It is *not* "conflict resolution learns that `fast`
is bad for every version": the clause still names `foo 1.2`, and a flag variable
shared across versions would anyway impose exactly the cross-version identity §1.3
denies, while a version-keyed one would not generalise either. The honest
comparison is therefore: a shared flag variable may generalise more but imposes an
identity Cabal does not have; a version-keyed one keeps the semantics and needs
conditional-existence machinery.

Here, each `(version, assignment)` pair is its own atom, so — *absent §4.2* — an
irrelevant flag enters the learned incompatibility, and a version rejected for a
flag-irrelevant reason is re-offered once per irrelevant assignment. That was the
price. It is recoverable **inside this model** — per-fact dependency collapsing
(§4.2) keeps irrelevant flags out of the depender term, which is precisely the
alternative's advantage — so the answer to the cost is collapsing, not a change of
model.

**And that answer has now been carried out** (§4.2 is implemented, §10), which
settles the argument of this section empirically: the cost the rejected alternative
was supposed to avoid was removed without adopting it. Read the rest of §1.4 as the
reasoning that led there, not as a description of current behaviour.

**Status.** Revisited 2026-08-04:
[decision-semantics.md](decision-semantics.md) collects the alternative's
advantage — irrelevant flags never enter clauses *or decisions* — without flag
variables: decisions generalise to condition terms on the package variable, made
under a decided version, so conditional existence never arises. The modelling
choice recorded here (the flag lives in the value) is unchanged and is what makes
that generalisation cheap.

Nothing in §2 or §3 depends on this choice being the right one; if the retry cost
ever dominates, this is the decision to revisit, and §2.3 largely dissolves when it
is. It is recorded here as a decision with a price, because the previous record of
it (see [flags-design.md](attic/flags-design.md) §1) gave a reason that does not
hold — invasiveness of a type substitution — and omitted the price entirely.

**Consequence for the rest of this document.** A constraint that mentions `f` is
evaluated **per instance, against that instance's own α**. Sharing a name across
versions is syntax, not identity.

### 1.5 Not every instance is admissible

Three notions have to be kept apart, because collapsing them means enforcing the
same rule in two places and letting the two readings drift — which is how §1.6's
question went wrong the first time:

1. **The universe** — the releases that exist *and could be interpreted*. A
   release whose package description the bridge cannot parse is not in the
   universe: it is skipped, and the skip must be **reported**, not silently
   folded into "no such version" (§3, O6). Suppressing it can otherwise produce a
   no-solution proof that is misleading rather than wrong.
2. **Intrinsic admissibility** — a property of an instance alone, independent of
   the partial solution:
   - the components in scope are buildable under α. A `buildable: False`
     reachable only under some assignments makes exactly those instances
     inadmissible, and PubGrub asks for that to be expressed as "never select
     this" rather than as dependencies (`references/pubgrub.md:476`);
   That is the whole of it. **Manual flags are deliberately not on this list** —
   see below.
3. **Eligibility for a query** — intrinsic admissibility *plus* membership in the
   accumulated constraint the solver is asking about.

**Manual flags belong to input translation, not to admissibility.** An earlier
draft put them here, as "every manual flag takes its declared default unless the
user set it", and that cannot hold: §1.6 says user flag values are translated once
and never re-checked by the provider, so if admissibility mentioned "unless the
user set it" then `Adm` would be parameterised by user input and the *same*
instance would change admissibility depending on what the user typed. Two rules,
one owner, exactly the drift this section exists to prevent.

The division that works, and it is all translation (§1.6):

- **no user value for a manual flag `f`** — translate the manual-default rule into
  an initial constraint, `(f is default) ∨ (f is not declared)`, leniently as §1.6
  requires;
- **a user value for `f`** — translate that value instead, by the same rule;
- **the provider's notion of admissibility never mentions user input at all.**

This matches what cabal does: `enforceManualFlags` lets only the default survive
when the flag is unconstrained, and admits the mentioned values when the user names
it, after which ordinary constraint enforcement picks. The behaviour is unchanged
from the earlier draft; what changed is which layer owns it. (And it is no longer
asserted from memory — see §8.)

Note that intrinsic admissibility is **assignment-dependent**: whether an
instance is buildable can depend on α. That is what makes O6's completeness
obligation non-trivial rather than a corollary of the representation.

User flag constraints are deliberately **not** on this list. They are input, not
a property of a release: they are translated once into an initial solver
constraint (§1.6), so the provider's universe stays independent of them.

### 1.6 User flag constraints are lenient

A user-supplied flag value applied to a package version that does not declare
that flag is **not** an error and excludes nothing. `--flag=+fast` against a
version with no `fast` flag simply says nothing about it. Only versions that
declare `fast` and set it `False` are excluded. This is a deliberate
input-handling decision, inherited from
[flags-design.md](attic/flags-design.md) §5, and this specification does not change it.

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

User input is translated **once**, at this boundary, and enforced only as a solver
constraint — never re-checked inside the provider's notion of admissibility
(§1.5). One owner, one reading.

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

A flag atom must be able to distinguish all three mutually exclusive
**observational cases**:

| case | true of a source instance `(ρ, α)` when |
|---|---|
| `f` is on | `f ∈ dom α` and `α(f) = True` |
| `f` is off | `f ∈ dom α` and `α(f) = False` |
| `f` is not applicable | `f ∉ dom α` |

Three *cases*, not necessarily three primitive atoms: predicates `declared(f)` and
`value(f)` induce the same partition, and this specification does not choose a
syntax. What it does require is that the partition be expressible, which is what
§2.3 is about.

**Pre-installed units.** An installed unit has no solver-controllable flags at
all, so for it:

| case | value |
|---|---|
| `f` is on | False |
| `f` is off | False |
| `f` is not applicable | True |

"Not applicable" is the operational reading — *absent from this instance's
solver-visible flag domain* — and is why the third case is not called "not
declared" here: the source that produced an installed unit may well have declared
`f`; what is absent is any assignment the solver could choose. If a report ever
names this case for an installed unit it should say "not applicable", not "not
declared".

Note the consequence, since it is easy to mistake for a defect: a flag *request*
cannot exclude an installed unit. That is correct — an installed unit's flags are
already baked, so the request can be neither honoured nor violated — and it is
what the lenient translation of §1.6 delivers, `(f is b) ∨ (f is not
applicable)`. It also means a constraint carrying flag conditions must carry its
installed instances as a separate disjunct; a representation that keeps the
installed side extensional gets this structurally.

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
  [flags-design.md §2 "Domain-freedom principle"](attic/flags-design.md) chose. Then
  the atom `f is on` also covers instances lacking `f`, and its negation covers
  them again. Difference comes out **too big**. That is the safe direction
  (§3, O4) but it is still not exact, and it makes two different constraints
  denote the same set for reasons no operation can see.

The three-case partition is the Boolean closure of either reading. It is the
minimal one under which every set operation is exact, and it needs no knowledge of
`D`: whether `f ∈ dom α` is a question about the *instance*, and §1.2 guarantees
the instance answers it.

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
N versions must not become N constraints, one per version's own `f`.

**Where the cited authority stops.** `:1172` establishes that a version constraint
must not be expanded into one atom per concrete version. It does *not* establish
that every conceivable release-scoped or lazily-instantiated flag-variable design
must enumerate the version axis — some would not. So keying flags by version is
**this project's design decision, not a PubGrub requirement**, and the honest
reasons are the ones §1.4 gives: such designs need conditional-existence
machinery, complicate incompatibilities, and either impose a cross-version flag
identity §1.3 denies or fail to generalise. An earlier draft of this section said
the exclusion followed from `:1172` "not as a matter of taste"; that overstated
what the citation supports.

The version axis being open is a real constraint on any such design and is worth
keeping in view: naming "every version except this one" is required, and a
per-version keying cannot express it.

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
  report one wrongly. What follows is therefore, precisely:

  > Every relation the implementation positively reports, and every unit
  > propagation performed from such a relation, is semantically sound.

  **That is a local result, and it is the only one O4 gives.** It does *not*
  follow that the solver's verdict is unaffected. An earlier draft concluded "no
  wrong 'no solution', and no wrong solution either", which overreaches its own
  argument: conflict resolution locates the *earliest* satisfier and derives a
  backjump level from it, so noticing satisfaction later than it semantically
  occurs could change which incompatibility is learned, whether it is asserting
  after backjumping, and whether the loop progresses. §6 already says this and
  owes the verdict oracle; O5 discharges one case (the provider's `{X}`,
  recognisable through `R ∖ R`) and not the loop. The formal model draws the same
  line — relation and propagation soundness use conservative emptiness, while the
  satisfier-search results in `specification/PubGrub/PartialSolution.lean` require
  exact emptiness.

  So: sound per query, unproven per solve. Treat the whole-loop claim as owed, not
  held.
- **O5 — progress.** O3b is what keeps O4 from meaning "the solver may do
  nothing". In particular, when the provider reports that a package has no
  admissible instance in the offered set, the resulting incompatibility must be
  detected as satisfied — which it is, because that question reduces to
  `R ∖ R`, vacuously empty. Every derivation the solver performs on its own
  output must rest on vacuous emptiness, never on `D`.
- **O6 — the provider is the only thing that knows reality, and it must be both
  sound and complete.** Writing `choose(p, X)` for the request "give me a value
  for `p` from `X`", and `Adm(p)` for the intrinsically admissible instances of
  `p` drawn from the universe (§1.5):

      choose(p, X) = Some i   ⟹   i ∈ Adm(p) ∩ ⟦X⟧
      choose(p, X) = None     ⟺   Adm(p) ∩ ⟦X⟧ = ∅

  The `⟸` half of the second line is the easy one; the **`⟹` half is the
  obligation that matters**, and it is not a formality. PubGrub turns "no
  candidate" into the external incompatibility `{X}`, which forbids the entire
  offered set — so a `None` that should have been a `Some` is a false external
  fact, and yields a confident "no solution" for a solvable problem. Note it is
  *stronger* than "the provider may test its preferred assignment": it must find a
  satisfying admissible assignment if one exists.

  Two lemmas are needed, and only the first is a property of the representation:

  - **Cell completion.** If a fixed release has any instance in a conjunctive cell
    `C`, then completing `C`'s free flags at their declared defaults yields an
    instance in `C`. (Each flag is constrained independently, so any completion of
    the free ones stays inside.)
  - **Provider completeness.** If `Adm(p) ∩ ⟦X⟧ ≠ ∅` then `choose(p, X) ≠ None`.

  The first does **not** imply the second, because intrinsic admissibility is
  assignment-dependent (§1.5): a release with `if flag(f) buildable: False` and
  `f` defaulting to `True` has an admissible instance in the unconstrained cell,
  while the default completion of that cell is inadmissible.

  So completeness is discharged by **searching**: the provider may not stop at one
  completion per cell. There is no alternative to searching — but the search is
  cheap and explicable because *the reason a completion is inadmissible is itself a
  constraint*. "Unbuildable when `f` is on" is the constraint `not (f is on)`, and
  it can be used twice over:

  - **locally**, intersected into the set being searched, which removes the whole
    inadmissible region rather than one completion at a time;
  - **globally**, returned as an incompatibility, so propagation gets it and the
    proof can say *why* — which is what PubGrub asks for at
    `references/pubgrub.md:476` ("add an incompatibility indicating that it should
    never be selected" **instead of adding its dependencies**).

  Both are the same fact; neither replaces the search. Note what `:476` does *not*
  say: nothing there requires the provider to decline to decide. A rejected
  completion's incompatibility travels back with whatever instance the provider
  does settle on (§10), so no interface case is needed for it.

  Also: the assignment offered must be total per §1.2; the dependencies reported
  must be those **at exactly the assignment the offered instance pins**; and
  nothing outside the provider may consult `D`.
- **O7 — the algebra may not enumerate instances; the provider may enumerate
  releases.** Precisely: no operation of the constraint algebra, and no
  term-relation query, may enumerate a package's concrete instance universe. The
  provider *may* enumerate available releases and construct assignments lazily,
  but may not materialise the version × assignment product. This is what §2.5
  requires and what candidate selection needs, and the earlier blanket wording
  ("no query may enumerate a package's instances") wrongly forbade the latter.

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

**Per dependency fact, not per dependency set.** The unit is one *guarded
dependency occurrence* `C ⇒ q ∈ R`, where `C` is the flag condition guarding it:

> An incompatibility `{D, not q ∈ R}` is **sound** when every instance denoted by
> `D` satisfies `C`, and therefore has that dependency fact. The instances' *other*
> dependencies are irrelevant.

Grouping by the whole dependency set instead would be a serious mistake, not a
conservative one: two assignments that agree on `simd-utils` but differ on an
unrelated documentation dependency would fail to group, so the depender term
would still name the irrelevant flag — and the 2^k re-offer cost that collapsing
exists to remove would survive it intact.

Soundness and policy are separate, and only the first is a requirement:

- *soundness*: every instance in `D` has the fact. A singleton `D` satisfies this,
  which is why the per-instance form we emit today is correct but useless.
- *policy*: make `D` as general as is practical, above all by **omitting flag
  conditions the guard does not mention**. PubGrub describes collapsing as a
  strategy rather than a logical prerequisite; for us it is the strategy that pays
  for §1.4's price.

What the guard does and does not buy. A `.cabal` file's conditional tree yields
guarded occurrences directly, so **the flag component of `D` is the guard** — no
enumeration of assignments, and no need to compute per-assignment dependency sets
at all. Several occurrences may constrain the same `q` (an unconditional
`q >=1`, a guarded `q <3`, a guarded `q /=2`); emit them as separate facts and let
propagation intersect them, rather than computing one effective range per
assignment, whose region would need a Boolean combination of guards. What remains
genuinely to be done is the **version** axis, and it splits in two:

- **The release's slot — free, and done (2026-08-12).** The version component of `D`
  is the half-open range from the release up to the next release *that exists in the
  index*, rather than the single version. The index's package→versions map is
  already resident, so this costs no `.cabal` read, and soundness is unaffected: the
  slot contains exactly one existing release, so the claim is still about that
  release alone and nothing is asserted about a release we have not read. What it
  buys is that adjacent slots **touch**, so the version algebra coalesces them
  instead of accumulating fragments, and a `difference` never leaves an empty
  between-releases hole for the solver to learn about separately.
- **Several releases — still open, and still needs reads.** Widening `D` across
  *distinct* releases requires knowing they have the same dependency, which means
  inspecting them — including whether each declares the flag the guard mentions at
  all, since where it does not the guard is not merely false but inapplicable
  (§2.2). Slots make this cheaper rather than harder: two adjacent slots union into
  one contiguous range with no gap to justify, so the only remaining question is the
  dependency-identity one.

### 4.3 Reports

A depender constraint appears verbatim in the explanation, so it must render as
something a user can act on: cabal range syntax plus a readable statement of the
flag conditions. The not-applicable case (§2.2) is part of the language and can
appear in a report; it must read as a fact about the package rather than as an
internal marker — "does not have a `simd` flag" for a source release, "not
applicable" for an installed unit, never a bare sigil.

## 5. Choice policy is not semantics

Any admissible instance may be chosen. Which one is preferred is **policy**:
changing it changes the solution found and the time taken, never whether a
problem is solvable.

Measure an assignment by its **deviation** from the release's declared defaults:

    cost(ρ, α) = |{ f ∈ D(ρ) | α(f) ≠ default_ρ(f) }|

The policy this project adopts, in two parts because the axes are ordered:

1. **Between releases**, newest first. (PubGrub deliberately leaves version choice
   to the provider.)
2. **Within a release**, fewest deviations first:

   > For a fixed source release, the provider does not choose an assignment with
   > more deviations from the declared defaults while an admissible assignment
   > with fewer deviations satisfies the accumulated constraint.

Directly implementable as: test the all-default assignment for the release first,
and consider non-default assignments only once it is excluded or inadmissible.

Two ways to get this wrong, both of which we have written down at some point:

- "a flag only moves when a conflict forces it" is not a policy. When the
  accumulated constraint says only `not (+simd +docs)`, *something* must decide
  which flag moves; the constraint does not.
- ranking candidate cells by **number of pins** is not the same as ranking
  assignments by deviation. A one-pin cell `f = False` beats a two-pin cell
  `f = True, g = True` on pin count, yet with both flags defaulting to `True` the
  second is the all-default assignment and the first is a deviation. The cost is a
  property of the *completed assignment*, never of the constraint that produced
  it.

**This section is policy over an O6-complete search, and cannot substitute for
one.** State it that way round: *enumerate the admissible members of the offered
set in nondecreasing deviation cost, deduplicate assignments arising from
overlapping cells, and take the first* — with a deterministic tie-break.

An earlier draft gave the recipe as "complete each candidate cell, drop
non-members and inadmissible completions, deduplicate, then order by cost". Read
with §5's own vocabulary, "complete each candidate cell" means *its default
completion*, so if that one completion is inadmissible the cell is discarded
without the rest of it being tried — which is exactly the false `None` that O6 and
§10 warn about. Dropping a *non-member* is fine; dropping a cell because one
completion of it was **inadmissible** is not.

That recipe is sound only while admissibility is assignment-independent, which is
the accident §10 records. It stops being sound the moment §1.5's buildability
lands, and it is therefore part of that one work item and not a separate cleanup.

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

- **The one-sided properties are necessary and not sufficient, so a verdict
  oracle is owed.** O4 argues that a conservative emptiness test can only produce
  `Inconclusive` for a single relation query. That is *not* a proof that the
  algorithm is unaffected: conflict resolution locates the earliest satisfier of
  an incompatibility and derives a backjump level from it, so detecting
  satisfaction later than it semantically occurs could in principle change which
  incompatibility is learned, whether it is asserting after backjumping, and
  whether the loop makes progress. O5 discharges one case (the provider's `{X}`,
  recognisable through `R ∖ R`), not the loop.

  The obligation is a **brute-force verdict oracle** over generated finite
  worlds — not a second solver. Enumerate all legal selections directly (at most
  one instance per package; reachable from the root with no extras; intrinsically
  admissible; every selected instance's dependency facts satisfied; translated
  user constraints satisfied) and assert:

      solver succeeds  ⟺  the oracle's solution set is non-empty
      the solver's answer, when it succeeds, is in that set

  plus a step bound or repeated-state detector, which is what actually catches a
  lost-progress regression. This is not a termination proof; it tests the risk
  conservative emptiness creates far more directly than set-level properties can.

  It must include a generated world in which **the default completion of a cell is
  inadmissible while a non-default completion of the same cell is admissible** —
  that case, and only that case, decides whether the implementation satisfies
  O6's completeness half.

## 7. Non-goals

- flag preference heuristics beyond §5;
- any relationship between flags of different versions (§1.3) or of different
  packages — there is no global flag;
- exploring manual flags (§1.5);
- setup/build-tool dependency scopes, sublibraries, Backpack — other rungs, and
  none of them change §2 or §3.

## 8. To verify or decide

- **Manual flags — no longer a memory claim, and the owner is now settled.** The
  behaviour is supported by `enforceManualFlags` in
  `cabal-install-solver`'s `Distribution.Solver.Modular.Preference`: with the flag
  unconstrained only the default survives, and when the user names it the mentioned
  values are admitted, after which ordinary constraint enforcement selects. The
  source is not vendored in this repository, but there is an adjacent Cabal
  checkout, so this is checkable locally rather than recalled.

  §1.5 previously listed the rule under *admissibility*, which contradicted §1.6;
  it is now stated as **input translation**, which is where §1.6 puts every other
  user flag value. What remains open is only the qualification for multiple package
  goals, and whether we want a strict mode.
- **Whether to give the algebra access to `D`.** It would make emptiness exact
  and delete the O3 slack, at the cost of the boundary in §1.1 and of O7. The
  slack is believed harmless (O4); this is a cost/benefit decision, not a
  correctness one.
- **Sub-library and component-level flags** interact with §4.1's "components in
  scope"; deferred with the rung that introduces them.
- **Whether to split the provider back into "pick" and "consequences".** Design
  item, not a decision. The interface was two functions before it was merged into
  one `expand`, and the reference implementation still is: `choose_version`
  (policy) plus `get_dependencies` returning `Available | Unavailable(reason)`,
  where the rejection path adds the "never select this" fact and **loops back to
  propagation without deciding** (`references/pubgrub/src/provider.rs:91,119` and
  `solver.rs:212`; the spec-level statement is `references/pubgrub.md:476`).

  What it would buy, in the order that matters:

  1. **O6's completeness half largely dissolves.** It decomposes into "the picker
     returns some member of the offered set if one exists" — which is the
     cell-completion lemma, already proved — plus an `Unavailable` path where *the
     solver's loop* does the searching over admissibility, terminating because each
     rejection adds an incompatibility that strictly shrinks the set. The obligation
     stops being a delicate property of provider-internal code.
  2. **Propagation runs between candidate attempts.** A provider looping internally
     iterates against a snapshot of the offered set that its own discovery has just
     invalidated; the solver, told about it, can narrow other packages' terms or
     surface a conflict immediately.
  3. **The reason becomes first-class.** `Incompatibility::custom_version(p, v,
     reason)` carries an explanation. We have no equivalent, so an unusable release
     can only appear in a proof as "no instances in range" — which is a deliverable
     #1 problem, not a cosmetic one. **Folded into this item:** an `IncompatCause`
     variant carrying the reason, and the report wording for it (§4.3).

  Note what the merge's stated rationale — "the choice and its consequences travel
  together, so the solver never holds one without the other" — actually requires:
  *ordering*, not merging. The decision is recorded only after `Available`.

  Costs. Our picker needs a total flag assignment and therefore the declared flags,
  so unlike `choose_version` it must read the package description, and
  `consequences` would read it again. That prerequisite is **already in place**:
  `Bridge.Provider.releaseReader` memoises the reduced form each release needs (its
  declared flags, and its dependencies as flag-guarded groups) for the duration of
  a solve. Note it memoises the *reduced* form deliberately — retaining parsed
  descriptions instead cost 27.2 s / 904 MB on `pandoc` against 3.7 s / 83 MB with
  no cache at all. And
  `Unavailable` must not become a place to hide what the picker should have
  avoided: preferring defaults is policy and belongs in the picker (§5); only
  genuine unusability belongs in `Unavailable`.

  Schedule it with the buildability work item in §10, which it makes smaller rather
  than larger.

  **All three benefits are inherited by condition decisions.**
  [decision-semantics.md](decision-semantics.md) §10 records that completeness
  dissolving into the solver's loop, propagation running between candidate attempts,
  and rejection reasons becoming first-class all fall out of its §2–§3 without any
  change to the provider's *shape*. So this item and that one are **one scheduling
  decision, not two**: deciding the split in isolation risks paying for the same
  benefit twice. Note also that document's sequencing note, which puts §4.2 per-fact
  emission first and measurement before either.

## 9. Worked example: learning that a flag must leave its default

`references/pubgrub.md` carries an Examples section for the same reason this
exists — a trace pins down what the prose means. This one also serves as the
**acceptance criterion**: if it cannot be reproduced, the semantics above is not
implemented.

Note what the example is *not*. There is no flag preference beyond §5, and no
search over the assignment space. Nor is there any flag-specific logic in the
PubGrub kernel: unit propagation, conflict resolution and backjumping run
unchanged, and flag awareness is confined to the value-set algebra (which knows
the three cases of §2.2 and Boolean operations on them) and to the provider (which
knows declarations, defaults and dependencies). The flip is the negation of
something the solver learned.

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
negation, which by §2.2 is a three-way disjunction:

```
not (parser 1.0 +simd)
  =  parser ≠ 1.0                       ∨
     parser 1.0 with simd off           ∨    ← the live one
     parser 1.0 with simd not applicable
```

intersected with `parser >=1.0 && <2`. Note this is stated purely in instance
properties: whether the index *has* a version other than 1.0 is a separate,
provider-side question (O6), and belongs to the next step rather than to the
complement.

Decision making runs again. The provider enumerates `parser`'s releases, finds
1.0, and — per §5 — tries the all-default assignment first, which the accumulated
constraint now excludes; the surviving disjunct **pins `simd` to False**. Decide
`parser 1.0 -simd`, whose dependency set at that assignment is empty. The solve
succeeds.

### What the trace establishes

**The flip is learned, not preferred.** The solver decided instances, derived
`{parser 1.0 +simd}` by ordinary conflict resolution, and read the flip off that
unit incompatibility. Remove §5's default-first policy and the same trace runs
with a different starting instance; the *verdict* is unchanged, as §5 claims.

**Where the third case of §2.3 earns its place — and where it does not.** Not
here. Add a `parser 1.1` that dropped the `simd` flag and it is admitted by the
`parser ≠ 1.0` disjunct, whatever it declares; the not-applicable disjunct does no
work in this trace. That is worth stating explicitly because it explains how a
two-valued pin survived so long: **while a depender term names a single
release, negating a learned decision never needs the not-applicable case** — the
version disjunct always covers the other releases, and every pin the algebra
produces is attached to a range holding just the one release.

Note the hinge is "one release", not "one version": the slot form above spans a
range of version *numbers* while still holding exactly one release, so it keeps
this property intact. What breaks it is spanning two releases that disagree about
which flags they declare, which only the second bullet of §4.2 does.

The case becomes load-bearing exactly when a depender term spans several versions
while carrying a flag condition, which is what §4.2's collapsing creates. In
collapsed form the same conflict learns

```
{parser >=1.0 && <2 with simd on, not simd-utils ==0.3}
```

and the negation of the depender term, intersected with the same range, is

```
parser >=1.0 && <2 with simd off  ∨  parser >=1.0 && <2 with simd not applicable
```

where the second disjunct is the *only* thing that retains `parser 1.1`. That is
the acceptance witness for §2.3, and it is directly checkable without a solver:
for `A = parser >=1 && <2` and `B = parser >=1 && <2 with simd on`, where 1.0
declares `simd` and 1.1 does not, `A ∖ B` must contain both `parser 1.0 -simd` and
`parser 1.1`. Note it needs a world where versions differ in what they declare —
per §6, the same requirement the property suite has.

**The price from §1.4, made concrete — and since fixed.** Give `parser 1.0` a
second, irrelevant flag `docs`. *Before §4.2*, (2) and (6) named
`parser 1.0 +simd +docs`, so propagation left `+simd -docs` open: the solver offered
it, re-read the same dependency, failed identically, learned
`{parser 1.0 +simd -docs}`, and only then reached `-simd`. Two flags, two wasted
rounds; k irrelevant flags, 2^k. Dependency collapsing (§4.2) is what removes it —
the depender term becomes "1.0 with simd on, any `docs`" — which is why §1.4 names
collapsing as the answer to this cost rather than a change of model.

**Implemented 2026-08-05**, and this trace is the acceptance test for it: measured 2
expansions where it had been 3 with one irrelevant flag and 5 with two
(`test/FlagSolveSpec.hs`). The residue is bounded by the number of *guard regions*,
not 2^k over declared flags — see [decision-semantics.md](decision-semantics.md) §0
for the three costs that survive, all from a decision still being a point instance.

**If `-simd` also failed**, the same machinery yields the failure report and the
flag appears in both polarities, as separate causes. That shape is already
observable today.

## 10. What holds today

A specification nobody has checked against the code is how the last round of
confusion started, so: this is the state as of **2026-08-17**, and it is expected to
be edited whenever the tree moves.

> **Read this first, or the table below will mislead you.** Since 2026-08-17 the
> implementation runs in this specification's **degenerate case**: every flag is
> treated as manual and fixed at its declared default, on our side by resolving flag
> conditions at flatten time (`componentDepsAtDefaults`) and on cabal's by marking
> every flag manual at the shared index read. So there is exactly **one instance per
> release**, no pin is ever created, and every set the algebra sees is flag-free.
>
> **Nothing in §§1–9 changes.** The semantics are what they are whether or not the
> search explores them, and the tests still exercise them: `InstanceSetSpec` for the
> three-state algebra over a non-uniform universe (§6), and `FlagSolveSpec` for the
> provider rule, which drives the real `mkExpand` over hand-built releases whose
> guards are genuine conditions — including §9's worked trace. That coverage is the
> only reason it is safe to leave the machinery in place. What changes is which rows below are *exercised*
> rather than merely *held*, and the table now says so. This is a scope cut for a
> first release, recorded in [STATUS.md](STATUS.md)'s "Release-1 scope"; the flag axis
> is expected back, and §10's couplings are written for whoever brings it back.

| obligation | status |
|---|---|
| O1 membership exact | holds |
| O2 exact ∩ ∪ ∖ | holds (since the three-case pin); guarded by the model-homomorphism properties |
| O3a / O3b one-sided emptiness | holds; guarded by "emptiness is one-sided" |
| O4 per-query soundness | holds, and is all O4 claims since the 2026-08-05 review |
| O4 whole-loop verdict preservation | **owed, not held.** §6's oracle is the discharge; do not cite O4 for it |
| O5 progress | the provider's `{X}` case holds; the conflict-resolution loop is unproven (§6 owes the oracle) |
| O6 soundness | holds |
| O6 completeness | **latent — see below** |
| O7 enumeration boundary | holds: the algebra never enumerates, the provider enumerates releases only |
| §1.5 buildability | **implemented for one assignment** (2026-08-17): `buildableCondition` computes the condition (`buildable:` plus `pkgconfig-depends` against the machine's `PkgConfigDb`, library only), `buildableAtDefaults` evaluates it, and the provider does not offer the release. *Satisfying* the condition rather than evaluating it is the flag-axis half, still owed |
| §1.5 unbuildable as a stated fact (`pubgrub.md:476`) | not implemented — the release is silently absent, so the report says "no versions in range" rather than why |
| §1.5 manual flags | **implemented in the degenerate case** (2026-08-17): every flag is manual and no user values exist, so the translation is "take the default" and it is applied at input rather than as a solver constraint. The general rule — some flags manual, some values user-supplied — is untouched |
| §1.6 lenient user constraints | not implemented (no user flag constraints yet), and while every flag is manual they are the only thing that could move one |
| §4.1 dependencies at the decided assignment | holds; currently trivial, since there is one assignment per release |
| §4.2 per-fact collapsing | **implemented, both axes.** Flag axis 2026-08-05 (the guard is the depender's flag component); version axis 2026-08-12 (`spanningOccurrence` over adjacent releases carrying the same occurrence) — a measured trade, see [collapsing.md](collapsing.md) |
| §4.3 report wording | partial: constraints render, the not-applicable wording is not aligned |
| §5 choice policy | implemented as release-major then fewest deviations, but over a **one-completion-per-cell** search — correct only while admissibility is assignment-independent (below). Currently vacuous: one completion exists, so "fewest deviations" ranks a single candidate |
| §6 non-uniform universe, one-sided properties | in place |
| §6 verdict oracle | owed, **and blocking for condition decisions** |
| D1 determination before success | specified ([decision-semantics.md](decision-semantics.md) §3), not implemented |
| D2 progress | specified ([decision-semantics.md](decision-semantics.md) §4), not implemented |
| D3 concretisation | specified ([decision-semantics.md](decision-semantics.md) §5), not implemented |
| condition-decision emission | specified ([decision-semantics.md](decision-semantics.md) §2.2), not implemented |

Three couplings worth knowing before picking up any of it.

**O6's completeness half is satisfied, and no longer by accident — by scope.** The
original wording of this paragraph said the accident would end the moment §1.5 was
implemented. §1.5 *was* implemented, on 2026-08-17, and completeness did not break,
because the same cut made every flag manual: a release has exactly one completion, so
"the default completion is inadmissible while another completion of the same cell is
admissible" has no instances. Admissibility is assignment-dependent in the `.cabal`
file and assignment-independent in the problem being solved.

This is a **weaker** guarantee than it looks, and the weakness is the point:
completeness now rests on there being one completion, not on the search finding all
of them. The provider's one-completion-per-cell shortcut is untouched and still
unsound in general. **Whoever restores flag search restores the gap**, and must land
the O6-complete search with it — buildability will by then look like finished, tested
code rather than half of a pair.

Note this is not only a property of the code: **§5's own selection recipe was
written against that accident** and said so, until the 2026-08-05 review caught it.
§5 is now stated as policy over an O6-complete search, which means the search and
the policy land together and neither is a separate task.

**§6's required oracle case cannot be built before then either.** "A cell whose
default completion is inadmissible while another completion of the same cell is
admissible" is unconstructible while admissibility is assignment-independent. So
the oracle, the O6 search, and buildability are one work item, not three.

**O6's preferred remedy needs no new interface case.** (An earlier draft of this
section said it did. It does not.) `expand` returns
`Maybe (Instance, [Incompatibility])`, and the solver adds those incompatibilities
to its store unexamined — it never requires them to be *about* the instance just
decided, and incompatibilities are context-independent by construction
(`references/pubgrub.md:131`), so "`foo 1.2 +simd` is unbuildable" is a valid fact
whatever was decided. A provider that skips inadmissible completions can therefore
report what it learned on the way *alongside* the decision it settles on, and
"never select this instance" (`:476`) rides along with a `Some`.

There is no case where the provider needs to answer "no decision, and here is what
to learn". The one situation that falls outside the above is "every candidate was
inadmissible", where it answers `None` and the per-instance reasons are dropped in
favour of the solver's set-level "no instances in `X`". That costs explanation
quality only, and the fix belongs in the *cause* attached to that incompatibility,
not in the return type.

**This stopped being hypothetical on 2026-08-17.** The provider now skips releases
whose library is unbuildable here, and says nothing about them. Two paths follow
directly from the paragraph above, and the second is the smaller job:

- where the scan eventually settles on a release, the skipped ones' facts —
  `{ foo 1.2 }`, "never select this", `pubgrub.md:476`, collapsed over adjacent
  releases like a dependency — can ride along with the `Some`, **no interface change
  required**;
- where every release was skipped, the reasons are lost and the report reads "no
  versions in range", which is the cause-side gap above rather than a new one.

A code comment in `Bridge.Provider` briefly claimed this was blocked on `expand`
being able to answer "no decision, but learn this". It is not; only the second case
would want that, and even there the cause is the right place.

The tree already leans on the same reasoning for uninterpretable descriptions:
they are skipped with a warning and no incompatibility, which §1.5 makes correct —
a release outside the universe is not a fact to learn about, it is a release that
does not exist for this solve.

Naming: the code calls the third case `NotDeclared`, which is accurate for source
cells — pins only ever apply to the source side — while this document calls the
case *not applicable*, because for an installed unit the reason differs (§2.2).
They describe the same partition; if the divergence ever causes a
misunderstanding, rename the constructor rather than the semantics.
