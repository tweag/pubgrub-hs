{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies      #-}

-- | The element and set types for choosing between installed and source
-- instances of a package.
--
-- A 'Choice' is the minimal identity of one realisation of a package: an
-- installed instance is its package-db key (a 'UnitId'), a source release is its
-- 'Version'. It carries nothing more. A choice's name, database and repository
-- belong to whatever supplies the choices, and are recovered from there.
--
-- 'ChoiceSet' is the product of the two worlds and a 'PubGrub.Lattice.Sets'
-- instance, so the solver resolves over it directly.
module PubGrub.Choice (
    Choice (..),
    ChoiceSet (..),
) where

import qualified Data.Set                   as Set
import qualified Data.Text                  as T
import           Distribution.Pretty        (prettyShow)
import           Distribution.Types.UnitId  (UnitId)
import           Distribution.Types.Version (Version)
import           PubGrub.Lattice
import           PubGrub.Pow                (Pow (..))
import           PubGrub.Pretty             (Pretty (..))
import           PubGrub.VersionSet         (VersionSet)

-- | One realisation of a package: a pre-installed instance, identified by its
-- package-db 'UnitId'; or a source release, identified by its 'Version'.
data Choice = Installed UnitId | Source Version
    deriving (Eq, Show)

-- | A set of choices: a product of the two worlds. The installed world is keyed
-- by 'UnitId', so instances sharing a version stay distinct; the source world is
-- keyed by version. As a product of two Boolean algebras it is itself one, with
-- every operation taken componentwise.
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
    singleton (Installed uid) = ChoiceSet (singleton uid) bottom
    singleton (Source v)      = ChoiceSet bottom (singleton v)
    member (Installed uid) (ChoiceSet i _) = member uid i
    member (Source v) (ChoiceSet _ s)      = member v s

-- | A source choice renders as its version; an installed one as its unit-id
-- (which already encodes name, version, and hash) plus an @(installed)@ marker.
instance Pretty Choice where
    pretty (Installed uid) = T.pack (prettyShow uid) <> " (installed)"
    pretty (Source v)      = pretty v

-- | A choice set renders as its source range, followed by the number of
-- installed instances it admits when that set is finite and non-empty.
instance Pretty ChoiceSet where
    pretty (ChoiceSet i s) = pretty s <> installedNote i
      where
        installedNote (Incl u)
            | Set.null u = ""
            | otherwise = " (+" <> T.pack (show (Set.size u)) <> " installed)"
        installedNote (Excl _) = ""
