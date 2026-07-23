{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TypeFamilies          #-}

module SourceProvider (
    SourceProvider (..),
    ResolveError (..),
    withSourceProvider,
)
where

import           Colog                                  (WithLog, logMsg)
import           Compiler                               (Compiler (..))
import           Control.Exception                      (Exception, throwIO)
import           Control.Monad                          (when)
import           Control.Monad.IO.Class                 (MonadIO)
import           Data.Binary                            (decodeFileOrFail,
                                                         encodeFile)
import qualified Data.ByteString.Lazy                   as BSL
import qualified Data.Foldable1                         as Foldable1
import           Data.List.NonEmpty                     (NonEmpty)
import qualified Data.List.NonEmpty                     as NE
import           Data.Map.Strict                        (Map)
import qualified Data.Map.Strict                        as Map
import           Data.Text                              (Text)
import qualified Data.Text                              as T
import           Data.Time                              (getCurrentTime)
import           Database                               (ParseError (..))
import           Distribution.Compiler                  (CompilerInfo)
import           Distribution.PackageDescription        (GenericPackageDescription,
                                                         PackageIdentifier (..),
                                                         PackageName)
import           Distribution.PackageDescription.Parsec (parseGenericPackageDescription,
                                                         runParseResult)
import           Distribution.System                    (Arch (..), OS (..),
                                                         Platform (..))
import           Distribution.Version                   (Version)
import           Hackage                                (indexOlderThan,
                                                         parseURI)
import           Hackage.Security.Client                (Directory (..),
                                                         HasUpdates (..),
                                                         IndexFile (..),
                                                         KeyThreshold (..),
                                                         checkForUpdates,
                                                         requiresBootstrap,
                                                         trusted)
import           Hackage.Security.Unlifted              (doesFileExist)
import           Hackage.Security.Unlifted              hiding (doesFileExist)
import qualified Hackage.Security.Unlifted              as Sec hiding
                                                               (doesFileExist)
import           Hackage.Security.Util.Pretty           as Hackage (pretty)
import           Hackage.Security.Util.Some             (Some (..))
import           HttpClient                             (Manager)
import           PubGrub.Cabal.Flatten                  (flattenDeps)
import           PubGrub.Solver                         (DependencyProvider (..))
import           PubGrub.VersionSet                     (VersionSet)
import qualified PubGrub.VersionSet                     as VS
import           UnliftIO                               (MonadIO (..))

-- | Thrown when a selected package version's .cabal cannot be parsed.
data ResolveError = ResolveError PackageName Version
    deriving (Show)

instance Exception ResolveError

-- | A source dependency provider backed by the Hackage index. @spVersions@ lists
-- each package's available versions; @spLookupCabal@ reads and parses one
-- version's .cabal file when its dependencies are asked for. The solve target,
-- its range and the installed packages belong to 'Provider.Combined'.
data SourceProvider = SourceProvider
    { spVersions :: Map PackageName (NonEmpty Version)
    , spLookupCabal :: PackageIdentifier -> IO (Either ParseError GenericPackageDescription)
    , spCompiler :: CompilerInfo
    }

thePlatform :: Platform
thePlatform = Platform X86_64 Linux

instance (MonadIO m) => DependencyProvider SourceProvider PackageName VersionSet m where
    expand
        :: (MonadIO m)
        => SourceProvider
        -> PackageName
        -> VersionSet
        -> m (Maybe (Version, Map PackageName VersionSet))
    expand hp n range =
        case Map.lookup n (spVersions hp) >>= filterInRange of
            Nothing -> pure Nothing
            Just neVs -> do
                let v = Foldable1.maximum neVs
                res <- liftIO (spLookupCabal hp (PackageIdentifier n v))
                case res of
                    Right gpd ->
                        pure (Just (v, flattenDeps thePlatform (spCompiler hp) gpd))
                    Left _ -> liftIO (throwIO (ResolveError n v))
      where
        filterInRange = NE.nonEmpty . NE.filter (VS.contains range)
