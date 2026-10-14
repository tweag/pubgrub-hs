# Cabal's build model

> **Status: forward-looking reference. None of this is implemented.** A model of
> *Cabal's* build structure — components, scopes, build units, installed units, setup
> programs, Backpack — not of our solver. It is the reference for **rungs 4 and 5**
> (setup and build-tool dependencies, public sublibraries), which have not been
> started.
>
> **"Scope" here is cabal's "qualifier".** `Distribution.Solver.Types.PackagePath`
> calls it `Qualifier`, and that is the word `../CLAUDE.md` and the shelved
> qualified-goals design use. Same concept, two names. Read them as synonyms.
>
> The solver as built handles one component per package and ignores scopes entirely.
> See [STATUS.md](STATUS.md) §3.2.

## Scope of this specification

This specification describes a simplified semantic model of building Cabal packages and projects.

The following Cabal features are intentionally simplified or ignored:

* package revisions are ignored.
* Cabal command-line target selectors are ignored.
* the detailed semantics of `buildable: false` are ignored here. The solver does
  implement it: `PubGrub.Cabal.Flatten`'s `buildableCondition` and
  `buildableAtDefaults`, plus `pkgconfig-depends` against the machine's real
  `pkg-config` database.
* custom setup scripts are treated as opaque package-level build procedures.
* Backpack is modelled only at the level needed to describe requirements, mixins, instantiations, and definite/indefinite units.

In this model, a project builds all enabled components of all local packages.

## Packages and source packages

A *package* is a name identifying a piece of code that can be published multiple times with different version numbers.

A *source package* is the source distribution of a particular version of a package.

A source package is uniquely identified by:

```text
package name
package version
```

Package revisions are ignored in this specification.

A *repository*, such as Hackage, provides a collection of source packages together with their package descriptions.

A package name does not determine a fixed set of components. Each source package version contains its own static set of components. Different versions of the same package may contain different components.

Therefore, component availability is a property of a source package, not merely of a package name.

## Components

A source package contains a static set of *components*.

A component is a compilation unit: a set of source files compiled together into a single binary artefact. The artefact may be statically or dynamically linked with other artefacts.

The component kinds in this specification are:

```text
library
executable
test
benchmark
foreign-library
```

A component is uniquely identified within a source package by:

```text
component kind
component name
```

Component identity is local to a particular source package version. The same package name at different versions may expose different component identities.

If a source package has a main library, this specification treats that main library as a library component whose name is the package name.

Therefore, the main library of package `p` is identified as:

```text
library p
```

This convention makes component identity unambiguous, even when a source package contains multiple components with the same textual name but different kinds.

For example, the following are distinct component identities:

```text
library foo
executable foo
test foo
benchmark foo
foreign-library foo
```

## Ordinary and optional components

Library, executable, and foreign-library components are *ordinary components*.

Test and benchmark components are *optional components*.

An optional component is included in the build plan only when it is enabled by the project configuration.

If an optional component is not enabled, it contributes no build unit and its dependencies do not participate in dependency solving.

Test and benchmark components are executable-like components. Like executable components, they produce executable artefacts and are not registered as installed units.

## Dependencies

A dependency consists of:

```text
package name
package version range
component selector
```

In this simplified model, dependency component selectors are either library selectors or executable selectors.

A library component selector specifies either:

```text
the main library
a named library component
```

An executable component selector specifies:

```text
an executable component name
```

A component selector is interpreted relative to a candidate source package version.

Dependency solving first chooses a candidate source package version satisfying the package name and version range. The dependency’s component selector is then checked against the components of that source package.

If the selected source package version does not contain the required component, that source package version cannot satisfy the dependency.

Therefore, a dependency is a constraint both on package versions and on component availability.

For example, an executable dependency on executable `bar` from package `foo` means:

```text
choose a source package foo-v such that:
  v satisfies the version range
  foo-v contains executable component bar
```

A library dependency on package `foo` with no explicit library name means:

```text
choose a source package foo-v such that:
  v satisfies the version range
  foo-v contains the main library component foo
```

A library dependency on named library `internal` from package `foo` means:

```text
choose a source package foo-v such that:
  v satisfies the version range
  foo-v contains library component internal
```

Library dependencies and executable dependencies have different semantics during the build.

A library dependency is resolved in the current scope.

An executable dependency is a build-time dependency. It is resolved in a fresh executable dependency scope. The executable artefact produced in that scope is made available to the depender, but the library choices used to build that executable do not enter the depender’s scope.

## Setup programs

A source package may have a setup program.

The setup program is a package-level build procedure, not a normal component of the package.

The setup program may have its own library dependencies, called *setup dependencies*. Setup dependencies are build-time dependencies of the source package. They are resolved in a setup scope and do not become dependencies of the package’s library, executable, test, benchmark, or foreign-library components.

For custom setup scripts, Cabal does not fully specify component-level behaviour independently of the setup program. A custom setup program is therefore treated as an opaque package-level build step, constrained only by its declared setup dependencies.

## Projects and local packages

A *project* is the entire build configuration.

A project defines a set of *local packages*.

