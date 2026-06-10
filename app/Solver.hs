{-# LANGUAGE ScopedTypeVariables #-}

module Solver
  ( runSolve
  ) where

import           Control.Exception                      (try)
import qualified Data.ByteString.Lazy                   as BSL
import           Data.Map.Strict                        (Map)
import qualified Data.Map.Strict                        as Map

import           Distribution.PackageDescription        (GenericPackageDescription,
                                                         PackageName)
import           Distribution.PackageDescription.Parsec (parseGenericPackageDescription,
                                                         runParseResult)
import           Distribution.Pretty                    (prettyShow)
import           Distribution.Version                   (Version, mkVersion)

import           Hackage.Security.Client                (IndexCallbacks)

import           BootPackages                           (queryBootPackages)
import           Database                               (ParseError (..),
                                                         mkDatabase)
import           HackageProvider                        (HackageProvider (..),
                                                         Pkg (..),
                                                         ResolveError (..),
                                                         indexVersions)
import           PubGrub.Solver                         (SolveError (..),
                                                         reportConflict, solve)
import           PubGrub.VersionSet                     (VersionSet)

-- | Resolve the dependency closure of @target@ within @range@ and print the
-- plan (or a derivation tree on failure).
runSolve :: IndexCallbacks -> PackageName -> VersionSet -> IO ()
runSolve indexCallbacks target range = do
  dblookup <- mkDatabase indexCallbacks parseGPD
  boot <- queryBootPackages
  let hp = HackageProvider
        { hpVersions = indexVersions indexCallbacks
        , hpLookup   = dblookup
        , hpBoot     = boot
        , hpTarget   = target
        , hpRange    = range
        }
  outcome <-
    try (solve hp Root (mkVersion [0]))
      :: IO (Either ResolveError (Either (SolveError Pkg) (Map Pkg Version)))
  case outcome of
    Left (ResolveError n v) ->
      putStrLn ("Failed to parse " ++ prettyShow n ++ "-" ++ prettyShow v)
    Right (Left (NoSolution i)) -> do
      putStrLn "No solution:"
      putStrLn (reportConflict i)
    Right (Right plan) -> do
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
