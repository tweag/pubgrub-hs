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

import           Data.Time.Clock                        (UTCTime)
import           Data.Time.Format                       (defaultTimeLocale,
                                                         formatTime)

import           Colog                                  (LogAction (..),
                                                         LoggerT, (>$<))

import           Distribution.PackageDescription        (GenericPackageDescription,
                                                         PackageName)
import           Distribution.PackageDescription.Parsec (parseGenericPackageDescription,
                                                         runParseResult)
import           Distribution.Pretty                    (prettyShow)
import           Distribution.Version                   (Version, mkVersion)

import           Hackage.Security.Client                (IndexCallbacks,
                                                         LogMessage)
import           Hackage.Security.Util.Pretty           (pretty)

import           UnliftIO                               (try)

import           BootPackages                           (queryBootPackages)
import           Database                               (ParseError (..),
                                                         indexEntries,
                                                         parseEntry)
import           HackageProvider                        (HackageProvider (..),
                                                         Pkg (..),
                                                         ResolveError (..))
import           PubGrub.Solver                         (SolveError (..),
                                                         SolverMsg (..),
                                                         reportConflict, solve)
import           PubGrub.Types                          (Term (..), incompTerms)
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
  Conflict i             -> "  \ESC[33m\x26A0\ESC[0m conflict: " <> renderIncompat i
  Backtracked n          -> "  \ESC[2m\x21A9 backtracking to level " <> T.pack (show n) <> "\ESC[0m"
  _                      -> ""  -- Root payloads: no output
  where
    name = T.pack . prettyShow
    showVer = T.pack . prettyShow
    showRange = T.pack . prettyShow . VS.toVersionRange
    renderIncompat i = T.intercalate ", " [ renderTerm p t | (p, t) <- Map.toList (incompTerms i) ]
    renderTerm Root _               = "root"
    renderTerm (Pkg n) (Positive r) = name n <> " " <> showRange r
    renderTerm (Pkg n) (Negative r) = name n <> " not " <> showRange r

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
  let entries = indexEntries indexCallbacks
      hp = HackageProvider
        { hpEntries = entries
        , hpParse   = parseEntry indexCallbacks parseGPD
        , hpBoot    = boot
        , hpTarget  = target
        , hpRange   = range
        }
      pkgCount = Map.size entries   -- forcing this does the single index traversal
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

parseGPD :: BSL.ByteString -> Either ParseError GenericPackageDescription
parseGPD bs =
  case runParseResult (parseGenericPackageDescription (BSL.toStrict bs)) of
    (_, Left (mver, errs)) -> Left (ParseError mver errs)
    (_, Right gpd)         -> Right gpd
