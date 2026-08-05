# `--with-compiler` Option Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `--with-compiler PATH` CLI option that drives both the boot-package set and the compiler version used for conditional `.cabal` flattening, falling back to `ghc` on `PATH` when absent.

**Architecture:** A new `app/Compiler.hs` module turns one GHC executable into a `Compiler` record (`CompilerInfo` + boot-package map) by shelling out to `<ghc> --print-libdir`, `<ghc> --numeric-version`, and the version-matched `<LIBDIR>/../bin/ghc-pkg`. `app/Main.hs` parses arguments with `optparse-applicative`, resolves the compiler once, and threads the `Compiler` into `withHackageProvider`, which stores it on `HackageProvider` in place of the old hardcoded constant and internal `ghc-pkg` call.

**Tech Stack:** Haskell (GHC2021), `optparse-applicative`, `process`, `filepath`, `Cabal`/`Cabal-syntax`, `co-log`, `tasty`/`tasty-hunit`.

## Global Constraints

- GHC2021, `cabal-version: 3.8`, `-Wall` on all components (the `warnings` common stanza).
- No partial functions (`head`, `fromJust`, etc.) — pattern-match or use `Maybe`/`Either`.
- Prefer `newtype` over type aliases for domain types.
- The version-matched `ghc-pkg` is derived as `takeDirectory libdir </> "bin" </> "ghc-pkg"` (i.e. `<LIBDIR>/../bin/ghc-pkg`).
- `thePlatform` stays hardcoded `Platform X86_64 Linux` — out of scope.
- Existing pure parser `PubGrub.Cabal.Boot.parseBootList` is reused unchanged.

---

### Task 1: Add `filepath` dependency and the pure `ghc-pkg` path helper

Introduces `app/Compiler.hs` with only the pure, unit-testable parts first: the libdir→ghc-pkg path derivation. Process glue comes in Task 2.

**Files:**
- Modify: `pubgrub-hs.cabal` (add `filepath` to the `executable pubgrub-hs` and `test-suite pubgrub-hs-test` `build-depends`; add `Compiler` to executable `other-modules`; add `CompilerSpec` to test `other-modules`)
- Create: `app/Compiler.hs`
- Test: `test/CompilerSpec.hs`
- Modify: `test/Main.hs` (wire in `CompilerSpec.tests`)

**Interfaces:**
- Produces: `ghcPkgFromLibdir :: FilePath -> FilePath` — given the output of `ghc --print-libdir`, returns the path to the version-matched `ghc-pkg`.

- [ ] **Step 1: Add `filepath` to the cabal file**

The pure helper lives in the `cabal-bridge` library (`app-lib/`), alongside
`PubGrub.Cabal.Boot` — matching the existing pattern where pure, testable
helpers are tested from the test suite (which already depends on
`pubgrub-hs:cabal-bridge`). This keeps the test target decoupled from the
executable's source tree.

In `pubgrub-hs.cabal`, under `library cabal-bridge` → `build-depends`, add a line:

```
        , filepath
```

Under `library cabal-bridge` → `exposed-modules`, add:

```
        PubGrub.Cabal.Compiler
```

Under `test-suite pubgrub-hs-test` → `other-modules`, add:

```
        CompilerSpec
```

(Do NOT modify the `executable pubgrub-hs` stanza or the test suite's
`hs-source-dirs` in this task — `app/Compiler.hs` and the `Compiler`
`other-module` are introduced in Task 2.)

- [ ] **Step 2: Write the failing test**

Create `test/CompilerSpec.hs`:

```haskell
module CompilerSpec (tests) where

import PubGrub.Cabal.Compiler (ghcPkgFromLibdir)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "Compiler"
        [ testCase "derives version-matched ghc-pkg from a ghcup libdir" $
            ghcPkgFromLibdir "/home/u/.ghcup/ghc/9.12.2/lib/ghc-9.12.2/lib"
                @?= "/home/u/.ghcup/ghc/9.12.2/lib/ghc-9.12.2/bin/ghc-pkg"
        , testCase "places ghc-pkg in a sibling bin of the libdir parent" $
            ghcPkgFromLibdir "/opt/ghc/lib/ghc-9.8.3/lib"
                @?= "/opt/ghc/lib/ghc-9.8.3/bin/ghc-pkg"
        ]
```

