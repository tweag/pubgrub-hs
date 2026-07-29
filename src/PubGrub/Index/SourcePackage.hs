module PubGrub.Index.SourcePackage
    ( Dependency (..)
    , SourcePackage (..)
    ) where
import           Distribution.Types.Condition
import           Distribution.Types.Flag        (FlagName, PackageFlag)
import           Distribution.Types.PackageName
import           Distribution.Types.Version     (Version)
import           PubGrub.VersionSet             (VersionSet)


-- | A dependency of a source package: a package, a version set, and a
-- condition over the depender's own flags under which the dependency is
-- active (@'Lit' True@ is unconditional).
--
-- A dependency constrains its target by version only. It cannot demand how
-- the target is provided (which unit, which flags), and the 'Provider' widens
-- the version set to the instances whose version is in it.
data Dependency = Dependency PackageName VersionSet (Condition FlagName)
    deriving (Show, Eq)

-- | A source package is a package that can be built from source: a version,
-- the flags it declares, its (conditional) dependencies, and a buildability
-- condition over its flags. Flags /determine/ the dependencies — that is why
-- a flag assignment is part of a 'BuildSource' instance: fixing the instance
-- fixes the dependencies.
data SourcePackage
    = SourcePackage
    { spVersion      :: Version
    , spFlags        :: [PackageFlag]
    , spDependencies :: [Dependency]
    , spBuildable    :: Condition FlagName
    }
    deriving (Show, Eq)

