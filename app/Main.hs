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
-- renders to stdout; the trace only under @--verbose@ (see 'Verbosity').
module Main (main) where

import           Bridge.Cabal.Baseline           (defaultSolverConfig, outcome,
                                                  solveWithCabal,
                                                  sourcePackageIndex)
import           Bridge.Hackage                  (mkCache)
import           Bridge.Provider                 (World (..), rootInstance,
                                                  rootName, withProvider,
                                                  withWorld)
import           Colog                           (HasLog (..), LogAction (..),
                                                  cmap, logMsg)
import           Control.Monad.Reader            (MonadReader, ReaderT,
                                                  runReaderT)
import           Data.List                       (sortOn)
import           Data.Map.Strict                 (Map)
import qualified Data.Map.Strict                 as Map
import           Data.Set                        (Set)
import qualified Data.Set                        as Set
import           Data.Text                       (Text)
import qualified Data.Text                       as T
import qualified Data.Text.IO                    as TIO
import           Distribution.Parsec             (eitherParsec)
import           Distribution.Pretty             (prettyShow)
import           Distribution.Types.Flag         (showFlagAssignment)
import qualified Distribution.Solver.Types.ComponentDeps as CD
import           Distribution.Solver.Types.ResolverPackage (ResolverPackage (..))
import           Distribution.Solver.Types.SolverPackage (SolverPackage (..))
import           Distribution.Package            (packageId)
import           Distribution.Types.PackageId    (pkgName)
import           Distribution.Types.PackageName  (PackageName)
import           Distribution.Types.VersionRange (VersionRange, anyVersion)
import           Hackage.Security.Util.Path      (fromFilePath, makeAbsolute)
import           Network.HTTP.Client             (defaultManagerSettings,
                                                  newManager)
import           PubGrub.Incompatibility         (IncompatCause (..),
                                                  Incompatibility,
                                                  incompCause, incompTerms)
import           PubGrub.InstanceSet             (HasVersion (version),
                                                  Instance (..),
                                                  singletonInstance)
import           PubGrub.Provider                (Provider (..))
import           PubGrub.Pretty                  (Pretty (pretty))
import           PubGrub.Report                  (reportConflict)
import           PubGrub.Solver                  (SolveError (..),
                                                  SolverMsg (..), solve)
import           PubGrub.VersionSet              (VersionSet, fromVersionRange)
import           System.Environment              (getArgs)
import           UnliftIO                        (MonadIO (liftIO),
                                                  MonadUnliftIO)

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

runApp :: Verbosity -> App a -> IO a
runApp verbosity app = runReaderT (unApp app) env
  where
    toStdout :: LogAction App Text
    toStdout = LogAction (liftIO . TIO.putStrLn)
    env =
        Env
            { envText = toStdout
            , envSolver = case verbosity of
                Verbose -> cmap renderSolverMsg toStdout
                -- 'mempty' is co-log's do-nothing action. The solver still
                -- constructs each 'SolverMsg' (one constructor application,
                -- with unforced fields) but nothing renders it, so the cost
                -- that matters for a timed run — pretty-printing an
                -- 'Incompatibility' and writing a line — is gone.
                Normal -> mempty
            }

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
-- Argument parsing
-- --------------------------------------------------------------------------

-- | Which solver to run. Both are fed from a world opened the same way
-- ('Bridge.Provider.withWorld'), so this switches the solver and nothing else.
data Which = Ours | Cabal
    deriving stock (Eq, Show)

data Options = Options
    { optVerbosity :: Verbosity
    , optWhich     :: Which
    , optTarget    :: PackageName
    , optRange     :: VersionSet
    , optRawRange  :: VersionRange
    -- ^ the same constraint unconverted: cabal's solver takes a 'VersionRange',
    -- ours a 'VersionSet', and both must come from the one argument
    }

usage :: String
usage = "usage: pubgrub [-v|--verbose] [--cabal] <package> [version-range]"

