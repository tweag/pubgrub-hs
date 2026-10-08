-- | Tests for 'PubGrub.Report.collapseNoInstances', the post-pass that absorbs
-- \"no version for @p@ in @r@\" leaves into the sibling they were resolved against.
--
-- The rendered output of the pass is covered end to end by @PaperSpec@'s golden
-- files. What is covered here is the pass itself, on derivation trees built by hand
-- with 'resolveOn' — because the property that makes it sound is not visible in a
-- rendered proof: __it must preserve the node's terms exactly__. It re-labels a
-- derivation step as the leaf it is equivalent to; it must never widen or narrow
-- what the proof claims.
module ReportSpec (tests) where

import           Data.List                       (isInfixOf)
import qualified Data.List.NonEmpty              as NE
import qualified Data.Map.Strict                 as Map
import qualified Data.Set                        as Set
import           Distribution.Types.PackageName  (PackageName, mkPackageName)
import           Distribution.Types.PkgconfigDependency (PkgconfigDependency (..))
import           Distribution.Types.PkgconfigName (mkPkgconfigName)
import           Distribution.Types.PkgconfigVersionRange (anyPkgconfigVersion)
import qualified Distribution.Types.Version      as Cabal
import           PubGrub.Version                 (Version)
import qualified PubGrub.Version                 as V
import           Distribution.Types.VersionRange (earlierVersion,
                                                  orLaterVersion)
import           PubGrub.Cabal                   (Cabal,
                                                  IncompatCause (..),
                                                  UnbuildableReason (..),
                                                  fromDependency,
                                                  onlyInstalled,
                                                  request,
                                                  unbuildable)
import           PubGrub.Incompatibility         (Incompatibility (..),
                                                  noInstances,
                                                  priorCause)
import           PubGrub.InstanceSet             (InstanceSet (..))
import           PubGrub.Value                   (ValueSet (..))
import           PubGrub.Variable                (Var (..))
import           PubGrub.Report                  (collapseNoInstances,
                                                  reportConflict,
                                                  reportHeadline, styleProof,
                                                  wrapProof)
import           PubGrub.SetOps                  (equivalent)
import           PubGrub.Term                    (Term (..))
import qualified Data.Text                       as T
import qualified PubGrub.VersionSet              as VersionSet
import           Test.Tasty                      (TestTree, testGroup)
import           Test.Tasty.HUnit                (assertBool, assertFailure,
                                                  testCase, (@?=))

-- --------------------------------------------------------------------------
-- Fixtures
-- --------------------------------------------------------------------------

pkgA, pkgB, pkgQ, pkgR, pkgS, pkgBase :: PackageName
pkgA = mkPackageName "a"
pkgBase = mkPackageName "base"
pkgB = mkPackageName "b"
pkgQ = mkPackageName "q"
pkgR = mkPackageName "r"
pkgS = mkPackageName "s"

v :: Int -> Version
v n = V.mkVersion [n]

-- | The same, as a Cabal version: what a declared range is written with.
cv :: Int -> Cabal.Version
cv n = Cabal.mkVersion [n]

sourceOnly :: VersionSet.VersionSet -> InstanceSet
sourceOnly vs = InstanceSet{isInstalled = Set.empty, isSource = vs}

-- | An unconditional dependency fact, the shape every fact here has.
dependency :: PackageName -> InstanceSet -> PackageName -> InstanceSet -> Incompatibility Cabal
dependency p s q r = fromDependency p s Map.empty q r

-- | A resolution step on a package.
resolveOn :: Incompatibility Cabal -> Incompatibility Cabal -> PackageName -> Incompatibility Cabal
resolveOn a b p = priorCause a b (PackageVar p)

-- | @[lo, hi)@, the shape a release slot and a declared range both have.
range :: Int -> Int -> InstanceSet
range lo hi =
    sourceOnly
        ( VersionSet.intersectionVersionSet
            (VersionSet.fromVersionRange (orLaterVersion (cv lo)))
            (VersionSet.fromVersionRange (earlierVersion (cv hi)))
        )

