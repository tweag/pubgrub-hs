-- | Compact rendering to 'Text', for messages and explanations: version sets
-- as ranges, finite sets in braces, negative terms as @¬(…)@.
--
-- It is separate from 'Show' on purpose. 'Show' stays derived and shows the
-- constructors as they are, which is what debugging wants; 'pretty' is what a
-- person reads.
module PubGrub.Pretty (Pretty (..), AsPretty (..)) where

import           Data.Maybe         (fromMaybe)
import           Data.Set           (Set)
import qualified Data.Set           as Set
import           Data.Text          (Text)
import qualified Data.Text          as T
import           PubGrub.Term       (Term (..))
import           PubGrub.Version    (Version, versionNumbers)
import           PubGrub.VersionSet (VersionSet, declared, renderVersionSet)

-- | Types with a compact rendering.
class Pretty a where
    -- | The rendering.
    pretty :: a -> Text

-- | Shows a value through 'pretty', for GHCi and examples.
newtype AsPretty a = AsPretty {getAsPretty :: a}

instance Pretty a => Show (AsPretty a) where
    show = T.unpack . pretty . getAsPretty

instance Pretty Version where
    pretty = T.intercalate (T.pack ".") . map (T.pack . show) . versionNumbers

-- | The declared spelling where there is one, and the canonical intervals
-- otherwise ('PubGrub.VersionSet.renderVersionSet').
instance Pretty VersionSet where
    pretty vs = fromMaybe (renderVersionSet vs) (declared vs)

instance Pretty a => Pretty (Term a) where
    pretty (Positive s) = pretty s
    pretty (Negative s) = T.pack "¬(" <> pretty s <> T.pack ")"

instance Pretty a => Pretty (Set a) where
    pretty s = T.pack "{" <> T.intercalate (T.pack ",") (map pretty (Set.toList s)) <> T.pack "}"
