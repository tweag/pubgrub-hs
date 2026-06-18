module Utils where

import           Data.Time.Clock (NominalDiffTime, diffUTCTime, getCurrentTime)
import           UnliftIO        (MonadIO (..))

timed :: MonadIO m => m a -> m (a, NominalDiffTime)
timed action = do
    start <- liftIO getCurrentTime
    result <- action
    end <- liftIO getCurrentTime
    let duration = diffUTCTime end start
    return (result, duration)

