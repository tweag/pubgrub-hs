# Design: Cabal flags in the solver

> **Status:** historical design document, kept for its arguments rather than its
> code. The Haskell declarations below are *design artifacts*, and they name types
> and modules from before the reboot (`PubGrub.Lattice`, `PubGrub.Choice`,
> `SourceConfigSet`) that no longer exist. What is implemented lives in
> `src/PubGrub/InstanceSet{,/SourceCell}.hs`; §2's DNF-of-cells shape survives
> under different names, its lenient-membership rule does not.
>
> **Scope:** how the solver comes to *choose* Cabal flags, in addition to versions and
> installed unit-ids. It was written as a companion to a `TODO.md` that no longer
> exists; the problem statement now lives in `CLAUDE.md` (rung 2) and the semantics
> in [flags-semantics.md](flags-semantics.md).
>
> **Superseded on semantics:** what a constraint mentioning a flag some version does
> not declare *means* is now specified in [flags-semantics.md](flags-semantics.md).
> §2's "Domain-freedom principle" chose the lenient reading (an undeclared flag
> vacuously satisfies a pin); that specification rejects both two-valued readings and
> requires a third case, "not declared". The rest of §2 — DNF over cells, why not
> `Map Version FlagAssignment`, why subsumption pruning is load-bearing — stands.

## 1. Problem and model

### The problem

The solver today chooses only *versions* (for source packages) and *unit-ids* (for
pre-installed packages). It does **not** choose Cabal **flags**. Instead,
`PubGrub.Cabal.Flatten.flattenDeps` collapses each package's conditional dependency tree at
its *default* flag values:

```haskell
-- app-lib/PubGrub/Cabal/Flatten.hs (current)
finalizePD (mkFlagAssignment []) defaultComponentRequestedSpec (const True)
           platform compiler [] gpd
```

`mkFlagAssignment []` means "pin no flags — let Cabal use each flag's default." Flags therefore
never enter the constraint system, and the solver can never pick a non-default flag even when
that is the only way to satisfy the user's request.

A correct build plan must choose flags too, because:

- A source package's **set of dependencies** depends on its flag assignment (a `if flag(fast)`
  stanza adds `vector`, etc.). Note: only *which* dependencies exist changes — the version
  *ranges* on a given dependency do not depend on flags (see §5).
- The **flag domain** — which flags exist at all — varies from version to version of the same
  package.
- The user may supply a **partial flag assignment** as a constraint, with *lenient* semantics
  (§2, §5).

### The chosen model: fold flags into the source config

A source package's decision element becomes a **version plus a total flag assignment** — one
coupled `(version, flags)` pair, never a version and its flags chosen independently. The source
component of `ChoiceSet` grows from a bare `VersionSet` into a *set of `(version, flag-config)`
points*: a set whose *members are those coupled pairs*. A decision pins exactly one pair, and
its dependencies are computed from that pair jointly (by evaluating the package's conditional
tree at the chosen flags, §4–5). Flags being
version-specific and dependency-determining is precisely *why* version and flags travel together
inside one element — it is not evidence that they are independent axes. Everything else in the
solver is reused unchanged: the `Term` / `Lattice` / product-of-sets machinery already carries
elements and sets generically, so a richer element and a richer set slot straight in.

This was chosen over modelling flags as independent Boolean solver *variables*. The reason
originally recorded here — that the alternative would force the package type `p` and set type `s`
into sums spanning versions, unit-ids and booleans, an invasive core rewrite — does not hold up.
It contradicts the paragraph above: a core that carries a richer *element* generically carries a
richer *variable* just as generically, and under that substitution neither unit propagation nor
conflict resolution nor backtracking changes a line. (A monomorphic core would touch every module,
but that is a property of the code as written, not a reason for the model.)

The real difference is that **the flag domain depends on the version**. As an independent variable,
`foo:fast` exists only when the chosen version of `foo` declares `fast`, and PubGrub has no notion
of a conditionally-existent variable — so the domain would have to be tied down with explicit
incompatibilities ("if `foo 1.3` then `foo:fast` is absent", and so on), one per version × flag.
That is precisely the class of bookkeeping PubGrub builds in for the version axis instead of
encoding (implicit mutual exclusivity, `references/pubgrub.md:1193`; lazy formulas, `:1207`). The
fold gets it for free, by absorbing the domain dependence into what an element *is*.

Note what that argument does and does not claim. The fold does not remove the version-dependence
of flag domains; it *relocates* it — out of explicit clauses and into the set algebra, which is
where every flag bug so far has lived. The three-case flag atom required by
[flags-semantics.md](flags-semantics.md) §2.3 is the bill for that relocation.

