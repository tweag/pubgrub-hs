# Specification: condition decisions

> **Status:** specification. Nothing in §2–§9 is implemented. §11 records the code this
> document generalises, by name rather than by line.
>
> **Dormant, and deliberately not withdrawn.** Flags are not
> a search dimension ([STATUS.md](STATUS.md) §3.1): every flag is fixed
> at its declared default, so a release has exactly one instance and the costs this
> document exists to remove — re-offering a version per irrelevant flag assignment,
> searching assignments outside the constraint store, naming uninvolved flags in every
> trace — are all currently **zero**. Nothing here is wrong. There is simply nothing
> for it to fix until the flag axis returns, at which point it becomes live again
> unchanged. Do not schedule it, and do not delete the machinery it depends on.
>
> **Prerequisite:** per-fact guarded emission,
> [flags-semantics.md §4.2](flags-semantics.md). It is restated nowhere here —
> this document assumes dependency facts arrive shaped
> `{p ∈ V × guard, not q ∈ R}`, with the guard verbatim as the depender's flag
> component, and it is inert without them.
>
> **Authority:** this document deliberately deviates from
> [references/pubgrub.md](../references/pubgrub.md) in exactly the places §1
> registers, and nowhere else. Outside §1 the PubGrub spec still wins. On flag
> semantics it defers to [flags-semantics.md](flags-semantics.md) and amends it
> only as §11 lists. Like that document, it says what must be *true* — no
> types, no data structures, no functions.
>
> **New here?** Read *Plain version* immediately below first. It is an informal
> paragraph-level summary with an analogy and a vocabulary table. §0 onwards
> assumes the vocabulary.

## Plain version

> **Informal, and not part of the specification.** Nothing here is normative: if
> it disagrees with anything below, what is below wins. It exists because the
> sections that follow are written to be precise rather than to be read in order.
> Skip it if you already have the vocabulary.

### A package is a recipe with switches

```
recipe: parser 1.0
  switch "simd"  (factory setting: ON)
  IF simd is ON   → you also need simd-utils
  IF simd is OFF  → nothing extra
```

Some switches change which ingredients you need. Most do not.

### What happens today

To choose this recipe, you must flip **every switch on the box** — including the
ones no rule mentions. Two things then go wrong.

**You redo the same work.** Give `parser 1.0` one switch that matters (`simd`) and
four that do not (`docs`, `debug`, `fast`, `pretty`). You try it. It fails, because of
`simd`. But the note you write says:

> *parser 1.0 with simd ON and docs ON and debug OFF and fast ON and pretty ON does
> not work*

That note is about **one exact setting of all five switches**. So next you flip
`docs`, and fail identically. Then `debug`. Four irrelevant switches means **16
identical failures**. Ten flags mean 1024.

**And your error messages name switches nobody touched**, because the note did. The
reader sees five switches when the answer was only ever about one.

Those are this project's two deliverables — performance and explanations — so both
halves of the scorecard are affected.

### What this document proposes

**Choose the recipe first. Touch a switch only when a rule asks about it.**

1. Decide `parser 1.0`. Say nothing about any switch.
2. A rule says *"IF simd is ON → need simd-utils."* Only now decide: `simd` is ON.
3. Switches no rule mentions are never decided at all. At the very end, write them
   down at their factory settings.

So if `simd` turns out wrong, you flip **that one switch** and keep the recipe —
today you would put the whole box back and start again from "which recipe?". And the
number of things you may have to decide is the number of **IF-rules** (usually one or
two), not the number of switch combinations.

### The trap it spends a whole section on

Add another switch:

```
switch "debug"  (factory setting: OFF)
IF debug is ON → you also need heavy-tracing
```

Nobody ever asked about `debug`, so you never decided it. You declare success. Then
you fill in the undecided switches at their factory settings — and had `debug`'s
factory setting been **ON**, you would leave with a shopping list missing
`heavy-tracing`: a rule you never checked.

Hence **D1**: before declaring success, look at the final switch settings, find every
IF-rule they turn **on**, and confirm those ingredients were actually required. Rules
your settings leave off need no attention — an ingredient list you never trigger
cannot matter. (That weaker form is deliberate. The stronger "settle every rule" was
drafted and rejected, because it burns a decision on rules the answer never touches.)

