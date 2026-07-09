{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies       #-}

-- | Terms: propositions about the single instance a package may have
-- selected, and the Boolean operations on them. See 'Term' for the meaning of
-- the two constructors, and 'SetOps' for the payload algebra the operations
-- are built from.
module PubGrub.Term where

import           Data.Set (Set)
import qualified Data.Set as Set

-- ---------------------------------------------------------------------------
-- SetOps
-- ---------------------------------------------------------------------------

-- | The operations the solver needs from a set of values: intersection,
-- union, difference and an emptiness test. This is a /ring of sets/, not a
-- Boolean algebra.
--
-- There is deliberately no @complement@, which would need a universe of
-- values. The only negation the solver needs is in 'Term', where it is a
-- polarity flip that costs nothing: the one-point extension turns this ring
-- into a Boolean algebra.
class SetOps a where
    intersect   :: a -> a -> a
    union       :: a -> a -> a
    difference  :: a -> a -> a
    isEmpty     :: a -> Bool

-- | @a ⊆ b@ iff removing @b@ from @a@ leaves nothing.
--
-- >>> Set.fromList [3,4] `isSubsetOf` Set.fromList [1..9]
-- True
--
-- >>> Set.fromList [1..9] `isSubsetOf` Set.fromList [3,4]
-- False
isSubsetOf :: SetOps a => a -> a -> Bool
isSubsetOf a b = isEmpty (a `difference` b)

-- | @a ∩ b = ∅@.
--
-- >>> Set.fromList [1,2] `isDisjoint` Set.fromList [3,4]
-- True
--
-- >>> Set.fromList [1,2,3] `isDisjoint` Set.fromList [3,4]
-- False
isDisjoint :: SetOps a => a -> a -> Bool
isDisjoint xs ys = isEmpty (xs `intersect` ys)

equivalent :: SetOps s => s -> s -> Bool
equivalent x y = x `isSubsetOf` y && y `isSubsetOf` x

instance Ord a => SetOps (Set a) where
    intersect = Set.intersection
    union = Set.union
    difference = Set.difference
    isEmpty = Set.null

-- ---------------------------------------------------------------------------
-- Term
-- ---------------------------------------------------------------------------

-- | A term is a proposition about one package, judged against a (possibly
-- partial) solution.
--
-- * @Positive s@ — the package is selected, as an instance in @s@.
-- * @Negative s@ — the package is not selected, or its instance lies outside @s@.
--
-- The solver instantiates @a@ at 'PubGrub.InstanceSet.InstanceSet', and the
-- doctests use small @'Set' Int@ payloads. Nothing below depends on which.
--
-- @Negative s@ is exactly the negation of @Positive s@, so it is satisfied
-- when the package is absent from the solution. It is /not/ the same as
-- @Positive (complement s)@, which would still require the package to be
-- selected.
--
-- A term carries no uncertainty: "not yet determined" is
-- 'PubGrub.Relation.relation' returning 'PubGrub.Relation.Inconclusive' when
-- a term is judged against the partial solution.
--
-- The /absent/ state separates the polarities: a positive term is always a
-- subset of ⊤ = @Negative ∅@ ("anything, or absent"), but ⊤ is never a subset
-- of a positive term, because absence escapes it:
--
-- >>> Positive (Set.fromList [1,2]) `isSubsetOf` (Negative Set.empty :: Term (Set Int))
-- True
--
-- >>> (Negative Set.empty :: Term (Set Int)) `isSubsetOf` Positive (Set.fromList [1,2])
-- False
--
-- Semantically, @Term a@ is the powerset algebra over the payload's value
-- domain /extended by one point/, the absent state. Positives are exactly the
-- subsets that exclude it and negatives exactly those that include it, so
-- every subset of states is representable, exactly once.
data Term a
    = Positive a
    | Negative a
    deriving (Eq, Ord, Show)

-- | Negation is a polarity flip — the payload is untouched. This is where the
-- complement 'SetOps' deliberately lacks comes from.
negateTerm :: Term a -> Term a
negateTerm (Positive s) = Negative s
negateTerm (Negative s) = Positive s

intersectTerm :: SetOps s => Term s -> Term s -> Term s
intersectTerm (Positive x) (Positive y) = Positive (x `intersect` y)
intersectTerm (Positive x) (Negative y) = Positive (x `difference` y)
intersectTerm (Negative x) (Positive y) = Positive (y `difference` x)
intersectTerm (Negative x) (Negative y) = Negative (x `union` y)

unionTerm :: SetOps s => Term s -> Term s -> Term s
unionTerm (Positive x) (Positive y) = Positive (x `union` y)
unionTerm (Positive x) (Negative y) = Negative (y `difference` x)
unionTerm (Negative x) (Positive y) = Negative (x `difference` y)
unionTerm (Negative x) (Negative y) = Negative (x `intersect` y)

differenceTerm :: SetOps s => Term s -> Term s -> Term s
differenceTerm x y =
    x `intersectTerm` negateTerm y

isEmptyTerm :: SetOps s => Term s -> Bool
isEmptyTerm (Positive s) = isEmpty s
isEmptyTerm (Negative _) = False

-- The term can never be true.
termIsImpossible :: SetOps s => Term s -> Bool
termIsImpossible (Positive s) = isEmpty s
termIsImpossible (Negative _) = False

-- The term is always true.
termIsUniversal :: SetOps s => Term s -> Bool
termIsUniversal (Positive _) = False
termIsUniversal (Negative s) = isEmpty s


-- | The Boolean algebra on terms, through the state-set denotations above.
-- The payload only ever needs 'intersect', 'union' and 'difference' — never a
-- complement: each right-hand side is forced by De Morgan once you track
-- whether the absent state is in or out.
--
-- >>> Positive (Set.fromList [2,3,4]) `intersect` Negative (Set.fromList [4,5])
-- Positive (fromList [2,3])
--
-- >>> Negative (Set.fromList [2]) `intersect` Negative (Set.fromList [4])
-- Negative (fromList [2,4])
--
-- A union of prohibitions only forbids what both prohibit:
--
-- >>> Negative (Set.fromList [5,6]) `union` Negative (Set.fromList [6,7])
-- Negative (fromList [6])
--
-- Subtracting a negative term removes the /absent/ state, so the result is positive:
--
-- >>> Negative (Set.fromList [1]) `difference` Negative (Set.fromList [0,1,2])
-- Positive (fromList [0,2])
--
-- Only a positive term over the empty payload is empty; a negative term always
-- admits the absent state:
--
-- >>> isEmpty (Negative Set.empty :: Term (Set Int))
-- False
instance SetOps a => SetOps (Term a) where
    intersect = intersectTerm
    union = unionTerm
    difference = differenceTerm
    isEmpty = isEmptyTerm

-- | The always-true term: "absent, or any value". This is the ⊤ an
-- 'PubGrub.Incompatibility.Incompatibility' never stores — such an entry says
-- nothing, so it is dropped from the map instead.
--
-- >>> isTopTerm (Negative Set.empty :: Term (Set Int))
-- True
isTopTerm :: SetOps a => Term a -> Bool
isTopTerm (Negative s) = isEmpty s
isTopTerm (Positive _) = False

-- | The never-true term: "selected, with a value in ∅". Note the bottom is
-- /positive/: it is the only unsatisfiable shape, because a negative term is
-- always satisfied by absence. In particular @Negative ⟨universe⟩@ ("the
-- package is absent") is satisfiable and NOT a bottom — mistaking it for one
-- would turn conflicts into "just don't pick this package":
--
-- >>> isBottomTerm (Positive Set.empty :: Term (Set Int))
-- True
--
-- >>> isBottomTerm (Negative (Set.fromList [1,2]) :: Term (Set Int))
-- False
isBottomTerm :: SetOps a => Term a -> Bool
isBottomTerm (Positive s) = isEmpty s
isBottomTerm (Negative _) = False
