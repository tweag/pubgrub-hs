-- | Tests for 'PubGrub.Report.collapseNoInstances', the post-pass that absorbs
-- \"no version for @p@ in @r@\" leaves into the sibling they were resolved against.
--
-- The rendered output of the pass is covered end to end by @PaperSpec@'s golden
-- files. What is covered here is the pass itself, on derivation trees built by hand
-- with 'priorCause' — because the property that makes it sound is not visible in a
-- rendered proof: __it must preserve the node's terms exactly__. It re-labels a
-- derivation step as the leaf it is equivalent to; it must never widen or narrow
-- what the proof claims.
module ReportSpec (tests) where

import qualified Data.Map.Strict                 as Map
import qualified Data.Set                        as Set
import           Distribution.Types.PackageName  (PackageName, mkPackageName)
import           Distribution.Types.Version      (Version, mkVersion)
import           Distribution.Types.VersionRange (earlierVersion,
                                                  orLaterVersion)
import           PubGrub.Incompatibility         (IncompatCause (..),
                                                  Incompatibility (..),
                                                  fromDependency, noInstances,
                                                  onlyInstalled, priorCause)
import           PubGrub.InstanceSet             (InstanceSet (..))
import           PubGrub.InstanceSet.SourceCell  (SourceCell (..))
import           PubGrub.Report                  (collapseNoInstances)
import           PubGrub.SetOps                  (equivalent)
import           PubGrub.Term                    (Term (..))
import qualified PubGrub.VersionSet              as VersionSet
import           Test.Tasty                      (TestTree, testGroup)
import           Test.Tasty.HUnit                (assertBool, assertFailure,
                                                  testCase, (@?=))

-- --------------------------------------------------------------------------
-- Fixtures
-- --------------------------------------------------------------------------

pkgA, pkgQ :: PackageName
pkgA = mkPackageName "a"
pkgQ = mkPackageName "q"

v :: Int -> Version
v n = mkVersion [n]

sourceOnly :: VersionSet.VersionSet -> InstanceSet
sourceOnly vs = InstanceSet{isInstalled = Set.empty, isSource = [SourceCell vs Map.empty]}

-- | @[lo, hi)@, the shape a release slot and a declared range both have.
range :: Int -> Int -> InstanceSet
range lo hi =
    sourceOnly
        ( VersionSet.intersectionVersionSet
            (VersionSet.fromVersionRange (orLaterVersion (v lo)))
            (VersionSet.fromVersionRange (earlierVersion (v hi)))
        )

from :: Int -> InstanceSet
from lo = sourceOnly (VersionSet.fromVersionRange (orLaterVersion (v lo)))

-- | @a@ over @dependers@ depends on @q@ in @1..5@.
dependsOnQ :: InstanceSet -> Incompatibility
dependsOnQ dependers = fromDependency pkgA dependers pkgQ (range 1 5)

-- | The hole the solver learns when a range holds no releases.
hole :: PackageName -> InstanceSet -> Incompatibility
hole = noInstances

causeOf :: Incompatibility -> IncompatCause
causeOf = incompCause

-- | Every cause in the tree, so a test can assert that no hole survives.
causes :: Incompatibility -> [IncompatCause]
causes inc = incompCause inc : case incompCause inc of
    CauseDerivedFrom c1 c2 -> causes c1 ++ causes c2
    _                      -> []

holesIn :: Incompatibility -> Int
holesIn inc = length [() | CauseNoInstances _ _ <- causes inc]

tests :: TestTree
tests =
    testGroup
        "PubGrub.Report.collapseNoInstances"
        [ testGroup "what is absorbed" absorbed
        , testGroup "what is left alone" untouched
        , testGroup "the property that makes it sound" soundness
        ]

-- --------------------------------------------------------------------------
-- What is absorbed
-- --------------------------------------------------------------------------

absorbed :: [TestTree]
absorbed =
    [ -- The shape @references/pubgrub.md:1005@'s own example produces: a dependency
      -- of one release, plus the fact that the rest of the offered range holds
      -- nothing. The step establishes only the union, so it stops being a step.
      testCase "a hole on the depender side becomes one dependency fact" $ do
        let dep = dependsOnQ (range 1 2)
            step = priorCause dep (hole pkgA (range 2 4)) pkgA
        holesIn step @?= 1
        let collapsed = collapseNoInstances step
        holesIn collapsed @?= 0
        case causeOf collapsed of
            CauseDependency p s (q, r) -> do
                (p, q) @?= (pkgA, pkgQ)
                -- the depender is the union of the two, which is what the step
                -- concluded; the dependee is untouched
                assertBool "depender should span 1..4" (s `equivalent` range 1 4)
                assertBool "dependee unchanged" (r `equivalent` range 1 5)
            c -> assertFailure ("expected a dependency leaf, got " ++ describe c)
    , -- Absorbing on the dependee side is a *narrowing* — the empty part of the
      -- declared range comes off — which is why the pass must take the step's own
      -- terms rather than union anything itself.
      testCase "a hole on the dependee side narrows the dependee range" $ do
        let dep = dependsOnQ (range 1 2)
            step = priorCause dep (hole pkgQ (range 4 5)) pkgQ
        case causeOf (collapseNoInstances step) of
            CauseDependency _ _ (q, r) -> do
                q @?= pkgQ
                assertBool "dependee should have lost 4..5" (r `equivalent` range 1 4)
            c -> assertFailure ("expected a dependency leaf, got " ++ describe c)
    , testCase "the pass reaches holes below the root" $ do
        let inner = priorCause (dependsOnQ (range 1 2)) (hole pkgA (range 2 4)) pkgA
            outer = priorCause inner (hole pkgQ (range 4 5)) pkgQ
        holesIn outer @?= 2
        holesIn (collapseNoInstances outer) @?= 0
    ]