And the alternative's advantage belongs on the record, since it was never written down. A clause
`{foo 1.2, foo:fast, not vector >=0.12}` names the flag as a *literal*, so conflict resolution
learns "`fast` is the problem" and that generalises across versions. Under the fold each
`(version, assignment)` pair is its own atom, so a version rejected for a reason having nothing to
do with a flag is retried once per irrelevant assignment — 2^k of them — and nothing learned about
`+fast` on `1.2` transfers to `1.3`. Depender-range collapsing (`references/pubgrub.md:456`) is
the fold's answer to that cost. "Closer to pure PubGrub" does no work in either direction:
nothing in the spec requires variables to be package names, and a Boolean variable gets implicit
mutual exclusivity exactly as a version does.

The fold stands — **one decision per package name**, with change confined to the
choice/lattice/provider layers — but on the strength of the domain argument, not the typing one.

### The binding constraint

The solver interacts with the set type `s` through exactly one narrow interface — the
`Lattice` class hierarchy in [src/PubGrub/Lattice.hs](../src/PubGrub/Lattice.hs):

```haskell
class Lattice a where (\/), (/\) :: a -> a -> a
class Lattice a => BoundedLattice a where
    bottom, top :: a
    isBottom, isTop :: a -> Bool           -- default: (== bottom) / (== top)
class BoundedLattice a => Boolean a where neg :: a -> a
class Boolean a => Sets a where
    type Elem a
    singleton :: Elem a -> a
    member    :: Elem a -> a -> Bool
```

Crucially, **`neg` is on the hot path.** `PubGrub.Term` reduces intersection of terms to it:

```haskell
-- src/PubGrub/Term.hs
intersectTerms (Positive p) (Negative n) = Positive (p /\ neg n)
intersectTerms (Negative a) (Negative b) = Negative (a \/ b)
```

and `subsetOf`/`disjoint` (used throughout conflict resolution) are defined via `neg` and
`isBottom`. So the replacement for `VersionSet` in the source component **must be a lawful
Boolean algebra** — a complemented lattice with a genuine `neg`, not merely a
join/meet semilattice. This single fact drives the whole design of §2.

## 2. The source-config lattice

This is the core of the design. `VersionSet` in the source component of `ChoiceSet` is replaced
by a `SourceConfigSet` that is a full `Boolean`/`Sets` instance.

### The element

What a `Decision` pins is a concrete, *total* configuration:

```haskell
-- design artifact
data SourceConfig = SourceConfig
    { scVersion :: !Version
    , scFlags   :: !(Map FlagName Bool)   -- keys = exactly the flags THIS version declares
    }
    deriving stock (Eq, Ord, Show)
```

The domain invariant "`keySet scFlags == flagsDeclaredBy scVersion`" is *external* data (it
comes from the `.cabal`), so the element type cannot enforce it. That gap is handled at the one
boundary where a total `SourceConfig` is born — the provider's `expand` (§4) — and is the
subject of the correctness discussion at the end of this section.

### The representation: DNF / union-of-cells

```haskell
-- design artifact — hidden data constructor; built only via smart constructors.
-- NB: Eq is SEMANTIC (see "Equality/emptiness are semantic" below), NOT derived.
newtype SourceConfigSet = SourceConfigSet [SourceCell]   -- interpreted as a UNION
    deriving stock (Show)

data SourceCell = SourceCell !VersionSet !FlagConj

-- Constraint on the flag axis: a conjunction of pinned flags (absent = top /
-- unconstrained), or the contradictory bottom. A pinned flag is just a `Bool`
-- — no per-flag set type is needed (see "No BoolSet" below).
data FlagConj = FCBottom | FCConj (Map FlagName Bool)
    deriving stock (Eq, Ord, Show)   -- structural Eq IS semantic once normalized
```

> **Refined by the spike (see end of §2).** An earlier draft used a `FlagConfigSet =
> Map FlagName BoolSet` with a bespoke 4-value `BoolSet` and a `deriving stock Eq` on
> `SourceConfigSet`. The spike showed (a) `BoolSet` is unnecessary — a cell only ever pins a
> flag `True`/`False` or leaves it unconstrained, which `FCConj`/`FCBottom` captures canonically;
> and (b) `SourceConfigSet` must **not** derive `Eq` (below).

Semantics: `SourceConfigSet [c₀, c₁, …]` denotes the union of its cells; a cell
`SourceCell vs fcs` denotes `{ (v, m) | v ∈ vs and m ⊨ fcs }`.

