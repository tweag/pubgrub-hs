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
import           PubGrub.Index.SourcePackage    (SourcePackage (..))
import           PubGrub.InstanceSet.SourceCell (SourceCell (..),
                                                 differenceCell, intersectCell,
                                                 mergeCells, nullCell,
                                                 singletonCell)
import           PubGrub.Pretty                 (Pretty (..))
import           PubGrub.SetOps                 (SetOps (..))
import qualified PubGrub.VersionSet             as VersionSet

-- | Both kinds of index entries carry a version, and so does an 'Instance' —
-- this is what lets the 'Provider' turn a 'Dependency'\'s 'VersionSet' into
-- the corresponding set of instances.
class HasVersion a where
    version :: a -> Version

instance HasVersion PreInstalledPackage where
    version = pipVersion

instance HasVersion SourcePackage where
    version = spVersion

-- Package Instance ------------------------------------------------------------

-- | The value domain of a solver variable: one concrete, fully-determined way
-- of having a package — use a specific pre-installed unit, or build a source
-- package under a flag assignment. The assignment must be /total/ over the
-- package's declared flags (a 'Provider' invariant, not enforced here), so an
-- instance has no conditionals left: its dependencies are plain facts.
data Instance
    = UsePreInstalled PreInstalledPackage
    | BuildSource SourcePackage FlagAssignment
    deriving (Show, Eq)

instance HasVersion Instance where
    version (UsePreInstalled pip) = version pip
    version (BuildSource sp _)    = version sp

instance Pretty Instance where
    pretty (UsePreInstalled pip) = T.pack "installed:" <> pretty (pipUnitId pip)
    pretty (BuildSource sp fa)   = pretty (spVersion sp) <> T.pack (showFlagAssignment fa)

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
-- @singletonInstance (BuildSource sp fa)@ is a cell pinning every flag in @fa@,
-- so it is a singleton only if @fa@ is total over the package's declared flags:
-- a cell denotes every value of a flag it leaves unpinned.
singletonInstance :: Instance -> InstanceSet
singletonInstance (UsePreInstalled pip) = InstanceSet { isInstalled = Set.singleton pip, isSource = [] }
singletonInstance (BuildSource sp flags) = InstanceSet { isInstalled = Set.empty, isSource = [singletonCell sp flags] }

-- | Does the set contain this instance?
memberInstance :: Instance -> InstanceSet -> Bool
memberInstance (UsePreInstalled pip) is =
    Set.member pip (isInstalled is)
memberInstance (BuildSource sp fa) is = any inCell (isSource is)
    where
        inCell (SourceCell vs flags) =
            vs `VersionSet.contains` version sp
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
