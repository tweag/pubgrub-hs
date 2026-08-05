# Independent review of `flags-semantics.md`

**Reviewed:** 2026-08-05

## Scope

This is a semantic and design review of
[`flags-semantics.md`](flags-semantics.md), not an implementation review. The
review also checked the claims on which that document depends against:

- [`references/pubgrub.md`](../references/pubgrub.md);
- [`decision-semantics.md`](decision-semantics.md);
- the formal kernel model in [`specification/`](../specification/);
- the relevant `InstanceSet`, provider, and Cabal solver code.

## Overall assessment

The central design makes sense. In particular, the three-state flag model is
well justified and appears mathematically correct. If one constraint may span
releases that differ in whether they declare a flag, then the observable cases

1. declared and on;
2. declared and off;
3. not applicable to this instance

must all be expressible. Otherwise, exact difference loses one of those cases.
The worked example in §9 is a good witness for this.

The document also makes several unusually careful distinctions:

- a strict flag atom versus lenient translation of user input;
- denotationally exact set operations versus conservative emptiness;
- semantic admissibility versus provider choice policy;
- one guarded dependency fact versus a complete dependency set;
- correctness obligations versus current implementation status.

I found four issues worth resolving before treating every claim in the document
as normative. None invalidates the core three-state model.

## Findings

### 1. Manual flags cross the stated input/admissibility boundary

**Severity:** medium

Section 1.5 defines intrinsic admissibility as a property of an instance alone,
independent of the partial solution. It then says that a manual flag must take
its default value *unless the user set it*. Section 1.6 separately says that user
flag constraints are not part of admissibility: they are translated once into a
solver constraint and never rechecked by the provider.

Those statements cannot all hold unless `Adm` is parameterized by user input.
Whether the same non-default instance is admissible would otherwise change when
the user supplies a flag constraint.

The intended Cabal behavior is supported by
[`enforceManualFlags`](../../cabal/cabal-install-solver/src/Distribution/Solver/Modular/Preference.hs):
without a constraint, only the default survives; when the user mentions a
manual flag, the mentioned values are also allowed, and ordinary constraint
enforcement selects the requested value. The behavioral rule therefore appears
sensible, but its semantic owner is unclear in this document.

A clean division would be:

- without a user value, translate the manual-default rule into an initial
  constraint;
- with a user value, translate that value instead;
- keep provider admissibility independent of user flag input.

The alternative is to define admissibility explicitly as relative to the static
solve configuration, but that would require weakening §1.6's “one owner, one
reading” claim.

### 2. Section 5's concrete choice recipe contradicts O6

**Severity:** medium

O6 correctly observes that the provider may not stop after trying one completion
per cell once admissibility is assignment-dependent. Its example is decisive:
the default completion may be unbuildable while a non-default completion of the
same cell is admissible.

Section 5 nevertheless gives this concrete recipe:

> Complete each candidate cell, drop non-members and inadmissible completions,
> deduplicate assignments arising from overlapping cells, then order by cost.

In the terminology used elsewhere in the document, “complete each candidate
cell” means producing its default completion. If that completion is
inadmissible, the recipe drops it without searching the other assignments in
the cell. That is exactly the false-`None` failure that O6 and §10 warn about.

Section 5 should instead be understood as policy over an O6-complete search:
generate admissible completions in nondecreasing deviation cost, deduplicate
them, and choose the first. The current one-completion recipe is valid only
while admissibility is assignment-independent.

### 3. O4 overstates what conservative emptiness establishes

**Severity:** medium

O4 correctly establishes a local result: because set operations are exact and
emptiness only under-claims emptiness, every reported `Satisfied` or
`Contradicted` relation is sound. It then concludes:

> Therefore no incompatibility is ever derived that is not entailed: no wrong
> “no solution”, and no wrong solution either.

That whole-solver conclusion is stronger than the preceding argument. Section 6
recognizes this: delayed detection of satisfaction can change satisfier
selection, learned incompatibilities, backjump levels, assertion after
backjumping, and progress. It therefore requires a finite verdict oracle.
Section 10 likewise labels the single-query direction as guarded and the solver
loop as unproved.

The formal model reflects the same boundary. Relation and unit-propagation
soundness use conservative emptiness, while the current executable
satisfier-search results in
[`PartialSolution.lean`](../specification/PubGrub/PartialSolution.lean) require
exact emptiness.

The justified conclusion at O4 is:

> Every relation the implementation positively reports, and every unit
> propagation performed from such relations, is semantically sound.

Whether conservative false negatives preserve the final verdict and progress of
the complete loop remains the oracle or proof obligation already recorded in
§6.

