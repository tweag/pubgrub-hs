-- | Lightweight rendering to 'Text' for conflict reports. Distinct from Cabal's
-- 'Distribution.Pretty.Pretty' (which targets 'Doc'/'String'). 'Package' keeps
-- its own 'prettyPackage' for the package type.
module PubGrub.Pretty (Pretty (..)) where

import           Data.Text            (Text)
import qualified Data.Text            as T
import           Distribution.Pretty  (prettyShow)
import           Distribution.Version (Version)
import           PubGrub.VersionSet   (VersionSet)
import qualified PubGrub.VersionSet   as VS

class Pretty a where
    pretty :: a -> Text

instance Pretty Version where
    pretty = T.pack . prettyShow

instance Pretty VersionSet where
    pretty = T.pack . prettyShow . VS.toVersionRange