### The prerequisite: what §4.2 is

[flags-semantics.md §4.2](flags-semantics.md) is about **how you write the note**, and
it is listed above as this document's prerequisite.

Today you record the exact setting you tried. §4.2 says: do not. Look at the IF-rule
you got the dependency from —

```
IF simd is ON → you also need simd-utils
```

— which mentions **only `simd`**. So copy the rule:

> *parser 1.0, **whenever simd is ON**, needs simd-utils — regardless of every other
> switch*

One failure now rules out all 16 settings at once, because the note was never about
the other switches. And you needn't be clever to get it: the rule is already written
on the box, so you copy it rather than compute it.

> **A trap §4.2 records.** Do *not* instead group settings that need the same
> ingredients. Two settings can agree about `simd-utils` and differ about some
> unrelated documentation dependency. They then fail to group, and the irrelevant
> switch stays in the note. Copying the guard is both simpler and more correct.

The relationship in one line:

| | keeps irrelevant switches out of… |
|---|---|
| **§4.2** | your **notes** — what gets written down when something fails |
| **this document** | your **decisions** — what you commit to along the way |

**§4.2 comes first.** It fixes the 16-failures waste and the noisy messages on its
own, it is much the smaller change, and this document is *inert* without it. Build it,
measure it on real problems, and only then decide whether the rest earns its keep —
see the sequencing note at the end of §11.

### Vocabulary

| the sections below say | it means |
|---|---|
| instance | a filled-in recipe card: one recipe, every switch set |
| flag | one switch: a declared name with a factory setting |
| **guard**, condition, `C` | an IF-rule on the box — see below |
| guarded dependency occurrence | one IF-rule paired with **one** ingredient |
| version decision | "this recipe", switches left open |
| refinement decision | flipping one switch, because a rule asked about it |
| dormant | a rule nobody has asked about yet |
| witness | the finished card you actually cook from |
| emission | writing down all of a recipe's IF-rules when you pick it |
| **D1** (§3) | do not declare success with a triggered rule unchecked |
| **D2** (§4) | each flip settles a rule, and rules run out — so it terminates |
| **D3** (§5) | the answer is the finished card, not the list of choices |

### What a guard is, exactly

The word carries a lot of weight below, so: a **guard** is the flag condition
attached to a group of dependencies — the `if` in a `.cabal` file, once the parts
that do not depend on flags have been evaluated away. Given this, on Linux:

```cabal
library
  build-depends: base >=4.14, containers

  if flag(simd)
    build-depends: simd-utils ==0.3
  else
    build-depends: fallback-impl >=1

  if os(windows) && flag(fast)
    build-depends: win-fast-io
```

`Bridge.Cabal.Flatten` produces three groups, and the left column is the guards:

| guard | dependencies |
|---|---|
| `True` | `base >=4.14`, `containers` |
| `flag(simd)` | `simd-utils ==0.3` |
| `NOT flag(simd)` | `fallback-impl >=1` |

The `os(windows)` block is **gone** — not guarded, discarded. Four things follow,
each used below:

1. **Flags only.** OS, architecture and compiler conditions are resolved to a
   concrete yes/no while flattening, so a guard is always a formula over flag
   *names*.
2. **A formula, not a flag.** `flag(a) && !flag(b)` is *one* guard mentioning two
   flags. Don't picture one flag per guard.
3. **Accumulated, not nested.** Nested `if`s conjoin into a longer formula, with
   `else` branches carrying the negation. A dependency two levels deep carries both
   conditions.
4. **Per release, not per package.** A guard comes from one `.cabal` file, so it
   mentions only flags *that release* declares. This is why §7's "two-valued where
   you decide" holds: under a decided version the flag is known to exist, so the
   "not declared here" state cannot arise.

`True` is a real guard, not the absence of one — every component has an
unconditional block, and that block's guard is exactly `True`. It is the case that
keeps the existing flagless behaviour unchanged.