A local package is a source package explicitly included by the user in the project configuration.

Dependency packages brought in by dependency solving are not local packages unless they are also explicitly included by the user.

In this simplified model, the project builds all enabled components of all local packages.

A non-local source package may still be selected as a dependency and built as part of the project. Such a package contributes build units to one or more scopes in the build plan, but it is not a local package.

## Enabling tests and benchmarks

A project configuration determines, for each source package occurrence in a scope, whether its test and benchmark components are enabled.

The default project configuration is:

```text
enable tests for all local packages
enable benchmarks for all local packages
disable tests for all non-local dependency packages
disable benchmarks for all non-local dependency packages
```

If tests or benchmarks are enabled for a package occurrence, the enabled test and benchmark components contribute build units and dependency constraints to that occurrence’s scope.

If tests or benchmarks are disabled for a package occurrence, those components contribute no build units and no dependency constraints.

## Scopes

A *scope* is a dependency-solving context that defines a domain of coherence.

Coherence is local to a scope. There is no global coherence requirement across the whole project.

A *package choice* is the selection, within a scope, of a source package version for a package name.

A scope is *package-version coherent* when each package name has at most one package choice in that scope.

Different scopes may make different package choices for the same package name. Therefore, the same package may appear in different scopes at different versions.

The same source package version may also appear in multiple scopes. When this happens, each occurrence belongs to its own scope and may have its own selected configuration, dependency assignment, build units, and Backpack instantiations.

A build unit is always scoped. A build unit is created by configuring a component of a package choice within a particular scope.

Therefore, the same source package component may give rise to different build units in different scopes.

For library units, a scope is *unit coherent* when each fully instantiated library identity is assigned at most one unit within that scope.

With Backpack, the same package version and library component may give rise to multiple units within the same scope if those units have different instantiations.

Across different scopes, even units derived from the same package version, component, configuration, and instantiation are treated as belonging to separate coherence domains.

A dependency edge determines how scopes are used:

```text
ordinary library dependencies are resolved in the current scope
executable dependencies are resolved in fresh executable dependency scopes
setup dependencies are resolved in setup scopes
```

Package choices made in one scope do not constrain package choices made in another scope, except through the explicit artefact or unit made available across the dependency edge.

## The main project scope

A project has a main project scope.

The main project scope is the coherence domain used to resolve the enabled components of local packages and their ordinary library dependencies.

For each enabled component of a local package, the main project scope contains a corresponding build unit, or enough dependency information to construct one.

For local packages, enabled components may include:

```text
library components
executable components
foreign-library components
enabled test components
enabled benchmark components
```

All ordinary library dependencies of components in the main project scope are resolved in the main project scope.

Therefore, all enabled components of all local packages share one coherent dependency assignment for ordinary library dependencies.

Foreign-library components belong to the main project scope when they are components of local packages.

Enabled test and benchmark components of local packages also belong to the main project scope.

The package choices made in the main project scope apply only within that scope.

## Executable dependency scopes

Each executable dependency is resolved in its own executable dependency scope.

An executable dependency scope is a separate coherence domain created for building an executable dependency.

The executable dependency scope contains the executable component being built, together with the library dependencies needed to build it.

Package choices made in an executable dependency scope do not need to agree with package choices made in the depender’s scope.

The resulting executable artefact is made available to the depender.

The libraries used to build the executable dependency do not enter the depender’s scope.

Therefore, different executable dependencies may use package versions and build configurations that differ from those chosen in the main project scope or in other executable dependency scopes.

## Setup scopes

Each setup program is resolved in a setup scope.

A setup scope is a separate coherence domain created for building and running a setup program.

The setup scope contains the setup program and the library dependencies needed to build and run it.

Package choices made in the setup scope do not need to agree with package choices made in the package’s ordinary component scope.

The resulting setup program is used to build the source package.

The libraries used to build the setup program do not enter the ordinary component scope of the package being built.

Therefore, setup dependencies may use package versions and build configurations that differ from those chosen in the main project scope or in executable dependency scopes.

## Build units

A *build unit* is a configured component instance in a build plan.

A build unit represents something that the current project build intends to build.

A build unit is always associated with a scope.

A build unit includes:

```text
scope
source package
package version
component kind
component name
selected configuration
effective component description
compiler and platform information
build options
dependency assignment
build artefact locations
```

For Backpack libraries, a build unit may also include an instantiation.

Library, executable, test, benchmark, and foreign-library components can all give rise to build units.

Different component kinds produce different artefacts:

```text
library build unit
  => library artefacts
  => installed unit

executable build unit
  => executable artefact

test build unit
  => test executable artefact

benchmark build unit
  => benchmark executable artefact

foreign-library build unit
  => foreign-linkable library artefact
```

Only library build units produce installed units.

Executable, test, benchmark, and foreign-library build units do not produce installed units in the GHC package database sense.

The same source package, component, and package version may give rise to different build units in different scopes, because each scope may choose different configurations, dependency assignments, or Backpack instantiations.

## Installed units

An *installed unit* is a library unit registered in a package database.

