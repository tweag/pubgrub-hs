{- | Parse the output of @ghc-pkg list --global --simple-output@ into a map of
pinned boot-package versions.
-}
module PubGrub.Cabal.Boot (
    parseBootList,
) where

import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Data.Maybe                     (mapMaybe)

import           Distribution.Parsec            (eitherParsec)
import           Distribution.Types.PackageId   (PackageIdentifier (..))
import           Distribution.Types.PackageName (PackageName)
import           Distribution.Version           (Version, versionNumbers)

{- | Parse whitespace-separated @name-version@ tokens using Cabal-syntax's
'PackageIdentifier' parser. Tokens that fail to parse, or that carry no
version (e.g. a bare @rts@), are dropped.
-}
parseBootList :: String -> Map PackageName Version
parseBootList = Map.fromList . mapMaybe parseToken . words
  where
    parseToken tok = case eitherParsec tok of
        Right (PackageIdentifier n v)
            | not (null (versionNumbers v)) -> Just (n, v)
        _ -> Nothing
