{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Solver
  ( App
  , runSolve
  , solverSink
  , hackageSink
  ) where

import           Control.Monad                          (unless)
import           Control.Monad.IO.Class                 (liftIO)
import qualified Data.ByteString.Lazy                   as BSL
import           Data.Map.Strict                        (Map)
import qualified Data.Map.Strict                        as Map
import           Data.Text                              (Text)
import qualified Data.Text                              as T
import qualified Data.Text.IO                           as TIO
import           System.IO                              (stderr)

import           Colog                                  (LogAction (..),
                                                         LoggerT, (>$<))

import           Distribution.PackageDescription        (GenericPackageDescription,
                                                         PackageName)
import           Distribution.PackageDescription.Parsec (parseGenericPackageDescription,
                                                         runParseResult)
import           Distribution.Pretty                    (prettyShow)
import           Distribution.Version                   (Version, mkVersion,
                                                         simplifyVersionRange)

import           Hackage.Security.Client                (IndexCallbacks,
                                                         LogMessage)
import           Hackage.Security.Util.Pretty           (pretty)

import           UnliftIO                               (try)

import           BootPackages                           (queryBootPackages)
import           Database                               (ParseError (..),
                                                         mkDatabase)
import           HackageProvider                        (HackageProvider (..),
                                                         Pkg (..),
                                                         ResolveError (..),
                                                         indexVersions)
import           PubGrub.Solver                         (SolveError (..),
                                                         SolverMsg (..),
                                                         reportConflict, solve)
import           PubGrub.VersionSet                     (VersionSet)
import qualified PubGrub.VersionSet                     as VS

-- | The CLI's logging monad: solver progress messages over IO.
type App = LoggerT (SolverMsg Pkg) IO

-- | Write each non-empty line to stderr. It is an 'IO' action because
-- 'usingLoggerT' and withRepository's logger both take one.
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
    showRange = T.pack . prettyShow . simplifyVersionRange . VS.toVersionRange

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
