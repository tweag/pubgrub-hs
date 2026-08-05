# Installed vs Source Providers — Implementation Plan (Phase 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve against the real GHC package database as a first-class source of
choices alongside Hackage — the solver picks installed *or* source instances of a
package, preferring reuse of installed ones.

**Architecture:** Two `DependencyProvider`s — `HackageProvider` over `VersionSet`
(source) and a new `PackageDbProvider` over `Pow UnitId` (installed, populated from
`ghc-pkg dump`) — combined into one provider over `ChoiceSet` (`Pow UnitId ×
VersionSet`) that dispatches each component to its sub-provider, prefers installed,
and fills the installed side of a source dependency's range from the db. The
existing boot-package pinning is subsumed by the installed db.

**Tech Stack:** GHC 9.12 / GHC2021, Cabal-syntax 3.14 (`InstalledPackageInfo`,
`parseInstalledPackageInfo`), Cabal, `process`, `containers`, `tasty`.

Builds on `docs/superpowers/specs/2026-06-24-choice-lattice-design.md` (Phase 3) and
the now-landed Phases 0–2 (`PubGrub.Lattice`, `PubGrub.Pow`, `PubGrub.Choice` with
`Choice`/`ChoiceSet` as a `Sets` instance).

## Global Constraints

- GHC2021; `-Wall` on every component; fix new warnings before committing.
- No partial functions (`head`, `fromJust`, …) — pattern-match or `Maybe`/`Either`.
- Library (`pubgrub-hs`) depends only on Cabal-syntax; anything needing `Cabal`,
  `process`, or `ghc-pkg` lives in `cabal-bridge` (pure) or the executable (IO),
  matching the existing split (`PubGrub.Cabal.*` pure, `app/Compiler.hs` IO).
- **Decision (locked):** populate the installed db from real `ghc-pkg dump` now.
- **Decision (locked):** when both worlds satisfy a dependency, prefer the installed
  instance (reuse); fall back to the newest in-range source version.
- Commit after every task; trailer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure

- `app-lib/PubGrub/Cabal/InstalledDb.hs` (create) — pure: parse `ghc-pkg dump`
  output into `[InstalledPkg]` (unit-id, name, version, dep unit-ids).
- `app/Pkg.hs` (create) — the shared resolution package type `Pkg` with its
  `Package` and `Pretty` instances, moved out of `HackageProvider` so both
  providers and the combiner can use it without a cycle.
- `app/PackageDbProvider.hs` (create) — the installed-world provider: an index over
  `[InstalledPkg]`, a `DependencyProvider Pkg (Pow UnitId)` instance, the
  `installedInRange` helper, and IO to populate it from `ghc-pkg dump`.
- `app/Provider.hs` (create) — the combined provider over `ChoiceSet`.
- `src/PubGrub/Choice.hs` (modify) — add `Pretty Choice` / `Pretty ChoiceSet`.
- `app/HackageProvider.hs` (modify) — import `Pkg`; drop boot/Root handling so it is
  a pure source provider.
- `app/Solver.hs`, `app/Main.hs` (modify) — run the solver over `ChoiceSet`.
- Tests: `test/InstalledDbSpec.hs`, `test/PackageDbProviderSpec.hs`,
  `test/ProviderSpec.hs`, plus `Pretty` cases in `test/PrettySpec.hs`.

---

## Task 1: Pure `ghc-pkg dump` parser

**Files:**
- Create: `app-lib/PubGrub/Cabal/InstalledDb.hs`
- Create: `test/InstalledDbSpec.hs`
- Modify: `pubgrub-hs.cabal` (add module to `cabal-bridge` exposed-modules; add
  `InstalledDbSpec` to the test-suite; the test-suite already depends on
  `pubgrub-hs:cabal-bridge`), `test/Main.hs`

**Interfaces:**
- Produces:
  - `data InstalledPkg = InstalledPkg { ipUnitId :: UnitId, ipName :: PackageName, ipVersion :: Version, ipDepends :: [UnitId] }` (deriving `Eq, Show`)
  - `parseGhcPkgDump :: ByteString -> Either String [InstalledPkg]`

- [ ] **Step 1: Write the failing test**

