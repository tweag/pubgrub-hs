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
import           Distribution.PackageDescription (PackageName, mkPackageName)
import           Distribution.Parsec             (eitherParsec)
import           Distribution.Types.PackageId    (PackageIdentifier (..))
import           Distribution.Types.VersionRange (VersionRange)
import           Distribution.Version            (versionNumbers)
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
  case parseTarget args of
    Nothing -> putStrLn "usage: pubgrub-hs <package>[-<version>] [version-range]"
    Just (target, range) ->
      usingLoggerT solverSink $
        withHackage cache manager (liftIO . unLogAction hackageSink) $ \repository ->
          withIndex repository $ \indexCallbacks -> do
            idxTime <- liftIO (getModificationTime (cacheRoot cache </> fragment "01-index.tar"))
            runSolve idxTime indexCallbacks target range

-- | Parse CLI args into a target package and version range. A single
-- @name-version@ arg (e.g. @lens-5.3.5@) means @== version@; a bare name means
-- any version; @<name> <range>@ uses an explicit Cabal version range.
parseTarget :: [String] -> Maybe (PackageName, VS.VersionSet)
parseTarget [one] =
  case eitherParsec one :: Either String PackageIdentifier of
    Right (PackageIdentifier n v)
      | null (versionNumbers v) -> Just (n, VS.full)
      | otherwise               -> Just (n, VS.singleton v)
    Left _ -> Just (mkPackageName one, VS.full)
parseTarget (name : r : _) =
  case eitherParsec r :: Either String VersionRange of
    Right vr -> Just (mkPackageName name, VS.fromVersionRange vr)
    Left _   -> Nothing
parseTarget [] = Nothing

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
