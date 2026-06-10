# Startup Banner + Streaming Tracing + name-version Args Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stream conflict/backtrack events live from the solver, add a startup banner + phase notes around the slow index load, and accept `lens-5.3.5` as `lens ==5.3.5`.

**Architecture:** `unitPropagation` becomes monadic with `(Ord p, WithLog env (SolverMsg p) m)` (no `MonadIO`), emitting new `Conflict`/`Backtracked` events the instant they occur; the CLI emits app-level phase notes to stderr and parses the target with Cabal-syntax's `PackageIdentifier`.

**Tech Stack:** GHC 9.12.4; co-log (`WithLog`/`logMsg`); `Cabal`/`Cabal-syntax` (`PackageIdentifier`, version ranges); `time` (`formatTime`).

---

## Environment / verification note

The library + test-suite build offline via `cabal test` (Task 1 fully verifiable). The
executable's deps are now cached, so `cabal build all` and `cabal run` also work offline
(Task 2 verifiable here too).

---

## File Structure

| File | Change |
|------|--------|
| `src/PubGrub/Solver.hs` | `SolverMsg` += `Conflict`/`Backtracked`; `unitPropagation` monadic + streams them; `solve` calls it monadically |
| `test/SolverSpec.hs` | new trace test asserting `Conflict` + `Backtracked` stream during backtracking |
| `app/Solver.hs` | render new events; `note` helper; `runSolve` gains banner/phase notes + index-timestamp param |
| `app/Main.hs` | compute index timestamp; `parseTarget` (name-version synonym); pass timestamp to `runSolve` |

---

## Task 1: Stream conflict/backtrack events from the solver

**Files:** Modify `src/PubGrub/Solver.hs`, `test/SolverSpec.hs`

- [ ] **Step 1: Add the new event constructors**

In `src/PubGrub/Solver.hs`, replace the `SolverMsg` definition:

```haskell
-- | Structured progress events emitted during resolution.
data SolverMsg p
  = Deciding p VersionSet      -- ^ about to choose a version for p within this range
  | Chose p Version            -- ^ picked this version for p
  | NoVersionFor p VersionSet  -- ^ no version available in range (forces a conflict next)
  deriving stock (Eq, Show)
```

with:

```haskell
-- | Structured progress events emitted during resolution.
data SolverMsg p
  = Deciding p VersionSet      -- ^ about to choose a version for p within this range
  | Chose p Version            -- ^ picked this version for p
  | NoVersionFor p VersionSet  -- ^ no version available in range (forces a conflict next)
  | Conflict (Incompatibility p) -- ^ this incompatibility is satisfied (a conflict)
  | Backtracked Int            -- ^ backtracked to this decision level
  deriving stock (Eq, Show)
```

- [ ] **Step 2: Make `unitPropagation` monadic and stream events**

In `src/PubGrub/Solver.hs`, replace the entire `unitPropagation` definition:

```haskell
unitPropagation
  :: Ord p
  => p -> Version
  -> [Incompatibility p]
  -> PartialSolution p
  -> Either (Incompatibility p) ([Incompatibility p], PartialSolution p)
unitPropagation rootPkg rootV = scan
  where
    scan incompats ps = step incompats ps incompats

    -- Walk the worklist of incompatibilities once; on any action, restart scan.
    step incompats ps [] = Right (incompats, ps)   -- fixpoint
    step incompats ps (i : rest) =
      case relation ps i of
        ISatisfied ->
          case conflictResolution rootPkg rootV i ps of
            Left terminal -> Left terminal
            Right (almostPkg, rootCause, ps') ->
              let ps'' = addDerivation almostPkg rootCause ps'
              in scan (rootCause : incompats) ps''
        IAlmostSatisfied q ->
          scan incompats (addDerivation q i ps)
        _ -> step incompats ps rest
```

with (note the `WithLog` constraint and `m` result — and that it stays IO-free):

