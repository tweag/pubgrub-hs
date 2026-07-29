module PubGrub.Index.PreInstalled where

import           Distribution.Types.UnitId  (UnitId)
import           Distribution.Types.Version (Version)

  -- | A package already present in the environment: a unit ID, a version, and
-- dependencies on other pre-installed units. The 'UnitId' distinguishes
-- different builds of the same package — even two builds of the same version
-- are distinct instances, since they may depend on different units.
data PreInstalledPackage
    = PreInstalledPackage
    { pipUnitId       :: UnitId
    , pipVersion      :: Version
    , pipDependencies :: [UnitId]
    }
    deriving (Eq, Ord, Show)
