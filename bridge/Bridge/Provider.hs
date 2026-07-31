-- | The real 'Provider', backed by a Hackage 'IndexHandle' and the compiler's
-- installed (boot) package database.
--
-- A package's instances are its installed units ('UsePreInstalled') and its
-- Hackage source releases. Installed units are strictly preferred: if the
-- range admits one, the provider commits to the newest such and pins its
-- dependencies to their exact installed units. Otherwise it picks the newest
-- source release and reads its dependencies from its @.cabal@, widened to the
-- instances in range, installed and source.
--
-- 'withProvider' is the entry point: it opens the index, resolves the compiler
-- and installed packages, and runs an action with the 'Provider'. The provider
-- is valid only during that action, because its @.cabal@ reads go through the
-- open index bracket.
module Bridge.Provider
    ( withProvider
    , rootName
    , rootInstance
    ) where

import           Bridge.Cabal.Flatten                         (flattenDeps)
import           Bridge.Cabal.InstalledPkg                    (getInstalledPackages)
import           Bridge.Hackage                               (IndexHandle (..),
                                                               withHackageIndex)
import           Bridge.Installed                             (InstalledDb (..),
                                                               installedInstancesOf,
                                                               mkInstalledDb,
                                                               toPreInstalled,
                                                               unitInstance)
import           Colog                                        (WithLog, logMsg)
import           Data.List                                    (sortOn)
import qualified Data.List.NonEmpty                           as NE
import qualified Data.Map.Strict                              as Map
import           Data.Maybe                                   (fromMaybe,
                                                               listToMaybe)
import           Data.Ord                                     (Down (..))
import qualified Data.Set                                     as Set
import           Data.Text                                    (Text)
import qualified Data.Text                                    as T
import           Distribution.Compiler                        (CompilerInfo)
import           Distribution.Pretty                          (prettyShow)
import           Distribution.Simple.Compiler                 (compilerInfo)
import           Distribution.Simple.GHC                      (configure)
import           Distribution.Simple.Program.Db               (defaultProgramDb)
import           Distribution.System                          (Platform,
                                                               buildPlatform)
import           Distribution.Types.Flag                      (PackageFlag (..),
                                                               mkFlagAssignment)
import           Distribution.Types.PackageName               (PackageName,
                                                               mkPackageName)
import           Distribution.Types.Version                   (Version,
                                                               mkVersion)
import qualified Distribution.Verbosity                       as Verbosity
import           Hackage.Security.Client.Repository.Cache     (Cache)
import           Network.HTTP.Client                          (Manager)
import           PubGrub.Incompatibility                      (Incompatibility,
                                                               fromDependency)
import           PubGrub.Index.PreInstalled                   (PreInstalledPackage (..))
import           PubGrub.InstanceSet                          (HasVersion (..),
                                                               Instance (..),
                                                               InstanceSet (..),
                                                               memberInstance,
                                                               singletonInstance,
                                                               singletonUsePreInstalled)
import           PubGrub.InstanceSet.SourceCell               (SourceCell (..))

import           Distribution.Types.GenericPackageDescription (GenericPackageDescription (..))
import           PubGrub.Provider                             (Provider (..))
import           PubGrub.VersionSet                           (VersionSet,
                                                               contains)
import qualified PubGrub.VersionSet                           as VersionSet
import           UnliftIO                                     (MonadIO,
                                                               MonadUnliftIO,
                                                               liftIO)

-- | Open the Hackage index and the compiler's installed world, build a
-- 'Provider', and run @act@ with it. The whole solve must run inside @act@.
--
-- It takes the root's target constraints ("solve for these packages in these
-- ranges") because the solver asks the provider to expand the root like any
-- other package, and the root has no index entry to read its dependencies
-- from.
withProvider
    :: (MonadUnliftIO m, WithLog env Text m)
    => Cache -> Manager -> [(PackageName, VersionSet)] -> (Provider m -> m a) -> m a
withProvider cache manager root act =
    withHackageIndex cache manager $ \handle -> do
        (compiler, mPlatform, programDb) <-
            liftIO $ configure Verbosity.normal Nothing Nothing defaultProgramDb
        installed <- liftIO $ getInstalledPackages Verbosity.normal compiler programDb
        let provider =
                Provider
                    ( mkExpand
                        (mkInstalledDb installed)
                        (fromMaybe buildPlatform mPlatform)
                        (compilerInfo compiler)
                        handle
                        root
                    )
        act provider

-- | The synthetic root package name, chosen so it cannot collide with a real
-- Hackage package.
rootName :: PackageName
rootName = mkPackageName "\0root"

-- | The synthetic root's sole instance. Pair it with 'rootName' when calling
-- 'PubGrub.Solver.solve'.
rootInstance :: Instance
rootInstance = sourceInstance (mkVersion [0])

