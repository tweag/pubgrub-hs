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
import           Bridge.Provider                 (rootName, syntheticRoot,
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
import           Distribution.Types.PackageName  (PackageName)
import           Distribution.Types.VersionRange (VersionRange)
import           Hackage.Security.Util.Path      (fromFilePath, makeAbsolute)
import           Network.HTTP.Client             (defaultManagerSettings,
                                                  newManager)
import           PubGrub.InstanceSet             (HasVersion (version),
                                                  Instance)
import           PubGrub.Solver                  (SolveError, SolverMsg (..),
                                                  solve)
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
    renderSolverMsg (Deciding pn is) = T.pack ("Deciding " <> prettyShow pn <> " among " <> show is)
    renderSolverMsg (Chose pn is) = T.pack ("Chose " <> prettyShow pn <> " as " <> show is)
    renderSolverMsg (Conflict incompatibility) = T.pack ("Conflict " <> show incompatibility)
    renderSolverMsg (Backtracked pn) = T.pack ("Backtracked " <> prettyShow pn)
    renderSolverMsg (NoVersionFor pn is) = T.pack ("No version available for " <> prettyShow pn <> " in " <> show is)

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
            runApp $
                withProvider cache manager $ \provider -> do
                    logMsg (T.pack ("Solving for " ++ prettyShow target))
                    result <- solve provider rootName (syntheticRoot [(target, range)])
                    report result


report :: Either SolveError (Map PackageName Instance) -> App ()
report (Left err) =
    logMsg (T.pack ("No solution found: " ++ show err))
report (Right solution) = do
    logMsg (T.pack "Solution:")
    mapM_
        (\(p, i) -> logMsg (T.pack ("  " ++ prettyShow p ++ " " ++ prettyShow (version i))))
        (Map.toList solution)
