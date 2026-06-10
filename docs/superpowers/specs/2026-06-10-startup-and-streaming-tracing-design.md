# Startup Banner, Streaming Conflict/Backtrack Tracing, and `name-version` Args — Design

**Date:** 2026-06-10
**Status:** Approved (pending spec review)
**Scope:** Improve CLI UX for slow solves: (1) a startup banner + phase notes around the
silent index-load phase, (2) live streaming of conflict/backtrack events from inside the
solver, (3) accept `lens-5.3.5` as a synonym for `lens ==5.3.5`.

Builds on the co-log tracing milestone
(`docs/superpowers/specs/2026-06-10-solver-progress-tracing-design.md`).

---

## 1. Motivation

`cabal run pubgrub-hs -- lens '==5.3.5'` sits silent for a long time, then prints all the
decisions at once. The silent wait is the eager index load: `mkDatabase` allocates a
`TVar` per package-version over the whole Hackage index, and the lazy version map is
forced on the first `chooseVersion` — all before any decision. Decisions then stream
fast. So the fixes are: label the startup phases, and surface the solver's conflict
search live.

---

## 2. Two message channels

- **Solver events** — emitted from the library via co-log `logMsg` as `SolverMsg`,
  including the new conflict/backtrack events. Streamed live from inside the solver.