```haskell
-- | Naïve unit propagation, now streaming 'Conflict'/'Backtracked' events as
-- they happen. The constraint is only @(Ord p, WithLog env (SolverMsg p) m)@ —
-- no @MonadIO@ — so the loop can log but cannot perform real I/O.
unitPropagation
  :: (Ord p, WithLog env (SolverMsg p) m)
  => p -> Version
  -> [Incompatibility p]
  -> PartialSolution p
  -> m (Either (Incompatibility p) ([Incompatibility p], PartialSolution p))
unitPropagation rootPkg rootV = scan
  where
    scan incompats ps = step incompats ps incompats

    -- Walk the worklist of incompatibilities once; on any action, restart scan.
    step incompats ps [] = pure (Right (incompats, ps))   -- fixpoint
    step incompats ps (i : rest) =
      case relation ps i of
        ISatisfied -> do
          logMsg (Conflict i)
          case conflictResolution rootPkg rootV i ps of
            Left terminal -> pure (Left terminal)
            Right (almostPkg, rootCause, ps') -> do
              logMsg (Backtracked (psLevel ps'))
              let ps'' = addDerivation almostPkg rootCause ps'
              scan (rootCause : incompats) ps''
        IAlmostSatisfied q ->
          scan incompats (addDerivation q i ps)
        _ -> step incompats ps rest
```

- [ ] **Step 3: Make `solve` call `unitPropagation` monadically**

In `src/PubGrub/Solver.hs`, in the `solve` definition, replace the `go` opening:

```haskell
    go incompats ps =
      case unitPropagation rootPkg rootV incompats ps of
        Left terminal -> pure (Left (NoSolution terminal))
        Right (incompats', ps') ->
```

with:

```haskell
    go incompats ps = do
      result <- unitPropagation rootPkg rootV incompats ps
      case result of
        Left terminal -> pure (Left (NoSolution terminal))
        Right (incompats', ps') ->
```

(The rest of `go` — `undecidedPositive`, the `Deciding`/`Chose`/`NoVersionFor` logs,
`chooseVersion`/`getDependencies` — is unchanged. Indentation of the `case` body shifts
right by two spaces to sit under the `do`.)

- [ ] **Step 4: Verify the library offline-builds**

Run: `cabal build pubgrub-hs:lib:pubgrub-hs 2>&1 | tail -5`
Expected: compiles, no errors/warnings. (If GHC complains `psLevel` is not in scope, note
it is a field of `PartialSolution` and already exported via `PartialSolution (..)`.)

- [ ] **Step 5: Add a streaming-trace test**

In `test/SolverSpec.hs`, add this `testCase` as the **last element** of the `testGroup
"Solver"` list — insert it (with its leading comma) immediately before the list's closing
`]`, so the block below ends with that same `]`:

```haskell
  , testCase "trace streams Conflict and Backtracked during backtracking" $ do
      ref <- newIORef ([] :: [SolverMsg String])
      let r = reg
            [ ("root", [([1], [("a", VS.full), ("b", geq [2])])])
            , ("a", [ ([2], [("b", VS.fromVersionRange (Distribution.Version.earlierVersion (mkVersion [2])))])
                    , ([1], [("b", VS.full)]) ])
            , ("b", [ ([2], []), ([1], []) ])
            ]
          collect = LogAction (\m -> modifyIORef' ref (++ [m]))
      _ <- usingLoggerT collect (solve r "root" (v [1]))
      evs <- readIORef ref
      assertBool ("expected a Conflict event, got: " ++ show evs)
        (not (null [() | Conflict _ <- evs]))
      assertBool ("expected a Backtracked event, got: " ++ show evs)
        (not (null [() | Backtracked _ <- evs]))
  ]
```

- [ ] **Step 6: Run the suite (offline)**

Run: `cabal test --test-show-details=direct 2>&1 | grep -E "streams Conflict|All .* tests|FAIL"`
Expected: `trace streams Conflict and Backtracked during backtracking: OK` and all tests
pass (26 total). The `Conflict`/`Backtracked` events appear because the `a@2 → b<2` choice
conflicts with `root`'s `b>=2`, forcing a backtrack to `a@1`.

- [ ] **Step 7: Commit**

