# Attic — ideas that were tried and dropped

> **What this is.** Approaches this project pursued and then abandoned, with why.
> Nothing in this directory describes the current system. Read it when a
> decision looks arbitrary. Read it before you propose something that was already
> tried.
>
> **For the current state**, see [../STATUS.md](../STATUS.md). For the ordered
> history of turns, see [../decision-log.md](../decision-log.md).

**Abandoned is not the same as unfinished.** Things that are merely *not built yet* —
setup dependencies, sublibraries, user flag constraints, the benchmark harness — are
**not** here. They are live work, listed in [../STATUS.md](../STATUS.md). This
directory is only for directions we walked away from.

---

## 1. Answer Set Programming (Clingo / Potassco)

**Dropped before any code existed.**

The original framing was to encode dependency solving as Answer Set Programming and
hand it to Clingo. Searching the whole history for `clingo` finds it only in
`CLAUDE.md` and design prose — no `.lp` file was ever committed, no solver was ever
invoked.

**Why dropped:** superseded by implementing PubGrub natively in Haskell, which is
what the PoC's two questions (explanation quality, performance) actually need. A
generic ASP solver's explanations are not PubGrub's explanations, and explanation
quality is half the point.

Worth knowing because ASP still appears in `../pubgrub-intro.md` §8 and can read as
though a component was removed. **Nothing was removed — there was never anything
there.**

*(Still theoretically useful as an external oracle that answers only "solvable?" /
"unsolvable?" — SAT/UNSAT — for differential
testing, but that is not on the delivery path, and the Lean specification in
`../../specification/` now occupies that niche.)*

## 2. Generalising the solver over a Heyting / Boolean set algebra

**Files:** `superpowers/plans/2026-06-24-solver-lattice-generalization.md`,
`superpowers/specs/2026-06-24-choice-lattice-design.md`

A `Lattice` / `Boolean` / `Sets` class hierarchy, a `Pow` powerset type, and
`Choice` / `ChoiceSet` modelling a package's value as a **product of sets**
(installed units × source configurations), with flags folded into the source
component. Built, and then thrown away in the reboot.

**Why dropped:** the value domain does not need a Boolean algebra. It needs
intersection, union, difference and an emptiness test — and specifically **not a
complement**. A complement requires a universe of values that nothing in the
algorithm ever asks for, and negation is needed in exactly one place (`Term`), where
it is a polarity flip that costs nothing.

Replaced by `SetOps`: four operations, no complement, no lattice vocabulary.

**This is the clearest "we made it more general and that was the wrong direction"
turn in the project.** Worth re-reading before generalising anything else.

Note the *product of sets* idea was also dropped, separately and for a different
reason: a package's value became one whole `Instance` rather than a tuple of
independent coordinates, because choosing the instance settles version, provenance
and every flag at once. See [../decision-log.md](../decision-log.md) Era 4.

## 3. An Alloy model of Cabal build-plan structure

**No files here — it left no artifact.** Added 2026-06-26, revised once, dropped by
2026-07-03.

A formal model of build-plan structure in Alloy. Recoverable only from git history.

**Why dropped:** not recorded at the time. The instinct outlived it twice: once as
[`../cabal-build-model.md`](../cabal-build-model.md), a prose model of Cabal's build
structure that is still live as a reference for rungs 4 and 5, and once as
[`../../specification/`](../../specification/), a Lean model of the PubGrub kernel. Neither is a descendant of the Alloy work in any
technical sense.

## 4. `flags-design.md` — the lenient flag rule

**File:** [`flags-design.md`](flags-design.md)

The first serious design for flags. **Superseded on semantics** by
`../flags-semantics.md`, which supersedes it by its own authority clause. Kept
because its arguments are still worth reading and because `flags-semantics.md` cites
it four times as the position it argues against.

**What it got wrong:** it chose the **lenient** rule — its §2 "Domain-freedom
principle" — under which a constraint mentioning a flag that a version does not
declare is *vacuously true*.

Two problems:

1. Lenient is the **safe** direction but still not exact: a constraint and its
   negation both cover the versions lacking the flag, so two different constraints
   denote the same set for reasons no operation can see.