- [ ] **Step 3: Wire `CompilerSpec` into the test runner**

Open `test/Main.hs`, add `import qualified CompilerSpec` (matching the existing import style for `BootSpec`), and add `CompilerSpec.tests` to the top-level `testGroup` list alongside the other specs. (Read the file to match its exact style — it aggregates `VersionSetSpec`, `SolverSpec`, `FlattenSpec`, `BootSpec`.)

- [ ] **Step 4: Create `app-lib/PubGrub/Cabal/Compiler.hs` with the pure helper only**

```haskell
-- | Pure helpers for locating a GHC's tooling. The IO that runs these
-- (and assembles a full compiler description) lives in the @Compiler@
-- module of the executable.
module PubGrub.Cabal.Compiler
  ( ghcPkgFromLibdir,
  )
where

import System.FilePath (takeDirectory, (</>))

-- | Given the output of @ghc --print-libdir@, return the path to the
-- version-matched @ghc-pkg@ that sits at @<LIBDIR>/../bin/ghc-pkg@.
ghcPkgFromLibdir :: FilePath -> FilePath
ghcPkgFromLibdir libdir = takeDirectory libdir </> "bin" </> "ghc-pkg"
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cabal test pubgrub-hs-test 2>&1 | tail -20`
Expected: build succeeds, `Compiler` group passes (both cases), and the previously-passing specs still pass.

- [ ] **Step 6: Commit**

```bash
git add pubgrub-hs.cabal app-lib/PubGrub/Cabal/Compiler.hs test/CompilerSpec.hs test/Main.hs
git commit -m "feat: add PubGrub.Cabal.Compiler.ghcPkgFromLibdir + filepath dep"
```

---

### Task 2: Add `Compiler` type and `resolveCompiler` (process glue)

Adds the runtime side of `Compiler.hs`: the record, error type, and the function that shells out to GHC. This is IO glue over external processes; verified by manual run, not a unit test.

**Files:**
- Create: `app/Compiler.hs`
- Modify: `pubgrub-hs.cabal` (add `Compiler` to `executable pubgrub-hs` → `other-modules`)

**Interfaces:**
- Consumes: `PubGrub.Cabal.Compiler.ghcPkgFromLibdir :: FilePath -> FilePath` (Task 1, in the `cabal-bridge` library); `PubGrub.Cabal.Boot.parseBootList :: String -> Map PackageName Version`.
- Produces:
  - `data Compiler = Compiler { compilerInfo :: CompilerInfo, bootPackages :: Map PackageName Version }`
  - `newtype CompilerError = CompilerError Text` (instance `Exception`)
  - `resolveCompiler :: FilePath -> IO Compiler` — throws `CompilerError` on any process/parse failure.

Note: the executable already depends on `pubgrub-hs:cabal-bridge`, so no new
dependency is needed to import `PubGrub.Cabal.Compiler`. `filepath` is NOT
added to the executable — the path helper lives in `cabal-bridge`.

- [ ] **Step 1: Add `Compiler` to the executable's modules, then create the file header/imports**

In `pubgrub-hs.cabal`, under `executable pubgrub-hs` → `other-modules`, add `Compiler` (leave `BootPackages` in place — it is removed in Task 5):

```
        Compiler
```

Create `app/Compiler.hs` with this header, export list, and imports:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DerivingStrategies #-}

module Compiler
  ( Compiler (..),
    CompilerError (..),
    resolveCompiler,
  )
where

import Control.Exception (Exception, IOException, throwIO, try)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as T
import Distribution.Compiler
  ( AbiTag (NoAbiTag),
    CompilerFlavor (GHC),
    CompilerId (..),
    CompilerInfo,
    unknownCompilerInfo,
  )
