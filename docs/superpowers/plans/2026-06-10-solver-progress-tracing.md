# Solver Progress Tracing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Emit live, decision-level progress to stderr during `solve`, via co-log contravariant logging.

**Architecture:** The core `solve` gains a `WithLog env (SolverMsg p) m` constraint and emits a structured `SolverMsg`; the Hackage provider generalizes from `IO` to `MonadIO m`; the CLI runs in `LoggerT (SolverMsg Pkg) IO`, rendering messages (and Hackage-security log messages) onto one stderr sink via `(>$<)`.

**Tech Stack:** GHC 9.12.4; `co-log-0.7.0.0` / `co-log-core-0.3.2.7` (`WithLog`, `logMsg`, `LoggerT`, `LogAction`, `(>$<)`); `text`.

---

## Confirmed facts (probed against the installed packages)

- `LoggerT msg m = ReaderT (LogAction (LoggerT msg m) msg) m`; `usingLoggerT :: Monad m => LogAction m msg -> LoggerT msg m a -> m a`.
- `WithLog env msg m = (MonadReader env m, HasLog env msg m, HasCallStack)`; `logMsg :: WithLog env msg m => msg -> m ()`. (`MonadReader` has fundep `m -> env`, so `env` is determined by `m`; no ambiguity from a constraint-only `env`.)
- `instance Applicative m => Monoid (LogAction m a)` — `mempty :: LogAction m msg` is the no-op sink.
- `(>$<) :: (a -> b) -> LogAction m b -> LogAction m a` (contravariant map).
- The local `withRepository` wrapper takes its logger as `(LogMessage -> m ())` (a plain function), so pass `unLogAction hackageSink`.

## Environment / verification note

`co-log` is NOT a boot lib but IS in the cabal store (from the executable build), so the library + test-suite build offline via **`cabal test`** (Tasks 1–3 fully verifiable in-sandbox). The executable (Tasks 4–5) needs `hackage-security` etc. and is built/run **on the user's machine**; `HackageProvider` (Task 4) gets a visual review only.

---

## File Structure

| File | Change |
|------|--------|
| `pubgrub-hs.cabal` | add `co-log` to `library` and `test-suite` build-depends |
| `src/PubGrub/Solver.hs` | add `SolverMsg`, `WithLog` on `solve`, `logMsg` calls |
| `test/SolverSpec.hs` | provider → `Monad m`; `solve` calls via `usingLoggerT mempty`; new trace test |
| `app/HackageProvider.hs` | instance `IO` → `MonadIO m` |
| `app/Solver.hs` | `App` monad, sinks, `renderSolverMsg`, `runSolve` in `App` |
| `app/Main.hs` | `withHackage` takes an explicit logger; wire `usingLoggerT solverSink` |

---

## Task 1: Add co-log dependency

**Files:** Modify `pubgrub-hs.cabal`

- [ ] **Step 1: Add `co-log` to the `library` stanza**

In the `library` stanza's `build-depends`, add a line:

```cabal
        , co-log
```

so it reads:
```cabal
    build-depends:
        , base ^>=4.21.0.0
        , containers
        , Cabal-syntax
        , text
        , co-log
```

- [ ] **Step 2: Add `co-log` to the `test-suite` stanza**

In `test-suite pubgrub-hs-test` `build-depends`, add:

```cabal
        , co-log
```

- [ ] **Step 3: Verify the library still configures/builds (offline)**

Run: `cabal build pubgrub-hs:lib:pubgrub-hs 2>&1 | tail -5`
Expected: builds (no new code yet — just the dependency resolves from the store).

- [ ] **Step 4: Commit**

```bash
git add pubgrub-hs.cabal
git commit -m "chore: depend on co-log for solver tracing"
```

---

## Task 2: SolverMsg + WithLog on solve

**Files:** Modify `src/PubGrub/Solver.hs`, `test/SolverSpec.hs`

- [ ] **Step 1: Enable FlexibleContexts and import co-log in the solver**

At the top of `src/PubGrub/Solver.hs`, add the pragma line (with the other `{-# LANGUAGE #-}` lines):

```haskell
{-# LANGUAGE FlexibleContexts #-}
```

And add this import (with the other imports):

```haskell
import Colog (WithLog, logMsg)
```

- [ ] **Step 2: Add `SolverMsg` to the export list**

In the module export list of `src/PubGrub/Solver.hs`, under the `-- * Solve` section, add `SolverMsg (..)`:

```haskell
    -- * Solve
  , SolveError (..)
  , SolverMsg (..)
  , solve
```