2. Worse, it was implemented as a **global rule in membership**, and a global rule
   cannot be scoped. It applied equally to constraints the solver derives *itself*,
   where the strict reading is the required one — negating a decision must exclude
   exactly that instance and nothing else.

The fix was three-state flag atoms (on / off / not declared here), under which both
readings are expressible, so each boundary says which it means. Leniency survives,
but only for **user input**, translated once at one boundary.

Also note its Haskell declarations name types from before the reboot
(`PubGrub.Lattice`, `PubGrub.Choice`, `SourceConfigSet`) that no longer exist. Its
§4 is a "Split provider API" design — related to but not the same as the open
`expand` question in `../flags-semantics.md` §8.

## 5. `flags-spike.hs` — the spike that validated the bug

**File:** [`flags-spike.hs`](flags-spike.hs)

An executable spike for the flag set algebra.

**Why it is here, and why it matters more than a dead spike normally would:** it
validated its laws on a universe where **every version declared the same two
flags**. A uniform universe cannot distinguish the three possible readings of a flag
statement, so the spike's properties passed while the semantics underneath them was
wrong — and the same gap then survived being "validated" a second time in the
property suite.

This is the direct reason `../flags-semantics.md` §6 makes a **non-uniform test
universe** a written obligation: versions must differ in which flags they declare,
including one that declares none. Keep the file as the evidence for that rule.

## 6. Pre-reboot plans and specs

**Directory:** `superpowers/` — 8 plans and 7 design specs, 2026-06-10 to
2026-06-24.

These describe the **first implementation**, which was rewritten from scratch in the
July reboot. They are not wrong about what they planned. They describe code that no
longer exists, in terms of modules that no longer exist.

Important: that first implementation **worked end to end on real Hackage data**. It
was not abandoned because it was broken. It was restarted for modelling reasons —
the value domain and the set algebra — not correctness ones.

What became of each idea:

| plan | fate |
|---|---|
| `pubgrub-native-solver` | **idea survived, code did not.** Rewritten in the reboot. Its provider interface is the two-method `chooseVersion`/`getDependencies` form, merged into `expand` on 2026-06-24 — and now under discussion to split back (`../flags-semantics.md` §8) |
| `hackage-integration` | **survived in spirit.** We still read a cached `01-index.tar` ourselves and avoid `cabal-install`. We do *not* avoid `hackage-security` — we read through it, in `bridge/Bridge/Hackage.hs` |
| `lazy-index-loading` | **survived, and then some.** Parse-on-demand is still the model, and the memoisation question was later settled by measurement — cache the *reduced* form, never parsed descriptions (7× slower, 10× bigger) |
| `solver-progress-tracing`, `startup-and-streaming-tracing` | **survived.** `co-log` is still a dependency and still used in `Solver`, `Provider`, `Hackage` and `Main` |
| `with-compiler-option` | **gone.** No `--with-compiler` anywhere in the tree. The CLI still uses `optparse-applicative`, so only the option went |
| `installed-source-providers` | **idea survived, shape did not.** Installed packages are rung 3 and work, but as `PreInstalled` instances in one provider, not as two providers combined |
| `solver-lattice-generalization`, `choice-lattice-design` | **dropped.** See §2 above |

## 7. `flags-semantics-review.md` — a review of a draft that was then rewritten

**File:** `flags-semantics-review.md`

An independent review of [`../flags-semantics.md`](../flags-semantics.md). Its four
findings were folded into that file on the same day, and the passages it quotes to
object to no longer exist. It argues against text that has been rewritten.

**Kept for two things it says better than the spec does:** why O4 is a *local* result
only, and what the "false `None`" failure mode is — the provider reporting "nothing
available" when something is available.

Its own links have rotted. It points at a Cabal checkout outside the repository, and it
cites `references/pubgrub.md` by heading anchor where this project requires line
numbers.

## 8. `bridge-and-problem-model.md` — a planning record whose decisions were reversed

**File:** `bridge-and-problem-model.md`, written 2026-07-23

