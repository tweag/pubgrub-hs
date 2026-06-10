-- | Parse the output of @ghc-pkg list --global --simple-output@ into a map of
-- pinned boot-package versions.
module PubGrub.Cabal.Boot
  ( parseBootList
  ) where

import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Data.Maybe                     (mapMaybe)
import           Text.Read                      (readMaybe)

import           Distribution.Types.PackageName (PackageName, mkPackageName)
import           Distribution.Version           (Version, mkVersion)

-- | Parse whitespace-separated @name-version@ tokens.
parseBootList :: String -> Map PackageName Version
parseBootList = Map.fromList . mapMaybe parseToken . words

-- | Split a @name-1.2.3@ token: the version is the final hyphen-segment that
-- parses as a dotted integer version; the rest (rejoined with @-@) is the name.
parseToken :: String -> Maybe (PackageName, Version)
parseToken tok =
  case reverse (splitOn '-' tok) of
    (vstr : nameSegsRev)
      | not (null nameSegsRev)
      , Just ver <- parseVersion vstr ->
          Just (mkPackageName (intercalateHyphen (reverse nameSegsRev)), ver)
    _ -> Nothing

parseVersion :: String -> Maybe Version
parseVersion s =
  case traverse (readMaybe :: String -> Maybe Int) (splitOn '.' s) of
    Just ns@(_ : _) -> Just (mkVersion ns)
    _               -> Nothing

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (a, [])       -> [a]
  (a, _ : rest) -> a : splitOn c rest

intercalateHyphen :: [String] -> String
intercalateHyphen []       = ""
intercalateHyphen [x]      = x
intercalateHyphen (x : xs) = x ++ "-" ++ intercalateHyphen xs
