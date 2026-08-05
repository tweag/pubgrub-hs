# Solver Progress Tracing (co-log) — Design

**Date:** 2026-06-10
**Status:** Approved (pending spec review)
**Scope:** Give the solver live progress output during resolution, via co-log contravariant logging. Decision-level events to stderr, always on.

Builds on the Hackage integration
(`docs/superpowers/specs/2026-06-10-hackage-integration-design.md`).

---

## 1. Goal & non-goals

**Goal.** While `solve` runs (notably the slow `cabal run pubgrub-hs -- lens` case),
emit a line per resolution step to stderr so the user sees progress and the search
working. Use co-log: the core `solve` gains a `WithLog` constraint and emits a
structured `SolverMsg`; the app renders it to stderr.

**Non-goals (deferred):**

- Tracing conflicts / backtracks (they happen inside the pure `unitPropagation` /
  `conflictResolution`, which stay untouched this round).
- Solver performance (watched literals, contradicted-incompatibility cache) — orthogonal.
- A `--quiet`/`-v` verbosity flag (always-on for now).
- Structured/JSON log output, log levels/severity, timestamps.

---

## 2. co-log API in use (co-log-0.7.0.0 / co-log-core-0.3.2.7, GHC 9.12.4)

- `LoggerT msg m` = `ReaderT (LogAction (LoggerT msg m) msg) m`.
- `usingLoggerT :: Monad m => LogAction m msg -> LoggerT msg m a -> m a`.
- `WithLog env msg m = (MonadReader env m, HasLog env msg m, HasCallStack)`.
- `logMsg :: WithLog env msg m => msg -> m ()`.
- `LogAction m msg = LogAction { unLogAction :: msg -> m () }`; contravariant.
- `cmap`, `(>$<) :: (a -> b) -> LogAction m b -> LogAction m a` (adapt a sink to a new
  input type). `(<&) :: LogAction m msg -> msg -> m ()` (log directly).
- `HasLog env msg m` has **no functional dependency** (an env may serve multiple msg
  types) — noted, but not needed given the single-sink wiring below.

---

## 3. Library: `SolverMsg` and a `WithLog` constraint on `solve`

In `src/PubGrub/Solver.hs`:

```haskell
-- | Structured progress events emitted during resolution.
data SolverMsg p
  = Deciding p VersionSet      -- about to choose a version for p within this range
  | Chose p Version            -- picked this version for p
  | NoVersionFor p VersionSet  -- no version available in range (forces a conflict next)
  deriving (Eq, Show)

solve
  :: (DependencyProvider dp p m, WithLog env (SolverMsg p) m)
  => dp -> p -> Version
  -> m (Either (SolveError p) (Map p Version))
```

The monadic `go` loop emits, at the decision point only (propagation untouched):
- `logMsg (Deciding p range)` immediately before `chooseVersion dp p range`;
- on `Just v`: `logMsg (Chose p v)`;
- on `Nothing`: `logMsg (NoVersionFor p range)`.

`SolverMsg` is **structured** — the library does no rendering (so no `Pretty`/`Show`
dependency on `p` beyond what `Package` already gives). `SolverMsg`, `Deciding`,
`Chose`, `NoVersionFor` are exported from `PubGrub.Solver`.

**New library dependency:** `co-log` (for `WithLog`/`logMsg`/`LoggerT`). Added to the
`library` stanza's `build-depends`.

---

## 4. Provider: generalize `IO` → `MonadIO m`

`HackageProvider`'s instance head changes from `DependencyProvider HackageProvider Pkg IO`
to:

```haskell
instance MonadIO m => DependencyProvider HackageProvider Pkg m where
  chooseVersion hp pkg range = pure (...)                 -- unchanged body, already pure
  getDependencies hp pkg v = case pkg of
    ...
    Pkg n | otherwise -> do
      res <- liftIO (hpLookup hp (PackageIdentifier n v))   -- liftIO the index lookup
      case res of
        Right gpd -> pure (Map.mapKeys Pkg (flattenDeps thePlatform theCompiler gpd))
        Left _    -> liftIO (throwIO (ResolveError n v))     -- liftIO the throw
```

This lets `solve` run inside the app's `LoggerT (SolverMsg Pkg) IO` (a `MonadIO`).
`MonadIO` is imported (e.g. `Control.Monad.IO.Class`); `HackageProvider.hs` gains
`{-# LANGUAGE FlexibleContexts #-}` if needed for the constraint.

The in-memory test provider becomes provider-monad-polymorphic:

```haskell
instance Monad m => DependencyProvider Registry String m where
  chooseVersion (Registry regMap) p range = pure (...)
  getDependencies (Registry regMap) p ver = pure (...)
```

---

## 5. App wiring — one stderr sink, two contravariant adapters

Run the CLI action in `LoggerT (SolverMsg Pkg) IO`. Build one base text sink and adapt
both producers onto it with `(>$<)`:

```haskell
type App = LoggerT (SolverMsg Pkg) IO

baseSink :: LogAction App Text
baseSink = LogAction (liftIO . Data.Text.IO.hPutStrLn stderr)

solverSink :: LogAction App (SolverMsg Pkg)
solverSink = renderSolverMsg >$< baseSink          -- passed to usingLoggerT

hackageSink :: LogAction App LogMessage
hackageSink = (Data.Text.pack . pretty) >$< baseSink  -- pretty :: LogMessage -> String
```