#### Why not `Map Version FlagAssignment` (keying flags by version)?

This is the natural first instinct — flags belong to a version, so map each version to its flag
assignment. It faithfully captures that flags are version-specific, but it does not work as the
solver's *set* type, for two reasons.

**1. Version × flags is a Cartesian product, not a disjoint union.** A source config is a
version *and* a flag assignment (a conjunction). Contrast `ChoiceSet`'s existing
`(Pow UnitId, VersionSet)`, which is a disjoint *union* — a choice is a unit-id *or* a version,
disjoint coordinates — where complement is componentwise (`neg (a,b) = (neg a, neg b)`) and the
product `Lattice` instance is correct. For a Cartesian product it is *not*: the complement of
one rectangle `X × Y` is `(¬X × ⊤) ∪ (⊤ × ¬Y)`, a *union of two* rectangles, never `¬X × ¬Y`.
So the version×flag space cannot reuse the componentwise product instance and cannot be a single
`(VersionSet, FlagConj)` pair — it must be a union of rectangles, i.e. a DNF.

**2. The version axis is open, so it cannot be keyed by concrete versions.** Complementing a
decision means naming *all other versions* (`neg (singleton v)` is a cofinite version set),
which `VersionSet`'s intervals represent but a `Map Version …` cannot — a finite map only
mentions finitely many concrete versions and has no way to say "every version except v". This is
the same reason the version axis is a `VersionSet`, not a `Set Version`, today.

Concretely, negating one decision point forces *both* a version complement and a flag
disjunction at once:

```
neg (singleton (SourceConfig v m))
    = SourceCell (neg (singleton v)) ⊤        -- every OTHER version, any flags  (interval complement)
    ⋁ SourceCell (singleton v) (fcNeg (FCConj m))  -- this version, some flag flipped (a union)
```

Neither piece fits in a `Map Version FlagAssignment`. This does *not* contradict the model:
per-version flag assignment is the right shape for an *element* (`SourceConfig`) and for
provider/reporting structures like the `SourceAssignment` scaffold — it is only the wrong shape
for the *set* the solver takes complements of.

The same objection stated for flags alone: a `FlagConj` (`Map FlagName Bool`) expresses only a
*conjunction* of pinned flags, and the complement of a conjunction is a *disjunction* it cannot
hold in one map. So we take the honest Boolean closure — **disjunctive normal form**, a union of
conjunctive cells:

```
neg (⋃ᵢ cellᵢ) = ⋂ᵢ neg cellᵢ         (De Morgan)
neg (SourceCell vs fc)
    = SourceCell (neg vs) fcTop               -- versions outside vs, any flags
    ⋁ [ SourceCell full f | f <- fcNeg fc ]   -- versions anywhere, one pinned flag flipped
```

`fcNeg` turns the conjunction `⋀ᵢ flagᵢ = bᵢ` into the union `⋁ᵢ flagᵢ = ¬bᵢ`, one cell per
pinned flag. The rejected alternative — keeping a fibered map and weakening `Boolean` to drop
`neg` — would require rewriting `intersectTerms`, `subsetOf`, `disjoint`, and `priorCause` in
the solver core. That is far more invasive and error-prone; DNF is preferred.

#### No per-flag set type (`BoolSet`) is needed

An earlier draft carried a per-flag set `BoolSet ∈ {none, true, false, both}`. It is
unnecessary: within a cell a flag is either **pinned** (`True`/`False`) or **unconstrained**,
and "unconstrained" is just absence from the `FCConj` map. The `both` state = unconstrained =
absent; the `none` state = contradiction = the whole cell is empty (`FCBottom`). So the four
states collapse into `FCConj`-present-`True`, present-`False`, absent, and `FCBottom`. A finite
per-flag set type would also be *non-canonical* — e.g. `Pow Bool` has `Excl {True} == Incl {False}`
denoting one set but not structurally `==`, and the solver compares sets with `==` to decide
emptiness (`termIsEmpty`, `priorCause`, the `Eq s` constraint pervading `Solver.hs`). A plain
pinned `Bool` sidesteps that entirely.

### Instances

`FlagConj` is a helper, **not** a `Boolean` instance (it is deliberately not closed under
complement — that is the whole reason for the DNF). It provides meet, top/bottom, complement-as-
a-union, and membership:

