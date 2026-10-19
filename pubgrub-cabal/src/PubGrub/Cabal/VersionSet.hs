-- | Version sets, with the conversions to and from Cabal's 'VersionRange'.
--
-- "PubGrub.VersionSet" is re-exported whole, so the cabal side imports this
-- module in its place. Cabal's syntax stops here: 'fromVersionRange' folds a
-- declared range into a set and tags it with the author's spelling, and
-- 'toVersionRange' reads a set back out for Cabal's own tools.
module PubGrub.Cabal.VersionSet
    ( module PubGrub.VersionSet
    , fromVersionRange
    , toVersionRange
    ) where

import qualified Data.Text                       as T
import           Distribution.Pretty             (prettyShow)
import           Distribution.Types.VersionRange (VersionRange, anyVersion,
                                                  earlierVersion,
                                                  foldVersionRange,
                                                  intersectVersionRanges,
                                                  laterVersion, noVersion,
                                                  orEarlierVersion,
                                                  orLaterVersion, thisVersion,
                                                  unionVersionRanges)
import           PubGrub.Cabal.Version           (fromCabalVersion,
                                                  toCabalVersion, version0)
import           PubGrub.VersionSet

-- | Build a canonical 'VersionSet' from any 'VersionRange', remembering the
-- range's spelling as the set's 'declared' tag: a range that arrives here was
-- written by someone, and that spelling is what a report should quote back.
--
-- Cabal's 'foldVersionRange' does the desugaring — @^>=v@ into its major
-- window, @>=v@ into @==v || >v@ — and the set is then assembled with the
-- core's operations, so every comparison between bounds is made in __our__
-- order. Two consecutive @^>=@ windows therefore touch and coalesce here.
fromVersionRange :: VersionRange -> VersionSet
fromVersionRange r =
    declare (T.pack (prettyShow r)) (foldVersionRange fullVersionSet this later earlier unionVersionSet intersectionVersionSet r)
  where
    this = singletonVersionSet . fromCabalVersion
    later = aboveVersionSet . fromCabalVersion
    earlier = belowVersionSet . Just . fromCabalVersion

-- | The canonical intervals as a 'VersionRange': @>=a && <b@ pieces joined by
-- @||@, a one-version interval as @==v@ and a lower bound at @0@ omitted. The
-- declared spelling is not consulted — it is text, not syntax — so a major
-- bound comes back as @>=v && <v'@; 'PubGrub.Pretty.Pretty' is where @^>=v@
-- survives. Cabal prints this range exactly as 'renderVersionSet' spells the
-- set.
toVersionRange :: VersionSet -> VersionRange
toVersionRange vs = case map interval (intervals vs) of
    []     -> noVersion
    r : rs -> foldr1 unionVersionRanges (r : rs)
  where
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
    lower Unbounded = Nothing -- unreachable: an interval never starts unbounded

    upper Unbounded      = Nothing
    upper (Cut w Before) = Just (earlierVersion (toCabalVersion w))
    upper (Cut w After)  = Just (orEarlierVersion (toCabalVersion w))