Finally, note that the *unit* is one guard with one **dependency**, not one guard
with its whole list. The same package can appear under several guards (an
unconditional `q >=1` and a guarded `q <3`), and
[flags-semantics.md §4.2](flags-semantics.md) wants those kept as separate facts,
with propagation intersecting them.

## 0. Why this exists

[flags-semantics.md §1.4](flags-semantics.md) put the flag in the value and
recorded the price: each `(version, assignment)` pair is its own atom, so the
solver's decisions and clauses can name flags the conflict never involved.
§4.2's per-fact collapsing pays most of that price — learned clauses carry
guards, not assignments — but three costs survive it, all traceable to the
decision still being a *point instance*:

1. **Backjumps are whole-instance.** Refuting a flag choice discards the
   version decision with it. The provider re-enumerates and re-offers a version
   that was never in question.
2. **The provider searches what propagation could derive.** Completion-per-cell
   candidate enumeration re-does, outside the constraint store, narrowing that
   guard-shaped terms would do inside it.
3. **Decisions name inert flags.** A decision is a total assignment, so every
   trace, log and report of it mentions flags no guard mentions.

The observation that removes them: a `.cabal` file's conditional structure is
a small set of **guarded, additive blocks**. `BuildInfo` is a monoid and
else-branches normalise to negated guards, so the search dimension for a
release is its guards — the cells of the Karnaugh map over the flags guards
mention — not the `2^N` corners of the flag hypercube. Guards already appear in
incompatibility terms (§4.2), and under a decided version they form a plain
two-valued Boolean algebra (§7). The generalisation is to let **decisions
speak the same language**: decide the version first, decide conditions only as
needed, and resolve conditions into a concrete flag assignment only at the
end.

This is a kernel-level change to what a decision *is*, which is why it gets a
specification before any code. It is also the revisit that
[flags-semantics.md §1.4](flags-semantics.md) reserved ("if the retry cost
ever dominates, this is the decision to revisit") — and it collects the
rejected alternative's whole advantage (irrelevant flags never enter clauses
*or decisions*) without flag variables, because a condition decision is a term
on the **package** variable, made under a decided version, so conditional
existence never arises.

## 1. The deviation register

Everything this document changes about PubGrub, with the line it changes. A
question of the form "does PubGrub require X?" is answered by this table or by
[references/pubgrub.md](../references/pubgrub.md) directly — never by prose
elsewhere in this repository.

| pubgrub.md | says | here |
|---|---|---|
| `:169` | decisions "select individual package versions" | decisions are **cause-less positive terms** (§2.1). The first decision for a package selects a version (§2.2), later ones refine its condition region (§2.3) |
| `:443` | decision making requires "the partial solution *doesn't* contain a decision for that package" | requires no **version** decision. A version-decided package re-enters decision making while the D1 check fails (§3) |
| `:451` | dependencies are converted to incompatibilities "lazily when each package version is first chosen" | same timing, but per guarded fact (§2.2). Facts whose guard the term does not yet satisfy stay **dormant**, which `:451`'s flooding concern already tolerates — the count is one per guarded occurrence, not per assignment |
| `:184` | total solution: "for every positive derivation, a corresponding decision that satisfies that assignment" | replaced by **D1** (§3): version decision + exhibited witness + fired guards entailed. Decisions no longer satisfy derivations pointwise. The witness does |
| `:492` | no matching version ⇒ add `{term}` | unchanged, and it also covers the refinement path: a provider that finds `Adm(p) ∩ ⟦term⟧ = ∅` while asked to certify D1 answers exactly as O6 prescribes |
| `:499` | add the decision "unless this would produce a conflict" | applies verbatim to refinement decisions (§2.3) |

**Explicitly not deviated from:** unit propagation. The generalised resolution
rule (`:350`). Satisfier location, prior causes and backjumping
(`:383`–`:417`). Decision levels (`:178`). Error reporting. The licence for
the whole table is that the algorithm demands only two things of a decision —
it is **cause-less** (`:364`–`:367`: a decision terminates conflict
resolution because there is no cause to resolve against) and **removable**
(backtracking strips it and un-satisfies the conflict). Neither property
mentions pointness.

