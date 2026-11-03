-- | Tests for 'PubGrub.Cabal.Installed.closureEdges': the walk over the compiler's
-- unit graph that turns "we chose this installed unit" into every dependency
-- edge of its transitive closure.
--
-- Choosing an installed unit fixes that whole closure — it is a compiled
-- artifact linked against exactly those units — so the provider emits all the
-- edges at once and lets unit propagation chain through them in one fixpoint.
-- What these tests pin down is that the walk is /edges/, not a star from the
-- root: each edge must name the unit that actually declares it, because that is
-- what keeps every emitted incompatibility a genuine direct dependency (and so
-- keeps @CauseDependency@ truthful in reports).
--
-- The dbs here are hand-built, so nothing needs a compiler or an index.
module InstalledSpec (tests) where

import qualified Data.Map.Strict                as Map
import           Distribution.Types.PackageName (PackageName, mkPackageName)
import           Distribution.Types.UnitId      (UnitId, mkUnitId)
import           Distribution.Version           (mkVersion)
import           PubGrub.Cabal.Installed        (InstalledDb (..),
                                                 InstalledEdge (..),
                                                 InstalledPkg (..),
                                                 closureEdges, mkInstalledDb)
import           PubGrub.Cabal.PreInstalled     (PreInstalledPackage (..))
import           Test.Tasty                     (TestTree, testGroup)
import           Test.Tasty.HUnit               (assertBool, testCase, (@?=))

-- | A unit whose id and package name are both the given string, at 1.0.
unit :: String -> [String] -> InstalledPkg
unit n deps =
    InstalledPkg
        { ipUnitId = mkUnitId n
        , ipName = mkPackageName n
        , ipVersion = mkVersion [1, 0]
        , ipDepends = map mkUnitId deps
        }

-- | Edges as @(depender, dependee)@ unit-id pairs, which is all these tests
-- need to look at.
edgesOf :: [InstalledPkg] -> String -> [(UnitId, UnitId)]
edgesOf pkgs root =
    [ (pipUnitId from, pipUnitId to)
    | InstalledEdge (_, from) (_, to) <- closureEdges (mkInstalledDb pkgs) (mkUnitId root)
    ]

edge :: String -> String -> (UnitId, UnitId)
edge a b = (mkUnitId a, mkUnitId b)

-- | The package names an edge relates — the solver variables it is keyed by.
namesOf :: [InstalledPkg] -> String -> [(PackageName, PackageName)]
namesOf pkgs root =
    [ (from, to)
    | InstalledEdge (from, _) (to, _) <- closureEdges (mkInstalledDb pkgs) (mkUnitId root)
    ]

tests :: TestTree
tests =
    testGroup
        "PubGrub.Cabal.Installed.closureEdges"
        [ testCase "a chain reaches the far end, each edge naming its own depender" $
            -- Not a --> c edge: the second edge is b --> c, because b is what
            -- declares it. A star from the root would report a dependency that
            -- does not exist.
            edgesOf [unit "a" ["b"], unit "b" ["c"], unit "c" []] "a"
                @?= [edge "a" "b", edge "b" "c"]
        , testCase "edges carry package names, not just unit ids" $
            namesOf [unit "a" ["b"], unit "b" []] "a"
                @?= [(mkPackageName "a", mkPackageName "b")]
        , testCase "a diamond emits both incoming edges but expands the sink once" $
            -- b --> d and c --> d are different facts and both must be emitted;
            -- d itself is walked once, so d --> e appears once. The order is
            -- depth-first, which is why d --> e lands before c --> d.
            edgesOf
                [ unit "a" ["b", "c"]
                , unit "b" ["d"]
                , unit "c" ["d"]
                , unit "d" ["e"]
                , unit "e" []
                ]
                "a"
                @?= [ edge "a" "b"
                    , edge "a" "c"
                    , edge "b" "d"
                    , edge "d" "e"
                    , edge "c" "d"
                    ]
        , testCase "a cycle terminates and yields each edge once" $
            edgesOf [unit "a" ["b"], unit "b" ["a"]] "a"
                @?= [edge "a" "b", edge "b" "a"]
        , testCase "a self-dependency emits no edge" $
            -- An incompatibility whose two terms name the same package
            -- collapses to a single bogus term, so this must never be emitted.
            let es = edgesOf [unit "a" ["a", "b"], unit "b" []] "a"
             in do
                    assertBool "no self-edge" (all (uncurry (/=)) es)
                    es @?= [edge "a" "b"]
        , testCase "a dependency on another unit of the same package emits no edge" $
            -- A library linked against its own installed sublibrary: both
            -- units are named a, so the edge would say "if a is a, then a is
            -- a:sub", which bans the unit just chosen.
            let sub = (unit "a:sub" []) {ipName = mkPackageName "a"}
             in namesOf [unit "a" ["a:sub", "b"], sub, unit "b" []] "a"
                    @?= [(mkPackageName "a", mkPackageName "b")]
        , testCase "a unit id listed twice keeps its last entry, by id and by name" $
            -- The two indexes must describe the same units: the provider
            -- offers instances by name and walks closures by id.
            let older = (unit "a" []) {ipVersion = mkVersion [0, 9]}
                db = mkInstalledDb [older, unit "a" []]
             in do
                    fmap ipVersion (Map.lookup (mkUnitId "a") (idbById db)) @?= Just (mkVersion [1, 0])
                    map ipVersion (Map.findWithDefault [] (mkPackageName "a") (idbByName db)) @?= [mkVersion [1, 0]]
        , testCase "a repeated dependency yields one edge" $
            edgesOf [unit "a" ["b", "b"], unit "b" ["c"], unit "c" []] "a"
                @?= [edge "a" "b", edge "b" "c"]
        , testCase "a dangling unit id contributes no edge" $
            edgesOf [unit "a" ["ghost", "b"], unit "b" []] "a"
                @?= [edge "a" "b"]
        , testCase "a root absent from the db has no closure" $
            edgesOf [unit "b" []] "a" @?= []
        , testCase "a leaf has no edges" $
            edgesOf [unit "a" []] "a" @?= []
        , testCase "the walk is deterministic" $
            let pkgs = [unit "a" ["c", "b"], unit "b" ["d"], unit "c" ["d"], unit "d" []]
             in edgesOf pkgs "a" @?= edgesOf pkgs "a"
        , testCase "dependency order is followed, not name order" $
            edgesOf [unit "a" ["c", "b"], unit "b" [], unit "c" []] "a"
                @?= [edge "a" "c", edge "a" "b"]
        ]
