-- | Versions: a list of numbers, such as @1.2.0@, ordered component by
-- component, for a domain whose values are versions. "PubGrub.VersionSet" is
-- the matching set type.
--
-- __Trailing zeros are insignificant__: @1.2@, @1.2.0@ and @1.2.0.0@ are one
-- version, equal under 'Eq' and 'Ord'. Each keeps its spelling for display
-- ('versionNumbers'), and the comparisons read the 'normalForm', the spelling
-- with its trailing zeros dropped.
--
-- An order in which @1.2 < 1.2.0@ would put room between two spellings of one
-- version, where no version can ever be, and every set would have to carry
-- it: @>=1.2 && <1.2.0@ would be a range that looks open and holds nothing,
-- which a search can only discover by asking. With trailing zeros
-- insignificant there is no such range, and a bound @>=1.8.0@ admits the
-- version spelled @1.8@, as its author means. Two values that spell one version
-- differently are one value here, so a domain that has both has to keep one.
module PubGrub.Version
    ( Version
    , mkVersion
    , versionNumbers
    , normalForm
    , version0
    ) where

import           Data.Ord (comparing)

-- | A version: its spelling, and its normal form. Build one with 'mkVersion'.
data Version = Version
    { versionNumbers :: ![Int]
    -- ^ the components as spelled — @[1,2,0,0]@ for @1.2.0.0@, not the normal
    -- form
    , normalForm     :: ![Int]
    -- ^ the spelling with trailing zeros dropped, keeping at least one
    -- component. What 'Eq' and 'Ord' compare.
    }

-- The normal form is a field, computed once by 'mkVersion', because 'Eq' and
-- 'Ord' read it on every comparison and a solve compares versions far more
-- often than it makes them. Deriving it on each comparison cost a fifth of a
-- large solve's time and a third of its allocation.

instance Eq Version where
    a == b = normalForm a == normalForm b

instance Ord Version where
    compare = comparing normalForm

-- | As the expression that makes it: @mkVersion [1,2,0]@.
instance Show Version where
    showsPrec d v =
        showParen (d > 10) (showString "mkVersion " . showsPrec 11 (versionNumbers v))

-- | A version from its components, as spelled. An empty list is the version
-- @0@, and a negative component is taken as @0@.
mkVersion :: [Int] -> Version
mkVersion [] = version0
mkVersion ns = Version spelled normal
  where
    spelled = map (max 0) ns
    normal = case reverse (dropWhile (== 0) (reverse spelled)) of
        [] -> [0]
        ms -> ms

-- | The version @0@, the lowest there is. Every version set starts here.
version0 :: Version
version0 = Version [0] [0]
