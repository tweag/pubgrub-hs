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
-- 'ihLookupGPD' is valid only while the index bracket is open, so a
-- 'Provider' from 'mkProvider' must be used inside 'withHackageIndex'.
module Bridge.Provider
    ( mkProvider
    , rootName
    , syntheticRoot
    ) where

import           Bridge.Compiler                (Compiler (..))
import           Bridge.Hackage                 (IndexHandle (..))
import           Bridge.Installed               (installedInstancesOf,
                                                 mkInstalledDb, unitInstance)
import           Bridge.Instances               (toSourcePackage)
import           Colog                          (WithLog, logMsg)
import           Data.List                      (maximumBy)
import qualified Data.List.NonEmpty             as NE
import qualified Data.Map.Strict                as Map
import           Data.Ord                       (comparing)
import qualified Data.Set                       as Set
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Distribution.Pretty            (prettyShow)
import           Distribution.System            (Platform)
import           Distribution.Types.Condition   (Condition (..))
import           Distribution.Types.Flag        (mkFlagAssignment)
import           Distribution.Types.PackageName (PackageName, mkPackageName)
import           Distribution.Types.Version     (Version, mkVersion)
import           PubGrub.Incompatibility        (Incompatibility,
                                                 fromDependency, noInstances)
import           PubGrub.InstanceSet            (Dependency (..),
                                                 HasVersion (..), Instance (..),
                                                 InstanceSet (..),
                                                 PreInstalledPackage (..),
                                                 SourcePackage (..),
                                                 singletonInstance)
import           PubGrub.Provider               (Provider (..))
import           PubGrub.VersionSet             (VersionSet, contains)
import           UnliftIO                       (MonadIO, liftIO)

-- | The synthetic root package name, chosen so it cannot collide with a real
-- Hackage package.
rootName :: PackageName
rootName = mkPackageName "\0root"

-- | Build the root instance from target constraints ("solve for these packages
-- in these ranges"). Its dependencies are baked in — it isn't in the index —
-- so 'mkProvider' reads them from the instance rather than looking them up.
-- Pair it with 'rootName' when calling 'PubGrub.Solver.solve'.
syntheticRoot :: [(PackageName, VersionSet)] -> Instance
syntheticRoot targets =
    BuildSource
        (SourcePackage (mkVersion [0]) [] [Dependency n vs (Lit True) | (n, vs) <- targets] (Lit True))
        (mkFlagAssignment [])

-- | A lightweight source instance: version only, no stored dependencies and
-- the default (empty) flag assignment. Dependencies are looked up on demand in
-- 'mkProvider', so enumerating a package's instances never parses a @.cabal@.
sourceInstance :: Version -> Instance
sourceInstance v = BuildSource (SourcePackage v [] [] (Lit True)) (mkFlagAssignment [])

-- | A 'Provider' backed by a Hackage 'IndexHandle' and the compiler's
-- installed package database. It reads the index, so it must be used inside
-- the 'withHackageIndex' bracket.
mkProvider
    :: (MonadIO m, WithLog env Text m)
    => Compiler -> Platform -> IndexHandle -> Provider m
mkProvider compiler platform handle = Provider expand'
  where
    installedDb = mkInstalledDb (installedPackages compiler)
    cInfo = compilerInfo compiler

    expand' p (InstanceSet s)
        | Set.null s = pure Nothing
        | otherwise = do
            let chosen = preferInstalled (Set.toList s)
            incs <- consequencesOf p chosen
            pure (Just (chosen, incs))

    preferInstalled instances =
        case [i | i@(UsePreInstalled _) <- instances] of
            []        -> maximumBy (comparing version) instances
            installed -> maximumBy (comparing version) installed

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

    -- Widen a dependency's version range into the set of that package's
    -- instances in range: installed units (from the db) plus source releases
    -- (from the in-memory version map, no .cabal parsing).
    widen d vs =
        InstanceSet
            ( Set.fromList
                ( [i | i <- installedInstancesOf installedDb d, contains vs (version i)]
                    ++ [sourceInstance v | v <- versionsOf d, contains vs v]
                )
            )

    versionsOf d = maybe [] NE.toList (Map.lookup d (ihVersions handle))

-- | The (name, range) dependencies of a source package. Their conditions are
-- ignored: 'toSourcePackage' makes every dependency unconditional.
sourcePackageDeps :: SourcePackage -> [(PackageName, VersionSet)]
sourcePackageDeps sp = [(d, vs) | Dependency d vs _ <- spDependencies sp]
