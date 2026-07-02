{-# LANGUAGE DerivingVia         #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE PatternSynonyms     #-}

module Main where

import           Colog                           (logMsg, logTextStdout)
import           Colog.Monad                     (usingLoggerT)
import           Compiler                        (Compiler (..),
                                                  CompilerError (..),
                                                  resolveCompiler)
import           Control.Exception               (try)
import           Data.Maybe                      (fromMaybe)
import           Data.Text                       (Text)
import qualified Data.Text                       as T
import           Data.Time                       (defaultTimeLocale, formatTime)
import           Distribution.PackageDescription (PackageName)
import           Distribution.Parsec             (eitherParsec)
import           Distribution.Pretty             (prettyShow)
import           Distribution.Types.PackageId    (PackageIdentifier (..))
import           Distribution.Types.VersionRange (VersionRange)
import           Distribution.Version            (Version)
import           Hackage                         (mkCache)
import qualified Hackage.Security.Client.Formats as Sec
import           Hackage.Security.Unlifted       (getCachedIndex,
                                                  getModificationTime)
import           Hackage.Security.Util.Path      (fromFilePath, makeAbsolute)
import           InstalledDbProvider             (mkInstalledDbProvider)
import           Network.HTTP.Client             (defaultManagerSettings,
                                                  newManager)
import           Options.Applicative             (Parser, ParserInfo, argument,
                                                  eitherReader, execParser,
                                                  fullDesc, help, helper, info,
                                                  long, metavar, optional,
                                                  progDesc, strOption, (<**>))
import           Provider                        (Combined (..))
import           PubGrub.Choice                  (pattern Source)
import           PubGrub.SourceConfig            (SourceConfig (..))
import qualified PubGrub.VersionSet              as VS
import           Solver                          (runSolve)
import           SourceProvider                  (withSourceProvider)
import           UnliftIO                        (MonadIO (..))

data Options = Options
    { optWithCompiler :: Maybe FilePath
    , optTarget       :: (PackageName, Version)
    , optRange        :: Maybe VS.VersionSet
    }

-- | Parse a @<package>-<version>@ argument. The target is solved at exactly
-- that version.
readTarget :: String -> Either String (PackageName, Version)
readTarget s =
    case eitherParsec s :: Either String PackageIdentifier of
        Right (PackageIdentifier n v) -> Right (n, v)
        Left e -> Left ("invalid package identifier: " <> e)

readRange :: String -> Either String VS.VersionSet
readRange s =
    case eitherParsec s :: Either String VersionRange of
        Right vr -> Right (VS.fromVersionRange vr)
        Left err -> Left ("invalid version range: " <> err)

optionsParser :: Parser Options
optionsParser =
    Options
        <$> optional
            ( strOption
                ( long "with-compiler"
                    <> metavar "PATH"
                    <> help "GHC executable to use for boot packages and impl(ghc) conditionals (default: ghc on PATH)"
                )
            )
        <*> argument (eitherReader readTarget) (metavar "TARGET")
        <*> optional (argument (eitherReader readRange) (metavar "VERSION-RANGE"))

optionsInfo :: ParserInfo Options
optionsInfo =
    info
        (optionsParser <**> helper)
        (fullDesc <> progDesc "Resolve a Hackage package's dependency closure with PubGrub")

main :: IO ()
main = do
    cache <- mkCache <$> makeAbsolute (fromFilePath "_cache")
    opts <- execParser optionsInfo

    usingLoggerT logTextStdout $ do
        manager <- liftIO $ newManager defaultManagerSettings
        ecompiler <- liftIO (try (resolveCompiler (fromMaybe "ghc" (optWithCompiler opts))))
        case ecompiler of
            Left (CompilerError msg) -> logMsg @Text ("error: " <> msg)
            Right compiler -> do
                let (target, targetVersion) = optTarget opts
                    db = mkInstalledDbProvider (installedPackages compiler)
                withSourceProvider cache manager compiler $ \hp -> do
                    let combined =
                            Combined
                                { cDb = db
                                , cSource = hp
                                }
                    idx <- liftIO $ getCachedIndex cache Sec.FGz
                    case idx of
                        Nothing -> logMsg @Text "error: cached index not found after update"
                        Just idxPath -> do
                            idxTime <- liftIO (getModificationTime idxPath)

                            logMsg @Text
                                ( "\ESC[1mSolving for "
                                    <> T.pack (prettyShow target)
                                    <> " "
                                    <> T.pack (prettyShow targetVersion)
                                    <> " (index from "
                                    <> T.pack (formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC" idxTime)
                                    <> ")\ESC[0m"
                                )

                            runSolve combined target (Source (SourceConfig targetVersion mempty))
