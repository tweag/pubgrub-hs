# `--with-compiler` option design

**Date:** 2026-06-18

## Problem

The compiler is hardcoded in two independent places, and they can disagree:

1. **Boot packages** — `BootPackages.queryBootPackages` runs `ghc-pkg list --global
   --simple-output` against whatever `ghc-pkg` is on `PATH`. These versions are
   pinned during resolution (a boot package is forced to its installed version and
   contributes no dependencies).
2. **Conditional flattening** — `HackageProvider.theCompiler` is a module-level
   constant (`GHC 9.12.4`) used by `flattenDeps` to evaluate `impl(ghc >= …)`
   conditionals in `.cabal` files.

There is no way to resolve against a chosen compiler, and the two sources can
reflect different GHC versions.

## Goal

Add a `--with-compiler PATH` option naming a GHC executable (e.g. `ghc-9.8.3`, or
an absolute path). It drives **both** the boot-package set and the compiler version
used for conditional flattening, keeping resolution self-consistent. When the
option is absent, fall back to `ghc` on `PATH` (non-breaking).

## Design

### New module `app/Compiler.hs`

Subsumes `app/BootPackages.hs`. Turns a GHC executable into everything the resolver
needs to know about that compiler:

```haskell
data Compiler = Compiler
  { compilerInfo :: CompilerInfo            -- for impl(ghc) conditionals
  , bootPackages :: Map PackageName Version -- pre-installed version pins
  }

-- | ghcExe is "ghc" (PATH default), "ghc-9.8.3", or an absolute path.
resolveCompiler :: FilePath -> IO Compiler
```

`resolveCompiler ghcExe` performs three process invocations:

1. `<ghcExe> --print-libdir` → `LIBDIR`.
2. `<ghcExe> --numeric-version` → trimmed, parsed to a `Version` via
   `eitherParsec`; built into `CompilerInfo` with
   `unknownCompilerInfo (CompilerId GHC v) NoAbiTag`.
3. `<LIBDIR>/../bin/ghc-pkg list --global --simple-output` → parsed by the
   existing `PubGrub.Cabal.Boot.parseBootList`.

The `ghc-pkg` sibling of the libdir is the version-matched one, so boot packages
and the compiler version always come from the same GHC.

> Note: an earlier sketch used `<LIBDIR>/../ghc-pkg`; the actual ghcup layout is
> `<LIBDIR>/../bin/ghc-pkg` (verified: `--print-libdir` →
> `…/ghc-9.12.2/lib/ghc-9.12.2/lib`, with `bin/ghc-pkg` one level up). The path is
> derived as `takeDirectory libdir </> "bin" </> "ghc-pkg"` (i.e. `<LIBDIR>/../bin/ghc-pkg`).

The pure parser `parseBootList` stays in the `cabal-bridge` library
(`app-lib/PubGrub/Cabal/Boot.hs`) and keeps its existing test coverage.

### `app/Main.hs` — argument parsing via optparse-applicative

`optparse-applicative` is already a declared dependency but currently unused. The
ad-hoc `getArgs` + `parseTarget` scheme is fully replaced by an
`optparse-applicative` parser:

- `--with-compiler PATH` → `Maybe FilePath` (default `Nothing`).
- positional `TARGET` — `<package>[-<version>]`, preserving today's semantics
  (bare name = any version; `name-version` = `== version`).
- optional positional `[VERSION-RANGE]`, preserving today's semantics.

The existing target/range parsing logic (the body of `parseTarget`) is reused
inside `ReadM`/`Parser` combinators rather than reimplemented. `main` resolves the
compiler once at startup:

```haskell
compiler <- liftIO (resolveCompiler (fromMaybe "ghc" mWithCompiler))
```

and threads the resulting `Compiler` into `withHackageProvider`.

### `app/HackageProvider.hs`

- Remove the module-level `theCompiler` constant.
- Add a field `hpCompiler :: CompilerInfo` to `HackageProvider`.
- `withHackageProvider` gains a `Compiler` parameter. Its body uses
  `bootPackages compiler` for `hpBoot` (replacing the internal
  `queryBootPackages` call) and `compilerInfo compiler` for `hpCompiler`.
- `getDependencies` passes `hpCompiler hp` to `flattenDeps` instead of the
  constant.
- `thePlatform` (`X86_64 Linux`) stays hardcoded — deriving the platform is out
  of scope.

### Error handling

`resolveCompiler` wraps its process calls so a missing or non-GHC executable
produces a clear message — `"could not query compiler '<path>': <reason>"` —
rather than a raw `IOException`. Surfaced via the existing logging / a clean exit
in `main`.

### Removed

- `app/BootPackages.hs` and its `other-modules` entry (subsumed by `Compiler`).

## Out of scope

- Platform selection (`thePlatform` stays Linux/x86_64).
- ABI tag / flavour beyond `unknownCompilerInfo`.
- Validating that the chosen compiler's boot packages are internally consistent.

## Testing

- The pure `parseBootList` retains its existing unit tests.
- `resolveCompiler` is thin IO glue over external processes; covered manually by
  running `cabal run pubgrub-hs -- --with-compiler ghc <target>` and confirming the
  boot set and `impl(ghc)` evaluation reflect the chosen GHC. (No new automated
  test for the process glue unless a seam is introduced later.)
