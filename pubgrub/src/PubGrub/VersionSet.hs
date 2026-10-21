{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TypeFamilies       #-}

-- | A version set: a canonical, sorted, disjoint, non-adjacent collection of
-- version intervals over 'PubGrub.Version.Version', each interval a pair of
-- bound positions ('Cut'). 'Eq' compares the intervals alone, so structural
-- equality coincides with semantic equality.
--
-- Beside the intervals, a set remembers the __declared spelling__ it was built
-- from, when it was built from one. That tag is a display hint and nothing more:
-- only 'declare' sets it, every operation below drops it, 'Eq' and 'Ord' cannot
-- see it, and 'Pretty' hands it back so a report quotes a range the way its
-- author wrote it — @^>=4.13.0.0@ rather than @>=4.13.0.0 && <4.14@: the same
-- intervals as a plain range, plus the knowledge of how it was spelled. A
-- derived term has no author, and prints canonically ('renderVersionSet').
--
-- Union, intersection and complement are computed /directly on the intervals/,
-- as one pass of comparisons between bound positions. No syntax tree is built
-- and the result is canonical by construction, so nothing is re-derived after an
-- operation. Range syntax is a domain's business: a domain folds a declared range
-- into a set with the operations below.
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
    aboveVersionSet,
    belowVersionSet,
    snapToVersions,
    fillGaps,
    declare,
    declared,
    renderVersionSet,
    complementVersionSet,
    unionVersionSet,
    intersectionVersionSet,
    contains,
    intervals,
) where

import           Data.List       (intercalate)
import           Data.Maybe      (mapMaybe)
import           Data.Ord        (Down (..), comparing)
import           Data.Set        (Set)
import qualified Data.Set        as Set
import           Data.Text       (Text)
import qualified Data.Text       as T
import           PubGrub.SetOps  (SetOps (..))
import           PubGrub.Version (Version, version0, versionNumbers)


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
    { intervals :: [(Cut, Cut)]
    -- ^ The canonical interval list, as cut pairs (for testing / reporting).
    , declared  :: Maybe Text
    -- ^ The spelling this set was built from by 'declare', if it was, and
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

-- | Tag a set with the spelling it was built from. This is the one place the
-- tag is set: a range that arrives here was written by someone, and that
-- spelling is what a report should quote back. The caller vouches that the
-- spelling denotes exactly the set.
declare :: Text -> VersionSet -> VersionSet
declare spelling vs = vs{declared = Just spelling}

-- | The canonical intervals as text, in cabal's range syntax: @>=a && <b@
-- pieces joined by @||@, a one-version interval as @==v@, a lower bound at @0@
-- omitted, everything as @>=0@ and nothing as @<0@. A major bound that went
-- through the intervals therefore comes back as @>=v && <v'@; the declared
-- spelling, where there is one, is how @^>=v@ survives, and 'Pretty' prefers it.
--
-- This is one spelling among the possible ones, chosen because it is what
-- Cabal's own printer writes for the same intervals, so a proof reads the same
-- whether a range was declared or derived.
renderVersionSet :: VersionSet -> Text
renderVersionSet vs = case map interval (cutsOf vs) of
    [] -> "<0"
    rs -> T.intercalate " || " rs
  where
    interval (Cut v Before, Cut w After) | v == w = "==" <> spell v
    interval (lo, hi) = case (lower lo, upper hi) of
        (Nothing, Nothing) -> ">=0"
        (Just l, Nothing)  -> l
        (Nothing, Just u)  -> u
        (Just l, Just u)   -> l <> " && " <> u

    lower (Cut v Before)
        | v == version0 = Nothing
        | otherwise = Just (">=" <> spell v)
    lower (Cut v After) = Just (">" <> spell v)
    lower Unbounded = Nothing -- unreachable: 'fromCuts' drops such an interval

    upper Unbounded      = Nothing
    upper (Cut w Before) = Just ("<" <> spell w)
    upper (Cut w After)  = Just ("<=" <> spell w)

    spell = T.pack . intercalate "." . map show . versionNumbers

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

-- | Everything strictly above @lo@: the set @>lo@.
aboveVersionSet :: Version -> VersionSet
aboveVersionSet lo = fromCuts [(Cut lo After, Unbounded)]

-- | Everything below @hi@, or everything when there is no @hi@: the slot of a
-- package's __first__ release, which has no lower bound: a proof says
-- @foo <1.1@, not @foo >=1.0 && <1.1@. Nothing is published below the first
-- release, so the set denotes the same instances as the half-open slot would —
-- but its complement is @>=hi@ and not @<lo || >=hi@, and the @<lo@ piece is a
-- hole the solver would otherwise have to learn is empty, one @no version for@
-- at a time.
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
-- __Not for declared ranges.__ Applied to them, it rewrites every quoted range
-- in a closed form nobody wrote: a user's own @lens <4@ comes back as
-- @lens >=0.1 && <=3.10.3@ on the proof's last line. That objection holds
-- whatever it would save. 'fillGaps' is the half of this that does not touch an
-- outer bound.
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
-- it carries no 'declared' spelling, since it is no longer what anyone wrote.
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
-- It is not meant for declared ranges, because a filled set has to drop its
-- 'declared' spelling, and a proof should quote the author's own spelling.
-- Where it belongs is a __derived__ term, which nobody wrote and which prints
-- canonically anyway; that needs the universe at report time, which the core
-- does not have yet.
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
    empty = emptyVersionSet
    intersect = intersectionVersionSet
    union = unionVersionSet
    difference a b = intersectionVersionSet a (complementVersionSet b)
    isEmpty = null . intervals
    isSubsetOf = subsetVersionSet
    isDisjoint = disjointVersionSet

-- | @a ⊆ b@: every interval of @a@ lies inside one interval of @b@. One sweep,
-- no set built. Both lists are sorted and their intervals separated by at least
-- one position, so an interval of @b@ that ends at or before the interval of @a@
-- in hand covers none of it and is passed; one that starts after it, or ends
-- before it does, leaves part of it uncovered that no later interval of @b@
-- can reach. The same answer as @isEmpty (a \\ b)@.
subsetVersionSet :: VersionSet -> VersionSet -> Bool
subsetVersionSet a b = go (cutsOf a) (cutsOf b)
  where
    go [] _ = True
    go _ [] = False
    go xs@((lo1, hi1) : xs') ys@((lo2, hi2) : ys')
        | hi2 <= lo1 = go xs ys'
        | lo2 <= lo1 && hi1 <= hi2 = go xs' ys
        | otherwise = False

-- | @a ∩ b = ∅@: no interval of @a@ overlaps one of @b@. Two intervals overlap
-- iff each starts before the other ends, so the sweep drops whichever ends
-- first. The same answer as @isEmpty (a ∩ b)@.
disjointVersionSet :: VersionSet -> VersionSet -> Bool
disjointVersionSet a b = go (cutsOf a) (cutsOf b)
  where
    go [] _ = True
    go _ [] = True
    go xs@((lo1, hi1) : xs') ys@((lo2, hi2) : ys')
        | hi1 <= lo2 = go xs' ys
        | hi2 <= lo1 = go xs ys'
        | otherwise = False

-- | Membership: @v@ lies in an interval iff the interval starts at or before
-- @Before v@ and ends at or after @After v@.
contains :: VersionSet -> Version -> Bool
contains vs v = any inside (cutsOf vs)
  where
    inside (lo, hi) = lo <= Cut v Before && Cut v After <= hi