Create `test/InstalledDbSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module InstalledDbSpec (tests) where

import Distribution.Types.PackageName (mkPackageName)
import Distribution.Types.UnitId (mkUnitId)
import Distribution.Version (mkVersion)
import PubGrub.Cabal.InstalledDb (InstalledPkg (..), parseGhcPkgDump)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

dump :: String
dump =
    unlines
        [ "name: ghc-prim"
        , "version: 0.11.0"
        , "id: ghc-prim-0.11.0-aaa"
        , "depends:"
        , "---"
        , "name: base"
        , "version: 4.21.0.0"
        , "id: base-4.21.0.0-bbb"
        , "depends: ghc-prim-0.11.0-aaa"
        , "---"
        ]

tests :: TestTree
tests =
    testGroup
        "InstalledDb"
        [ testCase "parses two records with names, versions, unit-ids" $
            (fmap (map ipName) (parseGhcPkgDump' dump))
                @?= Right [mkPackageName "ghc-prim", mkPackageName "base"]
        , testCase "parses dependency unit-ids" $
            (fmap (map ipDepends) (parseGhcPkgDump' dump))
                @?= Right [[], [mkUnitId "ghc-prim-0.11.0-aaa"]]
        , testCase "parses the unit-id and version of base" $
            (fmap (take 1 . drop 1) (parseGhcPkgDump' dump))
                @?= Right
                    [ InstalledPkg
                        (mkUnitId "base-4.21.0.0-bbb")
                        (mkPackageName "base")
                        (mkVersion [4, 21, 0, 0])
                        [mkUnitId "ghc-prim-0.11.0-aaa"]
                    ]
        ]
  where
    parseGhcPkgDump' = parseGhcPkgDump . encodeUtf8'
    -- Tests feed ASCII, so a Char->Word8 pack is faithful here.
    encodeUtf8' = Data.ByteString.Char8.pack
```

Add these imports to the test's import list (kept here for clarity):
`import qualified Data.ByteString.Char8` (so `Data.ByteString.Char8.pack` resolves).

- [ ] **Step 2: Register and run to verify it fails**

In `pubgrub-hs.cabal`, add `PubGrub.Cabal.InstalledDb` to the `cabal-bridge`
library `exposed-modules`, and add `InstalledDbSpec` to the test-suite
`other-modules`. In `test/Main.hs`, add `import InstalledDbSpec qualified` and
`InstalledDbSpec.tests` to the list. The test-suite already lists
`bytestring` and `pubgrub-hs:cabal-bridge` in `build-depends`.

Run: `cabal test 2>&1 | tail -20`
Expected: FAIL — `Could not find module 'PubGrub.Cabal.InstalledDb'`.

- [ ] **Step 3: Implement the parser**

Create `app-lib/PubGrub/Cabal/InstalledDb.hs`:

```haskell
-- | Parse the output of @ghc-pkg dump@ into a flat list of installed packages.
-- Each record is an 'InstalledPackageInfo' in the @.conf@ field format; records
-- are separated by lines containing exactly @---@.
module PubGrub.Cabal.InstalledDb (
    InstalledPkg (..),
    parseGhcPkgDump,
) where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.List.NonEmpty qualified as NE
import Distribution.InstalledPackageInfo (
    InstalledPackageInfo (..),
    parseInstalledPackageInfo,
 )
import Distribution.Types.PackageId (PackageIdentifier (..))
import Distribution.Types.PackageName (PackageName)
import Distribution.Types.UnitId (UnitId)
import Distribution.Version (Version)

data InstalledPkg = InstalledPkg
    { ipUnitId :: UnitId
    , ipName :: PackageName
    , ipVersion :: Version
    , ipDepends :: [UnitId]
    }
    deriving (Eq, Show)

-- | Split on @---@ separator lines, parse each non-blank record, project the
-- fields we need. Returns 'Left' with the first record's parse errors.
parseGhcPkgDump :: ByteString -> Either String [InstalledPkg]
parseGhcPkgDump = traverse parseRecord . filter (not . isBlank) . splitRecords
  where
    splitRecords =
        map BS8.unlines . wordsByLine (== BS8.pack "---") . BS8.lines
    isBlank = all (BS8.all (`elem` (" \t" :: String))) . BS8.lines
    parseRecord bs = case parseInstalledPackageInfo bs of
        Left errs -> Left (unlines (NE.toList errs))
        Right (_warnings, ipi) ->
            let PackageIdentifier n v = sourcePackageId ipi
             in Right (InstalledPkg (installedUnitId ipi) n v (depends ipi))

-- | Break a list of lines into groups delimited by lines satisfying @p@.
wordsByLine :: (a -> Bool) -> [a] -> [[a]]
wordsByLine p = foldr step [[]]
  where
    step x acc@(cur : rest)
        | p x = [] : acc
        | otherwise = (x : cur) : rest
    step _ [] = [[]] -- unreachable: acc is always non-empty
```

