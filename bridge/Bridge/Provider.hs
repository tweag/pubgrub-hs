-- | The real 'Provider', backed by a Hackage 'IndexHandle' and the compiler's
-- installed (boot) package database.
--
-- A package's instances are its installed units ('UsePreInstalled') and its
-- Hackage source releases. Installed units are strictly preferred: if the
-- range admits one, the provider commits to the newest such and pins its whole
-- transitive closure to the exact units it was built against. Otherwise it
-- picks the newest source release and reads its dependencies from its
-- @.cabal@, widened to the instances in range, installed and source.
--
-- 'withProvider' is the entry point: it opens the index, resolves the compiler
-- and installed packages, and runs an action with the 'Provider'. The provider
-- is valid only during that action, because its @.cabal@ reads go through the
-- open index bracket.
module Bridge.Provider
    ( withProvider
    , withWorld
    , World (..)
    , rootName
    , rootInstance

      -- * The provider rule, independently of where releases come from
      --
      -- | 'mkExpand' is the whole candidate-selection and emission rule, and it
      -- takes its world as arguments: an installed db, a 'ReleaseSource', and the
      -- root's targets. So @test\/FlagSolveSpec.hs@ runs the real rule over an
      -- in-memory world rather than a copy of it.
    , mkExpand
    , ReleaseSource (..)
    , Release (..)
    ) where

import           Bridge.Cabal.Flatten                         (GuardedDeps,
                                                               buildableAtDefaults,
                                                               componentDepsAtDefaults,
                                                               expandGuard)
import           Bridge.Cabal.InstalledPkg                    (getInstalledPackageIndex,
                                                               reduceIndex)
import           Bridge.Hackage                               (IndexHandle (..),
                                                               ParseError,
                                                               withHackageIndex)
import           Bridge.Installed                             (InstalledDb (..),
                                                               isNonReinstallable,
                                                               InstalledEdge (..),
                                                               closureEdges,
                                                               installedInstancesOf,
                                                               mkInstalledDb,
                                                               toPreInstalled)
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
import           Data.Set                                     (Set)
import qualified Data.Set                                     as Set
import           Data.Text                                    (Text)
import qualified Data.Text                                    as T
import           Distribution.Compiler                        (CompilerInfo)
import           Distribution.Pretty                          (prettyShow)
import           Distribution.Simple.Compiler                 (compilerInfo)
import           Distribution.Simple.GHC                      (configure)
import           Distribution.Simple.PackageIndex             (InstalledPackageIndex)
import           Distribution.Solver.Types.PkgConfigDb        (PkgConfigDb,
                                                               readPkgConfigDb)
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
                                                               singletonUsePreInstalled,
                                                               sourceInstances)
import           PubGrub.InstanceSet.SourceCell               (SourceCell (..),
                                                               assignmentFrom)

