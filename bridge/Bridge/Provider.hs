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

import           Bridge.Cabal.Flatten                         (GuardedDeps,
                                                               componentDeps,
                                                               depsAt)
import           Bridge.Cabal.InstalledPkg                    (getInstalledPackages)
import           Bridge.Hackage                               (IndexHandle (..),
                                                               ParseError,
                                                               withHackageIndex)
import           Bridge.Installed                             (InstalledDb (..),
                                                               installedInstancesOf,
                                                               mkInstalledDb,
                                                               toPreInstalled,
                                                               unitInstance)
import           Colog                                        (WithLog, logMsg)
import           Data.IORef                                   (atomicModifyIORef',
                                                               newIORef,
                                                               readIORef)
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
import           Distribution.Types.Flag                      (FlagAssignment,
                                                               FlagName,
                                                               PackageFlag (..),
                                                               mkFlagAssignment,
                                                               unFlagAssignment)
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
import           PubGrub.InstanceSet.SourceCell               (SourceCell (..),
                                                               assignmentFrom)

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
        let platform = fromMaybe buildPlatform mPlatform
            cInfo = compilerInfo compiler
        (readRelease, lookupStats) <- liftIO (releaseReader platform cInfo handle)
        let provider =
                Provider
                    ( mkExpand
                        (mkInstalledDb installed)
                        (\pn v -> liftIO (readRelease pn v))
                        handle
                        root
                    )
        result <- act provider
        (parsed, reused) <- liftIO lookupStats
        logMsg
            ( T.pack
                ( "read "
                    ++ show parsed
                    ++ " .cabal files, served "
                    ++ show reused
                    ++ " repeat lookups from cache"
                )
            )
        pure result

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

-- | What the provider needs from a release's description — and all it keeps.
--
-- Both components are independent of the flag assignment: the declared flags with
-- their defaults, and the dependencies as flag-guarded groups with the fixed
-- environment already resolved. So they are derived once per release and reused
-- for every assignment tried against it.
data Release = Release
    { relFlags   :: [(FlagName, Bool)]
    , relGuarded :: GuardedDeps
    }

-- | A memoising reader for 'Release', with a @(parsed, reused)@ count.
--
-- Do not memoise the 'GenericPackageDescription' instead. Retaining every
-- description a solve touches cost 27.2 s and 904 MB on @pandoc@, against
-- 3.7 s and 83 MB with no cache: each parse tree pins its slice of the index,
-- and every major collection copies that live data. A 'Release' is a few
-- hundred bytes and keeps nothing else alive.
--
-- The memo covers 'componentDeps' too, which walks the whole conditional tree
-- and depends only on the release and the environment. It is not measurably
-- faster, because a tar read and a parse are cheap next to the search. It is
-- here so that the repeat count can be seen, and so that splitting the
-- provider into pick and consequences would not read every candidate's
-- description twice (@docs\/flags-semantics.md@ §8).
--
-- Parse failures are cached too: a malformed description is a stable fact
-- about the index.
releaseReader
    :: Platform
    -> CompilerInfo
    -> IndexHandle
    -> IO (PackageName -> Version -> IO (Either ParseError Release), IO (Int, Int))
releaseReader platform cInfo handle = do
    ref <- newIORef (Map.empty, 0 :: Int, 0 :: Int)
    let readRelease pn v = do
            (entries, _, _) <- readIORef ref
            case Map.lookup (pn, v) entries of
                Just hit -> do
                    atomicModifyIORef' ref (\(es, p, reused) -> ((es, p, reused + 1), ()))
                    pure hit
                Nothing -> do
                    result <- fmap reduce <$> ihLookupGPD handle pn v
                    atomicModifyIORef' ref $ \(es, p, reused) ->
                        ((Map.insert (pn, v) result es, p + 1, reused), ())
                    pure result
        reduce gpd =
            Release
                { relFlags = [(flagName f, flagDefault f) | f <- genPackageFlags gpd]
                , relGuarded = componentDeps platform cInfo gpd
                }
    pure (readRelease, (\(_, p, reused) -> (p, reused)) <$> readIORef ref)

