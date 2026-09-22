# TODO — what is planned, and what is not

> **What this is.** The planned items: the rungs not yet built, what has a
> specification and no code, and the questions still open. The last two sections are
> the opposite, kept here because a list of what not to do only works where it is
> re-read.
>
> **What this is not.** Not a status: what the repository contains now is
> [STATUS.md](STATUS.md). Not a rationale: why it is built that way is
> [DESIGN.md](DESIGN.md). Not history: [decision-log.md](decision-log.md).

---

## 1. The next rungs

The rung ladder, with what is built, is [STATUS.md §1](STATUS.md#1-what-works-today).

### 1.1 Setup and build-tool dependencies (rung 4)

Not started. `Bridge.Cabal.Flatten.componentDeps` merges library,
sublibraries and executables into one `GuardedDeps` and discards which component each
occurrence came from. It reads neither `setup-depends` nor `build-tool-depends`.

Each component is now gated on its own buildability first, which is what removed the
plan divergence the merge used to cause
([DESIGN.md §15](DESIGN.md#15-a-component-that-is-not-buildable-contributes-no-dependencies)).

Recovering the component label is the bulk of the work, and it touches no solver code.

Two things are owed on the way. Qualified goals, designed and shelved: the design and
why it does not fix self-dependencies are in [STATUS.md §3.2](STATUS.md#32-one-version-per-package-name).
And the setup self-dependency exception: cabal keeps a reverse-dependency edge for a
*setup* self-dependency, so the cycle forces a different setup script
([DESIGN.md §8](DESIGN.md#8-a-dependency-of-p-on-p-is-dropped)).

### 1.2 Public sublibraries (rung 5)

Not started. [cabal-build-model.md](cabal-build-model.md) is the reference.

---

## 2. Specified, not built

Everything here has a specification and no implementation. **Do not assume any of it
exists in the code.**

| thing | specification | note |
| --- | --- | --- |
| **Condition decisions** (rules D1, D2, D3) | [decision-semantics.md](decision-semantics.md) §2–§9 | a kernel-level change to what a decision is. Dormant: the cost it removes is currently zero |
| **`buildable:` as a condition** | [flags-semantics.md](flags-semantics.md) §1.5 | half built. `buildableCondition` returns the condition and `buildableAtDefaults` evaluates it. Satisfying it rather than evaluating it is the flag-axis half |
| **User flag constraints** (`--flag`) | [flags-semantics.md](flags-semantics.md) §1.6 | do not exist. While every flag is manual, they are the only thing that can move one |
| **The verdict oracle** (test) | [flags-semantics.md](flags-semantics.md) §6 | owed. It blocks condition decisions, and it is what would discharge O4's whole-loop claim |
| **`preferred-versions`** | — | the index reader does not read it. Its entries are in the tar with timestamps, so an index-state would apply to it unchanged |

---

## 3. Flag search

Flags are applied at their declared defaults and not searched
([STATUS.md §3.1](STATUS.md#31-flags-are-fixed-at-their-declared-defaults)). The
machinery is kept and still tested, and one trap is armed there: the provider tries
one flag completion per candidate region, so with more than one completion a valid
instance can be missed and the verdict is a confident, wrong "no solution", which
[flags-semantics.md](flags-semantics.md)'s O6 forbids. **Whoever restores flag search
owns the O6-complete search and the verdict oracle** (§2), and cannot treat
buildability as already done. `--flag` constraints (§2) are the only thing that can
move a manual flag, so they come with it.

---

## 4. Open questions

1. **What does the 25 MB memory floor consist of?** It is the first thing to settle,
   because the memory claim is the strongest one the project has and the floor is most
   of it. See [STATUS.md §2.3](STATUS.md#23-what-these-numbers-do-not-establish).
2. **Should `expand` split back into "pick" then "consequences"?**
   ([flags-semantics.md](flags-semantics.md) §8.) A design item, not a decision.
   [decision-semantics.md](decision-semantics.md) §10 says the condition-decision model
   inherits all three benefits of the split, so schedule the two as one item.
3. **Should the set algebra be allowed to read flag declarations?** It would make
   emptiness exact and remove the one-sided slack. It costs the core-bridge boundary.
   A cost question, not a correctness one.
4. **Decision order is chosen by discovery, and on `yesod` that costs 4.4× the
   decisions.** Diagnosed, not fixed — see
   [DESIGN.md §12](DESIGN.md#12-decision-order-is-discovery-order-and-yesod-is-the-bill).
5. **How far can the walk go?** It is unbounded today, so widening reads the whole
   version list in the worst case. A cap stays sound, because flags-semantics.md §4.2
   makes maximality policy rather than a requirement. Nothing has chosen one.

## 5. Settled — not planned, do not reopen

Each of these was decided with reasons recorded, and revisiting it has already cost
time.

- **No complement in the value algebra.** Four operations plus emptiness. Negation
  lives in `Term` as a polarity flip. A complement needs a universe of values that
  nothing in the algorithm ever asks for.
- **No `Eq` or `Ord` on `InstanceSet`.** The representation is not canonical, so
  structural equality would be unlawful. Use mutual containment.
- **Sets stay intensional.** An extensional `Set Instance` is not a cheaper PubGrub. It
  is the encoding PubGrub exists to avoid.
- **Emptiness stays one-sided.** Missing an empty set costs time. Claiming emptiness
  wrongly gives wrong answers. Test `isEmpty ⟹ empty`, never `⟺`.
- **Flags live in the value, not as solver variables.** A flag variable would need
  conditional existence, which PubGrub has no notion of. The price is the 2^k re-offer,
  and the answer to that price is condition decisions, not a change of model. While
  flags take their defaults the price is not being paid, because the search is not
  being done. That is a scope cut, not a third answer.
- **The property suite's universe must be non-uniform.** Releases must differ in which
  flags they declare, including one declaring none. A uniform universe cannot tell the
  three flag readings apart, which is exactly how a wrong `difference` passed for weeks.
- **Do not chase byte-parity with pub's output.** `^1.0.0` is Dart. cabal writes
  `>=1.0.0 && <2`. Same sentences, cabal's syntax.

## 6. Measured and rejected

Both are recorded so nobody re-derives them.

**Narrowing declared ranges to published versions.** `Bridge.Provider.widen` puts a
declared range into a term verbatim, so version space no release occupies survives.
Narrowing it with `snapToVersions` was tried twice in August, reverted twice on cost,
and re-measured on 2026-09-03 on the current tree, where the cost argument no longer
applies: it moves the search in both directions (`aeson <2` 400 to 320 decisions and
11.6% less allocation, `yesod` 827 to 839 decisions and 11.7% more) and it rewrites
every quoted range in a closed form nobody wrote, down to the user's own `lens <4`
printing as `lens >=0.1 && <=3.10.3` on the proof's last line. The second is the
objection, and it holds at any price. Pub never narrows; pubgrub-rs offers
`Ranges::simplify` and applies it only in the report. `snapToVersions` is kept, tested
and unused.

Its interior half, `PubGrub.VersionSet.fillGaps`, merges the holes between a range's
intervals that hold no published release and never moves an outer bound. Measured the
same day: every search counter identical on eight problems, allocation within noise,
one proof line changed (`haddock`'s seven `^>=` windows into `>=4.13.0.0 && <4.20`; since [DESIGN.md §14](DESIGN.md#14-versions-compare-with-trailing-zeros-insignificant) those windows coalesce on construction, and the declared spelling is what prints).
It is kept in reserve for *derived* terms, which nobody wrote. Applying it to a
declared range would discard the author's spelling, which [DESIGN.md](DESIGN.md) §2 now keeps.

**The fewest-versions decision heuristic.** `references/pubgrub.md:446` suggests
deciding the package with the fewest versions first. It cuts `futhark` decisions by
5.2× and lengthens proofs from 66 to 95 sentences. Measured and reverted.

**Reopened by `yesod`**, which is satisfiable and therefore prints no proof at all, so
the reason for reverting does not apply to it. See
[DESIGN.md §12](DESIGN.md#12-decision-order-is-discovery-order-and-yesod-is-the-bill).
