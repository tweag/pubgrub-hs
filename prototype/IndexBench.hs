{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}

-- | __A throwaway measurement, not a component of the solver.__
--
-- It measures the three things that decide whether the derived index
-- ("Bridge.Hackage.Store") pays for itself:
--
--  1. __bytes per entry__, @binary@ against @serialise@ (CBOR), so the store's
--     total size on 152,746 releases can be extrapolated rather than guessed;
--  2. the __parse:flatten split__, because the whole design rests on parsing
--     being the expensive half. If flattening cost what parsing costs, caching a
--     pre-environment form would buy nothing;
--  3. __parse throughput__, to price the one-time build.
--
-- What it serialises is the __pre-environment__ form: guards keep their
-- 'ConfVar's, so @os@\/@arch@\/@impl@ are /not/ resolved against this machine and
-- the entry stays valid across a GHC upgrade or a pkg-config change. A flattened
-- form would not, because the flatten bakes in the environment
-- ('Bridge.Cabal.Flatten.envConfVar') and the parse does not.
--
-- The types below deliberately mirror that form in a __self-contained AST__
-- rather than reusing Cabal-syntax's. Two reasons: 'Dependency' holds a
-- @NonEmptySet LibraryName@ with no 'Generic', so a generic 'Serialise' instance
-- cannot be derived for it; and encoding both codecs over the /same/ declared
-- structure is what makes the size comparison fair, instead of comparing
-- Cabal-syntax's hand-written 'Binary' against a generic CBOR encoding.
--
-- __Known omission:__ @buildable@ and @pkgconfig-depends@ are not included, so
-- the byte counts are a slight under-estimate of a real entry. Dependencies
-- dominate, so this does not change the order of magnitude.
--
--   cabal run index-bench -- 2000
module Main (main) where

import           Bridge.Hackage                 (IndexHandle (..),
                                                IndexState (..), mkCache,
                                                 withHackageIndex)
import           Codec.Serialise                (Serialise)
import qualified Codec.Serialise                as CBOR
import           Colog                          (HasLog (..), LogAction (..),
                                                 logMsg)
import           Control.DeepSeq                (NFData, force)
import           Control.Exception              (evaluate)
import           Control.Monad                  (foldM)
import           Control.Monad.Reader           (MonadReader, ReaderT,
                                                 runReaderT)
import           Data.Binary                    (Binary)
import qualified Data.Binary                    as Binary
import qualified Data.ByteString.Lazy           as BL
import qualified Data.Map.Strict                as Map
import qualified Data.Set                       as Set
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import qualified Data.Text.IO                   as TIO
import           Distribution.Compiler          (CompilerFlavor)
import           Distribution.System            (Arch, OS)
import           Distribution.Types.Condition   (Condition (..))
import           Distribution.Types.CondTree    (CondBranch (..), CondTree (..))
import           Distribution.Types.ConfVar     (ConfVar (..))
import           Distribution.Types.Dependency  (Dependency (..))
import           Distribution.Types.Flag        (PackageFlag (..), unFlagName)
import           Distribution.Types.GenericPackageDescription (GenericPackageDescription (..))
import           Distribution.Types.LibraryName (LibraryName (..))
import           Distribution.Types.PackageName (PackageName, unPackageName)
import           Distribution.Types.UnqualComponentName (unUnqualComponentName)
import           Distribution.Types.Version     (Version)
import           Distribution.Types.VersionRange (VersionRange)
import qualified Distribution.Compat.NonEmptySet as NES
import           GHC.Clock                      (getMonotonicTime)
import           GHC.Generics                   (Generic)
import           Hackage.Security.Util.Path     (fromFilePath, makeAbsolute)
import           Network.HTTP.Client            (defaultManagerSettings,
                                                 newManager)
import qualified PubGrub.Version                as V
import qualified PubGrub.VersionSet             as VS
import           System.Environment             (getArgs)
import           Text.Printf                    (printf)
import           UnliftIO                       (MonadIO (liftIO),
                                                 MonadUnliftIO)

-- --------------------------------------------------------------------------
-- The pre-environment entry
-- --------------------------------------------------------------------------

-- | A version range as its canonical interval list, from
-- 'PubGrub.VersionSet.intervals': each bound is either absent (unbounded) or a
-- version plus whether the bound is inclusive. It encodes far smaller than the
-- syntactic 'VersionRange' tree.
newtype RawRange = RawRange [(([Int], Bool), Maybe ([Int], Bool))]
    deriving stock (Generic, Show)
    deriving anyclass (Binary, Serialise, NFData)

-- | One @build-depends@ entry: the package, the range, and which of its
-- libraries are wanted (empty meaning just the main one).
data RawDep = RawDep !String !RawRange ![String]
    deriving stock (Generic, Show)
    deriving anyclass (Binary, Serialise, NFData)