```haskell
-- design artifacts
fcTop :: FlagConj
fcTop = FCConj Map.empty                              -- unconstrained

fcMeet :: FlagConj -> FlagConj -> FlagConj             -- conjunction; conflict ⇒ FCBottom
fcMeet FCBottom _ = FCBottom
fcMeet _ FCBottom = FCBottom
fcMeet (FCConj a) (FCConj b)
    | and (Map.intersectionWith (==) a b) = FCConj (Map.union a b)
    | otherwise                           = FCBottom

fcNeg :: FlagConj -> [FlagConj]                        -- complement as a UNION of cells
fcNeg FCBottom      = [fcTop]
fcNeg (FCConj c)
    | Map.null c = []                                  -- neg top = bottom (empty union)
    | otherwise  = [FCConj (Map.singleton f (not b)) | (f, b) <- Map.toList c]

-- leniency lives here: a pinned flag the version does not declare is vacuously satisfied
fcMember :: Map FlagName Bool -> FlagConj -> Bool
fcMember _ FCBottom   = False
fcMember m (FCConj c) = all (\(f, b) -> maybe True (== b) (Map.lookup f m)) (Map.toList c)
```

`SourceConfigSet` gets the Boolean structure. `\/` is list append; `/\` is the pairwise cell
meet over the cross product; `neg` folds `(/\)` over per-cell complements (De Morgan, above).
**`isBottom`, `isTop`, and `Eq` are semantic, not derived** (see below):

```haskell
instance Lattice SourceConfigSet where
    SourceConfigSet a \/ SourceConfigSet b = mkSCS (a ++ b)
    SourceConfigSet a /\ SourceConfigSet b = mkSCS [cellMeet x y | x <- a, y <- b]
      where cellMeet (SourceCell v1 f1) (SourceCell v2 f2) = SourceCell (v1 /\ v2) (fcMeet f1 f2)

instance BoundedLattice SourceConfigSet where
    bottom = SourceConfigSet []
    top    = SourceConfigSet [SourceCell full fcTop]
    isBottom (SourceConfigSet cs) = null cs            -- reliable: mkSCS drops empty cells
    isTop s = isBottom (neg s)                          -- SEMANTIC, not (== top)

instance Boolean SourceConfigSet where
    neg (SourceConfigSet cs) = foldl' (/\) top (map negCell cs)
      where negCell (SourceCell vs fc) =
              mkSCS (SourceCell (neg vs) fcTop : [SourceCell full f | f <- fcNeg fc])

instance Eq SourceConfigSet where                       -- SEMANTIC: mutual subset
    a == b = subsetOf a b && subsetOf b a

instance Sets SourceConfigSet where
    type Elem SourceConfigSet = SourceConfig
    singleton (SourceConfig v m) = SourceConfigSet [SourceCell (VersionSet.singleton v) (FCConj m)]
    member (SourceConfig v m) (SourceConfigSet cs) =
        any (\(SourceCell vs fc) -> VersionSet.member v vs && fcMember m fc) cs
```

### Equality and emptiness are semantic

`SourceConfigSet` **must not** `deriving stock Eq`. Two structurally different DNFs can denote
the same set — e.g. `top` is one cell `[SourceCell full fcTop]`, but `singleton e \/ neg (singleton e)`
is a four-cell union that is *also* everything. Pairwise subsumption does not reduce these to a
common canonical form (that is DNF canonicalization, which is expensive), so a derived `Eq` would
wrongly report them unequal, and the solver relies on `Eq s`/`isBottom`/`isTop` being *semantic*
(`termIsEmpty`, `priorCause`). The robust definitions:

- `isBottom = null . cells` — reliable because `mkSCS` drops every empty cell, so a non-empty
  cell always denotes a non-empty set.
- `isTop = isBottom . neg`, and `(==) = mutual subsetOf` (`subsetOf a b = isBottom (a /\ neg b)`).
  None of these route through `Eq`, so there is no cycle.

`mkSCS` (the smart constructor; data ctor hidden) drops empty cells and prunes cells subsumed by
another kept cell. Subsumption is now **load-bearing, not just cosmetic**: without it, `neg` over
a `k`-cell union produces up to `(1 + #flags)^k` cells and the algebra blows up (the spike
confirmed this — it timed out until pruning was added). See the open question on a cell cap in §6.

### Domain-freedom principle (and the hardest risk)

**The hardest correctness risk:** the domain is *dependent* (valid flags depend on the version),
but the Boolean algebra is *not* domain-aware. `neg` can synthesize cells mentioning flags no
version in their `VersionSet` declares, and `member`'s leniency then treats such flags as
vacuously satisfied. If leniency were applied *inconsistently* between emptiness-testing and
`member`, the law `member e (a /\ neg a) = False` could break and corrupt `subsetOf`/`disjoint`
and hence conflict resolution.

