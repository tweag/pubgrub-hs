{-# LANGUAGE DerivingVia         #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings   #-}

module Main where

import           Colog                           (logMsg, logTextStdout)
import           Colog.Monad                     (usingLoggerT)
import           Compiler                        (CompilerError (..),
                                                  resolveCompiler)
import           Control.Exception               (try)
import           Data.Maybe                      (fromMaybe)
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
import           Options.Applicative             (Parser, ParserInfo, argument,
                                                  eitherReader, execParser,
                                                  fullDesc, help, helper, info,
                                                  long, metavar, optional,
                                                  progDesc, strOption, (<**>))
import qualified PubGrub.VersionSet              as VS
import           Solver                          (runSolve)
import           UnliftIO                        (MonadIO (..))

data Options = Options
    { optWithCompiler :: Maybe FilePath
    , optTarget       :: (PackageName, VS.VersionSet)
    , optRange        :: Maybe VS.VersionSet
    }

{- | Parse a @<package>[-<version>]@ argument. A bare name means any version;
@name-version@ means @== version@.
-}
readTarget :: String -> Either String (PackageName, VS.VersionSet)
readTarget s =
    case eitherParsec s :: Either String PackageIdentifier of
        Right (PackageIdentifier n v)
            | null (versionNumbers v) -> Right (n, VS.full)
            | otherwise -> Right (n, VS.singleton v)
        Left _ -> Right (mkPackageName s, VS.full)

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
                let (target, targetRange) = optTarget opts
                    range = fromMaybe targetRange (optRange opts)
                withHackageProvider cache manager compiler target range $ \hp -> do
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
