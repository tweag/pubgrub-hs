{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies       #-}

-- | A version set: a canonical, sorted, disjoint, non-adjacent collection of
-- version intervals. Backed by Cabal's 'VersionInterval' so that derived
-- structural equality coincides with semantic equality.
--
-- Union, intersection and complement are computed /directly on the intervals/,
-- as one pass of comparisons between bound positions. Going through
-- 'VersionRange' syntax instead would build a syntax tree and re-canonicalise
-- it with 'asVersionIntervals' on every operation. 'fromVersionRange' and
-- 'toVersionRange' convert at the boundary, where declared ranges arrive and
-- reports are rendered.
module PubGrub.VersionSet (
    -- The constructor is hidden so that every 'VersionSet' stays canonical.
    VersionSet,
    emptyVersionSet,
    fullVersionSet,
    singletonVersionSet,
    halfOpenVersionSet,
    snapToVersions,
    fromVersionRange,
    toVersionRange,
    complementVersionSet,
    unionVersionSet,
    intersectionVersionSet,
    contains,
    intervals,
) where

import           Data.Maybe                         (mapMaybe)
import           Data.Ord                           (Down (..), comparing)
import           Distribution.Types.VersionInterval (Bound (..),
                                                     LowerBound (..),
                                                     UpperBound (..),
                                                     VersionInterval (..),
                                                     asVersionIntervals,
                                                     fromVersionIntervals,
                                                     mkVersionIntervals)
import           Distribution.Version               (Version, VersionRange,
                                                     anyVersion, noVersion,
                                                     thisVersion, version0)
import           PubGrub.SetOps                     (SetOps (..))


-- | A position on the version line, fine enough to tell "up to but not
-- including @v@" from "up to and including @v@". Every interval bound is one of
-- these, and every operation below is comparisons between them.
--
-- 'Unbounded' is deliberately the /last/ constructor, so the derived 'Ord' puts
-- it above every position: a set with no upper bound reaches higher than any
-- bounded one.
data Cut
    = Cut Version Side
    | Unbounded
    deriving stock (Eq, Ord, Show)

-- | Which side of its version a cut falls on. An interval /starting/ at
-- @Before v@ contains @v@; one /ending/ there does not. @After v@ is the mirror
-- image. This is the whole trick: inclusive and exclusive bounds become two
-- neighbouring positions, so "does this interval touch that one" is @<=@.
data Side = Before | After
    deriving stock (Eq, Ord, Show)

lowerCut :: LowerBound -> Cut
lowerCut (LowerBound v InclusiveBound) = Cut v Before
lowerCut (LowerBound v ExclusiveBound) = Cut v After

upperCut :: UpperBound -> Cut
upperCut NoUpperBound                  = Unbounded
upperCut (UpperBound v ExclusiveBound) = Cut v Before
upperCut (UpperBound v InclusiveBound) = Cut v After

-- | A set as the cut pairs bounding its intervals: sorted, disjoint, and
-- separated by at least one position (that last part is what "non-adjacent"
-- means here, and what every operation below has to preserve).
cutsOf :: VersionSet -> [(Cut, Cut)]
cutsOf = map (\(VersionInterval lo hi) -> (lowerCut lo, upperCut hi)) . intervals

-- | Back from cut pairs, dropping the empty ones — which is where @>=2 && <2@
-- and friends disappear. An interval is empty exactly when its bounds are the
-- same position or crossed, so canonicalisation is a comparison.
fromCuts :: [(Cut, Cut)] -> VersionSet
fromCuts = VersionSet . mapMaybe interval
  where
    interval (lo, hi)
        | lo >= hi = Nothing
        | otherwise = case lo of
            Unbounded -> Nothing -- a lower bound above every version: empty
            Cut v Before -> Just (VersionInterval (LowerBound v InclusiveBound) (upper hi))
            Cut v After -> Just (VersionInterval (LowerBound v ExclusiveBound) (upper hi))
    upper Unbounded      = NoUpperBound
    upper (Cut w Before) = UpperBound w ExclusiveBound
    upper (Cut w After)  = UpperBound w InclusiveBound

newtype VersionSet = VersionSet [VersionInterval]
    deriving stock (Eq, Show)

-- | Order by how high the set reaches, then by how wide it is, then by the
-- full cut list — the third coordinate is arbitrary and exists only to
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
            , cutsOf vs
            )

        reachOf vs = case reverse (cutsOf vs) of
            (_, hi) : _ -> Just hi
            []          -> Nothing

        startOf vs = case cutsOf vs of
            (lo, _) : _ -> Just lo
            []          -> Nothing

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