Cabal and GHC often refer to installed units as “installed packages”, “pre-installed packages”, or “pre-existing packages”. This specification uses the term *installed unit* to avoid confusing them with source packages.

An installed unit is uniquely identified by a unit id.

An installed unit records information such as:

```text
unit id
package name
package version
library component name
exposed and hidden modules
ABI/interface information
dependencies on other installed units
Backpack requirement and instantiation information, when applicable
```

An installed unit does not record the full build configuration that produced it. In particular, it does not record enough information to reconstruct selected flags, build options, or the complete configured package description.

A library build unit may be compiled and registered into a temporary package database during the build. Such a registration is an installed unit in the GHC package database sense, but it is only a lossy projection of the richer build unit.

After the build plan is gone, only artefacts and package database registrations remain. The build configuration that produced them is not recoverable from installed units alone.

An existing installed unit may be used as an input to a scope. Such an installed unit is not a build unit of the current project, because its build configuration is not part of the current build plan.

## Definite and indefinite units

With Backpack, a library unit may be definite or indefinite.

A *requirement*, also called a *hole*, is a module interface that must be implemented by some module before a library unit can become fully definite.

A library component may declare module signatures. Each declared module signature introduces a requirement.

A *definite* library unit has no unsatisfied requirements.

An *indefinite* library unit has one or more unsatisfied requirements.

Only library components may produce indefinite units.

Executable, test, benchmark, and foreign-library build units must ultimately be definite in order to produce their artefacts.

A definite library build unit produces compiled library artefacts and a definite installed unit.

An indefinite library build unit may be typechecked and registered as an indefinite installed unit, but it does not produce ordinary compiled library artefacts in the same way as a definite unit.

An installed unit may therefore be definite or indefinite.

The package database records enough information for GHC to distinguish definite and indefinite units and to track their requirements and instantiations. The exact package database representation is outside this specification.

## Backpack mixins and instantiations

A library dependency may be included through a *mixin*.

A mixin determines which modules and requirements of a dependency are brought into scope, and under which names.

A mixin may:

```text
expose all modules and requirements unchanged
expose only selected modules
hide selected modules
rename provided modules
rename required signatures
```

The module environment of a component is constructed from its library inclusions.

A *library inclusion* consists of:

```text
a resolved library unit
a mixin
```

The same library unit may be included under different mixins.

An *instantiation* maps requirements of an indefinite library unit to implementation modules provided by other units.

A requirement is satisfied when the component’s module environment contains an implementation module matching that requirement after mixin renaming.

A module implementation is identified not merely by its module name, but by the unit that provides it together with the module name.

Therefore, an instantiation maps requirements to module identities, not just to bare module names.

Conceptually:

```text
requirement
  => providing unit + module name
```

A library build unit is therefore identified not only by source package, version, component, configuration, dependency assignment, and scope, but also by its Backpack instantiation.

Two build units may have the same package name, package version, library component name, and scope, but differ by instantiation. Such build units are distinct.

Two build units may also have the same package name, package version, library component name, and instantiation, but differ by scope. Such build units are also distinct because scopes are separate coherence domains.

## Dependency solving pipeline

A dependency is resolved conceptually as follows:

```text
read dependency:
  package name
  version range
  component selector

choose candidate source package version:
  package name matches
  version satisfies range

inspect candidate source package:
  required component exists

configure selected component in the current scope:
  evaluate configuration
  determine effective dependencies and build options

for library dependencies:
  resolve in the current scope
  apply mixins
  construct module environment
  determine requirements and implementations
  construct or select instantiated library unit

for executable dependencies:
  construct executable dependency scope
  resolve the executable component in that scope
  build executable artefact in that scope
  make executable artefact available to the depender

for setup dependencies:
  construct setup scope
  build setup program in that scope
  use setup program to build the source package
```

A candidate source package version that does not contain the required component is rejected.

For Backpack libraries, choosing the source package version and component is not enough to determine the final unit. The unit is determined only after configuration, dependency assignment, mixin application, instantiation, and scope are known.

## Build lifecycle

At the source level, a package version provides source components.

Within a scope, dependency solving chooses package versions and constructs package choices.

During elaboration, source components of package choices are configured into build units.

A library build unit may be definite or indefinite.

A definite library build unit may be compiled and registered into a package database, producing a definite installed unit.

An indefinite library build unit may be typechecked and registered as an indefinite installed unit, carrying its unsatisfied requirements.

Other build units may then depend on installed units, possibly instantiating indefinite units through Backpack.

The lifecycle can be summarized as:

```text
source component
  + source package version
  + scope
  + selected configuration
  + dependency assignment
  + optional Backpack instantiation
    => build unit
```

For ordinary libraries:

```text
definite library build unit
    => compiled library artefacts
    => definite installed unit
```

For indefinite Backpack libraries:

```text
indefinite library build unit
    => typechecked indefinite unit
    => indefinite installed unit
```

For executable-like components:

```text
executable build unit
    => executable artefact

test build unit
    => test executable artefact

benchmark build unit
    => benchmark executable artefact
```

For foreign libraries:

```text
foreign-library build unit
    => foreign-linkable library artefact
```
