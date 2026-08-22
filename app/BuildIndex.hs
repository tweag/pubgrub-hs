{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}

-- | Build the derived index: parse every release in the Hackage index once and
-- write it out in the pre-environment form 'Bridge.Hackage.Store' reads.
--
-- @cabal run pubgrub-index@
--
-- This is the one place the whole index is parsed. It takes a few minutes, and
-- afterwards a solve decodes entries instead of parsing them — measured at
-- __0.073 ms against 2.0 ms__, which is what makes reading a release's
-- /neighbours/ affordable (see the module haddock on 'Bridge.Hackage.Store').
--
-- Safe to interrupt: the store is written under temporary names and renamed only
-- once complete, so a killed build leaves the previous store — or no store —
-- rather than a half-written one. Safe to omit entirely: without it every lookup
-- falls back to parsing.
module Main (main) where

import           Bridge.Cabal.Flatten       (toStored)
import           Bridge.Hackage             (IndexHandle (..), cacheDirOf,
                                             mkCache, withHackageIndex)
import           Bridge.Hackage.Store       (buildStore, storePaths,
                                             StorePaths (..))
import           Colog                      (HasLog (..), LogAction (..),
                                             logMsg)
import           Control.Monad.Reader       (MonadReader, ReaderT, runReaderT)
import qualified Data.Map.Strict            as Map
import qualified Data.Set                   as Set
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import qualified Data.Text.IO               as TIO
import           GHC.Clock                  (getMonotonicTime)
import           Hackage.Security.Util.Path (fromFilePath, makeAbsolute)
import           Network.HTTP.Client        (defaultManagerSettings, newManager)
import           System.Directory           (getFileSize)
import           Text.Printf                (printf)
import           UnliftIO                   (MonadIO (liftIO), MonadUnliftIO)

newtype Env = Env {envText :: LogAction App Text}

newtype App a = App {unApp :: ReaderT Env IO a}
    deriving newtype (Functor, Applicative, Monad, MonadIO, MonadUnliftIO, MonadReader Env)

instance HasLog Env Text App where
    getLogAction = envText
    setLogAction a e = e {envText = a}

main :: IO ()
main = do
    cache <- mkCache <$> makeAbsolute (fromFilePath "_cache")
    manager <- newManager defaultManagerSettings
    runReaderT
        (unApp (withHackageIndex cache manager (build (cacheDirOf cache))))
        (Env (LogAction (liftIO . TIO.putStrLn)))

build :: FilePath -> IndexHandle -> App ()
build dir handle = do
    let versions = ihVersions handle
        packages = Map.size versions
        releases = sum (map Set.size (Map.elems versions))
    logMsg . T.pack $
        printf "parsing %d releases across %d packages" releases packages
    start <- liftIO getMonotonicTime
    liftIO $
        buildStore
            dir
            versions
            -- A release that will not parse is simply absent from the store, and
            -- absence means "fall back to parsing" — which will fail there too,
            -- identically. So a broken .cabal costs one wasted parse per solve
            -- that reaches it, and never a wrong answer.
            (\pn v -> either (const Nothing) (Just . toStored) <$> ihLookupGPD handle pn v)
            (\done total -> printf "\r  %d/%d packages" done total)
    done <- liftIO getMonotonicTime
    let StorePaths{spBlob, spIndex} = storePaths dir
    blobSize <- liftIO (getFileSize spBlob)
    idxSize <- liftIO (getFileSize spIndex)
    logMsg . T.pack $
        printf
            "\nwrote %.1f MB (+ %.1f MB index) in %.0f s"
            (fromIntegral blobSize / 1e6 :: Double)
            (fromIntegral idxSize / 1e6 :: Double)
            (done - start)
