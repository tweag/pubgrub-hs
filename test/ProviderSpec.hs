{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies          #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module ProviderSpec (tests) where

import           Data.Functor.Identity          (runIdentity)
import           Data.List                      (sortBy)
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Data.Maybe                     (listToMaybe)
import           Data.Ord                       (Down (..), comparing)
import           Distribution.Types.PackageName (PackageName, mkPackageName)
import           Distribution.Types.UnitId      (mkUnitId)
import           Distribution.Version           (Version, mkVersion)
import           PackageDbProvider              (PackageDbProvider,
                                                 installedInRange,
                                                 mkPackageDbProvider)
import           Pkg                            (Pkg (..))
import           Provider                       (Combined (..))
import           PubGrub.Cabal.InstalledDb      (InstalledPkg (..))
import           PubGrub.Choice                 (Choice (..), ChoiceSet (..))
import           PubGrub.Compiler               (PackageDb (..))
import           PubGrub.Lattice                (bottom)
import           PubGrub.Solver                 (DependencyProvider (..))
import           PubGrub.VersionSet             (VersionSet)
import qualified PubGrub.VersionSet             as VS
import           Test.Tasty                     (TestTree, testGroup)
import           Test.Tasty.HUnit               (assertFailure, testCase, (@?=))

-- | A tiny in-memory source provider, mirroring SolverSpec's Registry idiom:
-- package -> version -> its dependency ranges. It answers the newest version
-- in range.
newtype Src = Src (Map PackageName (Map Version (Map Pkg VersionSet)))

instance Monad m => DependencyProvider Src Pkg VersionSet m where
    expand (Src _) Root _ = pure Nothing
    expand (Src reg) (Pkg n) range =
        let vs = maybe [] Map.keys (Map.lookup n reg)
         in pure $ case listToMaybe (sortBy (comparing Down) (filter (VS.contains range) vs)) of
                Nothing -> Nothing
                Just ver ->
                    let deps =
                            Map.findWithDefault
                                Map.empty
                                ver
                                (Map.findWithDefault Map.empty n reg)
                     in Just (ver, deps)

ip :: String -> String -> [Int] -> [String] -> InstalledPkg
ip uid nm ver deps =
    InstalledPkg (mkUnitId uid) (mkPackageName nm) (mkVersion ver) (map mkUnitId deps)

-- | A db with base installed at 4.21.
db :: PackageDbProvider
db =
    mkPackageDbProvider
        GlobalDb
        [ ip "base-4.21-x" "base" [4, 21] []
        ]

emptyDb :: PackageDbProvider
emptyDb = mkPackageDbProvider GlobalDb []

-- | Source registry: base at {4.21, 4.22}, no deps.
src :: Src
src =
    Src $
        Map.singleton
            (mkPackageName "base")
            ( Map.fromList
                [ (mkVersion [4, 21], Map.empty)
                , (mkVersion [4, 22], Map.empty)
                ]
            )

sourceVersions :: VersionSet
sourceVersions =
    VS.singleton (mkVersion [4, 21]) `VS.union` VS.singleton (mkVersion [4, 22])

basePkg :: Pkg
basePkg = Pkg (mkPackageName "base")

tests :: TestTree
tests =
    testGroup
        "Provider"
        [ testCase "prefer-installed: returns an Installed choice when base is installed" $
            let combined = Combined db src (mkPackageName "base") VS.full
                sel =
                    ChoiceSet
                        (installedInRange db (mkPackageName "base") VS.full)
                        sourceVersions
             in case runIdentity (expand combined basePkg sel) of
                    Just (Installed _, _) -> pure ()
                    Just (Source _, _) -> assertFailure "expected Installed, got Source"
                    Nothing -> assertFailure "expand returned Nothing unexpectedly"
        , testCase "source fallback: returns a Source choice when nothing installed" $
            let combined = Combined emptyDb src (mkPackageName "base") VS.full
                sel = ChoiceSet bottom sourceVersions
             in case runIdentity (expand combined basePkg sel) of
                    Just (Source _, _) -> pure ()
                    Just (Installed _, _) -> assertFailure "expected Source, got Installed"
                    Nothing -> assertFailure "expand returned Nothing unexpectedly"
        , testCase "Root: returns a Source root and a dep keyed by the target" $
            let combined = Combined db src (mkPackageName "base") VS.full
             in case runIdentity (expand combined Root bottom) of
                    Just (Source _, deps) ->
                        Map.keys deps @?= [basePkg]
                    Just (Installed _, _) -> assertFailure "expected Source root, got Installed"
                    Nothing -> assertFailure "expand Root returned Nothing unexpectedly"
        ]
