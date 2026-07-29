-- | The installed (boot) package world, from a compiler's global package db.
--
-- Indexes @[InstalledPkg]@ for the two lookups the provider needs: all
-- installed units of a package name (they become 'UsePreInstalled' instances),
-- and the instance for a specific 'UnitId' (an installed unit's dependencies
-- name exact units, which pin their packages).
module Bridge.Installed
    ( InstalledDb
    , mkInstalledDb
    , installedInstancesOf
    , unitInstance
    ) where

import           Bridge.Cabal.InstalledPkg      (InstalledPkg (..))
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Distribution.Types.PackageName (PackageName)
import           Distribution.Types.UnitId      (UnitId)
import           PubGrub.Index.PreInstalled     (PreInstalledPackage (..))
import           PubGrub.InstanceSet            (Instance (..))

data InstalledDb = InstalledDb
    { idbById   :: Map UnitId InstalledPkg
    , idbByName :: Map PackageName [InstalledPkg]
    }

mkInstalledDb :: [InstalledPkg] -> InstalledDb
mkInstalledDb pkgs =
    InstalledDb
        { idbById = Map.fromList [(ipUnitId p, p) | p <- pkgs]
        , idbByName = Map.fromListWith (++) [(ipName p, [p]) | p <- pkgs]
        }

toPreInstalled :: InstalledPkg -> PreInstalledPackage
toPreInstalled p =
    PreInstalledPackage
        { pipUnitId = ipUnitId p
        , pipVersion = ipVersion p
        , pipDependencies = ipDepends p
        }

-- | Every installed unit of a package, as a 'UsePreInstalled' instance.
installedInstancesOf :: InstalledDb -> PackageName -> [Instance]
installedInstancesOf db p =
    [UsePreInstalled (toPreInstalled u) | u <- Map.findWithDefault [] p (idbByName db)]

-- | The package name and 'UsePreInstalled' instance for a specific unit id
-- ('Nothing' if it isn't in the db).
unitInstance :: InstalledDb -> UnitId -> Maybe (PackageName, Instance)
unitInstance db uid = do
    u <- Map.lookup uid (idbById db)
    pure (ipName u, UsePreInstalled (toPreInstalled u))
