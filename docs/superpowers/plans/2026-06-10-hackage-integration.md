# Hackage Index Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `cabal run pubgrub-hs -- <package> [version-range]` resolve a real Hackage package's dependency closure with the native PubGrub solver, over the bootstrapped index.

**Architecture:** Generalize the verified solver to run in any monad `m`; add a pure `cabal-bridge` sub-library that flattens a `GenericPackageDescription` to a dependency set and parses GHC's boot-package list; add an `IO` `DependencyProvider` in the executable that pulls versions/dependencies lazily from the Hackage index and pins boot packages.

**Tech Stack:** GHC 9.12.4; `Cabal`/`Cabal-syntax` (finalizePD, version ranges), `process` (ghc-pkg), `hackage-security` (index); tasty test-suite.

---

## Reference: confirmed Cabal APIs (probed against installed Cabal-3.14.2.0)

- `finalizePD :: FlagAssignment -> ComponentRequestedSpec -> (Dependency -> Bool) -> Platform -> CompilerInfo -> [PackageVersionConstraint] -> GenericPackageDescription -> Either [Dependency] (PackageDescription, FlagAssignment)`
- `defaultComponentRequestedSpec :: ComponentRequestedSpec` (tests/benchmarks off)
- `library :: PackageDescription -> Maybe Library`; `libBuildInfo :: Library -> BuildInfo`; `targetBuildDepends :: BuildInfo -> [Dependency]`
- `depPkgName :: Dependency -> PackageName`; `depVerRange :: Dependency -> VersionRange`
- `mkFlagAssignment :: [(FlagName, Bool)] -> FlagAssignment` (use `mkFlagAssignment []` for defaults)
- `Platform X86_64 Linux`; `unknownCompilerInfo (CompilerId GHC (mkVersion [9,12,4])) NoAbiTag`
- `eitherParsec :: String -> Either String VersionRange` (from `Distribution.Parsec`)

## Environment / verification note

`Cabal`, `Cabal-syntax`, `process`, and `tasty` are all available offline, so **Tasks 1–4 are fully verifiable in-sandbox** with `cabal test`. The executable (Tasks 5–6) depends on `hackage-security`/`http-client`/`co-log`/`lmdb-simple` (NOT installed; need hackage) and the live index, so it is built and run **on the user's machine**. For executable modules, the agent does a best-effort standalone `ghc -fno-code` typecheck only where the imports are boot-lib-only (noted per task).

---

## File Structure

| File | Responsibility |
|------|----------------|
| `src/PubGrub/Solver.hs` | MODIFIED: `DependencyProvider` + `solve` generalized to monad `m` |
| `test/SolverSpec.hs` | MODIFIED: in-memory provider at `Identity` |
| `pubgrub-hs.cabal` | MODIFIED: new `cabal-bridge` sub-library; exe/test deps |
| `app-lib/PubGrub/Cabal/Flatten.hs` | NEW: pure `flattenDeps` |
| `app-lib/PubGrub/Cabal/Boot.hs` | NEW: pure `parseBootList` |
| `test/FlattenSpec.hs` | NEW: flattening unit tests |
| `test/BootSpec.hs` | NEW: boot-list parser unit tests |
| `app/BootPackages.hs` | NEW: `queryBootPackages` (IO `ghc-pkg` wrapper) |
| `app/HackageProvider.hs` | NEW: `Pkg` type + `IO` `DependencyProvider` + index version map |
| `app/Solver.hs` | REWRITE: build provider, run solve, render result |
| `app/Main.hs` | MODIFIED: CLI parsing + dispatch |

---

## Task 1: Generalize the solver to a monad

**Files:**
- Modify: `src/PubGrub/Solver.hs`
- Modify: `test/SolverSpec.hs`

- [ ] **Step 1: Change the `DependencyProvider` class to take a monad parameter**

In `src/PubGrub/Solver.hs`, replace the class definition:

```haskell
-- | The oracle: pick a version in a range and report a version's dependencies.
class Package p => DependencyProvider dp p | dp -> p where
  chooseVersion   :: dp -> p -> VersionSet -> Maybe Version
  getDependencies :: dp -> p -> Version -> Map p VersionSet
```

