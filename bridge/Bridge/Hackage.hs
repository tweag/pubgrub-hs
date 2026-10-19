{-# LANGUAGE GADTs #-}
module Bridge.Hackage where

import           Colog                                        (WithLog, logMsg)
import           Control.Monad                                (when)
import           Control.Exception                            (Exception (..))
import           Control.Monad                                (forM_)
import           Data.Array.IO                                (IOUArray,
                                                               newArray,
                                                               writeArray)
import           Data.Array.Unboxed                           (UArray, (!))
import           Data.Array.Unsafe                            (unsafeFreeze)
import           Data.Binary                                  (get, put)
import           Data.Binary.Get                              (Get, runGetOrFail,
                                                               skip)
import           Data.Binary.Put                              (Put, runPut)
import qualified Data.ByteString.Lazy                         as BSL
import           Data.Int                                     (Int64)
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
import           Data.Time.Clock.POSIX                        (posixSecondsToUTCTime,
                                                               utcTimeToPOSIXSeconds)
import           Data.Time.Format.ISO8601                     (iso8601ParseM,
                                                               iso8601Show)
import           Data.Word                                    (Word32)
import           GHC.Stack                                    (HasCallStack)
import           Network.HTTP.Client                          (Manager)
import           Network.URI                                  (URI)
import qualified Network.URI
import           UnliftIO                                     (MonadIO (..),
                                                               MonadUnliftIO,
                                                               SomeException,
                                                               throwIO,
                                                               tryIO)

import           Distribution.PackageDescription.Parsec       (parseGenericPackageDescription,
                                                               runParseResult)
import           PubGrub.Cabal.Provider                       (ParseError (..))
import           Distribution.Pretty                          (prettyShow)
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
import qualified PubGrub.Cabal.Version                              as V


import qualified Bridge.Hackage.Unlifted                      as U
import qualified Hackage.Security.Client                      as Sec
import qualified Hackage.Security.Client.Formats              as Sec
import qualified Hackage.Security.Client.Repository.Cache     as Sec
import           Hackage.Security.Util.Path                   as Sec
import qualified Hackage.Security.Util.Pretty                 as Sec
import           Hackage.Security.Util.Some                   (Some (..))


-- --------------------------------------------------------------------------
-- Index-state
-- --------------------------------------------------------------------------

-- | Which moment of the index a run sees. cabal's @--index-state@.
--
-- The index tar is append-only, and every entry carries the time it was added.
-- A release is visible at a moment if its first entry is at or before it, and
-- the @.cabal@ it has there is the __last__ entry at or before that moment: a
-- revision is one more entry for the same release, and a revision made after
-- the moment did not exist yet. That is what makes a solve at a fixed state
-- reproducible after the weekly refresh, which otherwise moves both the set of
-- releases and their bounds.
data IndexState
    = IndexHead
    -- ^ everything the local index holds, refreshed at most weekly
    | IndexAt UTCTime
    -- ^ every entry stamped at or before this time. The index is refreshed only
    -- if the request is newer than the local head, and a request still newer
    -- after that is an error rather than a silently smaller universe.
    deriving (Eq, Show)

-- | Parse an @--index-state@ argument: an ISO 8601 timestamp in UTC, as cabal
-- writes one, e.g. @2016-09-24T17:47:48Z@.
parseIndexState :: String -> Either String IndexState
parseIndexState s =
    maybe
        (Left ("expected an ISO 8601 UTC timestamp such as 2016-09-24T17:47:48Z, got '" ++ s ++ "'"))
        (Right . IndexAt)
        (iso8601ParseM s)

-- | What the filter came to on this run. Both are entry times, so both print as
-- index-states.
data IndexStateInfo = IndexStateInfo
    { isiHead      :: EpochTime
    -- ^ the latest entry the local index holds, whatever was requested
    , isiEffective :: Maybe EpochTime
    -- ^ the latest entry that survived the request, which is the index-state
    -- the run is really at. cabal prints this when the request falls between
    -- two entries. 'Nothing' when no entry is that old.
    }
    deriving (Eq, Show)

-- | Seconds since the epoch, as the tar stamps them. @Tar.EpochTime@, without a
-- @tar@ dependency to name it.
type EpochTime = Int64

toEpoch :: UTCTime -> EpochTime
toEpoch = floor . utcTimeToPOSIXSeconds

fromEpoch :: EpochTime -> UTCTime
fromEpoch = posixSecondsToUTCTime . fromIntegral

-- | An index-state as cabal prints one: @2016-09-24T17:47:48Z@.
showIndexState :: EpochTime -> String
showIndexState = iso8601Show . fromEpoch

-- --------------------------------------------------------------------------
-- The open index
-- --------------------------------------------------------------------------

-- | The index as this run sees it: for each package the releases that exist at
-- the index-state, and for each release the tar block of the revision in force
-- there.
--
-- The blocks are one unboxed array over every release, and a package holds its
-- versions and the offset of its first block, so a release's block is at
-- @offset + Set.findIndex version@. Four bytes per release is the whole cost
-- of knowing which revision to read, against ~150k releases held for every
-- solve; a boxed word per release, or an array per package, is a few
-- megabytes on a floor that is about twenty.
data Index = Index
    { ixPackages :: !(Map PackageName Package)
    , ixBlocks   :: !(UArray Int Word32)
    }

data Package = Package
    { pkgVersions :: Set Version
    -- ^ lazy on purpose, and the one lazy field in this file. The set is built
    -- from an ascending list the first time a package is asked about, and a
    -- solve asks about a few hundred of ~19k packages, so the rest stay as
    -- lists at 24 bytes a release instead of set nodes at 40. That is 2.4 MB
    -- of a peak residency of about 22 MB.
    , pkgOffset   :: !Int
    , pkgSolverVersions :: Set V.Version
    -- ^ the same releases in the solver's order, one per version: where two
    -- spellings name one version (@0.1@ and @0.1.0@, 44 packages on Hackage),
    -- the later tar entry is kept. Lazy for the same reason 'pkgVersions' is, and
    -- built from it on first use.
    }

-- | An open view of the Hackage index at one index-state: the package-to-versions
-- map, held in memory and cached on disk, and a reader for one release's @.cabal@
-- __as revised at that state__. The reader closes over the live 'IndexCallbacks',
-- so an 'IndexHandle' is valid only /inside/ the 'withHackageIndex' callback.
data IndexHandle = IndexHandle
    { ihVersionsOf :: PackageName -> Set Version
    -- ^ empty for a package the index-state does not have
    , ihSolverVersionsOf :: PackageName -> Set V.Version
    -- ^ the same releases in the solver's order ('pkgSolverVersions'), which is
    -- what our own provider reads; the baseline reads Cabal's
    , ihVersions   :: Map PackageName (Set Version)
    -- ^ the same, whole. It is built when first asked for, and only the baseline
    -- and the index builder ask; our own solver never pays for the second map.
    , ihBlockOf    :: PackageName -> Version -> Maybe Word32
    -- ^ the tar block of the revision in force, 'Nothing' for a release the
    -- index-state does not have. The derived index keys its validity on it.
    , ihLookupGPD  :: PackageName -> Version -> IO (Either ParseError GenericPackageDescription)
    -- ^ the release's @.cabal@ as revised at the index-state
    , ihReadBlock  :: PackageName -> Version -> Word32 -> IO (Either ParseError GenericPackageDescription)
    -- ^ the same read, given the block up front. A closure over this one holds
    -- no map: the baseline builds ~150k lazy descriptions before it solves, and
    -- through 'ihLookupGPD' every one of them would keep the whole version map
    -- alive for the length of cabal's solve, which was measured at 22 MB of
    -- cabal's peak residency on @vector@.
    , ihState      :: IndexStateInfo
    }

-- | The one error a run at an index-state can end in: the request is newer than
-- the local index, and a refresh did not change that.
newtype IndexStateTooNew = IndexStateTooNew String
    deriving Show

instance Exception IndexStateTooNew where
    displayException (IndexStateTooNew msg) = msg

-- | Open the Hackage index at an 'IndexState' and hand an 'IndexHandle' to the
-- callback. The callback (e.g. a whole solve) runs inside the index bracket, so
-- its on-demand @.cabal@ reads through 'ihLookupGPD' stay valid.
--
-- Refreshing follows cabal. Under 'IndexHead' the index is refreshed when it is
-- more than a week old. Under 'IndexAt' it is refreshed only when the request is
-- newer than the latest entry held locally, and if the request is still newer
-- afterwards the run stops with an error, as cabal's @dieIfRequestedIdxIsNewer@
-- does: an index-state that the local index cannot honour is not a smaller
-- universe, it is a mistake.
--
-- Only the cheap package→versions map is held in memory; @.cabal@ bodies are
-- read lazily per release by tar block, so a solve parses only the releases it
-- actually touches rather than all of Hackage.
withHackageIndex
    :: (MonadUnliftIO m, WithLog env Text m)
    => Sec.Cache -> Manager -> IndexState -> (IndexHandle -> m a) -> m a
withHackageIndex cache manager state act =
    U.withClient manager $ \httpLib ->
        U.withRepository httpLib [uri] cache logger $ \repository -> do
            U.uncheckClientErrors $ do
                now <- liftIO getCurrentTime
                liftIO $ Sec.uncheckClientErrors $ do
                    rb <- Sec.requiresBootstrap repository
                    when rb $ Sec.bootstrap repository [] (Sec.KeyThreshold 0)

                -- The refresh decision needs the local head, and the head is in
                -- the version cache's header, which costs nothing to read. With
                -- no usable cache the decision waits until one is built.
                knownHead <- liftIO (readCacheHead cachePath)
                refreshFirst <- case (requested, knownHead) of
                    (Nothing, _)      -> liftIO (indexOlderThan oneWeek cache now)
                    (Just t, Just h)  -> pure (t > h)
                    (Just _, Nothing) -> pure False

                let refresh = do
                        logMsg (T.pack "\ESC[2mRefreshing the Hackage index\ESC[0m")
                        U.uncheckClientErrors (liftIO (Sec.checkForUpdates repository (Just now)))

                    -- One attempt: open the index, load or rebuild the cache,
                    -- and either run the callback or report that the request is
                    -- newer than the local head.
                    attempt updated = U.withIndex repository $ \indexCallbacks -> do
                        -- Only trust an existing cache when the index is unchanged
                        -- AND the cache was written by this build (matching
                        -- 'cacheFormatVersion'); a mismatch or unreadable file
                        -- forces a rebuild rather than silently serving stale or
                        -- wrongly-shaped data.
                        cached <-
                            if updated /= Sec.HasUpdates
                                then liftIO (readVersionCache state cachePath)
                                else pure Nothing
                        (info, index) <- case cached of
                            Just loaded -> do
                                logMsg (T.pack "\ESC[2mPackage version cache is current\ESC[0m")
                                pure loaded
                            Nothing -> do
                                logMsg (T.pack "\ESC[2mRebuilding package version cache\ESC[0m")
                                liftIO (updateCache cachePath indexCallbacks)
                                rebuilt <- liftIO (readVersionCache state cachePath)
                                maybe
                                    (liftIO (throwIO (userError "version cache unreadable after rebuild")))
                                    pure
                                    rebuilt
                        case requested of
                            Just t | t > isiHead info -> pure (Left (isiHead info))
                            _ -> do
                                announce info
                                Right <$> act (mkHandle indexCallbacks info index)

                    tooNew t h =
                        liftIO . throwIO . IndexStateTooNew $
                            "index-state "
                                ++ showIndexState t
                                ++ " is newer than the local index, whose latest entry is "
                                ++ showIndexState h
                                ++ ", and Hackage has nothing newer"

                first <- if refreshFirst then refresh else pure Sec.NoUpdates
                outcome <- attempt first
                case (outcome, requested) of
                    (Right a, _) -> pure a
                    (Left h, Just t)
                        | refreshFirst -> tooNew t h
                        | otherwise -> do
                            -- No cache existed, so the head was unknown until now.
                            second <- refresh
                            again <- attempt second
                            either (tooNew t) pure again
                    (Left _, Nothing) -> liftIO (throwIO (userError "impossible: no index-state was requested"))
  where
    uri = parseURI "http://hackage.haskell.org"
    oneWeek = 7 * 24 * 60 * 60

    requested = case state of
        IndexHead -> Nothing
        IndexAt t -> Just (toEpoch t)

    logger :: (WithLog env Text m) => Sec.LogMessage -> m ()
    logger = logMsg . T.pack . Sec.pretty

    cachePath = toFilePath (Sec.cacheRoot cache </> fragment "index-versions.bin")

    -- The line the harness and a reader look for. One per run, plain, and
    -- always the state the run is really at.
    announce info = case (requested, isiEffective info) of
        (_, Nothing) ->
            logMsg . T.pack $
                "index-state: none (no entry at or before "
                    ++ maybe "?" showIndexState requested
                    ++ "; the index is empty at this state)"
        (Just t, Just e)
            | e /= t ->
                logMsg . T.pack $
                    "index-state: " ++ showIndexState e
                        ++ " (no entry exactly at " ++ showIndexState t
                        ++ "; using the previous one)"
        (_, Just e) -> logMsg (T.pack ("index-state: " ++ showIndexState e))

mkHandle :: Sec.IndexCallbacks -> IndexStateInfo -> Index -> IndexHandle
mkHandle cbs info Index{ixPackages, ixBlocks} =
    IndexHandle
        { ihVersionsOf = \pn -> maybe Set.empty pkgVersions (Map.lookup pn ixPackages)
        , ihSolverVersionsOf = \pn -> maybe Set.empty pkgSolverVersions (Map.lookup pn ixPackages)
        , ihVersions = Map.map pkgVersions ixPackages
        , ihBlockOf = blockOf
        , ihLookupGPD = \pn v -> case blockOf pn v of
            Just blk -> lookupGPD cbs pn v blk
            Nothing ->
                pure . Left . ParseException . toException . userError $
                    prettyShow (PackageIdentifier pn v) ++ " is not in the index at this index-state"
        , ihReadBlock = lookupGPD cbs
        , ihState = info
        }
  where
    blockOf pn v = do
        Package{pkgVersions, pkgOffset} <- Map.lookup pn ixPackages
        i <- Set.lookupIndex v pkgVersions
        pure (ixBlocks ! (pkgOffset + i))

-- | A package's releases in the solver's order. Cabal's order tells @0.1@ from
-- @0.1.0@ and the solver's does not, so where a package published both (the
-- lists are aligned: the block of each release in force) the release with the
-- greater block — the later tar entry, which is the later upload — is the one
-- the solver is offered. Its spelling is kept, so converting back finds it.
solverVersionsFrom :: [Version] -> [Word32] -> Set V.Version
solverVersionsFrom vs blks =
    Set.fromList
        (map snd (Map.elems (Map.fromListWith later [(sv, (blk, sv)) | (v, blk) <- zip vs blks, let sv = V.fromCabalVersion v])))
  where
    later new old = if fst new >= fst old then new else old

