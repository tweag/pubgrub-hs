{-# LANGUAGE DerivingVia #-}
module PubGrub.InstanceSet where
import           Data.Map.Strict            (Map)
import           Data.Set                   (Set)
import qualified Data.Set                   as Set
import           Data.String                (IsString (..))
import           Distribution.Types.Version (Version)
import           PubGrub.Pretty             (Pretty (..))
import           PubGrub.Term               (SetOps)
import           PubGrub.VersionSet         (VersionSet)

-- ---------------------------------------------------------------------------
-- Packages and dependencies
-- ---------------------------------------------------------------------------

newtype PackageName = PackageName String deriving (Eq, Ord, Show)

instance Pretty PackageName where
    pretty (PackageName n) = fromString n

newtype UnitId = UnitId Int deriving (Eq, Ord, Show)

-- | Both kinds of index entries carry a version, and so does an 'Instance' —
-- this is what lets the 'Provider' turn a 'Dependency'\'s 'VersionSet' into
-- the corresponding set of instances.
class HasVersion a where
    version :: a -> Version

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

instance HasVersion PreInstalledPackage where
    version = pipVersion

-- | The name of a flag, as a package declares it.
newtype FlagName = FlagName String
    deriving (Eq, Ord, Show)

instance Pretty FlagName where
    pretty (FlagName n) = fromString n

-- | A flag is a named boolean option that can be set to @True@ or @False@.
-- Each flag has a default value, which is used when the flag is not explicitly set.
-- A manual flag may only be set by the user; an automatic flag may also be
-- flipped freely by the solver to resolve conflicts.
data Flag = Flag
    { flagName    :: FlagName
    , flagDefault :: Bool
    , flagManual  :: Bool
    }
    deriving (Eq, Ord, Show)

newtype FlagAssignment = FlagAssignment (Map FlagName Bool)
    deriving (Eq, Ord, Show)

data Condition a
    = Var a
    | Lit Bool
    | CNot (Condition a)
    | CAnd (Condition a) (Condition a)
    | COr (Condition a) (Condition a)
    deriving (Show, Eq, Ord)

-- | The dependencies expressed by a source package. Each dependency is a
-- package, a version set, and a condition over the package's own flags that
-- must hold for the dependency to be active (@'Lit' True@ = unconditional).
--
-- Note the /target/ of a dependency is constrained by version only — a
-- dependency cannot demand how the dependee is provided (which unit, which
-- flags). The 'Provider' widens the version set into the instance set
-- @{i | 'version' i ∈ vs}@.
data Dependency = Dependency PackageName VersionSet (Condition FlagName)
    deriving (Show, Eq, Ord)

-- | A source package is a package that can be built from source: a version,
-- the flags it declares, its (conditional) dependencies, and a buildability
-- condition over its flags. Flags /determine/ the dependencies — that is why
-- a flag assignment is part of a 'BuildSource' instance: fixing the instance
-- fixes the dependencies.
data SourcePackage
    = SourcePackage
    { spVersion      :: Version
    , spFlags        :: [Flag]
    , spDependencies :: [Dependency]
    , spBuildable    :: Condition FlagName
    }
    deriving (Show, Eq, Ord)

instance HasVersion SourcePackage where
    version = spVersion

-- Package Index ---------------------------------------------------------------

newtype IndexPackage = IndexPackage (Either PreInstalledPackage SourcePackage)
    deriving (Show)

newtype Index = Index (Map PackageName [IndexPackage])
    deriving (Show)

-- Package Instance ------------------------------------------------------------

-- | The value domain of a solver variable: one concrete, fully-determined way
-- of having a package — use a specific pre-installed unit, or build a source
-- package under a flag assignment. The assignment must be /total/ over the
-- package's declared flags (a 'Provider' invariant, not enforced here), so an
-- instance has no conditionals left: its dependencies are plain facts.
data Instance
    = UsePreInstalled PreInstalledPackage
    | BuildSource SourcePackage FlagAssignment
    deriving (Show, Eq, Ord)

instance HasVersion Instance where
    version (UsePreInstalled pip) = version pip
    version (BuildSource sp _)    = version sp

-- | A set of instances, stored explicitly. Per package the universe is finite
-- and known — whatever the 'Index' enumerates — which is what makes the
-- explicit representation workable. It also hides behind 'SetOps': if the
-- 2^flags blow-up ever hurts, a symbolic representation can replace this one
-- without the algorithm noticing.
newtype InstanceSet = InstanceSet (Set Instance)
    deriving (Show, Eq, Ord)

deriving via Set Instance instance SetOps InstanceSet

-- | The empty instance set. @Negative emptyInstanceSet@ is the always-true
-- term ⊤; @Positive emptyInstanceSet@ is the never-true term ⊥.
emptyInstanceSet :: InstanceSet
emptyInstanceSet = InstanceSet Set.empty

-- | The set containing exactly one instance — the shape of a decision.
singletonInstance :: Instance -> InstanceSet
singletonInstance = InstanceSet . Set.singleton

-- | Does the set contain this instance?
memberInstance :: Instance -> InstanceSet -> Bool
memberInstance i (InstanceSet s) = Set.member i s
