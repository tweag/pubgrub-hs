{-# LANGUAGE DerivingStrategies   #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE UndecidableInstances #-}

module PubGrub.Types (
    -- * Packages
    Package (..),

    -- * Incompatibilities
    IncompatCause (..),
    Incompatibility (..),
    notRoot,
    noVersions,
    fromDependency,
    incompGet,
    IncompatRelation (..),
    incompRelation,
    isTerminal,
    priorCause,
) where

import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Text       (Text)
import           PubGrub.Lattice (Boolean, BoundedLattice (..), Sets (..),
                                  isBottom)
import           PubGrub.Term

-- | A package is anything with equality, ordering, and a human-readable name.
class (Eq p, Ord p, Show p) => Package p where
    -- | A provider's identifying key for a package (e.g. @PackageName@). The
    -- solver does not use it.
    type Key p

    -- | Render the package name for conflict reports. Unlike 'show', this is
    -- meant for end users (e.g. @lens@ rather than @Pkg (PackageName "lens")@).
    prettyPackage :: p -> Text

-- | Why an incompatibility exists (drives error reporting).
data IncompatCause p s
    = NotRoot p (Elem s)
    | NoVersions p s
    | FromDependencyOf p s p s
    | DerivedFrom (Incompatibility p s) (Incompatibility p s)

deriving stock instance (Eq p, Eq s, Eq (Elem s)) => Eq (IncompatCause p s)
deriving stock instance (Show p, Show s, Show (Elem s)) => Show (IncompatCause p s)

-- | A set of terms (at most one per package) that can never all hold.
data Incompatibility p s = Incompatibility
    { incompTerms :: Map p (Term s)
    , incompCause :: IncompatCause p s
    }

deriving stock instance (Eq p, Eq s, Eq (Elem s)) => Eq (Incompatibility p s)
deriving stock instance (Show p, Show s, Show (Elem s)) => Show (Incompatibility p s)

-- | The root seed: it is impossible for @root@ to NOT be @version@.
notRoot :: Sets s => p -> Elem s -> Incompatibility p s
notRoot p v =
    Incompatibility
        { incompTerms = Map.singleton p (Negative (singleton v))
        , incompCause = NotRoot p v
        }

-- | No version of the package in this set is available, so none of them can
--   be selected.
noVersions :: Sets s => p -> s -> Incompatibility p s
noVersions p s =
    Incompatibility
        { incompTerms = Map.singleton p (Positive s)
        , incompCause = NoVersions p s
        }

-- | Dependency incompatibility: @package@ in @versions@ requires @dep@ in @depSet@.
--   Encoded as @{ package: Positive versions, dep: Negative depSet }@.
--   If @depSet@ is empty the dependency is unsatisfiable, leaving a unit term.
fromDependency :: (Ord p, Eq s, BoundedLattice s) => p -> s -> (p, s) -> Incompatibility p s
fromDependency package versions (dep, depSet) =
    Incompatibility
        { incompTerms =
            if isBottom depSet
                then Map.singleton package (Positive versions)
                else Map.fromList [(package, Positive versions), (dep, Negative depSet)]
        , incompCause = FromDependencyOf package versions dep depSet
        }

incompGet :: Ord p => p -> Incompatibility p s -> Maybe (Term s)
incompGet p i = Map.lookup p (incompTerms i)

-- | How an incompatibility relates to the partial solution.
data IncompatRelation p
    = ISatisfied
    | IContradicted p
    | -- | all terms satisfied but one (the named package)
      IAlmostSatisfied p
    | IInconclusive
    deriving stock (Eq, Show)

-- | @lookupTerm p@ returns the accumulated term for @p@ in the partial
--   solution, or Nothing if @p@ is absent (treated as the any-term).
incompRelation
    :: (Ord p, Eq s, Boolean s)
    => (p -> Maybe (Term s))
    -> Incompatibility p s
    -> IncompatRelation p
incompRelation lookupTerm i = go ISatisfied (Map.toList (incompTerms i))
  where
    go acc [] = acc
    go acc ((p, it) : rest) =
        case lookupTerm p of
            Just term ->
                case relationWith it term of
                    Satisfied    -> go acc rest
                    Contradicted -> IContradicted p
                    Inconclusive -> almost p acc rest
            Nothing -> almost p acc rest
    -- absent or inconclusive term: at most one allowed for AlmostSatisfied
    almost p ISatisfied rest = go (IAlmostSatisfied p) rest
    almost _ _ _             = IInconclusive

-- | Does this incompatibility end the solve: is it empty, or does it forbid
--   the root version?
isTerminal :: (Ord p, Sets s) => p -> Elem s -> Incompatibility p s -> Bool
isTerminal rootPkg rootV i =
    case Map.toList (incompTerms i) of
        []          -> True
        [(p, term)] -> p == rootPkg && termContains term rootV
        _           -> False

-- | Rule of Resolution. From the current incompatibility and the cause of the
--   satisfier (sharing @package@), derive their resolvent: union the shared
--   term, intersect every other package's terms, drop the shared term if it
--   becomes always-true.
priorCause
    :: (Ord p, Eq s, Boolean s)
    => Incompatibility p s
    -- ^ current incompatibility
    -> Incompatibility p s
    -- ^ satisfier's cause
    -> p
    -- ^ shared (pivot) package
    -> Incompatibility p s
priorCause cur sat package =
    Incompatibility
        { incompTerms = finalTerms
        , incompCause = DerivedFrom cur sat
        }
  where
    curTerms = Map.delete package (incompTerms cur)
    satTerms = Map.delete package (incompTerms sat)
    merged = Map.unionWith intersectTerms curTerms satTerms
    t1 = Map.findWithDefault anyTerm package (incompTerms cur)
    t2 = Map.findWithDefault anyTerm package (incompTerms sat)
    unioned = unionTerms t1 t2
    finalTerms
        | unioned == anyTerm = merged
        | otherwise = Map.insert package unioned merged
