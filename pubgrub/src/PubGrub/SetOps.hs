module PubGrub.SetOps where


import           Data.Set (Set)
import qualified Data.Set as Set

-- ---------------------------------------------------------------------------
-- SetOps
-- ---------------------------------------------------------------------------

-- | The operations the solver needs from a set of values: the empty set, closure
-- under intersection, union and difference, and an emptiness test — a /ring of
-- sets/, not a Boolean algebra.
--
-- Deliberately absent: @complement@. A complement needs a universe of values,
-- and nothing here wants one: the only place negation is needed is
-- 'PubGrub.Term.Term', where it is a polarity flip that costs nothing. Pairing
-- a set with a polarity turns this ring into a Boolean algebra. (A domain may
-- well know its universe, but the algebra never has to ask for it.)
class SetOps a where
    empty       :: a
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
    empty = Set.empty
    intersect = Set.intersection
    union = Set.union
    difference = Set.difference
    isEmpty = Set.null
