{-# LANGUAGE GADTs #-}
module Bridge.Hackage where

import           Colog                                        (WithLog, logMsg)
import           Control.Monad                                (when)
import           Data.Binary                                  (decodeFileOrFail,
                                                               encodeFile)
import qualified Data.ByteString.Lazy                         as BSL
import           Data.List.NonEmpty                           (NonEmpty)
import qualified Data.List.NonEmpty                           as NE
import           Data.Map.Strict                              (Map)
import qualified Data.Map.Strict                              as Map
import           Data.Maybe                                   (fromMaybe,
                                                               maybeToList)
import           Data.Set                                     (Set)
import qualified Data.Set                                     as Set
import           Data.Text                                    (Text)
import qualified Data.Text                                    as T
import           Data.Time.Clock                              (NominalDiffTime,
                                                               UTCTime,
                                                               diffUTCTime,
                                                               getCurrentTime)
import           GHC.Stack                                    (HasCallStack)
import           Network.HTTP.Client                          (Manager)
import           Network.URI                                  (URI)
import qualified Network.URI
import           UnliftIO                                     (MonadIO (..),
                                                               MonadUnliftIO,
                                                               SomeException,
                                                               throwIO)

import           Distribution.PackageDescription.Parsec       (parseGenericPackageDescription,
                                                               runParseResult)
import           Distribution.Parsec.Error                    (PError)
import qualified Distribution.Types.BuildInfo.Lens            as L
import           Distribution.Types.ComponentName             (ComponentName (..))
import           Distribution.Types.CondTree                  (CondTree,
                                                               mapTreeData)
import           Distribution.Types.ConfVar                   (ConfVar)
import           Distribution.Types.Dependency                (Dependency)
import           Distribution.Types.Flag                      (PackageFlag (..))
import           Distribution.Types.GenericPackageDescription (GenericPackageDescription (..))
import           Distribution.Types.LibraryName               (LibraryName (..))
import           Distribution.Types.PackageId                 (PackageIdentifier (..))
import           Distribution.Types.PackageName               (PackageName)
import           Distribution.Types.Version                   (Version)


import qualified Bridge.Hackage.Unlifted                      as U
import qualified Hackage.Security.Client                      as Sec
import qualified Hackage.Security.Client.Formats              as Sec
import qualified Hackage.Security.Client.Repository.Cache     as Sec
import           Hackage.Security.Util.Path                   as Sec
import qualified Hackage.Security.Util.Pretty                 as Sec
import           Hackage.Security.Util.Some                   (Some (..))



-- | An open view of the Hackage index: the package-to-versions map, held in
-- memory and cached on disk, and a reader for one release's @.cabal@. The reader
-- closes over the live 'IndexCallbacks', so an 'IndexHandle' is valid only
-- /inside/ the 'withHackageIndex' callback.
data IndexHandle = IndexHandle
    { ihVersions  :: Map PackageName (Set Version)
    , ihLookupGPD :: PackageName -> Version -> IO (Either ParseError GenericPackageDescription)
    }

-- | Open the Hackage index and run @act@ on an 'IndexHandle' inside the index
-- bracket, so that its @.cabal@ reads through 'ihLookupGPD' stay valid. First
-- bootstrap the index, refresh it if it is more than a week old, and build or
-- load the disk-cached version map.
--
-- Only the version map is held in memory. A @.cabal@ is read on demand through
-- hackage-security's random-access lookup, so a solve parses only the packages
-- it touches rather than all of Hackage.
withHackageIndex
    :: (MonadUnliftIO m, WithLog env Text m)
    => Sec.Cache -> Manager -> (IndexHandle -> m a) -> m a
withHackageIndex cache manager act =
    U.withClient manager $ \httpLib ->
        U.withRepository httpLib [uri] cache logger $ \repository -> do
            U.uncheckClientErrors $ do
                now <- liftIO getCurrentTime
                hasUpdates <- U.uncheckClientErrors $ liftIO $ do
                    rb <- Sec.requiresBootstrap repository
                    when rb $ Sec.bootstrap repository [] (Sec.KeyThreshold 0)
                    stale <- indexOlderThan oneWeek cache now
                    if stale
                        then
                            Sec.checkForUpdates repository (Just now)
                        else
                            return Sec.NoUpdates

                U.withIndex repository $ \indexCallbacks -> do
                    cacheExists <- liftIO $ doesFileExist cacheFile
                    -- Only trust an existing cache when the index is unchanged AND the
                    -- cache was written by this build (matching 'cacheFormatVersion'); a
                    -- mismatch or unreadable file forces a rebuild rather than silently
                    -- serving stale or wrongly-shaped data.
                    cached <-
                        if cacheExists && hasUpdates /= Sec.HasUpdates
                            then liftIO (readVersionCache (toFilePath cacheFile))
                            else pure Nothing
                    indexVersions <- case cached of
                        Just versions -> do
                            logMsg (T.pack "\ESC[2mPackage version cache is current\ESC[0m")
                            pure versions
                        Nothing -> do
                            logMsg (T.pack "\ESC[2mRebuilding package version cache\ESC[0m")
                            updateCache cacheFile indexCallbacks
                            rebuilt <- liftIO (readVersionCache (toFilePath cacheFile))
                            maybe
                                (liftIO (throwIO (userError "version cache unreadable after rebuild")))
                                pure
                                rebuilt

                    act (IndexHandle indexVersions (lookupGPD indexCallbacks))
  where
    uri = parseURI "http://hackage.haskell.org"
    oneWeek = 7 * 24 * 60 * 60

    logger :: (WithLog env Text m) => Sec.LogMessage -> m ()
    logger = logMsg . T.pack . Sec.pretty

    cacheFile = Sec.cacheRoot cache </> fragment "index-versions.bin"

-- | Read and parse one release's @.cabal@ through hackage-security's
-- random-access lookup ('indexLookupCabal'). Valid only while the 'withIndex'
-- bracket that gave the 'IndexCallbacks' is open, that is, inside
-- 'withHackageIndex'.
--
-- Every flag is marked __manual__ on the way out, so that flags are applied but
-- fixed at their declared defaults rather than searched. This is the half of
-- that rule which reaches /cabal's/ solver; our own goes through
-- 'Bridge.Cabal.Flatten.componentDepsAtDefaults'.
--
-- It works because @Distribution.Solver.Modular.IndexConversion.flagInfo@ reads
-- 'flagManual' off each 'PackageFlag', and
-- @Distribution.Solver.Modular.Preference.enforceManualFlags@ (wired in at
-- cabal's @Solver.hs@\'s validation phase) then prunes every branch of a manual
-- flag whose value is neither the default nor named by a user flag constraint. We
-- pass no flag constraints, so each flag is pinned to 'flagDefault', the same
-- value 'Bridge.Cabal.Flatten.defaultFlags' gives our provider.
--
-- Doing it here, at the single shared read, keeps the comparison structural:
-- both solvers are fed one index, so neither can be handed a different universe
-- by accident.
--
-- Two consequences to keep in mind when reading benchmark numbers:
--
-- * cabal's @weak m = not (strfl || m)@ makes a manual flag /non-weak/, so
--   @deferWeakFlagChoices@ stops deferring the flags that influence dependencies
--   (ones that influence none stay weak via @Builder@\'s @trivial@). That perturbs
--   cabal's goal ordering, not just its flag values.
-- * an automatic flag is exactly what cabal would flip to escape an
--   unsatisfiable dependency, so some problems that resolve with flags searched
--   do not resolve here. Both solvers fail together, which keeps the comparison
--   fair, but it is a restriction of the problem, and any published explanation
--   has to say so.
lookupGPD
    :: Sec.IndexCallbacks
    -> PackageName
    -> Version
    -> IO (Either ParseError GenericPackageDescription)
lookupGPD cbs pn v =
    Sec.uncheckClientErrors $
        fmap allFlagsManual . parseGPD . Sec.trusted
            <$> Sec.indexLookupCabal cbs (PackageIdentifier pn v)
  where
    allFlagsManual gpd =
        gpd{genPackageFlags = [f{flagManual = True} | f <- genPackageFlags gpd]}

-- | On-disk schema version for the package-version cache. Bump this whenever
-- the encoding written by 'updateCache' changes, so caches from older builds
-- are rebuilt instead of being misread.
cacheFormatVersion :: Int
cacheFormatVersion = 3

-- | The directory the index cache lives in, as a plain 'FilePath'. The derived
-- index ('Bridge.Hackage.Store') is written beside the index it is derived from,
-- so it is found and invalidated with it rather than needing a path of its own.
cacheDirOf :: Sec.Cache -> FilePath
cacheDirOf = toFilePath . Sec.cacheRoot

-- | Read the version cache, returning 'Nothing' if the file is corrupt or was
-- written by a different 'cacheFormatVersion'.
readVersionCache :: FilePath -> IO (Maybe (Map PackageName (Set Version)))
readVersionCache path = do
    result <- decodeFileOrFail path
    pure $ case result of
        Right (v, versions) | v == cacheFormatVersion -> Just versions
        _                                             -> Nothing

updateCache
    :: (MonadIO m, WithLog env Text m)
    => Path Absolute
    -> Sec.IndexCallbacks
    -> m ()
updateCache cacheFile Sec.IndexCallbacks{Sec.indexDirectory} = do
    logMsg $ T.pack "\ESC[2mUpdating package index\ESC[0m"
    let pkgs =
            [ (pkgName pkgId, pkgVersion pkgId)
            | (_entry, _, Just (Some (Sec.IndexPkgCabal pkgId))) <- Sec.directoryEntries indexDirectory
            ]
        -- A 'Set' rather than a list: the versions come out of
        -- 'Sec.directoryEntries' in the index's own order, which is neither sorted
        -- nor guaranteed unique (14796 of 19393 packages were not ascending when
        -- last measured). Every consumer wants them ordered, and the one that asks
        -- "which release comes next" ('Bridge.Provider.withSlots') is wrong if they
        -- are not — so make the order a property of the structure instead of an
        -- obligation on each caller.
        index =
            Map.fromListWith
                Set.union
                [ (pkgName, versions)
                | g <- NE.groupWith fst pkgs
                , let pkgName = fst (NE.head g)
                , let versions = Set.fromList (NE.toList (NE.map snd g))
                ]
    liftIO $ encodeFile (toFilePath cacheFile) (cacheFormatVersion, index)


type Result e a = Either (Either SomeException e) a

data ParseError
    = ParseError (Maybe Version) (NonEmpty PError)
    | ParseException SomeException
    deriving Show

-- Not used yet: each component's conditional dependency tree, for reading
-- dependencies under flags, operating system and architecture.
newtype DepInfo = DepInfo (Map ComponentName (CondTree ConfVar [Dependency] ()))

extractDepInfo :: GenericPackageDescription -> DepInfo
extractDepInfo gpd =
    DepInfo $
        Map.fromList $
            [(CLibName LMainLibName, f tree) | tree <- maybeToList (condLibrary gpd)]
                <> [(CLibName (LSubLibName ucn), f tree) | (ucn, tree) <- condSubLibraries gpd]
                <> [(CFLibName ucn, f tree) | (ucn, tree) <- condForeignLibs gpd]
                <> [(CExeName ucn, f tree) | (ucn, tree) <- condExecutables gpd]
                <> [(CTestName ucn, f tree) | (ucn, tree) <- condTestSuites gpd]
                <> [(CBenchName ucn, f tree) | (ucn, tree) <- condBenchmarks gpd]
  where
    f :: L.HasBuildInfo a => CondTree v c a -> CondTree v c ()
    f = mapTreeData (const ())


parseGPD :: BSL.ByteString -> Either ParseError GenericPackageDescription
parseGPD bs =
    case runParseResult (parseGenericPackageDescription (BSL.toStrict bs)) of
        (_, Left (mver, errs)) -> Left (ParseError mver errs)
        (_, Right gpd)         -> Right gpd

mkCache :: Path Absolute -> Sec.Cache
mkCache root =
    Sec.Cache{Sec.cacheRoot = root, Sec.cacheLayout = cabalCacheLayout}
  where
    cabalCacheLayout :: Sec.CacheLayout
    cabalCacheLayout =
        Sec.CacheLayout
            { Sec.cacheLayoutRoot = rootPath $ fragment "root.json"
            , Sec.cacheLayoutTimestamp = rootPath $ fragment "timestamp.json"
            , Sec.cacheLayoutSnapshot = rootPath $ fragment "snapshot.json"
            , Sec.cacheLayoutMirrors = rootPath $ fragment "mirrors.json"
            , Sec.cacheLayoutIndexTar = rootPath $ fragment "01-index.tar"
            , Sec.cacheLayoutIndexIdx = rootPath $ fragment "01-index.tar.idx"
            , Sec.cacheLayoutIndexTarGz = rootPath $ fragment "01-index.tar.gz"
            }

{- | True if the cached package index is missing, or older than @maxAge@.
Used to skip the (slow) Hackage index refresh on most runs.
-}
indexOlderThan :: NominalDiffTime -> Sec.Cache -> UTCTime -> IO Bool
indexOlderThan maxAge cache now = do
    idx <- Sec.getCachedIndex cache Sec.FGz
    case idx of
        Nothing -> pure True
        Just idxPath -> do
            mtime <- Sec.getModificationTime idxPath
            pure (diffUTCTime now mtime > maxAge)

parseURI :: (HasCallStack) => [Char] -> URI
parseURI str = fromMaybe (error $ "failed parsing URI " ++ str) $ Network.URI.parseURI str
