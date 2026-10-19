# Flags as solver variables

> **Status:** current, since 2026-10-08. The default is still `--flags fixed`,
> under which every flag takes its declared default and the recorded gate
> baselines were taken; `--flags search` makes every automatic flag a variable,
> for both solvers. The argument and the evidence are [DESIGN.md §3](DESIGN.md#3-a-flag-is-a-variable-and-a-decision-is-one-variables-value);
> this file is the model, what the provider emits, and the measurements. The
> two specifications it replaced are retired
> (Hindsight document `decision-log-dropped-directions`).
> Background: `references/Package Managers à la Carte.md` §4.4 and
> `references/What is Answer Set Programming.md`.

## 1. The model

```haskell
data Flag = Flag { flagName :: FlagName, flagDefault :: Bool }   -- PubGrub.Cabal.Variable
data Var  = PackageVar PackageName | FlagVar PackageName Flag

data Instance = UsePreInstalled PreInstalledPackage | BuildSource Version   -- PubGrub.Cabal.InstanceSet
data InstanceSet = InstanceSet { isInstalled :: Set PreInstalledPackage, isSource :: VersionSet }

data Value    = PackageValue Instance   | FlagValue Bool     -- PubGrub.Cabal.Value
data ValueSet = ValueSet { vsInstances :: InstanceSet, vsFlags :: BoolSet }
```

A solver variable is a package name or an automatic flag of a package. A
package takes an instance; a flag takes a Boolean. A set of values is a
product, not a sum: the subsets of `Instance + Bool` are the pairs of an
`InstanceSet` and a `BoolSet`, so every set operation is componentwise and a
package variable's set simply has an empty flag component. A flag's identity is its
*declaration*, name and default together: two releases declaring `fast` the
same way share the variable, a release that changed the default has a different
one. Manual flags are never variables; they are resolved at their defaults when
the release is flattened (`PubGrub.Cabal.Flatten.componentDepsStored`).

Terms are `Term ValueSet`, keyed by `Var` in every incompatibility. A term's
polarity supplies the states the flag axis needs: `Positive {True}` is "in play
and on", `Negative {True}` is "absent, or off", and `Positive {False, True}`,
which conflict resolution reaches by widening the two values, is "in play,
either value" — the owning release is in the plan. That last reading is what
a flag term must never lose: a flag has no value when its owner is absent, so
dropping a widened flag term as "universal" would forget that the owner is
required. Here the widened term is positive and nothing drops it.

## 2. What the provider emits

When a source release `p-v` is decided (`PubGrub.Cabal.Provider.mkExpand`):

- the value is `PackageValue (BuildSource v)`, with no flag assignment;
- per automatic flag `f`: `declaresFlag p slot f`, the clause
  `{ p: Positive slot, p:f: Negative {False, True} }`. Propagation derives a
  positive term for the flag at once, the solver asks for it, and the provider
  offers the declared default where the set admits it, read off the variable.
  Nothing else ever derives a positive term for a flag, so a flag is only
  decided while a release declaring it is decided;
- per guarded occurrence and per disjunct of its guard:
  `fromDependency p span guard q range`, the clause
  `{ p: Positive span, p:f₁: Positive {b₁}, …, q: Negative range }`. The span
  is widened across neighbours that carry the same occurrence *and* declare
  the same automatic flags with the same defaults, since the flag variables
  are named by both (`spanningOccurrenceWith`, `sameFlags`). An empty guard is
  an ordinary dependency fact.

The store merges a dependency fact only with one under the same guard
(`PubGrub.Store.MergeDep` carries the `Guard`) and a `declaresFlag` clause
with one for the same flag, so adjacent releases collapse exactly as unguarded
facts do.

Under `--flags fixed` a release has no automatic flags, so none of the above
is emitted and the dependencies are the ones its defaults select — the path
every number in `STATUS.md` was measured on. The baseline marks every flag
manual under `fixed` only (`Bridge.Cabal.Baseline.sourcePackageIndex`), so
under `search` cabal searches the same flags and the comparison stays
structural. The derived index records which flags are manual (`srManual`,
`storeFormatVersion` 5).

## 3. Reporting and output

- A flag term reads as its owner with a sign: `foo +fast`, `foo -fast`, `foo
  flag fast` when either value is in (`PubGrub.Cabal.Report.Wording.bare`).
- A guarded leaf reads "foo >=1 && <2 with +fast depends on bar"; the owner's
  clause reads "foo >=1 && <2 declares flag fast".
- The driver folds decided flags into their owners (`PubGrub.Cabal.Value.foldFlags`,
  giving `Resolved = Installed | Built Version FlagAssignment`), so the tree
  shows `tasty 1.5.4 +unix` and the `plan:` lines keep one entry per package.

## 4. Tests

`test/FlagSolveSpec.hs`: defaults used; a flag flips when its default branch is
unsatisfiable; the same world is unsat under `fixed`; two flags with one viable
assignment; unsat over both values with the proof naming `+fast` and `-fast`;
an unmentioned flag stays at its default and costs no package decision; an
irrelevant flag does not multiply a version-level retry, nor do two; the newest
release is kept with a flipped flag rather than downgraded; plus the boot,
unbuildable and self-dependency cases the same harness carries.
`test/InstanceSetSpec.hs` is a model-based spec of the reduced `InstanceSet`
and of `BoolSet`.

## 5. Measurements

Index-state `2026-09-09T02:42:09Z` (`bench/index-state`), this machine, after
the removal of the cell representation. Identical, line for line, to the spike
that preceded it except for the wording of the owner's clause.

**The gate under `--flags fixed`** is the recorded baseline, unchanged: 26/26
agreement, 20/20 corpus cases unsat, 76 proof sentences, 0 no-version lines,
golden proofs intact, 229 tests.

**The gate under `--flags search`, both solvers searching automatic flags**
(`EXE` pointed at a wrapper that adds the option):

| gate | result |
|---|---|
| agreement | 26/26, both models |
| corpus | 18/20 reproduce as unsat: `cabal-install ==3.18.1.0` and `futhark ==0.27.1` now resolve, for cabal as well. Their failures were artefacts of fixing flags |
| vs-cabal | shorter than cabal on all 18 remaining |
| proof sentences | 67 over the corpus (76 before, minus the 9 of the two now-solvable problems); every other corpus proof has the same sentence count |
| no-version lines | 0 |
| golden, pkgconfig, unit | pass |

**Search cost**, our solver, `--stats`, bench problems:

| problem | decisions fixed → search | conflicts fixed → search |
|---|---|---|
| vector | 38 → 42 | 0 → 0 |
| pandoc | 265 → 327 | 1 → 1 |
| conduit <1.3 | 15 → 24 | 8 → 12 |
| lens <4 | 64 → 64 | 23 → 23 |
| aeson <2 | 319 → 352 | 58 → 64 |
| yesod | 828 → 919 | 14 → 11 |

The extra decisions are the flags themselves, one per automatic flag of each
decided release. `yesod` resolves 91 more decisions and three fewer conflicts.

**Proof length on the bench unsat problems:** `aeson <2` 38 → 47 sentences and
`conduit <1.3` 9 → 15; `lens <4` unchanged. Both grow where ancient releases
with a `split-base` flag enter the proof:

    Because bytestring <0.9.1.0 declares flag split-base and
        bytestring <0.9.1.0 with -split-base depends on base <3, bytestring <0.9.1.0
        requires base <3 or bytestring +split-base.
    And because bytestring <0.9.1.0 with +split-base depends on base >=3 && <4.2,
        bytestring <0.9.1.0 requires base <4.2.

Each flag costs two or three sentences to refute both of its values. The gate
ceiling of 76 is over the corpus only, so these two do not move it, but a
problem-set change that brought flag-heavy failures into the corpus would.

**Plans** fold the flags back: `tasty 1.5.4 +unix` in `vector`'s tree,
`pandoc 3.11 -embed_data_files +http` in `pandoc`'s. Plan lines agree with
cabal's on `vector` under both models.

## 6. What this leaves open

- **User flag constraints** (`--constraint 'p +f'`): a level-0 constraint on the
  flag variable, `PubGrub.Cabal.flagConstraint`, "if the flag is in play, it is at
  this value". The seed is built (2026-10-14) and tested; no driver option parses
  one yet, and cabal's solver is passed none.
- **Proof wording in derived steps.** Leaves have their sentences; a derived
  step whose terms include a flag goes through the generic summary, which
  prints `foo +fast` where a term is named but has no dedicated rule.
- **Decision order.** Flags are decided in first-mention order like any
  variable; whether deciding them immediately after their owner changes the
  search counts is unmeasured.
- **The gate's baselines** are for `fixed`. Moving the project's measured
  numbers to `search` means re-measuring the corpus, where two problems become
  solvable, and deciding whether to keep them.