Top-level flow (in `app/Main.hs` / `app/Solver.hs`):

```haskell
usingLoggerT solverSink $
  withHackage cache manager hackageSink $ \repository ->
    withIndex repository $ \indexCallbacks ->
      runSolve indexCallbacks target range
```

- `solve` gets `WithLog env (SolverMsg Pkg) App` from `LoggerT`'s reader env.
- **`withHackage` is decoupled from `WithLog`:** it takes `hackageSink` explicitly and
  passes `unLogAction hackageSink` (a `LogMessage -> App ()`) to `withRepository` in place
  of co-log's `logMsg`. Its constraint drops from `(MonadUnliftIO m, WithLog env LogMessage m)`
  to just `MonadUnliftIO m`, plus the new `LogAction m LogMessage` argument.
- `runSolve :: (MonadUnliftIO m, MonadIO m, WithLog env (SolverMsg Pkg) m) => IndexCallbacks
  -> PackageName -> VersionSet -> m ()`. It builds the `HackageProvider`, calls `solve`,
  and uses `UnliftIO.try` (the logger monad over IO is `MonadUnliftIO`) to catch
  `ResolveError`. The final plan / `No solution:` tree prints to **stdout**
  (`liftIO . putStrLn`), keeping stderr for progress.

Both message streams thus land on stderr through the same `baseSink`, each adapted by a
single `>$<`. No dual-`HasLog` env is needed.

---

## 6. Rendering (ANSI, faint `Deciding`)

`renderSolverMsg :: SolverMsg Pkg -> Text` (in the app; it knows `p = Pkg` and can
`prettyShow` names/versions). Raw ANSI SGR escapes, no extra dependency:

| Event | Output |
|-------|--------|
| `Deciding (Pkg n) r` | `"\ESC[2mdeciding " <> name <> " " <> showRange r <> "\ESC[0m"` (dim) |
| `Chose (Pkg n) v` | `"  \ESC[32m✓\ESC[0m " <> name <> "-" <> ver` |
| `NoVersionFor (Pkg n) r` | `"  \ESC[31m✗\ESC[0m no version for " <> name <> " in " <> showRange r` |
| any `Root` payload | `""` (skipped — empty line suppressed by rendering to `Text` and the sink dropping empties, or by emitting nothing) |

`showRange` renders the `VersionSet` (via `prettyShow . toVersionRange`, or the interval
`Show`). Names/versions via `Distribution.Pretty.prettyShow`. The base sink skips empty
`Text` (so `Root` events produce no line).

---

## 7. Testing

- **Existing solver scenarios (18):** `solve` now requires `WithLog`. Run them in a no-op
  logging monad: `runIdentity (usingLoggerT mempty (solve r "root" (v [1])))` —
  `mempty :: LogAction m msg` discards. (`LogAction` is a `Monoid` given `Applicative m`.)
  All 18 must still pass. The `Registry` instance is `instance Monad m =>
  DependencyProvider Registry String m`, so it works at `LoggerT (SolverMsg String) Identity`.
- **New trace test (offline):** run a small scenario collecting emitted messages and assert
  the sequence/contents. Use a `LogAction` writing into an `IORef`/`Writer`, e.g. run in
  `LoggerT (SolverMsg String) IO` with `LogAction (\m -> liftIO (modifyIORef ref (m:)))`,
  solve a 2-package scenario, and assert `Chose "a" (mkVersion [1])` is among the events.
  Lives in a new `test/TraceSpec.hs` (or appended to `SolverSpec`). Needs no Cabal/network.
- **Library typecheck:** `ghc`/`cabal build` of the library with the new `co-log` dep —
  this requires `co-log` (NOT a boot lib; already in the store from the executable build),
  so a plain `ghc -fno-code -package Cabal-syntax` no longer suffices; use
  `cabal build pubgrub-hs:lib:pubgrub-hs` (offline, deps cached).
- **Integration:** `cabal run pubgrub-hs -- lens` shows dim `deciding …` lines and
  `✓ name-version` as packages resolve, with the plan on stdout — manual, user machine.

---

## 8. Risks

- **co-log in the core library.** Adds `co-log` (and transitively `co-log-core`) to the
  previously-light `library`. Accepted by the user; it's the chosen tracing mechanism.
- **`LogAction` `Monoid`/`mempty` for the no-op test path** — relies on the `Applicative m`
  `Monoid (LogAction m msg)` instance; confirmed part of co-log-core.
- **ANSI on non-TTY / Windows.** Escapes print literally if stderr isn't a TTY. Acceptable
  for a first cut (always-on); a TTY check or `--no-color` is a later refinement.
- **`withRepository` logger argument type.** The exact type the unlifted `withRepository`
  expects for its logger (a `LogAction m LogMessage` vs a `LogMessage -> m ()`) is confirmed
  at implementation time against `app/Hackage/Security/Unlifted.hs`; pass whichever it wants
  (`hackageSink` or `unLogAction hackageSink`).