> Note: confirm `parseInstalledPackageInfo`'s return type against Cabal-syntax
> 3.14 — it is `ByteString -> Either (NonEmpty String) ([String], InstalledPackageInfo)`.
> If your minimal fixtures are rejected for missing required fields, capture one
> real record from `ghc-pkg dump --global` into the fixture instead.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cabal test 2>&1 | grep -iE "InstalledDb|tests passed|FAIL"`
Expected: PASS — the `InstalledDb` group passes; all others stay green.

- [ ] **Step 5: Commit**

```bash
git add app-lib/PubGrub/Cabal/InstalledDb.hs test/InstalledDbSpec.hs pubgrub-hs.cabal test/Main.hs
git commit -m "feat: parse ghc-pkg dump into installed package records

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Extract the `Pkg` type into its own module

`Pkg` is currently defined in `HackageProvider`; both providers and the combiner
need it, so move it (with its instances) to a dedicated module to avoid a cycle.

**Files:**
- Create: `app/Pkg.hs`
- Modify: `app/HackageProvider.hs` (remove `Pkg` + its instances; import them),
  `app/Solver.hs` (import `Pkg` from `Pkg`), `pubgrub-hs.cabal` (add `Pkg` to the
  executable `other-modules`)

**Interfaces:**
- Produces: module `Pkg` exporting `data Pkg = Root | Pkg PackageName` with
  `instance Package Pkg` (`type Key Pkg = PackageName`) and `instance Pretty Pkg`.

- [ ] **Step 1: Create `app/Pkg.hs`** (move the existing definition verbatim)

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

-- | The resolution package type shared by every provider: a synthetic root, or
-- a real Hackage/installed package named by its 'PackageName'.
module Pkg (Pkg (..)) where

import Data.Text qualified as T
import Distribution.Pretty (prettyShow)
import Distribution.Types.PackageName (PackageName)
import PubGrub.Pretty (Pretty (..))
import PubGrub.Types (Package (..))

data Pkg = Root | Pkg PackageName
    deriving (Eq, Ord, Show)

instance Package Pkg where
    type Key Pkg = PackageName
    prettyPackage Root = "root"
    prettyPackage (Pkg n) = T.pack (prettyShow n)

instance Pretty Pkg where
    pretty Root = "root"
    pretty (Pkg n) = T.pack (prettyShow n)
```

(Note: this restores the `Pretty Pkg` instance, now that reporting over
`ChoiceSet` will render package names via `Pretty` in some contexts; it is the
canonical home for it.)

- [ ] **Step 2: Remove `Pkg` from `HackageProvider` and import it**

In `app/HackageProvider.hs`: delete the `data Pkg = …` definition and its
`instance Package Pkg`; add `import Pkg (Pkg (..))`; remove `Pkg` from the module
export list (it is re-exported via `Pkg` now, or export it from `Pkg`). Keep the
`HackageProvider`-specific code.

- [ ] **Step 3: Register and build**

Add `Pkg` to the executable `other-modules` in `pubgrub-hs.cabal`.

Run: `cabal build all 2>&1 | grep -iE "error|warning" | grep -v "package list"`
Expected: no output. Fix any import fallout in `app/Solver.hs`/`app/Main.hs`
(they import `Pkg (..)` from `HackageProvider` today → import from `Pkg`).

- [ ] **Step 4: Run tests**

Run: `cabal test 2>&1 | grep -iE "tests passed|FAIL"`
Expected: `All NN tests passed`.

- [ ] **Step 5: Commit**

```bash
git add app/Pkg.hs app/HackageProvider.hs app/Solver.hs app/Main.hs pubgrub-hs.cabal
git commit -m "refactor: move Pkg into its own module

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `PackageDbProvider` (installed world over `Pow UnitId`)

**Files:**
- Create: `app/PackageDbProvider.hs`
- Create: `test/PackageDbProviderSpec.hs`
- Modify: `pubgrub-hs.cabal`, `test/Main.hs`

**Interfaces:**
- Consumes: `InstalledPkg` (Task 1), `Pkg` (Task 2), `Pow` (`PubGrub.Pow`),
  `ChoiceInstalled` (`PubGrub.Choice`).
