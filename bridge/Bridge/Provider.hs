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
    , widenTo

      -- * The provider rule, independently of where releases come from
      --
      -- | 'mkExpand' is the whole candidate-selection and emission rule, and it
      -- takes its world as arguments: an installed db and a 'ReleaseSource'. So
      -- @test\/FlagSolveSpec.hs@ runs the real rule over an in-memory world
      -- rather than a copy of it.
    , mkExpand
    , ReleaseSource (..)
    , Release (..)
    ) where

import           Bridge.Cabal.Flatten                         (GuardedDeps,
                                                               componentDepsAtDefaultsStored,
                                                               expandGuard,
                                                               srFlags, toStored,
                                                               unbuildableAtDefaultsStored)
import           Bridge.Hackage.Store                         (StoreReader (..),
                                                               openStore)
import           Bridge.Cabal.InstalledPkg                    (getInstalledPackageIndex,
                                                               reduceIndex)
import           Bridge.Hackage                               (IndexHandle (..),
                                                               IndexState,
                                                               ParseError,
                                                               cacheDirOf,
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
                                                               unFlagAssignment)
import           Distribution.Types.PackageName               (PackageName)
import qualified Distribution.Types.Version                   as Cabal
import qualified PubGrub.Version                              as V
import           PubGrub.Version                              (Version)
import qualified Distribution.Verbosity                       as Verbosity
import           Hackage.Security.Client.Repository.Cache     (Cache)
import           Network.HTTP.Client                          (Manager)
import           PubGrub.Incompatibility                      (Incompatibility,
                                                               UnbuildableReason,
                                                               fromDependency,
                                                               onlyInstalled,
                                                               request,
                                                               unbuildable)
import           PubGrub.Index.PreInstalled                   (PreInstalledPackage (..))
import           PubGrub.Pretty                               (Pretty (pretty))
import           PubGrub.InstanceSet                          (HasVersion (..),
                                                               Instance (..),
                                                               InstanceSet (..),
                                                               memberInstance,
                                                               singletonUsePreInstalled)
import           PubGrub.InstanceSet.SourceCell               (SourceCell (..),
                                                               assignmentFrom,
                                                               pinnedCell)

import           Distribution.Types.Dependency                (depPkgName,
                                                               depVerRange)
import           PubGrub.Provider                             (Provider (..))
import           PubGrub.VersionSet                           (VersionSet,
                                                               contains)
import qualified PubGrub.VersionSet                           as VersionSet
import           UnliftIO                                     (MonadUnliftIO,
                                                               liftIO)

-- | Open the Hackage index and the compiler's installed world, build a
-- 'Provider' and the solver's seeds, and run @act@ with both. The whole solve
-- must run inside @act@.
--
-- The targets ("solve for these packages in these ranges") become one
-- 'request' each. They are built here rather than in the driver because
-- widening a range to instances needs the installed db: a target that names a
-- boot package has to admit its installed unit.
withProvider
    :: (MonadUnliftIO m, WithLog env Text m)
    => Cache -> Manager -> IndexState -> [(PackageName, VersionSet)] -> (Provider m -> [Incompatibility] -> m a) -> m a
