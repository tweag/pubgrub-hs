-- | The values a 'PubGrub.Cabal.Variable.Var' takes, and sets of them.
--
-- A package variable takes an 'Instance'; a flag variable takes a 'Bool'. A
-- value is therefore a sum, 'Value'. A /set/ of values is not: the subsets of
-- @A + B@ are the pairs of a subset of @A@ and a subset of @B@, so 'ValueSet'
-- is the product of an 'InstanceSet' and a 'BoolSet'. Every set operation is
-- componentwise and total, with no case for sets \"of different kinds\" — a
-- package variable's set simply has an empty flag component, and a flag
-- variable's set an empty instance component. 'InstanceSet' is the same shape
-- one level down: the installed units and the source range are the two halves
-- of a set over @PreInstalled + Version@.
module PubGrub.Cabal.Value
    ( -- * Values
      Value (..)
    , valueInstance
      -- * Sets of values
    , BoolSet (..)
    , boolSet
    , bothValues
    , neitherValue
    , memberBool
    , ValueSet (..)
    , emptyValueSet
    , instanceSet
    , flagSet
    , singletonValue
    , memberValue
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
import           PubGrub.Cabal.InstanceSet      (Instance (..), InstanceSet,
                                                 emptyInstanceSet,
                                                 memberInstance,
                                                 singletonInstance)
import           PubGrub.Cabal.PreInstalled     (PreInstalledPackage)
import           PubGrub.Cabal.Variable         (Flag (..), Var (..))
import           PubGrub.Cabal.Version          (Version)
import           PubGrub.Pretty                 (Pretty (..))
import           PubGrub.SetOps                 (SetOps (..))

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
    empty = neitherValue
    union (BoolSet f t) (BoolSet f' t') = BoolSet (f || f') (t || t')
    intersect (BoolSet f t) (BoolSet f' t') = BoolSet (f && f') (t && t')
    difference (BoolSet f t) (BoolSet f' t') = BoolSet (f && not f') (t && not t')
    isEmpty (BoolSet f t) = not f && not t
    isSubsetOf (BoolSet f t) (BoolSet f' t') = (f' || not f) && (t' || not t)
    isDisjoint (BoolSet f t) (BoolSet f' t') = not (f && f') && not (t && t')

boolSet :: Bool -> BoolSet
boolSet True  = BoolSet False True
boolSet False = BoolSet True False

bothValues, neitherValue :: BoolSet
bothValues = BoolSet True True
neitherValue = BoolSet False False

memberBool :: Bool -> BoolSet -> Bool
memberBool True  = allowsTrue
memberBool False = allowsFalse

instance Pretty BoolSet where
    pretty (BoolSet True True)   = T.pack "on or off"
    pretty (BoolSet False True)  = T.pack "on"
    pretty (BoolSet True False)  = T.pack "off"
    pretty (BoolSet False False) = T.pack "neither"

-- | A set of values: some instances and some Booleans. Both components are
-- canonical, so the set has a lawful 'Eq' and 'Ord' and an exact 'isEmpty'.
data ValueSet = ValueSet
    { vsInstances :: InstanceSet
    , vsFlags     :: BoolSet
    }
    deriving (Eq, Ord, Show)

instance SetOps ValueSet where
    empty = emptyValueSet
    union (ValueSet a b) (ValueSet a' b') = ValueSet (a `union` a') (b `union` b')
    intersect (ValueSet a b) (ValueSet a' b') = ValueSet (a `intersect` a') (b `intersect` b')
    difference (ValueSet a b) (ValueSet a' b') = ValueSet (a `difference` a') (b `difference` b')
    isEmpty (ValueSet a b) = isEmpty a && isEmpty b
    isSubsetOf (ValueSet a b) (ValueSet a' b') = a `isSubsetOf` a' && b `isSubsetOf` b'
    isDisjoint (ValueSet a b) (ValueSet a' b') = a `isDisjoint` a' && b `isDisjoint` b'

-- | No values. @Negative emptyValueSet@ is the always-true term ⊤ for any
-- variable; @Positive emptyValueSet@ is the never-true term ⊥.
emptyValueSet :: ValueSet
emptyValueSet = ValueSet emptyInstanceSet neitherValue

-- | These instances, and no Boolean: the set a term about a package ranges
-- over.
instanceSet :: InstanceSet -> ValueSet
instanceSet s = ValueSet s neitherValue

-- | These Booleans, and no instance: the set a term about a flag ranges over.
flagSet :: BoolSet -> ValueSet
flagSet = ValueSet emptyInstanceSet

-- | The set holding exactly one value — the shape of a decision.
singletonValue :: Value -> ValueSet
singletonValue (PackageValue i) = instanceSet (singletonInstance i)
singletonValue (FlagValue b)    = flagSet (boolSet b)

memberValue :: Value -> ValueSet -> Bool
memberValue (PackageValue i) s = memberInstance i (vsInstances s)
memberValue (FlagValue b) s    = memberBool b (vsFlags s)

-- | The components that hold anything; in practice one, since a set is only
-- ever about one variable.
instance Pretty ValueSet where
    pretty (ValueSet is bs) =
        T.intercalate (T.pack " or ") ([pretty is | not (isEmpty is)] ++ [pretty bs | not (isEmpty bs)])

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
    pretty (Built v fa)    = pretty v <> T.pack (showFlagAssignment fa)

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