-- | Read and parse one release's @.cabal@ from the tar block of the revision in
-- force at this run's index-state. Valid only while the 'withIndex' bracket that
-- gave the 'IndexCallbacks' is open, that is, inside 'withHackageIndex'.
--
-- By block and not by name: hackage-security's own lookup by name answers with
-- the last revision in the whole tar, which is the right one only at the head.
--
-- Each flag keeps its declared manual bit, which the derived index needs; under
-- fixed flags the baseline marks every flag manual itself ('markFlagsManual').
lookupGPD
    :: Sec.IndexCallbacks
    -> PackageName
    -> Version
    -> Word32
    -> IO (Either ParseError GenericPackageDescription)
lookupGPD cbs pn v blk =
    parseGPD . Sec.indexEntryContent
        <$> Sec.indexLookupFileEntry cbs (Sec.DirectoryEntry blk) (Sec.IndexPkgCabal (PackageIdentifier pn v))

-- | Every flag marked __manual__, for the baseline under fixed flags. The read
-- itself ('lookupGPD') keeps each flag's declared manual bit, because the derived
-- index needs it; the baseline applies this when the driver's flag model asks for
-- it (@Bridge.Cabal.Baseline.sourcePackageIndex@).
--
-- It works because @Distribution.Solver.Modular.IndexConversion.flagInfo@ reads
-- 'flagManual' off each 'PackageFlag', and
-- @Distribution.Solver.Modular.Preference.enforceManualFlags@ (wired in at
-- cabal's @Solver.hs@\'s validation phase) then prunes every branch of a manual
-- flag whose value is neither the default nor named by a user flag constraint. We
-- pass no flag constraints, so each flag is pinned to 'flagDefault', the value
-- our own provider fixes it at.
--
-- Two consequences to keep in mind when reading benchmark numbers under fixed
-- flags:
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
markFlagsManual :: GenericPackageDescription -> GenericPackageDescription
markFlagsManual gpd =
    gpd{genPackageFlags = [f{flagManual = True} | f <- genPackageFlags gpd]}

-- --------------------------------------------------------------------------
-- The version cache
-- --------------------------------------------------------------------------

-- | On-disk schema version for the package-version cache. Bump this whenever
-- the encoding written by 'updateCache' changes, so caches from older builds
-- are rebuilt instead of being misread.
cacheFormatVersion :: Int
cacheFormatVersion = 6

-- | The directory the index cache lives in, as a plain 'FilePath'. The derived
-- index ('Bridge.Hackage.Store') is written beside the index it is derived from,
-- so it is found and invalidated with it rather than needing a path of its own.
cacheDirOf :: Sec.Cache -> FilePath
cacheDirOf = toFilePath . Sec.cacheRoot

-- | One @.cabal@ entry in the tar: when it was added, and where. A release has
-- one per revision, and the cache keeps them __newest first__: the revision in
-- force at a cutoff is then the first one at or before it, and a read at the
-- head, or at any cutoff after the last revision, decodes one pair per release
-- and skips the rest.
type Revision = (EpochTime, Word32)

-- | What one 'Revision' occupies on disk: 'put' writes an 'Int64' in 8 bytes
-- and a 'Word32' in 4, so the rest of a list can be skipped by arithmetic.
revisionBytes :: Int
revisionBytes = 12

-- | The cache is cabal's @01-index.cache@ in our shape: every @.cabal@ entry in
-- the tar, revisions included, with its time and block, grouped by package.
--
-- It is index-state-agnostic, as cabal's is. Filtering happens on every read
-- ('readVersionCache'), so a change of index-state never rebuilds it; only a
-- refresh of the index does.
--
-- On disk it is a header — format version, the head time, and how many packages
-- and releases follow — then one record per package, so that a read can decode
-- and fold one package at a time. Decoding the whole thing at once would put
-- ~250k boxed tuples on the heap for the duration, which is comparable to the
-- entire residency of a solve. The release count sizes the block array before
-- the fold starts; at an index-state before the head, its tail goes unused.
data CacheHeader = CacheHeader
    { chVersion  :: Int
    , chHead     :: EpochTime
    , chPackages :: Int
    , chReleases :: Int
    }

putHeader :: CacheHeader -> BSL.ByteString
putHeader CacheHeader{chVersion, chHead, chPackages, chReleases} =
    runPut (put chVersion >> put chHead >> put chPackages >> put chReleases)

getHeader :: Get CacheHeader
getHeader = CacheHeader <$> get <*> get <*> get <*> get

type PackageRecord = (PackageName, [(Version, [Revision])])

-- | A package's record, as 'put' lays it out: the name, then the releases as a
-- length-prefixed list, each a version and a length-prefixed list of
-- revisions. 'getRecordAt' reads that layout back by hand so that it can
-- filter as it decodes.
putRecord :: PackageRecord -> Put
putRecord = put

-- | Just the head time, for the refresh decision. 'Nothing' for a missing,
-- unreadable, or differently-versioned cache, which means "build one first".
readCacheHead :: FilePath -> IO (Maybe EpochTime)
readCacheHead path = do
    bytes <- either (const BSL.empty) id <$> tryIO (BSL.readFile path)
    pure $ case runGetOrFail getHeader bytes of
        Right (_, _, h) | chVersion h == cacheFormatVersion -> Just (chHead h)
        _                                                   -> Nothing

-- | Read the cache at an index-state: the packages as that state sees them,
-- and what the state came to. 'Nothing' if the file is missing, corrupt, or was
-- written by a different 'cacheFormatVersion'.
readVersionCache :: IndexState -> FilePath -> IO (Maybe (IndexStateInfo, Index))
readVersionCache state path = do
    bytes <- either (const BSL.empty) id <$> tryIO (BSL.readFile path)
    case runGetOrFail getHeader bytes of
        Right (rest, _, h) | chVersion h == cacheFormatVersion -> do
            blocks <- newArray (0, chReleases h - 1) 0 :: IO (IOUArray Int Word32)
            let go 0 _ !_ !latest !acc = pure (Just (latest, acc))
                go k bs !next !latest !acc = case runGetOrFail (getRecordAt cutoff) bs of
                    Left _ -> pure Nothing
                    Right (bs', _, (pn, t, vs, blks))
                        | null vs -> go (k - 1 :: Int) bs' next latest acc
                        | otherwise -> do
                            forM_ (zip [next ..] blks) $ \(i, blk) -> writeArray blocks i blk
                            let pkg = Package (Set.fromDistinctAscList vs) next (solverVersionsFrom vs blks)
                            go (k - 1) bs' (next + length vs) (max latest t) (Map.insert pn pkg acc)
            folded <- go (chPackages h) rest 0 Nothing Map.empty
            case folded of
                Nothing -> pure Nothing
                Just (latest, packages) -> do
                    frozen <- unsafeFreeze blocks
                    pure (Just (IndexStateInfo (chHead h) latest, Index packages frozen))
        _ -> pure Nothing
  where
    cutoff = case state of
        IndexHead -> Nothing
        IndexAt t -> Just (toEpoch t)

-- | Decode one package's record at an index-state. cabal's @filterCache@
-- followed by @packageListFromCache@, on one package: of a release's revisions
-- keep those at or before the cutoff, and the latest of them is the revision in
-- force. A release none of whose revisions survive does not exist there.
--
-- The result is the releases that exist, ascending by version, the block of
-- each one's revision in force in the same order, and the latest surviving
-- time, which is the index-state the run is really at. The latest survivor is
-- always somebody's revision in force, so the maximum over those is the maximum
-- over all survivors. Two lists rather than one of pairs because the version
-- list is kept ('pkgVersions') and the blocks are copied out, and a list of
-- pairs would keep both.
--
-- It filters __while__ decoding, and the list it never builds is the point: the
-- cache holds ~250k revisions, and materialising them per read cost a fifth of
-- a small solve's allocation. With revisions newest first, the revision in
-- force is the first at or before the cutoff, and the rest are skipped unread.
-- A record whose versions are not ascending fails to decode, since
-- 'Set.fromDistinctAscList' would otherwise take them on trust.
getRecordAt :: Maybe EpochTime -> Get (PackageName, Maybe EpochTime, [Version], [Word32])
getRecordAt cutoff = do
    pn <- get
    n <- get :: Get Int
    (latest, vs, blks) <- versions n Nothing Nothing [] []
    pure (pn, latest, vs, blks)
  where
    versions :: Int -> Maybe Version -> Maybe EpochTime -> [Version] -> [Word32] -> Get (Maybe EpochTime, [Version], [Word32])
    versions 0 _ !latest vs blks = pure (latest, reverse vs, reverse blks)
    versions k prev !latest vs blks = do
        v <- get
        when (maybe False (>= v) prev) (fail "versions out of order in the cache")
        m <- get :: Get Int
        inForce <- revisions m
        case inForce of
            Nothing       -> versions (k - 1) (Just v) latest vs blks
            Just (t, blk) -> versions (k - 1) (Just v) (max latest (Just t)) (v : vs) (blk : blks)

    -- Newest first: the first revision at or before the cutoff is in force.
    -- The guard on 'skip' is worth 10% of the read's allocation: most releases
    -- have one revision, and a zero-length skip is not free.
    revisions :: Int -> Get (Maybe Revision)
    revisions 0 = pure Nothing
    revisions m = do
        t <- get
        blk <- get
        if maybe True (t <=) cutoff
            then Just (t, blk) <$ when (m > 1) (skip ((m - 1) * revisionBytes))
            else revisions (m - 1)

-- | Rebuild the cache from the index: one pass over every tar entry, in order,
-- revisions included. This is the one place that reads the whole tar, and it
-- runs once per refresh.
--
-- @directoryEntries@ would be cheaper, and is wrong for this: it lists each
-- path once, at its last occurrence, so it knows a release by the time of its
-- latest revision and not of its upload. A release uploaded in 2019 and revised
-- in 2025 would then not exist at any index-state before 2025.
updateCache :: FilePath -> Sec.IndexCallbacks -> IO ()
updateCache path Sec.IndexCallbacks{Sec.indexDirectory, Sec.indexLookupEntry} = do
    (headTime, entries) <- walk (Sec.directoryFirst indexDirectory) 0 Map.empty
    let -- Entries were consed on arrival, so each list is already newest first,
        -- which is the order 'getRecordAt' wants.
        records = [(pn, Map.toAscList vs) | (pn, vs) <- Map.toAscList entries]
        header = CacheHeader cacheFormatVersion headTime (length records) (sum (map Map.size (Map.elems entries)))
    BSL.writeFile path (putHeader header <> runPut (mapM_ putRecord records))
  where
    walk entry !headTime !acc = do
        (Some ie, next) <- indexLookupEntry entry
        let !t = Sec.indexEntryTime ie
            !blk = Sec.directoryEntryBlockNo entry
            acc' = case Sec.indexEntryPathParsed ie of
                Just (Sec.IndexPkgCabal (PackageIdentifier pn v)) ->
                    Map.alter (Just . Map.alter (Just . ((t, blk) :) . fromMaybe []) v . fromMaybe Map.empty) pn acc
                _ -> acc
        case next of
            Nothing -> pure (max headTime t, acc')
            Just n  -> walk n (max headTime t) acc'

-- --------------------------------------------------------------------------
-- Parsing and errors
-- --------------------------------------------------------------------------

type Result e a = Either (Either SomeException e) a

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
