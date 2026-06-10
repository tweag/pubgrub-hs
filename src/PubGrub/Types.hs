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
  ) where

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