- Produces:
  - `data PackageDbProvider` (an index built from `[InstalledPkg]`)
  - `mkPackageDbProvider :: PackageDb -> [InstalledPkg] -> PackageDbProvider`
  - `installedInRange :: PackageDbProvider -> PackageName -> VersionSet -> Pow UnitId`
  - `installedChoice :: PackageDbProvider -> UnitId -> Maybe ChoiceInstalled`
  - `instance Monad m => DependencyProvider PackageDbProvider Pkg (Pow UnitId) m`
    with `expand` returning the newest in-set installed unit-id and its
    dependencies as `Map Pkg (Pow UnitId)`.

- [ ] **Step 1: Write the failing test**

Create `test/PackageDbProviderSpec.hs`:

```haskell
{-# LANGUAGE ScopedTypeVariables #-}

module PackageDbProviderSpec (tests) where

import Data.Functor.Identity (runIdentity)
import Data.Map.Strict qualified as Map
import Distribution.Types.PackageName (mkPackageName)
import Distribution.Types.UnitId (UnitId, mkUnitId)
import Distribution.Version (mkVersion)
import PubGrub.Cabal.InstalledDb (InstalledPkg (..))
import PubGrub.Choice (ChoiceInstalled (..))
import PubGrub.Compiler (PackageDb (..))
import PubGrub.Lattice (singleton)
import PubGrub.Pow (Pow (..))
import PubGrub.Solver (expand)
import PackageDbProvider (PackageDbProvider, installedInRange, mkPackageDbProvider)
import Pkg (Pkg (..))
import PubGrub.VersionSet qualified as VS
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import qualified Data.Set as Set

ip :: String -> String -> [Int] -> [String] -> InstalledPkg
ip uid nm v deps =
    InstalledPkg (mkUnitId uid) (mkPackageName nm) (mkVersion v) (map mkUnitId deps)

db :: PackageDbProvider
db =
    mkPackageDbProvider
        GlobalDb
        [ ip "ghc-prim-0.11-a" "ghc-prim" [0, 11] []
        , ip "base-4.21-b" "base" [4, 21] ["ghc-prim-0.11-a"]
        , ip "base-4.20-c" "base" [4, 20] ["ghc-prim-0.11-a"]
        ]

tests :: TestTree
tests =
    testGroup
        "PackageDbProvider"
        [ testCase "installedInRange returns matching unit-ids" $
            installedInRange db (mkPackageName "base") VS.full
                @?= Incl (Set.fromList [mkUnitId "base-4.21-b", mkUnitId "base-4.20-c"])
        , testCase "installedInRange filters by version" $
            installedInRange db (mkPackageName "base")
                (VS.singleton (mkVersion [4, 20]))
                @?= Incl (Set.singleton (mkUnitId "base-4.20-c"))
        , testCase "expand picks the newest in-set unit-id" $
            let allBase = installedInRange db (mkPackageName "base") VS.full
                Just (uid, _) = runIdentity (expand db (Pkg (mkPackageName "base")) allBase)
             in uid @?= mkUnitId "base-4.21-b"
        , testCase "expand returns installed deps grouped by package" $
            let allBase = installedInRange db (mkPackageName "base") VS.full
                Just (_, deps) = runIdentity (expand db (Pkg (mkPackageName "base")) allBase)
             in deps
                    @?= Map.singleton
                        (Pkg (mkPackageName "ghc-prim"))
                        (singleton (mkUnitId "ghc-prim-0.11-a") :: Pow UnitId)
        , testCase "expand of an empty set is Nothing" $
            runIdentity (expand db (Pkg (mkPackageName "base")) (Incl Set.empty))
                @?= (Nothing :: Maybe (UnitId, Map.Map Pkg (Pow UnitId)))
        ]
```

- [ ] **Step 2: Register and run to verify it fails**

Add `PackageDbProvider` to the executable `other-modules` and
`PackageDbProviderSpec` to the test-suite `other-modules`; the test-suite must be
able to import the executable's modules — if it cannot, move `PackageDbProvider`
and `Pkg` into the `cabal-bridge` library instead (it already depends on `Cabal`),
and have the executable import them from there. Add to `test/Main.hs`.

Run: `cabal test 2>&1 | tail -20`
Expected: FAIL — `Could not find module 'PackageDbProvider'`.

- [ ] **Step 3: Implement the provider**

Create `app/PackageDbProvider.hs`:

```haskell
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}

-- | The installed-world dependency provider, backed by the compiler's package
-- database. Its set type is 'Pow UnitId': a constraint names a finite set of
-- installed unit-ids. 'expand' commits to one (the newest in set) and reports
-- its dependencies, which are themselves exact installed unit-ids.
module PackageDbProvider (
    PackageDbProvider,
    mkPackageDbProvider,
    installedInRange,
    installedChoice,
) where

import Data.List (maximumBy)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Ord (comparing)
import Data.Set qualified as Set
import Distribution.Types.PackageName (PackageName)
import Distribution.Types.UnitId (UnitId)
import Distribution.Version (Version)
import PubGrub.Cabal.InstalledDb (InstalledPkg (..))
import PubGrub.Choice (ChoiceInstalled (..))
import PubGrub.Compiler (PackageDb)
import PubGrub.Lattice (member, singleton)
import PubGrub.Pow (Pow (..))
import PubGrub.Solver (DependencyProvider (..))
import PubGrub.VersionSet (VersionSet)
import PubGrub.VersionSet qualified as VS
import Pkg (Pkg (..))

-- | A package-db index: each installed unit-id mapped to its record, plus a
-- name->unit-ids lookup. @pdbKind@ tags which db these came from (for 'Choice').
data PackageDbProvider = PackageDbProvider
    { pdbKind :: PackageDb
    , pdbById :: Map UnitId InstalledPkg
    , pdbByName :: Map PackageName [UnitId]
    }

mkPackageDbProvider :: PackageDb -> [InstalledPkg] -> PackageDbProvider
mkPackageDbProvider kind pkgs =
    PackageDbProvider
        { pdbKind = kind
        , pdbById = Map.fromList [(ipUnitId p, p) | p <- pkgs]
        , pdbByName = Map.fromListWith (++) [(ipName p, [ipUnitId p]) | p <- pkgs]
        }

-- | The installed unit-ids of @name@ whose version lies in @range@.
installedInRange :: PackageDbProvider -> PackageName -> VersionSet -> Pow UnitId
installedInRange pdb name range =
    Incl
        ( Set.fromList
            [ uid
            | uid <- Map.findWithDefault [] name (pdbByName pdb)
            , Just p <- [Map.lookup uid (pdbById pdb)]
            , VS.contains range (ipVersion p)
            ]
        )

-- | Recover the 'ChoiceInstalled' for a unit-id, if it is in this db.
installedChoice :: PackageDbProvider -> UnitId -> Maybe ChoiceInstalled
installedChoice pdb uid =
    fmap
        (\p -> ChoiceInstalled (ipName p) (ipVersion p) (pdbKind pdb) (ipUnitId p))
        (Map.lookup uid (pdbById pdb))

versionOf :: PackageDbProvider -> UnitId -> Version
versionOf pdb uid = maybe (mkV0) ipVersion (Map.lookup uid (pdbById pdb))
  where
    mkV0 = ipVersion (error "versionOf: unknown unit-id") -- unreachable for in-db ids

instance (Monad m) => DependencyProvider PackageDbProvider Pkg (Pow UnitId) m where
    expand _ Root _ = pure Nothing
    expand pdb (Pkg _) sel = pure $ case sel of
        Incl uids
            | not (Set.null inDb) ->
                let chosen = maximumBy (comparing (versionOf pdb)) (Set.toList inDb)
                 in Just (chosen, depsOf chosen)
          where
            inDb = Set.filter (`Map.member` pdbById pdb) uids
        _ -> Nothing
      where
        depsOf uid =
            Map.fromListWith
                orPow
                [ (Pkg (ipName dep), singleton duid)
                | duid <- maybe [] ipDepends (Map.lookup uid (pdbById pdb))
                , Just dep <- [Map.lookup duid (pdbById pdb)]
                ]
        orPow (Incl a) (Incl b) = Incl (Set.union a b)
        orPow a _ = a
```

> Notes: `expand` for a `Pow UnitId` ignores `Excl` selectors by returning
> `Nothing` — in practice the installed component of a real `ChoiceSet`
> constraint is always a finite `Incl` (built by `installedInRange` /
> `singleton`), never a cofinite `Excl`. `versionOf`'s fallback is unreachable
> (only in-db ids are ever passed); if you prefer, thread a `Maybe` instead.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cabal test 2>&1 | grep -iE "PackageDbProvider|tests passed|FAIL"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/PackageDbProvider.hs test/PackageDbProviderSpec.hs pubgrub-hs.cabal test/Main.hs
git commit -m "feat: PackageDbProvider over Pow UnitId (installed world)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Make `HackageProvider` a pure source provider

