-- | Sets of values: what a term ranges over.
--
-- A domain's set type ('PubGrub.Incompatibility.SetOf') is an instance of
-- 'SetOps'. 'Set' is one, for values that can be listed, and
-- "PubGrub.VersionSet" is one for ranges of versions.
module PubGrub.SetOps
    ( SetOps (..)
    , equivalent
    ) where

import           Data.Set (Set)
import qualified Data.Set as Set

-- $setup
-- >>> import qualified Data.Set as Set

-- ---------------------------------------------------------------------------
-- SetOps
-- ---------------------------------------------------------------------------

-- | The operations the solver needs from a set of values: the empty set,
-- intersection, union, difference and an emptiness test. Each must mean what
-- it says of the values a set holds.
--
-- There is no complement, so a set type needs no universe of all values. The
-- solver negates terms, not sets: 'PubGrub.Term.Negative' is the negation of
-- 'PubGrub.Term.Positive' over the same set.
--
-- 'isSubsetOf' and 'isDisjoint' have defaults in terms of the other methods.
-- An instance may override them to answer without building a set, and must
-- then answer exactly as the defaults would.
class SetOps a where
    -- | The set with no values.
    empty       :: a
    -- | The values in both sets.
    intersect   :: a -> a -> a
    -- | The values in either set.
    union       :: a -> a -> a
    -- | The values in the first set and not in the second.
    difference  :: a -> a -> a
    -- | Does the set hold no value?
    isEmpty     :: a -> Bool

    -- The two tests are methods because the solver asks them of every term it
    -- judges. Building the difference or the intersection first, as the
    -- defaults do, measured at a fifth of a large solve's time and two fifths
    -- of its allocation.

    -- | @a ⊆ b@: removing @b@ from @a@ leaves nothing.
    --
    -- >>> Set.fromList [3,4] `isSubsetOf` Set.fromList [1..9]
    -- True
    --
    -- >>> Set.fromList [1..9] `isSubsetOf` Set.fromList [3,4]
    -- False
    isSubsetOf :: a -> a -> Bool
    isSubsetOf a b = isEmpty (a `difference` b)

    -- | @a ∩ b = ∅@: no value is in both.
    --
    -- >>> Set.fromList [1,2] `isDisjoint` Set.fromList [3,4]
    -- True
    --
    -- >>> Set.fromList [1,2,3] `isDisjoint` Set.fromList [3,4]
    -- False
    isDisjoint :: a -> a -> Bool
    isDisjoint xs ys = isEmpty (xs `intersect` ys)

-- | Do two sets hold the same values? Two subset tests, so it needs neither
-- 'Eq' nor a canonical form.
--
-- >>> equivalent (Set.fromList [1,2]) (Set.fromList [2,1])
-- True
equivalent :: SetOps s => s -> s -> Bool
equivalent x y = x `isSubsetOf` y && y `isSubsetOf` x

-- | Sets whose values can be listed.
instance Ord a => SetOps (Set a) where
    empty = Set.empty
    intersect = Set.intersection
    union = Set.union
    difference = Set.difference
    isEmpty = Set.null
    isSubsetOf = Set.isSubsetOf
    isDisjoint = Set.disjoint
