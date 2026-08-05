# Lazy Index Loading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the slow upfront index load by replacing the eager `TVar`-per-entry database + second version-map traversal with one pure traversal that remembers each version's `DirectoryEntry`, parsing `.cabal` files on demand.

**Architecture:** `Database.indexEntries` builds `Map PackageName (Map Version DirectoryEntry)` in a single pure pass; `Database.parseEntry` parses one entry on demand; `HackageProvider` holds that map plus an on-demand parser; `runSolve` wires them with no `mkDatabase` IO.

**Tech Stack:** GHC 9.12.4; `hackage-security` (index `Directory`/`DirectoryEntry`/`indexLookupEntry`); `containers`; `Cabal-syntax`.

---

## Environment / verification note

This is a single cohesive refactor of three executable modules that only builds when all
three change together. The executable's deps are cached, so `cabal build all`,
`cabal run`, and `cabal test` all work offline and are the gates. The solver core/library
is untouched, so the 26 tests must stay green.

---

## File Structure

| File | Change |
|------|--------|
| `app/Database.hs` | Add pure `indexEntries` + on-demand `parseEntry`; delete the `TVar` machinery; keep `ParseError`/`Result`/`extractDepInfo`/`DepInfo` |
| `app/HackageProvider.hs` | Fields `hpEntries`/`hpParse` replace `hpVersions`/`hpLookup`; delete `indexVersions`; `chooseVersion`/`getDependencies` use the nested map |
| `app/Solver.hs` | `runSolve` uses `indexEntries`/`parseEntry` instead of `mkDatabase`/`indexVersions`; import changes |

---

## Task 1: Lazy index — single traversal, parse on demand

**Files:** Modify `app/Database.hs`, `app/HackageProvider.hs`, `app/Solver.hs`

- [ ] **Step 1: Replace `app/Database.hs` with the lean version**

Replace the ENTIRE contents of `app/Database.hs` with:

```haskell
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Database where

import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (maybeToList)

import Data.Map (Map)
import qualified Data.Map.Strict as M

import Control.Exception (SomeException)
import qualified Data.ByteString.Lazy as BSL
import Distribution.Fields
import Distribution.PackageDescription
import qualified Distribution.Types.Lens as L
import Distribution.Version (Version)
import Hackage.Security.Client (
    Directory (..),
    DirectoryEntry,
    IndexCallbacks (..),
    IndexEntry (..),
    IndexFile (..),
    uncheckClientErrors,
 )
import Hackage.Security.Util.Some (Some (..))

type Result e a = Either (Either SomeException e) a

data ParseError
    = ParseError (Maybe Version) (NonEmpty PError)
    | ParseException SomeException
    deriving Show

-- | One pure traversal of the index: package -> version -> its directory entry.
-- No parsing, no TVars. The package name and version come from the already-decoded
-- 'IndexPkgCabal', so no .cabal or path-string parsing is needed.
indexEntries :: IndexCallbacks -> Map PackageName (Map Version DirectoryEntry)
indexEntries IndexCallbacks{indexDirectory} =
    M.fromListWith (<>)
        [ (pkgName pkgId, M.singleton (pkgVersion pkgId) entry)
        | (entry, _indexPath, msIndexFile) <- directoryEntries indexDirectory
        , Just (Some (IndexPkgCabal pkgId)) <- [msIndexFile]
        ]

-- | Parse a single index entry's .cabal on demand.
parseEntry
    :: IndexCallbacks
    -> (BSL.ByteString -> Either e a)
    -> DirectoryEntry
    -> IO (Either e a)
parseEntry IndexCallbacks{indexLookupEntry} parse entry = do
    (Some indexEntry, _) <- uncheckClientErrors $ indexLookupEntry entry
    return $ parse (indexEntryContent indexEntry)

-- Dependency PackageName VersionRange (NonEmptySet LibraryName)
-- Retained for upcoming conditional-dependency work (flags/os/arch).
newtype DepInfo = DepInfo (Map ComponentName (CondTree ConfVar [Dependency] ()))

extractDepInfo :: GenericPackageDescription -> DepInfo
extractDepInfo gpd =
    DepInfo $
        M.fromList $
            [(CLibName LMainLibName, f tree) | tree <- maybeToList (condLibrary gpd)]
                <> [(CLibName (LSubLibName ucn), f tree) | (ucn, tree) <- condSubLibraries gpd]
                <> [(CFLibName ucn, f tree) | (ucn, tree) <- condForeignLibs gpd]
                <> [(CExeName ucn, f tree) | (ucn, tree) <- condExecutables gpd]
                <> [(CTestName ucn, f tree) | (ucn, tree) <- condTestSuites gpd]
                <> [(CBenchName ucn, f tree) | (ucn, tree) <- condBenchmarks gpd]
  where
    f :: L.HasBuildInfo a => CondTree v c a -> CondTree v c ()
    f = mapTreeData (const ())
```

