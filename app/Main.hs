{-# LANGUAGE DerivingVia         #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings   #-}

module Main where

import           Colog                           (logMsg, logTextStdout)
import           Colog.Monad                     (usingLoggerT)
import           Data.Text                       (Text)
import qualified Data.Text                       as T
import           Data.Time                       (defaultTimeLocale, formatTime)
import           Distribution.PackageDescription (PackageName, mkPackageName)
import           Distribution.Parsec             (eitherParsec)
import           Distribution.Pretty             (prettyShow)
import           Distribution.Types.PackageId    (PackageIdentifier (..))
import           Distribution.Types.VersionRange (VersionRange)
import           Distribution.Version            (versionNumbers)
import           Hackage                         (mkCache)
import qualified Hackage.Security.Client.Formats as Sec
import           Hackage.Security.Unlifted       (getCachedIndex,
                                                  getModificationTime)
import           Hackage.Security.Util.Path      (fromFilePath, makeAbsolute)
import           HackageProvider                 (withHackageProvider)
import           Network.HTTP.Client             (defaultManagerSettings,
                                                  newManager)
import qualified PubGrub.VersionSet              as VS
import           Solver                          (runSolve)
import           System.Environment              (getArgs)
import           UnliftIO                        (MonadIO (..))

main :: IO ()
main = do
  cache <- mkCache <$> makeAbsolute (fromFilePath "_cache")
  args <- getArgs

  usingLoggerT logTextStdout $ do
    manager <- liftIO $ newManager defaultManagerSettings
    case parseTarget args of
      Nothing -> logMsg @Text "usage: pubgrub-hs <package>[-<version>] [version-range]"
      Just (target, range) -> do
        withHackageProvider cache manager target range $ \hp -> do
          idx <- liftIO $ getCachedIndex cache Sec.FGz
          case idx of
            Nothing -> logMsg @Text "error: cached index not found after update"
            Just idxPath -> do
              idxTime <- liftIO (getModificationTime idxPath)

              logMsg @Text
                ( "\ESC[1mSolving for "
                    <> T.pack (prettyShow target)
                    <> " "
                    <> T.pack (prettyShow (VS.toVersionRange range))
                    <> " (index from "
                    <> T.pack (formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC" idxTime)
                    <> ")\ESC[0m"
                )

              runSolve hp

-- | Parse CLI args into a target package and version range. A single
-- @name-version@ arg (e.g. @lens-5.3.5@) means @== version@; a bare name means
-- any version; @<name> <range>@ uses an explicit Cabal version range.
parseTarget :: [String] -> Maybe (PackageName, VS.VersionSet)
parseTarget [one] =
  case eitherParsec one :: Either String PackageIdentifier of
    Right (PackageIdentifier n v)
      | null (versionNumbers v) -> Just (n, VS.full)
      | otherwise -> Just (n, VS.singleton v)
    Left _ -> Just (mkPackageName one, VS.full)
parseTarget (name : r : _) =
  case eitherParsec r :: Either String VersionRange of
    Right vr -> Just (mkPackageName name, VS.fromVersionRange vr)
    Left _   -> Nothing
parseTarget [] = Nothing