It planned the bridge before the bridge existed. Three of its substantive decisions
were then reversed, most importantly the central one:

- it decided to **reuse `convPIs`** and derive both solvers from the same `PInfo`,
  with a thin adapter. That is not what happened. `Bridge.Cabal.Flatten` does our own
  flattening without `finalizePD`, and cabal's side gets `SourcePackage` records while
  `modularResolver` runs `convPIs` itself. The counter-preference the document records
  as the losing option is what was built.
- it describes the bridge as an executable with a `tar` dependency. It is a private
  library, and there is no `tar` dependency.
- it says our model enumerates flag assignments into instances. There is one instance
  per release.

**Rescued before it moved:** its three-way analysis of what `cabal-install` would have
supplied, which is the *evidence* for a boundary decision that `../../CLAUDE.md` now
merely asserts. Everything else live in it is stated better, and currently, in
`../../CLAUDE.md`'s Architecture section.

## 9. `flags-semantics.md` and `decision-semantics.md` — the flag in the value

**Files:** [`flags-semantics.md`](flags-semantics.md), [`decision-semantics.md`](decision-semantics.md).
Retired 2026-10-08.

The second serious design for flags, and the one that shipped for a while: a
package's value is an instance *with* a total flag assignment, a set of instances is
a DNF of cells (a version range crossed with pins, three states per pin), and a
decision settles version and every flag at once. `decision-semantics.md` then
specified how to decide only the flags a guard made relevant, to undo the price of
that.

**Why dropped:** the price was the machinery. Keeping flags inside the value cost a
non-canonical set type with no lawful `Eq`, one-sided emptiness, subsumption
pruning between every operation, three states per pin, and a provider that completed
assignments per cell — all so that one variable per package would suffice. Making
each automatic flag a variable of its own, keyed by its declaration, gets conditional
existence from one clause per flag and leaves `InstanceSet` an installed set plus one
range. See [`../flags-as-variables.md`](../flags-as-variables.md) and
[`../DESIGN.md`](../DESIGN.md) §2–§3. The earlier attic entries §4, §5 and §7 are
about this model's own history.

## 10. Two representations that were replaced

Not in this directory, but abandoned, and easy to propose again:

- **An extensional `Set Instance`.** `Small.hs` stored instance sets literally, as
  `newtype InstanceSet = InstanceSet (Set Instance)`, with a comment claiming that
  "if the 2^flags blow-up ever hurts, a symbolic representation can replace this one
  **without the algorithm noticing**."

  That sentence was wrong twice over, and it is the most instructive thing about the
  sketch:

  1. **The swap was not optional.** A dependency's declared range must cost *one*
     entry, not one per matching version on Hackage. An extensional set is not a
     cheaper PubGrub — it is the encoding PubGrub exists to avoid, which the spec
     names as one of the four things separating it from CDCL (conflict-driven clause
     learning, the standard SAT-solver algorithm) and answer-set solving
     (`../../references/pubgrub.md:1172`).
  2. **The swap was not invisible.** The `PubGrub.InstanceSet` of the time had **no
     lawful `Eq`** (there was more than one way to write the same set), **could not be
     enumerated** (so a provider must enumerate from its own index and filter by
     membership — still true), and answered emptiness only **one-sidedly**. Every one
     of those changed callers. The first and third went away with the cell DNF (§9);
     the second is the point.

     *(The reason there is more than one way to write the same set: it is stored in
     **disjunctive normal form** — DNF, an OR of ANDs — as a list of cells, each a
     version range plus some pinned flags, unioned together. Nothing reduces that list
     to a unique form, so two different lists can denote the same set.)*

  Worth remembering as a general shape: "it is behind an interface, so we can swap it
  later" was false here in both directions at once — the abstraction did not make the
  choice free, and the choice was not free to change.
- **Two-state flag pins.** On/off only. The negation of "flag is on" then collapses
  to "flag is off", silently dropping every version that lacks the flag — which makes
  set difference come out too *small*, and too small a difference lets the solver
  report failure for a solvable problem. Shipped twice. Replaced by three states.
