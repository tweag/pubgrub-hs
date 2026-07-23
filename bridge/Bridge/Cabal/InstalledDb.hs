-- | Parse the output of @ghc-pkg dump@ into a flat list of installed packages.
-- Each record is an 'InstalledPackageInfo' in the @.conf@ field format; records
-- are separated by lines containing exactly @---@.
module Bridge.Cabal.InstalledDb (
    InstalledPkg (..),
    parseGhcPkgDump,
) where

import           Data.ByteString                   (ByteString)
import qualified Data.ByteString.Char8             as BS8
import qualified Data.List.NonEmpty                as NE
import           Distribution.InstalledPackageInfo (InstalledPackageInfo (..),
                                                    parseInstalledPackageInfo)
import           Distribution.Types.PackageId      (PackageIdentifier (..))
import           Distribution.Types.PackageName    (PackageName)
import           Distribution.Types.UnitId         (UnitId)
import           Distribution.Version              (Version)

data InstalledPkg = InstalledPkg
    { ipUnitId  :: UnitId
    , ipName    :: PackageName
    , ipVersion :: Version
    , ipDepends :: [UnitId]
    }
    deriving (Eq, Show)

-- | Blank records are skipped. The first record that fails to parse gives
-- 'Left' with its errors.
parseGhcPkgDump :: ByteString -> Either String [InstalledPkg]
parseGhcPkgDump = traverse parseRecord . filter (not . isBlank) . splitRecords
  where
    splitRecords =
        map BS8.unlines . wordsByLine (== BS8.pack "---") . BS8.lines
    isBlank = all (BS8.all (`elem` (" \t" :: String))) . BS8.lines
    parseRecord bs = case parseInstalledPackageInfo bs of
        Left errs -> Left (unlines (NE.toList errs))
        Right (_warnings, ipi) ->
            let PackageIdentifier n v = sourcePackageId ipi
             in Right (InstalledPkg (installedUnitId ipi) n v (depends ipi))

-- | Break a list of lines into groups delimited by lines satisfying @p@.
wordsByLine :: (a -> Bool) -> [a] -> [[a]]
wordsByLine p = foldr step [[]]
  where
    step x acc@(cur : rest)
        | p x = [] : acc
        | otherwise = (x : cur) : rest
    step _ [] = [[]] -- unreachable: acc is always non-empty
