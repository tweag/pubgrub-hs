{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies       #-}

-- | A version set: a canonical, sorted, disjoint, non-adjacent collection of
-- version intervals. Backed by Cabal's 'VersionInterval', and 'Eq' compares the
-- intervals alone, so structural equality coincides with semantic equality.
--
-- Beside the intervals, a set remembers the __declared range__ it was built from,
-- when it was built from one. That tag is a display hint and nothing more: only
-- 'fromVersionRange' sets it, every operation below drops it, 'Eq' and 'Ord'
-- cannot see it, and 'toVersionRange' hands it back so a report quotes a range
-- the way its author wrote it — @^>=4.13.0.0@ rather than @>=4.13.0.0 && <4.14@.
-- A derived term has no author, and prints canonically.
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
    belowVersionSet,
    snapToVersions,
    fillGaps,
    fromVersionRange,
    toVersionRange,
    declaredRange,
    complementVersionSet,
    unionVersionSet,
    intersectionVersionSet,
    contains,
    intervals,
) where

import           Data.Maybe                         (fromMaybe, mapMaybe)
import           Data.Ord                           (Down (..), comparing)
import           Data.Set                           (Set)
import qualified Data.Set                           as Set
import           Distribution.Types.VersionInterval (Bound (..),
                                                     LowerBound (..),
                                                     UpperBound (..),
                                                     VersionInterval (..),
                                                     asVersionIntervals,
                                                     fromVersionIntervals,
                                                     mkVersionIntervals)
import           Distribution.Version               (Version, VersionRange,
                                                     noVersion, version0)
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
fromCuts cs = VersionSet (mapMaybe interval cs) Nothing
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

data VersionSet = VersionSet
    { intervals     :: [VersionInterval]
    -- ^ The raw canonical interval list (for testing / reporting).
    , declaredRange :: Maybe VersionRange
    -- ^ The range this set was built from by 'fromVersionRange', if it was, and
    -- 'Nothing' for anything an operation produced. It always denotes exactly
    -- 'intervals'. Equality and order ignore it.
    }
    deriving stock (Show)

instance Eq VersionSet where
    a == b = intervals a == intervals b