-- | A condition variable with the environment __unresolved__ — this is the whole
-- point of the pre-environment form.
data RawConfVar
    = RawOS !String
    | RawArch !String
    | RawImpl !String !RawRange
    | RawFlag !String
    deriving stock (Generic, Show)
    deriving anyclass (Binary, Serialise, NFData)

data RawCond
    = RawVar !RawConfVar
    | RawLit !Bool
    | RawNot RawCond
    | RawOr RawCond RawCond
    | RawAnd RawCond RawCond
    deriving stock (Generic, Show)
    deriving anyclass (Binary, Serialise, NFData)

-- | Everything a derived index would store for one release.
data RawRelease = RawRelease
    { rrFlags :: ![(String, Bool)]
    , rrDeps  :: ![(RawCond, [RawDep])]
    }
    deriving stock (Generic, Show)
    deriving anyclass (Binary, Serialise, NFData)

-- --------------------------------------------------------------------------
-- GenericPackageDescription -> the entry
-- --------------------------------------------------------------------------

toRange :: VersionRange -> RawRange
toRange = RawRange . map bounds . VS.intervals . VS.fromVersionRange
  where
    bounds (lo, hi) = (low lo, up hi)
    low (VS.Cut v side) = (V.versionNumbers v, side == VS.Before)
    low VS.Unbounded    = ([], False) -- unreachable: an empty interval is dropped
    up VS.Unbounded     = Nothing
    up (VS.Cut v side)  = Just (V.versionNumbers v, side == VS.After)

toDep :: Dependency -> RawDep
toDep (Dependency pn vr libs) =
    RawDep (unPackageName pn) (toRange vr) (map libName (NES.toList libs))
  where
    libName LMainLibName    = ""
    libName (LSubLibName n) = unUnqualComponentName n

toConfVar :: ConfVar -> RawConfVar
toConfVar = \case
    OS o          -> RawOS (show (o :: OS))
    Arch a        -> RawArch (show (a :: Arch))
    Impl f vr     -> RawImpl (show (f :: CompilerFlavor)) (toRange vr)
    PackageFlag f -> RawFlag (unFlagName f)

toCond :: Condition ConfVar -> RawCond
toCond = \case
    Var v     -> RawVar (toConfVar v)
    Lit b     -> RawLit b
    CNot c    -> RawNot (toCond c)
    COr a b   -> RawOr (toCond a) (toCond b)
    CAnd a b  -> RawAnd (toCond a) (toCond b)

-- | The same walk 'Bridge.Cabal.Flatten.flattenWith' does, except the guard keeps
-- its 'ConfVar's instead of being resolved against this machine.
walkTree :: CondTree ConfVar [Dependency] a -> [(RawCond, [RawDep])]
walkTree = go (RawLit True)
  where
    go guard node =
        (guard, map toDep (condTreeConstraints node))
            : concatMap (branch guard) (condTreeComponents node)
    branch guard br =
        go (RawAnd guard (toCond (condBranchCondition br))) (condBranchIfTrue br)
            ++ maybe
                []
                (go (RawAnd guard (RawNot (toCond (condBranchCondition br)))))
                (condBranchIfFalse br)

reduce :: GenericPackageDescription -> RawRelease
reduce gpd =
    RawRelease
        { rrFlags = [(unFlagName (flagName f), flagDefault f) | f <- genPackageFlags gpd]
        , rrDeps =
            concat $
                [walkTree t | t <- maybe [] pure (condLibrary gpd)]
                    ++ [walkTree t | (_, t) <- condSubLibraries gpd]
                    ++ [walkTree t | (_, t) <- condExecutables gpd]
        }

-- --------------------------------------------------------------------------
-- Driver
-- --------------------------------------------------------------------------

newtype Env = Env {envText :: LogAction App Text}

newtype App a = App {unApp :: ReaderT Env IO a}
    deriving newtype (Functor, Applicative, Monad, MonadIO, MonadUnliftIO, MonadReader Env)

instance HasLog Env Text App where
    getLogAction = envText
    setLogAction a e = e {envText = a}

-- | Spread the sample across packages rather than taking a prefix: dependency
-- shape varies far more between packages than between one package's releases, so
-- a prefix of the alphabet would measure @acme-*@ and call it Hackage.
sample :: Int -> Map.Map PackageName (Set.Set Version) -> [(PackageName, Version)]
sample n versions =
    take n [(pn, v) | (pn, vs) <- everyNth stride pkgs, v <- Set.toList vs]
  where
    pkgs = Map.toList versions
    stride = max 1 (length pkgs `div` max 1 (n `div` 4))
    everyNth k xs = case xs of
        []      -> []
        (y : ys) -> y : everyNth k (drop (k - 1) ys)

-- | Running totals. Times are seconds, sizes bytes.
data Stats = Stats
    { stN     :: !Int
    , stFail  :: !Int
    , stParse :: !Double
    , stFlat  :: !Double
    , stBin   :: !Int
    , stCbor  :: !Int
    , stEncB  :: !Double
    , stEncC  :: !Double
    , stDecB  :: !Double
    , stDecC  :: !Double
    }

