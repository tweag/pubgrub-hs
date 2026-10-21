# Related work — the Potassco literature, mapped onto our problems

> **What this is.** A reading map. For each external paper: which problem *in this
> repository* it speaks to, what it actually says, and what it does **not** settle.
> Every entry is anchored to a file or section here, so it is usable as a pointer
> rather than a bibliography.
>
> **Dated.** Written when a package's value carried its flags and `InstanceSet` was a
> DNF of cells. That model was retired on 2026-10-08 ([flags-as-variables.md](flags-as-variables.md));
> the entries below that speak to `FlagPin`, `pruneCells` and one-sided emptiness
> now describe a retired model (decision records `decision-0010` to `decision-0019` and
> `decision-0054` to `decision-0056` in the project's Hindsight bank),
> not the code.
>
> **What this is not.** Not authoritative on anything. It cites no rule and creates
> none. In particular it **does not reopen the ASP decision** — see
> [STATUS.md](STATUS.md) §5.1, which still stands: there is no ASP
> component, there never was one, and none of this argues for adding one. What
> changed is that we now know some of our design problems have a formal literature,
> and where it is.
>
> **Provenance.** Assembled 2026-08-12 from the University of Potsdam
> Wissensverarbeitung group's publication list,
> <https://www.cs.uni-potsdam.de/wv/publications/>. Quotations were taken from the
> PDFs, not from summaries. **This is not an exhaustive sweep** of that page — the
> items below were each checked individually, and there are likely more. Note also that
> the page lists the whole group, so several papers here have no Gebser on them. The
> author list is given in full for each. Where an entry says *unread*, it means the
> title and venue were verified but the paper was not opened — treat those as leads.

---

## How to use this file

The single most useful thing in it is §1: **someone else solved our exact problem
with the opposite representation, and published the bill.** If you read one entry,
read that one. §2 is the most useful for anyone formalising the kernel, because it
supplies the *shape of the theorem* we currently only state in prose.

Ranked by how much each one bears on live work:

| our problem | where it lives here | paper |
|---|---|---|
| extensional vs intensional version ranges | [`DESIGN.md`](DESIGN.md) §2, [`STATUS.md`](STATUS.md) §5.1 | §1 aspcud |
| depender collapsing, and what it cost | [`collapsing.md`](collapsing.md) | §1.3 |
| narrowing the universe before/while solving | `Bridge.Hackage`, and `collapsing.md`'s read cost | §1.2, §2.4 |
| no lawful `Eq`, order-dependent pruning | the retired cell DNF (decision record `decision-0054-a-flag-is-a-solver-variable-keyed-by-its-declaration`); `InstanceSet` has had a lawful `Eq` since 2026-10-08 | §2.1 |
| one-sided `isEmpty`, `Relation.Inconclusive` | the retired specification's O3/O4; the set is exact since 2026-10-08 | §2.2 |
| three-state `FlagPin` | retired with the cell DNF on 2026-10-08 | §2.3 (analogy only) |
| correctness of conflict resolution | stated in prose only; nothing in the repo proves it | §3 |
| over-specific learned clauses (the old "2^k") | one fact per guarded occurrence, [`collapsing.md`](collapsing.md) — **landed** | §8 |
| prefer-installed / prefer-defaults / prefer-newest | `PubGrub.Cabal.Provider`'s decision order: installed first, then newest; a flag's default rides in its identity, so it is offered first ([`flags-as-variables.md`](flags-as-variables.md) §1) | §5 |
| explaining failure | `PubGrub.Report` | §6 |

---

## 1. aspcud — our exact problem, solved with the representation we rejected

**Gebser, M., Kaminski, R., & Schaub, T. (2011). aspcud: A Linux Package
Configuration Tool Based on Answer Set Programming.** LoCoCo'11, EPTCS 65:12–25.
[arXiv:1109.0113](https://arxiv.org/abs/1109.0113) ·
[PDF](https://www.cs.uni-potsdam.de/wv/publications/DBLP_journals/corr/abs-1109-0113.pdf)

**Gebser, M., Kaminski, R., Kaufmann, B., & Schaub, T. (2011). Multi-Criteria
Optimization in ASP and its Application to Linux Package Configuration.**
[PDF](https://www.cs.uni-potsdam.de/wv/publications/TEMP_misc/GebserKKS11.pdf) — a
TPLP-submission draft, extending a PoS'11 paper of the same title, which extends the
ICLP'11 technical communication *Multi-Criteria Optimization in Answer Set
Programming* ([DROPS](https://drops.dagstuhl.de/entities/document/10.4230/LIPIcs.ICLP.2011.1)).

Read the two together: the first is the front end (CUDF → facts), the second is the
encoding plus the optimization algorithm.

### 1.1 It is the extensional encoding, with the invoice attached

aspcud's preprocessor turns a version constraint into the set of matching concrete
versions:

> `targets(name [op n]) = { (name, n) | n ∈ ℕ⁺ such that (n op n) holds }` if `op n`
> is specified, `{ (name, n) | n ∈ ℕ⁺ }` if omitted

A dependency then becomes one interned constant plus one `satisfies` fact per
matching version — its Figure 4 has
`depends(inst, 1, id_{{(dep,3),(dep,2),(dep,1)}})` alongside three `satisfies` facts.
That is exactly the O(#versions-on-Hackage)-per-dependency cost that
`references/pubgrub.md:1172` names as one of the four things separating PubGrub from
CDCL and answer-set solving, and that our `InstanceSet` exists to avoid.

**Why this matters to us.** The dropped directions (Hindsight document
`decision-log-dropped-directions`) argue against the extensional `Set Instance` from first principles. This paper is the empirical
counterpart: people who chose extensional, on real distribution data, at scale. Cite
it when the question is "was intensionality really necessary, or were we being
fancy?" — and note *what they had to build to survive it*, next.

### 1.2 What they build to survive it is a design option we do not have

The entire aspcud paper is about a preprocessor (its Algorithm 1) that computes a
transitive closure `𝒞 ⊆ 𝒰` of versioned packages that could possibly appear in a
follow-up installation:

> "Any package remaining in `𝒰 \ 𝒞` belongs to `Out`, meaning that it must not be
> installed, or is irrelevant regarding dependencies, requests, and objectives.
> Hence, packages outside `𝒞` need not be reflected in ASP facts, so that both
> instance and residual problem size can be reduced."

A **relevance-closure prepass over the index, before solving.**

We now do an eager whole-index prepass of our own — the derived index parses every
release once, ahead of time. It is **unbounded and not relevance-closed**, so it
answers the question "what does a read cost" and not the question aspcud answers,
which is "which packages need to be read at all".

That second question is still unexplored here, and this is the published algorithm for
it. It is not among [`collapsing.md`](collapsing.md) §4's five options. It is arguably
a sixth.

Two riders, both of which bear on us:

- **The closure depends on the optimization objectives.** Its lines 4–9 and 12–13 add
  packages to `𝒞` *because* some criterion rewards them (e.g. minimising deletions
  pulls in all installed versions of everything in the old installation). So
  preference is not free of universe size. Directly relevant if rung 3's
  prefer-installed ever becomes an objective rather than a heuristic (§5).
- **Its line 2 is a cheap UNSAT check with no explanation**: it "identifies cases in
  which install or upgrade targets remain unsatisfiable, regardless of further
  preprocessing, so that `∅` can be immediately returned." Fast, and useless for
  deliverable 1. A reminder of what "detects unsatisfiability" is worth on its own.

### 1.3 The companion paper contains a version of our collapsing rule

The multi-criteria paper's Figure 3 opens with a block it describes as abstracting
"relations from particular package versions to their common name, provided that all
respective versions share a relation":

```
aux_depends(N,D) ← depends(N,V,D).
    depends(N,D) ← aux_depends(N,D), depends(N,V,D) : unit(N,V).
```

That is **version-axis depender collapsing**, expressed in ASP, using the
conditional-literal `:` connective ("expands to the list of all instances of its
left-hand side such that corresponding instances of literals on the right-hand side
hold"). Two differences worth noticing:

- **Granularity.** Theirs collapses only when *all* versions share the relation. The
  spec asks us for *adjacent runs* (`references/pubgrub.md:456`), which is strictly
  finer and strictly harder — it needs the intervening releases inspected, which is
  precisely the read cost in [`collapsing.md`](collapsing.md) §3.
- **Side.** Their `id_P` interning is the *dependee*-side dual: two dependencies whose
  matching-version sets coincide share one constant, so they collapse. We cannot do
  that, because we never compute the matching set — the price of §1.1 running the
  other way. Note that [`collapsing.md`](collapsing.md) §2 establishes we *can* key on
  the dependee term structurally, for the narrower reason that `widen`-minted terms are
  canonical by construction.

The `:` connective is also the closest thing in their language to a flag guard, which
makes this the nearest published relative of our guarded emission
([`flags-as-variables.md`](flags-as-variables.md) §2). It is not the same thing: their
guard ranges over versions, ours over flag conditions.

---

## 2. Kaminski & Schaub, grounding — the theory of what our set representation does

**Kaminski, R., & Schaub, T. (2023). On the Foundations of Grounding in Answer Set
Programming.** TPLP 23(6):1138–1197.
[arXiv:2108.04769](https://arxiv.org/abs/2108.04769)

Their problem statement is ours, generalised: "the entire set of systematically
instantiated rules is infinite in the worst — yet not uncommon — case", so "the
characterization of the grounding result boils down to identifying a finite yet
semantically equivalent set of rules (whenever possible)." Compare `widen`, which
admits versions the index does not have, and an `InstanceSet` that denotes a set we
never enumerate.

### 2.1 "No canonical form" is a known phenomenon with a known remedy

**Retired.** This entry described the cell DNF. Since 2026-10-08 `InstanceSet` is
canonical and has a lawful `Eq` ([`DESIGN.md`](DESIGN.md) §2); the entry is kept as
the account of why the earlier representation could not have one.

Their §1 example:

```
p(X) ← ¬q(X) ∧ u(X)        u(1)  u(2)
q(X) ← ¬p(X) ∧ v(X)        v(2)  v(3)
```

> "depending upon the order, in which the rules are passed to a grounder, it already
> produces either the fact `p(1)` or `q(3)` via simplification. Clearly, all three
> programs are distinct but semantically equivalent."

Syntactically distinct output, semantically equal, dependent on operation order,
caused by simplification. That is `InstanceSet` and `pruneCells` precisely. Their
remedy is the one to adopt in writing:

> "Our main result shows that the stable models of a non-ground input program coincide
> with the ones of the ground output program returned by our grounding algorithm upon
> termination."

**Do not characterise the output syntactically. Characterise it semantically.** If
anything is ever stated formally about pruning, this is the shape it must take:
*`pruneCells` and `mergeCells` preserve the denotation*, never *`pruneCells` yields
a normal form*.
It is also, from the general theory, why `SetOps.equivalent` (mutual containment) is
the right notion of equality and why `Eq` cannot be: there is no normal form to
compare. `../CLAUDE.md` forbade adding `Eq` while that representation stood. This is
the principled version of the reason.

### 2.2 One-sided emptiness is their trade too, made deliberately

> "In practice, however, all these concepts are subject to approximation, which leads
> to the order-dependence observed in the last example."

and, on §5:

> "While approximate models are in general less precise than well-founded ones, they
> are better suited for on-the-fly grounding along an instantiation sequence."

Give up precision to be able to work incrementally, then prove the approximation is
*safe*. That was the retired specification's O3/O4 — never claim
emptiness wrongly, may fail to notice it — as a general principle, with the proof
obligations named. Useful for any formal statement about `isEmpty`: the obligation
is one-directional (`isEmpty ⟹ denotation empty`), which is what the test suite
already asserts and what the theory says is the correct shape.

### 2.3 More truth values, for the same structural reason (analogy, not identity)

To keep the operators monotone they "resort to concepts borrowed from ID-logic", and
work with two- and four-valued contextual interpretations. We needed three `FlagPin`
states because a two-valued pin is not closed under negation
(retired with the cell DNF, decision record
`decision-0054-a-flag-is-a-solver-variable-keyed-by-its-declaration`).

**Flagged as an analogy.** The mechanisms are not the same and nothing here transfers
formally. It is worth one line only because "we tried two values and the operator
stopped behaving" is apparently a recurring shape, and it took us two shipped bugs to
believe it.

### 2.4 Component-wise grounding is what the provider is doing

> "each rule is instantiated in the context of all atoms being possibly derivable up
> to this point. In addition, grounding has to take subsequent atom definitions into
> account."

with an *instantiation sequence* derived from rule dependencies, and, algorithmically:

> "The instantiation of a program is seen as an iterative bottom-up process starting
> from the program's facts while being guided by the accumulation of variable-free
> atoms possibly derivable from the rules seen so far."

This is the formal account of expanding packages in dependency order and only ever
materialising the reachable slice — and it is what connects §1 and §2: aspcud's
Algorithm 1 closure is an ad-hoc instance of exactly this bottom-up evaluation.

### 2.5 Where it stops

Grounding here is still *full* grounding with on-the-fly simplification. What the
paper gives you is the vocabulary for saying which instances you are entitled to skip
and what you must prove about it — which is the argument the guarded emission makes
informally ([`flags-as-variables.md`](flags-as-variables.md) §2): use the guard
verbatim rather than enumerating assignments. It does not hand you the
algorithm. See §8.

**Sections to read:** §2.5 (program simplification) and §5 (approximate models along
an instantiation sequence). The rest is aggregates and infinitary formulas, and does
not concern us.

---

## 3. The algorithm we hand-rolled, done rigorously

**Gebser, M., Kaufmann, B., & Schaub, T. (2012). Conflict-driven answer set solving:
From theory to practice.** Artificial Intelligence 187–188:52–89.
[DOI](https://doi.org/10.1016/j.artint.2012.04.001) ·
[PDF](https://www.cs.uni-potsdam.de/wv/publications/DBLP_journals/ai/GebserKS12.pdf)

Inference as **unit propagation on nogoods**, with conflict-driven learning and
backjumping. Structurally: their nogoods are our incompatibilities, their propagation
is ours, their learning is conflict resolution. This is the rigorous account of the
machinery `pubgrub/src/PubGrub/Solver.hs` implements, and the peer-reviewed check on the
resolvent argument.

**The instructive delta.** Their nogoods are over *ground atoms*, so propagation is
complete and a term either is or is not satisfied. Ours are over intensional terms,
which is precisely where `Relation.Inconclusive` comes from. If you want a one-line
answer to "why does our propagation have a third outcome when the literature's does
not", it is this difference and nothing else.

---

## 4. Keeping an ordered domain out of the ground program

**Gebser, M., Kaminski, R., Kaufmann, B., Ostrowski, M., Schaub, T., & Wanko, P.
(2016). Theory Solving Made Easy with Clingo 5.** ICLP'16 Technical Communications,
OASIcs 52, 2:1–2:15. *(unread)*

**Banbara, M., Kaufmann, B., Ostrowski, M., & Schaub, T. (2017). Clingcon: The Next
Generation.** TPLP 17(4):408–461. *(no Gebser, unread)*

The principled form of what we built by hand: do not ground the ordered domain,
attach a propagator to it, and accept that the propagator's incompleteness is sound
but weaker. Our `InstanceSet` is a theory in this sense and `isEmpty` is its
(incomplete) check. Relevant mostly as vocabulary, and as the architecture a
differential oracle would use (§7) — since it is the one that avoids §1.1's expansion.

---

## 5. Preference: search heuristic vs. optimization objective

**Gebser, Kaminski, Kaufmann & Schaub, multi-criteria** (cited in §1) is the paper to
read here. Its criteria are ours in different clothing:

- *paranoid*: minimise deleted packages first, then changed packages
- *trendy*: minimise deleted, then out-of-date, then unsatisfied recommendations, then
  new packages

"Minimise deletions and changes" is **prefer-installed as a genuine objective** —
rung 3's rule, promoted from a decision heuristic to something optimised for. The
paper's payload is what that costs:

> "also the learned constraints that rely on an infeasible upper bound must be
> retracted. To this end, we make use of assumptions assigned at a solver's root level
> …, i.e., unbacktrackable literals allowing for the selective (de)activation of
> constraints."

Lexicographic descent over priority levels fights conflict-driven learning, because
learned constraints resting on a speculative bound must be retractable. Our
preferences are decision-*order* heuristics precisely so we never meet this. **If the
PoC ever wants the best plan rather than a plan, this paper is the cost estimate** —
and §1.2's rider applies too: adding an objective widens the relevant universe.

That heuristics are a legitimate alternative mechanism, rather than a shortcut, is
itself published:

**Gebser, M., Kaufmann, B., Otero, R., Romero, J., Schaub, T., & Wanko, P. (2013).
Domain-Specific Heuristics in Answer Set Programming.** AAAI'13 *(unread)* —
declarative decision heuristics as a first-class construct. The direct analogue of
our prefer-installed, prefer-default, prefer-newest decision order.

For the general theory of preference, if it is ever wanted: **asprin** (Brewka,
Delgrande, Romero & Schaub, AAAI'15:1467–1474, and *A general framework for
preferences in answer set programming*, AIJ 325:104023, 2023). *(no Gebser, unread)*
Not currently relevant — we have three fixed preference rules, not a preference
language.

---

## 6. Explaining failure

**Gebser, M., Pührer, J., Schaub, T., & Tompits, H. (2008). A Meta-Programming
Technique for Debugging Answer-Set Programs.** AAAI'08:448–453.
[PDF](https://cdn.aaai.org/AAAI/2008/AAAI08-071.pdf)

Read this as *support* for [STATUS.md](STATUS.md) §5.1 rather than as a
technique to borrow. Explaining "no answer set" in ASP requires a separate
meta-encoding layer bolted on top of the solver, and what it produces is a diagnosis
of a *logic program*, not a proof about packages and versions in cabal's range syntax.
Deliverable 1 is half the point of the PoC. This is the evidence that a general-purpose
solver does not hand it to you.

---

## 7. If the differential oracle is ever built

**Kaminski, R., Romero, J., Schaub, T., & Wanko, P. (2023). How to Build Your Own
ASP-based System?!** TPLP 23(1):299–361.
[arXiv:2008.06692](https://arxiv.org/abs/2008.06692)

A 68-page tutorial on customising clingo — the `Application` class, AST manipulation,
multi-shot control, theory propagators, and ASPIF (the grounder↔solver interface).
Mostly a manual for a system we decided not to build. Two parts still earn shelf
space:

- **Theory propagators.** The concrete route to an oracle that does *not* pay §1.1's
  expansion: keep versions and flags symbolic, reuse our own `VersionSet` logic as the
  theory, let clingo supply CDCL. If a SAT/UNSAT oracle for differential testing is
  ever built, build it this way, not as a plain encoding.
- **ASPIF, as boundary discipline.** Their split is grounder | solver. Ours is
  `pubgrub-hs` (the bridge) | `pubgrub`, and the mapping is closer than it looks — our `Provider` is
  playing the grounder's role, being the only component that consults the index
  (`expand'` is where reality is consulted). Their argument is that pinning that
  interface down as a narrow explicit format is what let three grounders and a dozen
  solvers interoperate. Our version of that contract is a typeclass plus prose.

**Also relevant:** multi-shot solving, i.e. assumption-based incremental re-solving
over a program that grows — **Gebser, M., Kaminski, R., Kaufmann, B., & Schaub, T.
(2019). Multi-shot ASP solving with clingo.** TPLP 19(1):27–82. This is the mechanism
if the candidate universe is ever grown eagerly-but-incrementally rather than kept
intensional.

The reification / meta-programming half of the tutorial is the least useful to us:
it is how you post-process a ground program declaratively, which is structurally the
job of our report post-passes (`collapseNoInstances`, chain collapsing) — but ASP's
answer is to write more ASP, and we want Haskell emitting cabal-syntax sentences.

---

## 8. The defect we called "2^k", and what it is actually called

Worth a section because the internal name was misleading, and because it is now
**fixed** — the flag axis landed 2026-08-05 (`decision-log-index`, Era 7), and since 2026-10-08 a guarded dependency's terms name only the flags the
guard mentions ([`flags-as-variables.md`](flags-as-variables.md)).

**The defect was not really exponential arithmetic. It was an over-specific learned
clause.** The depender term named a single point in the version × assignment space, so
refuting it failed to *generalise* to the sibling assignments of the same version, and
the solver rediscovered the same conflict once per irrelevant assignment. Stated that
way it is a standard CDCL failure mode — a learned constraint that does not cover the
symmetric branches — and "2^k" was only the worst-case count it produced. The residue
after that is bounded by the number of **guard regions**, not by 2^k over every
declared flag; the costs that remained because a decision was still a point instance
went with the flag-in-value model on 2026-10-08.

**The Potassco paper on exactly this mechanism** — generalising a learned constraint
past the ground instance that produced it, so it is not relearned per variant:

**Gebser, M., Kaminski, R., Kaufmann, B., Lühne, P., Romero, J., & Schaub, T. (2016).
Answer Set Solving with Generalized Learned Constraints.** ICLP'16 Technical
Communications, OASIcs 52, 9:1–9:15. *(unread — title and venue verified, contents
not.)* Worth opening before anyone designs the next generalisation step: the retired
condition-decision specification was the same move applied to decisions rather than
clauses, and the flag-variable model made it moot.

**What still has no literature here**, as far as this sweep found:

- **CUDF has no flags.** Its virtual packages (`provides: conf = 3`) are a
  name-aliasing mechanism, not a per-version configuration space. Nothing in the
  package-management line addresses a value domain that is *version × total assignment
  over a per-version-declared flag set*.
- **The nearest neighbour is product configuration**, where feature selection is the
  search dimension: **Gebser, M., Ryabokon, A., & Schenner, G. (2015). Combining
  Heuristics for Configuration Problems Using Answer Set Programming.**
  LPNMR'15:384–397. *(unread.)*
- **Instantiation blow-up as such is attacked by lazy grounding** — ASPeRiX, OMiGA,
  Weinzierl's Alpha — a different group, not on the Potsdam page, and not read. Noted
  so the gap is not mistaken for absence.

---

## Caveats, restated

1. **Not an exhaustive sweep.** The publications page is large and resists machine
   reading. Each item above was verified individually, but absence from this file means
   "not found", not "not there". Entries marked *unread* were not opened.
2. **The page is the group's, not one author's.** Author lists are given in full.
   Clingcon and asprin have no Gebser.
3. **Nothing here changes a decision, a rule, or a line of code.** If a future change
   is made *because* of something in this file, it belongs in a decision record in the
   project's Hindsight bank (the `hindsight-decisions` skill), and the authority for it belongs in the spec
   that owns the subject — not here.
