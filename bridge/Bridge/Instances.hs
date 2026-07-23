-- | Translating Cabal package descriptions into the solver's source model.
--
-- Flags are fixed at their defaults: a package's dependencies are those active
-- under the default flag assignment, with OS, architecture and compiler
-- conditions resolved against a given 'Platform' and 'CompilerInfo'.
module Bridge.Instances
    ( toSourcePackage
    ) where

import           Bridge.Cabal.Flatten                         (flattenDeps)
import qualified Data.Map.Strict                              as Map
import           Distribution.Compiler                        (CompilerInfo)
import           Distribution.System                          (Platform)
import           Distribution.Types.Condition                 (Condition (Lit))
import           Distribution.Types.GenericPackageDescription (GenericPackageDescription,
                                                               genPackageFlags,
                                                               packageDescription)
import           Distribution.Types.PackageDescription        (package)
import           Distribution.Types.PackageId                 (pkgVersion)
import           PubGrub.InstanceSet                          (Dependency (Dependency),
                                                               SourcePackage (SourcePackage))

-- | Translate a Cabal 'GenericPackageDescription' into our 'SourcePackage'.
--
-- The conditional dependency tree is flattened under the default flag
-- assignment by 'flattenDeps', so every resulting dependency is unconditional
-- (@Lit True@). The declared flags are still recorded on the 'SourcePackage',
-- though no dependency is conditional on them.
toSourcePackage :: Platform -> CompilerInfo -> GenericPackageDescription -> SourcePackage
toSourcePackage platform compiler gpd =
    SourcePackage
        (pkgVersion (package (packageDescription gpd)))
        (genPackageFlags gpd)
        [ Dependency name range (Lit True)
        | (name, range) <- Map.toList (flattenDeps platform compiler gpd)
        ]
        (Lit True)
