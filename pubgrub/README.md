# pubgrub

[PubGrub][] is a version-solving algorithm. Given a request and a way to read
what each version of each package needs, it finds a version for every package
the request needs, or proves that there is none, and the proof can be written
out for a person to read:

```
1. Because lib 1 depends on util 1 and util has no version 1, lib 1 is forbidden.

Because util has no version 2 and lib 2 depends on util 2, lib 2 is forbidden.
And because lib 1 is forbidden (1), lib 1 or 2 is forbidden.
So, because app 1 depends on lib 1 or 2 and app 1 is requested, version solving failed.
```

This package implements it in Haskell, once, for any domain: the things being
solved for need not be packages, and their values need not be versions. You
describe the domain with a type class, answer the solver's questions with a
callback, and choose the words its explanations use.

## Using it

Add `pubgrub` to your package's `build-depends`, and `import PubGrub`.

## Documentation

The documentation is in the package's modules:

- **[`PubGrub.Tutorial`][tutorial]** — start here. It builds a small domain,
  solves in it, breaks it, and explains the failure. The proof above is its
  output.
- **[`PubGrub.Cookbook`][cookbook]** — how-to guides: versions and ranges,
  requests and constraints, a provider over an index of releases, merging
  facts that say the same thing, explanations in your own words, watching the
  search, releasing a lock.
- **[`PubGrub`][front]** — how the solver sees a problem, and the reference
  for everything the library exports.

The domain of Haskell packages, over Cabal's package descriptions, is the
[`pubgrub-cabal`][cabal] package.

[PubGrub]: https://github.com/dart-lang/pub/blob/master/doc/solver.md
[tutorial]: https://hackage.haskell.org/package/pubgrub/docs/PubGrub-Tutorial.html
[cookbook]: https://hackage.haskell.org/package/pubgrub/docs/PubGrub-Cookbook.html
[front]: https://hackage.haskell.org/package/pubgrub/docs/PubGrub.html
[cabal]: https://hackage.haskell.org/package/pubgrub-cabal
