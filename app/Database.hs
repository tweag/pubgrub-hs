{-# LANGUAGE GADTs               #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Database where

import           Control.Exception               (SomeException)
import           Data.List.NonEmpty              (NonEmpty)
import           Data.Map                        (Map)
import qualified Data.Map.Strict                 as M
import           Data.Maybe                      (maybeToList)
import           Distribution.Fields
import           Distribution.PackageDescription
import qualified Distribution.Types.Lens         as L
import           Distribution.Version            (Version)

type Result e a = Either (Either SomeException e) a

data ParseError
    = ParseError (Maybe Version) (NonEmpty PError)
    | ParseException SomeException
    deriving Show

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