import Distribution.Parsec (eitherParsec)
import Distribution.Types.PackageName (PackageName)
import Distribution.Version (Version)
import PubGrub.Cabal.Boot (parseBootList)
import PubGrub.Cabal.Compiler (ghcPkgFromLibdir)
import System.Process (readProcess)
```

- [ ] **Step 2: Add the `Compiler` record and `CompilerError`**

Append to `app/Compiler.hs`:

```haskell
-- | Everything the resolver needs to know about a specific GHC: the compiler
-- info used to evaluate @impl(ghc)@ conditionals, and the installed
-- boot-package versions (pinned during resolution).
data Compiler = Compiler
  { compilerInfo :: CompilerInfo,
    bootPackages :: Map PackageName Version
  }

-- | A GHC executable could not be queried (not found, not a GHC, or
-- unparseable output).
newtype CompilerError = CompilerError Text
  deriving stock (Show)

instance Exception CompilerError
```

(`DerivingStrategies` for the `deriving stock` was already added to the pragma block in Step 1.)

- [ ] **Step 3: Add a process helper that converts IO errors to `CompilerError`**

Append to `app/Compiler.hs`:

```haskell
-- | Run a GHC-family executable, converting a missing/failed process into a
-- 'CompilerError' instead of a raw 'IOException'.
runTool :: FilePath -> [String] -> IO String
runTool exe args = do
  result <- try (readProcess exe args "")
  case result of
    Right out -> pure out
    Left (e :: IOException) ->
      throwIO
        ( CompilerError
            ( "could not query compiler '"
                <> T.pack exe
                <> "': "
                <> T.pack (show e)
            )
        )
```

- [ ] **Step 4: Add `resolveCompiler`**

Append to `app/Compiler.hs`:

```haskell
-- | Resolve a GHC executable (a name on @PATH@ like @ghc@/@ghc-9.8.3@, or an
-- absolute path) into its 'Compiler': version-derived 'CompilerInfo' and the
-- boot-package set from the version-matched @ghc-pkg@.
resolveCompiler :: FilePath -> IO Compiler
resolveCompiler ghcExe = do
  libdir <- trim <$> runTool ghcExe ["--print-libdir"]
  verStr <- trim <$> runTool ghcExe ["--numeric-version"]
  version <- case eitherParsec verStr :: Either String Version of
    Right v -> pure v
    Left err ->
      throwIO
        ( CompilerError
            ( "could not parse version '"
                <> T.pack verStr
                <> "' from '"
                <> T.pack ghcExe
                <> "': "
                <> T.pack err
            )
        )
  let ghcPkg = ghcPkgFromLibdir libdir
  bootOut <- runTool ghcPkg ["list", "--global", "--simple-output"]
  pure
    Compiler
      { compilerInfo = unknownCompilerInfo (CompilerId GHC version) NoAbiTag,
        bootPackages = parseBootList bootOut
      }
  where
    trim = T.unpack . T.strip . T.pack
