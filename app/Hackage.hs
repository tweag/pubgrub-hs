module Hackage where

import           Data.Maybe                      (fromMaybe)
import           Data.Time.Clock                 (NominalDiffTime, UTCTime,
                                                  diffUTCTime)
import           GHC.Stack                       (HasCallStack)
import           Hackage.Security.Client         as Sec (CacheLayout (..))
import           Hackage.Security.Client.Formats as Sec
import           Hackage.Security.Unlifted
import qualified Hackage.Security.Unlifted       as Sec
import qualified Network.URI

mkCache :: Path Absolute -> Cache
mkCache root =
    Cache{cacheRoot = root, cacheLayout = cabalCacheLayout}
  where
    cabalCacheLayout :: CacheLayout
    cabalCacheLayout =
        CacheLayout
            { cacheLayoutRoot = rootPath $ fragment "root.json"
            , cacheLayoutTimestamp = rootPath $ fragment "timestamp.json"
            , cacheLayoutSnapshot = rootPath $ fragment "snapshot.json"
            , cacheLayoutMirrors = rootPath $ fragment "mirrors.json"
            , cacheLayoutIndexTar = rootPath $ fragment "01-index.tar"
            , cacheLayoutIndexIdx = rootPath $ fragment "01-index.tar.idx"
            , cacheLayoutIndexTarGz = rootPath $ fragment "01-index.tar.gz"
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
