{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PatternSynonyms            #-}
{-# LANGUAGE TypeFamilies               #-}

-- | The element and set types for choosing between installed and source
-- instances of a package, as the product of the two worlds.
--
-- A 'Choice' is one realisation of a package, an installed instance (its
-- package-db 'UnitId') or a source release (its 'Version'): the disjoint union
-- of the two worlds' keys. A 'ChoiceSet' is the product of their set types,
-- @Pow UnitId@ × 'VersionSet'. Both are thin wrappers over the generic products
-- (the @(a, b)@ instances in "PubGrub.Lattice"), and carry nothing more: a
-- choice's name, database and repository belong to whatever supplies the
-- choices.
module PubGrub.Choice (
    Choice,
    pattern Installed,
    pattern Source,
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

-- | One realisation of a package: an installed instance keyed by 'UnitId', or a
-- source release keyed by 'Version'.
newtype Choice = Choice (Either UnitId Version)
    deriving stock (Eq, Show)

-- | An installed choice (the first/left world).
pattern Installed :: UnitId -> Choice
pattern Installed u = Choice (Left u)

-- | A source choice (the second/right world).
pattern Source :: Version -> Choice
pattern Source v = Choice (Right v)

{-# COMPLETE Installed, Source #-}

-- | A set of choices: the product of the installed world (@Pow UnitId@) and the
-- source world ('VersionSet'), with every Boolean operation taken
-- componentwise. Its elements are 'Choice'.
newtype ChoiceSet = ChoiceSet (Pow UnitId, VersionSet)
    deriving stock (Eq, Show)
    deriving (Lattice, BoundedLattice, Boolean)

instance Sets ChoiceSet where
    type Elem ChoiceSet = Choice
    singleton (Choice e) = ChoiceSet (singleton e)
    member (Choice e) (ChoiceSet s) = member e s

-- | A source choice renders as its version; an installed one as its unit-id
-- (which already encodes name, version, and hash) plus an @(installed)@ marker.
instance Pretty Choice where
    pretty (Installed uid) = T.pack (prettyShow uid) <> " (installed)"
    pretty (Source v)      = pretty v

-- | A choice set renders as its source range, followed by the unit-ids of the
-- installed instances it admits when that set is finite and non-empty.
instance Pretty ChoiceSet where
    pretty (ChoiceSet (i, s)) = pretty s <> installedNote i
      where
        installedNote (Incl u)
            | Set.null u = ""
            | otherwise =
                " (also installed: "
                    <> T.intercalate ", " (map (T.pack . prettyShow) (Set.toList u))
                    <> ")"
        installedNote (Excl _) = ""