with:

```haskell
-- | The oracle: pick a version in a range and report a version's dependencies.
-- Effects (e.g. lazy index loading) run in the monad @m@.
class (Package p, Monad m) => DependencyProvider dp p m | dp -> p where
  chooseVersion   :: dp -> p -> VersionSet -> m (Maybe Version)
  getDependencies :: dp -> p -> Version -> m (Map p VersionSet)
```

- [ ] **Step 2: Make `solve` monadic**

In `src/PubGrub/Solver.hs`, replace the entire `solve` definition (the `newtype SolveError` stays unchanged) with:

```haskell
-- | Solve for a root package pinned to @rootV@. Returns a complete assignment
-- or a 'SolveError'. Mirrors the main loop in the Rust reference / intro §6.
solve
  :: DependencyProvider dp p m
  => dp -> p -> Version
  -> m (Either (SolveError p) (Map p Version))
solve dp rootPkg rootV = go [notRoot rootPkg rootV] emptyPS
  where
    go incompats ps =
      case unitPropagation rootPkg rootV incompats ps of
        Left terminal -> pure (Left (NoSolution terminal))
        Right (incompats', ps') ->
          case undecidedPositive ps' of
            [] -> pure (Right (extractSolution ps'))
            ((p, range) : _) -> do
              mv <- chooseVersion dp p range
              case mv of
                Nothing ->
                  -- No version available in the allowed range: ban it and let
                  -- the next propagation turn it into a conflict.
                  go (noVersions p range : incompats') ps'
                Just v -> do
                  deps <- getDependencies dp p v
                  let depIncs =
                        [ fromDependency p (VS.singleton v) (q, r)
                        | (q, r) <- Map.toList deps ]
                  go (depIncs ++ incompats') (addDecision p v ps')
```

- [ ] **Step 3: Update the in-memory test provider to `Identity`**

In `test/SolverSpec.hs`, add the import (after the existing imports):

```haskell
import Data.Functor.Identity (Identity, runIdentity)
```

Replace the instance head and both method bodies:

```haskell
instance DependencyProvider Registry String where
  chooseVersion (Registry regMap) p range =
    let vs = maybe [] Map.keys (Map.lookup p regMap)
    in listToMaybe (sortBy (comparing Down) (filter (VS.contains range) vs))
  getDependencies (Registry regMap) p ver =
    Map.findWithDefault Map.empty ver (Map.findWithDefault Map.empty p regMap)
```

with:

```haskell
instance DependencyProvider Registry String Identity where
  chooseVersion (Registry regMap) p range =
    let vs = maybe [] Map.keys (Map.lookup p regMap)
    in pure (listToMaybe (sortBy (comparing Down) (filter (VS.contains range) vs)))
  getDependencies (Registry regMap) p ver =
    pure (Map.findWithDefault Map.empty ver (Map.findWithDefault Map.empty p regMap))
```

- [ ] **Step 4: Update the four `solve` call sites in the scenario tests**

In `test/SolverSpec.hs`, every `solve r "root" (v [1])` becomes `runIdentity (solve r "root" (v [1]))`. There are exactly four (trivial, transitive, backtracking, and the two unsat cases — note "no valid version" and "unsat text" each have one). Concretely, change each occurrence of:

```haskell
      in solve r "root" (v [1])
```
to
```haskell
      in runIdentity (solve r "root" (v [1]))
```
and each occurrence of:
```haskell
      in case solve r "root" (v [1]) of
```
to
```haskell
      in case runIdentity (solve r "root" (v [1])) of
```

(The "rule of resolution" test does not call `solve` and is unchanged.)

- [ ] **Step 5: Verify offline typecheck of the library**

Run: `ghc -fno-code -Wall -isrc -package Cabal-syntax -XGHC2021 src/PubGrub.hs`
Expected: compiles, no errors, no warnings.

- [ ] **Step 6: Run the full test suite (this works offline — tasty is cached)**

