{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}

-- | Build the derived index: parse every release in the Hackage index once and
-- write it out in the pre-environment form 'Bridge.Hackage.Store' reads.
--
-- @cabal run pubgrub-index@ builds at the head of the index;
-- @cabal run pubgrub-index -- --index-state TIMESTAMP@ builds the index as it was
-- then. Each entry is stored at the revision in force at the build's state and
-- served only for that revision, so a store built at the head leaves every
-- release revised since a pinned run's state to be parsed by that run. The gate
-- and the harness run at the pin in @bench/index-state@, so build there.
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
import           Bridge.Hackage             (IndexHandle (..),
                                             IndexState (..),
                                             IndexStateInfo (..),
                                             IndexStateTooNew (..),
                                             cacheDirOf, mkCache,
                                             parseIndexState,
                                             showIndexState,
                                             withHackageIndex)
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
import           Options.Applicative        (Parser, eitherReader, execParser,
                                             fullDesc, header, help, helper,
                                             info, long, metavar, option,
                                             progDesc, value, (<**>))
import           System.Directory           (getFileSize)
import           System.Exit                (exitFailure)
import           System.IO                  (hPutStrLn, stderr)
import           Text.Printf                (printf)
import           UnliftIO                   (MonadIO (liftIO), MonadUnliftIO)
import qualified UnliftIO

newtype Env = Env {envText :: LogAction App Text}

newtype App a = App {unApp :: ReaderT Env IO a}
    deriving newtype (Functor, Applicative, Monad, MonadIO, MonadUnliftIO, MonadReader Env)

instance HasLog Env Text App where
    getLogAction = envText
    setLogAction a e = e {envText = a}

newtype Options = Options {optIndexState :: IndexState}

options :: Parser Options
options =
    Options
        <$> option
            (eitherReader parseIndexState)
            ( long "index-state"
                <> metavar "TIMESTAMP"
                <> value IndexHead
                <> help "Build the index as it was at this time, e.g. 2016-09-24T17:47:48Z, as the driver's --index-state reads it; build at the state the gate and the harness run at (bench/index-state) and no pinned run parses (default: the head of the local index)"
            )

main :: IO ()
main = do
    opts <-
        execParser
            (info (options <**> helper) (fullDesc <> progDesc "Parse every release once into the derived index" <> header "pubgrub-index - build the derived index"))
    cache <- mkCache <$> makeAbsolute (fromFilePath "_cache")
    manager <- newManager defaultManagerSettings
    -- An index-state the local index cannot honour is reported, not built at.
    UnliftIO.handle tooNew $
        runReaderT
            (unApp (withHackageIndex cache manager (optIndexState opts) (build (cacheDirOf cache))))
            (Env (LogAction (liftIO . TIO.putStrLn)))
  where
    tooNew (IndexStateTooNew msg) = hPutStrLn stderr msg >> exitFailure

build :: FilePath -> IndexHandle -> App ()
build dir handle = do
    let versions = ihVersions handle
        packages = Map.size versions
        releases = sum (map Set.size (Map.elems versions))
    logMsg . T.pack $
        printf
            "parsing %d releases across %d packages, at index-state %s"
            releases
            packages
            (maybe "none" showIndexState (isiEffective (ihState handle)))
    start <- liftIO getMonotonicTime
    liftIO $
        buildStore
            dir
            versions
            -- A release that will not parse is simply absent from the store, and
            -- absence means "fall back to parsing" — which will fail there too,
            -- identically. So a broken .cabal costs one wasted parse per solve
            -- that reaches it, and never a wrong answer.
            --
            -- Each entry is tagged with the tar block it was parsed from, so a
            -- later run at any index-state can tell whether the store holds
            -- the revision it wants.
            (\pn v -> case ihBlockOf handle pn v of
                Nothing  -> pure Nothing
                Just blk -> either (const Nothing) (\gpd -> Just (blk, toStored gpd)) <$> ihLookupGPD handle pn v)
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
