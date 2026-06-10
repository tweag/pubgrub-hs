{-# LANGUAGE DerivingVia         #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE ImportQualifiedPost #-}

module Main where

import           Colog                           (LogAction (..))
import           Colog.Monad
import           Control.Monad                   (when)
import           Data.Maybe                      (fromMaybe)
import           Data.Time.Clock                 (NominalDiffTime, UTCTime,
                                                  diffUTCTime, getCurrentTime)
import           Distribution.PackageDescription (mkPackageName)
import           Distribution.Parsec             (eitherParsec)
import           Distribution.Types.VersionRange (VersionRange)
import           GHC.Stack                       (HasCallStack)
import           Hackage.Security.Client         (CacheLayout (..),
                                                  KeyThreshold (..), bootstrap,
                                                  checkForUpdates,
                                                  requiresBootstrap)
import           Hackage.Security.Unlifted
import           Hackage.Security.Util.Path      (Absolute, Path, doesFileExist,
                                                  fragment, fromFilePath,
                                                  getModificationTime,
                                                  makeAbsolute, rootPath, (</>))
import           Network.HTTP.Client             (Manager,
                                                  defaultManagerSettings,
                                                  newManager)
import qualified Network.URI
import qualified PubGrub.VersionSet              as VS
import           Solver                          (hackageSink, runSolve,
                                                  solverSink)
import           System.Environment              (getArgs)
import           UnliftIO                        (MonadIO (..))

main :: IO ()
main = do
  manager <- liftIO $ newManager defaultManagerSettings
  cache <- mkCache <$> makeAbsolute (fromFilePath "_cache")
  args <- getArgs
  case args of
    (pkgStr : rest) -> do
      let target = mkPackageName pkgStr
          range = case rest of
            [] -> VS.full
            (r : _) -> case eitherParsec r :: Either String VersionRange of
              Right vr -> VS.fromVersionRange vr
              Left err -> error ("invalid version range: " ++ err)
      usingLoggerT solverSink $
        withHackage cache manager (liftIO . unLogAction hackageSink) $ \repository ->
          withIndex repository $ \indexCallbacks ->
            runSolve indexCallbacks target range
    [] -> putStrLn "usage: pubgrub-hs <package> [version-range]"

parseURI :: (HasCallStack) => [Char] -> URI
parseURI str = fromMaybe (error $ "failed parsing URI " ++ str) $ Network.URI.parseURI str

mkCache :: Path Absolute -> Cache
mkCache root =
  Cache {cacheRoot = root, cacheLayout = cabalCacheLayout}
  where
    cabalCacheLayout :: CacheLayout
    cabalCacheLayout =
      CacheLayout
        { cacheLayoutRoot = rootPath $ fragment "root.json",
          cacheLayoutTimestamp = rootPath $ fragment "timestamp.json",
          cacheLayoutSnapshot = rootPath $ fragment "snapshot.json",
          cacheLayoutMirrors = rootPath $ fragment "mirrors.json",
          cacheLayoutIndexTar = rootPath $ fragment "01-index.tar",
          cacheLayoutIndexIdx = rootPath $ fragment "01-index.tar.idx",
          cacheLayoutIndexTarGz = rootPath $ fragment "01-index.tar.gz"
        }

withHackage ::
  (MonadUnliftIO m) =>
  Cache -> Manager -> (LogMessage -> m ()) -> (Repository RemoteTemp -> m a) -> m a
withHackage cache manager logAction act =
  withClient manager $ \httpLib ->
    withRepository httpLib [uri] cache logAction $ \repository -> do
      uncheckClientErrors $ liftIO $ do
        rb <- requiresBootstrap repository
        when rb $ bootstrap repository [] (KeyThreshold 0)
        now <- getCurrentTime
        stale <- indexOlderThan oneWeek (cacheRoot cache) now
        when stale $ do
          _ <- checkForUpdates repository (Just now)
          pure ()
      act repository
  where
    uri = parseURI "http://hackage.haskell.org"
    oneWeek = 7 * 24 * 60 * 60

-- | True if the cached package index is missing, or older than @maxAge@.
-- Used to skip the (slow) Hackage index refresh on most runs.
indexOlderThan :: NominalDiffTime -> Path Absolute -> UTCTime -> IO Bool
indexOlderThan maxAge cacheRoot' now = do
  let idx = cacheRoot' </> fragment "01-index.tar"
  exists <- doesFileExist idx
  if not exists
    then pure True
    else do
      mtime <- getModificationTime idx
      pure (diffUTCTime now mtime > maxAge)