**Mitigation — keep the algebra domain-free; push all domain-awareness to `expand`:**

- The algebra operates on abstract `(VersionSet, FlagConj)` cells under the fixed rules "absent
  flag key = unconstrained" and "undeclared flag = skipped in `member`" (`fcMember`). Cell
  emptiness is decided **purely algebraically** — empty `VersionSet`, or a flag conflict
  yielding `FCBottom` — *never* by consulting a per-version flag domain. So `X ∧ ¬X` collapses to
  `FCBottom` on the conflicting flag *before* any domain question is asked, giving `bottom`
  unconditionally, and the emptiness test can never contradict `member`'s leniency.
- The per-version flag **domain** is consulted at exactly one place: the provider's `expand`,
  the only site that constructs a *total* `SourceConfig` (keys = declared flags from
  `genPackageFlags`, values from the chosen assignment). The solver never fabricates elements,
  so no ill-domained `SourceConfig` enters a `Decision`.

### Validation (spike)

This model was prototyped against the **real** `PubGrub.Lattice` classes and `PubGrub.VersionSet`
([flags-spike.hs](flags-spike.hs), run with `cabal repl`) and checked by **denotation** over a
finite universe (3 versions × 2 flags = 12 total configs): each algebra operation was compared to
the corresponding set operation on the elements it denotes. All passed:

- Homomorphism: `denot (a \/ b) = denot a ∪ denot b`, `denot (a /\ b) = denot a ∩ denot b`,
  `denot (neg a) = U \ denot a`, `member e a = e ∈ denot a`, `singleton e` denotes `{e}`,
  `isBottom a = (denot a == ∅)`, `isTop a = (denot a == U)`, and semantic `(a == b) = (denot a == denot b)`.
- Abstract Boolean laws via semantic `==`: idempotence, commutativity, associativity, absorption,
  De Morgan, double negation, `a /\ neg a == bottom`, `a \/ neg a == top`.
- Leniency: a version declaring only `a` satisfies a `b=True` constraint (vacuous), but `a=True`
  violates `a=False`. Backtracking: `neg (singleton (v, {a,b}))` excludes exactly that point while
  keeping `(v, {a=False,b})` and other versions.
- Semantic-`Eq` necessity: `singleton e \/ neg (singleton e)` (4 cells) `==` `top` (1 cell) —
  a derived `Eq` would have said `False`.

The one caveat the spike forced: subsumption pruning in `mkSCS` is required for the algebra to
be usable (unpruned `neg` blew up); see §6.

## 3. Solver-core impact (deliberately minimal)

The payoff of folding flags into the element: the change is confined to the choice/lattice
layer. In [src/PubGrub/Choice.hs](../src/PubGrub/Choice.hs):

```haskell
-- from:  newtype Choice    = Choice (Either UnitId Version)
--        newtype ChoiceSet = ChoiceSet (Pow UnitId, VersionSet)
-- to:
newtype Choice    = Choice (Either UnitId SourceConfig)
newtype ChoiceSet = ChoiceSet (Pow UnitId, SourceConfigSet)
    deriving (Lattice, BoundedLattice, Boolean)          -- UNCHANGED line

pattern Installed :: UnitId -> Choice
pattern Source    :: SourceConfig -> Choice              -- was: Version -> Choice
```

- The `deriving (Lattice, BoundedLattice, Boolean)` line is **unchanged** and still valid,
  because `SourceConfigSet` is `Boolean`; `ChoiceSet` inherits its algebra from the product
  instance `(Pow UnitId, SourceConfigSet)`.
- The `Sets ChoiceSet` instance is **unchanged** — it delegates to the product, and
  `Elem ChoiceSet = Choice` still holds with the new `Choice` (whose element the product gives
  as `Either UnitId SourceConfig`).
- **No change** to `Assignment`/`Decision`, `assignmentTerm`, or `extractSolution` in
  [src/PubGrub/Solver.hs](../src/PubGrub/Solver.hs): `Decision.aVersion :: Elem s` already
  carries whatever the element type is — now a `Choice` with the flag assignment inside its
  `Source` arm. `extractSolution :: PartialSolution p s -> Map p (Elem s)` returns the flag
  assignment as part of each source choice, for free.
- **No change** to [src/PubGrub/Term.hs](../src/PubGrub/Term.hs),
  [src/PubGrub/Incompatibility.hs](../src/PubGrub/Incompatibility.hs), or the unit-propagation /
  conflict-resolution core.
- `Pretty Choice` is updated to render version + non-default flags (e.g. `foo-1.2 +fast -tls`).

## 4. Split provider API