parseArgs :: [String] -> Either String Options
parseArgs args = do
    (verbosity, which, positional) <- takeFlags Normal Ours [] args
    case positional of
        [name] -> options verbosity which name Nothing
        [name, range] -> options verbosity which name (Just range)
        _ -> Left usage
  where
    takeFlags v w acc [] = Right (v, w, reverse acc)
    takeFlags v w acc (a : as)
        | a == "-v" || a == "--verbose" = takeFlags Verbose w acc as
        | a == "--cabal" = takeFlags v Cabal acc as
        -- Only long options are rejected as unknown. A leading @-@ alone does
        -- not make an argument a flag — this is the position a version range
        -- appears in, and range syntax has historically included @-any@ — so
        -- anything else is handed to the range parser to accept or reject.
        | take 2 a == "--" = Left ("unknown flag: " ++ a ++ "\n" ++ usage)
        | otherwise = takeFlags v w (a : acc) as

    options v w name mRange = do
        p <- eitherParsec name
        range <- case mRange of
            Nothing -> pure anyVersion
            Just r -> eitherParsec r :: Either String VersionRange
        pure
            Options
                { optVerbosity = v
                , optWhich = w
                , optTarget = p
                , optRange = fromVersionRange range
                , optRawRange = range
                }

-- --------------------------------------------------------------------------
-- Driver
-- --------------------------------------------------------------------------

main :: IO ()
main = do
    args <- getArgs
    case parseArgs args of
        Left err -> putStrLn ("error: " ++ err)
        Right opts -> do
            let target = optTarget opts
            cache <- mkCache <$> makeAbsolute (fromFilePath "_cache")
            manager <- newManager defaultManagerSettings
            runApp (optVerbosity opts) $ case optWhich opts of
                -- The provider needs the root's targets up front: it is asked to
                -- expand the root like any other package, but has no index entry
                -- to look its dependencies up in.
                Ours ->
                    withProvider cache manager [(target, optRange opts)] $ \provider -> do
                        logMsg (T.pack ("Solving for " ++ prettyShow target))
                        result <- solve provider rootName rootInstance
                        report provider result
                Cabal ->
                    withWorld cache manager $ \world -> do
                        logMsg (T.pack ("Solving for " ++ prettyShow target ++ " (cabal's solver)"))
                        runBaseline world [(target, optRawRange opts)]


-- | Run cabal's solver over the same world and render its answer in the same
-- shape ours is rendered in: a plan, or the solver's own failure text.
--
-- Both solvers' indexes come from one 'World' (see @Bridge.Cabal.Baseline@).
-- Ours reads a @.cabal@ only when it expands a package, while cabal's wants a
-- 'SourcePackage' record for every release in the index before it starts, so
-- 'sourcePackageIndex' is where a large part of a baseline run's time and memory
-- goes. It is called here rather than inside 'solveWithCabal' so that the two
-- costs can be measured apart.
runBaseline :: World -> [(PackageName, VersionRange)] -> App ()
runBaseline world targets = do
    sourceIdx <- liftIO (sourcePackageIndex (wIndex world))
    let progress =
            solveWithCabal
                defaultSolverConfig
                (wPlatform world)
                (wCompiler world)
                (wInstalled world)
                sourceIdx
                targets
        (steps, result) = outcome progress
    case result of
        Left err -> do
            logMsg (T.pack ("cabal found no plan after " ++ show steps ++ " log steps:"))
            logMsg (T.pack err)
        Right plan -> do
            logMsg (T.pack ("cabal's plan (" ++ show steps ++ " log steps):"))
            mapM_ (mapM_ (logMsg . T.pack) . renderResolved) (sortOn resolvedName plan)
  where
    resolvedName p = prettyShow (pkgName (packageId p))

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

report :: Provider App -> Either SolveError (Map PackageName Instance) -> App ()
report _ (Left (NoSolution incompat)) =
    logMsg (reportConflict incompat)
report _ (Left (NoSatisfier p _)) =
    logMsg (T.pack ("internal error: no satisfier for " ++ prettyShow p))
report provider (Right solution) = do
    logMsg (T.pack "Solution:")
    children <- dependencyMap provider solution
    mapM_ logMsg (renderTree solution children)

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
        result <- expand provider pn (singletonInstance inst)
        let deps = case result of
                Just (_, incs) ->
                    [ d
                    | inc <- incs
                    , CauseDependency p _ (d, _) <- [incompCause inc]
                    , p == pn
                    ]
                Nothing -> []
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