emptyStats :: Stats
emptyStats = Stats 0 0 0 0 0 0 0 0 0 0

main :: IO ()
main = do
    args <- getArgs
    let n = case args of
            (a : _) | [(k, "")] <- reads a -> k
            _                              -> 2000
    cache <- mkCache <$> makeAbsolute (fromFilePath "_cache")
    manager <- newManager defaultManagerSettings
    runReaderT
        (unApp (withHackageIndex cache manager IndexHead (bench n)))
        (Env (LogAction (liftIO . TIO.putStrLn)))

bench :: Int -> IndexHandle -> App ()
bench n handle = do
    let versions = ihVersions handle
        picks = sample n versions
        allReleases = sum (map Set.size (Map.elems versions))
    logMsg . T.pack $
        printf
            "index: %d packages, %d releases; sampling %d"
            (Map.size versions)
            allReleases
            (length picks)
    stats <- liftIO (foldM (step handle) emptyStats picks)
    liftIO (report allReleases stats)

-- | One release: parse it, reduce it to the pre-environment entry, and encode
-- and decode that entry with both codecs. Each stage is forced before the clock
-- is read, so the split is between work done and not between thunks built.
step :: IndexHandle -> Stats -> (PackageName, Version) -> IO Stats
step handle st (pn, v) = do
    t0 <- getMonotonicTime
    result <- ihLookupGPD handle pn v
    case result of
        Left _ -> pure st{stFail = stFail st + 1}
        Right gpd -> do
            _ <- evaluate (force gpd)
            t1 <- getMonotonicTime
            raw <- evaluate (force (reduce gpd))
            t2 <- getMonotonicTime
            -- Encode, then decode back and force: decoding is what a neighbour
            -- lookup would actually pay, and it is the number the whole design
            -- turns on. Forcing matters doubly here because both libraries build
            -- the result lazily.
            binBs <- evaluate (force (Binary.encode raw))
            t3 <- getMonotonicTime
            cborBs <- evaluate (force (CBOR.serialise raw))
            t4 <- getMonotonicTime
            _ <- evaluate (force (Binary.decode binBs :: RawRelease))
            t5 <- getMonotonicTime
            _ <- evaluate (force (CBOR.deserialise cborBs :: RawRelease))
            t6 <- getMonotonicTime
            pure
                st
                    { stN = stN st + 1
                    , stParse = stParse st + (t1 - t0)
                    , stFlat = stFlat st + (t2 - t1)
                    , stBin = stBin st + fromIntegral (BL.length binBs)
                    , stCbor = stCbor st + fromIntegral (BL.length cborBs)
                    , stEncB = stEncB st + (t3 - t2)
                    , stEncC = stEncC st + (t4 - t3)
                    , stDecB = stDecB st + (t5 - t4)
                    , stDecC = stDecC st + (t6 - t5)
                    }

report :: Int -> Stats -> IO ()
report allReleases Stats{stN, stFail, stParse, stFlat, stBin, stCbor, stEncB, stEncC, stDecB, stDecC} = do
    let n = fromIntegral (max 1 stN) :: Double
        scale x = x / n * fromIntegral allReleases
    printf "\nsampled            %d releases (%d unparseable)\n" stN stFail
    printf "parse              %.3f ms/release\n" (stParse / n * 1000)
    printf "flatten            %.3f ms/release\n" (stFlat / n * 1000)
    printf
        "parse:flatten      %.1f : 1   <- the design rests on this being >> 1\n"
        (stParse / max 1e-9 stFlat)
    printf "\nbinary             %.0f B/release   -> %.1f MB over %d\n"
        (fromIntegral stBin / n) (scale (fromIntegral stBin) / 1e6) allReleases
    printf "serialise (CBOR)   %.0f B/release   -> %.1f MB over %d\n"
        (fromIntegral stCbor / n) (scale (fromIntegral stCbor) / 1e6) allReleases
    printf "CBOR/binary        %.2f\n" (fromIntegral stCbor / fromIntegral (max 1 stBin) :: Double)
    printf "\nencode  binary     %.3f ms/release\n" (stEncB / n * 1000)
    printf "encode  CBOR       %.3f ms/release\n" (stEncC / n * 1000)
    printf "decode  binary     %.3f ms/release\n" (stDecB / n * 1000)
    printf "decode  CBOR       %.3f ms/release\n" (stDecC / n * 1000)
    printf
        "\nspeedup vs parse   binary %.0fx   CBOR %.0fx   <- cost of one neighbour\n"
        (stParse / max 1e-9 stDecB)
        (stParse / max 1e-9 stDecC)
    printf "\nfull-index build   %.1f s (parse only, single-threaded)\n"
        (scale stParse)
