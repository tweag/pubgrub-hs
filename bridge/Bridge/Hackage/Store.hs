{-# LANGUAGE BangPatterns         #-}
{-# LANGUAGE DeriveAnyClass       #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TupleSections        #-}
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
-- Two files, and the granularity is the __package__, not the release:
--
-- * @derived-index.cbor@ — for each package, one CBOR-encoded slice holding all
--   of its releases, each tagged with the tar block it was parsed from;
-- * @derived-index.idx@ — @(formatVersion, Map PackageName (offset, length))@,
--   read whole at startup.
--
-- Package granularity is deliberate, and is what Dart's pub does: its
-- @\<name\>-versions.json@ carries every version's manifest, so walking a
-- release's neighbours touches data already in hand. One slice averages ~8
-- releases and ~3.2 KB, so a neighbour walk costs one read and one decode for the
-- whole package rather than one per release. It also keeps the resident index at
-- 19,419 entries instead of 152,987.
--
-- The store is a __cache, not a source of truth__: 'srLookup' answers
-- 'Nothing' for anything it does not have, and the caller falls back to parsing.
-- A missing, truncated or stale-format store therefore costs speed and never
-- correctness.
module Bridge.Hackage.Store
    ( StorePaths (..)
    , storePaths
    , StoreReader (..)
    , openStore
    , buildStore
    , storeFormatVersion
    ) where

import           PubGrub.Cabal.Flatten                  (LibNode (..),
                                                         Node (..),
                                                         StoredRelease (..))
import           Codec.Serialise                        (Serialise (..),
                                                         deserialiseOrFail,
                                                         serialise)
import           Codec.Serialise.Decoding               (decodeListLen)
import           Codec.Serialise.Encoding               (encodeListLen)
import           Control.Exception                      (SomeException, try)
import           Data.ByteString.Lazy                   (ByteString)
import qualified Data.ByteString.Lazy                   as BL
import           Data.IORef                             (IORef, atomicModifyIORef',
                                                         newIORef, readIORef)
import           Data.Int                               (Int64)
import           Data.List.NonEmpty                     (NonEmpty (..))
import           Data.Map.Strict                        (Map)
import qualified Data.Map.Strict                        as Map
import           Data.Set                               (Set)
import qualified Data.Set                               as Set
import           Data.Word                              (Word32)
import           Distribution.Compat.NonEmptySet        (NonEmptySet)
import qualified Distribution.Compat.NonEmptySet        as NES
import           Distribution.Compiler                  (CompilerFlavor)
import           Distribution.System                    (Arch, OS)
import           Distribution.Types.Condition            (Condition (..))
import           Distribution.Types.CondTree             (CondBranch (..),
                                                          CondTree (..))
import           Distribution.Types.ConfVar              (ConfVar (..))
import           Distribution.Types.Dependency           (Dependency (..))
import           Distribution.Types.ExeDependency        (ExeDependency)
import           Distribution.Types.Flag                 (FlagName, mkFlagName,
                                                          unFlagName)
import           Distribution.Types.LibraryName          (LibraryName (..))
import           Distribution.Types.PackageName          (PackageName,
                                                          mkPackageName,
                                                          unPackageName)
import           Distribution.Types.PkgconfigDependency  (PkgconfigDependency (..))
import           Distribution.Types.PkgconfigName        (PkgconfigName,
                                                          mkPkgconfigName,
                                                          unPkgconfigName)
import           Distribution.Types.PkgconfigVersion      (PkgconfigVersion)
import           Distribution.Types.PkgconfigVersionRange (PkgconfigVersionRange)
import           Distribution.Types.UnqualComponentName  (UnqualComponentName,
                                                          mkUnqualComponentName,
                                                          unUnqualComponentName)
import           Distribution.Types.Version              (Version, mkVersion,
                                                          versionNumbers)
import           Distribution.Types.VersionRange         (VersionRange)
import           System.Directory                        (doesFileExist,
                                                          renameFile)
import           System.IO                               (IOMode (..), hClose,
                                                          hSeek, SeekMode (..),
                                                          openBinaryFile,
                                                          withBinaryFile)

-- --------------------------------------------------------------------------
-- Codec
-- --------------------------------------------------------------------------

-- | Bumped whenever the encoding or the stored shape changes. A store written by
-- a different version is ignored rather than misread, as
-- 'Bridge.Hackage.readVersionCache' does: a generic encoding is positional, so
-- reordering a constructor silently changes its meaning.
storeFormatVersion :: Int
storeFormatVersion = 6

-- These are orphans. They belong here rather than in Cabal-syntax, and wrapping
-- every type in a newtype to avoid the orphan would cost more clarity than it
-- buys in a private library.
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
instance (Serialise v, Serialise c, Serialise a) => Serialise (CondBranch v c a)
instance (Serialise v, Serialise c, Serialise a) => Serialise (CondTree v c a)
instance Serialise ExeDependency
instance Serialise LibNode
instance Serialise Node
instance Serialise StoredRelease

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
data StoreReader = StoreReader
    { srLookup :: PackageName -> Version -> Word32 -> IO (Maybe StoredRelease)
    -- ^ 'Nothing' when the store has no entry, which the caller answers by
    -- parsing. Decoding a package's slice is memoised, so the second release of
    -- a package — and every neighbour of it — costs a map lookup.
    --
    -- The 'Word32' is the tar block of the revision the caller wants
    -- ('Bridge.Hackage.ihBlockOf'), and an entry is served only if it was
    -- parsed from that block. A release revised after the store was built, or
    -- read at an index-state before its latest revision, is therefore a miss
    -- and not a wrong answer.
    , srStats  :: IO (Int, Int)
    -- ^ @(slices decoded, entries served)@.
    }

-- | Open a store, or answer 'Nothing' if there is none here, it is unreadable, or
-- it was written by a different 'storeFormatVersion'.
openStore :: FilePath -> IO (Maybe StoreReader)
openStore dir = do
    let StorePaths{spBlob, spIndex} = storePaths dir
    haveBoth <- (&&) <$> doesFileExist spBlob <*> doesFileExist spIndex
    if not haveBoth
        then pure Nothing
        else do
            raw <- try (BL.readFile spIndex) :: IO (Either SomeException ByteString)
            case raw of
                Left _ -> pure Nothing
                Right bytes -> case deserialiseOrFail bytes of
                    Left _ -> pure Nothing
                    Right (v :: Int, offsets :: Map PackageName (Int64, Int64))
                        | v /= storeFormatVersion -> pure Nothing
                        | otherwise -> Just <$> mkReader spBlob offsets

-- | The decoded-slice cache holds __one package__, not every package touched.
--
-- Decoding a slice yields every version of that package, which is what makes a
-- neighbour walk cheap — but retaining all of them for every package a solve
-- touches is pure cost, because 'Bridge.Provider.releaseReader' already memoises
-- the 'Release' it derives per @(package, version)@. Measured on @pandoc@, which
-- touches ~150 packages and barely more than one version of each, an unbounded
-- slice cache costs __39.6 MB of peak residency where holding one costs 23.0__.
--
-- One slot is enough because the access pattern that needs it is package-local:
-- a walk asks for a release's neighbours, and those are all in the slice just
-- decoded. Interleaving packages costs a re-decode, not a wrong answer.
mkReader :: FilePath -> Map PackageName (Int64, Int64) -> IO StoreReader
mkReader blob offsets = do
    cacheRef <- newIORef (Nothing :: Maybe (PackageName, Map Version (Word32, StoredRelease)))
    statsRef <- newIORef (0 :: Int, 0 :: Int)
    let slice pn = do
            cached <- readIORef cacheRef
            case cached of
                Just (pn', m) | pn' == pn -> pure (Just m)
                _ -> case Map.lookup pn offsets of
                    Nothing -> pure Nothing
                    Just (off, len) -> do
                        bytes <- readSlice blob off len
                        case deserialiseOrFail bytes of
                            Left _ -> pure Nothing
                            Right entries -> do
                                let m = Map.fromList [(v, (blk, sr)) | (v, blk, sr) <- entries]
                                atomicModifyIORef' cacheRef (const (Just (pn, m), ()))
                                atomicModifyIORef' statsRef (\(d, s) -> ((d + 1, s), ()))
                                pure (Just m)
    pure
        StoreReader
            { srLookup = \pn v blk -> do
                found <- slice pn
                let hit = case found >>= Map.lookup v of
                        Just (blk', sr) | blk' == blk -> Just sr
                        _                             -> Nothing
                case hit of
                    Just _ -> atomicModifyIORef' statsRef (\(d, s) -> ((d, s + 1), ()))
                    Nothing -> pure ()
                pure hit
            , srStats = readIORef statsRef
            }

readSlice :: FilePath -> Int64 -> Int64 -> IO ByteString
readSlice path off len = do
    h <- openBinaryFile path ReadMode
    hSeek h AbsoluteSeek (fromIntegral off)
    bytes <- BL.hGet h (fromIntegral len)
    -- Force before closing: BL.hGet is lazy and the handle must outlive the read.
    BL.length bytes `seq` hClose h
    pure bytes

-- | Build the store from a reader of parsed releases, each with the tar block
-- it was parsed from, which is what 'srLookup' checks a request against.
--
-- Written to temporary names and renamed at the end, so an interrupted build
-- leaves the previous store intact rather than a half-written one that
-- 'openStore' would have to detect.
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
    offsets <- withBinaryFile tmpBlob WriteMode $ \h -> do
        let go :: Int64 -> Map PackageName (Int64, Int64) -> Int -> [(PackageName, Set Version)] -> IO (Map PackageName (Int64, Int64))
            go !_off !acc !done [] = do
                progress done total
                pure acc
            go !off !acc !done ((pn, vs) : rest) = do
                entries <-
                    sequence
                        [ fmap (\(blk, sr) -> (v, blk, sr)) <$> readOne pn v
                        | v <- Set.toList vs
                        ]
                let kept = [e | Just e <- entries]
                    bytes = serialise kept
                    len = BL.length bytes
                BL.hPut h bytes
                let acc' = if null kept then acc else Map.insert pn (off, len) acc
                progress' done total
                go (off + len) acc' (done + 1) rest
            progress' done t
                | done `mod` 500 == 0 = progress done t
                | otherwise = pure ()
        go 0 Map.empty 0 pkgs
    BL.writeFile tmpIndex (serialise (storeFormatVersion, offsets))
    renameFile tmpBlob spBlob
    renameFile tmpIndex spIndex
