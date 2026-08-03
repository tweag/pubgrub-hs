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
-- and 'SolverMsg' (the solver's search trace) — both rendered to stdout.
module Main (main) where

import           Bridge.Hackage                  (mkCache)
import           Bridge.Provider                 (rootInstance, rootName,
                                                  withProvider)
import           Colog                           (HasLog (..), LogAction (..),
                                                  cmap, logMsg)
import           Control.Monad.Reader            (MonadReader, ReaderT,
                                                  runReaderT)
import           Data.Map.Strict                 (Map)
import qualified Data.Map.Strict                 as Map
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
import           PubGrub.InstanceSet             (HasVersion (version),
                                                  Instance (..))
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

runApp :: App a -> IO a
runApp app = runReaderT (unApp app) env
  where
    toStdout :: LogAction App Text
    toStdout = LogAction (liftIO . TIO.putStrLn)
    env =
        Env
            { envText = toStdout
            , envSolver = cmap renderSolverMsg toStdout
            }

renderSolverMsg :: SolverMsg -> Text
renderSolverMsg (Deciding pn is) = T.pack "Deciding " <> pretty pn <> T.pack " among " <> pretty is
renderSolverMsg (Chose pn i) = T.pack "Chose " <> pretty pn <> T.pack " as " <> pretty i
renderSolverMsg (Conflict _incompatibility) = T.pack "Conflict ..."
renderSolverMsg (Backtracked level) = T.pack ("Backtracked to level " <> show level)
renderSolverMsg (NoVersionFor pn is) =
    T.pack "No version available for " <> pretty pn <> T.pack " in " <> pretty is

-- --------------------------------------------------------------------------
-- Argument parsing
-- --------------------------------------------------------------------------

parseArgs :: [String] -> Either String (PackageName, VersionSet)
parseArgs [name] = (\p -> (p, fullVersionSet)) <$> eitherParsec name
parseArgs [name, range] = do
    p <- eitherParsec name
    vr <- eitherParsec range :: Either String VersionRange
    pure (p, fromVersionRange vr)
parseArgs _ = Left "usage: pubgrub <package> [version-range]"

-- --------------------------------------------------------------------------
-- Driver
-- --------------------------------------------------------------------------

main :: IO ()
main = do
    args <- getArgs
    case parseArgs args of
        Left err -> putStrLn ("error: " ++ err)
        Right (target, range) -> do
            cache <- mkCache <$> makeAbsolute (fromFilePath "_cache")
            manager <- newManager defaultManagerSettings
            -- The provider needs the root's targets up front: it is asked to
            -- expand the root like any other package, but has no index entry
            -- to look its dependencies up in.
            runApp $
                withProvider cache manager [(target, range)] $ \provider -> do
                    logMsg (T.pack ("Solving for " ++ prettyShow target))
                    result <- solve provider rootName rootInstance
                    report result


report :: Either SolveError (Map PackageName Instance) -> App ()
report (Left (NoSolution incompat)) =
    logMsg (reportConflict incompat)
report (Right solution) = do
    logMsg (T.pack "Solution:")
    mapM_ (logMsg . uncurry renderChoice) (Map.toList solution)

-- | One line of the plan. A source release is shown with the flag assignment it
-- was decided under, because a different assignment is a different build. A
-- pre-installed unit is shown as such: it is already built, with no flags to
-- choose.
renderChoice :: PackageName -> Instance -> Text
renderChoice p (UsePreInstalled i) = T.pack $ unwords [prettyShow p, prettyShow (version i), "(installed)"]
renderChoice p (BuildSource v fa) = T.pack $ unwords ["  ", prettyShow p, prettyShow v, showFlagAssignment fa]
