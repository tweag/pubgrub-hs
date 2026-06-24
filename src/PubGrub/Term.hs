{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies       #-}

-- | Terms: constraints on the single element a package may have selected, and
-- the Boolean operations on them. 'Term' gives the meaning of the two
-- constructors.
module PubGrub.Term (
    -- * Terms
    Term (..),
    anyTerm,
    emptyTerm,
    exactTerm,
    isPositive,
    negateTerm,
    termContains,
    intersectTerms,
    unionTerms,
    termSubsetOf,
    termIsDisjoint,
    termIsEmpty,

    -- * Term relation
    TermRelation (..),
    relationWith,
) where

import           PubGrub.Lattice (Boolean (..), BoundedLattice (..),
                                  Lattice (..), Sets (..), disjoint, isBottom,
                                  isTop, subsetOf)

-- | A constraint on the /single/ element a package may have selected. A package
-- is assigned at most one element (e.g. one version), so a 'Term' is a predicate
-- on that optional choice — not a set of simultaneously-allowed elements.
-- 'Negative' is the logical negation of 'Positive', not a set complement:
--
--   * @Positive s@ — the package is assigned and its element is in @s@.
--   * @Negative s@ — @not (Positive s)@: the assigned element is /not/ in @s@,
--     /or/ the package has no assignment yet.
--
-- So @Negative (singleton 3)@ reads \"3 is not the selected element\" (which also
-- holds when nothing is selected) — /not/ \"every element except 3 is selected\".
data Term s
    = Positive s
    | Negative s
    deriving (Eq, Show)

-- | The always-true term, @not (Positive bottom)@: imposes no constraint (an
-- unassigned package trivially satisfies it).
anyTerm :: BoundedLattice s => Term s
anyTerm = Negative bottom

-- | The never-true term, @Positive bottom@: demands an element from the empty
-- set, so nothing can satisfy it.
emptyTerm :: BoundedLattice s => Term s
emptyTerm = Positive bottom

-- | Positive singleton term for a concrete element.
exactTerm :: Sets s => Elem s -> Term s
exactTerm = Positive . singleton

isPositive :: Term s -> Bool
isPositive (Positive _) = True
isPositive (Negative _) = False

negateTerm :: Term s -> Term s
negateTerm (Positive s) = Negative s
negateTerm (Negative s) = Positive s

-- | Does a concrete chosen element satisfy this term?
termContains :: Sets s => Term s -> Elem s -> Bool
termContains (Positive s) v = member v s
termContains (Negative s) v = not (member v s)

-- | Logical AND of two terms (over the same package).
intersectTerms :: Boolean s => Term s -> Term s -> Term s
intersectTerms (Positive r1) (Positive r2) = Positive (r1 /\ r2)
intersectTerms (Positive p) (Negative n)   = Positive (p /\ neg n)
intersectTerms (Negative n) (Positive p)   = Positive (p /\ neg n)
intersectTerms (Negative r1) (Negative r2) = Negative (r1 \/ r2)

-- | Logical OR of two terms (over the same package).
unionTerms :: Boolean s => Term s -> Term s -> Term s
unionTerms (Positive r1) (Positive r2) = Positive (r1 \/ r2)
unionTerms (Positive p) (Negative n)   = Negative (neg p /\ n)
unionTerms (Negative n) (Positive p)   = Negative (neg p /\ n)
unionTerms (Negative r1) (Negative r2) = Negative (r1 /\ r2)

-- | @t1 `termSubsetOf` t2@ iff t1 ∩ t2 = t1.
termSubsetOf :: (Boolean s, Eq s) => Term s -> Term s -> Bool
termSubsetOf (Positive r1) (Positive r2) = subsetOf r1 r2
termSubsetOf (Positive r1) (Negative r2) = disjoint r1 r2
termSubsetOf (Negative _) (Positive _)   = False
termSubsetOf (Negative r1) (Negative r2) = subsetOf r2 r1

-- | Are two terms mutually exclusive (intersection is the empty term)?
termIsDisjoint :: (Boolean s, Eq s) => Term s -> Term s -> Bool
termIsDisjoint (Positive r1) (Positive r2) = disjoint r1 r2
termIsDisjoint (Negative _) (Negative _)   = False
termIsDisjoint (Positive p) (Negative n)   = subsetOf p n
termIsDisjoint (Negative n) (Positive p)   = subsetOf p n

-- | Is this the never-true term?
termIsEmpty :: (Eq s, BoundedLattice s) => Term s -> Bool
termIsEmpty (Positive s) = isTop s
termIsEmpty (Negative s) = isBottom s

-- | Relation of a term to an accumulated set of terms (their intersection).
data TermRelation = Satisfied | Contradicted | Inconclusive
    deriving stock (Eq, Show)

-- | @relationWith t acc@: how the accumulated term @acc@ relates to @t@.
--   Satisfied iff acc ⊆ t; Contradicted iff acc ∩ t = ∅; else Inconclusive.
relationWith :: (Boolean s, Eq s) => Term s -> Term s -> TermRelation
relationWith t acc
    | acc `termSubsetOf` t = Satisfied
    | termIsDisjoint t acc = Contradicted
    | otherwise = Inconclusive
