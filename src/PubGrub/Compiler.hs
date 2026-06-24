-- | The compiler and package-database types the library needs. They depend on
-- Cabal-syntax only, not Cabal, so the core stays portable. Cabal-syntax's
-- compiler identifiers are re-exported.
module PubGrub.Compiler (
    CompilerId (..),
    CompilerFlavor (..),
    PackageDb (..),
)
where

import           Distribution.Compiler (CompilerFlavor (..), CompilerId (..))

-- | Which package database an installed instance lives in.
data PackageDb = GlobalDb | UserDb | SpecificDb FilePath