Run: `cabal test --test-show-details=direct`
Expected: all 18 tests PASS (behavioral equivalence — only the monad wrapper changed).

- [ ] **Step 7: Commit**

```bash
git add src/PubGrub/Solver.hs test/SolverSpec.hs
git commit -m "refactor: generalize DependencyProvider and solve to a monad"
```

---

## Task 2: Cabal stanzas for the cabal-bridge sub-library

**Files:**
- Modify: `pubgrub-hs.cabal`
- Create: `app-lib/PubGrub/Cabal/Flatten.hs` (placeholder)
- Create: `app-lib/PubGrub/Cabal/Boot.hs` (placeholder)

- [ ] **Step 1: Add the `cabal-bridge` internal library stanza**

Insert after the main `library` stanza in `pubgrub-hs.cabal` (before `executable pubgrub-hs`):

```cabal
library cabal-bridge
    import:           warnings
    exposed-modules:
        PubGrub.Cabal.Flatten
        PubGrub.Cabal.Boot
    build-depends:
        , base
        , containers
        , Cabal
        , Cabal-syntax
        , pubgrub-hs
    hs-source-dirs:   app-lib
    default-language: GHC2021
```

- [ ] **Step 2: Add deps to the executable**

In the `executable pubgrub-hs` stanza `build-depends`, add these lines:

```cabal
        , pubgrub-hs:cabal-bridge
        , process
```

(`pubgrub-hs`, `Cabal`, `Cabal-syntax`, `containers` are already present.) Also add to the executable's `other-modules`:

```cabal
        HackageProvider
        BootPackages
```

- [ ] **Step 3: Add deps + modules to the test-suite**

In the `test-suite pubgrub-hs-test` stanza, add to `build-depends`:

```cabal
        , pubgrub-hs:cabal-bridge
        , bytestring
```

and to `other-modules`:

```cabal
        FlattenSpec
        BootSpec
```

- [ ] **Step 4: Create placeholder modules so the package configures**

`app-lib/PubGrub/Cabal/Flatten.hs`:
```haskell
module PubGrub.Cabal.Flatten () where
```

`app-lib/PubGrub/Cabal/Boot.hs`:
```haskell
module PubGrub.Cabal.Boot () where
```

- [ ] **Step 5: Verify the cabal-bridge library builds (offline — Cabal is a boot lib)**

Run: `cabal build cabal-bridge 2>&1 | tail -5`
Expected: configures and compiles the (empty) modules with no errors.

- [ ] **Step 6: Commit**

```bash
git add pubgrub-hs.cabal app-lib/
git commit -m "chore: add cabal-bridge internal library scaffolding"
```

---

## Task 3: Dependency flattening

**Files:**
- Modify: `app-lib/PubGrub/Cabal/Flatten.hs`
- Create: `test/FlattenSpec.hs`
- Modify: `test/Main.hs`

- [ ] **Step 1: Write the flattening module**

Replace `app-lib/PubGrub/Cabal/Flatten.hs` with:

```haskell
-- | Flatten a GenericPackageDescription's main-library dependencies into a
-- concrete version-set map, resolving conditionals at default flag values for
-- a fixed platform and compiler. Flag *solving* is out of scope.
module PubGrub.Cabal.Flatten
  ( flattenDeps
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Distribution.Compiler (CompilerInfo)
import Distribution.PackageDescription.Configuration (finalizePD)
import Distribution.System (Platform)
import Distribution.Types.BuildInfo (targetBuildDepends)
import Distribution.Types.ComponentRequestedSpec (defaultComponentRequestedSpec)
import Distribution.Types.Dependency (depPkgName, depVerRange)
import Distribution.Types.Flag (mkFlagAssignment)
import Distribution.Types.GenericPackageDescription (GenericPackageDescription)
import Distribution.Types.Library (libBuildInfo)
import Distribution.Types.PackageDescription (library)
import Distribution.Types.PackageName (PackageName)

import qualified PubGrub.VersionSet as VS
import PubGrub.VersionSet (VersionSet)

-- | Main-library dependencies of a package version, as a version-set map.
-- Returns the empty map if the package has no library or finalization fails.
flattenDeps :: Platform -> CompilerInfo -> GenericPackageDescription -> Map PackageName VersionSet
flattenDeps platform compiler gpd =
  case finalizePD (mkFlagAssignment []) defaultComponentRequestedSpec
                  (const True) platform compiler [] gpd of
    Left _missing      -> Map.empty
    Right (pd, _flags) ->
      case library pd of
        Nothing  -> Map.empty
        Just lib -> Map.fromListWith VS.intersection
          [ (depPkgName d, VS.fromVersionRange (depVerRange d))
          | d <- targetBuildDepends (libBuildInfo lib) ]
```

