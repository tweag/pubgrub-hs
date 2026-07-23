-- | Pure helpers for locating a GHC's tooling and parsing its output, kept
-- out of the executable so the test-suite can reach them. The executable's
-- @Compiler@ module runs them and assembles the compiler description.
module Bridge.Cabal.Compiler (
    ghcPkgFromLibdir,
    parseCompilerVersion,
)
where

import           Data.Char            (isSpace)
import           Data.List            (dropWhileEnd)
import           Distribution.Parsec  (eitherParsec)
import           Distribution.Version (Version)
import           System.FilePath      (takeDirectory, (</>))

-- | Given the output of @ghc --print-libdir@, return the path to the
-- version-matched @ghc-pkg@ that sits at @<LIBDIR>/../bin/ghc-pkg@.
ghcPkgFromLibdir :: FilePath -> FilePath
ghcPkgFromLibdir libdir = takeDirectory libdir </> "bin" </> "ghc-pkg"

-- | Parse the output of @ghc --numeric-version@, ignoring surrounding
-- whitespace. The 'Left' message quotes the string that failed to parse.
parseCompilerVersion :: String -> Either String Version
parseCompilerVersion raw =
    case eitherParsec trimmed :: Either String Version of
        Right v -> Right v
        Left err -> Left ("could not parse version '" <> trimmed <> "': " <> err)
  where
    trimmed = dropWhileEnd isSpace (dropWhile isSpace raw)
