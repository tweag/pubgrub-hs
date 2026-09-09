{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies       #-}

-- | A version set: a canonical, sorted, disjoint, non-adjacent collection of
-- version intervals over 'PubGrub.Version.Version', each interval a pair of
-- bound positions ('Cut'). 'Eq' compares the intervals alone, so structural
-- equality coincides with semantic equality.
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
-- it with @asVersionIntervals@ on every operation. Cabal's 'VersionRange'
-- appears at the boundary only: 'fromVersionRange' folds a declared range into a
-- set with the operations below, and 'toVersionRange' renders a set for a report.
--
-- The version order is ours, not Cabal's: trailing zeros are insignificant
-- ('PubGrub.Version'). So @^>=4.13.0.0 || ^>=4.14.0.0@ is __one__ interval here,
-- and @>=0.3 && <0.3.0.0@ is empty, where Cabal's order leaves a hole below
-- @4.14.0.0@ and a live-looking interval below @0.3.0.0@ that no release ever
-- occupies.
module PubGrub.VersionSet (
    -- The constructor is hidden so that every 'VersionSet' stays canonical.
    VersionSet,
    Cut (..),
    Side (..),
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

import           Data.Maybe                      (fromMaybe, mapMaybe)
import           Data.Ord                        (Down (..), comparing)
import           Data.Set                        (Set)
import qualified Data.Set                        as Set
import           Distribution.Types.VersionRange (VersionRange, anyVersion,
                                                  earlierVersion,
                                                  foldVersionRange,
                                                  intersectVersionRanges,
                                                  laterVersion, noVersion,
                                                  orEarlierVersion,
                                                  orLaterVersion, thisVersion,
                                                  unionVersionRanges)
import           PubGrub.SetOps                  (SetOps (..))
import           PubGrub.Version                 (Version, fromCabalVersion,
                                                  toCabalVersion, version0,
                                                  versionNumbers)


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

-- | The later of two positions, and the earlier. At the __same__ position — two
-- spellings of one version, since 'Eq' on 'Version' ignores trailing zeros — the
-- shorter spelling is kept. Either denotes the set; the shorter one is what a
-- declared @>=2.0@ was written as, where the release's slot says @2.0.0.0@, and it
-- is what a derived term should print.
laterCut, earlierCut :: Cut -> Cut -> Cut
laterCut a b = case compare a b of
    LT -> b
    GT -> a
    EQ -> shorterCut a b
earlierCut a b = case compare a b of
    LT -> a
    GT -> b
    EQ -> shorterCut a b

shorterCut :: Cut -> Cut -> Cut
shorterCut a@(Cut v _) b@(Cut w _)
    | length (versionNumbers w) < length (versionNumbers v) = b
    | otherwise = a
shorterCut a _ = a

-- | A set as the cut pairs bounding its intervals: sorted, disjoint, and
-- separated by at least one position (that last part is what "non-adjacent"
-- means here, and what every operation below has to preserve).
cutsOf :: VersionSet -> [(Cut, Cut)]
cutsOf = intervals

-- | Back from cut pairs, dropping the empty ones — which is where @>=2 && <2@
-- and friends disappear. An interval is empty exactly when its bounds are the
-- same position or crossed, so canonicalisation is a comparison. The input must
-- already be sorted and non-adjacent; every caller below arranges that.
fromCuts :: [(Cut, Cut)] -> VersionSet
fromCuts cs = VersionSet (filter nonEmpty cs) Nothing
  where
    nonEmpty (Unbounded, _) = False -- a lower bound above every version: empty
    nonEmpty (lo, hi)       = lo < hi

data VersionSet = VersionSet
    { intervals     :: [(Cut, Cut)]
    -- ^ The canonical interval list, as cut pairs (for testing / reporting).
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
--
-- Cabal's 'foldVersionRange' does the desugaring — @^>=v@ into its major
-- window, @>=v@ into @==v || >v@ — and the set is then assembled with the
-- operations below, so every comparison between bounds is made in __our__
-- order. Two consecutive @^>=@ windows therefore touch and coalesce here.
fromVersionRange :: VersionRange -> VersionSet
fromVersionRange r = (foldVersionRange fullVersionSet this later earlier unionVersionSet intersectionVersionSet r) {declaredRange = Just r}
  where
    this v = singletonVersionSet (fromCabalVersion v)
    later v = fromCuts [(Cut (fromCabalVersion v) After, Unbounded)]
    earlier v = fromCuts [(Cut version0 Before, Cut (fromCabalVersion v) Before)]

-- | Convert back to a 'VersionRange': the declared range where there is one, and
-- otherwise the canonical intervals as @>=a && <b@ pieces joined by @||@, with a
-- one-version interval as @==v@ and a lower bound at @0@ omitted. A major bound
-- that went through the intervals therefore comes back as @>=v && <v'@;
-- handing the declared range back is the only way @^>=v@ survives.
toVersionRange :: VersionSet -> VersionRange
toVersionRange vs = fromMaybe canonical (declaredRange vs)
  where
    canonical = case map interval (cutsOf vs) of
        []     -> noVersion
        r : rs -> foldr1 unionVersionRanges (r : rs)

    interval (Cut v Before, Cut w After) | v == w = thisVersion (toCabalVersion v)
    interval (lo, hi) = case (lower lo, upper hi) of
        (Nothing, Nothing) -> anyVersion
        (Just l, Nothing)  -> l
        (Nothing, Just u)  -> u
        (Just l, Just u)   -> intersectVersionRanges l u

    lower (Cut v Before)
        | v == version0 = Nothing
        | otherwise = Just (orLaterVersion (toCabalVersion v))
    lower (Cut v After) = Just (laterVersion (toCabalVersion v))
    lower Unbounded = Nothing -- unreachable: 'fromCuts' drops such an interval

    upper Unbounded      = Nothing
    upper (Cut w Before) = Just (earlierVersion (toCabalVersion w))
    upper (Cut w After)  = Just (orEarlierVersion (toCabalVersion w))

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
-- an author: a declared @>=4.7 && <5@ is left alone, while @>=1.0 && <1.2 ||
-- >=1.3 && <2@ against a package with nothing published in @[1.2, 1.3)@
-- becomes @>=1.0 && <2@. Consecutive @^>=@ windows leave no hole for this to
-- fill, because trailing zeros are insignificant in this order; what is left is
-- a gap somebody wrote.
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
        | fst x < fst y = x : merge xs (y : ys)
        | fst y < fst x = y : merge (x : xs) ys
        | otherwise = (shorterCut (fst x) (fst y), snd x) : merge xs (y : ys)

    coalesce ((lo1, hi1) : (lo2, hi2) : rest)
        | lo2 <= hi1 = coalesce ((lo1, laterCut hi1 hi2) : rest)
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
        overlap = (laterCut lo1 lo2, earlierCut hi1 hi2)

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

-- | Membership: @v@ lies in an interval iff the interval starts at or before
-- @Before v@ and ends at or after @After v@.
contains :: VersionSet -> Version -> Bool
contains vs v = any inside (cutsOf vs)
  where
    inside (lo, hi) = lo <= Cut v Before && Cut v After <= hi
