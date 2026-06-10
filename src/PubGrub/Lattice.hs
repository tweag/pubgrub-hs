module PubGrub.Lattice where


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
