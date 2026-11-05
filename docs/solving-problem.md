# Cabal's dependency solving problem

> **Status:** specification. It states the problem that cabal's dependency solver
> answers: what the inputs are, what a solution is, and when a solution is valid. It
> says nothing about how a solution is found and nothing about how anything is
> represented.
>
> §1 is the core problem: one coherent domain, library dependencies only, flags.
> Three extensions follow, each adding to the core without changing it: optional
> components (§2), Backpack (§3), and the separate scopes that executable and setup
> dependencies introduce (§4). §5 lists what this specification leaves open.
>
> Simplifications, throughout. The solver sees one package description per source
> package, so package revisions do not exist here. Every local package is a target:
> narrowing the build to what the user asked for happens after solving. Relaxations
> of declared ranges such as `allow-newer` and `allow-older` rewrite the inputs
> before solving and do not appear. Every package with a custom build type has a
> well-formed `custom-setup` stanza. A custom setup script is an opaque build
> procedure constrained only by its declared dependencies. The `base` qualifier and
> independent-goal namespaces of cabal's solver are ignored, and so is its check of a
> component's languages and extensions against the compiler.

## 1. The core problem

### 1.1 Names, versions, ranges

A *package name* identifies a piece of code that can be published many times with
different version numbers.

A *version* is a value from a totally ordered set.

A *version range* `r` is a predicate on versions. Write `v ∈ r` when `v` satisfies
it.

### 1.2 Source packages and components

A *source package* `s = (p, v)` is a package name together with a version. A
*repository* is a finite set `Repo` of source packages, each with exactly one
package description. The repository may also mark, for each package name, a set
of versions as *deprecated*; that mark is used only by §1.10.

The description gives a static finite set of *components*, `comps(s)`. A component
is identified within its source package by a kind and a name:

```text
(kind, name)      kind ∈ { library, executable, foreign-library }
```

The main library of package `p`, when there is one, is the component
`(library, p)`. Any other library component is a named library. The main library
may share its name with one component of another kind, usually an executable. No two
named sections may share a name, whatever their kinds (§2): the parser accepts it, the
solver does not look, and Cabal's configure step refuses it. `cabal check` reports it
for all but foreign libraries.

Component identity is local to a source package. `foo-1.0` and `foo-1.1` may
contain different components. So "does this package contain component `x`" is a
question about a source package, not about a package name.

### 1.3 Environment, flags, conditions, configurations

A solve fixes an *environment* `E`:

```text
an operating system
an architecture
a compiler with its version
the set of pkg-config modules present on the machine, each with its version
```

`E` is the same everywhere in one solve.

Each source package `s` declares a finite set of *flags*, `F(s)`. A flag has a
name, a default value in `{true, false}`, and a mode in `{manual, automatic}`. The
set of declared flags is a property of the source package, not of the package name.
Two versions of one package may declare different flags, and a flag of one version
shares only its name with a flag of another: each has its own default and its own
mode, and at most one of them is ever live, since a plan contains at most one
version of the package.

The package description is a conditional tree. Every field that matters here sits
under a *condition*: a boolean expression built with `&&`, `||` and `!` from the
atoms

```text
flag(f)           f ∈ F(s)
os(o)
arch(a)
impl(c, r)        compiler c, version range r
```

Under a fixed `E`, every atom except `flag(f)` is a constant. So each condition of
`s` reduces to a boolean formula over `F(s)` alone.

A *configuration* of `s` is a total assignment

```text
α : F(s) → { true, false }        with domain exactly F(s)
```

Totality means every condition of `s` is decided. Exactness means `α` says
nothing about a flag the version does not declare.

Evaluating the tree under `E` and `α` gives the *effective description* of `s`.
For each component `c` it yields:

```text
buildable(s, c, α)     a boolean, the component's buildable: field
deps(s, c, α)          a finite set of dependencies              (§1.4)
pkgdeps(s, c, α)       a finite set of pkg-config dependencies   (§1.4)
```

### 1.4 Dependencies

*Library dependencies* are the ordinary `build-depends:` entries. A dependency is

```text
(q, r, sel)       package name q, version range r, sel a library selector
sel ∈ { main library, library n }
```

