-- | The solver's version type.
--
-- A version is spelled the way Hackage names the release — @1.2@, @1.2.0@ or
-- @1.2.0.0@ — and __ordered with trailing zeros insignificant__, so those three
-- spellings are one version. The spelling is kept for display only: 'Eq' and
-- 'Ord' compare the 'normalForm', which is the spelling with its trailing zeros
-- dropped and at least one component kept. This is the same move as
-- 'PubGrub.VersionSet.declared': a tag the lawful part of the type ignores.
--
-- Cabal's own 'Distribution.Types.Version.Version' orders @1.2 < 1.2.0 <
-- 1.2.0.0@, which puts version space between spellings of one version that
-- nothing published ever occupies. Every set operation then has to carry that
-- space: @^>=4.13.0.0 || ^>=4.14.0.0@ is two intervals with the hole
-- @[4.14, 4.14.0.0)@ between them, and the difference between a declared
-- @>=0.3@ and the slot of the release @0.3.0.0@ is a live-looking
-- @>=0.3 && <0.3.0.0@ that the search discovers empty one @no version for@ at
-- a time. The deviation from Cabal's order is small: on Hackage on 2026-09-09,
-- 44 of 19,458 packages published two spellings of one version, and 1,404
-- dependency bounds in latest releases admitted a slightly different set of
-- versions, each in the direction the author plainly meant (@time >=1.8.0@
-- against the release @time 1.8@, which Cabal excludes). Where an index has two
-- spellings of one version, its reader has to keep one.
--
-- Conversions to and from Cabal's type are exact in both directions, because
-- the spelling survives; they live with the cabal domain
-- (@PubGrub.Cabal.Version@), as this module knows nothing of Cabal.
module PubGrub.Version
    ( Version
    , mkVersion
    , versionNumbers
    , normalForm
    , version0
    ) where

import           Data.Ord (comparing)

-- | The spelling and its normal form, both non-empty and non-negative. The
-- constructor is not exported: 'mkVersion' keeps the invariant and computes
-- the normal form __once__, because 'Eq' and 'Ord' read it on every
-- comparison and a solve compares versions far more often than it makes them
-- (every cut of every version set, every slot, every installed unit). Deriving
-- it on each comparison measured at a fifth of a large solve's time and a third
-- of its allocation.
data Version = Version
    { versionNumbers :: ![Int]
    -- ^ the components as spelled — @[1,2,0,0]@ for @1.2.0.0@, not the normal
    -- form
    , normalForm     :: ![Int]
    -- ^ the spelling with trailing zeros dropped, keeping at least one
    -- component. What 'Eq' and 'Ord' compare.
    }

instance Eq Version where
    a == b = normalForm a == normalForm b

instance Ord Version where
    compare = comparing normalForm

-- | Like Cabal's: @mkVersion [1,2,0]@, so a trace reads the same either way.
instance Show Version where
    showsPrec d v =
        showParen (d > 10) (showString "mkVersion " . showsPrec 11 (versionNumbers v))

-- | Build from components. An empty list is the version @0@, and a negative
-- component, which Cabal's parser never produces, is taken as @0@.
mkVersion :: [Int] -> Version
mkVersion [] = version0
mkVersion ns = Version spelled normal
  where
    spelled = map (max 0) ns
    normal = case reverse (dropWhile (== 0) (reverse spelled)) of
        [] -> [0]
        ms -> ms

-- | The lowest version. Every version set's universe starts here.
version0 :: Version
version0 = Version [0] [0]