### 4. Section 2.5 presents a modelling choice as a PubGrub requirement

**Severity:** low

Section 2.5 correctly cites the PubGrub specification for the requirement that
version ranges remain intensional. It then says that the same requirement
excludes version-keyed flags “not as a matter of taste”.

The cited
[`Version Ranges`](../references/pubgrub.md#version-ranges) section establishes
that version constraints should not be expanded into one Boolean atom per
concrete version. It does not establish that every possible release-scoped or
lazy flag-variable design must enumerate the version axis.

Such alternatives may still be poor fits: they need conditional-existence
machinery, complicate incompatibilities, and may weaken cross-version
reasoning. Section 1.4 makes that argument well and accurately calls “the flag
lives in the value” a modelling choice with a price. Section 2.5 goes further
than its cited authority supports.

This does not make the selected design wrong. It only means that its rejection
of alternatives should remain a project design decision rather than be
presented as fundamental PubGrub semantics.

## Minor consistency points

### Source-release identity

Section 1.1 introduces `ρ` as a source-release identity including source and
chosen revision, and explains why `(p, v)` is insufficient. Section 1.2 then
writes:

```text
dom α = D(p, v)
```

This should semantically be `D(ρ)`. The distinction is dormant in the current
single-index implementation, as the document says, but becomes load-bearing
with multiple sources or local packages. At that point the source identity must
also be retained by the instance value; a version and flag assignment alone
cannot distinguish releases with different descriptions.

### The manual-flag rule is now locally verifiable

The document labels the manual-flag rule as recalled from memory because
`cabal-install-solver` is not vendored in this repository. There is an adjacent
Cabal source checkout, and its `enforceManualFlags` implementation supports the
stated default-versus-explicit-value behavior, including its qualification for
multiple package goals. The rule no longer needs to rest only on memory, though
the ownership issue in finding 1 remains.

## Strong parts of the specification

### The strict/lenient distinction

Making `f is on` strict, then obtaining lenient user behavior by translating
input to

```text
(f is on) ∨ (f is not applicable)
```

is the right separation. It keeps the algebra compositional and makes input
policy explicit. Cabal's modular solver also appears consistent with this
leniency: flag constraints are enforced at flag-choice nodes, so a release that
does not introduce that flag is unaffected.

### The three-state partition

The argument for the not-applicable state is sound. With only on and off,

```text
not (f is on)
```

cannot retain both releases that declare `f` as off and releases that do not
declare `f`. Treating absence as vacuous satisfaction merely moves the error:
the two Boolean polarities overlap instead of forming complements. Expressing
all three observational cases is the clean solution.

### The exact-operation/conservative-emptiness split

Requiring exact membership, intersection, union, and difference while allowing
emptiness to miss index-dependent emptiness is a coherent consequence of the
core/bridge boundary. The direction of permitted error is also correct:
under-claiming emptiness can delay a relation; over-claiming it can manufacture
an invalid implication.

### Per-fact guarded emission

Section 4.2 chooses the right unit: one guarded dependency occurrence
`C ⇒ q ∈ R`. Using the guard directly keeps unrelated flags out of the depender
term. Grouping instances by their complete effective dependency sets would fail
to group assignments that differ only in some unrelated dependency and would
retain the exponential re-offer cost.

Emitting multiple occurrences for the same dependency separately and letting
propagation intersect their ranges is also semantically cleaner than partitioning
the whole assignment space into effective dependency maps.

### Testing obligations and implementation honesty

The requirement for a non-uniform flag-declaration universe is important and
well motivated. So is testing emptiness only in its promised direction. The
proposed finite verdict oracle targets the actual residual risk in the solver
loop rather than mistaking set-level properties for an end-to-end correctness
argument.

Section 10 is especially useful: it distinguishes what is implemented, what is
currently correct only because assignment-dependent inadmissibility does not
yet exist, and what remains an argued rather than proved obligation.

## Conclusion

The specification's core model is sound and well thought through. I would accept
it as the project's direction, subject to:

1. assigning the manual-flag rule consistently either to input translation or
   to explicitly input-parameterized admissibility;
2. making §5's selection recipe consume an O6-complete assignment search;
3. limiting O4's conclusion to local relation and propagation soundness until
   the verdict oracle or a whole-loop proof exists;
4. describing the rejection of version-keyed flag models as a project design
   decision rather than a requirement derived from PubGrub.

The main unresolved correctness risk is not the three-state flag algebra. It is
the behavior of the complete solver loop under conservative emptiness, followed
by provider completeness once buildability makes admissibility depend on the
flag assignment. The original document already identifies both risks; the main
need is to align its stronger claims and concrete recipes with that diagnosis.
