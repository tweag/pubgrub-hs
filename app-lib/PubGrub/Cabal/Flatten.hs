{- | Flatten a GenericPackageDescription's main-library dependencies into a
concrete version-set map, resolving conditionals at default flag values for
a fixed platform and compiler. Flag *solving* is out of scope.
-}
module PubGrub.Cabal.Flatten (
    flattenDeps,
) where

import           Data.Map.Strict                               (Map)
import qualified Data.Map.Strict                               as Map

import           Distribution.Compiler                         (CompilerInfo)
import           Distribution.PackageDescription.Configuration (finalizePD)
import           Distribution.System                           (Platform)
import           Distribution.Types.BuildInfo                  (targetBuildDepends)
import           Distribution.Types.ComponentRequestedSpec     (defaultComponentRequestedSpec)
import           Distribution.Types.Dependency                 (depPkgName,
                                                                depVerRange)
import           Distribution.Types.Flag                       (mkFlagAssignment)
import           Distribution.Types.GenericPackageDescription  (GenericPackageDescription)
import           Distribution.Types.Library                    (libBuildInfo)
import           Distribution.Types.PackageDescription         (library)
import           Distribution.Types.PackageName                (PackageName)

import           PubGrub.VersionSet                            (VersionSet)
import qualified PubGrub.VersionSet                            as VS

{- | Main-library dependencies of a package version, as a version-set map.
Returns the empty map if the package has no library or finalization fails.
-}
flattenDeps :: Platform -> CompilerInfo -> GenericPackageDescription -> Map PackageName VersionSet
flattenDeps platform compiler gpd =
    case finalizePD
        (mkFlagAssignment [])
        defaultComponentRequestedSpec
        (const True)
        platform
        compiler
        []
        gpd of
        Left _missing -> Map.empty
        Right (pd, _flags) ->
            case library pd of
                Nothing -> Map.empty
                Just lib ->
                    Map.fromListWith
                        VS.intersection
                        [ (depPkgName d, VS.fromVersionRange (depVerRange d))
                        | d <- targetBuildDepends (libBuildInfo lib)
                        ]
