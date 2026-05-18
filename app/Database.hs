{-# LANGUAGE DerivingStrategies  #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Database where

import           Data.List.NonEmpty              (NonEmpty)
import           Data.Maybe                      (maybeToList)
import           GHC.Generics                    (Generic)

import           Data.Map                        (Map)
import qualified Data.Map.Strict                 as M

import           Control.Concurrent.STM          (atomically)
import           Control.Concurrent.STM.TMVar
import           Control.Concurrent.STM.TVar
import           Control.Exception               (SomeException, try)
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

newtype Index a = Index (Map PackageName (Map Version a))
    deriving (Eq, Generic, Show)

data Entry e a
    = NotStarted DirectoryEntry
    | InProgress !(TMVar (Result e a))
    | Done !(Result e a)

type Database e a = Index (TVar (Entry e a))


type Result e a = Either (Either SomeException e) a

data ParseError
    = ParseError (Maybe Version) (NonEmpty PError)
    | ParseException SomeException
    deriving Show

mkDatabase
    :: forall e a
     . IndexCallbacks
    -> (BSL.ByteString -> Either e a)
    -> IO (PackageIdentifier -> IO (Result e a))
mkDatabase IndexCallbacks{indexLookupEntry, indexDirectory} parse = do
    db <-
        traverseIndex newTVarIO $
            Index $
                M.fromListWith
                    (<>)
                    [ (pkgName pkgId, M.singleton (pkgVersion pkgId) (NotStarted entry))
                    | (entry, _indexPath, msIndexFile) <- directoryEntries indexDirectory
                    , Just (Some (IndexPkgCabal pkgId)) <- [msIndexFile]
                    ]

    return $ getOrParse db
  where
    getOrParse
        :: Database e a
        -> PackageIdentifier
        -> IO (Result e a)
    getOrParse db pkgId = do
        entVar <- lookupEntryVar pkgId db -- IO fail or return error if missing
        decision <- atomically $ do
            st <- readTVar entVar
            case st of
                Done r -> pure (Ready r)
                InProgress p -> pure (Follow p)
                NotStarted entry -> do
                    p <- newEmptyTMVar
                    writeTVar entVar (InProgress p)
                    pure (Win entry p)

        case decision of
            Ready r -> pure r
            Follow p -> atomically (readTMVar p)
            Win entry p -> do
                er <- try (parseIO entry) :: IO (Either SomeException (Either e a))
                let r = case er of
                        Left ex         -> Left (Left ex) -- your ParseError wrapper
                        Right (Left pe) -> Left (Right pe)
                        Right (Right a) -> Right a
                atomically $ do
                    writeTVar entVar (Done r)
                    putTMVar p r
                pure r

    parseIO :: DirectoryEntry -> IO (Either e a)
    parseIO entry = do
        (Some indexEntry, _) <- uncheckClientErrors $ indexLookupEntry entry
        return $ parse (indexEntryContent indexEntry)

traverseIndex :: Applicative f => (a -> f b) -> Index a -> f (Index b)
traverseIndex f (Index m) =
    Index <$> traverse (traverse f) m

data Decision e a
    = Ready (Either e a)
    | Follow (TMVar (Either e a))
    | Win DirectoryEntry (TMVar (Either e a))

lookupEntryVar
    :: PackageIdentifier
    -> Database e a
    -> IO (TVar (Entry e a))
lookupEntryVar pkgId (Index m) =
    case M.lookup (pkgName pkgId) m >>= M.lookup (pkgVersion pkgId) of
        Just v  -> pure v
        Nothing -> fail "Package/version not found in index"

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
