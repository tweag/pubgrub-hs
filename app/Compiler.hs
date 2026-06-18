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
import qualified Data.Map.Strict                as Map
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Distribution.Compiler          (AbiTag (NoAbiTag),
                                                 CompilerFlavor (GHC),
                                                 CompilerId (..), CompilerInfo,
                                                 unknownCompilerInfo)
import           Distribution.Types.PackageName (PackageName, mkPackageName)
import           Distribution.Version           (Version)
import           PubGrub.Cabal.Boot             (parseBootList)
import           PubGrub.Cabal.Compiler         (ghcPkgFromLibdir,
                                                 parseCompilerVersion)
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
runTool :: Text -> FilePath -> [String] -> IO String
runTool label exe args = do
  result <- try (readProcess exe args "")
  case result of
    Right out -> pure out
    Left (e :: IOException) ->
      throwIO
        ( CompilerError
            ( "could not query "
                <> label
                <> " '"
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
  libdir <- trim <$> runTool "compiler" ghcExe ["--print-libdir"]
  verOut <- runTool "compiler" ghcExe ["--numeric-version"]
  version <- case parseCompilerVersion verOut of
    Right v -> pure v
    Left msg ->
      throwIO (CompilerError ("compiler '" <> T.pack ghcExe <> "': " <> T.pack msg))
  let ghcPkg = ghcPkgFromLibdir libdir
  boot <- parseBootList <$> runTool "ghc-pkg" ghcPkg ["list", "--global", "--simple-output"]
  if Map.member (mkPackageName "base") boot
    then
      pure
        Compiler
          { compilerInfo = unknownCompilerInfo (CompilerId GHC version) NoAbiTag,
            bootPackages = boot
          }
    else
      throwIO
        ( CompilerError
            ( "ghc-pkg '"
                <> T.pack ghcPkg
                <> "' reported no 'base' package; its output may be malformed"
            )
        )
  where
    trim = T.unpack . T.strip . T.pack
