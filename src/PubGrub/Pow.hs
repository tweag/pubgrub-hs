{-# LANGUAGE TypeFamilies #-}

-- | The Boolean algebra of subsets of an /infinite/, unordered domain,
-- represented so that complement needs no enumeration of the universe.
--
-- A subset is stored as either a finite set of included elements ('Incl') or
-- the complement of a finite set ('Excl', a /cofinite/ set). Complement is then
-- just swapping the constructor, with no universe required — which is what makes
-- this usable inside the solver's term arithmetic (see "PubGrub.Lattice"). This
-- is the set type for the installed world, keyed by @UnitId@: the source world
-- uses ordered intervals ('PubGrub.VersionSet.VersionSet') instead.
--
-- The domain is treated as infinite, so the two constructors never denote the
-- same set: 'Incl' is always finite and 'Excl' always cofinite. That keeps the
-- derived 'Eq' canonical (@bottom@ is uniquely @Incl mempty@, @top@ uniquely
-- @Excl mempty@) and is why finite-domain membership can't witness emptiness.
module PubGrub.Pow (Pow (..)) where

import           Data.Set        (Set)
import qualified Data.Set        as Set
import           PubGrub.Lattice (Boolean (neg), BoundedLattice (..),
                                  Lattice (..), Sets (..))

-- | A subset of an infinite domain: the listed elements ('Incl'), or every
-- element /except/ the listed ones ('Excl').
data Pow a = Incl (Set a) | Excl (Set a)
    deriving (Eq, Show)

-- | Set union ('\/') and intersection ('/\'). Each mixed case is the
-- corresponding De Morgan identity (writing @¬s@ for @Excl s@):
--
-- > a ∪ ¬b = ¬(b \ a)      ¬a ∩ b = b \ a
-- > ¬a ∪ ¬b = ¬(a ∩ b)     ¬a ∩ ¬b = ¬(a ∪ b)
instance Ord a => Lattice (Pow a) where
    Incl a \/ Incl b = Incl (Set.union a b) -- a ∪ b
    Incl a \/ Excl b = Excl (Set.difference b a) -- a ∪ ¬b = ¬(b \ a)
    Excl a \/ Incl b = Excl (Set.difference a b) -- ¬a ∪ b = ¬(a \ b)
    Excl a \/ Excl b = Excl (Set.intersection a b) -- ¬a ∪ ¬b = ¬(a ∩ b)
    Incl a /\ Incl b = Incl (Set.intersection a b) -- a ∩ b
    Incl a /\ Excl b = Incl (Set.difference a b) -- a ∩ ¬b = a \ b
    Excl a /\ Incl b = Incl (Set.difference b a) -- ¬a ∩ b = b \ a
    Excl a /\ Excl b = Excl (Set.union a b) -- ¬a ∩ ¬b = ¬(a ∪ b)

-- | @bottom@ (the empty set) is @Incl mempty@; @top@ (the whole domain) is its
-- complement @Excl mempty@.
instance Ord a => BoundedLattice (Pow a) where
    bottom = Incl Set.empty
    top = Excl Set.empty

-- | Complement: swap the constructor (no universe needed).
instance Ord a => Boolean (Pow a) where
    neg (Incl s) = Excl s
    neg (Excl s) = Incl s

-- | Elements are the domain values; @member x (Excl s)@ is membership in the
-- complement.
instance Ord a => Sets (Pow a) where
    type Elem (Pow a) = a
    singleton = Incl . Set.singleton
    member x (Incl s) = Set.member x s
    member x (Excl s) = not (Set.member x s)