- [ ] **Step 2: Write the flattening tests**

Create `test/FlattenSpec.hs`:

```haskell
module FlattenSpec (tests) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.Map.Strict as Map

import Distribution.Compiler (AbiTag (..), CompilerFlavor (..), CompilerId (..), CompilerInfo, unknownCompilerInfo)
import Distribution.PackageDescription.Parsec (parseGenericPackageDescription, runParseResult)
import Distribution.System (Arch (..), OS (..), Platform (..))
import Distribution.Types.GenericPackageDescription (GenericPackageDescription)
import Distribution.Types.PackageName (mkPackageName)
import Distribution.Version (mkVersion)

import PubGrub.Cabal.Flatten (flattenDeps)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

plat :: Platform
plat = Platform X86_64 Linux

comp :: CompilerInfo
comp = unknownCompilerInfo (CompilerId GHC (mkVersion [9, 12, 4])) NoAbiTag

parseGPD :: String -> GenericPackageDescription
parseGPD s = case snd (runParseResult (parseGenericPackageDescription (BS.pack s))) of
  Right gpd -> gpd
  Left err  -> error ("parse failed: " ++ show err)

tests :: TestTree
tests = testGroup "Flatten"
  [ testCase "main library build-depends are extracted" $
      let gpd = parseGPD (unlines
            [ "cabal-version: 2.4"
            , "name: demo"
            , "version: 1.0"
            , "library"
            , "  build-depends: base >=4 && <5, containers"
            , "  default-language: Haskell2010"
            ])
      in Map.keys (flattenDeps plat comp gpd)
           @?= [mkPackageName "base", mkPackageName "containers"]

  , testCase "conditional dep behind a default-false flag is excluded" $
      let gpd = parseGPD (unlines
            [ "cabal-version: 2.4"
            , "name: demo"
            , "version: 1.0"
            , "flag fast"
            , "  default: False"
            , "  manual: True"
            , "library"
            , "  build-depends: base"
            , "  if flag(fast)"
            , "    build-depends: vector"
            , "  default-language: Haskell2010"
            ])
      in Map.member (mkPackageName "vector") (flattenDeps plat comp gpd) @?= False

  , testCase "package with no library yields no deps" $
      let gpd = parseGPD (unlines
            [ "cabal-version: 2.4"
            , "name: demo"
            , "version: 1.0"
            , "executable foo"
            , "  main-is: Main.hs"
            , "  build-depends: base"
            , "  default-language: Haskell2010"
            ])
      in flattenDeps plat comp gpd @?= Map.empty
  ]
```

- [ ] **Step 3: Wire FlattenSpec into the test tree**

In `test/Main.hs`, add `import qualified FlattenSpec` and add `FlattenSpec.tests` to the `testGroup "pubgrub-hs"` list:

```haskell
module Main (main) where

import Test.Tasty (defaultMain, testGroup)
import qualified VersionSetSpec
import qualified SolverSpec
import qualified FlattenSpec

main :: IO ()
main = defaultMain $ testGroup "pubgrub-hs"
  [ VersionSetSpec.tests
  , SolverSpec.tests
  , FlattenSpec.tests
  ]
```

- [ ] **Step 4: Run the tests (offline — Cabal + tasty available)**

Run: `cabal test --test-show-details=direct 2>&1 | tail -30`
Expected: the three `Flatten` cases PASS alongside the existing suite.

