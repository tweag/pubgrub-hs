{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE TypeFamilies      #-}

module PubGrub.Lattice (
    Lattice (..),
    BoundedLattice (..),
    Boolean (..),
    Sets (..),
    subsetOf,
    disjoint,
    intersects,
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

-- | A lattice with least and greatest elements. 'isBottom' and 'isTop'
-- default to comparing with '==', and a type without a usable 'Eq' defines
-- them itself.
class Lattice a => BoundedLattice a where
    bottom :: a
    top :: a

    isBottom :: a -> Bool
    default isBottom :: (Eq a) => a -> Bool
    isBottom = (== bottom)

    isTop :: a -> Bool
    default isTop :: (Eq a) => a -> Bool
    isTop = (== top)

-- | A Boolean algebra: a bounded lattice with a complement 'neg', where
-- @a '\/' neg a == top@, @a '/\' neg a == bottom@ and @neg (neg a) == a@.
class BoundedLattice a => Boolean a where
    neg :: a -> a

-- | Whether the first element is below the second in the lattice order.
subsetOf :: Boolean a => a -> a -> Bool
subsetOf a b = isBottom (a /\ neg b)

-- | Two elements are disjoint iff their meet is 'bottom'.
disjoint :: Boolean a => a -> a -> Bool
disjoint a b = isBottom (a /\ b)

intersects :: Boolean a => a -> a -> Bool
intersects a b = not (disjoint a b)

-- | A Boolean algebra whose values denote sets of @'Elem' a@.
class Boolean a => Sets a where
    type Elem a

    -- | The singleton set containing exactly this element.
    singleton :: Elem a -> a

    -- | Whether the element is in the set that the value denotes.
    member :: Elem a -> a -> Bool

-- The product of two of each structure, taken componentwise. A pair of sets is
-- itself a set whose elements are the disjoint union ('Either') of the two
-- component element types: a left element lives in the first component (the
-- other empty), a right element in the second.

instance (Lattice a, Lattice b) => Lattice (a, b) where
    (a1, b1) \/ (a2, b2) = (a1 \/ a2, b1 \/ b2)
    (a1, b1) /\ (a2, b2) = (a1 /\ a2, b1 /\ b2)

instance (BoundedLattice a, BoundedLattice b) => BoundedLattice (a, b) where
    bottom = (bottom, bottom)
    top = (top, top)

    isTop (a, b) = isTop a && isTop b
    isBottom (a, b) = isBottom a && isBottom b

instance (Boolean a, Boolean b) => Boolean (a, b) where
    neg (a, b) = (neg a, neg b)

instance (Sets a, Sets b) => Sets (a, b) where
    type Elem (a, b) = Either (Elem a) (Elem b)
    singleton (Left x)  = (singleton x, bottom)
    singleton (Right y) = (bottom, singleton y)

    member (Left x) (a, _)  = member x a
    member (Right y) (_, b) = member y b