from :: Int -> InstanceSet
from lo = sourceOnly (VersionSet.fromVersionRange (orLaterVersion (cv lo)))

-- | @a@ over @dependers@ depends on @q@ in @1..5@.
dependsOnQ :: InstanceSet -> Incompatibility Cabal
dependsOnQ dependers = dependency pkgA dependers pkgQ (range 1 5)

-- | The hole the solver learns when a range holds no releases.
hole :: PackageName -> InstanceSet -> Incompatibility Cabal
hole p s = noInstances (PackageVar p) (PackageSet s)

causeOf :: Incompatibility Cabal -> IncompatCause
causeOf = incompCause

-- | Every cause in the tree, so a test can assert that no hole survives.
causes :: Incompatibility Cabal -> [IncompatCause]
causes inc = incompCause inc : case incompCause inc of
    CauseDerivedFrom c1 c2 -> causes c1 ++ causes c2
    _                      -> []

holesIn :: Incompatibility Cabal -> Int
holesIn inc = length [() | CauseNoInstances _ _ <- causes inc]

tests :: TestTree
tests =
    testGroup
        "PubGrub.Report.collapseNoInstances"
        [ testGroup "what is absorbed" absorbed
        , testGroup "what is left alone" untouched
        , testGroup "the property that makes it sound" soundness
        , testGroup "a run of same-pair steps is one sentence" sameePairRun
        , testGroup "a run collected by depender alone is one sentence" widenedRun
        , testGroup "the boot-package leaf" bootLeaf
        , testGroup "the unbuildable leaf" unbuildableLeaf
        , testGroup "the headline" headline
        , testGroup "wrapping" wrapping
        , testGroup "styling" styling
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
            step = resolveOn dep (hole pkgA (range 2 4)) pkgA
        holesIn step @?= 1
        let collapsed = collapseNoInstances step
        holesIn collapsed @?= 0
        case causeOf collapsed of
            CauseDependency p s _ (q, r) -> do
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
            step = resolveOn dep (hole pkgQ (range 4 5)) pkgQ
        case causeOf (collapseNoInstances step) of
            CauseDependency _ _ _ (q, r) -> do
                q @?= pkgQ
                assertBool "dependee should have lost 4..5" (r `equivalent` range 1 4)
            c -> assertFailure ("expected a dependency leaf, got " ++ describe c)
    , testCase "the pass reaches holes below the root" $ do
        let inner = resolveOn (dependsOnQ (range 1 2)) (hole pkgA (range 2 4)) pkgA
            outer = resolveOn inner (hole pkgQ (range 4 5)) pkgQ
        holesIn outer @?= 2
        holesIn (collapseNoInstances outer) @?= 0
    ]

-- --------------------------------------------------------------------------
-- Collapsing a run of steps that all say the same kind of thing
-- --------------------------------------------------------------------------

-- | @a@ over @dependers@ depends on @q@ over @dependees@.
aDependsOn :: InstanceSet -> InstanceSet -> Incompatibility Cabal
aDependsOn dependers dependees = dependency pkgA dependers pkgQ dependees

-- | A linear chain of steps, each adding one more range of @a@ with a slightly
-- wider requirement on @q@ — the shape a proof takes when it walks a
-- dependency's bound history one adjacent pair at a time.
chainOf :: [(InstanceSet, InstanceSet)] -> Incompatibility Cabal
chainOf [] = error "chainOf: needs at least two facts"
chainOf ((s0, r0) : rest) =
    foldl step (aDependsOn s0 r0) rest
  where
    step acc (s, r) = resolveOn acc (aDependsOn s r) pkgA

proofLines :: Incompatibility Cabal -> [String]
proofLines = map T.unpack . T.lines . reportConflict

