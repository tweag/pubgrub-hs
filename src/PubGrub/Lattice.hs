{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE TypeFamilies    #-}

module PubGrub.Lattice (
    Lattice (..),
    joinLeq,
    meetLeq,
    BoundedLattice (..),
    Boolean (..),
    Sets (..),
    isBottom,
    isTop,
    subsetOf,
    disjoint,
) where

infixr 6 /\ -- This comment needed because of CPP
infixr 5 \/

-- | An algebraic structure with joins and meets. Instances satisfy these
-- laws.
--
-- See <http://en.wikipedia.org/wiki/Lattice_(order)> and <http://en.wikipedia.org/wiki/Absorption_law>.
--
-- /Associativity/
--
-- @
-- x '\/' (y '\/' z) ≡ (x '\/' y) '\/' z
-- x '/\' (y '/\' z) ≡ (x '/\' y) '/\' z
-- @
--
-- /Commutativity/
--
-- @
-- x '\/' y ≡ y '\/' x
-- x '/\' y ≡ y '/\' x
-- @
--
-- /Idempotency/
--
-- @
-- x '\/' x ≡ x
-- x '/\' x ≡ x
-- @
--
-- /Absorption/
--
-- @
-- a '\/' (a '/\' b) ≡ a
-- a '/\' (a '\/' b) ≡ a
-- @
class Lattice a where
    -- | Join: the least upper bound.
    (\/) :: a -> a -> a

    -- | Meet: the greatest lower bound.
    (/\) :: a -> a -> a

-- | The partial ordering induced by the join-semilattice structure
joinLeq :: (Eq a, Lattice a) => a -> a -> Bool
joinLeq x y = (x \/ y) == y

meetLeq :: (Eq a, Lattice a) => a -> a -> Bool
meetLeq x y = (x /\ y) == x

-- | A bounded lattice: least ('bottom') and greatest ('top') elements.
class Lattice a => BoundedLattice a where
    bottom :: a
    top :: a

isBottom :: (Eq a, BoundedLattice a) => a -> Bool
isBottom = (== bottom)

isTop :: (Eq a, BoundedLattice a) => a -> Bool
isTop = (== top)

-- | A Boolean algebra: a bounded lattice with a complement 'neg', where
-- @a '\/' neg a == top@, @a '/\' neg a == bottom@ and @neg (neg a) == a@.
-- Implication is derivable as @neg a '\/' b@, so it is not a method.
class BoundedLattice a => Boolean a where
    neg :: a -> a

-- | Whether the first element is below the second in the lattice order.
subsetOf :: (Eq a, Boolean a) => a -> a -> Bool
subsetOf a b = isBottom (a /\ neg b)

-- | Two elements are disjoint iff their meet is 'bottom'.
disjoint :: (Eq a, Boolean a) => a -> a -> Bool
disjoint a b = isBottom (a /\ b)

-- | A Boolean algebra of sets over an element type, with membership kept
-- apart from the lattice structure.
class Boolean a => Sets a where
    type Elem a
    singleton :: Elem a -> a
    member :: Elem a -> a -> Bool
