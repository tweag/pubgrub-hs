module Hackage.Security.Unlifted (
    module Hackage.Security.Unlifted,
    module Sec,
    module Network.URI,
    module UnliftIO,
)
where

import           GHC.Stack                                  (HasCallStack)
import           Hackage.Security.Client                    as Sec (IndexCallbacks (..),
                                                                    InvalidPackageException,
                                                                    LogMessage,
                                                                    Repository,
                                                                    SomeRemoteError,
                                                                    bootstrap,
                                                                    hackageIndexLayout,
                                                                    hackageRepoLayout)
import           Hackage.Security.Client                    as Sec.Private (uncheckClientErrors,
                                                                            withIndex)
import           Hackage.Security.Client.Repository.Cache   as Sec (Cache (..),
                                                                    getCachedIndex)
import           Hackage.Security.Client.Repository.HttpLib as Sec (HttpLib (..))
import           Hackage.Security.Client.Repository.Remote  as Sec (RemoteTemp,
                                                                    defaultRepoOpts)
import           Hackage.Security.Client.Repository.Remote  as Sec.Private (withRepository)
import           Hackage.Security.Trusted                   (VerificationError)
import           Hackage.Security.Util.Checked              (Throws)
import           Hackage.Security.Util.Path                 as Sec
import           HttpClient                                 as Sec.Private (withClient)
import           Network.HTTP.Client                        (Manager)
import           Network.URI                                (URI)
import           UnliftIO                                   (MonadUnliftIO (..))

uncheckClientErrors
    :: (HasCallStack, MonadUnliftIO m)
    => ((Throws Sec.InvalidPackageException, Throws Sec.SomeRemoteError, Throws VerificationError) => m b)
    -> m b
uncheckClientErrors act =
    withRunInIO $ \runInIO -> Sec.Private.uncheckClientErrors (runInIO act)

withRepository
    :: (HasCallStack, MonadUnliftIO m)
    => Sec.HttpLib
    -> [URI]
    -> Sec.Cache
    -> (LogMessage -> m ())
    -> (Sec.Repository Sec.RemoteTemp -> m b)
    -> m b
withRepository httpLib uris cache logger act =
    withRunInIO $ \runInIO ->
        Sec.Private.withRepository
            httpLib
            uris
            Sec.defaultRepoOpts
            cache
            Sec.hackageRepoLayout
            Sec.hackageIndexLayout
            (runInIO . logger)
            (runInIO . act)

withClient
    :: (HasCallStack, MonadUnliftIO m)
    => Manager -> (Sec.HttpLib -> m a) -> m a
withClient manager act =
    withRunInIO $ \runInIO ->
        Sec.Private.withClient manager (runInIO . act)

withIndex
    :: (HasCallStack, MonadUnliftIO m)
    => Sec.Repository down -> (Sec.IndexCallbacks -> m a) -> m a
withIndex repository act =
    withRunInIO $ \runInIO ->
        Sec.Private.withIndex repository (runInIO . act)