- [ ] **Step 5: Commit**

```bash
git add app-lib/PubGrub/Cabal/Flatten.hs test/FlattenSpec.hs test/Main.hs
git commit -m "feat: flatten GenericPackageDescription to dependency set"
```

---

## Task 4: Boot-package list parser

**Files:**
- Modify: `app-lib/PubGrub/Cabal/Boot.hs`
- Create: `test/BootSpec.hs`
- Modify: `test/Main.hs`

- [ ] **Step 1: Write the pure boot-list parser**

Replace `app-lib/PubGrub/Cabal/Boot.hs` with:

```haskell
-- | Parse the output of @ghc-pkg list --global --simple-output@ into a map of
-- pinned boot-package versions.
module PubGrub.Cabal.Boot
  ( parseBootList
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Text.Read (readMaybe)

import Distribution.Types.PackageName (PackageName, mkPackageName)
import Distribution.Version (Version, mkVersion)

-- | Parse whitespace-separated @name-version@ tokens.
parseBootList :: String -> Map PackageName Version
parseBootList = Map.fromList . mapMaybe parseToken . words

-- | Split a @name-1.2.3@ token: the version is the final hyphen-segment that
-- parses as a dotted integer version; the rest (rejoined with @-@) is the name.
parseToken :: String -> Maybe (PackageName, Version)
parseToken tok =
  case reverse (splitOn '-' tok) of
    (vstr : nameSegsRev)
      | not (null nameSegsRev)
      , Just ver <- parseVersion vstr ->
          Just (mkPackageName (intercalateHyphen (reverse nameSegsRev)), ver)
    _ -> Nothing

parseVersion :: String -> Maybe Version
parseVersion s =
  case traverse (readMaybe :: String -> Maybe Int) (splitOn '.' s) of
    Just ns@(_ : _) -> Just (mkVersion ns)
    _               -> Nothing

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (a, [])        -> [a]
  (a, _ : rest)  -> a : splitOn c rest

intercalateHyphen :: [String] -> String
intercalateHyphen []       = ""
intercalateHyphen [x]      = x
intercalateHyphen (x : xs) = x ++ "-" ++ intercalateHyphen xs
```

- [ ] **Step 2: Write the parser tests**

Create `test/BootSpec.hs`:

```haskell
module BootSpec (tests) where

import qualified Data.Map.Strict as Map

import Distribution.Types.PackageName (mkPackageName)
import Distribution.Version (mkVersion)

import PubGrub.Cabal.Boot (parseBootList)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests = testGroup "Boot"
  [ testCase "parses simple name-version tokens" $
      parseBootList "base-4.21.0.0 containers-0.7"
        @?= Map.fromList
              [ (mkPackageName "base", mkVersion [4, 21, 0, 0])
              , (mkPackageName "containers", mkVersion [0, 7])
              ]

  , testCase "handles hyphenated package names" $
      parseBootList "Cabal-syntax-3.14.2.0"
        @?= Map.fromList [(mkPackageName "Cabal-syntax", mkVersion [3, 14, 2, 0])]

  , testCase "ignores tokens without a parseable version" $
      parseBootList "rts notaversion-foo base-4.21.0.0"
        @?= Map.fromList [(mkPackageName "base", mkVersion [4, 21, 0, 0])]
  ]
```

- [ ] **Step 3: Wire BootSpec into the test tree**

In `test/Main.hs`, add `import qualified BootSpec` and add `BootSpec.tests` to the list:

```haskell
module Main (main) where

import Test.Tasty (defaultMain, testGroup)
import qualified VersionSetSpec
import qualified SolverSpec
import qualified FlattenSpec
import qualified BootSpec

main :: IO ()
main = defaultMain $ testGroup "pubgrub-hs"
  [ VersionSetSpec.tests
  , SolverSpec.tests
  , FlattenSpec.tests
  , BootSpec.tests
  ]
```

- [ ] **Step 4: Run the tests (offline)**

Run: `cabal test --test-show-details=direct 2>&1 | tail -20`
Expected: the three `Boot` cases PASS alongside the rest.