(Removed: `Index`, `Entry`, `Database`, `Decision`, `mkDatabase`, `getOrParse`,
`lookupEntryVar`, `traverseIndex`, and the `Control.Concurrent.STM*`/`TVar`/`TMVar`/
`Control.Exception (try)`/`GHC.Generics` imports. `Result` is kept though now unused, per
the spec.)

- [ ] **Step 2: Replace `app/HackageProvider.hs`**

Replace the ENTIRE contents of `app/HackageProvider.hs` with:

```haskell
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}

module HackageProvider
  ( Pkg (..)
  , HackageProvider (..)
  , ResolveError (..)
  ) where

import Control.Exception (Exception, throwIO)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.List (sortBy)
import Data.Maybe (listToMaybe)
import Data.Ord (Down (..), comparing)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Distribution.PackageDescription (GenericPackageDescription, PackageName)
import Distribution.System (Arch (..), OS (..), Platform (..))
import Distribution.Compiler (AbiTag (..), CompilerFlavor (..), CompilerId (..), CompilerInfo, unknownCompilerInfo)
import Distribution.Version (Version, mkVersion)

import Hackage.Security.Client (DirectoryEntry)

import Database (ParseError)
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

-- | A dependency provider backed by the Hackage index. @hpEntries@ remembers each
-- version's directory entry; @hpParse@ parses one on demand.
data HackageProvider = HackageProvider
  { hpEntries :: Map PackageName (Map Version DirectoryEntry)
  , hpParse   :: DirectoryEntry -> IO (Either ParseError GenericPackageDescription)
  , hpBoot    :: Map PackageName Version
  , hpTarget  :: PackageName
  , hpRange   :: VersionSet
  }

thePlatform :: Platform
thePlatform = Platform X86_64 Linux

theCompiler :: CompilerInfo
theCompiler = unknownCompilerInfo (CompilerId GHC (mkVersion [9, 12, 4])) NoAbiTag

instance MonadIO m => DependencyProvider HackageProvider Pkg m where
  chooseVersion hp pkg range = pure $ case pkg of
    Root -> Just (mkVersion [0])
    Pkg n
      | Just bv <- Map.lookup n (hpBoot hp) ->
          if VS.contains range bv then Just bv else Nothing
      | otherwise ->
          listToMaybe
            (sortBy (comparing Down)
              (filter (VS.contains range)
                (Map.keys (Map.findWithDefault Map.empty n (hpEntries hp)))))

  getDependencies hp pkg v = case pkg of
    Root -> pure (Map.singleton (Pkg (hpTarget hp)) (hpRange hp))
    Pkg n
      | Map.member n (hpBoot hp) -> pure Map.empty
      | otherwise ->
          case Map.lookup n (hpEntries hp) >>= Map.lookup v of
            Just entry -> do
              res <- liftIO (hpParse hp entry)
              case res of
                Right gpd -> pure (Map.mapKeys Pkg (flattenDeps thePlatform theCompiler gpd))
                Left _    -> liftIO (throwIO (ResolveError n v))
            Nothing -> liftIO (throwIO (ResolveError n v))
```

