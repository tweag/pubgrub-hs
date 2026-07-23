-- | The installed packages of the compiler's global package database, read
-- through Cabal's own 'Cabal.getInstalledPackages' and reduced to what the
-- solver uses: each unit's id, name, version and dependencies.
module Bridge.Cabal.InstalledPkg
    ( InstalledPkg (..)
    , getInstalledPackages
    ) where

import           Distribution.Simple.Compiler            (Compiler,
                                                          PackageDBX (..))
import qualified Distribution.Simple.GHC                 as Cabal
import           Distribution.Simple.PackageIndex        (allPackages)
import           Distribution.Simple.Program.Db          (ProgramDb)
import           Distribution.Types.InstalledPackageInfo (InstalledPackageInfo (..))
import           Distribution.Types.PackageId            (PackageIdentifier (..))
import           Distribution.Types.PackageName          (PackageName)
import           Distribution.Types.UnitId               (UnitId)
import           Distribution.Verbosity                  (Verbosity)
import           Distribution.Version                    (Version)

data InstalledPkg = InstalledPkg
    { ipUnitId  :: UnitId
    , ipName    :: PackageName
    , ipVersion :: Version
    , ipDepends :: [UnitId]
    }
    deriving (Eq, Show)

getInstalledPackages :: Verbosity -> Compiler -> ProgramDb -> IO [InstalledPkg]
getInstalledPackages verbosity compiler programDb = do
    iidx <- Cabal.getInstalledPackages verbosity compiler Nothing [GlobalPackageDB] programDb
    return [ InstalledPkg (installedUnitId ipi) n v (depends ipi)
            | ipi <- allPackages iidx
            , let PackageIdentifier n v = sourcePackageId ipi
            ]