In cabal's syntax `q` alone selects the main library of `q`, and `q:n` selects the
named library `n` of `q`.

A dependency is a constraint on two things at once: the version of `q`, and the
presence of the selected component in that version. A version in range that lacks
the component cannot satisfy the dependency, and neither can one in which the
selected component is unbuildable or is a private library (§1.9). A named library is
private unless declared `visibility: public`, and a private library can be selected
only from its own package.

*pkg-config dependencies* are the `pkgconfig-depends:` entries. Each is a module
name with a version range. Nothing in a plan can satisfy one; only the environment
can. It is satisfied when `E` lists the module at a version in the range.

An *internal dependency* is a library dependency whose package name is the
depender's own package. There is nothing to choose for it, since the depender's
own source package is the only thing that can satisfy it. Its range still holds: a
version outside the range of its own internal dependency cannot be chosen (V2).
Otherwise it matters for build order (§1.11), and, when it sits under a flag or
stanza, the solver also rejects it if the package's own component is missing or
unbuildable.

### 1.5 Solving is per package

Solving chooses versions and configurations for packages, not for components.
Given a configuration, the dependencies of every component of a source package are
considered together as the dependencies of the whole package.

The *included components* of `s` under `α` are the components that are buildable
under `α`:

```text
inc(s, α) = { c ∈ comps(s) | buildable(s, c, α) }
```

An unbuildable component is not included: it contributes no build unit and no
dependencies. §2 refines `inc` for optional components.

The dependencies of the package are those of its included components, minus the
internal ones:

```text
deps(s, α)    = ⋃ { deps(s, c, α)    | c ∈ inc(s, α) }  minus internal dependencies
pkgdeps(s, α) = ⋃ { pkgdeps(s, c, α) | c ∈ inc(s, α) }
```

So an executable of a dependency package contributes its dependencies to solving
even though nothing in the plan depends on that executable.

### 1.6 Installed units

An *installed unit* `u` is a library already registered in a package database. It
records

```text
a unit id
pkg(u)            a package name
ver(u)            a version
a library component name
linked(u)         the set of installed units it was built against
```

It records no configuration. The flags and build options that produced it cannot
be recovered from it. Only libraries are installed units; there is no installed
executable, test, benchmark or foreign library in this sense.

The set `I` of installed units is an input to the solve. Whether a registered unit
is usable at all, for instance whether everything in `linked(u)` is itself present,
is a property of that input, not a condition stated here.

### 1.7 The project

A *project* supplies:

- A finite set `L ⊆ Repo` of *local packages*: source packages the user has
  explicitly included. Every other source package that ends up in a plan is a
  *dependency package*. Every local package is a target.
- A finite set of *user constraints*. A user constraint names a package `p` and
  states one property:

  ```text
  version range r     every choice for p has a version in r
  installed           the choice for p, if there is one, is an installed unit
  source              the choice for p, if there is one, is a source package
  flag f = b          every chosen source package of p that declares f has f = b
  ```

  A flag constraint is keyed by package name, so it may name a flag that some
  version of `p` does not declare. It applies to the versions that declare `f` and
  says nothing about the versions that do not. Write `U_p` for the partial
  assignment the flag constraints on `p` define, and assume they give each flag at
  most one value. §2 adds one more property and §4 adds a scope to every
  constraint.

### 1.8 A plan

A *plan* is

```text
choice : package name ⇀ Repo ∪ I     with choice(p) = (p, _) or pkg(choice(p)) = p
α(s)   : a configuration of s        for every source package s in the range of choice
```

`choice` is a partial function: each package name has at most one *package
choice*, either a source package to build or an installed unit to reuse. This is
*package-version coherence*, and in the core problem there is exactly one coherent
domain, so a plan holds one version and one configuration of each package it
contains.

Nothing else is chosen. Which components are built, and what depends on what,
follow from `choice` and `α` through §1.5.

### 1.9 Validity

A dependency `d = (q, r, sel)` in `deps(s, α(s))` is *satisfied* by the plan when
one of the following holds:

- `choice(q)` is a source package `s' = (q, v')` with `v' ∈ r`, and the selected
  library is public and in `inc(s', α(s'))`.