- [ ] **Step 3: Define `SolverMsg` and make `solve` log**

In `src/PubGrub/Solver.hs`, replace the `solve` definition (the `solve :: ...` signature through the end of its `where go` block) with:

```haskell
-- | Structured progress events emitted during resolution.
data SolverMsg p
  = Deciding p VersionSet      -- ^ about to choose a version for p within this range
  | Chose p Version            -- ^ picked this version for p
  | NoVersionFor p VersionSet  -- ^ no version available in range (forces a conflict next)
  deriving stock (Eq, Show)

-- | Solve for a root package pinned to @rootV@. Returns a complete assignment
-- or a 'SolveError'. Emits decision-level progress via co-log.
solve
  :: (DependencyProvider dp p m, WithLog env (SolverMsg p) m)
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
              logMsg (Deciding p range)
              mv <- chooseVersion dp p range
              case mv of
                Nothing -> do
                  logMsg (NoVersionFor p range)
                  go (noVersions p range : incompats') ps'
                Just v -> do
                  logMsg (Chose p v)
                  deps <- getDependencies dp p v
                  let depIncs =
                        [ fromDependency p (VS.singleton v) (q, r)
                        | (q, r) <- Map.toList deps ]
                  go (depIncs ++ incompats') (addDecision p v ps')
```

- [ ] **Step 4: Update the test provider to be monad-polymorphic**

In `test/SolverSpec.hs`, change the instance head from:

```haskell
instance DependencyProvider Registry String Identity where
```
to:
```haskell
instance Monad m => DependencyProvider Registry String m where
```

(The method bodies already use `pure`; leave them unchanged.)

- [ ] **Step 5: Add the co-log import to the test**

In `test/SolverSpec.hs`, add:

```haskell
import Colog (usingLoggerT)
```

(`Data.Functor.Identity (Identity, runIdentity)` is already imported.)

- [ ] **Step 6: Wrap the five `solve` call sites in a no-op logger**

In `test/SolverSpec.hs`, replace each `runIdentity (solve r "root" (v [1]))` with `runIdentity (usingLoggerT mempty (solve r "root" (v [1])))`. There are five occurrences (trivial, transitive, backtracking — direct; and the two unsat cases inside `case … of`). Use `grep -n "solve r" test/SolverSpec.hs` to confirm all five are wrapped.

- [ ] **Step 7: Build + run the suite (offline)**

Run: `cabal test --test-show-details=direct 2>&1 | tail -15`
Expected: all 24 tests still PASS (only the logging wrapper changed; behavior identical).

- [ ] **Step 8: Commit**

```bash
git add src/PubGrub/Solver.hs test/SolverSpec.hs
git commit -m "feat: emit decision-level SolverMsg progress via co-log"
```

---

## Task 3: Trace assertion test

**Files:** Modify `test/SolverSpec.hs`

- [ ] **Step 1: Add imports for an accumulating sink**

In `test/SolverSpec.hs`, add:

```haskell
import Data.IORef (newIORef, readIORef, modifyIORef')
import Colog (LogAction (..))
```

(Keep the existing `import Colog (usingLoggerT)`; you may merge them into `import Colog (LogAction (..), usingLoggerT)`.)

- [ ] **Step 2: Add the trace test to the `tests` list**

In `test/SolverSpec.hs`, add this `testCase` to the `testGroup "Solver"` list (e.g. after the "trivial" case):

```haskell
  , testCase "trace emits Chose events for resolved packages" $ do
      ref <- newIORef []
      let r = reg [ ("root", [([1], [("a", VS.full)])])
                  , ("a",    [([1], [])]) ]
          collect = LogAction (\m -> modifyIORef' ref (++ [m]))
      _ <- usingLoggerT collect (solve r "root" (v [1]))
      evs <- readIORef ref
      assertBool ("expected Chose for root and a, got: " ++ show evs)
        (Chose "root" (v [1]) `elem` evs && Chose "a" (v [1]) `elem` evs)
```

(Here `solve` runs in `LoggerT (SolverMsg String) IO`; `collect` accumulates emitted messages into an `IORef`.)

- [ ] **Step 3: Run the suite (offline)**

Run: `cabal test --test-show-details=direct 2>&1 | grep -E "trace emits|All .* tests"`
Expected: `trace emits Chose events for resolved packages: OK` and all tests pass (25 now).

- [ ] **Step 4: Commit**

```bash
git add test/SolverSpec.hs
git commit -m "test: assert solver emits Chose trace events"
```

---

