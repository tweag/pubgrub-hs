{-# LANGUAGE DerivingStrategies #-}

module PubGrub.Types
  ( -- * Packages
    Package
    -- * Terms
  , Term (..)
  , anyTerm
  , emptyTerm
  , exactTerm
  , isPositive
  , negateTerm
  , termContains
  , intersectTerms
  , unionTerms
  , termSubsetOf
  , termIsDisjoint
  , termIsEmpty
    -- * Term relation
  , TermRelation (..)
  , relationWith
    -- * Incompatibilities
  , IncompatCause (..)
  , Incompatibility (..)
  , notRoot
  , noVersions
  , fromDependency
  , incompGet
  , IncompatRelation (..)
  , incompRelation
  , isTerminal
  , priorCause
  ) where

import           Data.Map.Strict      (Map)
import qualified Data.Map.Strict      as Map
import           Distribution.Version (Version)
import           PubGrub.VersionSet   (VersionSet)
import qualified PubGrub.VersionSet   as VS

-- | A package is anything with equality, ordering, and a printable name.
class (Eq p, Ord p, Show p) => Package p

-- | A positive or negative assertion about a package's selected version.
data Term
  = Positive VersionSet  -- ^ a version in this set is selected
  | Negative VersionSet  -- ^ no version selected, or one outside this set
  deriving stock (Eq, Show)

-- | The always-true term (@Negative empty@): any version, or none, satisfies it.
anyTerm :: Term
anyTerm = Negative VS.empty

-- | Never-true term (Positive empty): no version can satisfy it.
emptyTerm :: Term
emptyTerm = Positive VS.empty

-- | Positive singleton term for a concrete version.
exactTerm :: Version -> Term
exactTerm = Positive . VS.singleton

isPositive :: Term -> Bool
isPositive (Positive _) = True
isPositive (Negative _) = False

negateTerm :: Term -> Term
negateTerm (Positive s) = Negative s
negateTerm (Negative s) = Positive s

-- | Does a concrete chosen version satisfy this term?
termContains :: Term -> Version -> Bool
termContains (Positive s) v = VS.contains s v
termContains (Negative s) v = not (VS.contains s v)

-- | Logical AND of two terms (over the same package).
intersectTerms :: Term -> Term -> Term
intersectTerms (Positive r1) (Positive r2) = Positive (VS.intersection r1 r2)
intersectTerms (Positive p)  (Negative n)  = Positive (VS.intersection (VS.complement n) p)
intersectTerms (Negative n)  (Positive p)  = Positive (VS.intersection (VS.complement n) p)
intersectTerms (Negative r1) (Negative r2) = Negative (VS.union r1 r2)

-- | Logical OR of two terms (over the same package).
unionTerms :: Term -> Term -> Term
unionTerms (Positive r1) (Positive r2) = Positive (VS.union r1 r2)
unionTerms (Positive p)  (Negative n)  = Negative (VS.intersection (VS.complement p) n)
unionTerms (Negative n)  (Positive p)  = Negative (VS.intersection (VS.complement p) n)
unionTerms (Negative r1) (Negative r2) = Negative (VS.intersection r1 r2)

-- | @t1 `termSubsetOf` t2@ iff t1 ∩ t2 = t1.
termSubsetOf :: Term -> Term -> Bool
termSubsetOf (Positive r1) (Positive r2) = VS.subsetOf r1 r2
termSubsetOf (Positive r1) (Negative r2) = VS.isDisjoint r1 r2
termSubsetOf (Negative _)  (Positive _)  = False
termSubsetOf (Negative r1) (Negative r2) = VS.subsetOf r2 r1

-- | Are two terms mutually exclusive (intersection is the empty term)?
termIsDisjoint :: Term -> Term -> Bool
termIsDisjoint (Positive r1) (Positive r2) = VS.isDisjoint r1 r2
termIsDisjoint (Negative _)  (Negative _)  = False
termIsDisjoint (Positive p)  (Negative n)  = VS.subsetOf p n
termIsDisjoint (Negative n)  (Positive p)  = VS.subsetOf p n

-- | Is this term's version set empty (@Positive empty@ or @Negative full@)?
termIsEmpty :: Term -> Bool
termIsEmpty (Positive s) = VS.isEmpty s
termIsEmpty (Negative s) = VS.isFull s

-- | Relation of a term to an accumulated set of terms (their intersection).
data TermRelation = Satisfied | Contradicted | Inconclusive
  deriving stock (Eq, Show)

-- | @relationWith t acc@: how the accumulated term @acc@ relates to @t@.
--   Satisfied iff acc ⊆ t; Contradicted iff acc ∩ t = ∅; else Inconclusive.
relationWith :: Term -> Term -> TermRelation
relationWith t acc
  | acc `termSubsetOf` t = Satisfied
  | termIsDisjoint t acc = Contradicted
  | otherwise            = Inconclusive

-- | Why an incompatibility exists (drives error reporting).
data IncompatCause p
  = NotRoot p Version
  | NoVersions p VersionSet
  | FromDependencyOf p VersionSet p VersionSet
  | DerivedFrom (Incompatibility p) (Incompatibility p)
  deriving stock (Eq, Show)

-- | A set of terms (at most one per package) that can never all hold.
data Incompatibility p = Incompatibility
  { incompTerms :: Map p Term
  , incompCause :: IncompatCause p
  }
  deriving stock (Eq, Show)

-- | The root seed: it is impossible for @root@ to NOT be @version@.
notRoot :: p -> Version -> Incompatibility p
notRoot p v = Incompatibility
  { incompTerms = Map.singleton p (Negative (VS.singleton v))
  , incompCause = NotRoot p v
  }

-- | No version of the package in this set is available, so none of them can
--   be selected.
noVersions :: p -> VersionSet -> Incompatibility p
noVersions p s = Incompatibility
  { incompTerms = Map.singleton p (Positive s)
  , incompCause = NoVersions p s
  }

-- | Dependency incompatibility: @package@ in @versions@ requires @dep@ in @depSet@.
--   Encoded as @{ package: Positive versions, dep: Negative depSet }@.
--   If @depSet@ is empty the dependency is unsatisfiable, leaving a unit term.
fromDependency :: Ord p => p -> VersionSet -> (p, VersionSet) -> Incompatibility p
fromDependency package versions (dep, depSet) = Incompatibility
  { incompTerms =
      if VS.isEmpty depSet
        then Map.singleton package (Positive versions)
        else Map.fromList [(package, Positive versions), (dep, Negative depSet)]
  , incompCause = FromDependencyOf package versions dep depSet
  }

incompGet :: Ord p => p -> Incompatibility p -> Maybe Term
incompGet p i = Map.lookup p (incompTerms i)

-- | How an incompatibility relates to the partial solution.
data IncompatRelation p
  = ISatisfied
  | IContradicted p
  | IAlmostSatisfied p   -- ^ all terms satisfied but one (the named package)
  | IInconclusive
  deriving stock (Eq, Show)

-- | @lookupTerm p@ returns the accumulated term for @p@ in the partial
--   solution, or Nothing if @p@ is absent (treated as the any-term).
incompRelation :: Ord p => (p -> Maybe Term) -> Incompatibility p -> IncompatRelation p
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
isTerminal :: Ord p => p -> Version -> Incompatibility p -> Bool
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
  :: Ord p
  => Incompatibility p   -- ^ current incompatibility
  -> Incompatibility p   -- ^ satisfier's cause
  -> p                   -- ^ shared (pivot) package
  -> Incompatibility p
priorCause cur sat package = Incompatibility
  { incompTerms = finalTerms
  , incompCause = DerivedFrom cur sat
  }
  where
    curTerms = Map.delete package (incompTerms cur)
    satTerms = Map.delete package (incompTerms sat)
    merged   = Map.unionWith intersectTerms curTerms satTerms
    t1 = Map.findWithDefault anyTerm package (incompTerms cur)
    t2 = Map.findWithDefault anyTerm package (incompTerms sat)
    unioned = unionTerms t1 t2
    finalTerms
      | unioned == anyTerm = merged
      | otherwise          = Map.insert package unioned merged