Boot pinning moves to the installed db; Root moves to the combiner. Strip both
from `HackageProvider` so it only offers source versions.

**Files:**
- Modify: `app/HackageProvider.hs`

**Interfaces:**
- Produces: `instance DependencyProvider HackageProvider Pkg VersionSet m` whose
  `expand` handles only the ordinary-package case (newest in-range source version
  + flattened deps); the `Root` and boot-package cases are removed. `hpBoot` is
  removed from the `HackageProvider` record; `hpTarget`/`hpRange` are removed too
  (Root handling moves to the combiner). `hpCompiler` and `hpVersions`/
  `hpLookupCabal` remain.

- [ ] **Step 1: Update the record and `expand`**

In `app/HackageProvider.hs`, change the record to drop `hpBoot`, `hpTarget`,
`hpRange` (keep `hpVersions`, `hpLookupCabal`, `hpCompiler`), and replace the
instance body with the source-only version:

```haskell
instance (MonadIO m) => DependencyProvider HackageProvider Pkg VersionSet m where
    expand _ Root _ = pure Nothing
    expand hp (Pkg n) range =
        case Map.lookup n (hpVersions hp) >>= filterInRange of
            Nothing -> pure Nothing
            Just neVs -> do
                let v = Foldable1.maximum neVs
                res <- liftIO (hpLookupCabal hp (PackageIdentifier n v))
                case res of
                    Right gpd ->
                        pure (Just (v, Map.mapKeys Pkg (flattenDeps thePlatform (hpCompiler hp) gpd)))
                    Left _ -> liftIO (throwIO (ResolveError n v))
      where
        filterInRange = NE.nonEmpty . NE.filter (VS.contains range)
```

Update `withHackageProvider` to stop taking/threading `target`/`range`/boot and to
build the slimmed record. (The target/range now flow to the combiner — Task 6.)

- [ ] **Step 2: Build (other call sites will break until Task 6)**

This task leaves `app/Solver.hs`/`app/Main.hs` referencing the old shape; they are
rewritten in Task 6. Verify just the provider module type-checks in isolation by
building the library + this module's dependencies is not possible standalone, so
this task's deliverable is folded into Task 6's build. **Stage and commit the
`HackageProvider` change together with Task 6** (do not build between).

(If you prefer an independently-building commit, instead keep `withHackageProvider`
signature-compatible by ignoring the now-unused args until Task 6; the reviewer
may accept either.)

- [ ] **Step 3: Commit** — deferred into Task 6 (see note).

---

## Task 5: `Pretty` for `Choice` and `ChoiceSet`

**Files:**
- Modify: `src/PubGrub/Choice.hs`, `test/PrettySpec.hs`

**Interfaces:**
- Produces: `instance Pretty Choice`, `instance Pretty ChoiceSet`.
  - `pretty (Installed ci)` = `pretty (ciVersion ci) <> " (installed)"`
  - `pretty (Source cs)` = `pretty (csVersion cs)`
  - `pretty (ChoiceSet i s)` renders the source range; if the installed component
    is non-empty it appends `" (+N installed)"` where N is its size.

- [ ] **Step 1: Write the failing test** (append to `test/PrettySpec.hs`)

```haskell
        , testCase "installed choice is marked" $
            pretty (Installed (ChoiceInstalled (mkPackageName "foo") (mkVersion [1,5]) GlobalDb (mkUnitId "foo-1.5-x")))
                @?= "1.5 (installed)"
        , testCase "source choice renders its version" $
            pretty (Source (ChoiceSource (mkPackageName "foo") (mkVersion [1,5]) Hackage))
                @?= "1.5"
        , testCase "choiceset renders the source range" $
            pretty (ChoiceSet bottom (VS.fromVersionRange (orLaterVersion (mkVersion [1]))))
                @?= ">=1"
```

(add the needed imports: `PubGrub.Choice`, `PubGrub.Compiler (PackageDb(..))`,
`PubGrub.Lattice (bottom)`, `Distribution.Types.UnitId (mkUnitId)`,
`Distribution.Types.PackageName (mkPackageName)`.)

- [ ] **Step 2: Run to verify it fails**

Run: `cabal test 2>&1 | grep -iE "Pretty|FAIL"`
Expected: FAIL — no `Pretty Choice` instance.

- [ ] **Step 3: Implement** (in `src/PubGrub/Choice.hs`)