```

- [ ] **Step 5: Build to verify it compiles**

Run: `cabal build pubgrub-hs 2>&1 | tail -20`
Expected: compiles with no warnings (note `Main.hs` still references the old `queryBootPackages`/`getArgs` — that is fine until Task 3/4; `cabal build` of the executable may still fail there. If so, build just the module via `cabal build` after Task 4. To check Task 2 in isolation, run `cabal repl pubgrub-hs --repl-options=-fno-code` is not available; instead rely on Task 4's build). 

> Practical note: because `Main.hs` and `HackageProvider.hs` are part of the same `executable` target, the executable will not fully build until Tasks 3 and 4 land. Do Tasks 2–4 as a unit, committing after each, but expect the executable build to go green only at the end of Task 4. Step 5 here is just a syntax/type sanity check of the new code via your editor / HLS if available; otherwise proceed and rely on Task 4's build gate.

- [ ] **Step 6: Commit**

```bash
git add app/Compiler.hs pubgrub-hs.cabal
git commit -m "feat: add Compiler type and resolveCompiler process glue"
```

---

### Task 3: Thread `Compiler` through `HackageProvider`

Replaces the module-level `theCompiler` constant and the internal `queryBootPackages` call with the passed-in `Compiler`.

**Files:**
- Modify: `app/HackageProvider.hs`

**Interfaces:**
- Consumes: `Compiler (..)` from Task 2.
- Produces:
  - `HackageProvider` gains field `hpCompiler :: CompilerInfo` (in place of the removed `theCompiler` constant).
  - `withHackageProvider :: (MonadIO m, MonadUnliftIO m, WithLog env Text m) => Sec.Cache -> Manager -> Compiler -> PackageName -> VersionSet -> (HackageProvider -> m a) -> m a` (new `Compiler` parameter, inserted after `Manager`).

- [ ] **Step 1: Update imports**

In `app/HackageProvider.hs`, remove the now-unneeded `BootPackages` import and the `Distribution.Compiler` import block that only existed for `theCompiler`. Add:

```haskell
import Compiler (Compiler (..))
```

Remove:

```haskell
import BootPackages (queryBootPackages)
```

and the `Distribution.Compiler (..)` import block (lines importing `AbiTag`, `CompilerFlavor`, `CompilerId`, `CompilerInfo`, `unknownCompilerInfo`) — but keep `CompilerInfo` available, since `hpCompiler` needs it. Replace that block with a minimal:

```haskell
import Distribution.Compiler (CompilerInfo)
```

- [ ] **Step 2: Remove the `theCompiler` constant**

Delete these lines from `app/HackageProvider.hs`:

```haskell
theCompiler :: CompilerInfo
theCompiler = unknownCompilerInfo (CompilerId GHC (mkVersion [9, 12, 4])) NoAbiTag
```

(Keep `thePlatform`.)

If `mkVersion` is now unused, remove it from the `Distribution.Version` import list (leave `Version`).

- [ ] **Step 3: Add `hpCompiler` field to `HackageProvider`**

Modify the `data HackageProvider = HackageProvider { ... }` record to add a field:

```haskell
data HackageProvider = HackageProvider
  { hpVersions :: Map PackageName [Version],
    hpLookupCabal :: PackageIdentifier -> IO (Either ParseError GenericPackageDescription),
    hpBoot :: Map PackageName Version,
    hpCompiler :: CompilerInfo,
    hpTarget :: PackageName,
    hpRange :: VersionSet
  }
```

- [ ] **Step 4: Use `hpCompiler` in `getDependencies`**

In the `getDependencies` instance method, change the `flattenDeps` call from the constant to the field:

```haskell
            Right gpd -> pure (Map.mapKeys Pkg (flattenDeps thePlatform (hpCompiler hp) gpd))
```

- [ ] **Step 5: Add the `Compiler` parameter to `withHackageProvider`**

Update the type signature to insert `Compiler` after `Manager`:

```haskell
withHackageProvider ::
  (MonadIO m, MonadUnliftIO m, WithLog env Text m) =>
  Sec.Cache ->
  Manager ->
  Compiler ->
  PackageName ->
  VersionSet ->
  (HackageProvider -> m a) ->
  m a
withHackageProvider cache manager compiler target range act =
```

Inside the body, replace the boot-package query:

```haskell
          boot <- liftIO queryBootPackages
```

with using the passed-in compiler:

```haskell
          let boot = bootPackages compiler
```

and set the new field when constructing `hp`:

```haskell
          let hp =
                HackageProvider
                  { hpVersions = indexVersions,
                    hpLookupCabal = \pkgId -> do
                      bytes <- uncheckClientErrors $ indexLookupCabal indexCallbacks pkgId
                      return $ parseGPD (trusted bytes),
                    hpBoot = boot,
                    hpCompiler = compilerInfo compiler,
                    hpTarget = target,
                    hpRange = range
                  }