## 2. The decision model

### 2.1 Decisions are cause-less positive terms

A decision is a positive term added to the partial solution as a free guess:
no cause, its own decision level, removable by backjumping, subject to
`:499`'s add-unless-conflict rule. Derivations are unchanged. All existing
relation machinery applies, because it was already term-generic.

Because refinement decisions occupy their own levels, conflict resolution
whose satisfier is a refinement backjumps to a level where the **version
decision survives**. That is the intended behaviour, not an accident: flipping
a condition must not cost re-deciding the version. (Cost 1 of §0.)

### 2.2 The version decision, and emission

The first decision for a package `p` is `p ∈ {v}` — the version pinned, the
flag axis unconstrained. Choosing `v` triggers emission of **all** of `v`'s
guarded dependency facts, per §4.2: for each occurrence `C ⇒ q ∈ R` of the
flattened conditional tree (environment resolved, so `C` mentions only flags
`v` declares),

    { p ∈ {v} × C,  not q ∈ R }

Unconditional occurrences (`C = true`) have depender `p ∈ {v}` and propagate
immediately, exactly as today. Guarded occurrences propagate when — and only
when — the accumulated term for `p` comes to satisfy `{v} × C`. Until then
they are dormant. Dormancy is a feature (a block the solve never enters is
never reasoned about) and a hazard (§3 exists because of it).

Version-axis collapsing — widening `{v}` to a range shared with adjacent
releases — is [flags-semantics.md §4.2](flags-semantics.md)'s remaining half
and composes with everything here. It changes the depender's version
component, never the decision model. Where a widened depender spans releases
that differ in what they declare, the third pin state carries it, unchanged
(§7).

### 2.3 Refinement decisions

A refinement decision for a version-decided package `p` is a term

    p ∈ {v} × G

where `G` is a condition region — in the canonical per-guard form, a single
guard `C` or its negation `¬C` — that the accumulated term does not already
entail. Per-guard versus whole-region refinement is **policy, not semantics**
(a region is a conjunction of guard decisions). §6 fixes the policy.

A refinement must make progress in the sense D2 defines (§4). Which package
decision making attends to first — an undecided package or an
under-determined one — is policy and does not affect solvability.

### 2.4 What "decided" no longer means

Under `:169` a decision *is* the answer for its package. Here it is not: the
version decision plus refinements pin down a region, and the answer is the
**witness** (§3, §5). Anything that currently reads solutions off decisions —
`extractSolution` reads `paDecision` directly — is reading a concept this
document deletes.

## 3. D1 — determination before success

The hazard, first, because the obligation is its negation. A guarded fact is
dormant until the term satisfies its depender. If nothing ever refines the
guard, the fact stays dormant through a "successful" solve — and the
end-of-solve flag resolution may then pick an assignment that **fires the
guard whose dependencies were never propagated**. That is a false plan: the
exact dual of the false "no solution" that
[flags-semantics.md O6](flags-semantics.md) exists to forbid.

> **D1 — determination before success.** Version solving may declare success
> only when every package `p` with a positive accumulated term satisfies all
> of:
>
> 1. **(version)** `p` has a version decision `{v}`.
> 2. **(witness)** the provider has exhibited a witness instance
>    `(v, α) ∈ Adm(p) ∩ ⟦accumulated term⟧`, with `dom α = D(v)` exactly
>    (totality per [flags-semantics.md §1.2](flags-semantics.md) — required
>    of the witness, no longer of any decision).
> 3. **(fired guards are entailed)** for every guarded dependency occurrence
>    `C ⇒ q ∈ R` of `v`: if `α` satisfies `C`, then the accumulated term
>    detectably satisfies the depender `p ∈ {v} × C` — under **the same
>    relation query unit propagation uses**, so "counts as determined for D1"
>    and "has propagated" cannot disagree.

Notes, each load-bearing:

- **Soundness argument.** The delivered plan (§5) assigns every package its
  witness. The witness's dependencies are the base occurrences plus exactly
  the occurrences whose guards `α` fires
  ([flags-semantics.md §4.1](flags-semantics.md)). Base facts propagated at
  the version decision. Fired guarded facts propagated by clause 3. Each
  propagated fact put `q ∈ R` into `q`'s accumulated term, and `q`'s own
  witness lies inside it by clause 2. So every dependency edge of the plan is
  satisfied. No step consults `D` outside the provider.
