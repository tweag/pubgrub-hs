{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}

module HackageProvider
  ( Pkg (..)
  , HackageProvider (..)
  , ResolveError (..)
  , indexVersions
  ) where

import           Control.Exception               (Exception, throwIO)
import           Control.Monad.IO.Class          (MonadIO, liftIO)
import           Data.List                       (sortBy)
import           Data.Map.Strict                 (Map)
import qualified Data.Map.Strict                 as Map
import           Data.Maybe                      (listToMaybe)
import           Data.Ord                        (Down (..), comparing)

import           Distribution.Compiler           (AbiTag (..),
                                                  CompilerFlavor (..),
                                                  CompilerId (..), CompilerInfo,
                                                  unknownCompilerInfo)
import           Distribution.PackageDescription (GenericPackageDescription,
                                                  PackageIdentifier (..),
                                                  PackageName, pkgName,
                                                  pkgVersion)
import           Distribution.System             (Arch (..), OS (..),
                                                  Platform (..))
import           Distribution.Version            (Version, mkVersion)

import           Hackage.Security.Client         (Directory (..),
                                                  IndexCallbacks (..),
                                                  IndexFile (..))
import           Hackage.Security.Util.Some      (Some (..))

import           Database                        (ParseError, Result)
import           PubGrub.Cabal.Flatten           (flattenDeps)
import           PubGrub.Solver                  (DependencyProvider (..))
import           PubGrub.Types                   (Package)
import           PubGrub.VersionSet              (VersionSet)
import qualified PubGrub.VersionSet              as VS

-- | Resolution package: a synthetic root, or a real Hackage package.
data Pkg = Root | Pkg PackageName
  deriving (Eq, Ord, Show)

instance Package Pkg

-- | Thrown when a selected package version's .cabal cannot be parsed.
data ResolveError = ResolveError PackageName Version
  deriving (Show)

instance Exception ResolveError

-- | A dependency provider backed by the Hackage index.
data HackageProvider = HackageProvider
  { hpVersions :: Map PackageName [Version]
  , hpLookup   :: PackageIdentifier -> IO (Result ParseError GenericPackageDescription)
  , hpBoot     :: Map PackageName Version
  , hpTarget   :: PackageName
  , hpRange    :: VersionSet
  }

thePlatform :: Platform
thePlatform = Platform X86_64 Linux

theCompiler :: CompilerInfo
theCompiler = unknownCompilerInfo (CompilerId GHC (mkVersion [9, 12, 4])) NoAbiTag

-- | The set of available versions per package, from the index directory.
indexVersions :: IndexCallbacks -> Map PackageName [Version]
indexVersions IndexCallbacks{indexDirectory} =
  Map.fromListWith (++)
    [ (pkgName pkgId, [pkgVersion pkgId])
    | (_entry, _path, msIndexFile) <- directoryEntries indexDirectory
    , Just (Some (IndexPkgCabal pkgId)) <- [msIndexFile]
    ]

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
