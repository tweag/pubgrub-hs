{-# LANGUAGE CPP #-}
-- | The real 'Provider', backed by a Hackage 'IndexHandle' and the compiler's
-- installed (boot) package database.
--
-- The rule itself, which instance of a package to commit to and what that
-- entails, is 'PubGrub.Cabal.Provider.mkExpand', and needs nothing but
-- @Cabal-syntax@. This module supplies the world it runs over on this machine:
-- 'withWorld' opens the index, resolves the compiler and the installed packages,
-- and reads @pkg-config@; 'releaseReader' turns an index entry into the 'Release'
-- the rule reads, through the derived index where there is one; and
-- 'withProvider' puts the two together with the solver's seeds and runs an action
-- with them. The provider is valid only during that action, because its @.cabal@
-- reads go through the open index bracket.
module Bridge.Provider
    ( withProvider
    , withWorld
    , World (..)
    , pkgConfigPresent
    ) where

import           Bridge.Cabal.InstalledPkg                    (getInstalledPackageIndex,
                                                               reduceIndex)
import           Bridge.Hackage                               (IndexHandle (..),
                                                               IndexState,
                                                               cacheDirOf,
                                                               withHackageIndex)
import           Bridge.Hackage.Store                         (StoreReader (..),
                                                               openStore)
import           Colog                                        (LogAction (..),
                                                               WithLog, logMsg)
import           Data.IORef                                   (atomicModifyIORef',
                                                               newIORef,
                                                               readIORef)
import qualified Data.Map.Strict                              as Map
import           Data.Maybe                                   (fromMaybe)
import           Data.Text                                    (Text)
import qualified Data.Text                                    as T
import           Distribution.Compiler                        (CompilerInfo)
import           Distribution.Simple.Compiler                 (compilerInfo)
import           Distribution.Simple.GHC                      (configure)
import           Distribution.Simple.PackageIndex             (InstalledPackageIndex)
import           Distribution.Simple.Program.Db               (defaultProgramDb)
import           Distribution.Solver.Types.PkgConfigDb        (PkgConfigDb,
                                                               pkgConfigPkgIsPresent,
                                                               readPkgConfigDb)
import           Distribution.System                          (Platform,
                                                               buildPlatform)
import           Distribution.Types.PackageName               (PackageName)
import           Distribution.Types.PkgconfigDependency       (PkgconfigDependency (..))
import qualified Distribution.Types.Version                   as Cabal
import qualified Distribution.Verbosity                       as Verbosity
import           Hackage.Security.Client.Repository.Cache     (Cache)
import           Network.HTTP.Client                          (Manager)
import           PubGrub.Cabal                                (Cabal, request)
import           PubGrub.Cabal.Flatten                        (FlagModel (..),
                                                               PkgConfigPresent,
                                                               componentDepsStored,
                                                               componentToolsStored,
                                                               srFlags, srManual,
                                                               srSetup,
                                                               toStored,
                                                               unbuildableAtDefaultsStored)
import           PubGrub.Cabal.Installed                      (mkInstalledDb)
import           PubGrub.Cabal.Provider                       (ParseError,
                                                               Release (..),
                                                               ReleaseSource (..),
                                                               constrainTo,
                                                               mkExpand,
                                                               noPreference,
                                                               widenTo)
import           PubGrub.Incompatibility                      (Incompatibility)
import           PubGrub.Provider                             (Provider (..))
import           PubGrub.Cabal.Variable                             (Flag (..))
import qualified PubGrub.Cabal.Version                              as V
import           PubGrub.Cabal.VersionSet                           (VersionSet)
import           UnliftIO                                     (MonadUnliftIO,
                                                               liftIO)

-- | Cabal's normal verbosity. From Cabal 3.18 a 'Verbosity.Verbosity' also
-- carries the handles it prints to, and 'Verbosity.normal' is the flags alone.
normal :: Verbosity.Verbosity
#if MIN_VERSION_Cabal(3,18,0)
normal = Verbosity.mkVerbosity Verbosity.defaultVerbosityHandles Verbosity.normal
#else
normal = Verbosity.normal
#endif

-- | 'PubGrub.Cabal.Flatten.PkgConfigPresent' from cabal's own reading of this
-- machine's @pkg-config@, so both solvers answer a @pkgconfig-depends@ from one
-- db with one predicate. 'Nothing' is no @pkg-config@ executable, and fails every
-- dependency, as cabal's own validation does.
pkgConfigPresent :: Maybe PkgConfigDb -> PkgConfigPresent
pkgConfigPresent db (PkgconfigDependency n range) =
    maybe False (\d -> pkgConfigPkgIsPresent d n range) db

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
    => Cache -> Manager -> IndexState -> FlagModel -> [(PackageName, VersionSet)] -> [(PackageName, VersionSet)] -> (Provider Cabal m -> [Incompatibility Cabal] -> m a) -> m a
withProvider cache manager state model targets constraints act =
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
            liftIO (releaseReader model platform cInfo (wPkgConfig world) handle store)
        let installedDb = mkInstalledDb installed
            provider =
                Provider
                    ( mkExpand
                        (LogAction logMsg)
                        noPreference
                        installedDb
                        ReleaseSource
                            { rsVersionsOf = ihSolverVersionsOf handle
                            , rsReadRelease = \pn v -> liftIO (readRelease pn (V.toCabalVersion v))
                            }
                    )
            seeds =
                [request pn (widenTo installedDb pn vs) | (pn, vs) <- targets]
                    ++ [constrainTo installedDb pn (widenTo installedDb pn vs) | (pn, vs) <- constraints]
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
    -- 'PubGrub.Cabal.Flatten.buildableCondition'.
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
            liftIO $ configure normal Nothing Nothing defaultProgramDb
        installedIndex <- liftIO $ getInstalledPackageIndex normal compiler programDb
        pkgConfig <- liftIO $ readPkgConfigDb normal programDb
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
    :: FlagModel
    -> Platform
    -> CompilerInfo
    -> Maybe PkgConfigDb
    -> IndexHandle
    -> Maybe StoreReader
    -> IO (PackageName -> Cabal.Version -> IO (Either ParseError Release), IO (Int, Int, Int))
releaseReader model platform cInfo pkgConfig handle store = do
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
                { relAutomatic = case model of
                    FixedFlags   -> []
                    FlagPackages -> [Flag f d | (f, d) <- srFlags sr, f `notElem` srManual sr]
                , relGuarded = componentDepsStored model platform cInfo sr
                , relUnbuildable = unbuildableAtDefaultsStored (pkgConfigPresent pkgConfig) platform cInfo sr
                , relTools = componentToolsStored model platform cInfo sr
                , relSetup = srSetup sr
                }

        reduce = fromStored . toStored
    pure (readRelease, (\(_, p, d, reused) -> (p, d, reused)) <$> readIORef ref)
