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
    , syntheticRoot
    ) where

import           Bridge.Cabal.InstalledPkg                (getInstalledPackages)
import           Bridge.Hackage                           (IndexHandle (..),
                                                           withHackageIndex)
import           Bridge.Installed                         (InstalledDb,
                                                           installedInstancesOf,
                                                           mkInstalledDb,
                                                           unitInstance)
import           Bridge.Instances                         (toSourcePackage)
import           Colog                                    (WithLog, logMsg)
import           Data.List                                (sortOn)
import qualified Data.List.NonEmpty                       as NE
import qualified Data.Map.Strict                          as Map
import           Data.Maybe                               (fromMaybe)
import           Data.Ord                                 (Down (..))
import qualified Data.Set                                 as Set
import           Data.Text                                (Text)
import qualified Data.Text                                as T
import           Distribution.Compiler                    (CompilerInfo)
import           Distribution.Pretty                      (prettyShow)
import           Distribution.Simple.Compiler             (compilerInfo)
import           Distribution.Simple.GHC                  (configure)
import           Distribution.Simple.Program.Db           (defaultProgramDb)
import           Distribution.System                      (Platform,
                                                           buildPlatform)
import           Distribution.Types.Condition             (Condition (..))
import           Distribution.Types.Flag                  (mkFlagAssignment)
import           Distribution.Types.PackageName           (PackageName,
                                                           mkPackageName)
import           Distribution.Types.Version               (Version, mkVersion)
import qualified Distribution.Verbosity                   as Verbosity
import           Hackage.Security.Client.Repository.Cache (Cache)
import           Network.HTTP.Client                      (Manager)
import           PubGrub.Incompatibility                  (Incompatibility,
                                                           fromDependency,
                                                           noInstances)
import           PubGrub.Index.PreInstalled               (PreInstalledPackage (..))
import           PubGrub.InstanceSet                      (HasVersion (..),
                                                           Instance (..),
                                                           InstanceSet (..),
                                                           memberInstance,
                                                           singletonInstance)
import           PubGrub.InstanceSet.SourceCell           (SourceCell (..))

import           PubGrub.Index.SourcePackage              (Dependency (..),
                                                           SourcePackage (..))
import           PubGrub.Provider                         (Provider (..))
import           PubGrub.VersionSet                       (VersionSet, contains)
import           UnliftIO                                 (MonadIO,
                                                           MonadUnliftIO,
                                                           liftIO)

-- | Open the Hackage index and the compiler's installed world, build a
-- 'Provider', and run @act@ with it. The whole solve must run inside @act@.
--
-- It takes the root instance ('syntheticRoot') because the solver asks the
-- provider to expand the root like any other package, and the root is not in
-- the index.
withProvider
    :: (MonadUnliftIO m, WithLog env Text m)
    => Cache -> Manager -> Instance -> (Provider m -> m a) -> m a
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

-- | Build the root instance from target constraints ("solve for these packages
-- in these ranges"). Its dependencies are baked in — it isn't in the index —
-- so 'mkExpand' reads them from the instance rather than looking them up. Pair
-- it with 'rootName' when calling 'PubGrub.Solver.solve'.
syntheticRoot :: [(PackageName, VersionSet)] -> Instance
syntheticRoot targets =
    BuildSource
        (SourcePackage (mkVersion [0]) [] [Dependency n vs (Lit True) | (n, vs) <- targets] (Lit True))
        (mkFlagAssignment [])

-- | A lightweight source instance: version only, no stored dependencies and
-- the default (empty) flag assignment. Dependencies are looked up on demand in
-- 'mkExpand', so enumerating a package's instances never parses a @.cabal@.
sourceInstance :: Version -> Instance
sourceInstance v = BuildSource (SourcePackage v [] [] (Lit True)) (mkFlagAssignment [])

-- | The provider's @expand@.
mkExpand
    :: (MonadIO m, WithLog env Text m)
    => InstalledDb
    -> Platform
    -> CompilerInfo
    -> IndexHandle
    -> Instance
    -- ^ the synthetic root instance, which is not in the index
    -> PackageName
    -> InstanceSet
    -> m (Maybe (Instance, [Incompatibility]))
mkExpand installedDb platform cInfo handle root = expand'
  where
    -- An 'InstanceSet' is a symbolic description (version ranges plus flag
    -- pins), not a container: membership is decidable but it cannot be
    -- enumerated. So enumerate the package's own instances — cheaply, from the
    -- installed db and the index's version map, without parsing any @.cabal@ —
    -- and keep those the offered set admits.
    expand' p range =
        case filter (`memberInstance` range) (universeOf p) of
            [] -> pure Nothing
            chosen : _ -> do
                incs <- consequencesOf p chosen
                pure (Just (chosen, incs))

    -- Candidates for @p@, best first: installed units newest first, then source
    -- releases newest first. Ordering within each group rather than by version
    -- overall keeps the installed world pinned: Hackage can carry a newer
    -- @base@ than the compiler's own, and the compiler cannot build it.
    universeOf p
        | p == rootName = [root]
        | otherwise =
             sortOn (Down . version) (installedInstancesOf installedDb p)
                ++ sortOn (Down . version) (map sourceInstance (versionsOf p))

    consequencesOf p chosen = case chosen of
        -- Installed unit: its dependencies name exact units, each pinning its
        -- package to that one instance.
        UsePreInstalled pip ->
            pure
                [ fromDependency p (singletonInstance chosen) (depName, singletonInstance depInst)
                | uid <- pipDependencies pip
                , Just (depName, depInst) <- [unitInstance installedDb uid]
                ]
        -- Synthetic root: dependencies are baked into the instance.
        BuildSource sp _
            | p == rootName -> pure (depIncs p chosen (sourcePackageDeps sp))
        -- Source release: read and flatten its .cabal on demand.
        BuildSource _ _ -> do
            result <- liftIO (ihLookupGPD handle p (version chosen))
            case result of
                Right gpd ->
                    pure (depIncs p chosen (sourcePackageDeps (toSourcePackage platform cInfo gpd)))
                -- A .cabal that fails to parse: warn, and ban just this
                -- instance so the solver backtracks to another version.
                Left err -> do
                    logMsg
                        ( T.pack
                            ( "warning: ignoring "
                                ++ prettyShow p
                                ++ "-"
                                ++ prettyShow (version chosen)
                                ++ " (unparseable .cabal: "
                                ++ show err
                                ++ ")"
                            )
                        )
                    pure [noInstances p (singletonInstance chosen)]

    depIncs :: PackageName -> Instance -> [(PackageName, VersionSet)] -> [Incompatibility]
    depIncs p chosen deps =
        [ fromDependency p (singletonInstance chosen) (d, widen d vs)
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

-- | The (name, range) dependencies of a source package. Their conditions are
-- ignored: 'toSourcePackage' makes every dependency unconditional.
sourcePackageDeps :: SourcePackage -> [(PackageName, VersionSet)]
sourcePackageDeps sp = [(d, vs) | Dependency d vs _ <- spDependencies sp]