- [ ] **Step 5: Commit**

```bash
git add app-lib/PubGrub/Cabal/Boot.hs test/BootSpec.hs test/Main.hs
git commit -m "feat: parse ghc-pkg boot-package list"
```

---

## Task 5: Hackage IO DependencyProvider

**Files:**
- Create: `app/HackageProvider.hs`
- Create: `app/BootPackages.hs`

> Verification note: these modules import `hackage-security`/`Database` (not available in the agent sandbox), so they are built by the user via `cabal build`. `BootPackages` imports only boot libs + `cabal-bridge`, so the agent can standalone-typecheck it (Step 3).

- [ ] **Step 1: Write the boot-package IO wrapper**

Create `app/BootPackages.hs`:

```haskell
module BootPackages
  ( queryBootPackages
  ) where

import Data.Map.Strict (Map)
import System.Process (readProcess)

import Distribution.Types.PackageName (PackageName)
import Distribution.Version (Version)

import PubGrub.Cabal.Boot (parseBootList)

-- | Query the installed GHC global package db for boot-package versions.
queryBootPackages :: IO (Map PackageName Version)
queryBootPackages =
  parseBootList <$> readProcess "ghc-pkg" ["list", "--global", "--simple-output"] ""
```

- [ ] **Step 2: Write the Hackage provider**

Create `app/HackageProvider.hs`:

```haskell
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}

module HackageProvider
  ( Pkg (..)
  , HackageProvider (..)
  , ResolveError (..)
  , indexVersions
  ) where

import Control.Exception (Exception, throwIO)
import Data.List (sortBy)
import Data.Maybe (listToMaybe)
import Data.Ord (Down (..), comparing)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Distribution.PackageDescription (GenericPackageDescription, PackageIdentifier (..), PackageName, pkgName, pkgVersion)
import Distribution.System (Arch (..), OS (..), Platform (..))
import Distribution.Compiler (AbiTag (..), CompilerFlavor (..), CompilerId (..), CompilerInfo, unknownCompilerInfo)
import Distribution.Version (Version, mkVersion)

import Hackage.Security.Client (Directory (..), IndexCallbacks (..), IndexFile (..))
import Hackage.Security.Util.Some (Some (..))

import Database (ParseError, Result)
import PubGrub.Cabal.Flatten (flattenDeps)
import PubGrub.Types (Package)
import PubGrub.Solver (DependencyProvider (..))
import qualified PubGrub.VersionSet as VS
import PubGrub.VersionSet (VersionSet)

-- | Resolution package: a synthetic root, or a real Hackage package.
data Pkg = Root | Pkg PackageName
  deriving (Eq, Ord, Show)

instance Package Pkg

-- | Thrown when a selected package version's .cabal cannot be parsed.
data ResolveError = ResolveError PackageName Version
  deriving (Show)

instance Exception ResolveError

-- | A dependency provider backed by the Hackage index.
data HackageProvider = HackageProvider
  { hpVersions :: Map PackageName [Version]
  , hpLookup   :: PackageIdentifier -> IO (Result ParseError GenericPackageDescription)
  , hpBoot     :: Map PackageName Version
  , hpTarget   :: PackageName
  , hpRange    :: VersionSet
  }

thePlatform :: Platform
thePlatform = Platform X86_64 Linux

theCompiler :: CompilerInfo
theCompiler = unknownCompilerInfo (CompilerId GHC (mkVersion [9, 12, 4])) NoAbiTag

-- | The set of available versions per package, from the index directory.
indexVersions :: IndexCallbacks -> Map PackageName [Version]
indexVersions IndexCallbacks{indexDirectory} =
  Map.fromListWith (++)
    [ (pkgName pkgId, [pkgVersion pkgId])
    | (_entry, _path, msIndexFile) <- directoryEntries indexDirectory
    , Just (Some (IndexPkgCabal pkgId)) <- [msIndexFile]
    ]

instance DependencyProvider HackageProvider Pkg IO where
  chooseVersion hp pkg range = pure $ case pkg of
    Root -> Just (mkVersion [0])
    Pkg n
      | Just bv <- Map.lookup n (hpBoot hp) ->
          if VS.contains range bv then Just bv else Nothing
      | otherwise ->
          listToMaybe
            (sortBy (comparing Down)
              (filter (VS.contains range)
                (Map.findWithDefault [] n (hpVersions hp))))

  getDependencies hp pkg v = case pkg of
    Root -> pure (Map.singleton (Pkg (hpTarget hp)) (hpRange hp))
    Pkg n
      | Map.member n (hpBoot hp) -> pure Map.empty
      | otherwise -> do
          res <- hpLookup hp (PackageIdentifier n v)
          case res of
            Right gpd -> pure (Map.mapKeys Pkg (flattenDeps thePlatform theCompiler gpd))
            Left _    -> throwIO (ResolveError n v)
```