-- | The provider's @expand@.
mkExpand
    :: forall m env
     . (MonadIO m, WithLog env Text m)
    => InstalledDb
    -> (PackageName -> Version -> m (Either ParseError Release))
    -> IndexHandle
    -> [(PackageName, VersionSet)]
    -- ^ the synthetic root's targets, which are not in the index
    -> PackageName
    -> InstanceSet
    -> m (Maybe (Instance, [Incompatibility]))
mkExpand installedDb readRelease handle root = expand'
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
        let installedHere = [toPreInstalled u | u <- Map.findWithDefault [] pn (idbByName installedDb)]
            admissible = sortOn (Down . version) (filter (`Set.member` isInstalled range) installedHere)
        case listToMaybe admissible of
            Just chosen -> do
                incs <- consequencesOfUsePreInstalled pn chosen
                pure (Just (UsePreInstalled chosen, incs))
            Nothing -> firstUsable (sortOn Down (versionsOf pn))

                where
                    -- Releases newest first (@docs/flags-semantics.md@ §5,
                    -- between-releases half). One @.cabal@ read per release, not
                    -- per candidate assignment.
                    firstUsable [] = pure Nothing
                    firstUsable (v:rest) = do
                        result <- readRelease pn v
                        case result of
                            -- A .cabal that fails to parse: warn and skip. The
                            -- release then drops out of the universe the solve
                            -- runs over (§1.5), so the warning has to be visible.
                            -- If every release fails, the solver turns @Nothing@
                            -- into "no instances in range".
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
                                firstUsable rest
                            Right release ->
                                case listToMaybe (usableAssignments v release) of
                                    Nothing -> firstUsable rest
                                    Just flags ->
                                        -- The guards are evaluated at @flags@ — the
                                        -- same assignment the instance pins — so the
                                        -- decision and the incompatibilities it
                                        -- entails cannot disagree.
                                        let inst = BuildSource v flags
                                            deps = Map.toList (depsAt flags (relGuarded release))
                                        in pure (Just (inst, depIncs pn inst deps))

                    -- The assignments this release could be built under, in
                    -- preference order, keeping only those the offered set
                    -- admits. Each cell admitting @v@ contributes one assignment:
                    -- its pins, completed at the declared defaults. That finds a
                    -- member if the cell has one, because a cell constrains each
                    -- flag independently. It stops being enough once
                    -- admissibility depends on the assignment (@buildable: False@
                    -- under some flags): that is the open completeness obligation
                    -- O6 in @docs/flags-semantics.md@.
                    usableAssignments v release =
                        [ flags
                        | flags <- preferDefaults declared (map (assignmentFrom declared) cells)
                        , memberInstance (BuildSource v flags) range
                        ]
                      where
                        declared = relFlags release
                        cells =
                            filter (\c -> scVersionSet c `VersionSet.contains` v) (isSource range)

    -- | Candidate assignments in preference order, deduplicated: fewest
    -- deviations from the release's declared defaults first, then a deterministic
    -- tie-break on the assignment itself
    -- (@docs/flags-semantics.md@ §5, within-a-release half).
    --
    -- The cost is a property of the /completed assignment/, never of the cell it
    -- came from. Ranking cells by pin count instead looks equivalent and is not: a
    -- one-pin cell @f = False@ beats a two-pin @f = True, g = True@ on pin count,
    -- yet with both flags defaulting to True the second cell is the all-default
    -- assignment and the first is a deviation.
    preferDefaults :: [(FlagName, Bool)] -> [FlagAssignment] -> [FlagAssignment]
    preferDefaults declared =
        Map.elems . Map.fromList . map key
      where
        key fa = ((deviations fa, unFlagAssignment fa), fa)
        deviations fa =
            length [() | (f, b) <- unFlagAssignment fa, lookup f declared /= Just b]

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