- **Guards the witness does not fire may remain undetermined.** This is
  deliberately weaker than "every guard entailed true or false", which was
  this document's first draft of D1 and is **rejected**: it forces one
  refinement per guard even when the default completion avoids every block —
  the common case — polluting decision levels for nothing. The weakening is
  sound because an unfired block contributes no dependencies to the delivered
  instance. The term still admitting instances that *would* fire it is
  irrelevant, since only the witness is delivered.
- **Only the provider can certify D1.** Clause 2 is `Adm` and reality
  (`D`-knowledge, [flags-semantics.md §1.1](flags-semantics.md)). Clause 3's
  guard list is index data. The kernel asks. The provider answers. A provider
  that finds the term really empty answers as O6's `None` and `:492` applies
  unchanged.
- **Buildability needs no seat in D1.** "Unbuildable when `C`" is the fact
  `{p ∈ {v} × C}` — a single positive term — emitted with the others at the
  version decision. Unit propagation immediately derives its negation. No
  determination question ever arises. When
  [flags-semantics.md §1.5](flags-semantics.md) is implemented, its guards
  join the *emission* of §2.2, not this obligation. (This also discharges
  `references/pubgrub.md:476` — "never select this" *instead of* its
  dependencies — natively.)

## 4. D2 — progress

Entailment is answered conservatively
([flags-semantics.md O4](flags-semantics.md)): the relation may fail to see
that a term satisfies a depender it semantically satisfies. D1 clause 3 uses
that same conservative query, so the slack must be shown to point the safe
way.

> **D2 — progress.**
>
> 1. *(direction of slack)* A conservative verdict may only cause a
>    **redundant refinement** — deciding a region the term already
>    semantically entails — never a skipped dependency. Redundant refinements
>    are consistent by construction and harmless.
> 2. *(refinements are detectable)* Intersecting a term with `p ∈ {v} × C`
>    must make `C` **detectably** entailed by the result. This is what makes
>    clause 1 true — a refinement always converts "semantically entailed but
>    invisible" into "visible" — and it is a property of the representation:
>    intersection leaves the region's pins syntactically present in every
>    surviving cell. It is an obligation on the algebra and gets a property
>    test (§9), not an assumption.
> 3. *(termination metric)* Each refinement strictly increases the number of
>    **detectably determined** dep-guards of its package. Guards per version
>    and versions per package are finite. Version decisions per package per
>    branch are single. The remaining argument is PubGrub's own. Note the
>    *semantic* term need not shrink — a redundant refinement shrinks nothing
>    — which is why the metric counts detectability, not denotation.

The forbidden direction — claiming entailment that does not hold — is already
excluded by [flags-semantics.md O2/O4](flags-semantics.md) and needs no new
rule here.

## 5. D3 — concretisation

> **D3 — the answer is the witnesses.** The solution delivered to the user is,
> per package, the witness of D1 clause 2 — not any decision. Its assignment
> is total (`dom α = D(v)`), so every flag has a value in the plan: flags
> pinned by the final term take their pinned values. All others take the
> release's declared defaults, per the choice policy below.

Existence is not a search at solve end: D1 clause 2 already exhibited the
witness, and the cell-completion lemma
([flags-semantics.md O6](flags-semantics.md)) is what made exhibiting it
cheap. D3 is bookkeeping plus policy, and deliberately so — a concretisation
step that could *fail* would be D1 mis-stated.

## 6. Choice policy is not semantics

As in [flags-semantics.md §5](flags-semantics.md): any admissible choice is
correct. Policy changes the solution found and the time taken, never
solvability. The policy adopted:

1. **Between releases**: newest first (unchanged).
2. **Intended witness**: for a version-decided package, the fewest-deviations
   completion of the accumulated term (deviation measured against the
   release's declared defaults — a property of the completed assignment,
   never of a cell. Both recorded traps in
   [flags-semantics.md §5](flags-semantics.md) apply verbatim).
