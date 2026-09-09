{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}

-- | A minimal end-to-end driver: resolve a Hackage package's dependency
-- closure with the native PubGrub solver, over a real (lazily read) index.
--
-- @cabal run pubgrub -- aeson@  (optionally a version range: @... aeson '>=2'@)
--
-- Everything runs in one 'App' monad whose environment carries two co-log
-- channels — @Text@ (the bridge's own messages and the provider's warnings)
-- and 'SolverMsg' (the solver's search trace). The @Text@ channel always
-- renders to stdout; the trace only under @--verbose@ (see 'Verbosity'), and
-- under @--stats@ it is folded into counters instead of, or as well as, being
-- rendered (see 'Stats').
module Main (main) where

import           Bridge.Cabal.Baseline                     (defaultSolverConfig,
                                                            outcome,
                                                            solveWithCabal,
                                                            sourcePackageIndex)
import           Bridge.Hackage                            (IndexState (..),
                                                            IndexStateTooNew (..),
                                                            mkCache,
                                                            parseIndexState)
import           Bridge.Provider                           (World (..),
                                                            rootInstance,
                                                            rootName,
                                                            withProvider,
                                                            withWorld)
import           Colog                                     (HasLog (..),
                                                            LogAction (..),
                                                            cmap, logMsg)
import           Control.Monad                             (when)
import           Control.Monad.Reader                      (MonadReader,
                                                            ReaderT, runReaderT)
import           Data.IORef                                (IORef,
                                                            atomicModifyIORef',
                                                            newIORef, readIORef)
import           Data.List                                 (intercalate, sortOn)
import           Data.Map.Strict                           (Map)
import qualified Data.Map.Strict                           as Map
import           Data.Set                                  (Set)
import qualified Data.Set                                  as Set
import           Data.Text                                 (Text)
import qualified Data.Text                                 as T
import qualified Data.Text.IO                              as TIO
import           Distribution.Package                      (packageId)
import           Distribution.Parsec                       (eitherParsec)
import           Distribution.Pretty                       (prettyShow)
import qualified Distribution.Solver.Types.ComponentDeps   as CD
import           Distribution.Solver.Types.ResolverPackage (ResolverPackage (..))
import           Distribution.Solver.Types.SolverPackage   (SolverPackage (..))
import           Distribution.Types.Flag                   (showFlagAssignment)
import           Distribution.Types.PackageId              (pkgName, pkgVersion)
import           Distribution.Types.PackageName            (PackageName)
import           Distribution.Types.VersionRange           (VersionRange,
                                                            anyVersion)
import           GHC.Clock                                 (getMonotonicTime)
import           Hackage.Security.Util.Path                (fromFilePath,
                                                            makeAbsolute)
import           Network.HTTP.Client                       (defaultManagerSettings,
                                                            newManager)
import           Options.Applicative                       (Parser, argument,
                                                            eitherReader,
                                                            execParser, flag,
                                                            fullDesc, header,
                                                            help, helper, info,
                                                            long, metavar,
                                                            option, progDesc,
                                                            short, switch,
                                                            value)
import           PubGrub.Incompatibility                   (IncompatCause (..),
                                                            Incompatibility,
                                                            incompCause,
                                                            incompTerms)
import           PubGrub.InstanceSet                       (HasVersion (version),
                                                            Instance (..),
                                                            singletonInstance)
import           PubGrub.Pretty                            (Pretty (pretty))
import           PubGrub.Provider                          (Provider (..))
import           PubGrub.Report                            (reportConflict,
                                                            reportHeadline,
                                                            styleProof, wrapProof)
import           PubGrub.Solver                            (SolveError (..),
                                                            SolverMsg (..),
                                                            solve)
import           PubGrub.VersionSet                        (fromVersionRange)
import           System.Environment                        (lookupEnv)
import           System.Exit                               (exitFailure)
import           System.IO                                 (hIsTerminalDevice,
                                                            hPutStrLn, stderr,
                                                            stdout)
import           Text.Printf                               (printf)
import           Text.Read                                 (readMaybe)
import           UnliftIO                                  (MonadIO (liftIO), handle,
                                                            MonadUnliftIO,
                                                            evaluate)

-- --------------------------------------------------------------------------
-- The application monad: two log channels rendered to stdout
-- --------------------------------------------------------------------------

-- | How much of the run to narrate. Only the solver trace is switched: the
-- @Text@ channel is a handful of lines (index status, the read counts) and
-- carries the answer itself, so it always prints.
--
-- The trace defaults to /off/ so that a run can be timed without a terminal in
-- the measurement: @aeson '<2'@ emits 3396 lines with it and 179 without. Note
-- that the saving is in the /rendering/, not in the solve — redirected to a
-- file the two are the same speed within run-to-run noise. Turn it on with
-- @-v@ when you want to watch or count the search.
data Verbosity = Normal | Verbose
    deriving stock (Eq, Show)

data Env = Env
    { envText   :: LogAction App Text
    , envSolver :: LogAction App SolverMsg
    }

newtype App a = App {unApp :: ReaderT Env IO a}
    deriving newtype (Functor, Applicative, Monad, MonadIO, MonadUnliftIO, MonadReader Env)

instance HasLog Env Text App where
    getLogAction = envText
    setLogAction a e = e {envText = a}

instance HasLog Env SolverMsg App where
    getLogAction = envSolver
    setLogAction a e = e {envSolver = a}

toStdout :: LogAction App Text
toStdout = LogAction (liftIO . TIO.putStrLn)

runApp :: LogAction App SolverMsg -> App a -> IO a
runApp solverLog app = runReaderT (unApp app) Env {envText = toStdout, envSolver = solverLog}

-- | What to do with each 'SolverMsg'. The two switches are independent, so
-- @-v --stats@ both renders the trace and counts it: 'LogAction' is a
-- 'Semigroup' and @<>@ runs both actions on every message.
--
-- 'mempty' is co-log's do-nothing action. The solver still constructs each
-- 'SolverMsg' (one constructor application, with unforced fields) but nothing
-- renders it, so the cost that matters for a timed run — pretty-printing an
-- 'Incompatibility' and writing a line — is gone.
solverLogAction :: Verbosity -> Maybe (IORef Stats) -> LogAction App SolverMsg
solverLogAction verbosity counters = trace <> maybe mempty countInto counters
  where
    trace = case verbosity of
        Verbose -> cmap renderSolverMsg toStdout
        Normal  -> mempty

renderSolverMsg :: SolverMsg -> Text
renderSolverMsg (Deciding pn is) = T.pack "Deciding " <> pretty pn <> T.pack " among " <> pretty is
renderSolverMsg (Chose pn i) = T.pack "Chose " <> pretty pn <> T.pack " as " <> pretty i
renderSolverMsg (Conflict incompatibility) =
    T.pack "Conflict " <> prettyIncompat incompatibility
renderSolverMsg (Resolving pn incompatibility) =
    T.pack "  resolving at " <> pretty pn <> T.pack " -> " <> prettyIncompat incompatibility
renderSolverMsg (Learned incompatibility) =
    T.pack "Learned " <> prettyIncompat incompatibility
renderSolverMsg (Backtracked level) = T.pack ("Backtracked to level " <> show level)
renderSolverMsg (NoVersionFor pn is) =
    T.pack "No version available for " <> pretty pn <> T.pack " in " <> pretty is

-- | An incompatibility on one line, as its terms. Deliberately not
-- 'PubGrub.Report.reportConflict', which renders a whole numbered proof — that is
-- the right thing for a failure and far too much for a trace event.
prettyIncompat :: Incompatibility -> Text
prettyIncompat i =
    T.pack "{"
        <> T.intercalate
            (T.pack ", ")
            [pretty p <> T.pack " " <> pretty t | (p, t) <- Map.toList (incompTerms i)]
        <> T.pack "}"

-- --------------------------------------------------------------------------
-- Counting the search without rendering it
-- --------------------------------------------------------------------------

-- | The search counters, event for event the ones @bench/summarise.awk@ derives
-- from a @-v@ trace, so that the two can be checked against each other
-- (@scripts/check-stats.sh@). They are counted in-process, so a run without
-- @-v@ is counted too.
--
-- The depth histogram needs one bit of state, exactly as the awk keeps it: a
-- 'Resolving' between a 'Conflict' and its 'Learned' deepens that resolution,
-- and one outside is counted but deepens nothing.
data Stats = Stats
    { stDeciding     :: !Int
    , stChose        :: !Int
    , stNoVersion    :: !Int
    , stConflicts    :: !Int
    , stResolving    :: !Int
    , stLearned      :: !Int
    , stBacktracked  :: !Int
    , stDepth        :: !Int
    -- ^ 'Resolving' events since the last 'Conflict'
    , stInResolution :: !Bool
    -- ^ between a 'Conflict' and its 'Learned'
    , stHistogram    :: !(Map Int Int)
    -- ^ resolution depth, read off at each 'Learned', to how many resolutions
    -- reached exactly that depth
    }

emptyStats :: Stats
emptyStats =
    Stats
        { stDeciding = 0
        , stChose = 0
        , stNoVersion = 0
        , stConflicts = 0
        , stResolving = 0
        , stLearned = 0
        , stBacktracked = 0
        , stDepth = 0
        , stInResolution = False
        , stHistogram = Map.empty
        }

count :: SolverMsg -> Stats -> Stats
count msg st = case msg of
    Deciding {} -> st {stDeciding = stDeciding st + 1}
    Chose {} -> st {stChose = stChose st + 1}
    NoVersionFor {} -> st {stNoVersion = stNoVersion st + 1}
    Conflict {} -> st {stConflicts = stConflicts st + 1, stDepth = 0, stInResolution = True}
    Resolving {} ->
        st
            { stResolving = stResolving st + 1
            , stDepth = if stInResolution st then stDepth st + 1 else stDepth st
            }
    Learned {} ->
        st
            { stLearned = stLearned st + 1
            , stHistogram = Map.insertWith (+) (stDepth st) 1 (stHistogram st)
            , stInResolution = False
            }
    Backtracked {} -> st {stBacktracked = stBacktracked st + 1}

-- | Fold every message into the counters. The 'IORef' is the seam: the solver
-- already hands each 'SolverMsg' to a 'LogAction', and updating a strict record
-- is the cheapest thing such an action can do with it.
countInto :: IORef Stats -> LogAction App SolverMsg
countInto ref = LogAction (\msg -> liftIO (atomicModifyIORef' ref (\st -> (count msg st, ()))))

-- | One line, all integers, read by the harness field by name. The read
-- counters (parses, decodes, cache hits) are not here: the provider prints
-- them on its own closing line, and that line is read by name too.
--
-- Not one of the connectives a proof line opens with, and not containing
-- @no version for@: @scripts/gate.sh@ counts proof lines by those.
renderStats :: Stats -> Text
renderStats st =
    T.pack $
        unwords
            [ "stats:"
            , "deciding=" ++ show (stDeciding st)
            , "chose=" ++ show (stChose st)
            , "conflicts=" ++ show (stConflicts st)
            , "learned=" ++ show (stLearned st)
            , "resolving=" ++ show (stResolving st)
            , "backtracked=" ++ show (stBacktracked st)
            , "noversion=" ++ show (stNoVersion st)
            , "depth=" ++ intercalate "," [show k ++ ":" ++ show c | (k, c) <- Map.toAscList (stHistogram st)]
            ]

-- | Wall-clock seconds spent in each phase of one run. Only the child can
-- separate these, because only it knows where the phases are.
data Phases = Phases
    { phWorld  :: !Double
    -- ^ opening the index, the installed db and the pkg-config db
    , phIndex  :: !Double
    -- ^ cabal's 'sourcePackageIndex'; always zero for ours, which has no such
    -- step. See 'runBaseline' for what this does and does not include
    , phSolve  :: !Double
    -- ^ the solve, until its verdict is known
    , phRender :: !Double
    -- ^ printing the answer, plan or proof
    }

renderPhases :: Phases -> Text
renderPhases p =
    T.pack (printf "phases: world=%.3f index=%.3f solve=%.3f render=%.3f" (phWorld p) (phIndex p) (phSolve p) (phRender p))

-- --------------------------------------------------------------------------
-- Argument parsing
-- --------------------------------------------------------------------------

-- | Which solver to run. Both are fed from a world opened the same way
-- ('Bridge.Provider.withWorld'), so this switches the solver and nothing else.
data Which = Ours | Cabal
    deriving stock (Eq, Show)

-- | How to render a plan. 'Tree' is for people; 'Lines' is one @plan:@ line
-- per resolved package, sorted by name, so that two plans can be diffed.
-- Failures render the same way under both.
data PlanShape = Tree | Lines
    deriving stock (Eq, Show)

data Options = Options
    { optVerbosity  :: Verbosity
    , optStats      :: Bool
    , optPlan       :: PlanShape
    , optWhich      :: Which
    , optIndexState :: IndexState
    -- ^ which moment of the index both solvers see; 'IndexHead' unless
    -- @--index-state@ says otherwise. It is the one thing that makes a run
    -- repeatable across the weekly refresh.
    , optTarget    :: PackageName
    , optRange     :: VersionRange
    -- ^ the same constraint unconverted: cabal's solver takes a 'VersionRange',
    -- ours a 'VersionSet', and both must come from the one argument
    }

parseTarget :: String -> Either String PackageName
parseTarget = eitherParsec

parseRange :: String -> Either String VersionRange
parseRange = eitherParsec

parsePlan :: String -> Either String PlanShape
parsePlan "tree"  = Right Tree
parsePlan "lines" = Right Lines
parsePlan other   = Left ("expected 'tree' or 'lines', got '" ++ other ++ "'")

optionsParser :: Parser Options
optionsParser =
    Options
        <$> flag Normal Verbose (short 'v' <> long "verbose" <> help "Print the solver trace")
        <*> switch (long "stats" <> help "Count the search events in-process and print them, with the phase timings, after the answer")
        <*> option (eitherReader parsePlan) (long "plan" <> metavar "tree|lines" <> value Tree <> help "Render a plan as a dependency tree (default) or as one 'plan:' line per package")
        <*> flag Ours Cabal (long "cabal" <> help "Run cabal's solver instead of the native solver")
        <*> option (eitherReader parseIndexState) (long "index-state" <> metavar "TIMESTAMP" <> value IndexHead <> help "Solve against the index as it was at this time, e.g. 2016-09-24T17:47:48Z, as cabal's --index-state does (default: everything the local index holds, refreshed at most weekly)")
        <*> argument (eitherReader parseTarget) (metavar "PACKAGE")
        <*> argument (eitherReader parseRange) (value anyVersion <> metavar "VERSION-RANGE")

-- --------------------------------------------------------------------------
-- Driver
-- --------------------------------------------------------------------------

main :: IO ()
main = do
    handle tooNew $ work =<< execParser (info (helper <*> optionsParser) infoMod)
    where
        infoMod = fullDesc <>
                  progDesc "Resolve a Hackage package's dependency closure" <>
                  header "pubgrub - a Hackage dependency resolver"
        -- An index-state the local index cannot honour: say why on stderr and
        -- fail, without a backtrace.
        tooNew (IndexStateTooNew msg) = hPutStrLn stderr msg >> exitFailure
        work opts = do
            let target = optTarget opts
            cache <- mkCache <$> makeAbsolute (fromFilePath "_cache")
            manager <- newManager defaultManagerSettings
            counters <-
                if optStats opts
                    then Just <$> newIORef emptyStats
                    else pure Nothing
            -- The world phase starts here: everything before this line is
            -- argument parsing and two allocations.
            t0 <- getMonotonicTime
            runApp (solverLogAction (optVerbosity opts) counters) $ case optWhich opts of
                -- The provider needs the root's targets up front: it is asked to
                -- expand the root like any other package, but has no index entry
                -- to look its dependencies up in.
                Ours ->
                    withProvider cache manager (optIndexState opts) [(target, fromVersionRange (optRange opts))] $ \provider ->
                        runOurs opts t0 counters provider
                Cabal ->
                    withWorld cache manager (optIndexState opts) $ \world ->
                        runBaseline opts t0 world

-- | Solve with the native solver, render the answer, and — under @--stats@ —
-- the counters and the phase timings after it. Those two lines come before the
-- provider's closing read-counter line, which 'withProvider' prints on the way
-- out.
runOurs :: Options -> Double -> Maybe (IORef Stats) -> Provider App -> App ()
runOurs opts t0 counters provider = do
    t1 <- liftIO getMonotonicTime
    logMsg (T.pack ("Solving for " ++ prettyShow (optTarget opts)))
    tSolve <- liftIO getMonotonicTime
    -- 'evaluate' pins the end of the solve phase to the verdict, so the boundary
    -- does not depend on how lazily 'solve' builds its result.
    result <- evaluate =<< solve provider rootName rootInstance
    tRender <- liftIO getMonotonicTime
    report (optPlan opts) provider result
    tEnd <- liftIO getMonotonicTime
    case counters of
        Nothing -> pure ()
        Just ref -> do
            st <- liftIO (readIORef ref)
            logMsg (renderStats st)
            logMsg
                ( renderPhases
                    Phases
                        { phWorld = t1 - t0
                        , phIndex = 0
                        , phSolve = tRender - tSolve
                        , phRender = tEnd - tRender
                        }
                )

-- | Run cabal's solver over the same world and render its answer in the same
-- shape ours is rendered in: a plan, or the solver's own failure text.
--
-- Both solvers' indexes come from one 'World' (see @Bridge.Cabal.Baseline@).
-- Ours reads a @.cabal@ only when it expands a package, while cabal's wants a
-- 'SourcePackage' record for every release in the index before it starts.
-- 'sourcePackageIndex' is called here rather than inside 'solveWithCabal' so
-- that the two costs can be measured apart.
--
-- What the @index@ phase measures needs care, though. 'sourcePackageIndex' runs
-- one 'IO' action per release (~153k 'SourcePackage' records, each with a
-- deferred parse), but the 'PackageIndex' over them is built lazily when the
-- solver first looks a package up, and every @.cabal@ parse happens on demand
-- inside the solve. So @index@ is the record allocation only, and most of what
-- STATUS.md §3.3 calls cabal's index cost lands in @solve@. Forcing the index
-- here would move the number, not the work — and would change what is being
-- measured, since a solve that never touches most of the index would then pay
-- for all of it.
--
-- @stats: steps=N@ is cabal's one search counter: the log steps of its
-- 'Progress', which 'outcome' counts rather than keeps.
runBaseline :: Options -> Double -> World -> App ()
runBaseline opts t0 world = do
    t1 <- liftIO getMonotonicTime
    logMsg (T.pack ("Solving for " ++ prettyShow (optTarget opts) ++ " (cabal's solver)"))
    tIndex <- liftIO getMonotonicTime
    sourceIdx <- liftIO (sourcePackageIndex (wIndex world))
    tSolve <- liftIO getMonotonicTime
    let progress =
            solveWithCabal
                defaultSolverConfig
                (wPlatform world)
                (wCompiler world)
                (wInstalled world)
                (wPkgConfig world)
                sourceIdx
                [(optTarget opts, optRange opts)]
        (steps, lazyResult) = outcome progress
    -- Forcing the 'Either' walks the whole 'Progress': that is the solve. The
    -- step count is a chain of increments left behind by the same walk, so it
    -- is known too, and forcing it later costs nothing worth timing.
    result <- evaluate lazyResult
    tRender <- liftIO getMonotonicTime
    case result of
        Left err -> do
            logMsg (T.pack ("cabal found no plan after " ++ show steps ++ " log steps:"))
            logMsg (T.pack err)
        Right plan -> do
            logMsg (T.pack ("cabal's plan (" ++ show steps ++ " log steps):"))
            case optPlan opts of
                Tree  -> mapM_ (mapM_ (logMsg . T.pack) . renderResolved) (sortOn resolvedName plan)
                Lines -> mapM_ (logMsg . planLine) (sortOn packageId plan)
    tEnd <- liftIO getMonotonicTime
    when (optStats opts) $ do
        logMsg (T.pack ("stats: steps=" ++ show steps))
        logMsg
            ( renderPhases
                Phases
                    { phWorld = t1 - t0
                    , phIndex = tSolve - tIndex
                    , phSolve = tRender - tSolve
                    , phRender = tEnd - tRender
                    }
            )
  where
    resolvedName p = prettyShow (pkgName (packageId p))

    -- One resolved package on one line, in the shape 'planLines' gives ours.
    -- Sorted by name and then version because a package may legitimately appear
    -- twice (see 'renderResolved'); the qualifier does not survive into a
    -- 'ResolverPackage', so nothing here says which domain each copy is from.
    planLine p =
        T.pack $
            unwords
                [ "plan:"
                , prettyShow (pkgName (packageId p))
                , prettyShow (pkgVersion (packageId p))
                , case p of
                    PreExisting _ -> "installed"
                    Configured _  -> "source"
                ]

    -- A plan entry with the /component/ each of its dependencies belongs to.
    --
    -- Do not flatten this to a package list. cabal solves __qualified goals__: a
    -- setup or executable dependency is solved in its own domain, so @Setup.hs@
    -- may be built against a different @mtl@ than the library, and one plan can
    -- legitimately name two versions of a package.
    -- 'Distribution.Solver.Modular.modularResolver' applies @convCP@ on the way
    -- out, which strips the qualifiers from the /identities/, but the component
    -- structure survives in each package's 'ComponentDeps', which is what this
    -- prints. @setup:@ lines are the other domain.
    renderResolved p = case p of
        PreExisting _ -> ["  " ++ prettyShow (packageId p) ++ " (installed)"]
        Configured sp ->
            ("  " ++ prettyShow (packageId p) ++ flags sp)
                : [ "      " ++ component c ++ ": " ++ unwords (map (prettyShow . packageId) ids)
                  | (c, ids) <- CD.toList (CD.zip (solverPkgLibDeps sp) (solverPkgExeDeps sp)) >>= split
                  , not (null ids)
                  ]
      where
        split (c, (libs, exes)) = [(c, libs), (c, exes)]

    flags sp = case showFlagAssignment (solverPkgFlags sp) of
        "" -> ""
        fa -> " [" ++ fa ++ "]"

    component CD.ComponentLib     = "lib"
    component CD.ComponentSetup   = "setup"
    component (CD.ComponentExe n) = "exe:" ++ prettyShow n
    component c                   = show c

report :: PlanShape -> Provider App -> Either SolveError (Map PackageName Instance) -> App ()
report _ _ (Left (NoSolution incompat)) = do
    width <- liftIO proofWidth
    style <- liftIO proofStyle
    logMsg (style (wrapProof width (reportHeadline incompat)))
    logMsg T.empty
    logMsg (style (wrapProof width (reportConflict incompat)))
report _ _ (Left (NoSatisfier p _)) =
    logMsg (T.pack ("internal error: no satisfier for " ++ prettyShow p))
report shape provider (Right solution) = do
    logMsg (T.pack "Solution:")
    case shape of
        Tree -> do
            children <- dependencyMap provider solution
            mapM_ logMsg (renderTree solution children)
        Lines -> mapM_ logMsg (planLines solution)

-- | The width a proof is wrapped to. The terminal's own, from @COLUMNS@, when
-- stdout is one; 80 otherwise, so a proof in a log or in the showcase is wrapped
-- the same way on every machine. (@COLUMNS@ is a shell variable that most shells
-- do not export, so on a terminal the answer is usually 80 too.)
proofWidth :: IO Int
proofWidth = do
    tty <- hIsTerminalDevice stdout
    cols <- lookupEnv "COLUMNS"
    pure $ case (tty, cols >>= readMaybe) of
        (True, Just n) | n >= 40 -> n
        _                        -> 80

-- | Colour for the proof on a terminal, and none anywhere else: stdout a terminal,
-- @NO_COLOR@ unset (<https://no-color.org>), @TERM@ not @dumb@. The gate, the
-- harness and every log read the plain text.
proofStyle :: IO (Text -> Text)
proofStyle = do
    tty <- hIsTerminalDevice stdout
    noColor <- lookupEnv "NO_COLOR"
    term <- lookupEnv "TERM"
    pure $ if tty && noColor == Nothing && term /= Just "dumb" then styleProof else id

-- | One resolved package per line, sorted by name — the 'Map' already is. The
-- synthetic root is the solver's, not the plan's, so it is left out.
planLines :: Map PackageName Instance -> [Text]
planLines solution =
    [ T.pack (unwords ["plan:", prettyShow pn, prettyShow (version inst), kind inst])
    | (pn, inst) <- Map.toList (Map.delete rootName solution)
    ]
  where
    kind (UsePreInstalled _) = "installed"
    kind (BuildSource _ _)   = "source"

-- | Who does @pn@'s decided instance depend on, per the solution? Re-asks the
-- provider for the exact instance the solver already committed to — 'expand'
-- is deterministic on a singleton offered set, so this recovers the same
-- dependency incompatibilities the solve itself derived, without the solver
-- having to hand back its internal store.
--
-- Keep only the edges @pn@ itself declares: on an installed unit the provider
-- returns every edge of the unit's /transitive/ closure at once, and those
-- deeper edges belong under their own depender, which the same walk reaches on
-- its own turn.
dependencyMap :: Provider App -> Map PackageName Instance -> App (Map PackageName [PackageName])
dependencyMap provider solution =
    Map.fromList <$> mapM childrenOf (Map.toList solution)
  where
    childrenOf (pn, inst) = do
        (_, incs) <- expand provider pn (singletonInstance inst)
        let deps =
                [ d
                | inc <- incs
                , CauseDependency p _ (d, _) <- [incompCause inc]
                , p == pn
                ]
        pure (pn, deps)

-- | Render the solution as a dependency tree from the synthetic root, in the
-- style of @cargo tree@. A dependency graph is a DAG, not a tree: a shared
-- dependency like @base@ has many parents, and printing its subtree under each
-- would blow up the output. So a subtree is printed once, and @(*)@ marks every
-- later occurrence of its package.
renderTree :: Map PackageName Instance -> Map PackageName [PackageName] -> [Text]
renderTree solution children =
    label rootName : snd (goChildren (Set.singleton rootName) T.empty (childrenOf rootName))
  where
    label pn = maybe (T.pack (prettyShow pn)) (renderChoice pn) (Map.lookup pn solution)
    childrenOf pn = sortOn prettyShow (Map.findWithDefault [] pn children)

    -- Threads 'seen' through the whole render (not just down one branch) so a
    -- package printed in full under an earlier sibling is recognised as
    -- already-shown under a later one.
    goChildren :: Set PackageName -> Text -> [PackageName] -> (Set PackageName, [Text])
    goChildren seen _ [] = (seen, [])
    goChildren seen prefix [k] = goOne seen prefix k True
    goChildren seen prefix (k : ks) =
        let (seen1, ls1) = goOne seen prefix k False
            (seen2, ls2) = goChildren seen1 prefix ks
        in (seen2, ls1 ++ ls2)

    goOne :: Set PackageName -> Text -> PackageName -> Bool -> (Set PackageName, [Text])
    goOne seen prefix pn isLast
        | pn `Set.member` seen = (seen, [line True])
        | otherwise =
            let seen' = Set.insert pn seen
                childPrefix = prefix <> (if isLast then T.pack "   " else T.pack "│  ")
                (seenFinal, childLines) = goChildren seen' childPrefix (childrenOf pn)
            in (seenFinal, line False : childLines)
      where
        connector = T.pack (if isLast then "└─ " else "├─ ")
        line alreadySeen = prefix <> connector <> label pn <> (if alreadySeen then T.pack " (*)" else T.empty)

-- | One node's label. A source release is shown with the flag assignment it
-- was decided under, because a different assignment is a different build. A
-- pre-installed unit is shown as such: it is already built, with no flags to
-- choose.
renderChoice :: PackageName -> Instance -> Text
renderChoice p (UsePreInstalled i) = T.pack $ unwords [prettyShow p, prettyShow (version i), "(installed)"]
renderChoice p (BuildSource v fa) = T.pack $ unwords ([prettyShow p, prettyShow v] ++ [showFlagAssignment fa | not (null (showFlagAssignment fa))])