```bash
git add src/PubGrub/Solver.hs test/SolverSpec.hs
git commit -m "feat: stream Conflict/Backtracked events from monadic unitPropagation"
```

---

## Task 2: CLI banner, phase notes, conflict rendering, name-version args

**Files:** Modify `app/Solver.hs`, `app/Main.hs`

- [ ] **Step 1: Add imports to `app/Solver.hs`**

In `app/Solver.hs`, add these imports alongside the existing ones:

```haskell
import Data.Time.Clock (UTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import PubGrub.Types (Term (..), incompTerms)
```

- [ ] **Step 2: Replace `renderSolverMsg` in `app/Solver.hs`**

Replace the existing `renderSolverMsg` definition with:

```haskell
renderSolverMsg :: SolverMsg Pkg -> Text
renderSolverMsg msg = case msg of
  Deciding (Pkg n) r     -> "\ESC[2mdeciding " <> name n <> " " <> showRange r <> "\ESC[0m"
  Chose (Pkg n) v        -> "  \ESC[32m\x2713\ESC[0m " <> name n <> "-" <> showVer v
  NoVersionFor (Pkg n) r -> "  \ESC[31m\x2717\ESC[0m no version for " <> name n <> " in " <> showRange r
  Conflict i             -> "  \ESC[33m\x26A0\ESC[0m conflict: " <> renderIncompat i
  Backtracked n          -> "  \ESC[2m\x21A9 backtracking to level " <> T.pack (show n) <> "\ESC[0m"
  _                      -> ""  -- Root payloads: no output
  where
    name = T.pack . prettyShow
    showVer = T.pack . prettyShow
    showRange = T.pack . prettyShow . VS.toVersionRange
    renderIncompat i = T.intercalate ", " [ renderTerm p t | (p, t) <- Map.toList (incompTerms i) ]
    renderTerm Root _              = "root"
    renderTerm (Pkg n) (Positive r) = name n <> " " <> showRange r
    renderTerm (Pkg n) (Negative r) = name n <> " not " <> showRange r
```

- [ ] **Step 3: Replace `runSolve` in `app/Solver.hs`**

Replace the entire `runSolve` definition (signature through its `where`) with:

```haskell
-- | Resolve the dependency closure of @target@ within @range@, printing a
-- startup banner and phase notes to stderr and the plan to stdout. Runs in 'App'.
runSolve :: UTCTime -> IndexCallbacks -> PackageName -> VersionSet -> App ()
runSolve idxTime indexCallbacks target range = do
  note ("\ESC[1mSolving for " <> T.pack (prettyShow target) <> " "
          <> T.pack (prettyShow (VS.toVersionRange range))
          <> " (index from "
          <> T.pack (formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC" idxTime)
          <> ")\ESC[0m")
  note "\ESC[2mQuerying GHC boot packages\x2026\ESC[0m"
  boot <- liftIO queryBootPackages
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
  outcome <-
    try (solve hp Root (mkVersion [0]))
      :: App (Either ResolveError (Either (SolveError Pkg) (Map Pkg Version)))
  case outcome of
    Left (ResolveError n v) ->
      liftIO (putStrLn ("Failed to parse " ++ prettyShow n ++ "-" ++ prettyShow v))
    Right (Left (NoSolution i)) -> liftIO $ do
      putStrLn "No solution:"
      putStrLn (reportConflict i)
    Right (Right plan) -> do
      liftIO $ do
        putStrLn "Resolved:"
        mapM_ putPlanLine (Map.toList plan)
      note ("\ESC[2mResolved "
              <> T.pack (show (length [() | (Pkg _, _) <- Map.toList plan]))
              <> " packages\ESC[0m")
  where
    putPlanLine (Root, _)  = pure ()
    putPlanLine (Pkg n, v) = putStrLn ("  " ++ prettyShow n ++ " => " ++ prettyShow v)

-- | Emit an app-level note (banner / phase / summary) to stderr.
note :: Text -> App ()
note t = liftIO (TIO.hPutStrLn stderr t)
```

