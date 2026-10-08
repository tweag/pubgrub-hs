-- | The values a 'PubGrub.Variable.Var' takes, and sets of them.
--
-- A package variable takes an 'Instance'; a flag variable takes a 'Bool'. A set
-- of values is a set of instances or a set of Booleans, and the two kinds never
-- meet: a term is always about one variable, and every operation on terms
-- combines two terms about the same variable. The mixed cases of the 'SetOps'
-- instance are therefore unreachable; they are given a total definition rather
-- than an error, and the definition is the one that would make a reached case
-- visible (an empty result, never a silently widened one).
module PubGrub.Value
    ( -- * Values
      Value (..)
    , valueInstance
      -- * Sets of values
    , BoolSet (..)
    , boolSet
    , bothValues
    , noValues
    , memberBool
    , ValueSet (..)
    , emptyValueSetLike
    , singletonValue
    , memberValue
    , packageSet
      -- * A plan
    , Resolved (..)
    , resolvedInstance
    , foldFlags
    ) where

import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import qualified Data.Text                      as T
import           Distribution.Types.Flag        (FlagAssignment,
                                                 insertFlagAssignment,
                                                 mkFlagAssignment,
                                                 showFlagAssignment)
import           Distribution.Types.PackageName (PackageName)
import           PubGrub.Index.PreInstalled     (PreInstalledPackage)
import           PubGrub.InstanceSet            (Instance (..), InstanceSet,
                                                 emptyInstanceSet,
                                                 memberInstance,
                                                 singletonInstance)
import           PubGrub.Pretty                 (Pretty (..))
import           PubGrub.SetOps                 (SetOps (..))
import           PubGrub.Variable               (Flag (..), Var (..))
import           PubGrub.Version                (Version)

-- --------------------------------------------------------------------------
-- Values
-- --------------------------------------------------------------------------

data Value
    = PackageValue Instance
    | FlagValue Bool
    deriving (Eq, Ord, Show)

valueInstance :: Value -> Maybe Instance
valueInstance (PackageValue i) = Just i
valueInstance (FlagValue _)    = Nothing

instance Pretty Value where
    pretty (PackageValue i)  = pretty i
    pretty (FlagValue True)  = T.pack "on"
    pretty (FlagValue False) = T.pack "off"

-- --------------------------------------------------------------------------
-- Sets
-- --------------------------------------------------------------------------

-- | A subset of @{False, True}@.
data BoolSet = BoolSet
    { allowsFalse :: Bool
    , allowsTrue  :: Bool
    }
    deriving (Eq, Ord, Show)

instance SetOps BoolSet where
    union (BoolSet f t) (BoolSet f' t') = BoolSet (f || f') (t || t')
    intersect (BoolSet f t) (BoolSet f' t') = BoolSet (f && f') (t && t')
    difference (BoolSet f t) (BoolSet f' t') = BoolSet (f && not f') (t && not t')
    isEmpty (BoolSet f t) = not f && not t

boolSet :: Bool -> BoolSet
boolSet True  = BoolSet False True
boolSet False = BoolSet True False

bothValues, noValues :: BoolSet
bothValues = BoolSet True True
noValues = BoolSet False False

memberBool :: Bool -> BoolSet -> Bool
memberBool True  = allowsTrue
memberBool False = allowsFalse

instance Pretty BoolSet where
    pretty (BoolSet True True)   = T.pack "on or off"
    pretty (BoolSet False True)  = T.pack "on"
    pretty (BoolSet True False)  = T.pack "off"
    pretty (BoolSet False False) = T.pack "neither"

-- | A set of values of one variable.
data ValueSet
    = PackageSet InstanceSet
    | FlagSet BoolSet
    deriving (Eq, Ord, Show)

-- | Componentwise. The mixed cases cannot arise (see the module header); they
-- answer with the empty set of the left operand's kind for an intersection or
-- a difference, and with the left operand for a union.
instance SetOps ValueSet where
    union (PackageSet a) (PackageSet b) = PackageSet (a `union` b)
    union (FlagSet a) (FlagSet b)       = FlagSet (a `union` b)
    union a _                           = a
    intersect (PackageSet a) (PackageSet b) = PackageSet (a `intersect` b)
    intersect (FlagSet a) (FlagSet b)       = FlagSet (a `intersect` b)
    intersect a _                           = emptyValueSetLike a
    difference (PackageSet a) (PackageSet b) = PackageSet (a `difference` b)
    difference (FlagSet a) (FlagSet b)       = FlagSet (a `difference` b)
    difference a _                           = emptyValueSetLike a
    isEmpty (PackageSet a) = isEmpty a
    isEmpty (FlagSet a)    = isEmpty a

-- | The empty set of the same kind.
emptyValueSetLike :: ValueSet -> ValueSet
emptyValueSetLike (PackageSet _) = PackageSet emptyInstanceSet
emptyValueSetLike (FlagSet _)    = FlagSet noValues

singletonValue :: Value -> ValueSet
singletonValue (PackageValue i) = PackageSet (singletonInstance i)
singletonValue (FlagValue b)    = FlagSet (boolSet b)

memberValue :: Value -> ValueSet -> Bool
memberValue (PackageValue i) (PackageSet s) = memberInstance i s
memberValue (FlagValue b) (FlagSet s)       = memberBool b s
memberValue _ _                             = False

-- | The instances a set holds, if it is a set of instances.
packageSet :: ValueSet -> Maybe InstanceSet
packageSet (PackageSet s) = Just s
packageSet (FlagSet _)    = Nothing

instance Pretty ValueSet where
    pretty (PackageSet s) = pretty s
    pretty (FlagSet s)    = pretty s

-- --------------------------------------------------------------------------
-- A plan
-- --------------------------------------------------------------------------

-- | One package of a plan, as a reader sees it: the solver's decisions on a
-- source release and on each of its flags, folded into one entry.
data Resolved
    = Installed PreInstalledPackage
    | Built Version FlagAssignment
    deriving (Eq, Show)

resolvedInstance :: Resolved -> Instance
resolvedInstance (Installed pip) = UsePreInstalled pip
resolvedInstance (Built v _)     = BuildSource v

instance Pretty Resolved where
    pretty (Installed pip) = pretty (UsePreInstalled pip)
    pretty (Built v fa) = pretty v <> T.pack (showFlagAssignment fa)

-- | Fold the solver's answer into one entry per package: each decided flag
-- goes into the flag assignment of its owner, which must be a source release.
-- A flag whose owner is not in the answer, or not built from source, is dropped;
-- neither can happen, since a flag is only ever decided under its owner.
foldFlags :: Map Var Value -> Map PackageName Resolved
foldFlags decided = Map.foldrWithKey fold owners decided
  where
    owners =
        Map.fromList
            [ (p, resolved i)
            | (PackageVar p, PackageValue i) <- Map.toList decided
            ]
    resolved (UsePreInstalled pip) = Installed pip
    resolved (BuildSource v)       = Built v (mkFlagAssignment [])
    fold (FlagVar p f) (FlagValue b) = Map.adjust (withFlag f b) p
    fold _ _                         = id
    withFlag f b (Built v fa) = Built v (insertFlagAssignment (flagName f) b fa)
    withFlag _ _ r            = r