```

- [ ] **Step 6: Commit (build gate deferred to Task 4)**

The executable will not build until `Main.hs` is updated (Task 4) because `withHackageProvider`'s arity changed. Commit the consistent change now:

```bash
git add app/HackageProvider.hs
git commit -m "refactor: thread Compiler through HackageProvider"
```

---

### Task 4: optparse-applicative argument parsing in `Main.hs`

Replaces the ad-hoc `getArgs` + `parseTarget` with an `optparse-applicative` parser, resolves the compiler, and passes it to `withHackageProvider`. This task makes the executable build green again.

**Files:**
- Modify: `app/Main.hs`

**Interfaces:**
- Consumes: `Compiler.resolveCompiler`, `Compiler.CompilerError (..)`; `withHackageProvider` with its new `Compiler` parameter (Task 3).
- Produces: the final CLI. No downstream consumers.

- [ ] **Step 1: Update imports in `app/Main.hs`**

Remove `import System.Environment (getArgs)`. Add:

```haskell
import Compiler (CompilerError (..), resolveCompiler)
import Control.Exception (try)
import Data.Maybe (fromMaybe)
import Options.Applicative
  ( Parser,
    ParserInfo,
    eitherReader,
    execParser,
    fullDesc,
    help,
    helper,
    info,
    long,
    metavar,
    optional,
    argument,
    progDesc,
    str,
    strOption,
    (<**>),
  )
```

(Keep existing imports for `eitherParsec`, `mkPackageName`, `PackageIdentifier`, `VersionRange`, `versionNumbers`, `VS`. `PackageName` is already imported via `Distribution.PackageDescription` — do **not** add a second import for it.)

- [ ] **Step 2: Define the `Options` type and pure arg readers**

Add near the top of `app/Main.hs`:

```haskell
data Options = Options
  { optWithCompiler :: Maybe FilePath,
    optTarget :: (PackageName, VS.VersionSet),
    optRange :: Maybe VS.VersionSet
  }

-- | Parse a @<package>[-<version>]@ argument. A bare name means any version;
-- @name-version@ means @== version@.
readTarget :: String -> Either String (PackageName, VS.VersionSet)
readTarget s =
  case eitherParsec s :: Either String PackageIdentifier of
    Right (PackageIdentifier n v)
      | null (versionNumbers v) -> Right (n, VS.full)
      | otherwise -> Right (n, VS.singleton v)
    Left _ -> Right (mkPackageName s, VS.full)

-- | Parse a Cabal version-range argument.
readRange :: String -> Either String VS.VersionSet
readRange s =
  case eitherParsec s :: Either String VersionRange of
    Right vr -> Right (VS.fromVersionRange vr)
    Left err -> Left ("invalid version range: " <> err)
```

- [ ] **Step 3: Define the parser and `ParserInfo`**

Add:

```haskell
optionsParser :: Parser Options
optionsParser =
  Options
    <$> optional
      ( strOption
          ( long "with-compiler"
              <> metavar "PATH"
              <> help "GHC executable to use for boot packages and impl(ghc) conditionals (default: ghc on PATH)"
          )
      )
    <*> argument (eitherReader readTarget) (metavar "TARGET")
    <*> optional (argument (eitherReader readRange) (metavar "[VERSION-RANGE]"))

optionsInfo :: ParserInfo Options
optionsInfo =
  info
    (optionsParser <**> helper)
    (fullDesc <> progDesc "Resolve a Hackage package's dependency closure with PubGrub")
