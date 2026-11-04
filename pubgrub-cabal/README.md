# pubgrub-cabal

The cabal domain for the [`pubgrub`][pubgrub] solver: a package name or one of
its automatic flags is a variable, an installed unit or a source release is a
value, a dependency's declared range is one symbolic set of instances, and the
leaves of every proof are what the request asks for, what a `.cabal` file states,
and what the compiler and the machine rule out.

- `PubGrub.Cabal` is the variables and the facts; `PubGrub.Cabal.Value` and
  `PubGrub.Cabal.InstanceSet` are the values and their sets.
- `PubGrub.Cabal.Flatten` reads a `GenericPackageDescription` into the solver's
  input, with the machine passed in as plain data.
- `PubGrub.Cabal.Installed` is the installed package set and its unit graph.
- `PubGrub.Cabal.Provider.mkExpand` is the rule that picks an instance of a
  package and states what it entails, over a `ReleaseSource` the caller
  supplies. `releaseOf` reduces a `GenericPackageDescription` to the `Release`
  a source reads.
- `PubGrub.Cabal.Report` prints a failed resolution as a proof in cabal's
  range syntax.

Of the cabal ecosystem it depends on `Cabal-syntax` only. The Hackage index,
the compiler and the installed database are the caller's to supply.

[pubgrub]: https://hackage.haskell.org/package/pubgrub