withProvider cache manager state targets act =
    withWorld cache manager state $ \world -> do
        let handle = wIndex world
            platform = wPlatform world
            cInfo = wCompiler world
            installed = reduceIndex (wInstalled world)
        -- The derived index, when one has been built here. It is a cache and not
        -- a source of truth: 'openStore' answers 'Nothing' for a missing,
        -- unreadable or stale-format store, and every miss falls back to parsing,
        -- so its absence costs speed and never correctness.
        store <- liftIO (openStore (cacheDirOf cache))
        (readRelease, lookupStats) <-
            liftIO (releaseReader platform cInfo (wPkgConfig world) handle store)
        let installedDb = mkInstalledDb installed
            provider =
                Provider
                    ( mkExpand
                        installedDb
                        ReleaseSource
                            { rsVersionsOf = ihSolverVersionsOf handle
                            , rsReadRelease = \pn v -> liftIO (readRelease pn (V.toCabalVersion v))
                            }
                    )
            seeds = [request pn (widenTo installedDb pn vs) | (pn, vs) <- targets]
        result <- act provider seeds
        (parsed, decoded, reused) <- liftIO lookupStats
        logMsg
            ( T.pack
                ( "read "
                    ++ show parsed
                    ++ " .cabal files, decoded "
                    ++ show decoded
                    ++ " from the derived index, served "
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
    -- release from the candidate list and state which module was missing (see
    -- 'relUnbuildable').
    }

-- | Open the index and resolve the compiler world, then run @act@. The index
-- bracket closes on the way out, so nothing that reads a @.cabal@ lazily may
-- escape.
withWorld
    :: (MonadUnliftIO m, WithLog env Text m)
    => Cache -> Manager -> IndexState -> (World -> m a) -> m a
withWorld cache manager state act =
    withHackageIndex cache manager state $ \handle -> do
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

-- | What the provider needs from a release's description — and all it keeps.
--
-- Both components are independent of the flag assignment: the declared flags with
-- their defaults, and the dependencies as flag-guarded groups with the fixed
-- environment already resolved. So they are derived once per release and reused
-- for every assignment tried against it.
data Release = Release
    { relFlags     :: [(FlagName, Bool)]
    , relGuarded   :: GuardedDeps
    , relUnbuildable :: [UnbuildableReason]
    -- ^ why this release's library cannot be built here, if it cannot: @buildable@
    -- and @pkgconfig-depends@ resolved against the machine, at the declared flag
    -- defaults (@Bridge.Cabal.Flatten.unbuildableAtDefaults@). Empty means it can.
    -- A verdict because flags are fixed at their defaults; searching flags will need
    -- the condition itself, which 'Bridge.Cabal.Flatten.buildableCondition' returns.
    }

-- | A memoising reader for 'Release', with a @(parsed, decoded, reused)@ count.
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
    -> Maybe StoreReader
    -> IO (PackageName -> Cabal.Version -> IO (Either ParseError Release), IO (Int, Int, Int))
releaseReader platform cInfo pkgConfig handle store = do
    -- (entries, parsed, decoded, reused). @parsed@ counts .cabal files actually
    -- put through Cabal-syntax and @decoded@ counts entries served by the derived
    -- index. They are kept apart because a parse costs about 27 times a decode
    -- (2.0 ms against 0.073 ms), and every measurement this project quotes is in
    -- parses.
    ref <- newIORef (Map.empty, 0 :: Int, 0 :: Int, 0 :: Int)
    let readRelease pn v = do
            (entries, _, _, _) <- readIORef ref
            case Map.lookup (pn, v) entries of
                Just hit -> do
                    atomicModifyIORef' ref
                        (\(es, p, d, reused) -> ((es, p, d, reused + 1), ()))
                    pure hit
                Nothing -> do
                    (result, fromStore) <- fromStoreOrParse pn v
                    atomicModifyIORef' ref $ \(es, p, d, reused) ->
                        ( ( Map.insert (pn, v) result es
                          , if fromStore then p else p + 1
                          , if fromStore then d + 1 else d
                          , reused
                          )
                        , ()
                        )
                    pure result

        -- The derived index first, the index tar second. Both arrive at a
        -- 'Release' by the same route: the store keeps the /pre-environment/ form,
        -- so the environment-dependent half — @os@\/@arch@\/@impl@, and
        -- @pkg-config@ for buildability — is resolved here either way, against this
        -- machine as it is now rather than as it was when the store was written.
        fromStoreOrParse pn v = do
            hit <- case (store, ihBlockOf handle pn v) of
                (Just s, Just blk) -> srLookup s pn v blk
                _                  -> pure Nothing
            case hit of
                Just stored -> pure (Right (fromStored stored), True)
                Nothing     -> do
                    parsed <- fmap reduce <$> ihLookupGPD handle pn v
                    pure (parsed, False)

        fromStored sr =
            Release
                { relFlags = srFlags sr
                , relGuarded = componentDepsAtDefaultsStored platform cInfo sr
                , relUnbuildable = unbuildableAtDefaultsStored pkgConfig platform cInfo sr
                }

        reduce = fromStored . toStored
    pure (readRelease, (\(_, p, d, reused) -> (p, d, reused)) <$> readIORef ref)

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
-- an installed world and a source world.
--
-- It needs a text log channel and __not__ 'MonadIO': reading a release runs in
-- whatever @m@ the 'ReleaseSource' was built in, so an in-memory world can drive
-- it purely, as @test\/PaperSpec.hs@ does.
mkExpand
    :: forall m env
     . (WithLog env Text m)
    => InstalledDb
    -> ReleaseSource m
    -> PackageName
    -> InstanceSet
    -> m (Maybe Instance, [Incompatibility])
mkExpand installedDb source = expand'
  where
    -- An 'InstanceSet' is a symbolic description (version ranges plus flag
    -- pins), not a container: membership is decidable but it cannot be
    -- enumerated. So walk the package's own candidates, installed units first
    -- and then source (version, cell) pairs newest first, and commit to the
    -- first the offered set admits. A source candidate's @.cabal@ is parsed
    -- only when it is tried.
    expand' :: PackageName -> InstanceSet -> m (Maybe Instance, [Incompatibility])
    expand' pn range = do
        let installedHere = [toPreInstalled u | u <- Map.findWithDefault [] pn (idbByName installedDb)]
            admissible = sortOn (Down . version) (filter (`Set.member` isInstalled range) installedHere)
        case listToMaybe admissible of
            Just chosen -> do
                incs <- consequencesOfUsePreInstalled chosen
                pure (Just (UsePreInstalled chosen), onlyInstalledFact pn ++ incs)
            -- No admissible installed unit. For most packages that means falling
            -- through to source releases; for a non-reinstallable one it means
            -- nothing at all, because its Hackage releases cannot be built against
            -- this compiler (@Bridge.Installed.nonReinstallablePackages@). This is
            -- the difference between preferring installed units and allowing only
            -- installed ones. Without it @aeson '<2'@ resolves by planning to build
            -- @base 4.15.1.0@ from Hackage, which cabal rejects.
            --
            -- __Say why, rather than answering with nothing.__ The fact rides out
            -- with the 'Nothing', as the scan's facts do below. Without it the
            -- solver learns only that the range is empty, and the proof reads /no
            -- version for base in >=4.5 && <4.7/ when the reason is that the
            -- compiler provides @base@. 'onlyInstalledFact' also rides with the
            -- first installed decision, but a boot package whose early queries are
            -- all source-only has no decision to ride with: on @lens \'<4\'@ that was
            -- three of the four no-version events, and all three reached the proof.
            --
            -- It replaces a clause rather than adding one: @banRest@ subtracts what
            -- the provider stated, and the fact covers every instance in a
            -- source-only range, so the @noInstances@ clause is dropped as empty.
            -- ('isEmpty' is one-sided, so at worst the store carries a redundant
            -- clause; @banRest@ says why that is the safe direction.)
            --
            -- This broadens a learned clause, and broadening is what made stating
            -- all eight boot facts at the root expensive (see 'onlyInstalledFact').
            -- Emitting one fact where it is needed is expected not to be, but that
            -- is to be measured on the search, not assumed.
            Nothing
                | isNonReinstallable pn -> pure (Nothing, onlyInstalledFact pn)
                | otherwise -> firstUsable (withSlots (rsVersionsOf source pn))

                where
                    -- Releases newest first (@docs/flags-semantics.md@ §5,
                    -- between-releases half). One @.cabal@ read per release, not
                    -- per candidate assignment.
                    --
                    -- @stated@ accumulates the facts learned about releases the scan
                    -- rejects on the way past, newest first. They ride out with
                    -- whichever release it settles on: incompatibilities are
                    -- context-independent, so the solver never requires them to be
                    -- about the instance just decided
                    -- (@docs\/flags-semantics.md@ §10).
                    firstUsable = scan []

                    -- An exhausted list answers @Nothing@, and the facts go with it.
                    -- That is why 'expand' reports its clauses outside the 'Maybe': a
                    -- range holding nothing but unbuildable releases is the commonest
                    -- way a real Hackage package fails to resolve, and without the
                    -- facts the report says "no version for hpqtypes in >=1.13" where
                    -- cabal says "pkg-config package libpq-any, not found in the
                    -- pkg-config database".
                    scan stated [] = pure (Nothing, reverse stated)
                    scan stated ((v, slot):rest) = do
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
                                            ++ T.unpack (pretty v)
                                            ++ " (unparseable .cabal: "
                                            ++ show err
                                            ++ ")"
                                        )
                                    )
                                scan stated rest
                            -- A release whose library cannot be built here is not a
                            -- candidate: its @pkgconfig-depends@ are unsatisfiable on
                            -- this machine, or it declares @buildable: False@. Unlike an
                            -- unparseable @.cabal@ this is an ordinary fact about the
                            -- release, so it gets no warning, and cabal applies the same
                            -- rule from the same pkg-config db.
                            --
                            -- It is /stated/ as a clause (@references\/pubgrub.md:476@).
                            -- Without one the solver learns only that the range it
                            -- narrowed to is empty, and the report reads "no version for
                            -- p in range" when the versions exist and cannot be built
                            -- here. With it, the proof line gives the reason, naming the
                            -- module @pkg-config@ could not find, as cabal's own message
                            -- does. The clause covers the release's whole slot: see
                            -- 'unbuildableFact'.
                            Right release | Just why <- NE.nonEmpty (relUnbuildable release) ->
                                scan (unbuildableFact pn slot why : stated) rest
                            Right release ->
                                -- Each guarded dependency becomes one incompatibility
                                -- @{pn: D, dep: not T}@. The depender @D@ is every
                                -- instance of @v@ whose flags satisfy the guard, not
                                -- just @inst@, so refuting it rules out every flag
                                -- assignment that shares the dependency at once. Only
                                -- guards that @inst@ satisfies are emitted.
                                case listToMaybe (usableAssignments v release) of
                                    Nothing -> scan stated rest
                                    Just flags -> do
                                        let inst = BuildSource v flags
                                        incs <-
                                            sequence
                                                [ dependencyInc pn v slot guard assignment dep
                                                | -- for each guarded dependency of the chosen release
                                                  (guard, deps) <- relGuarded release
                                                , Just assignment <- [NE.nonEmpty (expandGuard guard)]
                                                , -- only if the guard admits the chosen instance, which is what
                                                  -- makes the fact true of it
                                                  inst `memberInstance` slotInstances slot assignment
                                                , dep <- deps
                                                , -- and not a self-dependency: an
                                                  -- intra-package edge, not a version
                                                  -- constraint (see the note below)
                                                  depPkgName dep /= pn
                                                ]
                                        pure (Just inst, reverse stated ++ incs)

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

    -- | For a non-reinstallable package, the standing fact that it can __only__ be an
    -- installed unit: no source release of it may be selected, whatever the range.
    -- It is emitted alongside the decision that first commits to one of its
    -- installed units.
    --
    -- 'expand'' never offers a source release of such a package, so without the
    -- fact the solver rediscovers the rule one range at a time: every range of
    -- @base@ holding only source releases costs a decision, a provider call
    -- answering 'Nothing', and a @noInstances@ clause for that range.
    -- @aeson \'<2\'@ paid that over five ranges; with the fact it pays once, and its
    -- proof halves. cabal takes the same rule as a constraint
    -- (@Bridge.Cabal.Baseline.nonReinstallableConstraints@), so this closes an
    -- asymmetry rather than adding a rule of our own.
    --
    -- __Why here and not up front__, where cabal\'s equivalent goes and where it
    -- would cover the first query too: stating all eight facts there shortens
    -- @lens \'<4\'@\'s proof to two lines, but costs @aeson \'<2\'@ 41% more
    -- allocation and 466 more decisions, because eight extra level-0 derivations
    -- change which satisfier conflict resolution picks. That is search-path luck
    -- rather than a principle, and worth revisiting if the @aeson@ path is ever
    -- understood.
    --
    -- Riding along with a decision needs no new interface: incompatibilities are
    -- context-independent, so the solver never requires them to be about the
    -- instance just decided (@docs\/flags-semantics.md@ §10). A package whose
    -- /first/ query is already source-only still pays once: @conduit \'<1.3\'@ and
    -- @lens \'<4\'@ each keep one such event.
    onlyInstalledFact pn
        | isNonReinstallable pn = [onlyInstalled pn (installedVersionsOf pn) anySourceRelease]
        | otherwise = []

    -- Newest first, one entry per version: two units of one version (a profiling
    -- way, say) are one version to the reader.
    installedVersionsOf pn =
        Set.toDescList
            (Set.fromList [pipVersion (toPreInstalled u) | u <- Map.findWithDefault [] pn (idbByName installedDb)])

    -- | The fact that a release cannot be built in this environment: a unit clause
    -- banning every instance of its version __slot__ (@references\/pubgrub.md:476@).
    --
    -- Unpinned, because with flags fixed at their declared defaults a release has
    -- exactly one instance and buildability is a property of the release. Under a
    -- searched flag axis a release can be unbuildable at one assignment and fine
    -- at another, and the term would have to be the region where
    -- 'Bridge.Cabal.Flatten.buildableCondition' is false.
    --
    -- The slot, rather than the single version, lets 'PubGrub.Store' union a run of
    -- unbuildable releases into one clause: adjacent slots touch, so the union has
    -- no hole between the releases and reads as the range the spec asks for. The
    -- store merges only runs that give the same reasons, so a release missing
    -- @libpq@ and one declaring @buildable: False@ stay two facts, each with its own
    -- sentence.
    unbuildableFact pn slot why = unbuildable pn (slotInstances slot (NE.singleton Map.empty)) why

    -- | Every source instance of a package: any version, no flags pinned. The
    -- complement of \"is an installed unit\", on the source side.
    anySourceRelease =
        InstanceSet
            { isInstalled = Set.empty
            , isSource = [SourceCell VersionSet.fullVersionSet Map.empty]
            }

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

    -- Why a dependency of @p@ on @p@ itself is dropped rather than stated (the
    -- @depPkgName dep /= pn@ filter in 'expand'' above).
    --
    -- It is not a version constraint. @lens 1.7@ depends on @lens ==1.7@ because
    -- one of its components (an executable) is built against its own library: an
    -- /intra-package/ edge, resolved inside the package. Stated as a fact it says
    -- something much stronger and false: that every instance of @lens@ must be
    -- @1.7@.
    --
    -- __This is cabal\'s rule.__ @Distribution.Solver.Modular.Builder.extendOpen@
    -- adds no goal and no edge when @qpn == qpn\'@, /except/ for a setup dependency,
    -- where it adds only a reverse-dependency edge, so that the cycle makes the
    -- solver pick a different instance for the setup script.
    -- @Distribution.Solver.Modular.IndexConversion@ likewise drops a
    -- @build-tool-depends@ on the package\'s own executable (@isInternal@).
    --
    -- We model neither setup nor build-tool dependencies yet. When they arrive the
    -- setup exception must come with them, and qualified goals will __not__ subsume
    -- this rule: a library dependency inherits its depender\'s qualifier
    -- (@qualifyDeps@\'s @inheritedQ@), so an executable\'s dependency on its own
    -- library is a self-dependency under any qualifier scheme.
    --
    -- The installed side drops it too: 'Bridge.Installed.closureEdges' emits no
    -- edge for a self-dependency.
    -- | One guarded dependency occurrence of the decided release, as an
    -- incompatibility whose depender starts from that release\'s __slot__, the
    -- half-open range up to the next release in the index ('withSlots').
    --
    -- @references\/pubgrub.md:456@ asks for identical dependencies of adjacent
    -- versions of the depender to be /one/ incompatibility. Two mechanisms deliver
    -- that, and both run. 'spanningOccurrence', below, reads the decided release\'s
    -- neighbours and widens the slot while the occurrence is identical.
    -- 'PubGrub.Store' unions the depender terms of two facts that agree about the
    -- dependee as they arrive; adjacent slots /touch/, so the union is one interval
    -- with no hole.
    --
    -- The walk is affordable only because a neighbour read is a CBOR decode rather
    -- than a parse (2.007 ms to 0.073 ms). As a parse it took @pandoc@, a problem
    -- with one conflict, from 167 reads to 2834 and from 22.9 MB to 81.0 MB of
    -- residency; as a decode it costs that problem 22.6 MB to 33.1 MB of residency
    -- and under 1% of allocation. @docs\/collapsing.md@ has the trade, and five ways
    -- to walk less if read-dominated problems ever matter more.
    dependencyInc pn v slot guard assignment dep = do
        dependers <- spanningOccurrence pn v slot guard dep
        pure
            ( fromDependency
                pn
                (slotInstances dependers assignment)
                (depPkgName dep)
                (widen (depPkgName dep) (VersionSet.fromVersionRange (depVerRange dep)))
            )

    -- | The range to name a release's neighbours by: walk out from @v@ in both
    -- directions while each neighbour carries this same occurrence, then take the
    -- half-open range from the lowest such release up to the first release above the
    -- highest. This is @references\/pubgrub.md:456@ done where the spec asks for it,
    -- at generation time, rather than left to @PubGrub.Store@ to rebuild one
    -- expanded release at a time.
    --
    -- \"The same occurrence\" is compared per /dependency/, not per group: a neighbour
    -- qualifies when any of its guarded groups has this guard and contains this exact
    -- 'Dependency', whatever else it declares (@docs\/flags-semantics.md@ §4.2).
    -- Comparing whole groups would refuse to merge two releases that differ in
    -- something unrelated.
    --
    -- Requiring the guard to be __identical__ keeps this sound on the flag axis:
    -- every release in the span declares the flags the guard mentions, since one
    -- that did not could not have produced that guard.
    --
    -- The walk costs a release read per neighbour tried. When a read was a @.cabal@
    -- parse (2.0 ms and ~7.7 MB), @pandoc@, a problem with a single conflict, went
    -- from 167 reads to 2834 and from 22.9 MB to 81.0 MB of residency
    -- (@docs\/collapsing.md@). It is affordable because a read is now a 0.073 ms
    -- decode from 'Bridge.Hackage.Store', which is keyed by __package__, so a walk
    -- stays inside one slice that is already in hand.
    spanningOccurrence pn v slot guard dep = do
        lo <- walk Set.lookupLT v
        hi <- walk Set.lookupGT v
        pure $ case (lo, hi) of
            -- Neither neighbour carries it: just the release's own slot.
            (l, h) | l == v && h == v -> slot
            (l, h) -> spanSlot (slotRange releases l (Set.lookupGT h releases))
      where
        releases = rsVersionsOf source pn

        -- The furthest release in one direction still carrying the occurrence.
        walk step from = case step from releases of
            Nothing -> pure from
            Just w -> do
                result <- rsReadRelease source pn w
                case result of
                    -- An unparseable neighbour stops the walk rather than being
                    -- stepped over: we cannot claim a fact about a release we cannot
                    -- read, and widening across it would do exactly that.
                    Right neighbour | carries neighbour -> walk step w
                    _ -> pure from

        carries neighbour =
            any (\(g, ds) -> g == guard && dep `elem` ds) (relGuarded neighbour)

    widen = widenTo installedDb

-- | Widen a version range into an instance set: a dependency's declared range, or
-- a target's. The installed half is extensional: the compiler's database is small
-- and fully known. The source half is a single cell carrying the declared range,
-- not one entry per version in range. That keeps the cell count per dependency
-- constant, which matters because 'difference' multiplies cell counts, and it
-- keeps the range in the incompatibility, so a conflict report can say
-- @>=1.0 && <2@ instead of listing versions.
--
-- The cell admits versions the index does not have. That is harmless: the set
-- algebra never needs the instance universe, and 'mkExpand' enumerates candidates
-- from the index, so an unsatisfiable dependency surfaces as @Nothing@ from
-- 'mkExpand' rather than as an empty widening.
widenTo :: InstalledDb -> PackageName -> VersionSet -> InstanceSet
widenTo installedDb d vs =
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
withSlots :: Set Version -> [(Version, Slot)]
withSlots releases =
    [ (v, Slot (slotRange releases v (Set.lookupGT v releases)))
    | v <- Set.toDescList releases
    ]

-- | The range from release @lo@ up to, and not including, the next release @hi@
-- — except that the package's __first__ release has no lower bound at all
-- (@references\/pubgrub.md:464@–@:469@: "if the first published version of the
-- package has the dependency, the lower bound is omitted"). Nothing is published
-- below it, so the two ranges hold the same releases; what differs is the
-- complement. Banning @>=0.1 && <2.4@ leaves @<0.1@ for the solver to discover
-- empty and to print as @no version for lens in <0.1@. Banning @<2.4@ leaves
-- nothing, and the proof reads @lens <2.4@ where the spec writes @foo <1.1.0@.
slotRange :: Set Version -> Version -> Maybe Version -> VersionSet
slotRange releases lo hi
    | Set.lookupMin releases == Just lo = VersionSet.belowVersionSet hi
    | otherwise = VersionSet.halfOpenVersionSet lo hi

-- | One release's slot, as a type of its own.
--
-- A depender term over a __slot__ is the collapsed term
-- @references\/pubgrub.md:456@ asks for; one over the __single version__ just
-- decided is the per-version emission it replaces. Both are intervals, so only a
-- type keeps one from being passed where the other belongs.
--
-- The constructor is not exported and 'withSlots' is the only thing that applies it,
-- so a slot can only mean \"this release, up to the next one the index actually
-- has\". 'slotInstances' is the only way back out.
newtype Slot = Slot VersionSet

-- | Every instance of a slot that satisfies one of the given pin sets — the depender
-- term of a dependency fact, and the term an unbuildable fact bans.
--
-- The pin sets are __not assignments__: they need not mention every declared flag,
-- and how much the result denotes follows from how much they pin (see 'pinnedCell').
-- 'NonEmpty' because an empty union is the empty set, and a guard that no assignment
-- satisfies is dropped before it gets here.
-- | A slot spanning a __run of adjacent releases__ that all carry the same
-- dependency occurrence, which is the collapsed form @references\/pubgrub.md:456@
-- asks for.
--
-- It is a 'Slot' for the same reason one release's slot is: the invariant the type
-- protects is that a depender term is never a single version, and a span satisfies
-- that more strongly rather than less. 'Bridge.Provider.spanningOccurrence' is the
-- only thing that builds one, and it establishes the run by reading every release in
-- it.
spanSlot :: VersionSet -> Slot
spanSlot = Slot

slotInstances :: Slot -> NE.NonEmpty (Map.Map FlagName Bool) -> InstanceSet
slotInstances (Slot vs) pinSets =
    InstanceSet
        { isInstalled = Set.empty
        , isSource = [pinnedCell vs pins | pins <- NE.toList pinSets]
        }