```haskell
import PubGrub.Pretty (Pretty (..))
import PubGrub.Pow (Pow (..))   -- already imports Pow; widen to Pow(..)
import Data.Set qualified as Set
import Data.Text qualified as T

instance Pretty Choice where
    pretty (Installed ci) = pretty (ciVersion ci) <> " (installed)"
    pretty (Source cs) = pretty (csVersion cs)

instance Pretty ChoiceSet where
    pretty (ChoiceSet i s) = pretty s <> installedNote i
      where
        installedNote (Incl u)
            | Set.null u = ""
            | otherwise = " (+" <> T.pack (show (Set.size u)) <> " installed)"
        installedNote (Excl _) = ""
```

- [ ] **Step 4: Run to verify it passes**

Run: `cabal test 2>&1 | grep -iE "Pretty|tests passed|FAIL"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/PubGrub/Choice.hs test/PrettySpec.hs
git commit -m "feat: Pretty instances for Choice and ChoiceSet

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Combined provider over `ChoiceSet` + wiring

**Files:**
- Create: `app/Provider.hs`
- Create: `test/ProviderSpec.hs`
- Modify: `app/Solver.hs`, `app/Main.hs`, `app/HackageProvider.hs` (carry Task 4),
  `pubgrub-hs.cabal`, `test/Main.hs`

**Interfaces:**
- Consumes: `PackageDbProvider`/`installedInRange`/`installedChoice` (Task 3),
  `HackageProvider` source `expand` (Task 4), `Choice`/`ChoiceSet` (Phase 2).
- Produces:
  - `data Combined = Combined { cDb :: PackageDbProvider, cSource :: HackageProvider, cTarget :: PackageName, cRange :: VersionSet }`
  - `instance DependencyProvider Combined Pkg ChoiceSet m` (needs `MonadIO m`)

- [ ] **Step 1: Write the failing test** (combiner logic, pure where possible)

Create `test/ProviderSpec.hs` exercising the prefer-installed policy and
cross-world lift with an in-memory `PackageDbProvider` and a `HackageProvider`
whose `hpLookupCabal` returns a trivial `.cabal` with no deps. Assert:

```haskell
-- with base installed at 4.21 and source base at {4.21, 4.22}, expanding base
-- over (ChoiceSet (installedInRange db base full) {4.21,4.22}) returns an
-- Installed choice (prefer reuse), not a Source choice.
```

(Spell the assertions out concretely as in earlier specs: build `Combined`, call
`expand`, pattern-match the returned `Choice` on `Installed`/`Source`.)

- [ ] **Step 2: Run to verify it fails** — `Could not find module 'Provider'`.

- [ ] **Step 3: Implement the combiner**

```haskell
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}

module Provider (Combined (..)) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Distribution.Types.PackageName (PackageName)
import Distribution.Version (Version, mkVersion)
import PubGrub.Choice
import PubGrub.Lattice (bottom)
import PubGrub.Pow (Pow)
import PubGrub.Solver (DependencyProvider (..))
import PubGrub.VersionSet (VersionSet)
import PackageDbProvider
import HackageProvider (HackageProvider)
import Pkg (Pkg (..))

data Combined = Combined
    { cDb :: PackageDbProvider
    , cSource :: HackageProvider
    , cTarget :: PackageName
    , cRange :: VersionSet
    }

instance (MonadIO m) => DependencyProvider Combined Pkg ChoiceSet m where
    expand c Root _ =
        -- synthetic root: depend on the target across both worlds
        let dep = ChoiceSet (installedInRange (cDb c) (cTarget c) (cRange c)) (cRange c)
            root = Source (ChoiceSource (cTarget c) (mkVersion [0]) Hackage)
         in pure (Just (root, Map.singleton (Pkg (cTarget c)) dep))
    expand c p (ChoiceSet inst src) = do
        mi <- expand (cDb c) p inst             -- Maybe (UnitId, Map Pkg (Pow UnitId))
        case mi of
            Just (uid, ideps)
                | Just ci <- installedChoice (cDb c) uid ->
                    pure (Just (Installed ci, fmap installedDep ideps))
            _ -> do
                ms <- expand (cSource c) p src  -- Maybe (Version, Map Pkg VersionSet)
                pure (fmap (sourceResult p) ms)
      where
        installedDep i = ChoiceSet i bottom
        sourceResult (Pkg n) (v, sdeps) =
            (Source (ChoiceSource n v Hackage), Map.mapWithKey liftSourceDep sdeps)
        sourceResult Root r = r `seq` error "unreachable"  -- Root handled above
        liftSourceDep (Pkg dn) range = ChoiceSet (installedInRange (cDb c) dn range) range
        liftSourceDep Root range = ChoiceSet bottom range