-- --------------------------------------------------------------------------
-- What is left alone
-- --------------------------------------------------------------------------

untouched :: [TestTree]
untouched =
    [ -- Two empty ranges do not make a sentence, and there is no dependency to
      -- absorb into.
      testCase "two holes stay a derivation step" $ do
        let step = priorCause (hole pkgA (range 1 2)) (hole pkgA (range 2 4)) pkgA
        case causeOf (collapseNoInstances step) of
            CauseDerivedFrom _ _ -> pure ()
            c -> assertFailure ("expected the step to survive, got " ++ describe c)
    , -- The dependee's *whole* range being empty makes the union over the pivot ⊤,
      -- so the dependee entry drops out of the step's terms. Rebuilding from those
      -- terms would produce a dependency fact with no dependee range in it, and the
      -- proof would never mention @q@ at all. The report's @pair@ renders this
      -- case as "depends on …, which has no versions", which keeps the range.
      testCase "a wholly empty dependee range stays a derivation step" $ do
        let dep = dependsOnQ (range 1 2)
            step = priorCause dep (hole pkgQ (range 1 5)) pkgQ
        Map.size (incompTerms step) @?= 1
        case causeOf (collapseNoInstances step) of
            CauseDerivedFrom _ _ -> pure ()
            c -> assertFailure ("expected the step to survive, got " ++ describe c)
    , -- Only dependency facts are absorbed into. A hole resolved against "cannot be
      -- built from source" would have to widen *that* claim, which would say the
      -- empty range cannot be built from source — a different and false statement.
      testCase "a hole is not absorbed into a boot-package fact" $ do
        let step = priorCause (onlyInstalled pkgA (from 1)) (hole pkgA (range 1 2)) pkgA
        case causeOf (collapseNoInstances step) of
            CauseDerivedFrom _ _ -> pure ()
            c -> assertFailure ("expected the step to survive, got " ++ describe c)
    , -- pubgrub-rs leaves this one too (its @collapse_no_versions@ carries a TODO).
      -- Dropping the hole here would print a conclusion wider than the two causes
      -- named on the line justify, because the widening is what the hole paid for.
      testCase "a hole against a derived sibling stays a derivation step" $ do
        let inner = priorCause (dependsOnQ (range 1 2)) (dependsOnQ (range 2 3)) pkgQ
            step = priorCause inner (hole pkgA (range 3 4)) pkgA
        case causeOf (collapseNoInstances step) of
            CauseDerivedFrom _ _ -> pure ()
            c -> assertFailure ("expected the step to survive, got " ++ describe c)
    ]

-- --------------------------------------------------------------------------
-- Soundness
-- --------------------------------------------------------------------------

soundness :: [TestTree]
soundness =
    [ -- The whole argument for the pass: it changes how a step is *explained*, never
      -- what it claims. If this ever fails, the proof has started asserting something
      -- the solver did not derive.
      testCase "the terms of every collapsed node are unchanged" $ do
        let inner = priorCause (dependsOnQ (range 1 2)) (hole pkgA (range 2 4)) pkgA
            outer = priorCause inner (hole pkgQ (range 4 5)) pkgQ
        mapM_ sameTerms [inner, outer]
    ]
  where
    sameTerms inc = do
        let collapsed = collapseNoInstances inc
        Map.keys (incompTerms collapsed) @?= Map.keys (incompTerms inc)
        sequence_
            [ assertBool
                ("term for " ++ show p ++ " changed")
                (sameTerm t (Map.lookup p (incompTerms collapsed)))
            | (p, t) <- Map.toList (incompTerms inc)
            ]

    sameTerm (Positive a) (Just (Positive b)) = a `equivalent` b
    sameTerm (Negative a) (Just (Negative b)) = a `equivalent` b
    sameTerm _ _                              = False

describe :: IncompatCause -> String
describe CauseRoot{}          = "CauseRoot"
describe CauseNoInstances{}   = "CauseNoInstances"
describe CauseOnlyInstalled{} = "CauseOnlyInstalled"
describe CauseUnbuildable{}   = "CauseUnbuildable"
describe CauseDependency{}    = "CauseDependency"
describe CauseDerivedFrom{}   = "CauseDerivedFrom"