(`pkgCount` is used by the following `note`, which forces it — so the expensive version-map
traversal happens under the "Loading package index…" label rather than silently during the
first decision.)

- [ ] **Step 4: Update `app/Main.hs` imports**

In `app/Main.hs`, change `import Distribution.PackageDescription (mkPackageName)` to:

```haskell
import Distribution.PackageDescription (PackageName, mkPackageName)
```

and add:

```haskell
import Distribution.Types.PackageId (PackageIdentifier (..))
import Distribution.Version (versionNumbers)
```

(`getModificationTime`, `(</>)`, `fragment`, `UTCTime`, `eitherParsec`, `VersionRange`,
`PubGrub.VersionSet qualified as VS`, and `Solver (runSolve, solverSink, hackageSink)` are
already imported.)

- [ ] **Step 5: Replace `main` in `app/Main.hs` and add `parseTarget`**

Replace the `main` definition with:

```haskell
main :: IO ()
main = do
  manager <- liftIO $ newManager defaultManagerSettings
  cache <- mkCache <$> makeAbsolute (fromFilePath "_cache")
  args <- getArgs
  case parseTarget args of
    Nothing -> putStrLn "usage: pubgrub-hs <package>[-<version>] [version-range]"
    Just (target, range) ->
      usingLoggerT solverSink $
        withHackage cache manager (liftIO . unLogAction hackageSink) $ \repository ->
          withIndex repository $ \indexCallbacks -> do
            idxTime <- liftIO (getModificationTime (cacheRoot cache </> fragment "01-index.tar"))
            runSolve idxTime indexCallbacks target range

-- | Parse CLI args into a target package and version range. A single
-- @name-version@ arg (e.g. @lens-5.3.5@) means @== version@; a bare name means
-- any version; @<name> <range>@ uses an explicit Cabal version range.
parseTarget :: [String] -> Maybe (PackageName, VS.VersionSet)
parseTarget [one] =
  case eitherParsec one :: Either String PackageIdentifier of
    Right (PackageIdentifier n v)
      | null (versionNumbers v) -> Just (n, VS.full)
      | otherwise               -> Just (n, VS.singleton v)
    Left _ -> Just (mkPackageName one, VS.full)
parseTarget (name : r : _) =
  case eitherParsec r :: Either String VersionRange of
    Right vr -> Just (mkPackageName name, VS.fromVersionRange vr)
    Left _   -> Nothing
parseTarget [] = Nothing
```

- [ ] **Step 6: Build everything (offline; deps cached)**

Run: `cabal build all 2>&1 | tail -6`
Expected: library, `cabal-bridge`, and executable compile, `-Wall`-clean. If `Term`/
`incompTerms` are reported out of scope in `app/Solver.hs`, confirm Step 1's
`import PubGrub.Types (Term (..), incompTerms)` was added.

- [ ] **Step 7: Smoke-test the CLI**

Run: `cabal run -v0 pubgrub-hs -- lens-5.3.5 2>&1 | head -20`
Expected: a bold `Solving for lens ==5.3.5 (index from …)` banner, dim
`Querying GHC boot packages…` / `Loading package index… / N packages indexed` notes, then
streamed `deciding`/`✓`/`⚠ conflict`/`↩ backtracking` lines, ending with `Resolved:` +
`Resolved N packages`.
Also run: `cabal run -v0 pubgrub-hs -- lens-5.3.5 2>/dev/null` — expected: only the
`Resolved:` plan on stdout.
And: `cabal run -v0 pubgrub-hs -- lens '>=5 && <6' 2>/dev/null | head` — expected: a plan
(confirms two-arg form still works).

- [ ] **Step 8: Commit**

```bash
git add app/Solver.hs app/Main.hs
git commit -m "feat: startup banner, phase notes, conflict rendering, name-version args"
```

---

## Out of scope (future)

- Per-resolution-step tracing (making `conflictResolution` monadic).
- TTY detection / `--no-color`; `--quiet`/`-v` verbosity.
- Rendering the full `VS.full` range as `any` rather than `>=0`.