## Task 4: Generalize the Hackage provider to MonadIO

**Files:** Modify `app/HackageProvider.hs`

> Verification: this module imports `hackage-security`, unavailable in the sandbox — it is built by the user (Task 5's build). The agent does a visual check only.

- [ ] **Step 1: Add the MonadIO import**

In `app/HackageProvider.hs`, add:

```haskell
import Control.Monad.IO.Class (MonadIO, liftIO)
```

- [ ] **Step 2: Generalize the instance and `liftIO` the effects**

In `app/HackageProvider.hs`, replace the whole instance:

```haskell
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

with:

```haskell
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
                (Map.findWithDefault [] n (hpVersions hp))))

  getDependencies hp pkg v = case pkg of
    Root -> pure (Map.singleton (Pkg (hpTarget hp)) (hpRange hp))
    Pkg n
      | Map.member n (hpBoot hp) -> pure Map.empty
      | otherwise -> do
          res <- liftIO (hpLookup hp (PackageIdentifier n v))
          case res of
            Right gpd -> pure (Map.mapKeys Pkg (flattenDeps thePlatform theCompiler gpd))
            Left _    -> liftIO (throwIO (ResolveError n v))
```

(`throwIO` and `Control.Exception` are already imported.)

- [ ] **Step 3: Commit**

```bash
git add app/HackageProvider.hs
git commit -m "refactor: HackageProvider works in any MonadIO"
```

---

## Task 5: CLI wiring (App monad, sinks, rendering)

**Files:** Rewrite `app/Solver.hs`; modify `app/Main.hs`

> Verification: built and run by the user (executable). Do NOT run `cabal build` of the exe in the sandbox.

- [ ] **Step 1: Rewrite `app/Solver.hs`**

Replace the ENTIRE contents of `app/Solver.hs` with:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Solver
  ( App
  , runSolve
  , solverSink
  , hackageSink
  ) where

import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString.Lazy as BSL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.IO (stderr)

import Colog (LogAction (..), LoggerT, (>$<))

import Distribution.PackageDescription (GenericPackageDescription, PackageName)
import Distribution.PackageDescription.Parsec (parseGenericPackageDescription, runParseResult)
import Distribution.Pretty (prettyShow)
import Distribution.Version (Version, mkVersion)

import Hackage.Security.Client (IndexCallbacks, LogMessage)
import Hackage.Security.Util.Pretty (pretty)

import UnliftIO (try)

import BootPackages (queryBootPackages)
import Database (ParseError (..), mkDatabase)
import HackageProvider (HackageProvider (..), Pkg (..), ResolveError (..), indexVersions)
import PubGrub.Solver (SolveError (..), SolverMsg (..), reportConflict, solve)
import qualified PubGrub.VersionSet as VS
import PubGrub.VersionSet (VersionSet)

-- | The CLI's logging monad: solver progress messages over IO.
type App = LoggerT (SolverMsg Pkg) IO

-- | Base sink: write non-empty lines to stderr. Lives in the BASE monad 'IO' —
-- that is what 'usingLoggerT' (and withRepository's logger) consume.
baseSink :: LogAction IO Text
baseSink = LogAction $ \t -> unless (T.null t) (TIO.hPutStrLn stderr t)

-- | Solver-progress sink (passed to 'usingLoggerT' by Main).
solverSink :: LogAction IO (SolverMsg Pkg)
solverSink = renderSolverMsg >$< baseSink

-- | Hackage-security message sink. Main passes @liftIO . unLogAction hackageSink@
-- to withRepository so it runs in the 'App' monad.
hackageSink :: LogAction IO LogMessage
hackageSink = (T.pack . pretty) >$< baseSink

renderSolverMsg :: SolverMsg Pkg -> Text
renderSolverMsg msg = case msg of
  Deciding (Pkg n) r     -> "\ESC[2mdeciding " <> name n <> " " <> showRange r <> "\ESC[0m"
  Chose (Pkg n) v        -> "  \ESC[32m\x2713\ESC[0m " <> name n <> "-" <> showVer v
  NoVersionFor (Pkg n) r -> "  \ESC[31m\x2717\ESC[0m no version for " <> name n <> " in " <> showRange r
  _                      -> ""  -- Root events: no output
  where
    name = T.pack . prettyShow
    showVer = T.pack . prettyShow
    showRange = T.pack . prettyShow . VS.toVersionRange

-- | Resolve the dependency closure of @target@ within @range@ and print the
-- plan (or a derivation tree on failure). Runs in the logging monad 'App'.
runSolve :: IndexCallbacks -> PackageName -> VersionSet -> App ()
runSolve indexCallbacks target range = do
  dblookup <- liftIO (mkDatabase indexCallbacks parseGPD)
  boot <- liftIO queryBootPackages
  let hp = HackageProvider
        { hpVersions = indexVersions indexCallbacks
        , hpLookup   = dblookup
        , hpBoot     = boot
        , hpTarget   = target
        , hpRange    = range
        }
  outcome <-
    try (solve hp Root (mkVersion [0]))
      :: App (Either ResolveError (Either (SolveError Pkg) (Map Pkg Version)))
  case outcome of
    Left (ResolveError n v) ->
      liftIO (putStrLn ("Failed to parse " ++ prettyShow n ++ "-" ++ prettyShow v))
    Right (Left (NoSolution i)) -> liftIO $ do
      putStrLn "No solution:"
      putStrLn (reportConflict i)
    Right (Right plan) -> liftIO $ do
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

- [ ] **Step 2: Update `app/Main.hs` imports**

In `app/Main.hs`, remove the import line `import Hackage.Security.Util.Pretty (Pretty (..))` (no longer used in Main). Change the `Solver` import to:

```haskell
import Solver (runSolve, solverSink, hackageSink)
```

- [ ] **Step 3: Rewrite `main` to use the sinks**

In `app/Main.hs`, replace the `main` function body's logger/withHackage block. The `main` should read:

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
            [] -> VS.full
            (r : _) -> case eitherParsec r :: Either String VersionRange of
              Right vr -> VS.fromVersionRange vr
              Left err -> error ("invalid version range: " ++ err)
      usingLoggerT solverSink $
        withHackage cache manager (liftIO . unLogAction hackageSink) $ \repository ->
          withIndex repository $ \indexCallbacks ->
            runSolve indexCallbacks target range
    [] -> putStrLn "usage: pubgrub-hs <package> [version-range]"
```

