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

import           Bridge.Hackage                  (mkCache)
import           Bridge.Provider                 (rootInstance, rootName,
                                                  withProvider)
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
import           Distribution.Types.PackageName  (PackageName)
import           Distribution.Types.VersionRange (VersionRange)
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
import           PubGrub.VersionSet              (VersionSet, fromVersionRange,
                                                  fullVersionSet)
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

data Options = Options
    { optVerbosity :: Verbosity
    , optTarget    :: PackageName
    , optRange     :: VersionSet
    }

usage :: String
usage = "usage: pubgrub [-v|--verbose] <package> [version-range]"

parseArgs :: [String] -> Either String Options
parseArgs args = do
    (verbosity, positional) <- takeFlags Normal [] args
    case positional of
        [name] -> options verbosity name Nothing
        [name, range] -> options verbosity name (Just range)
        _ -> Left usage
  where
    takeFlags v acc [] = Right (v, reverse acc)
    takeFlags v acc (a : as)
        | a == "-v" || a == "--verbose" = takeFlags Verbose acc as
        -- Only long options are rejected as unknown. A leading @-@ alone does
        -- not make an argument a flag — this is the position a version range
        -- appears in, and range syntax has historically included @-any@ — so
        -- anything else is handed to the range parser to accept or reject.
        | take 2 a == "--" = Left ("unknown flag: " ++ a ++ "\n" ++ usage)
        | otherwise = takeFlags v (a : acc) as

    options v name mRange = do
        p <- eitherParsec name
        vs <- case mRange of
            Nothing -> pure fullVersionSet
            Just range -> fromVersionRange <$> (eitherParsec range :: Either String VersionRange)
        pure (Options {optVerbosity = v, optTarget = p, optRange = vs})

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
            -- The provider needs the root's targets up front: it is asked to
            -- expand the root like any other package, but has no index entry
            -- to look its dependencies up in.
            runApp (optVerbosity opts) $
                withProvider cache manager [(target, optRange opts)] $ \provider -> do
                    logMsg (T.pack ("Solving for " ++ prettyShow target))
                    result <- solve provider rootName rootInstance
                    report provider result


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