sameePairRun :: [TestTree]
sameePairRun =
    [ testCase "four same-pair steps collapse below one line each" $ do
        let inc = chainOf [(range 1 2, range 1 5), (range 2 3, range 1 6), (range 3 4, range 1 7), (range 4 5, range 1 8)]
            ls = proofLines inc
        assertBool
            ("expected fewer lines than facts, got:\n" ++ unlines ls)
            (length ls < 4)
    , -- The collapsed sentence may only state the union of the facts it stands in
      -- for. Each says @a in Si@ requires @q in Ri@, so together they imply that
      -- @a in union S@ requires @q in union R@, since every @Ri@ lies within it.
      testCase "the collapsed sentence states the union, not one member" $ do
        let inc = chainOf [(range 1 2, range 1 5), (range 2 3, range 1 6), (range 3 4, range 1 7), (range 4 5, range 1 8)]
            proof = unlines (proofLines inc)
        assertBool
            ("the widest dependee bound should appear:\n" ++ proof)
            ("<8" `isInfixOf` proof)
    , -- Rule 3 keys on the (depender, dependee) pair, and rule 5 takes over where
      -- the dependee changes. Either way no dependee may be dropped: a sentence
      -- that stood for a fact about @r@ and did not mention @r@ would be claiming
      -- something the facts do not say.
      testCase "a step about a different dependee keeps that dependee named" $ do
        let other = dependency pkgA (range 3 4) (mkPackageName "r") (range 1 9)
            base = resolveOn (aDependsOn (range 1 2) (range 1 5)) (aDependsOn (range 2 3) (range 1 6)) pkgA
            inc = resolveOn base other pkgA
            proof = unlines (proofLines inc)
        assertBool ("r should still be named:\n" ++ proof) ("r " `isInfixOf` proof)
    ]

-- --------------------------------------------------------------------------
-- Rule 5: a run collected by depender alone is one sentence
-- --------------------------------------------------------------------------

-- | @a@ over @dependers@ depends on @dependee@ over @dependees@ — like
-- 'aDependsOn', but the dependee is the caller's, which is the whole point of
-- rule 5.
aRequires :: InstanceSet -> String -> InstanceSet -> Incompatibility Cabal
aRequires dependers dependee dependees =
    dependency pkgA dependers (mkPackageName dependee) dependees

-- | A chain of steps that all name @a@ as the depender and nothing else in
-- common: the shape a proof takes when it walks a target's whole version
-- history, one release and one unrelated dependency at a time.
mixedChainOf :: [(InstanceSet, String, InstanceSet)] -> Incompatibility Cabal
mixedChainOf [] = error "mixedChainOf: needs at least two facts"
mixedChainOf ((s0, q0, r0) : rest) = foldl step (aRequires s0 q0 r0) rest
  where
    step acc (s, q, r) = resolveOn acc (aRequires s q r) pkgA

