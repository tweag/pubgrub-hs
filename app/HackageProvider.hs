{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedStrings     #-}

module HackageProvider
  ( Pkg (..),
    HackageProvider (..),
    ResolveError (..),
    withHackageProvider,
  )
where

import           BootPackages                           (queryBootPackages)
import           Colog                                  (WithLog, logMsg)
import           Control.Exception                      (Exception, throwIO)
import           Control.Monad                          (when)
import           Control.Monad.IO.Class                 (MonadIO)
import           Data.Binary                            (decodeFile, encodeFile)
import qualified Data.ByteString.Lazy                   as BSL
import           Data.List                              (sortBy)
import qualified Data.List.NonEmpty                     as NE
import           Data.Map.Strict                        (Map)
import qualified Data.Map.Strict                        as Map
import           Data.Maybe                             (listToMaybe)
import           Data.Ord                               (Down (..), comparing)
import           Data.Text                              (Text)
import qualified Data.Text                              as T
import           Data.Time                              (getCurrentTime)
import           Database                               (ParseError (..))
import           Distribution.Compiler                  (AbiTag (..),
                                                         CompilerFlavor (..),
                                                         CompilerId (..),
                                                         CompilerInfo,
                                                         unknownCompilerInfo)
import           Distribution.PackageDescription        (GenericPackageDescription,
                                                         PackageIdentifier (..),
                                                         PackageName)
import           Distribution.PackageDescription.Parsec (parseGenericPackageDescription,
                                                         runParseResult)
import           Distribution.System                    (Arch (..), OS (..),
                                                         Platform (..))
import           Distribution.Version                   (Version, mkVersion)
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
import           Hackage.Security.Util.Pretty           (Pretty (pretty))
import           Hackage.Security.Util.Some             (Some (..))
import           HttpClient                             (Manager)
import           PubGrub.Cabal.Flatten                  (flattenDeps)
import           PubGrub.Solver                         (DependencyProvider (..))
import           PubGrub.Types                          (Package)
import           PubGrub.VersionSet                     (VersionSet)
import qualified PubGrub.VersionSet                     as VS
import           UnliftIO                               (MonadIO (..))
import           Utils                                  (timed)

-- | Resolution package: a synthetic root, or a real Hackage package.
data Pkg = Root | Pkg PackageName
  deriving (Eq, Ord, Show)

instance Package Pkg

-- | Thrown when a selected package version's .cabal cannot be parsed.
data ResolveError = ResolveError PackageName Version
  deriving (Show)

instance Exception ResolveError

-- | A dependency provider backed by the Hackage index. @hpVersions@ lists each
-- package's available versions; @hpLookupCabal@ reads and parses one version's
-- .cabal file when its dependencies are asked for.
data HackageProvider = HackageProvider
  { hpVersions :: Map PackageName [Version],
    hpLookupCabal :: PackageIdentifier -> IO (Either ParseError GenericPackageDescription),
    hpBoot :: Map PackageName Version,
    hpTarget :: PackageName,
    hpRange :: VersionSet
  }

thePlatform :: Platform
thePlatform = Platform X86_64 Linux

theCompiler :: CompilerInfo
theCompiler = unknownCompilerInfo (CompilerId GHC (mkVersion [9, 12, 4])) NoAbiTag

instance (MonadIO m) => DependencyProvider HackageProvider Pkg m where
  chooseVersion :: (MonadIO m) => HackageProvider -> Pkg -> VersionSet -> m (Maybe Version)
  chooseVersion hp pkg range = pure $ case pkg of
    Root -> Just (mkVersion [0])
    Pkg n
      | Just bv <- Map.lookup n (hpBoot hp) ->
          if VS.contains range bv then Just bv else Nothing
      | otherwise ->
          listToMaybe
            ( sortBy
                (comparing Down)
                ( filter
                    (VS.contains range)
                    (Map.findWithDefault [] n (hpVersions hp))
                )
            )

  getDependencies :: (MonadIO m) => HackageProvider -> Pkg -> Version -> m (Map Pkg VersionSet)
  getDependencies hp pkg v = case pkg of
    Root -> pure (Map.singleton (Pkg (hpTarget hp)) (hpRange hp))
    Pkg n
      | Map.member n (hpBoot hp) -> pure Map.empty
      | otherwise -> do
          res <- liftIO (hpLookupCabal hp (PackageIdentifier n v))
          case res of
            Right gpd -> pure (Map.mapKeys Pkg (flattenDeps thePlatform theCompiler gpd))
            Left _ -> liftIO (throwIO (ResolveError n v))

withHackageProvider ::
  (MonadIO m, MonadUnliftIO m, WithLog env Text m) =>
  Sec.Cache ->
  Manager ->
  PackageName ->
  VersionSet ->
  (HackageProvider -> m a) ->
  m a
withHackageProvider cache manager target range act =
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
          when (not cacheExists || hasUpdates == HasUpdates) $ do
            logMsg @Text "\ESC[2mPackage index updated\ESC[0m"
            updateCache cacheFile indexCallbacks

          logMsg @Text "\ESC[2mReading package index\ESC[0m"
          (indexVersions, t') <- timed $ liftIO $ decodeFile (toFilePath cacheFile)
          logMsg @Text ("\ESC[2mPackage index read in " <> T.pack (show t') <> " seconds\ESC[0m")

          boot <- liftIO queryBootPackages
          let hp =
                HackageProvider
                  { hpVersions = indexVersions,
                    hpLookupCabal = \pkgId -> do
                      bytes <- uncheckClientErrors $ indexLookupCabal indexCallbacks pkgId
                      return $ parseGPD (trusted bytes),
                    hpBoot = boot,
                    hpTarget = target,
                    hpRange = range
                  }

          let pkgCount = Map.size (hpVersions hp)
          logMsg @Text ("\ESC[2m  " <> T.pack (show pkgCount) <> " packages indexed\ESC[0m")
          act hp
  where
    uri = parseURI "http://hackage.haskell.org"
    oneWeek = 7 * 24 * 60 * 60

    logger :: (WithLog env Text m) => LogMessage -> m ()
    logger = logMsg . T.pack . pretty

    cacheFile = cacheRoot cache </> fragment "index-versions.bin"

updateCache ::
  (MonadIO m, WithLog env Text m) =>
  Path Absolute ->
  IndexCallbacks ->
  m ()
updateCache cacheFile IndexCallbacks {indexDirectory} = do
  logMsg @Text "\ESC[2mUpdating package index\ESC[0m"
  let pkgs =
        [ (pkgName pkgId, pkgVersion pkgId)
        | (_entry, _, Just (Some (IndexPkgCabal pkgId))) <- directoryEntries indexDirectory
        ]
      index =
        Map.fromListWith
          (<>)
          [ (pkgName, versions)
          | g <- NE.groupWith fst pkgs,
            let pkgName = fst (NE.head g),
            let versions = NE.map snd g
          ]
  liftIO $ encodeFile (toFilePath cacheFile) index

parseGPD :: BSL.ByteString -> Either ParseError GenericPackageDescription
parseGPD bs =
  case runParseResult (parseGenericPackageDescription (BSL.toStrict bs)) of
    (_, Left (mver, errs)) -> Left (ParseError mver errs)
    (_, Right gpd)         -> Right gpd