Per the spec sketch, the single expansion is split per package kind and recombined by the
existing `Combined` provider. The generic solver keeps `DependencyProvider` as its **sole**
interface (it stays parametric in `p`, `s`); only the combiner and the two leaf providers change.

### Installed packages (no flags)

Installed packages have their flags baked into the `UnitId`; there is nothing to decide.

```haskell
-- design artifact — pure; the current instance is `pure $ case …` for any monad
expandInstalledPackage
    :: InstalledDbProvider -> PackageName -> Pow UnitId
    -> Maybe (UnitId, Map PackageName (Pow UnitId))
```

**Do not introduce `newtype SingletonSet = SingletonSet UnitId`** (floated in the TODO). The
installed world's set type is already `Pow UnitId`, and a single-unit-id dependency already *is*
`singleton uid = Incl (Set.singleton uid)`. A `SingletonSet` with no `Lattice`/`Sets` instances
would only have to be re-embedded into `Pow UnitId` at the combiner — friction with no
proportional safety. Recommend dropping that idea (it came from a `TODO.md` since
removed).

### Source packages (flags decided here)

```haskell
-- design artifact
data SourceExpansion = SourceExpansion
    { seVersion :: Version
    , seFlags   :: FlagAssignment                -- the assignment actually committed
    , seDeps    :: Map PackageName VersionSet     -- deps flattened AT seFlags
    }

expandSourcePackage
    :: MonadIO m => SourceProvider -> PackageName -> SourceConfigSet -> m (Maybe SourceExpansion)
```

Version, flags, and flag-evaluated deps come out **atomically** — they must, because a
dependency set is only defined once a concrete flag assignment fixes which conditional branches
are live (§5). The returned `(seVersion, seFlags)` must be a point the incoming
`SourceConfigSet` still admits (`member (SourceConfig seVersion (fromAssignment seFlags)) src`),
the flag-axis analogue of today's "the chosen version must be in range" contract.

Once flags are chosen, `seDeps` is a plain `Map PackageName VersionSet`, **type-identical to
today's output**. Flags only changed *which* ranges appear, not the ranges themselves — the
spec's "flags don't influence the compatibility of a build dependency, only the version does".

### The combiner

```haskell
-- design artifact, in app-lib/Provider.hs — DependencyProvider (Combined src) Pkg ChoiceSet m
expand c (Pkg n) (ChoiceSet (inst, srcCfg)) =
    case expandInstalledPackage (cDb c) n inst of
        Just (uid, ideps) ->                       -- prefer-installed policy, unchanged
            pure (Just (Installed uid, fmap installedDep ideps))
        Nothing -> do
            ms <- expandSourcePackage (cSource c) n srcCfg
            pure (fmap sourceResult ms)
  where
    installedDep p = ChoiceSet (p, bottom)         -- `bottom` now over SourceConfigSet; line unchanged
    sourceResult (SourceExpansion v flags sdeps) =
        ( Source (SourceConfig v (assignmentMap flags))
        , Map.mapWithKey liftSourceDep (Map.mapKeys Pkg sdeps) )
    -- a source dep spans both worlds: its range, plus installed instances in that range;
    -- the source facet admits ANY flags — the dependency picks its OWN flags when expanded.
    liftSourceDep (Pkg dn) range = ChoiceSet (installedInRange (cDb c) dn range, anyFlagsIn range)
    liftSourceDep Root     range = ChoiceSet (bottom,                            anyFlagsIn range)
```

where `anyFlagsIn range = SourceConfigSet [SourceCell range top]` — "any version in range, any
flags". The dependency does **not** constrain its own flags here; it makes that decision when it
is itself expanded.

### Flag decision is eager

Flags are chosen inside `expandSourcePackage`, in the same act as choosing the version (like
"newest version" today). This keeps **one `Decision` per package name** and leaves the decide
loop in `Solver.hs` untouched — the alternative (flags as a separate decision variable) would
need a synthetic package per flag or a second decision pass, contradicting the fold model. It is
also *required* for well-defined deps: the solver builds the dependency-cause incompatibility
from `singleton v` at the moment of decision, so `v` (and hence its deps) must already include
the flags.

**Tradeoff:** eager selection *guesses* a flag assignment; the solver can only reject it by
backtracking. Rejecting, say, `foo=True` for a version derives `neg (singleton (Source (SourceConfig v flags)))`
and re-`expand`s with a strictly smaller `SourceConfigSet`. Soundness — that this excludes
`(v, foo=True)` while leaving `(v, foo=False)` open — rests on the DNF lattice's ability to
subtract a *single* `(version, flag-config)` point (§2). This is why the naive representation is
not merely inelegant but unsound for lenient flags.

