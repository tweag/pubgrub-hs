# pubgrub

A native Haskell implementation of [PubGrub][], the version-solving algorithm
behind pub, Cargo's resolver and uv, written once over any domain.

- `PubGrub.Incompatibility.Domain` says what a variable, a value, a set of
  values and an external fact are.
- `PubGrub.Provider` is the one callback the solver reads the world through:
  given a variable and the set it is constrained to, commit to one value and
  state the incompatibilities that choice entails.
- `PubGrub.Solver.solve` resolves the seeds, or hands back the terminal
  incompatibility with its whole derivation.
- `PubGrub.Report` renders that derivation as the numbered proof the
  specification describes, in words a `Formatter` supplies.

To get started, follow the tutorial in the `PubGrub.Tutorial` module: it builds
a small domain, solves in it, and explains a failure.

The instantiation for cabal packages is the [`pubgrub-cabal`][cabal] package.
The algorithm follows pub's specification, which the repository vendors as the
authority.

[PubGrub]: https://github.com/dart-lang/pub/blob/master/doc/solver.md
[cabal]: https://hackage.haskell.org/package/pubgrub-cabal