- **App phase notes** — emitted from `runSolve`/`Main` as plain dim stderr lines via a
  small `note :: Text -> App ()`. These are orchestration (startup banner, "loading
  index", summary), not solver internals, so they are NOT `SolverMsg`.

Both go to stderr; the resolved plan stays on stdout.

---

## 3. Streaming conflict/backtrack tracing (solver core becomes monadic, stays IO-free)

Extend the event type (in `PubGrub.Solver`):

```haskell
data SolverMsg p
  = Deciding p VersionSet
  | Chose p Version
  | NoVersionFor p VersionSet
  | Conflict (Incompatibility p)   -- NEW: a satisfied incompatibility (a conflict)
  | Backtracked Int                -- NEW: backtracked to this decision level
  deriving (Eq, Show)
```

Make `unitPropagation` **monadic so it streams events as they occur** — not accumulate
and return them (which would still batch). Its constraint is exactly
`(Ord p, WithLog env (SolverMsg p) m)` — **no `MonadIO`**: the type guarantees the
propagation loop can only emit log messages through the abstract logging interface, never
perform real I/O. Purity-in-the-sense-that-matters is preserved by the abstract `m`.

```haskell
unitPropagation
  :: (Ord p, WithLog env (SolverMsg p) m)
  => p -> Version
  -> [Incompatibility p]
  -> PartialSolution p
  -> m (Either (Incompatibility p) ([Incompatibility p], PartialSolution p))
```

Behaviour: the scan loop runs in `m`; when it finds a satisfied incompatibility it
`logMsg (Conflict i)` before resolving, and after `conflictResolution` returns it
`logMsg (Backtracked (psLevel ps'))`. The recursion threads `m` via `do`/`>>=`.

`conflictResolution` stays **pure** (its returned partial solution carries the backtracked
level, which `unitPropagation` reads for the `Backtracked` event). It could be made
monadic later for per-resolution-step tracing, but that is out of scope here.

`solve` already carries `WithLog`; it now calls `unitPropagation` monadically:

```haskell
go incompats ps = do
  result <- unitPropagation rootPkg rootV incompats ps   -- streams Conflict/Backtracked live
  case result of
    Left terminal -> pure (Left (NoSolution terminal))
    Right (incompats', ps') -> case undecidedPositive ps' of
      []              -> pure (Right (extractSolution ps'))
      ((p, range): _) -> do
        logMsg (Deciding p range)
        ...
```

So `Conflict`/`Backtracked` interleave chronologically with `Deciding`/`Chose`/
`NoVersionFor`, all streamed at the moment they happen. Only `solve` (already monadic)
consumes `unitPropagation`; the change is behaviour-preserving under a no-op logger, so
the existing scenario tests still pass.

---

## 4. Startup banner + phase notes (app)

`runSolve` gains the index timestamp argument:

```haskell
runSolve :: UTCTime -> IndexCallbacks -> PackageName -> VersionSet -> App ()
```

`Main` computes the timestamp with `getModificationTime (cacheRoot cache </> fragment "01-index.tar")`
(it already locates that file for the weekly-refresh throttle) and passes it in.

`note :: Text -> App ()` writes a dim line to stderr (reusing the stderr sink style).

Sequence emitted by `runSolve`:

1. Banner: `Solving for <name> <range> (index from <YYYY-MM-DD HH:MM UTC>)`.
   `<range>` rendered via `prettyShow . toVersionRange`; `<time>` via `formatTime` (UTC).
2. `note "Querying GHC boot packages…"` then `queryBootPackages`.
3. `note "Loading package index…"`, build the provider, then **force** the version map
   (`let !n = Map.size (hpVersions hp)`) so the expensive traversal happens under this
   label, then `note ("  " <> n <> " packages indexed")`.
4. Solve (streams the per-step events from §3).
5. On success: after the `Resolved:` plan, `note ("Resolved " <> k <> " packages")` where
   `k` counts the non-`Root` decisions.

This turns the silent wait into labelled phases.

---

## 5. `lens-5.3.5` ⇒ `lens ==5.3.5` (request #3)

Argument parsing in `Main`, using Cabal-syntax parsers (per the project rule to parse
Cabal types with Cabal-syntax, never hand-roll):

- **one arg** → `eitherParsec arg :: Either String PackageIdentifier`:
  - `Right (PackageIdentifier n v)` with non-null `v` (`not (null (versionNumbers v))`)
    → target `n`, range `VS.singleton v` (i.e. `==v`). Handles `lens-5.3.5`.
  - `Right (PackageIdentifier n _)` with null version → target `n`, range `VS.full`.
    Handles `lens`.
  - `Left _` → fall back to `mkPackageName arg`, range `VS.full`.
- **two args** → `mkPackageName arg1` + `eitherParsec arg2 :: VersionRange`
  → `VS.fromVersionRange` (current behaviour, e.g. `lens '>=5 && <6'`). Invalid range
  prints a usage/error message.
- **no args** → usage.

So `lens-5.3.5`, `lens`, and `lens '==5.3.5'` all resolve correctly.

---

## 6. Rendering (ANSI)

App `renderSolverMsg` gains:
- `Conflict i` → yellow: `"  \ESC[33m⚠\ESC[0m conflict: " <> terms` where `terms` is the
  compact render of `incompTerms i` as `name range, name range…` (reusing `showRange` and
  `prettyShow` on package names; `Root` terms shown as `root`).
- `Backtracked n` → dim: `"  \ESC[2m↩ backtracking to level " <> n <> "\ESC[0m"`.

Phase notes (`note`) render dim. Existing `Deciding`/`Chose`/`NoVersionFor` lines
unchanged.

---

## 7. Testing

- **Library (offline):** extend the trace test — run the backtracking scenario
  (`root → a(any), b(>=2)`; `a@2` needs `b<2`) collecting `SolverMsg`s, and assert that a
  `Conflict _` and a `Backtracked _` event are emitted (in addition to the `Chose`
  events). All existing scenario tests still pass at the no-op logger.
- **App (now buildable here):** `cabal build all` clean; `cabal run -- lens-5.3.5` shows
  the banner, phase notes, streamed decisions/conflicts/backtracks on stderr, and the plan
  on stdout; `cabal run -- lens-5.3.5 2>/dev/null` shows only the plan.

---

## 8. Risks / notes

- **Monadic `unitPropagation` touches the verified core.** Mitigated: the change is
  behaviour-preserving under a no-op logger, covered by the existing scenario tests plus
  the new conflict/backtrack assertions; the constraint adds only `WithLog` (no `MonadIO`).
- **Forcing the version map under the "loading" note** does the same work that was
  previously deferred to first `chooseVersion`; net time is unchanged, just relabelled.
- **`Conflict` carries a full `Incompatibility`** — fine for a trace line; the compact
  renderer shows only its terms, not the derivation tree.
- Conflict-resolution per-step tracing (making `conflictResolution` monadic) is deferred.
