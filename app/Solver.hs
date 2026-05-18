module Solver where

import           Hackage.Security.Unlifted (IndexCallbacks (..))
import           UnliftIO                  (MonadUnliftIO)

solve :: MonadUnliftIO m => IndexCallbacks -> m ()
solve IndexCallbacks{} = error "TODO"
