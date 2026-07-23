module Bridge.Hackage.Unlifted where

import qualified Bridge.Hackage.HttpClient                  as HttpClient
import           GHC.Stack                                  (HasCallStack)
import qualified Hackage.Security.Client                    as Sec
import qualified Hackage.Security.Client.Repository.Cache   as Sec.Cache
import qualified Hackage.Security.Client.Repository.HttpLib as Sec.HttpLib
import qualified Hackage.Security.Client.Repository.Remote  as Sec.Remote
import           Hackage.Security.Util.Checked              (Throws)
import           Network.HTTP.Client                        (Manager)
import           Network.URI                                (URI)
import           UnliftIO                                   (MonadUnliftIO (..))


uncheckClientErrors
    :: (HasCallStack, MonadUnliftIO m)
    => ((Throws Sec.InvalidPackageException, Throws Sec.SomeRemoteError, Throws Sec.VerificationError) => m b)
    -> m b
uncheckClientErrors act =
    withRunInIO $ \runInIO -> Sec.uncheckClientErrors (runInIO act)

withRepository
    :: (HasCallStack, MonadUnliftIO m)
    => Sec.HttpLib.HttpLib -- from Hackage.Security.Client.Repository.HttpLib
    -> [URI]
    -> Sec.Cache.Cache
    -> (Sec.LogMessage -> m ())
    -> (Sec.Repository Sec.Remote.RemoteTemp -> m b)
    -> m b
withRepository httpLib uris cache logger act =
    withRunInIO $ \runInIO ->
        Sec.Remote.withRepository
            httpLib
            uris
            Sec.Remote.defaultRepoOpts
            cache
            Sec.hackageRepoLayout
            Sec.hackageIndexLayout
            (runInIO . logger)
            (runInIO . act)

withClient
    :: (HasCallStack, MonadUnliftIO m)
    => Manager -> (Sec.HttpLib.HttpLib -> m a) -> m a
withClient manager act =
    withRunInIO $ \runInIO ->
        HttpClient.withClient manager (runInIO . act)

withIndex
    :: (HasCallStack, MonadUnliftIO m)
    => Sec.Repository down -> (Sec.IndexCallbacks -> m a) -> m a
withIndex repository act =
    withRunInIO $ \runInIO ->
        Sec.withIndex repository (runInIO . act)
