{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies       #-}

-- | Terms: statements about the value of one variable, and the Boolean
-- operations on them. 'Term' says what the two kinds of term mean.
module PubGrub.Term
    ( Term (..)
    , negateTerm
    , anyTerm
    , isTopTerm
    , isBottomTerm
      -- * The operations, by name
      -- | The same as the 'SetOps' methods of @'Term' s@, for use where the
      -- class is not wanted.
    , intersectTerm
    , unionTerm
    , differenceTerm
    , isEmptyTerm
    ) where

import           PubGrub.SetOps

-- $setup
-- >>> import qualified Data.Set as Set
-- >>> import Data.Set (Set)
-- >>> import PubGrub.SetOps

-- ---------------------------------------------------------------------------
-- Term
-- ---------------------------------------------------------------------------

-- | A statement about the value of one variable in a solution, given a set
-- @s@ of its values.
--
--   * @Positive s@: the variable has a value, and it is in @s@.
--   * @Negative s@: the variable has no value, or its value is not in @s@.
--
-- A variable a solution leaves out has no value, and only a negative term is
-- true of it. @Negative s@ is exactly the negation of @Positive s@; it is not
-- @Positive@ of the values outside @s@, which would still require a value.
--
-- So a term stands for a set of /states/ of the variable: each of its values,
-- plus one more, /absent/. A positive term is a set of states without absent,
-- a negative term one with it, and every set of states has exactly one term.
-- Absent is what separates the two: every positive term is a subset of
-- @Negative ∅@, the term that is always true, but no negative term is a subset
-- of a positive one.
--
-- >>> Positive (Set.fromList [1,2]) `isSubsetOf` (Negative Set.empty :: Term (Set Int))
-- True
--
-- >>> (Negative Set.empty :: Term (Set Int)) `isSubsetOf` Positive (Set.fromList [1,2])
-- False
data Term a
    = Positive a
    | Negative a
    deriving (Eq, Ord, Show)

-- | Negation: the other polarity over the same set.
negateTerm :: Term a -> Term a
negateTerm (Positive s) = Negative s
negateTerm (Negative s) = Positive s

-- | The states both terms allow.
intersectTerm :: SetOps s => Term s -> Term s -> Term s
intersectTerm (Positive x) (Positive y) = Positive (x `intersect` y)
intersectTerm (Positive x) (Negative y) = Positive (x `difference` y)
intersectTerm (Negative x) (Positive y) = Positive (y `difference` x)
intersectTerm (Negative x) (Negative y) = Negative (x `union` y)

-- | The states either term allows.
unionTerm :: SetOps s => Term s -> Term s -> Term s
unionTerm (Positive x) (Positive y) = Positive (x `union` y)
unionTerm (Positive x) (Negative y) = Negative (y `difference` x)
unionTerm (Negative x) (Positive y) = Negative (x `difference` y)
unionTerm (Negative x) (Negative y) = Negative (x `intersect` y)

-- | The states the first term allows and the second does not.
differenceTerm :: SetOps s => Term s -> Term s -> Term s
differenceTerm x y =
    x `intersectTerm` negateTerm y

-- | Does the term allow no state? Only a positive term over an empty set.
isEmptyTerm :: SetOps s => Term s -> Bool
isEmptyTerm (Positive s) = isEmpty s
isEmptyTerm (Negative _) = False


-- | The Boolean algebra on sets of states. It needs only 'intersect', 'union'
-- and 'difference' of the sets, never a complement: each case follows from
-- whether absent is in or out.
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
-- Subtracting a negative term removes absent, so the result is positive:
--
-- >>> Negative (Set.fromList [1]) `difference` Negative (Set.fromList [0,1,2])
-- Positive (fromList [0,2])
--
-- Only a positive term over the empty set is empty; a negative term always
-- allows absent:
--
-- >>> isEmpty (Negative Set.empty :: Term (Set Int))
-- False
instance SetOps a => SetOps (Term a) where
    empty = Positive empty
    intersect = intersectTerm
    union = unionTerm
    difference = differenceTerm
    isEmpty = isEmptyTerm

    -- The two tests by cases on polarity, so that neither builds a term. Each
    -- case is the default definition evaluated by hand: P x ⊆ N y is
    -- isEmpty (P (x ∩ y)), N x ⊆ N y is isEmpty (P (y \ x)), and a negative
    -- term is never empty, which is why N x ⊆ P y is False and two negative
    -- terms are never disjoint.

    isSubsetOf (Positive x) (Positive y) = x `isSubsetOf` y
    isSubsetOf (Positive x) (Negative y) = x `isDisjoint` y
    isSubsetOf (Negative _) (Positive _) = False
    isSubsetOf (Negative x) (Negative y) = y `isSubsetOf` x

    isDisjoint (Positive x) (Positive y) = x `isDisjoint` y
    isDisjoint (Positive x) (Negative y) = x `isSubsetOf` y
    isDisjoint (Negative x) (Positive y) = y `isSubsetOf` x
    isDisjoint (Negative _) (Negative _) = False

-- | The term that is always true, ⊤: \"absent, or any value\". An
-- incompatibility never holds it, since it says nothing, and a variable an
-- incompatibility does not mention stands for it.
--
-- >>> isTopTerm (anyTerm :: Term (Set Int))
-- True
anyTerm :: SetOps a => Term a
anyTerm = Negative empty

-- | Is this the term that is always true?
--
-- >>> isTopTerm (Negative Set.empty :: Term (Set Int))
-- True
isTopTerm :: SetOps a => Term a -> Bool
isTopTerm (Negative s) = isEmpty s
isTopTerm (Positive _) = False

-- | Is this the term that is never true, ⊥: \"a value, in ∅\"? Only a positive
-- term can be, because a negative term is true of absent. In particular
-- @Negative@ of all of a variable's values, \"the variable has no value\", can
-- be true and is not ⊥.
--
-- >>> isBottomTerm (Positive Set.empty :: Term (Set Int))
-- True
--
-- >>> isBottomTerm (Negative (Set.fromList [1,2]) :: Term (Set Int))
-- False
isBottomTerm :: SetOps a => Term a -> Bool
isBottomTerm (Positive s) = isEmpty s
isBottomTerm (Negative _) = False