```

> The `import UnliftIO (MonadIO(..))` (or `Control.Monad.IO.Class`) is needed for
> the `MonadIO m` constraint; align with how `HackageProvider` imports it.

- [ ] **Step 4: Carry Task 4 + rewire `app/Solver.hs` and `app/Main.hs`**

Apply this substitution in the app entry points:

| today (VersionSet world) | new (ChoiceSet world) |
|---|---|
| `solve hp Root (mkVersion [0])` | `solve combined Root (mkVersion [0] -- Elem ChoiceSet is Choice)` → use a synthetic root `Choice`: `solve combined Root rootChoice` where `rootChoice = Source (ChoiceSource (mkPackageName "root") (mkVersion [0]) Hackage)` |
| `SolverMsg Pkg VS.VersionSet` | `SolverMsg Pkg ChoiceSet` |
| `ReportEnv { rePinned = … hpBoot … }` | `ReportEnv { rePinned = const Nothing, reIsRoot = isRoot }` (boot is now ordinary installed; pinned-explanation can be revisited later) |
| plan value `v :: Version` | `v :: Choice`; render with `pretty`/`PubGrub.Choice.version` |

In `app/Main.hs`, build the `Combined` provider: query `ghc-pkg dump --global`
(reuse `app/Compiler.hs`'s `runTool`/`ghcPkgFromLibdir`), `parseGhcPkgDump`, and
`mkPackageDbProvider GlobalDb pkgs`; build `HackageProvider` via the slimmed
`withHackageProvider`; assemble `Combined db source target range`; call
`runSolve combined`.

`renderSolverMsg`'s `Chose (Pkg n) v` now has `v :: Choice` — render
`name n <> "-" <> pretty v` (so installed choices show `foo-1.5 (installed)`).

- [ ] **Step 5: Build and run; verify against the real compiler**

Run: `cabal build all 2>&1 | grep -iE "error|warning" | grep -v "package list"`
Expected: clean.

Run: `cabal test 2>&1 | grep -iE "tests passed|FAIL"`
Expected: all green (existing 67 + new InstalledDb/PackageDbProvider/Provider).

Manual end-to-end (the real payoff): `cabal run pubgrub-hs -- base` and confirm the
plan reuses installed packages (they render as `(installed)`), and that a target
forcing a newer-than-installed version falls back to source.

- [ ] **Step 6: Commit**

```bash
git add app/Provider.hs test/ProviderSpec.hs app/HackageProvider.hs app/Solver.hs app/Main.hs pubgrub-hs.cabal test/Main.hs
git commit -m "feat: combined installed/source provider over ChoiceSet

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage (Phase 3):**
- PackageDbProvider over `Pow UnitId`, built from the compiler db — Tasks 1, 3. ✓
- Installed deps land in the installed component (exact unit-ids); source deps span
  both worlds (range + installed-in-range) — Task 3 (`depsOf`) + Task 6
  (`liftSourceDep`). ✓
- Combined provider = product, prefer-installed, cross-world lookup in the combiner
  — Task 6. ✓
- Boot pinning folded into the global db — Task 4 (remove `hpBoot`) + Task 6 (db is
  the global db). ✓
- Reporting over `ChoiceSet` (`Pretty`) — Task 5; richer pinned-provenance
  annotations deferred (noted in Task 6 Step 4). ✓
- Wire into `Main` — Task 6. ✓

**Open items flagged for the implementer (not placeholders — judgment calls):**
- Whether `Pkg`/`PackageDbProvider` live in the executable or in `cabal-bridge`
  depends on whether the test-suite can import executable modules; Task 3 Step 2
  gives the fallback (move to `cabal-bridge`).
- `versionOf`'s unreachable fallback (Task 3) — replace with `Maybe` if preferred.
- The "no version for X / provided by the compiler" report wording for boot
  packages changes (boot is now ordinary installed); refine `rePinned` later.

**Type consistency:** `expand` signatures line up — db: `Pkg → Pow UnitId →
Maybe (UnitId, Map Pkg (Pow UnitId))`; source: `Pkg → VersionSet → Maybe (Version,
Map Pkg VersionSet)`; combined: `Pkg → ChoiceSet → Maybe (Choice, Map Pkg
ChoiceSet)`. `installedInRange`/`installedChoice`/`mkPackageDbProvider` names match
across Tasks 3 and 6.
