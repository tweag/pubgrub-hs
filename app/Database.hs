{-# LANGUAGE GADTs               #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Database where

import           Data.List.NonEmpty              (NonEmpty)
import           Data.Maybe                      (maybeToList)

import           Data.Map                        (Map)
import qualified Data.Map.Strict                 as M

import           Control.Exception               (SomeException)
import qualified Data.ByteString.Lazy            as BSL
import           Distribution.Fields
import           Distribution.PackageDescription
import qualified Distribution.Types.Lens         as L
import           Distribution.Version            (Version)
import           Hackage.Security.Client         (Directory (..),
                                                  DirectoryEntry,
                                                  IndexCallbacks (..),
                                                  IndexEntry (..),
                                                  IndexFile (..),
                                                  uncheckClientErrors)
import           Hackage.Security.Util.Some      (Some (..))

type Result e a = Either (Either SomeException e) a

data ParseError
    = ParseError (Maybe Version) (NonEmpty PError)
    | ParseException SomeException
    deriving Show

-- | The index as package -> version -> directory entry, in one pure pass. The
-- name and version come from the decoded 'IndexPkgCabal', so no .cabal file or
-- path is parsed.
indexEntries :: IndexCallbacks -> Map PackageName (Map Version DirectoryEntry)
indexEntries IndexCallbacks{indexDirectory} =
    M.fromListWith (<>)
        [ (pkgName pkgId, M.singleton (pkgVersion pkgId) entry)
        | (entry, _indexPath, msIndexFile) <- directoryEntries indexDirectory
        , Just (Some (IndexPkgCabal pkgId)) <- [msIndexFile]
        ]

-- | Parse a single index entry's .cabal on demand.
parseEntry
    :: IndexCallbacks
    -> (BSL.ByteString -> Either e a)
    -> DirectoryEntry
    -> IO (Either e a)
parseEntry IndexCallbacks{indexLookupEntry} parse entry = do
    (Some indexEntry, _) <- uncheckClientErrors $ indexLookupEntry entry
    return $ parse (indexEntryContent indexEntry)

-- Unused. Kept for the conditional-dependency work (flags, OS, architecture).
newtype DepInfo = DepInfo (Map ComponentName (CondTree ConfVar [Dependency] ()))

extractDepInfo :: GenericPackageDescription -> DepInfo
extractDepInfo gpd =
    DepInfo $
        M.fromList $
            [(CLibName LMainLibName, f tree) | tree <- maybeToList (condLibrary gpd)]
                <> [(CLibName (LSubLibName ucn), f tree) | (ucn, tree) <- condSubLibraries gpd]
                <> [(CFLibName ucn, f tree) | (ucn, tree) <- condForeignLibs gpd]
                <> [(CExeName ucn, f tree) | (ucn, tree) <- condExecutables gpd]
                <> [(CTestName ucn, f tree) | (ucn, tree) <- condTestSuites gpd]
                <> [(CBenchName ucn, f tree) | (ucn, tree) <- condBenchmarks gpd]
  where
    f :: L.HasBuildInfo a => CondTree v c a -> CondTree v c ()
    f = mapTreeData (const ())
