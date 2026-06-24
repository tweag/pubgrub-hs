-- | The concrete element and set types for choosing between installed and
-- source instances of a package. Not yet wired into the solver: 'ChoiceSet'
-- has no 'PubGrub.Lattice.Sets' or 'PubGrub.Pretty.Pretty' instance, and no
-- provider produces it.
module PubGrub.Choice (
    Choice (..),
    ChoiceInstalled (..),
    ChoiceSource (..),
    Repository (..),
    ChoiceSet (..),
    version,
    name,
) where

import           Distribution.Types.PackageName (PackageName)
import           Distribution.Types.UnitId      (UnitId)
import           Distribution.Types.Version     (Version)
import           PubGrub.Compiler               (PackageDb)
import           PubGrub.Pow                    (Pow)
import           PubGrub.VersionSet             (VersionSet)

-- | One concrete realisation of a package: a pre-installed instance or a
-- buildable source release. A decision commits to one, and it is the element
-- type of 'ChoiceSet'.
data Choice = Installed ChoiceInstalled | Source ChoiceSource

-- | A pre-installed package, identified by its package-db key ('ciUnitId').
-- Its dependencies are already fixed (to specific installed unit-ids).
data ChoiceInstalled = ChoiceInstalled
    { ciName      :: PackageName
    , ciVersion   :: Version
    , ciPackageDB :: PackageDb
    , ciUnitId    :: UnitId
    -- ^ the identity: distinguishes instances that share name and version
    }

-- | A buildable source release. Its dependencies are version ranges.
data ChoiceSource = ChoiceSource
    { csName       :: PackageName
    , csVersion    :: Version
    , csRepository :: Repository
    }

-- | Where a source release comes from.
data Repository = Hackage

-- | The version of a choice, regardless of how it is realised.
version :: Choice -> Version
version (Installed ci) = ciVersion ci
version (Source cs)    = csVersion cs

-- | The package name of a choice.
name :: Choice -> PackageName
name (Installed ci) = ciName ci
name (Source cs)    = csName cs

-- | A set of choices: a product of the two worlds. The installed world is keyed
-- by 'UnitId', so instances sharing name and version stay distinct; the source
-- world is keyed by version. Boolean structure is componentwise.
data ChoiceSet = ChoiceSet
    { csetInstalled :: Pow UnitId
    , csetSource    :: VersionSet
    }
