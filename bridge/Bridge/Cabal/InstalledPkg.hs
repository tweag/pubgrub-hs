-- | The installed packages of the compiler's global package database, read
-- through Cabal's own 'Cabal.getInstalledPackages' and reduced to what the
-- solver uses: each unit's id, name, version and dependencies.
module Bridge.Cabal.InstalledPkg
    ( InstalledPkg (..)
    , getInstalledPackages
    , getInstalledPackageIndex
    , reduceIndex
    ) where

import           Distribution.Simple.Compiler            (Compiler,
                                                          PackageDBX (..))
import qualified Distribution.Simple.GHC                 as Cabal
import           Distribution.Simple.PackageIndex        (InstalledPackageIndex,
                                                          allPackages)
import           Distribution.Simple.Program.Db          (ProgramDb)
import           Distribution.Types.InstalledPackageInfo (InstalledPackageInfo (..))
import           Distribution.Types.PackageId            (PackageIdentifier (..))
import           PubGrub.Cabal.Installed                 (InstalledPkg (..))
import           Distribution.Verbosity                  (Verbosity)


getInstalledPackages :: Verbosity -> Compiler -> ProgramDb -> IO [InstalledPkg]
getInstalledPackages verbosity compiler programDb =
    reduceIndex <$> getInstalledPackageIndex verbosity compiler programDb

-- | Keep only what our solver models: a unit's id, name, version and direct
-- dependencies. The cabal baseline takes the whole index instead, so the db is
-- read once and this reduction is applied to that one read.
reduceIndex :: InstalledPackageIndex -> [InstalledPkg]
reduceIndex iidx =
    [ InstalledPkg (installedUnitId ipi) n v (depends ipi)
    | ipi <- allPackages iidx
    , let PackageIdentifier n v = sourcePackageId ipi
    ]

-- | The global package db as Cabal's own index, unreduced.
--
-- The cabal baseline ('Bridge.Cabal.Baseline') needs the whole
-- 'InstalledPackageIndex', because that is what its resolver takes, and both
-- solvers must see the /same/ db. So the db is read once, here, and
-- 'reduceIndex' cuts it down for our solver.
getInstalledPackageIndex :: Verbosity -> Compiler -> ProgramDb -> IO InstalledPackageIndex
getInstalledPackageIndex verbosity compiler programDb =
    Cabal.getInstalledPackages verbosity compiler Nothing [GlobalPackageDB] programDb
