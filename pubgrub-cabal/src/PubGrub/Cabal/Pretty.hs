{-# OPTIONS_GHC -Wno-orphans #-}

-- | 'Pretty' for the Cabal-syntax types a proof names. The class is the core's
-- and the types are Cabal's, so these are orphans by necessity; this module is
-- imported, for its instances, by the modules that define the cabal domain, so
-- they are in scope wherever the domain is.
module PubGrub.Cabal.Pretty () where

import qualified Data.Text                      as T
import           Distribution.Pretty            (prettyShow)
import           Distribution.Types.Flag        (FlagName, unFlagName)
import           Distribution.Types.PackageName (PackageName)
import           Distribution.Types.UnitId      (UnitId)
import           PubGrub.Pretty                 (Pretty (..))

instance Pretty PackageName where
    pretty = T.pack . prettyShow

instance Pretty FlagName where
    pretty = T.pack . unFlagName

instance Pretty UnitId where
    pretty = T.pack . prettyShow