## 5. Dependency extraction without `finalizePD`

The current [Flatten.hs](../app-lib/PubGrub/Cabal/Flatten.hs) calls
`finalizePD (mkFlagAssignment []) …`. `finalizePD` is dropped entirely: it performs dependency
*satisfiability* resolution and flag *defaulting* we do not want (the solver resolves versions;
the solver chooses flags), and it is a hot spot. We work directly on the conditional tree.

### Reuse Cabal's `Condition`; replace only the `CondTree` walk

Cabal's boolean-expression type is already the right one — **do not invent a parallel `Expr`**:

```haskell
data Condition c = Var c | Lit Bool | CNot (Condition c) | COr … | CAnd …
--  instances: Functor, Applicative, Monad, Foldable, Traversable, Semigroup, Monoid
--  helper:    simplifyCondition :: Condition c -> (c -> Either d Bool) -> (Condition d, [d])
```

`Condition c` is the free boolean algebra over `c`, with `fmap`/`foldMap`/`traverse` and a
partial evaluator. The awkwardness is only in `CondTree`/`CondBranch` (the node-with-
data-constraints-branches shape, `condBranchIfFalse :: Maybe (…)`). Each conditional dependency
tree in a GPD is a `CondTree ConfVar [Dependency] a`, carrying the deps at each node in
`condTreeConstraints :: [Dependency]`. We keep `Condition` and replace the tree walk with one
small fold to **guarded dependency groups**:

```haskell
-- design artifacts

type GuardedDeps = [(Condition FlagName, [Dependency])]   -- guard uses ONLY flags

-- os/arch/compiler are KNOWN inputs; flags stay symbolic (ConfVar's flag ctor is
-- `PackageFlag FlagName` in Cabal-syntax 3.16 — confirm against the pinned version).
envConfVar :: Platform -> CompilerInfo -> ConfVar -> Either FlagName Bool
envConfVar plat comp = \case
    OS os         -> Right (os == platformOS plat)
    Arch a        -> Right (a  == platformArch plat)
    Impl fl vr    -> Right (comp `implMatches` (fl, vr))
    PackageFlag f -> Left f                     -- keep symbolic

-- flatten one component tree; `simplifyCondition … env` folds away os/arch/impl per branch,
-- our ~10-line recursion pushes branch guards down (ifTrue: g ; ifFalse: CNot g).
flattenComponent :: (ConfVar -> Either FlagName Bool)
                 -> CondTree ConfVar [Dependency] a -> GuardedDeps

-- merge the SELECTED components (see below), evaluate at a concrete assignment.
componentDeps :: Platform -> CompilerInfo -> GenericPackageDescription -> GuardedDeps
depsAt        :: FlagAssignment -> GuardedDeps -> Map PackageName VersionSet
--   keep groups whose guard evaluates True; merge with VS.intersection (as today)
```

- **`componentDeps` is computed once** per `(gpd, platform, compiler)` and reused across every
  flag assignment the solver tries on backtracking; `depsAt` is a pure `Condition` fold — no
  satisfiability search, no defaulting. `seFlags` is exactly the assignment we chose (there is
  no `finalizePD`-defaulting layer to disagree with), evaluated over the declared flag domain.
- **Component scope: all libraries and executables.** Merge `condLibrary`, `condSubLibraries`,
  and `condExecutables`; **exclude** `condTestSuites`, `condBenchmarks`, `condForeignLibs` (test
  and benchmark deps must not be forced into a build plan). Make the component filter an explicit
  parameter so it can be widened later.

### Flag domain and manual flags

The per-version flag *domain* comes from `genPackageFlags :: GenericPackageDescription -> [PackageFlag]`
(each `PackageFlag` has name, default, `manual`), read lazily inside `expandSourcePackage` after
the `.cabal` fetch that already happens. **Decision: pin every declared flag** to a concrete
`Bool` when constructing the `SourceConfig`. **Honor `flagManual`:** manual flags are not flipped
from their default unless the user's constraints explicitly ask.

### User flag constraints (lenient)

A user-supplied partial flag assignment enters as an **initial constraint incompatibility** over
the target package — the same path version constraints already use (`fromDependency` in
[src/PubGrub/Incompatibility.hs](../src/PubGrub/Incompatibility.hs)). No new incompatibility
*kind* is needed. For "`P` wants `foo=True`", the constraint set is

```haskell
SourceConfigSet [SourceCell full (FCConj (Map.singleton "foo" True))]
```

