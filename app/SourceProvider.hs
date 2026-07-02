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

withSourceProvider
    :: (MonadIO m, MonadUnliftIO m, WithLog env Text m)
    => Sec.Cache
    -> Manager
    -> Compiler
    -> (SourceProvider -> m a)
    -> m a
withSourceProvider cache manager compiler act =
    withClient manager $ \httpLib ->
        withRepository httpLib [uri] cache logger $ \repository -> do
            uncheckClientErrors $ do
                now <- liftIO getCurrentTime
                hasUpdates <- uncheckClientErrors $ liftIO $ do
                    rb <- requiresBootstrap repository
                    when rb $ bootstrap repository [] (KeyThreshold 0)
                    stale <- indexOlderThan oneWeek cache now
                    if stale
                        then
                            checkForUpdates repository (Just now)
                        else
                            return NoUpdates

                withIndex repository $ \indexCallbacks -> do
                    cacheExists <- liftIO $ doesFileExist cacheFile
                    -- Read an existing cache only when the index has no updates;
                    -- 'readVersionCache' also rejects one written under another
                    -- 'cacheFormatVersion', and either case rebuilds it.
                    cached <-
                        if cacheExists && hasUpdates /= HasUpdates
                            then liftIO (readVersionCache (toFilePath cacheFile))
                            else pure Nothing
                    indexVersions <- case cached of
                        Just versions -> do
                            logMsg @Text "\ESC[2mPackage version cache is current\ESC[0m"
                            pure versions
                        Nothing -> do
                            logMsg @Text "\ESC[2mRebuilding package version cache\ESC[0m"
                            updateCache cacheFile indexCallbacks
                            rebuilt <- liftIO (readVersionCache (toFilePath cacheFile))
                            maybe
                                (liftIO (throwIO (userError "version cache unreadable after rebuild")))
                                pure
                                rebuilt

                    let hp =
                            SourceProvider
                                { spVersions = indexVersions
                                , spLookupCabal = \pkgId -> do
                                    bytes <- uncheckClientErrors $ indexLookupCabal indexCallbacks pkgId
                                    return $ parseGPD (trusted bytes)
                                , spCompiler = compilerInfo compiler
                                }

                    let pkgCount = Map.size (spVersions hp)
                    logMsg @Text ("\ESC[2m  " <> T.pack (show pkgCount) <> " packages indexed\ESC[0m")
                    act hp
  where
    uri = parseURI "http://hackage.haskell.org"
    oneWeek = 7 * 24 * 60 * 60

    logger :: (WithLog env Text m) => LogMessage -> m ()
    logger = logMsg . T.pack . Hackage.pretty

    cacheFile = cacheRoot cache </> fragment "index-versions.bin"

-- | On-disk schema version for the package-version cache. Bump this whenever
-- the encoding written by 'updateCache' changes, so caches from older builds
-- are rebuilt instead of being misread.
cacheFormatVersion :: Int
cacheFormatVersion = 2

-- | Read the version cache, returning 'Nothing' if the file is corrupt or was
-- written by a different 'cacheFormatVersion'.
readVersionCache :: FilePath -> IO (Maybe (Map PackageName (NonEmpty Version)))
readVersionCache path = do
    result <- decodeFileOrFail path
    pure $ case result of
        Right (v, versions) | v == cacheFormatVersion -> Just versions
        _                                             -> Nothing

updateCache
    :: (MonadIO m, WithLog env Text m)
    => Path Absolute
    -> IndexCallbacks
    -> m ()
updateCache cacheFile IndexCallbacks{indexDirectory} = do
    logMsg @Text "\ESC[2mUpdating package index\ESC[0m"
    let pkgs =
            [ (pkgName pkgId, pkgVersion pkgId)
            | (_entry, _, Just (Some (IndexPkgCabal pkgId))) <- directoryEntries indexDirectory
            ]
        index =
            Map.fromListWith
                (<>)
                [ (pkgName, versions)
                | g <- NE.groupWith fst pkgs
                , let pkgName = fst (NE.head g)
                , let versions = NE.map snd g
                ]
    liftIO $ encodeFile (toFilePath cacheFile) (cacheFormatVersion, index)

parseGPD :: BSL.ByteString -> Either ParseError GenericPackageDescription
parseGPD bs =
    case runParseResult (parseGenericPackageDescription (BSL.toStrict bs)) of
        (_, Left (mver, errs)) -> Left (ParseError mver errs)
        (_, Right gpd)         -> Right gpd
