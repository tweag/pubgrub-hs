{-# LANGUAGE DerivingVia         #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE ImportQualifiedPost #-}

module Main where

import           Colog                                  (LogAction (..))
import           Colog.Monad
import           Control.Monad                          (when)
import qualified Data.ByteString.Lazy                   as BSL
import           Data.Maybe                             (fromMaybe)
import           Database                               (ParseError (..),
                                                         mkDatabase)
import           Distribution.PackageDescription        (GenericPackageDescription,
                                                         PackageIdentifier (..),
                                                         mkPackageName)
import           Distribution.PackageDescription.Parsec (parseGenericPackageDescription,
                                                         runParseResult)
import           Distribution.Version                   (mkVersion)
import           GHC.Stack                              (HasCallStack)
import           Hackage.Security.Client                (CacheLayout (..),
                                                         KeyThreshold (..),
                                                         bootstrap,
                                                         requiresBootstrap)
import           Hackage.Security.Unlifted
import           Hackage.Security.Util.Path             (Absolute, Path,
                                                         fragment, fromFilePath,
                                                         makeAbsolute, rootPath)
import           Hackage.Security.Util.Pretty           (Pretty (..))
import           Network.HTTP.Client                    (Manager,
                                                         defaultManagerSettings,
                                                         newManager)
import qualified Network.URI
import           UnliftIO                               (MonadIO (..))

main :: IO ()
main = do
  manager <- liftIO $ newManager defaultManagerSettings
  cache <- mkCache <$> makeAbsolute (fromFilePath "_cache")

  usingLoggerT logMessageAction $ do
    withHackage cache manager $ \repository -> do
      withIndex repository $ \indexCallbacks -> liftIO $ do
        dblookup <- mkDatabase indexCallbacks parse
        dblookup (PackageIdentifier (mkPackageName "lens") (mkVersion [5, 3, 6])) >>= print

  putStrLn "Done."

parse :: BSL.ByteString -> Either ParseError GenericPackageDescription
parse bs =
  case runParseResult (parseGenericPackageDescription (BSL.toStrict bs)) of
    (_, Left (mver, errs)) -> Left (ParseError mver errs)
    (_, Right gpd)         -> Right gpd

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
