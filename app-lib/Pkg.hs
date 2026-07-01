{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies      #-}

-- | The resolution package type shared by every provider: a synthetic root, or
-- a real Hackage/installed package named by its 'PackageName'.
module Pkg (Pkg (..)) where

import qualified Data.Text                      as T
import           Distribution.Pretty            (prettyShow)
import           Distribution.Types.PackageName (PackageName)
import           PubGrub.Pretty                 (Pretty (..))

data Pkg = Root | Pkg PackageName
    deriving (Eq, Ord, Show)

instance Pretty Pkg where
    pretty Root    = "root"
    pretty (Pkg n) = T.pack (prettyShow n)