widenedRun :: [TestTree]
widenedRun =
    [ -- Four facts about @a@ and four different dependees. Rule 3 cannot touch
      -- this — no two facts share a dependee — so without rule 5 it costs a line
      -- for every two facts.
      testCase "four steps with four dependees collapse below one line each" $ do
        let inc =
                mixedChainOf
                    [ (range 1 2, "q", range 1 5)
                    , (range 2 3, "r", range 1 6)
                    , (range 3 4, "s", range 1 7)
                    , (range 4 5, "t", range 1 8)
                    ]
            ls = proofLines inc
        assertBool
            ("expected fewer lines than facts, got:\n" ++ unlines ls)
            (length ls < 4)
    , -- The collapsed sentence stands in for every fact in the run, so every
      -- dependee it collected has to appear in it. Dropping one would be claiming
      -- that a range of @a@ requires less than it does.
      testCase "every dependee of the run is named" $ do
        let inc =
                mixedChainOf
                    [ (range 1 2, "q", range 1 5)
                    , (range 2 3, "r", range 1 6)
                    , (range 3 4, "s", range 1 7)
                    , (range 4 5, "t", range 1 8)
                    ]
            proof = unlines (proofLines inc)
        mapM_
            (\d -> assertBool (d ++ " should be named:\n" ++ proof) (d `isInfixOf` proof))
            ["q ", "r ", "s ", "t "]
    , -- The depender's range is the union of the run's, and it may be neither
      -- wider nor narrower: wider claims facts the run does not have, narrower
      -- drops one it does. The chain is closed with a request for that union,
      -- as the solver closes a terminal derivation, so the union is a line's
      -- conclusion rather than the proof's last word.
      testCase "the depender is the union of the run's ranges" $ do
        let chain =
                mixedChainOf
                    [ (range 1 2, "q", range 1 5)
                    , (range 2 3, "r", range 1 6)
                    , (range 3 4, "s", range 1 7)
                    ]
            inc = resolveOn chain (request pkgA (range 1 4)) pkgA
            proof = unlines (proofLines inc)
        assertBool
            ("a should span 1..4 in one sentence:\n" ++ proof)
            (">=1 && <4" `isInfixOf` proof)
    , -- Two facts already fit one line with both of them named, and naming both
      -- says strictly more than naming their union. The union has to buy a line
      -- to be worth taking, so a two-fact run is left to the ordinary skip.
      testCase "two facts are named, not merged" $ do
        let inc = mixedChainOf [(range 1 2, "q", range 1 5), (range 2 3, "r", range 1 6)]
            proof = unlines (proofLines inc)
        assertBool
            ("both declared bounds should survive:\n" ++ proof)
            ("<5" `isInfixOf` proof && "<6" `isInfixOf` proof)
    , -- The union argument is about one depender. Where a package is a depender
      -- in one fact and a dependee in another the run has two subjects, no union
      -- fact stands for it, and the steps must stay separate.
      testCase "a second depender stops the run" $ do
        let inc =
                resolveOn
                    (mixedChainOf [(range 1 2, "q", range 1 5), (range 2 3, "r", range 1 6)])
                    (dependency pkgQ (range 1 5) pkgA (range 3 4))
                    pkgA
            proof = unlines (proofLines inc)
        assertBool ("q should be named as a depender:\n" ++ proof) ("q " `isInfixOf` proof)
    ]

-- --------------------------------------------------------------------------
-- What is left alone
-- --------------------------------------------------------------------------

-- | The boot-package leaf. The bound that failed is only legible against the
-- installed version, and nothing else in a proof states it.
bootLeaf :: [TestTree]
bootLeaf =
    [ testCase "a boot package's fact names the installed version" $ do
        let proof = unlines (proofLines (onlyInstalled pkgA [v 3] (from 1)))
        assertBool proof ("a is pinned to 3 (installed)" `isInfixOf` proof)
    , testCase "two installed versions are both named" $ do
        let proof = unlines (proofLines (onlyInstalled pkgA [v 3, v 2] (from 1)))
        assertBool proof ("a is pinned to 3 or 2 (installed)" `isInfixOf` proof)
    , testCase "a boot package with no installed unit says so" $ do
        let proof = unlines (proofLines (onlyInstalled pkgA [] (from 1)))
        assertBool proof ("a is not installed and cannot be built from source" `isInfixOf` proof)
    ]