-- | A source instance: a version under the default (empty) flag assignment.
sourceInstance :: Version -> Instance
sourceInstance v = BuildSource v (mkFlagAssignment [])

-- | The provider's @expand@.
mkExpand
    :: forall m env
     . (MonadIO m, WithLog env Text m)
    => InstalledDb
    -> Platform
    -> CompilerInfo
    -> IndexHandle
    -> [(PackageName, VersionSet)]
    -- ^ the synthetic root's targets, which are not in the index
    -> PackageName
    -> InstanceSet
    -> m (Maybe (Instance, [Incompatibility]))
mkExpand installedDb platform cInfo handle root = expand'
  where
    -- An 'InstanceSet' is a symbolic description (version ranges plus flag
    -- pins), not a container: membership is decidable but it cannot be
    -- enumerated. So walk the package's own candidates, installed units first
    -- and then source (version, cell) pairs newest first, and commit to the
    -- first the offered set admits. A source candidate's @.cabal@ is parsed
    -- only when it is tried.
    expand' :: PackageName -> InstanceSet -> m (Maybe (Instance, [Incompatibility]))
    expand' pn range
            | pn == rootName
            , memberInstance rootInstance range
            = let incs = depIncs pn rootInstance root
            in pure (Just (rootInstance, incs))
    expand' pn range = do
        let installed = [toPreInstalled u | u <- Map.findWithDefault [] pn (idbByName installedDb)]
            filtered = filter (`Set.member` isInstalled range) installed
            sorted = sortOn (Down . version) filtered
        case listToMaybe sorted of
            Just chosen -> do
                incs <- consequencesOfUsePreInstalled pn chosen
                pure (Just (UsePreInstalled chosen, incs))
            Nothing -> go filtered

                where
                    filtered = [ (v, cell)
                        | v <- sortOn Down (versionsOf pn)
                        , cell <- filter (\c -> scVersionSet c `VersionSet.contains` v) (isSource range)
                        ]

                    go [] = pure Nothing
                    go ((v, sc):rest) = do
                        -- Source release: read and flatten its .cabal on demand.
                        result <- liftIO (ihLookupGPD handle pn v)
                        case result of
                            -- A .cabal that fails to parse: warn and skip the
                            -- version. If every candidate fails, the solver
                            -- reports that no instance is left.
                            Left err -> do
                                logMsg
                                    ( T.pack
                                        ( "warning: ignoring "
                                            ++ prettyShow pn
                                            ++ "-"
                                            ++ prettyShow v
                                            ++ " (unparseable .cabal: "
                                            ++ show err
                                            ++ ")"
                                        )
                                    )
                                go rest
                            Right gpd -> do
                                let packageFlags = genPackageFlags gpd
                                    flags = mkFlagAssignment
                                        [ (flagName f, Map.findWithDefault (flagDefault f) (flagName f) (scFlags sc))
                                        | f <- packageFlags ]
                                    inst = BuildSource v flags
                                if memberInstance inst range
                                -- The guards are evaluated at @flags@ — the same
                                -- assignment @inst@ pins — so the decision and the
                                -- incompatibilities it entails cannot disagree.
                                then let incs = depIncs pn inst (Map.toList (flattenDeps platform cInfo flags gpd))
                                     in pure $ Just (inst, incs)
                                else
                                    go rest

    consequencesOfUsePreInstalled pn pip =
            pure
                [ fromDependency pn (singletonUsePreInstalled pip) (depName, singletonInstance depInst)
                | uid <- pipDependencies pip
                , Just (depName, depInst) <- [unitInstance installedDb uid]
                ]

    depIncs :: PackageName -> Instance -> [(PackageName, VersionSet)] -> [Incompatibility]
    depIncs pn chosen deps =
        [ fromDependency pn (singletonInstance chosen) (d, widen d vs)
        | (d, vs) <- deps
        ]

    -- Widen a dependency's version range into an instance set. The installed
    -- half is extensional: the compiler's database is small and fully known.
    -- The source half is a single cell carrying the declared range, not one
    -- entry per version in range. That keeps the cell count per dependency
    -- constant, which matters because 'difference' multiplies cell counts, and
    -- it keeps the range in the incompatibility, so a conflict report can say
    -- @>=1.0 && <2@ instead of listing versions.
    --
    -- The cell admits versions the index does not have. That is harmless: the
    -- set algebra never needs the instance universe, and 'expand'' enumerates
    -- candidates from the index, so an unsatisfiable dependency surfaces as
    -- @Nothing@ from 'expand'' rather than as an empty widening.
    widen d vs =
        InstanceSet
            { isInstalled =
                Set.fromList
                    [ pip
                    | UsePreInstalled pip <- installedInstancesOf installedDb d
                    , contains vs (version pip)
                    ]
            , isSource = [SourceCell vs Map.empty]
            }

    versionsOf d = maybe [] NE.toList (Map.lookup d (ihVersions handle))