- `choice(q)` is an installed unit `u` with `ver(u) ∈ r` whose library component
  name matches `sel`.

A plan is *valid* when:

- **V1, roots.** For every local package `l`, `choice(name(l)) = l`.
- **V2, closure.** For every source package `s` in the range of `choice`, every
  `d ∈ deps(s, α(s))` is satisfied, every pkg-config dependency in
  `pkgdeps(s, α(s))` is satisfied by `E`, and the version of `s` is in the range of
  every internal dependency of every component in `inc(s, α(s))`.
- **V3, flags.** For every source package `s = (p, v)` in the range of `choice`
  and every `f ∈ F(s)`:
  - if `f` is manual, `α(s)(f)` is `U_p(f)` when `U_p` defines `f`, and the
    declared default otherwise;
  - if `f` is automatic, `α(s)(f)` is `U_p(f)` when `U_p` defines `f`, and is
    otherwise unconstrained.
- **V4, user constraints.** Every user constraint holds, with the meaning given
  in §1.7.
- **V5, installed linkage.** If `choice(q)` is an installed unit `u`, then for
  every `u' ∈ linked(u)`, `choice(pkg(u')) = u'`.
- **V6, acyclicity.** The graph whose nodes are the source packages in the range
  of `choice`, with an edge from `s` to `choice(q)` whenever some
  `d ∈ deps(s, α(s))` names `q` and `choice(q)` is a source package, has no
  cycle.
- **V7, minimality.** Every package choice is reachable from a local package
  along dependencies: `choice(p)` is defined only if `p` is the name of a local
  package or some source package in the range of `choice` has a dependency on
  `p`.

V1 and V7 together say a plan is exactly the dependency closure of the local
packages. V6 excludes installed units from its graph because an installed unit
depends only on installed units, and a cycle among those is impossible.

V3 is the whole difference between the two flag modes. A manual flag has no
freedom: its value is fixed by the user or by the declaration before solving
starts, and a plan with any other value is invalid. An automatic flag is a free
variable of the problem, constrained only through V2, because its value changes
which dependencies exist.

### 1.10 Preference

Everything above is a satisfiability problem, and several valid plans usually
exist. Which one cabal produces is configurable. In general:

- cabal prefers a newer version of a package over an older one;
- cabal avoids the versions the repository marks as deprecated, trying one only
  after the search has failed on the others;
- cabal starts an automatic flag at its declared default and moves off it only
  when forced.

These are preferences among valid plans, applied by the order in which the search
tries alternatives. They are not conditions of validity, and a plan that goes
against every one of them is still valid.

### 1.11 After solving: build units and build order

Once a valid plan is fixed, each included component of each chosen source package
becomes a *build unit*: the component, configured under `α(s)`, with its
dependencies assigned by `choice`. A library build unit produces library artefacts
and an installed unit. Every other kind produces an artefact and no installed
unit. Nothing about build units is chosen; they are derived from the plan.

Build order is computed on the build units, and at that granularity internal
dependencies count: an executable of `s` is built after the library of `s` it
depends on. A cycle among components is refused at this stage. It cannot arise
from a choice the solver made, since V6 already forbids a cycle among packages
and internal dependencies involve no choice, so it is a defect of the package
description, not of the plan.

## 2. Extension: optional components

Library, executable and foreign-library components are *ordinary* components. This
extension adds two *optional* kinds:

```text
kind ∈ { library, executable, foreign-library, test, benchmark }
```

Test and benchmark components are executable-like. They produce executable
artefacts, they produce no installed unit, and nothing can depend on them.

User constraints gain one property:

```text
stanzas S           S ⊆ { tests, benchmarks }: the optional components of p that must be enabled
```

For a source package `s`, `enabled(s)` is the set of its test components, if the
constraints on its name enable `tests`, together with its benchmark components, if
they enable `benchmarks`. The default, when the user says nothing, is

```text
every test and benchmark component of a local package is enabled
no test or benchmark component of a dependency package is enabled
```

and the user may enable or disable the tests or the benchmarks of any package. Cabal
holds the local default as a preference unless the user asked explicitly, so a plan
with that stanza disabled is valid (§5).

