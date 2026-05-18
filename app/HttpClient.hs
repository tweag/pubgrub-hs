{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

{- HLINT ignore "Eta reduce" -}

module HttpClient (
    withClient,

    -- ** Re-exports
    HttpLib (..),
    Manager, -- opaque
) where

import           Control.Exception
import           Control.Monad                              (void)
import           Data.ByteString                            (ByteString)
import qualified Data.ByteString                            as BS
import qualified Data.ByteString.Char8                      as BS.C8
import           Network.HTTP.Client                        (Manager)
import qualified Network.HTTP.Client                        as HttpClient
import qualified Network.HTTP.Client.Internal               as HttpClient
import qualified Network.HTTP.Types                         as HttpClient
import           Network.URI

import           Control.Monad.IO.Class                     (MonadIO (..))
import           Hackage.Security.Client                    hiding (Header)
import           Hackage.Security.Client.Repository.HttpLib
import           Hackage.Security.Util.Checked

{-------------------------------------------------------------------------------
  Top-level API
-------------------------------------------------------------------------------}

{- | An 'HttpLib' for @hackage-security@ over an existing 'Manager'.

Any proxy must already be configured on the 'Manager': @http-client@ cannot
change it once the 'Manager' is created.
-}
withClient
    :: MonadIO m
    => Manager
    -> (HttpLib -> m a)
    -> m a
withClient manager callback = do
    callback HttpLib{..}
  where
    httpGet
        :: Throws SomeRemoteError
        => [HttpRequestHeader]
        -> URI
        -> ([HttpResponseHeader] -> BodyReader -> IO a)
        -> IO a
    httpGet reqHeaders uri act = wrapCustomEx $ do
        -- TODO: setUri fails on a URI that carries credentials
        -- (user:password@host). Not sure if this is a concern.
        request' <- HttpClient.setUri HttpClient.defaultRequest uri
        let request = addRequestHeaders reqHeaders request'
        checkHttpException $ HttpClient.withResponse request manager $ \response -> do
            let br = wrapCustomEx $ HttpClient.responseBody response
            act (getResponseHeaders response) br

    httpGetRange
        :: Throws SomeRemoteError
        => [HttpRequestHeader]
        -> URI
        -> (Int, Int)
        -> (HttpStatus -> [HttpResponseHeader] -> BodyReader -> IO a)
        -> IO a
    httpGetRange reqHeaders uri (from, to) act = wrapCustomEx $ do
        request <-
            (setRange from to . addRequestHeaders reqHeaders)
                `fmap` HttpClient.setUri HttpClient.defaultRequest uri
        checkHttpException $ HttpClient.withResponse request manager $ \response -> do
            let br = wrapCustomEx $ HttpClient.responseBody response
            case () of
                ()
                    | HttpClient.responseStatus response == HttpClient.partialContent206 ->
                        act HttpStatus206PartialContent (getResponseHeaders response) br
                ()
                    | HttpClient.responseStatus response == HttpClient.ok200 ->
                        act HttpStatus200OK (getResponseHeaders response) br
                _otherwise ->
                    throwChecked $
                        HttpClient.HttpExceptionRequest request $
                            HttpClient.StatusCodeException (void response) BS.empty

{- | Rethrow an @http-client@ 'HttpClient.HttpException' as the 'SomeRemoteError'
that @hackage-security@ expects of an 'HttpLib'.
-}
wrapCustomEx
    :: (Throws HttpClient.HttpException => IO a)
    -> (Throws SomeRemoteError => IO a)
wrapCustomEx act =
    handleChecked
        (\(ex :: HttpClient.HttpException) -> go ex)
        act
  where
    go ex = throwChecked (SomeRemoteError ex)

checkHttpException :: Throws HttpClient.HttpException => IO a -> IO a
checkHttpException = handle $ \(ex :: HttpClient.HttpException) ->
    throwChecked ex

{-------------------------------------------------------------------------------
  http-client auxiliary
-------------------------------------------------------------------------------}

hAcceptRanges :: HttpClient.HeaderName
hAcceptRanges = "Accept-Ranges"

hAcceptEncoding :: HttpClient.HeaderName
hAcceptEncoding = "Accept-Encoding"

setRange
    :: Int
    -> Int
    -> HttpClient.Request
    -> HttpClient.Request
setRange from to req =
    req
        { HttpClient.requestHeaders =
            (HttpClient.hRange, rangeHeader)
                : HttpClient.requestHeaders req
        }
  where
    -- A Range header's last byte is inclusive, and @to@ is exclusive.
    -- See <https://www.rfc-editor.org/rfc/rfc9110#section-14.1.2>
    rangeHeader = BS.C8.pack $ "bytes=" ++ show from ++ "-" ++ show (to - 1)

addRequestHeaders
    :: [HttpRequestHeader]
    -> HttpClient.Request
    -> HttpClient.Request
addRequestHeaders opts req =
    req
        { HttpClient.requestHeaders = HttpClient.requestHeaders req ++ trOpt disallowCompressionByDefault opts
        }
  where
    trOpt
        :: [(HttpClient.HeaderName, [ByteString])]
        -> [HttpRequestHeader]
        -> [HttpClient.Header]
    trOpt acc [] =
        concatMap finalizeHeader acc
    trOpt acc (HttpRequestMaxAge0 : os) =
        trOpt (insert HttpClient.hCacheControl ["max-age=0"] acc) os
    trOpt acc (HttpRequestNoTransform : os) =
        trOpt (insert HttpClient.hCacheControl ["no-transform"] acc) os

    -- Disable content compression (a potential security issue).
    disallowCompressionByDefault :: [(HttpClient.HeaderName, [ByteString])]
    disallowCompressionByDefault = [(hAcceptEncoding, [])]

    -- TODO: every header is sent as one comma-separated line, though some
    -- headers need one line per value.
    finalizeHeader
        :: (HttpClient.HeaderName, [ByteString])
        -> [HttpClient.Header]
    finalizeHeader (name, strs) = [(name, BS.intercalate ", " (reverse strs))]

    insert :: Eq a => a -> [b] -> [(a, [b])] -> [(a, [b])]
    insert x y = modifyAssocList x (++ y)

    -- Modifies the first matching element only.
    modifyAssocList :: Eq a => a -> (b -> b) -> [(a, b)] -> [(a, b)]
    modifyAssocList a f = go
      where
        go [] = []
        go (p@(a', b) : xs)
            | a == a' = (a', f b) : xs
            | otherwise = p : go xs

-- | The one response header @hackage-security@ asks about: @Accept-Ranges: bytes@.
getResponseHeaders :: HttpClient.Response a -> [HttpResponseHeader]
getResponseHeaders response =
    [ HttpResponseAcceptRangesBytes
    | (hAcceptRanges, "bytes") `elem` headers
    ]
  where
    headers = HttpClient.responseHeaders response
