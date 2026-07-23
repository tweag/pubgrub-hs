-- | Lightweight rendering to 'Text' for conflict reports. Distinct from Cabal's
-- 'Distribution.Pretty.Pretty' (which targets 'Doc'/'String').
--
-- Kept separate from 'Show' on purpose: 'Show' stays derived, showing
-- constructors as they are — which is what you want when chasing a canonicity
-- bug — while 'pretty' is the compact notation (version sets as ranges,
-- finite sets in braces, negative terms as @¬(…)@).
module PubGrub.Pretty (Pretty (..), AsPretty (..)) where

import           PubGrub.Term                   (Term (..))

import           Data.Set                       (Set)
import qualified Data.Set                       as Set
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Distribution.Pretty            (prettyShow)
import           Distribution.Types.Flag        (FlagName, unFlagName)
import           Distribution.Types.PackageName (PackageName)
import           Distribution.Version           (Version)
import           PubGrub.VersionSet             (VersionSet)
import qualified PubGrub.VersionSet             as VS

class Pretty a where
    pretty :: a -> Text

-- | Adapter for the repl and doctests: 'show' goes through 'pretty'.
newtype AsPretty a = AsPretty {getAsPretty :: a}

instance Pretty a => Show (AsPretty a) where
    show = T.unpack . pretty . getAsPretty

instance Pretty PackageName where
    pretty = T.pack . prettyShow

instance Pretty FlagName where
    pretty = T.pack . unFlagName

instance Pretty Version where
    pretty = T.pack . prettyShow

instance Pretty VersionSet where
    pretty = T.pack . prettyShow . VS.toVersionRange

instance Pretty a => Pretty (Term a) where
    pretty (Positive s) = pretty s
    pretty (Negative s) = T.pack "¬(" <> pretty s <> T.pack ")"

instance Pretty a => Pretty (Set a) where
    pretty s = T.pack "{" <> T.intercalate (T.pack ",") (map pretty (Set.toList s)) <> T.pack "}"
