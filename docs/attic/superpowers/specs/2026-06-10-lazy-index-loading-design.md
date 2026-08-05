# Lazy Index Loading — Design

**Date:** 2026-06-10
**Status:** Approved (pending spec review)
**Scope:** Eliminate the slow upfront index-load. Replace the eager `TVar`-per-entry
database + the separate version-map traversal with a single pure traversal that remembers
each version's `DirectoryEntry`, parsing `.cabal` files on demand.

Builds on the Hackage integration and streaming-tracing milestones.

---

## 1. Problem

`runSolve` does two full traversals of the Hackage index before any decision:

- `mkDatabase` builds `Map PackageName (Map Version (TVar (Entry …)))` — it allocates a
  `TVar` per package-version (`newTVarIO`, an IO action) across the *whole* index
  (~19k packages, far more versions), plus an STM-memoised lazy-parse wrapper.
- `HackageProvider.indexVersions` builds a *second* `Map PackageName [Version]`.

The `TVar` allocation and double traversal are the silent startup cost. `.cabal` parsing
was already lazy and is not the problem.

---

## 2. Approach

One pure traversal of `directoryEntries` produces
`Map PackageName (Map Version DirectoryEntry)` — no `TVar`s, no parsing. Each entry's
package name and version come from the already-decoded `IndexPkgCabal pkgId`
(`pkgName`/`pkgVersion`), so no `.cabal` and no `IndexPath` string parsing is needed.
`.cabal` files are parsed on demand from the remembered `DirectoryEntry` when a version's
dependencies are actually requested.

**No parse cache** (approved): `getDependencies` re-parses a `.cabal` if the same version
is re-decided after a backtrack. That is rare and a single-file parse; a lazy cache can be
added later if profiling shows it matters.

---

## 3. `app/Database.hs`

Add two small definitions:

```haskell
-- | One pure traversal: package -> version -> its index entry. No parsing, no TVars.
indexEntries :: IndexCallbacks -> Map PackageName (Map Version DirectoryEntry)
indexEntries IndexCallbacks{indexDirectory} =
  M.fromListWith (<>)
    [ (pkgName pkgId, M.singleton (pkgVersion pkgId) entry)
    | (entry, _path, msIndexFile) <- directoryEntries indexDirectory
    , Just (Some (IndexPkgCabal pkgId)) <- [msIndexFile] ]

-- | Parse one entry's .cabal on demand.
parseEntry :: IndexCallbacks -> (BSL.ByteString -> Either e a) -> DirectoryEntry -> IO (Either e a)
parseEntry IndexCallbacks{indexLookupEntry} parse entry = do
  (Some ie, _) <- uncheckClientErrors (indexLookupEntry entry)
  pure (parse (indexEntryContent ie))
```

**Delete** the now-dead eager machinery: `mkDatabase`, `Index`, `Entry`, `Database`,
`Decision`, `getOrParse`, `lookupEntryVar`, `traverseIndex`, and the unused imports they
needed (`Control.Concurrent.STM*`, `TVar`/`TMVar`, `Control.Exception (try)`,
`GHC.Generics (Generic)`).

**Keep:** `ParseError`, `Result`, and `extractDepInfo`/`DepInfo` — the latter will be
needed when we tackle `.cabal` conditionals (flags/os/arch), so they stay even though
currently unused.

(`indexEntries` is pure — no `IO` — so its single traversal can be forced exactly where we
want, under the "Loading package index…" note.)

---

## 4. `app/HackageProvider.hs`

Replace the provider's fields:

```haskell
data HackageProvider = HackageProvider
  { hpEntries :: Map PackageName (Map Version DirectoryEntry)
  , hpParse   :: DirectoryEntry -> IO (Either ParseError GenericPackageDescription)
  , hpBoot    :: Map PackageName Version
  , hpTarget  :: PackageName
  , hpRange   :: VersionSet
  }
```

- `chooseVersion hp (Pkg n) range` (non-boot): the highest version satisfying `range`
  among `Map.keys (Map.findWithDefault Map.empty n (hpEntries hp))`.
- `getDependencies hp (Pkg n) v` (non-boot):
  `Map.lookup n (hpEntries hp) >>= Map.lookup v`:
  - `Just entry` → `liftIO (hpParse hp entry)`; `Right gpd` → `Map.mapKeys Pkg (flattenDeps … gpd)`;
    `Left _` → `liftIO (throwIO (ResolveError n v))`.
  - `Nothing` → `liftIO (throwIO (ResolveError n v))` (shouldn't happen — `chooseVersion`
    only returns versions present in `hpEntries`).
- `Root` cases and boot-package handling unchanged.

**Delete** `indexVersions` (its role is now `Map.keys`).

---

## 5. `app/Solver.hs` (`runSolve`)

Replace the `mkDatabase` + `indexVersions` setup:

```haskell
note "\ESC[2mLoading package index…\ESC[0m"
let entries = indexEntries indexCallbacks
    hp = HackageProvider
      { hpEntries = entries
      , hpParse   = parseEntry indexCallbacks parseGPD
      , hpBoot    = boot
      , hpTarget  = target
      , hpRange   = range
      }
    pkgCount = Map.size entries   -- forces the single traversal under this note
note ("\ESC[2m  " <> T.pack (show pkgCount) <> " packages indexed\ESC[0m")
```

(`parseGPD` and `queryBootPackages` are unchanged; `mkDatabase` is no longer called.)

---

## 6. Testing

- `indexEntries`/`parseEntry` need the live index, so no offline unit test. Verified by:
  - `cabal build all` clean (`-Wall`).
  - `cabal run -- lens-5.3.5` still resolves to the same plan, with a noticeably shorter
    "Loading package index…" phase (no `TVar` allocation, single traversal).
- The solver core is untouched, so the 26 tests still pass.

---

## 7. Risks / notes

- **Behavioural equivalence:** the provider still returns the highest in-range version and
  the same flattened deps; only the loading mechanism changes. The `lens-5.3.5` plan should
  be identical before/after.
- **No cache:** re-parse on backtrack re-decide (rare, cheap). Documented; future lazy
  cache possible.
- **Dead code removal:** deleting `mkDatabase` et al. is safe — only `app/Solver.hs` used
  it, and it's being rewired here. `extractDepInfo`/`DepInfo` are deliberately retained for
  future conditional-dependency work.