```

(`str` may be unused; drop it from the import list if so to satisfy `-Wall`.)

- [ ] **Step 4: Rewrite `main`**

Replace the body of `main` (from `args <- getArgs` onward, and delete the old `parseTarget` function entirely) with:

```haskell
main :: IO ()
main = do
  cache <- mkCache <$> makeAbsolute (fromFilePath "_cache")
  opts <- execParser optionsInfo

  usingLoggerT logTextStdout $ do
    manager <- liftIO $ newManager defaultManagerSettings
    ecompiler <- liftIO (try (resolveCompiler (fromMaybe "ghc" (optWithCompiler opts))))
    case ecompiler of
      Left (CompilerError msg) -> logMsg ("error: " <> msg)
      Right compiler -> do
        let (target, targetRange) = optTarget opts
            range = fromMaybe targetRange (optRange opts)
        withHackageProvider cache manager compiler target range $ \hp -> do
          idx <- liftIO $ getCachedIndex cache Sec.FGz
          case idx of
            Nothing -> logMsg @Text "error: cached index not found after update"
            Just idxPath -> do
              idxTime <- liftIO (getModificationTime idxPath)

              logMsg @Text
                ( "\ESC[1mSolving for "
                    <> T.pack (prettyShow target)
                    <> " "
                    <> T.pack (prettyShow (VS.toVersionRange range))
                    <> " (index from "
                    <> T.pack (formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC" idxTime)
                    <> ")\ESC[0m"
                )

              runSolve hp
```

Delete the old `parseTarget :: [String] -> Maybe (PackageName, VS.VersionSet)` function and its doc comment.

- [ ] **Step 5: Build and verify the executable compiles cleanly**

Run: `cabal build 2>&1 | tail -30`
Expected: all components build with no `-Wall` warnings.

- [ ] **Step 6: Run the test suite**

Run: `cabal test 2>&1 | tail -20`
Expected: all specs pass (including `Compiler` from Task 1).

- [ ] **Step 7: Commit**

```bash
git add app/Main.hs
git commit -m "feat: parse args with optparse-applicative; add --with-compiler"
```

---

### Task 5: Remove the obsolete `BootPackages` module

`Compiler` now owns boot-package resolution. Remove the dead module.

**Files:**
- Delete: `app/BootPackages.hs`
- Modify: `pubgrub-hs.cabal` (remove `BootPackages` from executable `other-modules`)

**Interfaces:**
- Consumes: nothing (verifying no remaining references).
- Produces: nothing.

- [ ] **Step 1: Confirm there are no remaining references**

Run: `rg -n "BootPackages|queryBootPackages" --glob '*.hs' --glob '*.cabal'`
Expected: the only hits are the module's own definition and its `other-modules` entry. If any other file imports it, stop and reconcile.

- [ ] **Step 2: Delete the module and its cabal entry**

```bash
git rm app/BootPackages.hs
```

In `pubgrub-hs.cabal`, remove the `BootPackages` line from `executable pubgrub-hs` → `other-modules`.

- [ ] **Step 3: Build and test**

Run: `cabal build 2>&1 | tail -20 && cabal test 2>&1 | tail -20`
Expected: clean build, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add pubgrub-hs.cabal
git commit -m "refactor: remove BootPackages, subsumed by Compiler"
```

---

### Task 6: Manual end-to-end verification

The process glue (`resolveCompiler`) has no automated test; verify behavior against a real GHC.

**Files:** none.

- [ ] **Step 1: Default (PATH) compiler still works**

Run: `cabal run pubgrub-hs -- containers`
Expected: solves and prints a resolved plan, the same as before this change (boot packages from the `ghc` on `PATH`).

- [ ] **Step 2: Explicit `--with-compiler` matching PATH**

Run: `cabal run pubgrub-hs -- --with-compiler ghc containers`
Expected: identical result to Step 1.

- [ ] **Step 3: Bad compiler path produces a clean error**

Run: `cabal run pubgrub-hs -- --with-compiler ghc-does-not-exist containers`
Expected: a single `error: could not query compiler 'ghc-does-not-exist': ...` line, no Haskell exception/backtrace.

- [ ] **Step 4: `--help` lists the option**

Run: `cabal run pubgrub-hs -- --help`
Expected: usage text shows `--with-compiler PATH` and the `TARGET`/`[VERSION-RANGE]` positionals.

- [ ] **Step 5: (If a second GHC is installed) version drives boot set**

If another GHC is available on `PATH` (e.g. `ghc-9.8.x`), run the resolver with `--with-compiler ghc-9.8.x` against a target whose closure includes a boot package (e.g. `text`) and confirm the pinned boot version differs from the default compiler's. If only one GHC is installed, note this step as skipped.
