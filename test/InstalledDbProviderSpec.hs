{-# LANGUAGE ScopedTypeVariables #-}

module InstalledDbProviderSpec (tests) where

import           Data.Functor.Identity          (runIdentity)
import qualified Data.Map.Strict                as Map
import qualified Data.Set                       as Set
import           Distribution.Types.PackageName (mkPackageName)
import           Distribution.Types.UnitId      (UnitId, mkUnitId)
import           Distribution.Version           (mkVersion)
import           InstalledDbProvider            (InstalledDbProvider,
                                                 installedInRange,
                                                 mkInstalledDbProvider)
import           Pkg                            (Pkg (..))
import           PubGrub.Cabal.InstalledDb      (InstalledPkg (..))
import           PubGrub.Lattice                (singleton)
import           PubGrub.Pow                    (Pow (..))
import           PubGrub.Solver                 (expand)
import qualified PubGrub.VersionSet             as VS
import           Test.Tasty                     (TestTree, testGroup)
import           Test.Tasty.HUnit               (testCase, (@?=))

ip :: String -> String -> [Int] -> [String] -> InstalledPkg
ip uid nm v deps =
    InstalledPkg (mkUnitId uid) (mkPackageName nm) (mkVersion v) (map mkUnitId deps)

db :: InstalledDbProvider
db =
    mkInstalledDbProvider
        [ ip "ghc-prim-0.11-a" "ghc-prim" [0, 11] []
        , ip "base-4.21-b" "base" [4, 21] ["ghc-prim-0.11-a"]
        , ip "base-4.20-c" "base" [4, 20] ["ghc-prim-0.11-a"]
        ]

tests :: TestTree
tests =
    testGroup
        "InstalledDbProvider"
        [ testCase "installedInRange returns matching unit-ids" $
            installedInRange db (mkPackageName "base") VS.full
                @?= Incl (Set.fromList [mkUnitId "base-4.21-b", mkUnitId "base-4.20-c"])
        , testCase "installedInRange filters by version" $
            installedInRange db (mkPackageName "base")
                (VS.singleton (mkVersion [4, 20]))
                @?= Incl (Set.singleton (mkUnitId "base-4.20-c"))
        , testCase "expand picks the newest in-set unit-id" $
            let allBase = installedInRange db (mkPackageName "base") VS.full
             in case runIdentity (expand db (Pkg (mkPackageName "base")) allBase) of
                    Just (uid, _) -> uid @?= mkUnitId "base-4.21-b"
                    Nothing       -> fail "expand returned Nothing unexpectedly"
        , testCase "expand returns installed deps grouped by package" $
            let allBase = installedInRange db (mkPackageName "base") VS.full
             in case runIdentity (expand db (Pkg (mkPackageName "base")) allBase) of
                    Just (_, deps) ->
                        deps
                            @?= Map.singleton
                                (Pkg (mkPackageName "ghc-prim"))
                                (singleton (mkUnitId "ghc-prim-0.11-a") :: Pow UnitId)
                    Nothing -> fail "expand returned Nothing unexpectedly"
        , testCase "expand of an empty set is Nothing" $
            runIdentity (expand db (Pkg (mkPackageName "base")) (Incl Set.empty))
                @?= (Nothing :: Maybe (UnitId, Map.Map Pkg (Pow UnitId)))
        ]
