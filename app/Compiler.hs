{-# LANGUAGE DerivingStrategies  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Compiler
  ( Compiler (..),
    CompilerError (..),
    resolveCompiler,
  )
where

import           Control.Exception              (Exception, IOException,
                                                 throwIO, try)
import           Data.Map.Strict                (Map)
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Distribution.Compiler          (AbiTag (NoAbiTag),
                                                 CompilerFlavor (GHC),
                                                 CompilerId (..), CompilerInfo,
                                                 unknownCompilerInfo)
import           Distribution.Parsec            (eitherParsec)
import           Distribution.Types.PackageName (PackageName)
import           Distribution.Version           (Version)
import           PubGrub.Cabal.Boot             (parseBootList)
import           PubGrub.Cabal.Compiler         (ghcPkgFromLibdir)
import           System.Process                 (readProcess)

-- | Everything the resolver needs to know about one GHC: the compiler info
-- that decides @impl(ghc)@ conditionals, and the versions of the boot
-- packages in its global database, which resolution must take as installed.
data Compiler = Compiler
  { compilerInfo :: CompilerInfo,
    bootPackages :: Map PackageName Version
  }

-- | A GHC executable could not be queried (not found, not a GHC, or
-- unparseable output).
newtype CompilerError = CompilerError Text
  deriving stock (Show)

instance Exception CompilerError

-- | Run a GHC-family executable, converting a missing/failed process into a
-- 'CompilerError' instead of a raw 'IOException'.
runTool :: FilePath -> [String] -> IO String
runTool exe args = do
  result <- try (readProcess exe args "")
  case result of
    Right out -> pure out
    Left (e :: IOException) ->
      throwIO
        ( CompilerError
            ( "could not query compiler '"
                <> T.pack exe
                <> "': "
                <> T.pack (show e)
            )
        )

-- | Resolve a GHC executable (a name on @PATH@ like @ghc@/@ghc-9.8.3@, or an
-- absolute path) into its 'Compiler': version-derived 'CompilerInfo' and the
-- boot-package set from the version-matched @ghc-pkg@.
resolveCompiler :: FilePath -> IO Compiler
resolveCompiler ghcExe = do
  libdir <- trim <$> runTool ghcExe ["--print-libdir"]
  verStr <- trim <$> runTool ghcExe ["--numeric-version"]
  version <- case eitherParsec verStr :: Either String Version of
    Right v -> pure v
    Left err ->
      throwIO
        ( CompilerError
            ( "could not parse version '"
                <> T.pack verStr
                <> "' from '"
                <> T.pack ghcExe
                <> "': "
                <> T.pack err
            )
        )
  let ghcPkg = ghcPkgFromLibdir libdir
  bootOut <- runTool ghcPkg ["list", "--global", "--simple-output"]
  pure
    Compiler
      { compilerInfo = unknownCompilerInfo (CompilerId GHC version) NoAbiTag,
        bootPackages = parseBootList bootOut
      }
  where
    trim = T.unpack . T.strip . T.pack