Notes for the implementer:
- `Result e a = Either (Either SomeException e) a` and `ParseError` are exported by `Database` (which has no explicit export list).
- `directoryEntries`, `Directory (..)`, `IndexFile (..)`, `Some (..)`, `pkgName`, `pkgVersion`, `PackageIdentifier (..)` mirror the existing usage in `app/Database.hs` — cross-check import spellings against that file if any import fails.

- [ ] **Step 3: Standalone-typecheck `BootPackages` (offline; boot-lib-only imports)**

Run: `ghc -fno-code -Wall -iapp -iapp-lib -package process -package Cabal-syntax -package containers -XGHC2021 app/BootPackages.hs 2>&1 | tail`
Expected: compiles (it imports `PubGrub.Cabal.Boot` from `app-lib` and only boot libs). If `-iapp-lib` resolution complains, also pass `-isrc` so `PubGrub.VersionSet` is found transitively. `HackageProvider` is NOT typecheckable offline (needs `hackage-security`); leave it for the user build in Task 7.

- [ ] **Step 4: Commit**

```bash
git add app/BootPackages.hs app/HackageProvider.hs
git commit -m "feat: Hackage IO dependency provider and boot-package query"
```

---

## Task 6: CLI integration

**Files:**
- Rewrite: `app/Solver.hs`
- Modify: `app/Main.hs`

> Verification: built and run by the user (executable needs `hackage-security` et al.).

- [ ] **Step 1: Rewrite `app/Solver.hs` as the integration entry point**

Replace `app/Solver.hs` with EXACTLY:

```haskell
{-# LANGUAGE ScopedTypeVariables #-}

module Solver
  ( runSolve
  ) where

import Control.Exception (try)
import qualified Data.ByteString.Lazy as BSL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Distribution.PackageDescription (GenericPackageDescription, PackageName)
import Distribution.PackageDescription.Parsec (parseGenericPackageDescription, runParseResult)
import Distribution.Pretty (prettyShow)
import Distribution.Version (Version, mkVersion)

import Hackage.Security.Client (IndexCallbacks)

import BootPackages (queryBootPackages)
import Database (ParseError (..), mkDatabase)
import HackageProvider (HackageProvider (..), Pkg (..), ResolveError (..), indexVersions)
import PubGrub.Solver (SolveError (..), solve, reportConflict)
import PubGrub.VersionSet (VersionSet)

-- | Resolve the dependency closure of @target@ within @range@ and print the
-- plan (or a derivation tree on failure).
runSolve :: IndexCallbacks -> PackageName -> VersionSet -> IO ()
runSolve indexCallbacks target range = do
  dblookup <- mkDatabase indexCallbacks parseGPD
  boot <- queryBootPackages
  let hp = HackageProvider
        { hpVersions = indexVersions indexCallbacks
        , hpLookup   = dblookup
        , hpBoot     = boot
        , hpTarget   = target
        , hpRange    = range
        }
  outcome <-
    try (solve hp Root (mkVersion [0]))
      :: IO (Either ResolveError (Either (SolveError Pkg) (Map Pkg Version)))
  case outcome of
    Left (ResolveError n v) ->
      putStrLn ("Failed to parse " ++ prettyShow n ++ "-" ++ prettyShow v)
    Right (Left (NoSolution i)) -> do
      putStrLn "No solution:"
      putStrLn (reportConflict i)
    Right (Right plan) -> do
      putStrLn "Resolved:"
      mapM_ putPlanLine (Map.toList plan)
  where
    putPlanLine (Root, _)  = pure ()
    putPlanLine (Pkg n, v) = putStrLn ("  " ++ prettyShow n ++ " => " ++ prettyShow v)

parseGPD :: BSL.ByteString -> Either ParseError GenericPackageDescription
parseGPD bs =
  case runParseResult (parseGenericPackageDescription (BSL.toStrict bs)) of
    (_, Left (mver, errs)) -> Left (ParseError mver errs)
    (_, Right gpd)         -> Right gpd
```

