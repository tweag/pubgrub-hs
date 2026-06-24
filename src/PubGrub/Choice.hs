{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies      #-}

-- | The concrete element and set types for choosing between installed and
-- source instances of a package: 'Choice', one realisation of a package, and
-- 'ChoiceSet', a set of them. 'ChoiceSet' is a 'PubGrub.Lattice.Sets'
-- instance, so the solver can resolve over it. It has no
-- 'PubGrub.Pretty.Pretty' instance yet, and no provider produces it.
module PubGrub.Choice (
    Choice (..),
    ChoiceInstalled (..),
    ChoiceSource (..),
    Repository (..),
    ChoiceSet (..),
    version,
    name,
) where

import qualified Data.Set                       as Set
import qualified Data.Text                      as T
import           Distribution.Types.PackageName (PackageName)
import           Distribution.Types.UnitId      (UnitId)
import           Distribution.Types.Version     (Version)
import           PubGrub.Compiler               (PackageDb)
import           PubGrub.Lattice
import           PubGrub.Pow                    (Pow (..))
import           PubGrub.Pretty                 (Pretty (..))
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
-- world is keyed by version. As a product of two Boolean algebras it is itself
-- one, with every operation taken componentwise.
data ChoiceSet = ChoiceSet
    { csetInstalled :: Pow UnitId
    , csetSource    :: VersionSet
    }
    deriving (Eq, Show)

instance Lattice ChoiceSet where
    ChoiceSet i1 s1 \/ ChoiceSet i2 s2 = ChoiceSet (i1 \/ i2) (s1 \/ s2)
    ChoiceSet i1 s1 /\ ChoiceSet i2 s2 = ChoiceSet (i1 /\ i2) (s1 /\ s2)

instance BoundedLattice ChoiceSet where
    bottom = ChoiceSet bottom bottom
    top = ChoiceSet top top

instance Boolean ChoiceSet where
    neg (ChoiceSet i s) = ChoiceSet (neg i) (neg s)

-- | An installed choice lives only in the installed world (keyed by its
-- unit-id), a source choice only in the source world (keyed by its version), so
-- the two are distinct even at the same version.
instance Sets ChoiceSet where
    type Elem ChoiceSet = Choice
    singleton (Installed ci) = ChoiceSet (singleton (ciUnitId ci)) bottom
    singleton (Source cs)    = ChoiceSet bottom (singleton (csVersion cs))
    member (Installed ci) (ChoiceSet i _) = member (ciUnitId ci) i
    member (Source cs) (ChoiceSet _ s)    = member (csVersion cs) s

instance Pretty Choice where
    pretty (Installed ci) = pretty (ciVersion ci) <> " (installed)"
    pretty (Source cs)    = pretty (csVersion cs)

instance Pretty ChoiceSet where
    pretty (ChoiceSet i s) = pretty s <> installedNote i
      where
        installedNote (Incl u)
            | Set.null u = ""
            | otherwise = " (+" <> T.pack (show (Set.size u)) <> " installed)"
        installedNote (Excl _) = ""