-- | Order by how high the set reaches, then by how wide it is, then by the
-- full cut list — the third coordinate is arbitrary and exists only to
-- keep the order total and consistent with 'Eq' (two distinct sets
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

-- | Build a canonical 'VersionSet' from any 'VersionRange', remembering the
-- range as the set's 'declaredRange'. This is the one place the tag is set: a
-- range that arrives here was written by someone, and that spelling is what a
-- report should quote back.
fromVersionRange :: VersionRange -> VersionSet
fromVersionRange r = VersionSet (asVersionIntervals r) (Just r)

-- | Convert back to a 'VersionRange': the declared range where there is one, and
-- otherwise Cabal's own canonical 'VersionIntervals' round-trip. Our interval
-- list is always canonical (it comes from 'asVersionIntervals'), so
-- 'mkVersionIntervals' always succeeds; the 'noVersion' fallback is unreachable.
--
-- Cabal never re-sugars: its 'fromVersionIntervals' rebuilds @==v@ and nothing
-- else, so a major bound that went through the intervals comes back as
-- @>=v && <v'@. Handing the declared range back is the only way @^>=v@ survives.
toVersionRange :: VersionSet -> VersionRange
toVersionRange vs = fromMaybe canonical (declaredRange vs)
  where
    canonical = maybe noVersion fromVersionIntervals (mkVersionIntervals (intervals vs))

emptyVersionSet :: VersionSet
emptyVersionSet = VersionSet [] Nothing

fullVersionSet :: VersionSet
fullVersionSet = fromCuts [(Cut version0 Before, Unbounded)]

-- | The set containing exactly one version.
singletonVersionSet :: Version -> VersionSet
singletonVersionSet v = fromCuts [(Cut v Before, Cut v After)]

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

-- | Everything below @hi@, or everything when there is no @hi@: the slot of a
-- package's __first__ release, which takes no lower bound. Nothing is published
-- below the first release, so the set denotes the same instances as the
-- half-open slot would — but its complement is @>=hi@ and not @<lo || >=hi@, and
-- the @<lo@ piece is a hole the solver would otherwise have to learn is empty,
-- one @no version for@ at a time.
belowVersionSet :: Maybe Version -> VersionSet
belowVersionSet hi = fromCuts [(Cut version0 Before, maybe Unbounded (`Cut` Before) hi)]

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
-- Takes the universe as a 'Set' so each interval costs two ordered lookups rather
-- than a pass over every version of the package.
--
-- Nothing calls this, and cost is not the reason: applied to declared dependency
-- ranges it rewrites every quoted range into a closed form nobody wrote — a
-- user's own @lens <4@ comes back as @lens >=0.1 && <=3.10.3@ — and that
-- objection holds at any price. 'fillGaps' is the half of this that does not
-- touch an outer bound.
snapToVersions :: Set Version -> VersionSet -> VersionSet
snapToVersions universe vs = fromCuts (mapMaybe tighten (cutsOf vs))
  where
    tighten (lo, hi) = do
        a <- lowest lo
        b <- highest hi
        if a <= b then Just (Cut a Before, Cut b After) else Nothing

    -- The lowest member of the universe at or above the interval's lower bound.
    -- @Before v@ admits @v@ itself, @After v@ does not — the same distinction the
    -- cut makes.
    lowest (Cut v Before) = Set.lookupGE v universe
    lowest (Cut v After)  = Set.lookupGT v universe
    lowest Unbounded      = Nothing  -- a lower bound above every version: empty

    -- And the highest at or below the upper bound, mirrored: an interval ending
    -- @Before w@ excludes @w@, one ending @After w@ includes it.
    highest (Cut w Before) = Set.lookupLT w universe
    highest (Cut w After)  = Set.lookupLE w universe
    highest Unbounded      = Set.lookupMax universe

-- | Fill every gap between two intervals that no member of @universe@ occupies.
-- The outer bounds are never touched; only interior holes go. The result is a
-- __superset__ of the input denoting the __same__ members of the universe, and
-- it carries no 'declaredRange', since it is no longer what anyone wrote.
--
-- This is the other half of 'snapToVersions', and the half that is safe to show
-- an author: a declared @>=4.7 && <5@ is left alone, while @^>=4.13.0.0 ||
-- ^>=4.14.0.0 || … || ^>=4.19.0.0@ against a package with nothing published
-- between @4.13.x@ and @4.14.0.0@ becomes @>=4.13.0.0 && <4.20@. Cabal's own
-- 'majorUpperBound' keeps two components, so the holes it leaves between
-- consecutive major bounds — the versions @4.14@ and @4.14.0@, below
-- @4.14.0.0@ — are real in Cabal's ordering and empty on Hackage.
--
-- A single interval costs nothing here. Each gap costs one ordered lookup.
--
-- Nothing calls this yet. It is not applied to declared ranges, because a filled
-- set drops its 'declaredRange' and the report would lose the author's own
-- spelling. It belongs on a __derived__ term, which nobody wrote and which prints
-- canonically anyway; that needs the version universe at report time.
fillGaps :: Set Version -> VersionSet -> VersionSet
fillGaps universe vs = fromCuts (go (cutsOf vs))
  where
    go ((lo1, hi1) : (lo2, hi2) : rest)
        | occupied hi1 lo2 = (lo1, hi1) : go ((lo2, hi2) : rest)
        | otherwise = go ((lo1, hi2) : rest)
    go is = is

    -- Is some member of the universe strictly between the two cuts? @v@ is, iff
    -- @hi < After v@ and @Before v < lo@; 'above' finds the least @v@ with the
    -- first property, and the second is one comparison.
    occupied hi lo = case above hi of
        Nothing -> False
        Just v  -> Cut v Before < lo
    above (Cut w Before) = Set.lookupGE w universe
    above (Cut w After)  = Set.lookupGT w universe
    above Unbounded      = Nothing

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
contains vs v = any inside (intervals vs)
  where
    inside (VersionInterval lo hi) = lowerOk lo && upperOk hi
    lowerOk (LowerBound w InclusiveBound) = v >= w
    lowerOk (LowerBound w ExclusiveBound) = v > w
    upperOk NoUpperBound                  = True
    upperOk (UpperBound w InclusiveBound) = v <= w
    upperOk (UpperBound w ExclusiveBound) = v < w