3. **Refinement direction**: refine toward the guards the intended witness
   fires — equivalently, decide each guard the way the intended witness
   evaluates it, one guard per decision, in a deterministic order.
4. **Manual flags** *(provisional, tracking
   [flags-semantics.md §1.5/§8](flags-semantics.md))*: refinements may not
   move a manual flag off its declared default or user-supplied value.

**Recorded drift:** greedy per-guard refinement toward the intended witness
can diverge from globally-fewest deviations when guards share flags — deciding
one guard can change which completion is cheapest for the rest. Permitted:
policy never changes solvability, and the divergence is bounded by the shared
flags, which the Karnaugh observation says are few.

## 7. The condition algebra is version-local

Under a decided version `v`, every flag a guard mentions is declared
(`Bridge.Cabal.Flatten` resolves the environment and leaves only `v`'s own
flag conditions), so guards form a plain two-valued Boolean algebra closed
under `∧ ∨ ¬`, and the negation a backjump propagates is

    ¬(p ∈ {v} × C)  =  p ∉ {v}  ∨  p ∈ {v} × ¬C

with `¬C` computed inside that two-valued algebra — **no third pin state
required**. Refinement terms are DNFs over `PinnedTo` literals — *disjunctive normal
form*, an OR of ANDs: a union of cells, each cell pinning some flags — that is, the
existing cell language, no new representation.

`NotDeclared` is not dissolved. It stays load-bearing exactly where it always
was — dependers that span versions differing in what they declare, i.e. the
version-axis half of §4.2 collapsing, whose acceptance witness is
[flags-semantics.md §9](flags-semantics.md)'s. The clean split worth stating:
**two-valued where you decide, three-valued where you collapse.**

### Both halves on one world

Take two releases that differ in what they declare — the minimum needed to tell the
readings apart at all ([flags-semantics.md §6](flags-semantics.md)):

```
parser 1.0    declares  flag simd
parser 1.1    declares  no flags
```

**Two-valued, where you decide.** The version is already decided to `1.0`, so
`dom α` is known to be `{simd}`. Refine, then let a conflict negate it:

    refinement       parser ∈ {1.0} × +simd
    its negation     parser ∉ {1.0}  ∨  parser ∈ {1.0} × -simd

Inside the decided version there are exactly two cases, because "does this release
declare `simd`?" already has an answer — yes. `¬(+simd)` is `-simd` and nothing else.
The `parser ∉ {1.0}` disjunct is the version axis doing its ordinary work. It is not a
third *flag* state. This is why refinement needs no `NotDeclared`.

**Three-valued, where you collapse.** Now the depender spans a range, which is what
§4.2's version-axis half produces. Writing the collapsed term the way
[flags-semantics.md §9](flags-semantics.md) does:

    A = parser >=1.0 && <2                     -- both releases
    B = parser >=1.0 && <2  with simd on       -- denotes exactly {1.0 +simd}

    A ∖ B  =  parser >=1.0 && <2 with simd off              -- catches 1.0 -simd
           ∨  parser >=1.0 && <2 with simd not declared     -- catches 1.1

`1.1` is in `A` and is not in `B`, so it **must** survive the difference. Only the
second disjunct retains it: `1.1` has no `simd` to be "off". With a two-state pin the
difference yields the first disjunct alone, `1.1` vanishes, and the solver believes a
release is excluded that is not — the unsound direction, which lets it report failure
for a solvable problem.

The contrast in one line: **deciding fixes one release, so the flag's domain is
known. Collapsing spans releases, so the domain itself varies and has to be
speakable.**

The second half is checkable without a solver — it is exactly
[flags-semantics.md §9](flags-semantics.md)'s acceptance witness, an assertion about
`A ∖ B` — and the current implementation satisfies it. Evaluated by hand,
`difference` on those two sets yields precisely two cells:

    [(simd, PinnedTo False)]     -- retains 1.0 -simd
    [(simd, NotDeclared)]        -- retains 1.1, and is the only cell that does