(Removed: the `GADTs` pragma, `indexVersions`, the `Hackage.Security.Client (Directory(..),
IndexCallbacks(..), IndexFile(..))` + `Some(..)` imports, `pkgName`/`pkgVersion`/
`PackageIdentifier(..)`, and `Database (Result)`. Added `DirectoryEntry`.)

- [ ] **Step 3: Update `app/Solver.hs` imports**

In `app/Solver.hs`, change:

```haskell
import Database (ParseError (..), mkDatabase)
import HackageProvider (HackageProvider (..), Pkg (..), ResolveError (..), indexVersions)
```

to:

```haskell
import Database (ParseError (..), indexEntries, parseEntry)
import HackageProvider (HackageProvider (..), Pkg (..), ResolveError (..))
```

- [ ] **Step 4: Rewire the provider construction in `runSolve`**

In `app/Solver.hs`, find this block inside `runSolve`:

```haskell
  note "\ESC[2mLoading package index\x2026\ESC[0m"
  dblookup <- liftIO (mkDatabase indexCallbacks parseGPD)
  let hp = HackageProvider
        { hpVersions = indexVersions indexCallbacks
        , hpLookup   = dblookup
        , hpBoot     = boot
        , hpTarget   = target
        , hpRange    = range
        }
      pkgCount = Map.size (hpVersions hp)   -- forcing this does the costly index traversal
  note ("\ESC[2m  " <> T.pack (show pkgCount) <> " packages indexed\ESC[0m")
```

and replace it with:

```haskell
  note "\ESC[2mLoading package index\x2026\ESC[0m"
  let entries = indexEntries indexCallbacks
      hp = HackageProvider
        { hpEntries = entries
        , hpParse   = parseEntry indexCallbacks parseGPD
        , hpBoot    = boot
        , hpTarget  = target
        , hpRange   = range
        }
      pkgCount = Map.size entries   -- forcing this does the single index traversal
  note ("\ESC[2m  " <> T.pack (show pkgCount) <> " packages indexed\ESC[0m")
```

(`indexEntries` is pure, so there is no `dblookup <- liftIO …` line any more. `parseGPD`,
`queryBootPackages`, the banner, and the rest of `runSolve` are unchanged.)

- [ ] **Step 5: Build everything (offline)**

Run: `cabal build all 2>&1 | tail -8`
Expected: library, `cabal-bridge`, and executable compile, `-Wall`-clean. If GHC reports an
unused import or symbol in `Database.hs`/`HackageProvider.hs`, remove it (the import lists
above are intended to be exactly what's used; `Result` in `Database` is unused but its
module has no export list so it produces no warning).

- [ ] **Step 6: The 26 tests still pass**

Run: `cabal test --test-show-details=direct 2>&1 | grep -E "All .* tests|FAIL"`
Expected: all 26 pass (the solver core/library is untouched).

- [ ] **Step 7: Resolve a real package (same plan, faster load)**

Run: `cabal run -v0 pubgrub-hs -- lens-5.3.5 2>/dev/null`
Expected: the SAME `Resolved:` plan as before the refactor (lens 5.3.5 and its closure).
Also run: `cabal run -v0 pubgrub-hs -- lens-5.3.5 2>&1 | grep "packages indexed"`
Expected: the `N packages indexed` note still prints; the "Loading package index…" phase
should be noticeably quicker than before (no per-entry `TVar` allocation, single traversal).

- [ ] **Step 8: Commit**

```bash
git add app/Database.hs app/HackageProvider.hs app/Solver.hs
git commit -m "perf: lazy index loading — remember DirectoryEntry, parse on demand"
```

---

## Out of scope (future)

- A lazy parse cache (re-parse on backtrack re-decide is currently accepted).
- Using `extractDepInfo`/`DepInfo` for conditional dependencies (flags/os/arch) — retained
  for that work.
