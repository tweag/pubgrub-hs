module PubGrub.InstanceSet where

import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Data.Set                       (Set)
import qualified Data.Set                       as Set
import qualified Data.Text                      as T
import           Distribution.Types.Flag        (FlagAssignment, FlagName,
                                                 showFlagAssignment,
                                                 unFlagAssignment)
import           Distribution.Types.Version     (Version)
import           PubGrub.Index.PreInstalled     (PreInstalledPackage (..))
import           PubGrub.InstanceSet.SourceCell (SourceCell (..),
                                                 differenceCell, intersectCell,
                                                 mergeCells, nullCell,
                                                 singletonCell)
import           PubGrub.Pretty                 (Pretty (..))
import           PubGrub.SetOps                 (SetOps (..))
import qualified PubGrub.VersionSet             as VersionSet

-- | A pre-installed unit carries a version, and so does an 'Instance' — this is
-- what lets the 'PubGrub.Provider.Provider' turn a @.cabal@ dependency's
-- 'PubGrub.VersionSet.VersionSet' into the corresponding set of instances.
class HasVersion a where
    version :: a -> Version

instance HasVersion PreInstalledPackage where
    version = pipVersion

-- Package Instance ------------------------------------------------------------

-- | The value domain of a solver variable: one concrete, fully-determined way
-- of having a package — use a specific pre-installed unit, or build a source
-- release under a flag assignment. The assignment must be /total/ over the
-- package's declared flags (a 'Provider' invariant, not enforced here), so an
-- instance has no conditionals left.
--
-- An 'Instance' /identifies/ a way of having a package; it does not describe
-- one, and carries no dependencies. Those come from the 'Provider', which owns
-- the index the identifier points into, so enumerating a package's instances
-- parses no @.cabal@ file, and no instance has to stand for dependencies it
-- does not know.
--
-- The two identifiers differ in shape because the two halves of an
-- 'InstanceSet' do. A unit ID is global and the installed half is an explicit
-- set, so identity is all it needs. A source release is identified only
-- /relative to its package name/, and stays structured because the source half
-- is symbolic: membership tests the version against a range and the assignment
-- against pinned flags.
data Instance
    = UsePreInstalled PreInstalledPackage
    | BuildSource Version FlagAssignment
    deriving (Show, Eq)

instance HasVersion Instance where
    version (UsePreInstalled pip) = version pip
    version (BuildSource v _)     = v

instance Pretty Instance where
    pretty (UsePreInstalled pip) = T.pack "installed:" <> pretty (pipUnitId pip)
    pretty (BuildSource v fa)    = pretty v <> T.pack (showFlagAssignment fa)

-- | A set of instances in two halves: the pre-installed units, listed
-- explicitly, and the source instances, as a union of 'SourceCell's. A cell
-- keeps the version range it was built from, so a report can still be phrased
-- in ranges after the set algebra has run.
data InstanceSet = InstanceSet
    { isInstalled :: Set PreInstalledPackage
    -- ^ The pre-installed units in the set.
    , isSource    :: [SourceCell]
    }

instance SetOps InstanceSet where
    union lhs rhs  =
        InstanceSet
            { isInstalled = isInstalled lhs `Set.union` isInstalled rhs
            , isSource    = mergeCells (isSource lhs <> isSource rhs)
            }
    intersect lhs rhs =
        InstanceSet
            { isInstalled = isInstalled lhs `Set.intersection` isInstalled rhs
            , isSource    =
                [ cell
                | x <- isSource lhs
                , y <- isSource rhs
                , Just cell <- [intersectCell x y]   -- drops contradictory flag pins
                , not (nullCell cell)
                ]
            }
    difference lhs rhs
        = InstanceSet
            { isInstalled = isInstalled lhs `Set.difference` isInstalled rhs
            , isSource    = foldl' (\xs y -> concatMap (`differenceCell` y) xs) (isSource lhs) (isSource rhs)
            }
    isEmpty is = Set.null (isInstalled is) && all nullCell (isSource is)

-- | The empty instance set. @Negative emptyInstanceSet@ is the always-true
-- term ⊤; @Positive emptyInstanceSet@ is the never-true term ⊥.
emptyInstanceSet :: InstanceSet
emptyInstanceSet = InstanceSet { isInstalled = Set.empty, isSource = [] }

-- | The set containing exactly one instance — the shape of a decision.
-- @singletonInstance (BuildSource v fa)@ is a cell pinning every flag in @fa@,
-- so it is a singleton only if @fa@ is total over the package's declared flags:
-- a cell denotes every value of a flag it leaves unpinned.
singletonInstance :: Instance -> InstanceSet
singletonInstance (UsePreInstalled pip) = singletonUsePreInstalled pip
singletonInstance (BuildSource v flags) = singletonBuildSource v flags

singletonUsePreInstalled :: PreInstalledPackage -> InstanceSet
singletonUsePreInstalled pip =
    InstanceSet { isInstalled = Set.singleton pip, isSource = [] }

singletonBuildSource :: Version -> FlagAssignment -> InstanceSet
singletonBuildSource v flags =
    InstanceSet { isInstalled = Set.empty, isSource = [singletonCell v flags] }

-- | Does the set contain this instance?
memberInstance :: Instance -> InstanceSet -> Bool
memberInstance (UsePreInstalled pip) is =
    Set.member pip (isInstalled is)
memberInstance (BuildSource v fa) is = any inCell (isSource is)
    where
        inCell (SourceCell vs flags) =
            vs `VersionSet.contains` v
            && flags `memberFlagAssignment` fa

-- | Does an assignment satisfy a cell's pins? Every pin must be met; flags the
-- cell leaves free are unconstrained — which is exactly "the pins are a submap
-- of the assignment".
--
-- Note the direction. Quantifying over the /assignment/ instead would demand
-- that every assigned flag also be pinned, so an unpinned cell would contain
-- nothing rather than everything.
memberFlagAssignment :: Map FlagName Bool -> FlagAssignment -> Bool
memberFlagAssignment flags fa = flags `Map.isSubmapOf` Map.fromList (unFlagAssignment fa)

instance Pretty InstanceSet where
    pretty is =
        T.intercalate (T.pack " or ")
            ( map (pretty . pipUnitId) (Set.toList (isInstalled is)) <> map pretty (isSource is)
            )