Note: `reportConflict` is exported from `PubGrub.Solver` (not `PubGrub.Types`). The `Version` import is used only via the `Map Pkg Version` annotation; if GHC reports it unused, it is still needed by that signature — keep it.

- [ ] **Step 2: Update `app/Main.hs` to parse argv and dispatch**

In `app/Main.hs`, add imports:

```haskell
import System.Environment (getArgs)
import Distribution.Parsec (eitherParsec)
import Distribution.Types.VersionRange (VersionRange)
import Distribution.PackageDescription (mkPackageName)
import qualified PubGrub.VersionSet as VS
import Solver (runSolve)
```

Replace the body of `main` (the `usingLoggerT ... withIndex ... dblookup ...` block and the `Done.` line) with argv parsing and a dispatch to `runSolve`:

```haskell
main :: IO ()
main = do
  manager <- liftIO $ newManager defaultManagerSettings
  cache <- mkCache <$> makeAbsolute (fromFilePath "_cache")
  args <- getArgs
  case args of
    (pkgStr : rest) -> do
      let target = mkPackageName pkgStr
          range = case rest of
            []      -> VS.full
            (r : _) -> case eitherParsec r :: Either String VersionRange of
              Right vr -> VS.fromVersionRange vr
              Left err -> error ("invalid version range: " ++ err)
      usingLoggerT logMessageAction $
        withHackage cache manager $ \repository ->
          withIndex repository $ \indexCallbacks ->
            liftIO (runSolve indexCallbacks target range)
    [] -> putStrLn "usage: pubgrub-hs <package> [version-range]"
```

(Remove the now-unused `parse`, `Database`/`PackageIdentifier`/`mkVersion` imports from `Main` if GHC flags them; the GPD parser now lives in `Solver`.)

- [ ] **Step 3: Commit**

```bash
git add app/Solver.hs app/Main.hs
git commit -m "feat: CLI resolves a Hackage package via the solver"
```

---

## Task 7: Build & integration verification (user machine)

**Files:** none (verification only).

> The agent cannot run these (executable deps + live index need hackage). The user runs them.

- [ ] **Step 1: Build everything**

Run: `cabal build all`
Expected: library, `cabal-bridge`, executable, and test-suite all compile (warnings from pre-existing `app/` code that this plan does not touch are acceptable; new modules should be `-Wall`-clean).

- [ ] **Step 2: Run the test suite**

Run: `cabal test --test-show-details=direct`
Expected: all tests pass (VersionSet, Solver, Flatten, Boot).

- [ ] **Step 3: Resolve a real package**

Run: `cabal run pubgrub-hs -- bytestring` (a small, mostly-boot dependency set) and then `cabal run pubgrub-hs -- lens`.
Expected: a `Resolved:` block listing `package => version` for the closure, or a `No solution:` derivation tree. (First run may update the index from the network.)

- [ ] **Step 4: Final commit (if any tweaks were needed during integration)**

```bash
git add -A
git commit -m "chore: Hackage integration verification fixups"
```

---

## Out of scope (future)

- Cabal flag *solving*; non-library components; reinstallable boot packages.
- `preferred-versions`/deprecation; revision selection.
- Performance (watched literals); deduped/numbered error reports.
- ASP cross-validation.