"any version of `P`; if `foo` is constrained, it must be True". Because `member` treats a
constrained-but-undeclared flag as vacuously satisfied (§2), a version of `P` that does not
declare `foo` still satisfies this — the lenient rule, for free. Only versions that *declare*
`foo` and set it `False` are excluded. Leniency applies to **user** constraints only: a
package's own conditional branches are resolved by evaluating their `Condition FlagName` guards
at the chosen assignment (`depsAt`), never represented as solver-level flag constraints, so
there is no "strict vs lenient" ambiguity for them.

### Bridge to the flags lattice

A `Condition FlagName` guard *is* a propositional formula over flags, and the union-of-`FlagConj`
DNF of §2 is its disjunctive normal form. If a future step needs set operations on guards (e.g.
to build `SourceConfigSet` constraints directly rather than evaluating point-wise), a
`guardToCells :: Condition FlagName -> [FlagConj]` bridges the two — same
propositional-logic-over-flags idea, two views. Guards are kept as `Condition` and converted
lazily only where set algebra is actually required.

## 6. Migration path and open questions

### Suggested implementation phasing (later task)

1. Land `SourceConfig` / `SourceConfigSet` / `FlagConj` as a new module (e.g.
   `PubGrub.SourceConfig`), promoting the validation spike into real property tests for the
   Boolean/denotation laws (§2 Validation).
2. Swap the `ChoiceSet` source component `VersionSet → SourceConfigSet`; update `Choice`, the
   `Source` pattern, and `Pretty Choice`.
3. Replace `finalizePD` in the Cabal layer with `componentDeps`/`depsAt` (guarded-deps
   extraction over `Condition FlagName`), plus the `genPackageFlags`-based flag domain; split
   the providers (`expandInstalledPackage` / `expandSourcePackage`).
4. Wire user flag constraints as initial constraint incompatibilities.
5. End-to-end solver tests (including the `FlattenSpec` conditional-flag case, now solved rather
   than defaulted).

### Resolved decisions

- **DNF / union-of-cells** over `Map Version FlagAssignment` / a fibered flag map — version×flags
  is a Cartesian product with an *open* version axis, so complement is neither componentwise nor
  version-keyable; only a union of rectangles gives a lawful `neg`.
- **No per-flag set type** (`BoolSet` dropped): a cell's flag constraint is `FlagConj` =
  `Map FlagName Bool` (pinned flags) `| FCBottom`. `FlagConj` is a helper, not a `Boolean`.
- **Semantic `Eq`/`isBottom`/`isTop`** on `SourceConfigSet` — NOT derived; `isBottom = null cells`,
  `isTop = isBottom . neg`, `(==) = mutual subsetOf`. Subsumption pruning in `mkSCS` is required
  (not cosmetic) to bound `neg`'s cell-count blowup. *(Both confirmed by the spike.)*
- **Eager flag choice** inside `expandSourcePackage` — one decision per package name.
- **Pin every declared flag** (domain from `genPackageFlags`); honor `manual`.
- **Drop `finalizePD`.** Extract deps directly from the `CondTree`, reusing Cabal's `Condition`
  (not a custom `Expr`) with `simplifyCondition` for os/arch/impl; guards kept as
  `Condition FlagName`, evaluated point-wise by `depsAt`.
- **Component scope: all libraries + executables** (main + sub-libraries + executables);
  exclude test-suites/benchmarks/foreign-libs. Filter is an explicit parameter.
- **No `SingletonSet`** — `Pow UnitId` singletons suffice.
- **Leniency only for user constraints**; a package's own conditionals are resolved by guard
  evaluation.
- **Solver core unchanged** — flags ride inside `Elem`.

### Genuinely open

- **Cell-count blowup.** `neg` over a `k`-cell union can produce up to `(1 + #flags)^k` cells;
  the spike hit this and needed subsumption pruning in `mkSCS` just to run. Pruning keeps it
  small for realistic packages (well under ~10 flags), but whether a hard cell **cap** is needed
  for adversarial inputs is open — if one is added it must `log` what it drops, never silently
  truncate. (Also note: semantic `Eq`/`subsetOf` cost scales with cell count, another reason to
  keep cells pruned.)
- **Flag selection policy on backtrack.** Defaults-first, then flip — affects search
  performance, not correctness (given the point-subtraction property of §2).
- **The `SourceAssignment` scaffold** in
  [src/PubGrub/SourcePackage.hs](../src/PubGrub/SourcePackage.hs): keep as a reporting helper or
  delete now that flags live inside `Elem`? Confirm nothing else references it before removing.
