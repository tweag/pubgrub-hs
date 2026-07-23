-- | The real 'Provider', backed by a Hackage 'IndexHandle'. Like the toy
-- provider in @test\/PaperSpec.hs@ it picks the newest instance in range.
-- A package's versions come from the handle's disk-cached version map
-- ('ihVersions'), and a decided release's dependencies are read from its
-- @.cabal@ through 'ihLookupGPD' on demand, so a solve parses only the
-- packages it explores.
--
-- 'ihLookupGPD' is valid only while the index bracket is open, so a
-- 'Provider' from 'mkProvider' must be used inside 'withHackageIndex'.
module Bridge.Provider
    ( mkProvider
    , rootName
    , syntheticRoot
    ) where

import           Bridge.Hackage                 (IndexHandle (..))
import           Bridge.Instances               (toSourcePackage)
import           Data.List                      (maximumBy)
import qualified Data.List.NonEmpty             as NE
import qualified Data.Map.Strict                as Map
import           Data.Ord                       (comparing)
import qualified Data.Set                       as Set
import           Distribution.Compiler          (CompilerInfo)
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

-- | A 'Provider' backed by a Hackage 'IndexHandle'. It reads the index, so it
-- must be used inside the 'withHackageIndex' bracket.
mkProvider :: MonadIO m => Platform -> CompilerInfo -> IndexHandle -> Provider m
mkProvider platform compiler handle = Provider expand'
  where
    expand' p (InstanceSet s)
        | Set.null s = pure Nothing
        | otherwise = do
            let chosen = maximumBy (comparing version) (Set.toList s)
            incs <- consequencesOf p chosen
            pure (Just (chosen, incs))

    -- The synthetic root carries its dependencies; every real package's are
    -- read lazily from its .cabal via the handle.
    consequencesOf p chosen
        | p == rootName = pure (depIncs p chosen (instanceDeps chosen))
        | otherwise = do
            result <- liftIO (ihLookupGPD handle p (version chosen))
            pure $ case result of
                Right gpd -> depIncs p chosen (sourcePackageDeps (toSourcePackage platform compiler gpd))
                -- A .cabal that fails to parse: ban just this instance so the
                -- solver backtracks to another version.
                -- TODO: surface the parse error (needs a WithLog constraint).
                Left _err -> [noInstances p (singletonInstance chosen)]

    depIncs :: PackageName -> Instance -> [(PackageName, VersionSet)] -> [Incompatibility]
    depIncs p chosen deps =
        [ fromDependency p (singletonInstance chosen) (d, widen d vs)
        | (d, vs) <- deps
        ]

    -- Widen a dependency's version range into the set of that package's
    -- instances, using only the in-memory version map (no .cabal parsing).
    widen d vs =
        InstanceSet (Set.fromList [sourceInstance v | v <- versionsOf d, contains vs v])

    versionsOf d = maybe [] NE.toList (Map.lookup d (ihVersions handle))

-- | The (name, range) dependencies of an instance's source package.
instanceDeps :: Instance -> [(PackageName, VersionSet)]
instanceDeps (BuildSource sp _) = sourcePackageDeps sp
instanceDeps _                  = []

-- | The (name, range) dependencies of a source package. Their conditions are
-- ignored: 'toSourcePackage' makes every dependency unconditional.
sourcePackageDeps :: SourcePackage -> [(PackageName, VersionSet)]
sourcePackageDeps sp = [(d, vs) | Dependency d vs _ <- spDependencies sp]
