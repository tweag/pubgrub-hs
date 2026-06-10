{-# LANGUAGE DerivingVia         #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE ImportQualifiedPost #-}

module Main where

import           Colog                           (LogAction (..))
import           Colog.Monad
import           Control.Monad                   (when)
import           Data.Maybe                      (fromMaybe)
import           Distribution.PackageDescription (mkPackageName)
import           Distribution.Parsec             (eitherParsec)
import           Distribution.Types.VersionRange (VersionRange)
import           GHC.Stack                       (HasCallStack)
import           Hackage.Security.Client         (CacheLayout (..),
                                                  KeyThreshold (..), bootstrap,
                                                  requiresBootstrap)
import           Hackage.Security.Unlifted
import           Hackage.Security.Util.Path      (Absolute, Path, fragment,
                                                  fromFilePath, makeAbsolute,
                                                  rootPath)
import           Hackage.Security.Util.Pretty    (Pretty (..))
import           Network.HTTP.Client             (Manager,
                                                  defaultManagerSettings,
                                                  newManager)
import qualified Network.URI
import qualified PubGrub.VersionSet              as VS
import           Solver                          (runSolve)
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
      usingLoggerT logMessageAction $
        withHackage cache manager $ \repository ->
          withIndex repository $ \indexCallbacks ->
            liftIO (runSolve indexCallbacks target range)
    [] -> putStrLn "usage: pubgrub-hs <package> [version-range]"

parseURI :: (HasCallStack) => [Char] -> URI
parseURI str = fromMaybe (error $ "failed parsing URI " ++ str) $ Network.URI.parseURI str

logMessageAction :: (MonadIO m) => LogAction m LogMessage
logMessageAction = LogAction (liftIO . putStrLn . pretty)

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
  (MonadUnliftIO m, WithLog env LogMessage m) =>
  Cache -> Manager -> (Repository RemoteTemp -> m a) -> m a
withHackage cache manager act =
  withClient manager $ \httpLib ->
    withRepository httpLib [uri] cache logMsg $ \repository -> do
      uncheckClientErrors $ liftIO $ do
        rb <- requiresBootstrap repository
        when rb $ bootstrap repository [] (KeyThreshold 0)
      act repository
  where
    uri = parseURI "http://hackage.haskell.org"
