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

import           Data.Ord                           (Down (..), comparing)
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


-- | How high a set reaches: the upper bound of its highest interval.
-- 'Unbounded' is deliberately the /last/ constructor — a set with no upper
-- bound reaches higher than any bounded one. This is why it is not just
-- @Maybe (Version, Bool)@, which would sort unbounded lowest.
data Reach
    = ReachesTo Version Bool  -- ^ bound version, and whether it is inclusive
    | Unbounded
    deriving stock (Eq, Ord, Show)

-- | Where a set starts: the lower bound of its lowest interval, ordered so
-- that @>=1@ sits below @>1@. A /smaller/ 'Start' means a wider set.
data Start = StartsAt Version Bool  -- ^ bound version, and whether it is exclusive
    deriving stock (Eq, Ord, Show)

newtype VersionSet = VersionSet [VersionInterval]
    deriving stock (Eq, Show)

-- | Order by how high the set reaches, then by how wide it is, then by the
-- full interval list — the third coordinate is arbitrary and exists only to
-- keep the order total and consistent with the derived 'Eq' (two distinct sets
-- can share a reach and a start: @[1,2) ∪ [3,4)@ and @[1,4)@).
--
-- The empty set has neither reach nor start; @Nothing@ sorts below every
-- @Just@, so it is the minimum.
instance Ord VersionSet where
    compare = comparing sortKey
      where
        sortKey vs =
            ( reachOf vs
            , Down (startOf vs)               -- wider (lower start) ranks higher
            , map shapeKey (intervals vs)
            )

        reachOf vs = case reverse (intervals vs) of
            VersionInterval _ ub : _ -> Just (upperKey ub)
            []                       -> Nothing

        startOf vs = case intervals vs of
            VersionInterval lb _ : _ -> Just (lowerKey lb)
            []                       -> Nothing

        upperKey NoUpperBound     = Unbounded
        upperKey (UpperBound v b) = ReachesTo v (b == InclusiveBound)
        lowerKey (LowerBound v b) = StartsAt v (b == ExclusiveBound)

        shapeKey (VersionInterval lb ub) = (lowerKey lb, upperKey ub)

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