An optional component is included only when it is both enabled and buildable:

```text
inc(s, α) = { c ∈ comps(s) | buildable(s, c, α), and c is ordinary or c ∈ enabled(s) }
```

That is the whole change. An enabled optional component contributes its
dependencies to `deps(s, α)` and `pkgdeps(s, α)` exactly as an ordinary one does,
and V2 closes over them. A disabled one contributes nothing, exactly as an
unbuildable one does.

## 3. Extension: Backpack

### 3.1 Requirements, definite and indefinite units

A library component may declare module signatures. Each declared signature is a
*requirement*, also called a hole: a module interface that some module must
implement before the library can be compiled.

A library build unit with no unsatisfied requirement is *definite*. One with an
unsatisfied requirement is *indefinite*. Only library components can give rise to
indefinite units. Every executable, test, benchmark and foreign-library build unit
must be definite to produce its artefact.

A definite library unit is compiled and registered as a definite installed unit.
An indefinite library unit is typechecked and registered as an indefinite
installed unit that carries its requirements. An installed unit may therefore be
definite or indefinite.

### 3.2 Mixins, inclusions, instantiations

A library dependency may be included through a *mixin*, which determines which
modules and requirements of the dependency are brought into the depender's module
environment, and under which names. A mixin may expose everything unchanged,
expose only selected modules, hide selected modules, rename provided modules, or
rename required signatures.

A *library inclusion* is a resolved library unit together with a mixin. The module
environment of a component is constructed from its library inclusions. The same
unit may be included more than once under different mixins.

An *instantiation* maps each requirement of an indefinite unit to an
implementation module. A module implementation is identified by the unit that
provides it together with the module name, not by the module name alone:

```text
requirement  =>  providing unit + module name
```

A requirement of an included unit is satisfied when the depender's module
environment, after the mixin's renaming, contains an implementation module that
matches it.

### 3.3 Unit identity and coherence

With Backpack a library build unit is identified by its source package, component,
configuration, dependency assignment, and instantiation. Two library build units
that agree on everything but instantiation are distinct units.

Package-version coherence (§1.8) is unchanged: the plan still holds one version of
each package. On top of it, the derived build units are *unit coherent* when each
fully instantiated library identity is assigned at most one unit. So one library
component, at one version, may give rise to several units that differ in
instantiation, and never to two units with the same instantiation.

### 3.4 What this extension does not change

Choosing a source package version and a component is not enough to determine a
Backpack unit. The unit is determined only after the configuration, the dependency
assignment and the mixins are known, and the instantiation is computed from them.
So this extension does not change which plans are valid. It changes what a build
unit is, and it adds one condition on the elaborated build units: every
requirement of every non-library unit's inclusions must be satisfied.

## 4. Extension: executable dependencies, setup dependencies, and scopes

### 4.1 Executable dependencies

Executable dependencies are `build-tool-depends:` entries, and the legacy
`build-tools:` entries cabal can translate to one. A dependency gains a third kind
of selector:

```text
(q, r, sel)       sel ∈ { main library, library n, executable n }
```

In cabal's syntax `q:n` under `build-tool-depends:` selects executable `n` of
package `q`. As with a library selector, the dependency is satisfied only by a
version of `q` in `r` that contains `(executable, n)` and in which that executable
is buildable. No installed unit can satisfy an executable dependency, since
installed units are libraries.

An executable dependency is a build-time dependency. The depender needs the
executable artefact and nothing else: the libraries used to build that executable
do not become dependencies of the depender and need not agree with the depender's
own library choices.

An executable dependency on the depender's own package is internal too, and cabal
drops it before solving, range included. The solver checks neither the range nor that
the executable exists, so such a release passes solving and Cabal's configure step
then refuses it.

### 4.2 Setup dependencies

A source package whose build type is `Custom` or `Hooks` has a *setup program*:
the package is built by compiling and running its own setup script. The setup
program is a package-level build procedure, not a component of the package. Every
other build type uses cabal's own build procedure and has no setup program.