with `memberInstance` agreeing: `1.0 -simd` ∈, `1.1` ∈, `1.0 +simd` ∉. Deleting the
second cell — the two-state reading — makes `1.1` a non-member of `A ∖ B` while it
remains a member of `A` and a non-member of `B`, which is the unsoundness §2.3 of
that document describes, exhibited concretely.

## 8. Worked example (acceptance criterion)

Same world as [flags-semantics.md §9](flags-semantics.md), so the two traces
can be read side by side:

```
myapp (local)     depends on  parser >=1.0 && <2

parser 1.0        flag simd (default: True)
                  when +simd:  depends on simd-utils ==0.3
                  when -simd:  no extra dependencies

simd-utils 0.3    depends on  base >=4.22
base 4.21.0.0     pre-installed: the only base obtainable
```

| # | incompatibility | source |
|---|---|---|
| (1) | `{myapp 0.1, not parser >=1.0 && <2}` | myapp's dependency |
| (2) | `{parser ∈ {1.0} × +simd, not simd-utils ==0.3}` | **emission at the version decision** (§2.2) — dormant |
| (3) | `{simd-utils 0.3, not base >=4.22}` | dependency of the decided instance |
| (4) | `{base >=4.22}` | provider reports no instance (O6) |
| (5) | `{simd-utils 0.3}` | conflict resolution, (4) + (3) |
| (6) | `{parser ∈ {1.0} × +simd}` | conflict resolution, (5) + (2) |

**Level 1.** Decide `myapp 0.1`. Derive `parser >=1.0 && <2`.

**Level 2.** Version decision `parser ∈ {1.0}`. Emission adds (2), dormant —
its depender is not satisfied by a term that pins no flag. D1 check: the
intended witness is the default completion `+simd`, which fires the guard.
not entailed → refine.

**Level 3.** Refinement `parser ∈ {1.0} × +simd` (§6 rule 3). (2)'s depender
is now satisfied. Derive `simd-utils ==0.3`.

**Level 4.** Decide `simd-utils 0.3`, giving (3). Derive `base >=4.22`.

**Conflict.** (4), then resolution: (4)+(3) → (5), (5)+(2) → **(6)**. The
earliest satisfier of (6) is the *refinement* at level 3. The previous
satisfier is the version decision at level 2. **Backjump to level 2: the
version decision survives.** No re-expansion of `parser` occurs.

**Propagation.** (6) is unit. Derive its negation intersected with the
current term: `parser ∈ {1.0} × ¬(+simd)` — computed in the two-valued
algebra of §7.

**D1 check.** Intended witness: fewest-deviations member of
`{1.0} × -simd`, which is `parser 1.0 -simd`. It fires no dep-guard, so
clause 3 holds vacuously. The provider exhibits the witness. No package has
an unsatisfied positive term. **Success.**

**D3.** The plan is the witnesses: `myapp 0.1`, `parser 1.0 -simd`.

Contrast with the same world today: the whole instance `parser 1.0 +simd` is
the decision, the backjump discards it, and the provider re-enumerates
completions to re-offer `parser 1.0 -simd`.

**Variant B — inert flags (the 2^k witness).** Give `parser 1.0` k further
flags `docs₁ … docsₖ` (any defaults) mentioned by no guard. The trace above is
**identical, symbol for symbol**: no incompatibility, decision, refinement or
derivation names any `docsᵢ`. They first appear in the answer, at D3, at
their defaults. Compare [flags-semantics.md §9](flags-semantics.md)'s price
paragraph: the point-decision model wastes 2^k rounds pre-§4.2 and still
*decides and names* the inert flags post-§4.2.

**Variant C — a default-off guard never refined.** Add to `parser 1.0` a
block `when +debug: depends on heavy-tracing ==1.0` with `debug` defaulting
to `False`. No trace line changes: the intended witness never fires the
guard, D1 clause 3 never demands it, and (per the rejected-strong-D1 note in
§3) no refinement decision is spent on it. This is the case that motivates
D1's witness-relative form.

## 9. Testing obligations