-- | The unbuildable leaf. It names what rules the release out — the module
-- @pkg-config@ could not find, spelled as Cabal-syntax spells the field — rather
-- than saying only that it cannot be built. A lone leaf is rendered as the whole
-- proof here, range and all.
unbuildableLeaf :: [TestTree]
unbuildableLeaf =
    [ testCase "a missing pkg-config module is named" $ do
        let proof = unlines (proofLines (unbuildable pkgA (from 1) (NE.singleton (missing "libpq"))))
        assertBool proof ("a >=1 needs pkg-config package libpq, which is not found" `isInfixOf` proof)
    , testCase "several missing modules share one needs, in order" $ do
        let proof = unlines (proofLines (unbuildable pkgA (from 1) (NE.fromList [missing "libpq", missing "zlib"])))
        assertBool proof ("a >=1 needs pkg-config packages libpq and zlib, which are not found" `isInfixOf` proof)
    , testCase "buildable: False says so" $ do
        let proof = unlines (proofLines (unbuildable pkgA (from 1) (NE.singleton NotBuildable)))
        assertBool proof ("a >=1 is marked buildable: False" `isInfixOf` proof)
    , testCase "both kinds of reason are joined with and" $ do
        let proof = unlines (proofLines (unbuildable pkgA (from 1) (NE.fromList [NotBuildable, missing "libpq"])))
        assertBool proof ("a >=1 is marked buildable: False and needs pkg-config package libpq, which is not found" `isInfixOf` proof)
    ]

-- | A @pkgconfig-depends@ on the module at any version.
missing :: String -> UnbuildableReason
missing name = MissingPkgConfig (PkgconfigDependency (mkPkgconfigName name) anyPkgconfigVersion)