A custom setup is an implicit executable dependency. The package needs an
executable, the setup program, built before the package itself can be built. That
executable does not come from the repository: its source is the package's own
setup script, and its library dependencies are the package's declared *setup
dependencies*, the `setup-depends:` entries of the `custom-setup` stanza. Write
`setup(s)` for that finite set of library dependencies, or *none* when `s` has no
setup program. Setup dependencies are not under conditions, so `setup(s)` does not
depend on `α(s)`.

Setup dependencies are build-time dependencies of the source package. They do not
become dependencies of any component of the package, and the libraries used to
build the setup program need not agree with the package's own library choices.

### 4.3 Scopes

A *scope* is a coherence domain. Package-version coherence (§1.8) and, under §3,
unit coherence hold within a scope. There is no coherence requirement across
scopes: the same package name may be chosen at different versions in different
scopes. The same source package or installed unit may be chosen in several scopes
only under V9 (§4.6). Cabal's solver calls a scope a *qualifier*
(`Distribution.Solver.Types.PackagePath`, with `QualSetup` and `QualExe`).

Scopes are identified by package names, and there are three kinds:

```text
top               the main scope
setup(p)          the setup scope of package name p
exe(p1, p2)       the scope in which the executables of p2 that p1 needs are built
```

Which scope a dependency is resolved in depends on the kind of dependency and on
the name of the depender, never on the scope the depender is in:

```text
a library dependency of a package in scope σ is resolved in σ
an executable dependency of a package named p1 on package q is resolved in exe(p1, q)
a setup dependency of a package named p is resolved in setup(p)
```

Because the identity is by name, a scope is shared. Every occurrence of `p`, at
whatever version and in whatever scope, uses the one setup scope `setup(p)`.
Every occurrence of `p1` that needs an executable of `p2` uses the one scope
`exe(p1, p2)`. The number of scopes is bounded by the number of package names.

Both keyings are deliberate simplifications. Setup scopes ought to nest, since a
setup dependency may itself have a setup program with its own dependencies, but
nesting gives the solver an unbounded search tree, so cabal allows one setup scope
per package name and no nesting. Executable scopes are keyed by the pair because
either name alone is wrong: keying by `p1` only would force every executable
`p1` needs, from every package, into one coherent resolution; keying by `p2` only
would force one version of `p2`'s executables on the whole plan.

The only thing that crosses a dependency edge between scopes is the artefact: the
executable, or the setup program. Apart from V9, package choices made in one scope
place no constraint on package choices made in another.

### 4.4 Occurrences and the plan

A plan becomes a finite set of scopes, each carrying its own

```text
choice_σ : package name ⇀ Repo ∪ I
α_σ(s)   : a configuration of s        for every source package s chosen in σ
```

An *occurrence* is a pair `(σ, s)` of a scope and a source package chosen in it.
Everything §1.5 derives from a chosen package, its included components and its
dependencies, is derived per occurrence, from `α_σ(s)`. Under §2, `enabled` is
likewise read per occurrence, from the constraints that apply in `σ` (§4.6).

User constraints gain a *scope selector*:

```text
any scope
the main scope only
any setup scope
one named scope, setup(q) or exe(q, p)
```

A constraint applies in the scopes its selector names, so a constraint on `p`
selecting the main scope says nothing about `p` in `setup(q)` or `exe(q, p)`.

### 4.5 Satisfaction with scopes

A dependency `d = (q, r, sel)` of an occurrence `(σ, s)` with `s = (p, v)` is
*satisfied* when:

- `sel` is a library selector, and `d` is satisfied by `choice_σ` exactly as in
  §1.9, with `α_σ` in place of `α`.
- `sel` is `executable n`, and in the scope `τ = exe(p, q)`, `choice_τ(q)` is a
  source package `s' = (q, v')` with `v' ∈ r` and `(executable, n)` in
  `inc(s', α_τ(s'))`.

A setup dependency `d ∈ setup(s)` of an occurrence `(σ, s)` with `s = (p, v)` is
satisfied when `d` is satisfied by `choice_setup(p)`, as a library dependency, as
in §1.9.

The *occurrence graph* of a plan has the occurrences as nodes and an edge from
`(σ, s)` to the occurrence that satisfies each of its dependencies:

```text
(σ, s) → (σ, choice_σ(q))              for a library dependency on q
(σ, s) → (exe(p, q), choice_exe(p,q)(q))   for an executable dependency on q
(σ, s) → (setup(p), choice_setup(p)(q))   for a setup dependency on q
```

Edges into installed units are recorded but, as in V6, cannot lie on a cycle.

### 4.6 Validity with scopes

A plan is valid when:

- **V1, roots.** For every local package `l`, `choice_top(name(l)) = l`.
- **V2, closure.** For every occurrence `(σ, s)`, every `d ∈ deps(s, α_σ(s))` is
  satisfied (§4.5), every pkg-config dependency in `pkgdeps(s, α_σ(s))` is
  satisfied by `E`, the range of every internal library dependency holds as in §1.9,
and if
  `setup(s)` is not *none*, every `d ∈ setup(s)` is satisfied.
- **V3, flags.** V3 of §1.9 holds in every scope, against that scope's `α_σ`,
  with `U_p` read from the flag constraints that apply in that scope. One
  relaxation: a manual flag constrained only in other scopes may also take the
  constrained value here, so that the occurrences can link (V9).
- **V4, user constraints.** Every user constraint holds in every scope its
  selector names.
- **V5, installed linkage.** V5 of §1.9 holds in every scope, against that
  scope's `choice_σ`.
- **V6, acyclicity.** The occurrence graph has no cycle.
- **V7, minimality.** Every occurrence is reachable in the occurrence graph from
  some `(top, l)` with `l` a local package.
- **V8, independence.** No condition relates `choice_σ` and `choice_σ'` for
  distinct scopes `σ` and `σ'`, beyond the edges of §4.5 and V9.
- **V9, single instance.** When several scopes choose the same source package or the
  same installed unit, their occurrences are linked: they have equal configurations
  and enabled stanzas, and their dependencies are linked in turn.

V8 is not a constraint but the explicit absence of one. V7 says which scopes a
plan has: a scope exists exactly when some occurrence has an edge into it. V6 now
does double duty. Within a scope it is V6 of §1.9. Across scopes it rules out two
packages each needing an executable of the other, since with scopes keyed by name
that chain returns to an occurrence it has already visited.

Since `setup(p)` is shared by every occurrence of `p`, if two occurrences of `p`
at different versions declare different setup dependencies, `setup(p)` must
satisfy both sets. Since `exe(p1, p2)` is shared, the version of `p2` chosen there
must satisfy every executable dependency any occurrence of `p1` has on `p2`, and
every such executable must be buildable in it.

### 4.7 Structure

By V8, apart from V9, the choices in one scope are constrained by other scopes only
through the roots those scopes hand it: the main scope's roots are the local packages,
the roots of `exe(p1, p2)` are the executables of `p2` that the occurrences of `p1`
need, and the roots of `setup(p)` are the setup dependencies of the occurrences of
`p`. The roots of a scope are therefore determined by occurrences in other scopes,
and V6 guarantees that this determination is well-founded: there is an order of
the occurrences in which every occurrence's dependencies are resolved by
occurrences that come earlier.

Cabal's solver *links* occurrences across scopes, so that one build unit serves
both. V9 is the condition. Trying a linked choice first, where scopes could also
choose different versions, is a preference in the sense of §1.10.

## 5. What this specification leaves open

- **Preference beyond §1.10.** Cabal's full preference order is configurable and
  is expressed by search order rather than by a ranking of whole plans. Installed
  units over rebuilding at an equal version, and enabling optional components
  where a valid plan allows and disabling them where it does not, are two rules in
  it that §1.10 does not state.
- **Optional components of a local package outside the main scope.** The default
  of §2 enables the tests and benchmarks of a local package. Whether that default
  reaches an occurrence of the local package in a setup or executable scope, or
  applies in the main scope only, is not stated.
- **Pruning to targets.** Every local package is a target here. Narrowing the
  plan to the packages the user named, and their dependencies, happens after
  solving and is not described.
- **Component-level build order.** §1.11 says a cycle among components is refused
  after solving. The build-order graph itself, and how Backpack instantiation
  enters it, are not described.
