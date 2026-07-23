{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies       #-}

-- | A version set: a canonical, sorted, disjoint, non-adjacent collection of
-- version intervals. Backed by Cabal's 'VersionInterval' so that derived
-- structural equality coincides with semantic equality.
module PubGrub.VersionSet (
    -- The constructor is hidden so that every 'VersionSet' stays canonical.
    VersionSet,
    emptyVersionSet,
    fullVersionSet,
    singletonVersionSet,
    fromVersionRange,
    toVersionRange,
    complementVersionSet,
    unionVersionSet,
    intersectionVersionSet,
    contains,
    intervals,
) where

import           Data.Ord                           (comparing)
import           Distribution.Types.VersionInterval (Bound (..),
                                                     LowerBound (..),
                                                     UpperBound (..),
                                                     VersionInterval (..),
                                                     asVersionIntervals,
                                                     fromVersionIntervals,
                                                     mkVersionIntervals)
import           Distribution.Version               (Version, VersionRange,
                                                     anyVersion, earlierVersion,
                                                     intersectVersionRanges,
                                                     laterVersion, noVersion,
                                                     orEarlierVersion,
                                                     orLaterVersion,
                                                     thisVersion,
                                                     unionVersionRanges)
import           PubGrub.SetOps                     (SetOps (..))

newtype VersionSet = VersionSet [VersionInterval]
    deriving stock (Eq, Show)

-- | Cabal's 'VersionInterval' has no 'Ord', so order by the canonical
-- interval list mapped onto orderable keys. The particular order is
-- arbitrary; it only has to be total, lawful, and consistent with 'Eq'
-- (it is: the representation is canonical and the key is injective).
instance Ord VersionSet where
    compare = comparing (map key . intervals)
      where
        key (VersionInterval (LowerBound lv lb) ub) =
            (lv, lb == InclusiveBound, upperKey ub)
        upperKey NoUpperBound       = Nothing
        upperKey (UpperBound uv ub) = Just (uv, ub == InclusiveBound)

-- | The raw canonical interval list (for testing / reporting).
intervals :: VersionSet -> [VersionInterval]
intervals (VersionSet is) = is

-- | Build a canonical 'VersionSet' from any 'VersionRange'.
fromVersionRange :: VersionRange -> VersionSet
fromVersionRange = VersionSet . asVersionIntervals

-- | Convert back to a 'VersionRange' (used to delegate set arithmetic to Cabal),
-- via Cabal's own canonical 'VersionIntervals' round-trip. Our interval list is
-- always canonical (it comes from 'asVersionIntervals'), so 'mkVersionIntervals'
-- always succeeds; the 'noVersion' fallback is unreachable.
toVersionRange :: VersionSet -> VersionRange
toVersionRange (VersionSet is) =
    maybe noVersion fromVersionIntervals (mkVersionIntervals is)

emptyVersionSet :: VersionSet
emptyVersionSet = VersionSet []

fullVersionSet :: VersionSet
fullVersionSet = fromVersionRange anyVersion

-- | The set containing exactly one version.
singletonVersionSet :: Version -> VersionSet
singletonVersionSet = fromVersionRange . thisVersion

unionVersionSet :: VersionSet -> VersionSet -> VersionSet
unionVersionSet a b = fromVersionRange (unionVersionRanges (toVersionRange a) (toVersionRange b))

intersectionVersionSet :: VersionSet -> VersionSet -> VersionSet
intersectionVersionSet a b = fromVersionRange (intersectVersionRanges (toVersionRange a) (toVersionRange b))

-- | The versions not in the set.
complementVersionSet :: VersionSet -> VersionSet
complementVersionSet (VersionSet is) =
    fromVersionRange (foldr (intersectVersionRanges . complementInterval) anyVersion is)
  where
    complementInterval (VersionInterval lo hi) =
        unionVersionRanges (belowLower lo) (aboveUpper hi)
    belowLower (LowerBound v InclusiveBound) = earlierVersion v -- < v
    belowLower (LowerBound v ExclusiveBound) = orEarlierVersion v -- <= v
    aboveUpper NoUpperBound                  = noVersion -- nothing above
    aboveUpper (UpperBound v InclusiveBound) = laterVersion v -- > v
    aboveUpper (UpperBound v ExclusiveBound) = orLaterVersion v -- >= v

-- | The class asks for no complement, because not every payload has one.
-- Version ranges do, so 'difference' is computed through it here.
instance SetOps VersionSet where
    intersect = intersectionVersionSet
    union = unionVersionSet
    difference a b = intersectionVersionSet a (complementVersionSet b)
    isEmpty = null . intervals

contains :: VersionSet -> Version -> Bool
contains (VersionSet is) v = any inside is
  where
    inside (VersionInterval lo hi) = lowerOk lo && upperOk hi
    lowerOk (LowerBound w InclusiveBound) = v >= w
    lowerOk (LowerBound w ExclusiveBound) = v > w
    upperOk NoUpperBound                  = True
    upperOk (UpperBound w InclusiveBound) = v <= w
    upperOk (UpperBound w ExclusiveBound) = v < w