-- | The line above the proof: the request as the proof names it, and the
-- world-fact leaves verbatim. A terminal derivation ends by resolving against
-- the seeds it rests on, as 'PubGrub.Solver' closes it, so the seeds are its
-- last external facts.
headline :: [TestTree]
headline =
    [ -- The second line names the package the search gave up on: the pivot of
      -- a step that dropped it after a step below had narrowed it. Here @q@ is
      -- refuted a piece at a time — @[1,3)@ through @r@, @>=3@ through @s@ —
      -- and the only thing left standing at the dropping step is the depender.
      testCase "names the package refuted a piece at a time, and who depends on it" $ do
        let aNeedsQ = dependency pkgA (range 1 2) pkgQ (from 1)
            lowQ = resolveOn (dependency pkgQ (range 1 3) pkgR (range 1 2)) (hole pkgR (range 1 2)) pkgR
            highQ = resolveOn (dependency pkgQ (from 3) pkgS (range 1 2)) (hole pkgS (range 1 2)) pkgS
            narrowed = resolveOn aNeedsQ lowQ pkgQ
            dropped' = resolveOn narrowed highQ pkgQ
            inc = resolveOn dropped' (request pkgA (range 1 2)) pkgA
        T.unpack (reportHeadline inc)
            @?= "No solution for a >=1 && <2.\nNo version of q suits a >=1 && <2."
    , -- With something present that is not a depender, the step's terms are
      -- what @q@ cannot be reconciled with, and the depender is named after.
      testCase "names what the package cannot be reconciled with" $ do
        let aNeedsQ = dependency pkgA (range 1 2) pkgQ (from 1)
            lowQ = resolveOn (dependency pkgQ (range 1 3) pkgR (range 1 2)) (hole pkgR (range 1 2)) pkgR
            highQ = resolveOn (dependency pkgQ (from 3) pkgS (range 1 2)) (dependency pkgB (range 1 2) pkgS (from 2)) pkgS
            narrowed = resolveOn aNeedsQ lowQ pkgQ
            dropped' = resolveOn narrowed highQ pkgQ
            inc = resolveOn (resolveOn dropped' (request pkgA (range 1 2)) pkgA) (request pkgB (range 1 2)) pkgB
        T.unpack (reportHeadline inc)
            @?= "No solution for a >=1 && <2 and b >=1 && <2.\na >=1 && <2 needs q, and no version of q is compatible with a >=1 && <2 and b >=1 && <2 together."
    , -- Where the proof rests on a pinned package, the line joins who wants
      -- @q@, the window they leave for it, and the wall it fails against: the
      -- step "q >=1 && <5 is forbidden" with the pinned base among its premises.
      testCase "against a wall, names the window and the wall" $ do
        let aNeedsQ = dependency pkgA (range 1 2) pkgQ (range 1 5)
            qNeedsOldBase = dependency pkgQ (range 1 5) pkgBase (range 0 4)
            qForbidden = resolveOn qNeedsOldBase (onlyInstalled pkgBase [v 5] (from 0)) pkgBase
            inc = resolveOn (resolveOn aNeedsQ qForbidden pkgQ) (request pkgA (range 1 2)) pkgA
        T.unpack (reportHeadline inc)
            @?= "No solution for a >=1 && <2: base is pinned to 5 (installed).\na >=1 && <2 needs q >=1 && <5, and no q there builds on base 5 (installed)."
    , -- A package refuted in one step was not given up on piece by piece, so
      -- nothing is added: the proof's two lines already say it all.
      testCase "a package refuted in one step earns no second line" $ do
        let inc =
                resolveOn
                    (resolveOn (dependency pkgA (range 1 2) pkgQ (range 1 5)) (hole pkgQ (range 1 5)) pkgQ)
                    (request pkgA (range 1 2))
                    pkgA
        T.unpack (reportHeadline inc) @?= "No solution for a >=1 && <2."
    , testCase "names the request and the wall" $ do
        let inc = resolveOn (onlyInstalled pkgA [v 3] (from 1)) (request pkgA (range 1 2)) pkgA
        T.unpack (reportHeadline inc) @?= "No solution for a >=1 && <2: a is pinned to 3 (installed)."
    , -- The reason is part of the fact, so it is part of the wall.
      testCase "an unbuildable wall carries its reason" $ do
        let inc = resolveOn (unbuildable pkgA (from 1) (NE.singleton (missing "libpq"))) (request pkgA (range 1 2)) pkgA
        T.unpack (reportHeadline inc)
            @?= "No solution for a >=1 && <2: a >=1 needs pkg-config package libpq, which is not found."
    , testCase "a pure version conflict has no wall" $ do
        let inc = resolveOn (hole pkgA (range 1 2)) (request pkgA (range 1 2)) pkgA
        T.unpack (reportHeadline inc) @?= "No solution for a >=1 && <2."
    , -- Only the seeds the proof reaches are the request; a target the derivation
      -- never used did not fail.
      testCase "names every seed in the proof, once" $ do
        let inc =
                resolveOn
                    (resolveOn (aDependsOn (range 1 2) (range 5 9)) (request pkgA (range 1 2)) pkgA)
                    (request pkgQ (range 1 5))
                    pkgQ
        T.unpack (reportHeadline inc) @?= "No solution for a >=1 && <2 and q >=1 && <5."
    , -- The closing line of such a proof: the seeds, and failure by name.
      testCase "the last line names the seeds and concludes failure" $ do
        let inc =
                resolveOn
                    (resolveOn (aDependsOn (range 1 2) (range 5 9)) (request pkgA (range 1 2)) pkgA)
                    (request pkgQ (range 1 5))
                    pkgQ
        T.unpack (reportConflict inc)
            @?= "Because a >=1 && <2 depends on q >=5 && <9 and a >=1 && <2 is requested, q >=5 && <9 is required.\nSo, because q >=1 && <5 is requested, version solving failed."
    ]

-- | 'wrapProof': a hanging indent, and never a break inside a range.
wrapping :: [TestTree]
wrapping =
    [ testCase "a short line is left alone" $
        wrapped 80 short @?= [short]
    , testCase "a blank line stays blank" $
        T.unpack (wrapProof 80 (T.pack "a\n\nb")) @?= "a\n\nb"
    , testCase "continuation lines carry the indent and fit the width" $ do
        let ls = wrapped 60 long
        assertBool (show ls) (length ls > 1)
        mapM_ (\l -> assertBool ("too long: " ++ l) (length l <= 60)) ls
        mapM_ (\l -> assertBool ("no indent: " ++ l) (take 4 l == "    ")) (drop 1 ls)
    , testCase "a range is never split" $ do
        let ls = wrapped 60 long
        mapM_
            (\l -> assertBool ("starts inside a range: " ++ l)
                (not (any (`isPrefixOf'` dropWhile (== ' ') l) [">=", "<", "&&", "(installed)"])))
            ls
    , testCase "the words survive, in order" $
        words (unwords (wrapped 60 long)) @?= words long
    , testCase "a preposition is not left at the end of a line" $
        mapM_
            (\l -> assertBool ("dangling: " ++ l) (not (any (`isSuffixOf'` l) [" on", " of", " to", " with", " depends"])))
            (wrapped 60 long ++ wrapped 40 long ++ wrapped 50 long)
    , -- The haddock bound is a hundred characters of one range. It has to break
      -- somewhere, and the only honest place is before a "||".
      testCase "an atom too long for a line breaks before ||" $ do
        let ls = wrapped 60 seven
        assertBool (show ls) (length ls > 1)
        mapM_ (\l -> assertBool ("too long: " ++ l) (length l <= 60)) ls
        mapM_
            (\l -> assertBool ("bad break: " ++ l) ("|| " `isPrefixOf'` dropWhile (== ' ') l))
            (drop 1 ls)
    ]
  where
    wrapped n = map T.unpack . T.lines . wrapProof n . T.pack
    isPrefixOf' p s = take (length p) s == p
    isSuffixOf' p s = reverse (take (length p) (reverse s)) == p
    short = "So, because foo is requested, version solving failed."
    long = "Because aeson >=1.1.0.0 && <1.2.2.0 depends on base >=4.5 && <4.13 and bytestring >=0.10.0.1 && <0.10.6.0 || >=0.10.8.1 && <0.10.9.0 depends on base 4.21.0.0 (installed), aeson >=0.8.1.0 && <1.4.7.0 requires base >=4.2 && <4.15."
    seven = "base ^>=4.13.0.0 || ^>=4.14.0.0 || ^>=4.15.0.0 || ^>=4.16.0.0 || ^>=4.17.0.0 || ^>=4.18.0.0 || ^>=4.19.0.0."

-- | 'styleProof': escapes around what is there, and nothing else.
styling :: [TestTree]
styling =
    [ testCase "stripping the escapes gives the input back" $ do
        let inp = T.pack (unlines' [headline', "", sentence, continuation, conclusion])
        stripEscapes (styleProof inp) @?= inp
    , testCase "a range is dimmed and a package name is not" $ do
        let out = T.unpack (styleProof (T.pack sentence))
        assertBool out ("\ESC[2m>=1.0 && <2\ESC[0m" `isInfixOf` out)
        assertBool out (not ("\ESC[2mfoo" `isInfixOf` out) && not ("\ESC[1mfoo" `isInfixOf` out))
    , testCase "the connective is bold and a continuation line has none" $ do
        assertBool "opener" ("\ESC[1mAnd\ESC[0m \ESC[1mbecause\ESC[0m" `isInfixOf` T.unpack (styleProof (T.pack sentence)))
        assertBool "numbered" ("\ESC[1m1.\ESC[0m" `isInfixOf` T.unpack (styleProof (T.pack ("1. " ++ sentence))))
        assertBool "continuation" (not ("\ESC[1m" `isInfixOf` T.unpack (styleProof (T.pack continuation))))
    , testCase "the headline and the conclusion are bold throughout" $ do
        T.unpack (styleProof (T.pack conclusion)) @?= "\ESC[1m" ++ conclusion ++ "\ESC[0m"
        T.unpack (styleProof (T.pack headline')) @?= "\ESC[1m" ++ headline' ++ "\ESC[0m"
    , -- A wrapped conclusion is still one bold line to the eye.
      testCase "a continuation of the conclusion is bold too" $ do
        let out = T.unpack (styleProof (T.pack (conclusion ++ "\n" ++ continuation)))
        assertBool out (("\n\ESC[1m" ++ continuation ++ "\ESC[0m") `isInfixOf` out)
    ]
  where
    headline' = "No solution for foo >=1.0: bar is pinned to 2 (installed)."
    sentence = "And because foo >=1.0 && <2 depends on bar >=1.0, foo >=1.0 && <2 is forbidden"
    continuation = "    bar >=1.0 && <2 which depends on baz"
    conclusion = "So, because foo >=1.0 is requested, version solving failed."
    unlines' = foldr1 (\a b -> a ++ "\n" ++ b)
    stripEscapes = T.replace (T.pack "\ESC[1m") T.empty . T.replace (T.pack "\ESC[2m") T.empty . T.replace (T.pack "\ESC[0m") T.empty

untouched :: [TestTree]
untouched =
    [ -- Two empty ranges do not make a sentence, and there is no dependency to
      -- absorb into.
      testCase "two holes stay a derivation step" $ do
        let step = resolveOn (hole pkgA (range 1 2)) (hole pkgA (range 2 4)) pkgA
        case causeOf (collapseNoInstances step) of
            CauseDerivedFrom _ _ -> pure ()
            c -> assertFailure ("expected the step to survive, got " ++ describe c)
    , -- The dependee's *whole* range being empty makes the union over the pivot ⊤,
      -- so the dependee entry drops out of the step's terms. Rebuilding from those
      -- terms would produce a dependency fact with no dependee range in it, and the
      -- proof would never mention @q@ at all. 'PubGrub.Report.dependsOnNothing'
      -- renders this case as "depends on …, which has no versions", which keeps
      -- the range.
      testCase "a wholly empty dependee range stays a derivation step" $ do
        let dep = dependsOnQ (range 1 2)
            step = resolveOn dep (hole pkgQ (range 1 5)) pkgQ
        Map.size (incompTerms step) @?= 1
        case causeOf (collapseNoInstances step) of
            CauseDerivedFrom _ _ -> pure ()
            c -> assertFailure ("expected the step to survive, got " ++ describe c)
    , -- Only dependency facts are absorbed into. A hole resolved against "cannot be
      -- built from source" would have to widen *that* claim, which would say the
      -- empty range cannot be built from source — a different and false statement.
      testCase "a hole is not absorbed into a boot-package fact" $ do
        let step = resolveOn (onlyInstalled pkgA [v 3] (from 1)) (hole pkgA (range 1 2)) pkgA
        case causeOf (collapseNoInstances step) of
            CauseDerivedFrom _ _ -> pure ()
            c -> assertFailure ("expected the step to survive, got " ++ describe c)
    , -- pubgrub-rs leaves this one too (its @collapse_no_versions@ carries a TODO).
      -- Dropping the hole here would print a conclusion wider than the two causes
      -- named on the line justify, because the widening is what the hole paid for.
      testCase "a hole against a derived sibling stays a derivation step" $ do
        let inner = resolveOn (dependsOnQ (range 1 2)) (dependsOnQ (range 2 3)) pkgQ
            step = resolveOn inner (hole pkgA (range 3 4)) pkgA
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
        let inner = resolveOn (dependsOnQ (range 1 2)) (hole pkgA (range 2 4)) pkgA
            outer = resolveOn inner (hole pkgQ (range 4 5)) pkgQ
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
describe CauseRequest{}       = "CauseRequest"
describe CauseNoInstances{}   = "CauseNoInstances"
describe CauseOnlyInstalled{} = "CauseOnlyInstalled"
describe CauseUnbuildable{}   = "CauseUnbuildable"
describe CauseDependency{}    = "CauseDependency"
describe CauseDeclaresFlag{}  = "CauseDeclaresFlag"
describe CauseDerivedFrom{}   = "CauseDerivedFrom"
