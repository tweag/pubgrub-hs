-- | A package's instances, and sets of them.
--
-- An instance is one concrete way of having a package: a specific pre-installed
-- unit, or a source release. Flags are not part of an instance: an automatic
-- flag is a solver variable of its own ('PubGrub.Cabal.FlagVar'), decided
-- beside the version, and a manual flag is fixed before the solver sees the
-- release.
--
-- A set of instances has two halves, represented differently because they
-- differ in kind. The installed half is /extensional/: the installed database is
-- small and fully known, so it is a plain 'Set' of units. The source half is
-- /intensional/: a dependency's declared range admits versions the index may not
-- even have, so it is kept as one 'VersionSet', a range over versions rather
-- than a list of them, and never enumerated. Both halves are canonical, so the
-- set has a lawful 'Eq' and 'Ord', every operation is exact, and 'isEmpty'
-- answers both ways.
module PubGrub.Cabal.InstanceSet
    ( HasVersion (..)
    , Instance (..)
    , InstanceSet (..)
    , emptyInstanceSet
    , sourceInstances
    , singletonInstance
    , memberInstance
    , isEveryVersion
    ) where

import           Data.Set                   (Set)
import qualified Data.Set                   as Set
import qualified Data.Text                  as T
import           PubGrub.Cabal.PreInstalled (PreInstalledPackage (..))
import           PubGrub.Cabal.Pretty       ()
import           PubGrub.Cabal.Version      (Version)
import           PubGrub.Cabal.VersionSet   (VersionSet)
import qualified PubGrub.Cabal.VersionSet   as VersionSet
import           PubGrub.Pretty             (Pretty (..))
import           PubGrub.SetOps             (SetOps (..))

-- | A pre-installed unit carries a version, and so does an 'Instance' — this is
-- what lets the 'PubGrub.Provider.Provider' turn a @.cabal@ dependency's
-- 'VersionSet' into the corresponding set of instances.
class HasVersion a where
    version :: a -> Version

instance HasVersion PreInstalledPackage where
    version = pipVersion

-- | One concrete way of having a package. It /identifies/ that way and does not
-- describe it: it carries no dependencies, which come from the provider that
-- owns the index the identifier points into.
data Instance
    = UsePreInstalled PreInstalledPackage
    | BuildSource Version
    deriving (Eq, Ord, Show)

instance HasVersion Instance where
    version (UsePreInstalled pip) = version pip
    version (BuildSource v)       = v

instance Pretty Instance where
    pretty (UsePreInstalled pip) = T.pack "installed:" <> pretty (pipUnitId pip)
    pretty (BuildSource v)       = pretty v

-- | A set of 'Instance's of one package.
data InstanceSet = InstanceSet
    { isInstalled :: Set PreInstalledPackage
    -- ^ the pre-installed units in the set, extensionally
    , isSource    :: VersionSet
    -- ^ the source releases in the set, as a range
    }
    deriving (Eq, Ord, Show)

instance SetOps InstanceSet where
    empty = emptyInstanceSet
    union a b = InstanceSet (isInstalled a `Set.union` isInstalled b) (isSource a `union` isSource b)
    intersect a b = InstanceSet (isInstalled a `Set.intersection` isInstalled b) (isSource a `intersect` isSource b)
    difference a b = InstanceSet (isInstalled a `Set.difference` isInstalled b) (isSource a `difference` isSource b)
    isEmpty a = Set.null (isInstalled a) && isEmpty (isSource a)
    isSubsetOf a b = isInstalled a `Set.isSubsetOf` isInstalled b && isSource a `isSubsetOf` isSource b
    isDisjoint a b = isInstalled a `Set.disjoint` isInstalled b && isSource a `isDisjoint` isSource b

-- | The empty instance set. @Negative emptyInstanceSet@ is the always-true
-- term ⊤; @Positive emptyInstanceSet@ is the never-true term ⊥.
emptyInstanceSet :: InstanceSet
emptyInstanceSet = InstanceSet Set.empty VersionSet.emptyVersionSet

-- | The source releases in a range, and no installed unit.
sourceInstances :: VersionSet -> InstanceSet
sourceInstances = InstanceSet Set.empty

-- | The set containing exactly one instance — the shape of a decision.
singletonInstance :: Instance -> InstanceSet
singletonInstance (UsePreInstalled pip) = InstanceSet (Set.singleton pip) VersionSet.emptyVersionSet
singletonInstance (BuildSource v)       = sourceInstances (VersionSet.singletonVersionSet v)

-- | Is the instance in the set?
memberInstance :: Instance -> InstanceSet -> Bool
memberInstance (UsePreInstalled pip) s = Set.member pip (isInstalled s)
memberInstance (BuildSource v) s       = VersionSet.contains (isSource s) v

-- | Does the set admit every source release of its package? True of an
-- unconstrained target's request and of a depender that spans the whole
-- version list. The report writes such a set as \"every version of foo\"
-- rather than \"foo any\".
isEveryVersion :: InstanceSet -> Bool
isEveryVersion s = isSource s == VersionSet.fullVersionSet

instance Pretty InstanceSet where
    pretty s = T.intercalate (T.pack " or ") (installed <> source)
      where
        -- An installed unit whose version the range admits is one of the range's
        -- versions, and naming it separately tells a reader nothing. The unit id
        -- is never shown: it is a hash, and the version is what a reader can act
        -- on.
        installed =
            [ pretty (pipVersion pip) <> T.pack " (installed)"
            | pip <- Set.toList (isInstalled s)
            , not (VersionSet.contains (isSource s) (pipVersion pip))
            ]
        source = [pretty (isSource s) | not (isEmpty (isSource s))]
