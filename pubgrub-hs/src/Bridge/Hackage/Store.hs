{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | A derived index: every release's @.cabal@, parsed once and kept in the
-- __pre-environment__ form ('PubGrub.Cabal.Flatten.StoredRelease').
--
-- == Why this exists
--
-- Reading one release costs a @parseGenericPackageDescription@, measured at
-- __2.0 ms and ~7.7 MB of allocation__ against __0.019 ms__ to flatten the
-- result, a ratio of about 106 : 1 (@prototype\/IndexBench.hs@). Generation-time
-- depender collapsing (@references\/pubgrub.md:456@) has to read a release's
-- neighbours to learn what they declare, and at 2 ms a read it took @pandoc@
-- from 167 reads to 2834.
--
-- Decoding an entry from here is __0.073 ms__, 27x cheaper than parsing, which
-- makes that walk affordable.
--
-- == Why the /pre-environment/ form
--
-- Flattening resolves @os@, @arch@ and @impl@ against this machine
-- ('PubGrub.Cabal.Flatten.envConfVar'), and buildability also resolves
-- @pkgconfig-depends@ against its @pkg-config@ database. A store of /flattened/
-- dependencies would be silently wrong the day someone upgrades GHC or installs
-- @libpq@. Flattening is 0.5% of the cost, so it stays live and only the parse
-- is cached. One store then survives toolchain changes, and serves either
-- flag model.
--
-- == Layout
--
-- Two files, and the granularity is the __release__:
--
-- * @derived-index.cbor@ — one CBOR entry per release, @(package, version,
--   'StoredRelease')@, one after another;
-- * @derived-index.idx@ — the format version, then one fixed-width record per
--   entry, @(block, offset, length)@, sorted by block. It is read whole at
--   startup and searched as it lies, with nothing decoded.
--
-- The key is the tar block the entry was parsed from, which names one revision
-- of one @.cabal@, and is what the caller already holds
-- ('Bridge.Hackage.ihBlockOf'). Finding the block is therefore the whole
-- validity check, and the package and version stored in the entry are compared
-- only so that a store built against some other tar is a miss and not a wrong
-- answer.
--
-- A slice per package, decoded whole on the first lookup, would put a
-- neighbour walk's releases in hand, but it decodes far more than it serves:
-- on @haskell-language-server@, 6,292 releases to serve 3,612, and the decode
-- was half the solve's allocation. Every release is read at most once anyway,
-- since 'Bridge.Provider.releaseReader' memoises the 'Release' it derives.
--
-- The store is a __cache, not a source of truth__: 'srLookup' answers
-- 'Nothing' for anything it does not have, and the caller falls back to parsing.
-- A missing, truncated or stale-format store therefore costs speed and never
-- correctness.
module Bridge.Hackage.Store
    ( StorePaths (..)
    , storePaths
    , StoreReader (..)
    , withStore
    , buildStore
    , storeFormatVersion
    , StoreCorrupt (..)
    ) where

import           Codec.Serialise                          (Serialise (..),
                                                           deserialiseOrFail,
                                                           serialise)
import           Codec.Serialise.Decoding                 (decodeBytes,
                                                           decodeListLen)
import           Codec.Serialise.Encoding                 (encodeBytes,
                                                           encodeListLen)
import           Control.Exception                        (Exception,
                                                           SomeException, throw,
                                                           try)
import           Control.Monad                            (foldM, when)
import           Data.Bits                                (shiftL, (.|.))
import qualified Data.ByteString                          as BS
import qualified Data.ByteString.Builder                  as BB
import qualified Data.ByteString.Lazy                     as BL
import           Data.Int                                 (Int64)
import           Data.List                                (sortOn)
import           Data.List.NonEmpty                       (NonEmpty (..))
import           Data.Map.Strict                          (Map)
import qualified Data.Map.Strict                          as Map
import           Data.Set                                 (Set)
import qualified Data.Set                                 as Set
import           Data.Word                                (Word32, Word64)
import qualified Distribution.Compat.NonEmptySet          as NES
import           Distribution.Compiler                    (CompilerFlavor)
import           Distribution.System                      (Arch, OS)
import           Distribution.Types.Condition             (Condition (..))
import           Distribution.Types.ConfVar               (ConfVar (..))
import           Distribution.Types.Dependency            (Dependency (..))
import           Distribution.Types.ExeDependency         (ExeDependency)
import           Distribution.Types.Flag                  (FlagName, mkFlagName,
                                                           unFlagName)
import           Distribution.Types.LibraryName           (LibraryName (..))
import           Distribution.Types.PackageName           (PackageName,
                                                           mkPackageName,
                                                           unPackageName)
import           Distribution.Types.PkgconfigDependency   (PkgconfigDependency (..))
import           Distribution.Types.PkgconfigName         (PkgconfigName,
                                                           mkPkgconfigName,
                                                           unPkgconfigName)
import           Distribution.Types.PkgconfigVersion      (PkgconfigVersion)
import           Distribution.Types.PkgconfigVersionRange (PkgconfigVersionRange)
import           Distribution.Types.UnqualComponentName   (UnqualComponentName,
                                                           mkUnqualComponentName,
                                                           unUnqualComponentName)
import           Distribution.Types.Version               (Version, mkVersion,
                                                           versionNumbers)
import           Distribution.Types.VersionRange          (VersionRange)
import           PubGrub.Cabal.Flatten                    (Branch (..),
                                                           LibNode (..),
                                                           Node (..),
                                                           StoredRelease (..),
                                                           Tree (..))
import           System.Directory                         (doesFileExist,
                                                           renameFile)
import           System.IO                                (Handle, IOMode (..),
                                                           SeekMode (..), hSeek,
                                                           withBinaryFile)

-- --------------------------------------------------------------------------
-- Codec
-- --------------------------------------------------------------------------

-- | Bumped whenever the encoding or the stored shape changes. A store written by
-- a different version is ignored rather than misread, as
-- 'Bridge.Hackage.readVersionCache' does: a generic encoding is positional, so
-- reordering a constructor silently changes its meaning.
storeFormatVersion :: Int
storeFormatVersion = 11

-- These are orphans. They belong here rather than in Cabal-syntax, and wrapping
-- every type in a newtype to avoid the orphan would cost more clarity than it
-- buys in an unpublished library.
--
-- Most go through 'Generic'. The exceptions are the types whose representation is
-- abstract or lacks a 'Generic' instance, and each of those is encoded through the
-- constructor/destructor pair its own module exports.
instance Serialise PackageName where
    encode = encode . unPackageName
    decode = mkPackageName <$> decode

instance Serialise FlagName where
    encode = encode . unFlagName
    decode = mkFlagName <$> decode

instance Serialise UnqualComponentName where
    encode = encode . unUnqualComponentName
    decode = mkUnqualComponentName <$> decode

instance Serialise PkgconfigName where
    encode = encode . unPkgconfigName
    decode = mkPkgconfigName <$> decode

instance Serialise Version where
    encode = encode . versionNumbers
    decode = mkVersion <$> decode

-- | 'Dependency' is the reason a generic derivation cannot be used throughout:
-- it holds a @NonEmptySet LibraryName@, which has no 'Generic' instance.
instance Serialise Dependency where
    encode (Dependency pn vr libs) =
        encodeListLen 3 <> encode pn <> encode vr <> encode (NES.toList libs)
    decode = do
        _ <- decodeListLen
        pn <- decode
        vr <- decode
        libs <- decode
        case libs of
            []       -> fail "Dependency with no library names"
            (l : ls) -> pure (Dependency pn vr (NES.fromNonEmpty (l :| ls)))

instance Serialise LibraryName
instance Serialise VersionRange
instance Serialise PkgconfigVersion
instance Serialise PkgconfigVersionRange
instance Serialise PkgconfigDependency
instance Serialise OS
instance Serialise Arch
instance Serialise CompilerFlavor
instance Serialise ConfVar
instance Serialise a => Serialise (Condition a)
instance Serialise a => Serialise (Branch a)
instance Serialise a => Serialise (Tree a)
instance Serialise ExeDependency
instance Serialise LibNode
instance Serialise Node

-- | Hand-written, unlike its neighbours, so that the test suites and benchmarks
-- can be skipped. Each is a CBOR byte string holding its own CBOR encoding. The
-- byte string's header carries its length, so decoding the entry steps over it
-- without building it, and the field is a thunk that decodes the bytes when
-- forced. A driver that reads no stanzas never forces them, and they are 29% of
-- the store's bytes.
--
-- The thunk cannot answer 'Nothing' the way a lookup does, because the lookup has
-- returned by the time it runs. Bytes that fail to decode there throw
-- 'StoreCorrupt', and only damage to the file can cause that: the entry around
-- them decoded, and was written by the same encoder.
instance Serialise StoredRelease where
    encode sr =
        encodeListLen 7
            <> encode (srFlags sr)
            <> encode (srManual sr)
            <> encode (srLibrary sr)
            <> encode (srOthers sr)
            <> deferred (srTests sr)
            <> deferred (srBenchmarks sr)
            <> encode (srSetup sr)
      where
        deferred x = encodeBytes (BL.toStrict (serialise x))
    decode = do
        n <- decodeListLen
        when (n /= 7) (fail "a stored release with the wrong number of fields")
        flags <- decode
        manual <- decode
        library <- decode
        others <- decode
        tests <- undefer <$> decodeBytes
        benchmarks <- undefer <$> decodeBytes
        setup <- decode
        pure
            StoredRelease
                { srFlags = flags
                , srManual = manual
                , srLibrary = library
                , srOthers = others
                , srTests = tests
                , srBenchmarks = benchmarks
                , srSetup = setup
                }
      where
        undefer bytes = case deserialiseOrFail (BL.fromStrict bytes) of
            Right x  -> x
            Left err -> throw (StoreCorrupt (show err))

-- | A deferred section of a stored release failed to decode when it was forced.
newtype StoreCorrupt = StoreCorrupt String

instance Show StoreCorrupt where
    show (StoreCorrupt err) =
        "the derived index is damaged (" <> err <> "); delete _cache/derived-index.* or run pubgrub-index again"

instance Exception StoreCorrupt

-- --------------------------------------------------------------------------
-- On disk
-- --------------------------------------------------------------------------

data StorePaths = StorePaths
    { spBlob  :: FilePath
    , spIndex :: FilePath
    }

storePaths :: FilePath -> StorePaths
storePaths dir =
    StorePaths
        { spBlob = dir <> "/derived-index.cbor"
        , spIndex = dir <> "/derived-index.idx"
        }

-- | What a solve reads the store through.
newtype StoreReader = StoreReader
    { srLookup :: PackageName -> Version -> Word32 -> IO (Maybe StoredRelease)
    -- ^ 'Nothing' when the store has no entry, which the caller answers by
    -- parsing. Each call reads and decodes one entry and keeps nothing:
    -- 'Bridge.Provider.releaseReader' memoises what it derives.
    --
    -- The 'Word32' is the tar block of the revision the caller wants
    -- ('Bridge.Hackage.ihBlockOf'), and it is the key: an entry is served only
    -- if it was parsed from that block. A release revised after the store was
    -- built, or read at an index-state before its latest revision, is therefore
    -- a miss and not a wrong answer.
    --
    -- One thread at a time: a lookup is a seek and then a read on one handle.
    }

-- | The index file opens with the format version in 8 bytes.
headerBytes :: Int
headerBytes = 8

-- | What one index record occupies: the block in 4 bytes, the entry's offset in
-- 8 and its length in 4, all big-endian. The reader finds a record by this
-- arithmetic, so a change to the layout must change both, and
-- 'storeFormatVersion' too.
recordBytes :: Int
recordBytes = 16

-- | Run an action with the store here, or with 'Nothing' if there is none, it is
-- unreadable, or it was written by a different 'storeFormatVersion'.
--
-- The data file stays open for the length of the action. Opening it per lookup
-- cost ~19 KB of handle buffers each, 70 MB of allocation on
-- @haskell-language-server@.
withStore :: FilePath -> (Maybe StoreReader -> IO a) -> IO a
withStore dir act = do
    let StorePaths{spBlob, spIndex} = storePaths dir
    haveBoth <- (&&) <$> doesFileExist spBlob <*> doesFileExist spIndex
    records <- if haveBoth then readIndex spIndex else pure Nothing
    case records of
        Nothing -> act Nothing
        Just rs -> withBinaryFile spBlob ReadMode $ \h -> act (Just (mkReader h rs))

-- | The index's records, once the header and the length check out.
readIndex :: FilePath -> IO (Maybe BS.ByteString)
readIndex path = do
    raw <- try (BS.readFile path) :: IO (Either SomeException BS.ByteString)
    pure $ case raw of
        Right bytes
            | BS.length bytes >= headerBytes
            , wordAt 8 bytes 0 == fromIntegral storeFormatVersion
            , (BS.length bytes - headerBytes) `mod` recordBytes == 0 ->
                Just (BS.drop headerBytes bytes)
        _ -> Nothing

-- | A reader over the index records, searched in place, and the open data file.
mkReader :: Handle -> BS.ByteString -> StoreReader
mkReader blob records =
    StoreReader
        { srLookup = \pn v blk -> case findBlock records blk of
            Nothing -> pure Nothing
            Just (off, len) -> do
                bytes <- readEntry blob off len
                pure $ case deserialiseOrFail (BL.fromStrict bytes) of
                    Right (pn', v', sr :: StoredRelease) | pn' == pn && v' == v -> Just sr
                    _ -> Nothing
        }

-- | Binary search for a block's record: the entry's offset and length.
findBlock :: BS.ByteString -> Word32 -> Maybe (Int64, Int)
findBlock records blk = go 0 (BS.length records `div` recordBytes)
  where
    go lo hi
        | lo >= hi = Nothing
        | otherwise =
            let mid = (lo + hi) `div` 2
                at = mid * recordBytes
             in case compare (fromIntegral (wordAt 4 records at)) blk of
                    LT -> go (mid + 1) hi
                    GT -> go lo mid
                    EQ -> Just (fromIntegral (wordAt 8 records (at + 4)), fromIntegral (wordAt 4 records (at + 12)))

-- | The big-endian word of @n@ bytes at @i@. Short at the end of the input
-- rather than partial, though 'readIndex' checks the length first.
wordAt :: Int -> BS.ByteString -> Int -> Word64
wordAt n bytes i = BS.foldl' (\acc b -> acc `shiftL` 8 .|. fromIntegral b) 0 (BS.take n (BS.drop i bytes))

readEntry :: Handle -> Int64 -> Int -> IO BS.ByteString
readEntry h off len = do
    hSeek h AbsoluteSeek (fromIntegral off)
    BS.hGet h len

-- | Build the store from a reader of parsed releases, each with the tar block
-- it was parsed from, which is what 'srLookup' checks a request against.
--
-- Written to temporary names and renamed at the end, so an interrupted build
-- leaves the previous store intact rather than a half-written one that
-- 'withStore' would have to detect.
buildStore
    :: FilePath
    -> Map PackageName (Set Version)
    -> (PackageName -> Version -> IO (Maybe (Word32, StoredRelease)))
    -> (Int -> Int -> IO ())
    -- ^ progress: packages done, of how many
    -> IO ()
buildStore dir versions readOne progress = do
    let StorePaths{spBlob, spIndex} = storePaths dir
        tmpBlob = spBlob <> ".tmp"
        tmpIndex = spIndex <> ".tmp"
        pkgs = Map.toList versions
        total = length pkgs
    records <- withBinaryFile tmpBlob WriteMode $ \h -> do
        let go :: Int64 -> [(Word32, Int64, Int64)] -> Int -> [(PackageName, Set Version)] -> IO [(Word32, Int64, Int64)]
            go !_off acc !done [] = do
                progress done total
                pure acc
            go !off acc !done ((pn, vs) : rest) = do
                (off', acc') <- foldM (entry pn) (off, acc) (Set.toList vs)
                progress' done total
                go off' acc' (done + 1) rest
            entry pn (!off, acc) v =
                readOne pn v >>= \case
                    Nothing -> pure (off, acc)
                    Just (blk, sr) -> do
                        let bytes = serialise (pn, v, sr)
                            len = BL.length bytes
                        BL.hPut h bytes
                        pure (off + len, (blk, off, len) : acc)
            progress' done t
                | done `mod` 500 == 0 = progress done t
                | otherwise = pure ()
        go 0 [] 0 pkgs
    BL.writeFile tmpIndex . BB.toLazyByteString $
        BB.word64BE (fromIntegral storeFormatVersion)
            <> foldMap
                (\(blk, off, len) -> BB.word32BE blk <> BB.int64BE off <> BB.word32BE (fromIntegral len))
                (sortOn (\(blk, _, _) -> blk) records)
    renameFile tmpBlob spBlob
    renameFile tmpIndex spIndex
