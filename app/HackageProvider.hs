{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}

module HackageProvider
  ( Pkg (..)
  , HackageProvider (..)
  , ResolveError (..)
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
                                                  PackageName)
import           Distribution.System             (Arch (..), OS (..),
                                                  Platform (..))
import           Distribution.Version            (Version, mkVersion)

import           Hackage.Security.Client         (DirectoryEntry)

import           Database                        (ParseError)
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

-- | A dependency provider backed by the Hackage index. @hpEntries@ remembers each
-- version's directory entry; @hpParse@ parses one on demand.
data HackageProvider = HackageProvider
  { hpEntries :: Map PackageName (Map Version DirectoryEntry)
  , hpParse   :: DirectoryEntry -> IO (Either ParseError GenericPackageDescription)
  , hpBoot    :: Map PackageName Version
  , hpTarget  :: PackageName
  , hpRange   :: VersionSet
  }

thePlatform :: Platform
thePlatform = Platform X86_64 Linux

theCompiler :: CompilerInfo
theCompiler = unknownCompilerInfo (CompilerId GHC (mkVersion [9, 12, 4])) NoAbiTag

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
                (Map.keys (Map.findWithDefault Map.empty n (hpEntries hp)))))

  getDependencies hp pkg v = case pkg of
    Root -> pure (Map.singleton (Pkg (hpTarget hp)) (hpRange hp))
    Pkg n
      | Map.member n (hpBoot hp) -> pure Map.empty
      | otherwise ->
          case Map.lookup n (hpEntries hp) >>= Map.lookup v of
            Just entry -> do
              res <- liftIO (hpParse hp entry)
              case res of
                Right gpd -> pure (Map.mapKeys Pkg (flattenDeps thePlatform theCompiler gpd))
                Left _    -> liftIO (throwIO (ResolveError n v))
            Nothing -> liftIO (throwIO (ResolveError n v))