- [ ] **Step 4: Delete the now-unused `logMessageAction`**

In `app/Main.hs`, delete this definition entirely:

```haskell
logMessageAction :: (MonadIO m) => LogAction m LogMessage
logMessageAction = LogAction (liftIO . putStrLn . pretty)
```

- [ ] **Step 5: Update `withHackage` to take an explicit logger**

In `app/Main.hs`, replace the `withHackage` definition with:

```haskell
withHackage ::
  (MonadUnliftIO m) =>
  Cache -> Manager -> (LogMessage -> m ()) -> (Repository RemoteTemp -> m a) -> m a
withHackage cache manager logAction act =
  withClient manager $ \httpLib ->
    withRepository httpLib [uri] cache logAction $ \repository -> do
      uncheckClientErrors $ liftIO $ do
        rb <- requiresBootstrap repository
        when rb $ bootstrap repository [] (KeyThreshold 0)
        now <- getCurrentTime
        _ <- checkForUpdates repository (Just now)
        pure ()
      act repository
  where
    uri = parseURI "http://hackage.haskell.org"
```

(`WithLog`/`logMsg` are no longer used in Main; `Colog.Monad` is still imported for `usingLoggerT`, and `Colog (LogAction (..))` for `unLogAction`.)

- [ ] **Step 6: Commit**

```bash
git add app/Solver.hs app/Main.hs
git commit -m "feat: stream solver progress to stderr via co-log sinks"
```

---

## Task 6: Build & integration verification (user machine)

**Files:** none.

- [ ] **Step 1: Build everything**

Run: `cabal build all`
Expected: library, `cabal-bridge`, executable, and test-suite compile. New code should be `-Wall`-clean.

- [ ] **Step 2: Run the tests**

Run: `cabal test --test-show-details=direct`
Expected: all tests pass (incl. the trace test).

- [ ] **Step 3: See progress on a real solve**

Run: `cabal run pubgrub-hs -- lens`
Expected: dim `deciding …` lines and green `✓ name-version` lines stream to stderr as packages resolve; the final `Resolved:` plan prints on stdout. Confirm `cabal run pubgrub-hs -- lens 2>/dev/null` shows only the plan (progress is on stderr).

- [ ] **Step 4: Final commit (if integration needed tweaks)**

```bash
git add -A
git commit -m "chore: progress-tracing integration fixups"
```

---

## Out of scope (future)

- Conflict/backtrack tracing (needs threading events out of pure propagation).
- Verbosity flag / `--quiet`; TTY detection / `--no-color`.
- Severity levels, timestamps, structured/JSON logs.
- Solver performance.