import           Distribution.Types.Dependency                (depPkgName,
                                                               depVerRange)
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
    withWorld cache manager $ \world -> do
        let handle = wIndex world
            platform = wPlatform world
            cInfo = wCompiler world
            installed = reduceIndex (wInstalled world)
        (readRelease, lookupStats) <-
            liftIO (releaseReader platform cInfo (wPkgConfig world) handle)
        let provider =
                Provider
                    ( mkExpand
                        (mkInstalledDb installed)
                        ReleaseSource
                            { rsVersionsOf = \pn ->
                                Map.findWithDefault Set.empty pn (ihVersions handle)
                            , rsReadRelease = \pn v -> liftIO (readRelease pn v)
                            }
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

-- | Everything a solve needs to be run against: the open index, and the compiler
-- world its results are relative to.
--
-- It exists so that the two solvers can be driven from __one__ of each. Both take
-- an installed db and a set of source releases, and if either got its own the
-- comparison between them would include the difference between two reads (see
-- @Bridge.Cabal.Baseline@).
data World = World
    { wIndex     :: IndexHandle
    -- ^ open, and only valid inside 'withWorld'
    , wPlatform  :: Platform
    , wCompiler  :: CompilerInfo
    , wInstalled :: InstalledPackageIndex
    -- ^ the global db as Cabal models it; 'reduceIndex' cuts it down to what our
    -- own solver uses
    , wPkgConfig :: Maybe PkgConfigDb
    -- ^ what @pkg-config@ on this machine reports, for the @pkgconfig-depends@
    -- both solvers validate: cabal in its own validation phase, ours through
    -- 'Bridge.Cabal.Flatten.buildableCondition'.
    --
    -- 'Nothing' would not mean "ignore them": cabal reads it as /no pkg-config
    -- executable was found/ and rejects every @pkgconfig-depends@. That made cabal
    -- reject @zlib +pkg-config@ and flip @zlib@\'s automatic @pkg-config@ flag
    -- instead, on 9 of 29 popular targets.
    --
    -- What each solver does with an unsatisfiable @pkgconfig-depends@ still
    -- differs: cabal rules out that branch of the flag tree, while we drop the
    -- release from the candidate list without stating why (see 'relBuildable').
    }

-- | Open the index and resolve the compiler world, then run @act@. The index
-- bracket closes on the way out, so nothing that reads a @.cabal@ lazily may
-- escape.
withWorld
    :: (MonadUnliftIO m, WithLog env Text m)
    => Cache -> Manager -> (World -> m a) -> m a
withWorld cache manager act =
    withHackageIndex cache manager $ \handle -> do
        (compiler, mPlatform, programDb) <-
            liftIO $ configure Verbosity.normal Nothing Nothing defaultProgramDb
        installedIndex <- liftIO $ getInstalledPackageIndex Verbosity.normal compiler programDb
        pkgConfig <- liftIO $ readPkgConfigDb Verbosity.normal programDb
        act
            World
                { wIndex = handle
                , wPlatform = fromMaybe buildPlatform mPlatform
                , wCompiler = compilerInfo compiler
                , wInstalled = installedIndex
                , wPkgConfig = pkgConfig
                }

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
    { relFlags     :: [(FlagName, Bool)]
    , relGuarded   :: GuardedDeps
    , relBuildable :: Bool
    -- ^ whether this release's library can be built here at all: @buildable@ and
    -- @pkgconfig-depends@ resolved against the machine, at the declared flag
    -- defaults (@Bridge.Cabal.Flatten.buildableAtDefaults@). A 'Bool' because
    -- flags are fixed at their defaults; searching flags will need the condition
    -- itself, which 'Bridge.Cabal.Flatten.buildableCondition' returns.
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
    -> Maybe PkgConfigDb
    -> IndexHandle
    -> IO (PackageName -> Version -> IO (Either ParseError Release), IO (Int, Int))
releaseReader platform cInfo pkgConfig handle = do
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
                , relGuarded = componentDepsAtDefaults platform cInfo gpd
                , relBuildable = buildableAtDefaults pkgConfig platform cInfo gpd
                }
    pure (readRelease, (\(_, p, reused) -> (p, reused)) <$> readIORef ref)

-- | Where a package's /source releases/ come from: which versions exist, and
-- how to read one. These are the only two questions 'mkExpand' asks about the
-- source side, so the same rule runs over Hackage ('withProvider') and over an
-- in-memory world (@test\/FlagSolveSpec.hs@).
--
-- Installed units are deliberately not here. They have no flags to assign and
-- no @.cabal@ to read, they come from the compiler rather than an index, and
-- 'mkExpand' takes them as a separate argument.
data ReleaseSource m = ReleaseSource
    { rsVersionsOf  :: PackageName -> Set Version
    -- ^ every version of this package the source has. A 'Set', because
    -- 'withSlots' asks which release comes /next/, and an unsorted list would
    -- answer that wrongly and silently.
    , rsReadRelease :: PackageName -> Version -> m (Either ParseError Release)
    -- ^ the reduced form of one release: its declared flags and its guarded
    -- dependencies. Only ever called for versions 'rsVersionsOf' reported.
    }

-- | The provider's @expand@: the whole candidate-selection and emission rule, over
-- an installed world, a source world, and the root's targets.
mkExpand
    :: forall m env
     . (MonadIO m, WithLog env Text m)
    => InstalledDb
    -> ReleaseSource m
    -> [(PackageName, VersionSet)]
    -- ^ the synthetic root's targets, which are not in the index
    -> PackageName
    -> InstanceSet
    -> m (Maybe (Instance, [Incompatibility]))
mkExpand installedDb source root = expand'
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
            = pure (Just (rootInstance, incs))
                where
                    incs = [ fromDependency rootName (singletonInstance rootInstance) depName (widen depName vs)
                           | (depName, vs) <- root
                           ]
    expand' pn range = do
        let installedHere = [toPreInstalled u | u <- Map.findWithDefault [] pn (idbByName installedDb)]
            admissible = sortOn (Down . version) (filter (`Set.member` isInstalled range) installedHere)
        case listToMaybe admissible of
            Just chosen -> do
                incs <- consequencesOfUsePreInstalled chosen
                pure (Just (UsePreInstalled chosen, incs))
            -- No admissible installed unit. For most packages that means falling
            -- through to source releases; for a non-reinstallable one it means
            -- nothing at all, because its Hackage releases cannot be built against
            -- this compiler (@Bridge.Installed.nonReinstallablePackages@). This is
            -- the difference between preferring installed units and allowing only
            -- installed ones. Without it @aeson '<2'@ resolves by planning to build
            -- @base 4.15.1.0@ from Hackage, which cabal rejects.
            Nothing
                | isNonReinstallable pn -> pure Nothing
                | otherwise -> firstUsable (withSlots (rsVersionsOf source pn))

                where
                    -- Releases newest first (@docs/flags-semantics.md@ §5,
                    -- between-releases half). One @.cabal@ read per release, not
                    -- per candidate assignment.
                    firstUsable [] = pure Nothing
                    firstUsable ((v, slot):rest) = do
                        result <- rsReadRelease source pn v
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
                            -- A release whose library cannot be built here is not a
                            -- candidate: its @pkgconfig-depends@ are unsatisfiable on
                            -- this machine, or it declares @buildable: False@. It is
                            -- skipped without a warning because, unlike an unparseable
                            -- @.cabal@, this is an ordinary fact about the release, and
                            -- cabal applies the same rule from the same pkg-config db.
                            --
                            -- The spec states such a release as an incompatibility of
                            -- its own, collapsed over adjacent releases
                            -- (@references\/pubgrub.md:476@), so that a report can say
                            -- why it is out. @expand@ cannot answer "no decision, but
                            -- learn this" (@PubGrub.Provider@), so the release is not
                            -- offered, and an exhausted list reads as "no versions in
                            -- range".
                            Right release | not (relBuildable release) -> firstUsable rest
                            Right release ->
                                -- Each guarded dependency becomes one incompatibility
                                -- @{pn: D, dep: not T}@. The depender @D@ is every
                                -- instance of @v@ whose flags satisfy the guard, not
                                -- just @inst@, so refuting it rules out every flag
                                -- assignment that shares the dependency at once. Only
                                -- guards that @inst@ satisfies are emitted.
                                case listToMaybe (usableAssignments v release) of
                                    Nothing -> firstUsable rest
                                    Just flags -> do
                                        let inst = BuildSource v flags
                                        incs <-
                                            sequence
                                                [ dependencyInc pn v guard assignment dep
                                                | -- for each guarded dependency of the chosen release
                                                  (guard, deps) <- relGuarded release
                                                , Just assignment <- [NE.nonEmpty (expandGuard guard)]
                                                , -- only if the guard admits the chosen instance, which is what
                                                  -- makes the fact true of it
                                                  inst `memberInstance` sourceInstances slot assignment
                                                , dep <- deps
                                                ]
                                        pure (Just (inst, incs))

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

    -- Committing to an installed unit fixes its whole transitive closure, so
    -- hand the solver every edge of that closure at once. Each edge names its
    -- own depender, so each is a genuine direct dependency: propagation chains
    -- through the closure in one fixpoint (rather than learning one hop per
    -- decision), and a report about any edge stays true.
    consequencesOfUsePreInstalled pip =
            pure
                [ fromDependency
                    fromName
                    (singletonUsePreInstalled fromPip)
                    toName
                    (singletonUsePreInstalled toPip)
                | InstalledEdge (fromName, fromPip) (toName, toPip) <-
                    closureEdges installedDb (pipUnitId pip)
                ]

    -- | One guarded dependency occurrence as an incompatibility, with the depender
    -- covering __every adjacent release that carries the same occurrence__, not
    -- just the one being decided.
    --
    -- @references\/pubgrub.md:456@ asks for this: identical dependencies of
    -- adjacent versions collapse into one incompatibility, from the first version
    -- that has the dependency to the first that does not. One per release is not
    -- wrong, but the solver then re-derives the range a release at a time, which
    -- fills proofs with lines that only merge two neighbours (@conduit \'<1.3\'@
    -- took 1061 lines against cabal\'s 16) and leaves N clauses to propagate where
    -- one would do.
    dependencyInc pn v guard assignment dep = do
        dependers <- spanningOccurrence pn v guard dep
        pure
            ( fromDependency
                pn
                (sourceInstances dependers assignment)
                (depPkgName dep)
                (widen (depPkgName dep) (VersionSet.fromVersionRange (depVerRange dep)))
            )

    -- | The range to name a release\'s neighbours by: walk out from @v@ in both
    -- directions while each neighbour carries this same occurrence, then take the
    -- half-open range from the lowest such release up to the first release above the
    -- highest.
    --
    -- \"The same occurrence\" is compared per /dependency/, not per group: a neighbour
    -- qualifies when any of its guarded groups has this guard and contains this exact
    -- \'Dependency\', whatever else it declares (@docs\/flags-semantics.md@ §4.2).
    -- Comparing whole groups would refuse to merge two releases that differ in
    -- something unrelated.
    --
    -- Requiring the guard to be __identical__ keeps this sound on the flag axis:
    -- every release in the span declares the flags the guard mentions, since one that
    -- did not could not have produced that guard. So the third pin state is not needed
    -- here, and flags the guard never mentions stay free in the cell.
    --
    -- The walk costs a @.cabal@ read per neighbour tried, memoised per release. Many
    -- are releases the solver would never have read: on @pandoc@ the reads rose from
    -- 167 to 2834.
    spanningOccurrence pn v guard dep = do
        lo <- walk Set.lookupLT v
        hi <- walk Set.lookupGT v
        pure (VersionSet.halfOpenVersionSet lo (Set.lookupGT hi releases))
      where
        releases = rsVersionsOf source pn

        -- The furthest release in one direction still carrying the occurrence.
        walk step from = case step from releases of
            Nothing -> pure from
            Just w -> do
                result <- rsReadRelease source pn w
                case result of
                    -- An unparseable neighbour stops the walk rather than being stepped
                    -- over: we cannot claim a fact about a release we cannot read, and
                    -- widening across it would do exactly that.
                    Right neighbour | carries neighbour -> walk step w
                    _ -> pure from

        carries neighbour =
            any (\(g, ds) -> g == guard && dep `elem` ds) (relGuarded neighbour)

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

-- | Pair each release with its __version slot__: the half-open range from it up
-- to the next release that exists, unbounded for the newest. Newest first, the
-- order candidates are tried in (@docs\/flags-semantics.md@ §5, between-releases
-- half).
--
-- A slot contains exactly one existing release, so @p ∈ slot(v) × C@ denotes the
-- same instances as @p ∈ {v} × C@ over anything that can be offered: the claim is
-- about @v@ alone, and it costs no @.cabal@ reads. What the slot adds is that
-- adjacent slots /touch/, so 'PubGrub.VersionSet.unionVersionSet' coalesces them
-- and 'SetOps.difference' leaves no empty hole between releases (see
-- 'PubGrub.VersionSet.halfOpenVersionSet').
--
-- The bound is the next release in the __index__, not the next /usable/ one: a
-- release that is skipped (unparseable, or admitted by no offered assignment)
-- still has its own dependencies, and widening across it would attribute this
-- release's dependencies to it.
withSlots :: Set Version -> [(Version, VersionSet)]
withSlots releases =
    [ (v, VersionSet.halfOpenVersionSet v (Set.lookupGT v releases))
    | v <- Set.toDescList releases
    ]
