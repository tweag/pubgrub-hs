-- | Pure helpers for locating a GHC's tooling, kept out of the executable so
-- the test-suite can reach them.
module PubGrub.Cabal.Compiler
  ( ghcPkgFromLibdir,
  )
where

import           System.FilePath (takeDirectory, (</>))

-- | Given the output of @ghc --print-libdir@, return the path to the
-- version-matched @ghc-pkg@ that sits at @<LIBDIR>/../bin/ghc-pkg@.
ghcPkgFromLibdir :: FilePath -> FilePath
ghcPkgFromLibdir libdir = takeDirectory libdir </> "bin" </> "ghc-pkg"
