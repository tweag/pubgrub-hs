-- | A logger kept in a reader environment: the part of the @co-log@ package's
-- interface that the bridge and the drivers use, written here because @co-log@
-- itself depends on @dependent-map@, which caps @containers@ below 0.8. The
-- 'LogAction' type is @co-log-core@'s, the one the solver takes, so a logger
-- built for the solver and a logger for the bridge's own messages sit in the
-- same environment and are reached the same way.
module Bridge.Log
    ( HasLog (..)
    , WithLog
    , logMsg
    ) where

import           Colog.Core           (LogAction (..))
import           Control.Monad.Reader (MonadReader, asks)

-- | An environment that holds a logger for messages of type @msg@ in @m@.
class HasLog env msg m where
    getLogAction :: env -> LogAction m msg

-- | A monad that reads such an environment.
type WithLog env msg m = (MonadReader env m, HasLog env msg m)

-- | Log one message through the environment's logger.
logMsg :: forall msg env m. WithLog env msg m => msg -> m ()
logMsg msg = do
    LogAction act <- asks getLogAction
    act msg
