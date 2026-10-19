-- | The solver's version type, with the conversions to and from Cabal's.
--
-- "PubGrub.Version" is re-exported whole, so the cabal side imports this module
-- in its place. The conversions are exact in both directions, because the
-- spelling survives: a version converted in and back out is the Cabal version
-- it came from, trailing zeros included, so it still names its release's
-- @.cabal@.
module PubGrub.Cabal.Version
    ( module PubGrub.Version
    , fromCabalVersion
    , toCabalVersion
    ) where

import qualified Distribution.Types.Version as Cabal
import           PubGrub.Version

fromCabalVersion :: Cabal.Version -> Version
fromCabalVersion = mkVersion . Cabal.versionNumbers

toCabalVersion :: Version -> Cabal.Version
toCabalVersion = Cabal.mkVersion . versionNumbers