- **The verdict oracle of [flags-semantics.md §6](flags-semantics.md) —
  still owed there — is blocking for any implementation of this document.** A
  modified decision loop whose success criterion rests on conservative
  entailment is precisely the thing only a brute-force oracle over generated
  finite worlds catches: enumerate legal selections, assert
  `solver succeeds ⟺ oracle non-empty`, solver's answer ∈ oracle set, plus a
  step bound. Generated worlds must additionally include:
  - **(a) the D1 witness**: a world where declaring success *without* D1
    clause 3 delivers a plan containing an unsatisfied dependency — a dormant
    fired guard. This is the case that fails if D1 is dropped or weakened
    below §3's statement.
  - **(b) shared-flag guards**: two guards over one flag, where greedy
    refinement (§6 rule 3) diverges from globally-fewest deviations — pins
    down that the drift is solvability-neutral.
  - **(c) a guard determined false by propagation**: its dependencies must
    not fire, and no refinement may be spent on it.
  - **(d)** [flags-semantics.md §9](flags-semantics.md)'s collapsed-depender
    witness, unchanged — this document adds no slack to the three-case
    algebra and must not regress it.
- **D2 clause 2 as a property** (InstanceSetSpec-style, against the
  extensional model): for all terms `T`, versions `v`, guards `C` over `v`'s
  declared flags — after `T ∩ ({v} × C)`, the entailment of `C` is detected
  by the same relation query propagation uses. The universe rules of
  [flags-semantics.md §6](flags-semantics.md) (non-uniform declarations)
  apply.
- **The §8 traces are acceptance tests**, like the PaperSpec pair: the main
  trace, Variant B's symbol-identity, and Variant C's absent refinement are
  each mechanically checkable.

## 10. Non-goals

- The provider interface shape (`expand` vs pick/consequences vs a `refine`
  form) — design, not semantics. Recorded where
  [flags-semantics.md §8](flags-semantics.md) records its sibling question.
  Note only that this document *subsumes the benefits* §8 lists for the
  split: completeness dissolving into the loop, propagation running between
  attempts, and reasons becoming first-class all fall out of §2–§3.
- Implementation sequencing (see §11's closing note).
- Manual flags, buildability, user flag constraints: their obligations live
  in [flags-semantics.md](flags-semantics.md) and are unchanged. §3 and §6
  note the two interaction points. Buildability joins emission, and manual flags
  constrain refinement policy. User flag constraints are ordinary terms and
  compose without any new rule.
- Setup dependencies, sublibraries — other rungs. Nothing here moves for
  them.

## 11. What holds today

Everything in §2–§9 is **specified, not implemented**.

**The prerequisite is paid.** §4.2 per-fact guarded emission is implemented on both
axes, so this document is no longer inert. Its §0 costs are the live argument for or
against building it.

**It is dormant all the same.** While every flag takes its declared default there is
one assignment per release, so the cost condition decisions remove is currently zero.
It becomes live again the moment the flag axis returns.

The code this document generalises. **Cited by name, not by line** — every line number
in an earlier version of this table had drifted, some by 300 lines:

| fact | where |
| --- | --- |
| decisions are point instances, at most one per package | `paDecision`, `addDecision` — `src/PubGrub/Solver.hs` |
| the solution is read off decisions | `extractSolution` — the concept §2.4 deletes |
| success is "no undecided positive term" | `undecidedPositive`, `solve` — the criterion D1 replaces |
| dependers are guarded occurrences over a release span | `dependencyInc`, `spanningOccurrence` — `bridge/Bridge/Provider.hs`. This row records the prerequisite as **paid** |
| the provider searches completions per cell | `usableAssignments`, `preferDefaults` — the machinery §2–§3 makes mostly redundant |
| guards exist per release, environment resolved, flags only | `GuardedDeps`, `flattenComponent` — `bridge/Bridge/Cabal/Flatten.hs` |
| the flags-semantics rows this document leans on | O2 (exact algebra), O4 (slack direction), O6 soundness and the cell-completion lemma all hold. §6's verdict oracle is **owed, and blocking here** (§9) |

**§11 used to list five amendments to other documents.** All five were applied, and the
section held verbatim copies of paragraphs that live in
[flags-semantics.md](flags-semantics.md). It has been removed.