-- | The half-open interval @[lo, hi)@, unbounded above when there is no @hi@.
-- Empty if @hi <= lo@ ('fromCuts' drops it).
--
-- This is the shape to reach for when naming /one release/ out of an index whose
-- version list you know: pass the release and the next existing release above it.
-- The interval then contains exactly that one real release, so it denotes the same
-- instances as @'singletonVersionSet' lo@ over anything that can actually be
-- offered — but unlike the singleton it __touches its neighbour__, and touching
-- intervals coalesce (see 'unionVersionSet'). So @[v1,v2)@ and @[v2,v3)@ join into
-- @[v1,v3)@ on their own, while @{v1}@ and @{v2}@ stay two fragments forever, and
-- removing @[v1,v2)@ leaves no empty @(v1,v2)@ hole behind to be learned about
-- later. Both matter to a solver: singleton fragments cannot express a depender
-- term such as @>=1.0 && <1.3@, and each hole in a range is refuted on its own.
halfOpenVersionSet :: Version -> Maybe Version -> VersionSet
halfOpenVersionSet lo hi = fromCuts [(Cut lo Before, maybe Unbounded (`Cut` Before) hi)]

-- | Narrow every interval to the versions in @universe@ that it actually
-- contains: each becomes the closed range from its lowest such version to its
-- highest, and intervals holding none are dropped.
--
-- The result is a __subset__ of the input denoting the __same__ versions of
-- @universe@ — it only ever removes version space nothing occupies. That is what
-- makes it safe to apply to a declared dependency range once the index's version
-- list is known: @>=0.2@ against a package whose oldest release is @0.5.1.0@
-- becomes @>=0.5.1.0@, so banning that release empties the set instead of leaving
-- a live-looking @>=0.2 && <0.5.1.0@ for the solver to refute separately.
--
-- Narrowing, never widening, is deliberate. The dual operation (widening each
-- interval out to the next existing version, as 'halfOpenVersionSet' does for a
-- release's slot) denotes the same versions just as soundly, but it would report
-- a declared @<5@ back to its author as @<=4.21.0.0@. A subset cannot overstate
-- what was declared.
--
-- @universe@ need not be sorted and may hold versions outside the set; cost is one
-- pass over it per interval.
--
-- Nothing calls this yet: applied to every emitted dependency it costs more
-- allocation than the conflicts it removes are worth, because it walks the
-- dependee's version list afresh each time.
snapToVersions :: [Version] -> VersionSet -> VersionSet
snapToVersions universe vs = fromCuts (mapMaybe tighten (cutsOf vs))
  where
    tighten (lo, hi) = bounds (lo, hi) >>= \(a, b) -> Just (Cut a Before, Cut b After)

    -- The lowest and highest members of the universe inside one interval, in one
    -- fold. Nothing if the interval holds none.
    bounds (lo, hi) = foldl' step Nothing universe
      where
        step acc v
            | inside v = Just (maybe (v, v) (\(a, b) -> (min a v, max b v)) acc)
            | otherwise = acc
        -- @v@ is in the interval when the cut just below it is at or above the
        -- lower bound and the cut just above it is at or below the upper.
        inside v = lo <= Cut v Before && Cut v After <= hi

-- | Merge two sorted interval lists, joining any that overlap or touch.
--
-- Touching is the case worth naming: @<2@ and @>=2@ share no version, yet their
-- union is everything, so leaving them as two intervals would break canonicity
-- (and with it the derived 'Eq'). In cut terms both are the position
-- @Before 2@, so the test for "join these" is just @<=@.
unionVersionSet :: VersionSet -> VersionSet -> VersionSet
unionVersionSet a b = fromCuts (coalesce (merge (cutsOf a) (cutsOf b)))
  where
    merge [] ys = ys
    merge xs [] = xs
    merge (x : xs) (y : ys)
        | fst x <= fst y = x : merge xs (y : ys)
        | otherwise = y : merge (x : xs) ys

    coalesce ((lo1, hi1) : (lo2, hi2) : rest)
        | lo2 <= hi1 = coalesce ((lo1, max hi1 hi2) : rest)
    coalesce (i : rest) = i : coalesce rest
    coalesce [] = []

-- | Sweep both lists together, taking the overlap of the pair in hand and
-- advancing whichever interval ends first. Empty overlaps fall out in 'fromCuts'.
intersectionVersionSet :: VersionSet -> VersionSet -> VersionSet
intersectionVersionSet a b = fromCuts (go (cutsOf a) (cutsOf b))
  where
    go [] _ = []
    go _ [] = []
    go xs@((lo1, hi1) : xs') ys@((lo2, hi2) : ys')
        | hi1 <= hi2 = overlap : go xs' ys
        | otherwise = overlap : go xs ys'
      where
        overlap = (max lo1 lo2, min hi1 hi2)

-- | Complement: the gaps between the intervals, plus the tails at either end.
--
-- Consecutive gaps are separated by the non-empty interval that lies between
-- them, so the result is canonical without any coalescing pass.
complementVersionSet :: VersionSet -> VersionSet
complementVersionSet vs = fromCuts (go (Cut version0 Before) (cutsOf vs))
  where
    go prev []             = [(prev, Unbounded)]
    go prev ((lo, hi) : rest)
        | hi == Unbounded = [(prev, lo)]
        | otherwise = (prev, lo) : go hi rest

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
