module BootPackages (
    queryBootPackages,
)
where

import           Data.Map.Strict                (Map)
import           Distribution.Types.PackageName (PackageName)
import           Distribution.Version           (Version)
import           PubGrub.Cabal.Boot             (parseBootList)
import           System.Process                 (readProcess)

-- | Query the installed GHC global package db for boot-package versions.
queryBootPackages :: IO (Map PackageName Version)
queryBootPackages =
    parseBootList <$> readProcess "ghc-pkg" ["list", "--global", "--simple-output"] ""
