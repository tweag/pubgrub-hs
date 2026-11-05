{-# LANGUAGE OverloadedStrings #-}

-- | The lines above the proof: what was asked for, the facts about this
-- machine the proof rests on, and the package the search gave up on.
--
-- The proof is read bottom-up — its first line is the deepest fact and the
-- request appears only on the last — so a reader of the matterhorn proof meets
-- @hashable@ before learning that @base@ is the wall. The headline says both
-- first, in the proof's own words: the request is the seeds the proof rests on
-- ('CauseRequest'), and the walls are its world-fact leaves
-- ('CauseOnlyInstalled', 'CauseUnbuildable'), verbatim. It claims nothing the
-- proof does not: every named fact is a premise of the derivation below it.
--
--  > No solution for matterhorn ==90000.1.1: base is pinned to 4.21.0.0 (installed).
--
-- It is not a proof sentence and opens with no connective, so a count of a
-- proof's sentences by connective leaves it out — the same footing as cabal's own
-- \"Could not resolve dependencies:\" line above its own message.
--
-- == The second line
--
-- A second sentence names the package the search gave up on: \"lsp-types
-- >=2.0.0.0 needs regex, and no version of regex is compatible with ghcide
-- >=2.15.0.0, lsp-types >=2.0.0.0 and regex-tdfa >=1.3.1.0 together.\" It is a
-- derived step read out, not a summary written over the proof, and two rules
-- produce it, tried in turn. A guard that does not hold means no line, never a
-- wrong one.
module PubGrub.Cabal.Report.Headline
    ( headline
    ) where

import           Control.Monad                  (guard)
import           Data.List                      (nub)
import qualified Data.Map.Strict                as Map
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Distribution.Types.PackageName (PackageName)
import           PubGrub.Cabal                  (CabalFact (..), Var (..))
import           PubGrub.Cabal.InstanceSet      (InstanceSet)
import           PubGrub.Cabal.Report.Rule
import           PubGrub.Cabal.Report.Wording   (bare, bareP, leaf, listing,
                                                 namedP)
import           PubGrub.Cabal.Value            (ValueSet (..))
import           PubGrub.Cabal.Version          (Version)
import           PubGrub.Incompatibility        (Cause (..),
                                                 Incompatibility (..))
import           PubGrub.Pretty                 (Pretty (..))
import           PubGrub.SetOps                 (SetOps (intersect, union),
                                                 isSubsetOf)
import           PubGrub.Term                   (Term (..), unionTerm)

-- | The headline of a proof whose holes have been absorbed
-- ('PubGrub.Cabal.Report.collapseNoInstances').
headline :: Incompatibility Var -> Text
headline root = T.concat ["No solution", forWhat, walls, ".", culprit]
  where
    forWhat = case requests of
        [] -> ""
        rs -> " for " <> T.intercalate " and " rs
    walls = case nub [leaf c | c <- externals root, isWorld c] of
        [] -> ""
        ws -> ": " <> T.intercalate "; " ws
    -- What was asked for, as the proof itself names it. A seed the proof
    -- never reaches is not the one that failed.
    requests = nub [bareP p r | (p, r) <- seedRanges root]
    isWorld c = case incompCause c of
        Fact CauseOnlyInstalled{} -> True
        Fact CauseUnbuildable{}   -> True
        _                         -> False
    culprit = case firstOf [wallStory, pivotStory] root of
        Nothing -> ""
        Just s  -> "\n" <> s <> "."

-- --------------------------------------------------------------------------
-- What the proof rests on
-- --------------------------------------------------------------------------

-- | The seeds the proof rests on, with their ranges, in proof order.
seedRanges :: Incompatibility Var -> [(PackageName, InstanceSet)]
seedRanges root = [(p, r) | c <- externals root, Just (p, r) <- [asRequest c]]

seeds :: Incompatibility Var -> [PackageName]
seeds = nub . map fst . seedRanges

-- | The pinned packages the proof rests on, with their installed versions.
pinnedWalls :: Incompatibility Var -> [(PackageName, [Version])]
pinnedWalls root = nub [(p, vs) | c <- externals root, Fact (CauseOnlyInstalled p vs@(_ : _)) <- [incompCause c]]

-- | A pinned package as \"base 4.21.0.0 (installed)\": the installed version is
-- what a reader can act on, and a step's own term for the wall may be its
-- whole source side, which would print as the bare name.
wallText :: Incompatibility Var -> PackageName -> Text
wallText root p = case lookup p (pinnedWalls root) of
    Just vs -> pretty p <> " " <> T.intercalate " or " (map pretty vs) <> " (installed)"
    Nothing -> pretty p

-- | The packages the headline already names as walls, pinned or unbuildable.
walled :: Incompatibility Var -> [PackageName]
walled root = nub (concat [wallPackage c | c <- externals root])
  where
    wallPackage c = case incompCause c of
        Fact (CauseOnlyInstalled p _)   -> [p]
        Fact (CauseUnbuildable p _ _ _) -> [p]
        _                               -> []

-- --------------------------------------------------------------------------
-- The wall story
-- --------------------------------------------------------------------------

-- | Where the proof rests on a pinned package, the reader wants three things
-- joined: who wants @x@, the window their bounds leave for it, and that nothing
-- in that window builds against the installed version. The proof has each,
-- apart: the window is spread over the dependency leaves, and the refutation is
-- a derived step of the shape \"x in W is incompatible with base 4.21.0.0
-- (installed)\" — one positive term on @x@ and the rest positive terms on wall
-- packages — or \"x in W is forbidden\" with the wall among its premises. That
-- step is the wall doing its work ('wallStep'), and it is chosen nearest the
-- root.
--
-- The window is what the seeds force ('inPlay'): @x@ must sit in the
-- intersection of the in-play leaves' ranges for it. The line is only printed
-- when that window lies inside the union of the ranges the wall steps refute,
-- so \"no x there builds\" is exactly what those steps say.
wallStory :: Rule (Incompatibility Var) Text
wallStory root = do
    let steps = everywhere (wallStep root) root
    (x, wallTexts) <- nearestRoot [(depth, (x, ws)) | (depth, (x, _, ws)) <- steps]
    refuted <- unions [w | (_, (x', w, _)) <- steps, x' == x]
    let wanting = Map.toList (Map.fromListWith meet [(d, (s, r)) | (d, s, q, r) <- inPlay root, q == x])
        meet (s1, r1) (s2, r2) = (s1 `union` s2, r1 `intersect` r2)
    window <- case [r | (_, (_, r)) <- wanting] of
        []       -> Nothing
        (r : rs) -> Just (foldr intersect r rs)
    guard (window `isSubsetOf` refuted)
    let who = listing [namedP d s | (d, (s, _)) <- wanting]
        leaves = case wanting of
            [_] -> " needs "
            _   -> " leave only "
    pure (who <> leaves <> bareP x window <> ", and no " <> pretty x <> " there builds on " <> listing wallTexts)

-- | A derived step of the wall shape: the package refuted, the range refuted,
-- and the walls it was refuted against, as text. A seed is never the package:
-- the headline has said it already, and the proof's last line says it again.
wallStep :: Incompatibility Var -> Rule (Incompatibility Var) (PackageName, InstanceSet, [Text])
wallStep root n = do
    guard (isDerived n)
    let ps = [(p, s) | (PackageVar p, Positive (ValueSet s _)) <- Map.toList (incompTerms n)]
    guard (length ps == Map.size (incompTerms n))
    (x, w) <- case [(p, s) | (p, s) <- ps, p `notElem` pinnedPackages] of
        [one] -> Just one
        _     -> Nothing
    guard (x `notElem` seeds root)
    let against = [wallText root p | (p, _) <- ps, p `elem` pinnedPackages]
        pinned = nub [wallText root p | c <- externals n, Fact (CauseOnlyInstalled p (_ : _)) <- [incompCause c]]
    guard (not (null against) || not (null pinned))
    pure (x, w, if null against then pinned else against)
  where
    pinnedPackages = map fst (pinnedWalls root)

-- | The dependency leaves the seeds force, as (depender, its range, dependee,
-- its range). A leaf is in play when its depender's range covers a seed's, or
-- covers the dependee range of a leaf already in play; the chain from the
-- request is then forced. A fixed point.
inPlay :: Incompatibility Var -> [(PackageName, InstanceSet, PackageName, InstanceSet)]
inPlay root = grow [l | l@(d, s, _, _) <- allDeps, or [r `isSubsetOf` s | (p, r) <- seedRanges root, p == d]]
  where
    allDeps = [l | c <- externals root, Just l <- [asDependency c]]
    grow have =
        let more = [l | l@(d, s, _, _) <- allDeps, not (l `elemBy` have), or [r `isSubsetOf` s | (_, _, q, r) <- have, q == d]]
         in if null more then have else grow (have ++ more)
    elemBy l have = l `elem` have

-- --------------------------------------------------------------------------
-- The pivot story
-- --------------------------------------------------------------------------

-- | For a proof with no wall to name: the package the search gave up on, read
-- off the step that dropped it.
--
-- A step resolves on one package, the pivot, and either keeps a narrowed term
-- for it or drops it when its two terms union to ⊤. The step that drops @p@ is
-- the proof's own statement that, with the step's remaining terms all in force,
-- no version of @p@ is left — so the terms are named, and the \"together\" is the
-- conjunction the incompatibility is.
--
-- Which package. Every pivot is dropped somewhere, and most of them are dropped
-- at the one step that refutes their whole range in one go. The one worth a
-- sentence is the package whose range had to be cut in pieces and refuted a
-- piece at a time: a step below narrowed its term before a step above dropped
-- it ('droppedStep'). Of those, the one dropped nearest the root is the last
-- thing the solver had to give up on.
pivotStory :: Rule (Incompatibility Var) Text
pivotStory root = do
    (p, node) <- nearestRoot (everywhere (droppedStep root) root)
    pure (gaveUpOn p node)

-- | A step that dropped a package a step below had narrowed. A seed is never
-- the package, nor is one the headline already names as a wall: it is pinned
-- or unbuildable, and the wall says so in fewer words.
droppedStep :: Incompatibility Var -> Rule (Incompatibility Var) (PackageName, Incompatibility Var)
droppedStep root n = do
    (a, b) <- derivedFrom n
    v <- dropped n a b
    p <- case v of
        PackageVar p -> Just p
        FlagVar{}    -> Nothing
    guard (p `notElem` seeds root)
    guard (p `notElem` walled root)
    guard (narrowedBelow v a || narrowedBelow v b)
    pure (p, n)

-- | The pivot of a step that dropped it: the one package both causes name and
-- the step does not. Every other package the causes share survives the step,
-- intersected, so at most one is missing.
dropped :: Incompatibility Var -> Incompatibility Var -> Incompatibility Var -> Maybe Var
dropped n a b =
    case [p | p <- Map.keys (Map.intersectionWith const (incompTerms a) (incompTerms b)), Map.notMember p (incompTerms n)] of
        [p] -> Just p
        _   -> Nothing

-- | Does some step in this subtree narrow @p@: resolve on it and keep it? The
-- step's term for @p@ is then the union of its causes' two terms and differs
-- from both; a package the causes merely share is intersected instead, and a
-- pivot whose union equals one side learnt nothing.
narrowedBelow :: Var -> Incompatibility Var -> Bool
narrowedBelow p n = case derivedFrom n of
    Just (a, b) -> narrowedAt p n a b || narrowedBelow p a || narrowedBelow p b
    Nothing     -> False

narrowedAt :: Var -> Incompatibility Var -> Incompatibility Var -> Incompatibility Var -> Bool
narrowedAt p n a b
    | Just ta <- Map.lookup p (incompTerms a)
    , Just tb <- Map.lookup p (incompTerms b)
    , Just t <- Map.lookup p (incompTerms n) =
        sameTerm t (unionTerm ta tb) && not (sameTerm t ta) && not (sameTerm t tb)
    | otherwise = False

-- | The sentence. The step's positive terms are what has to be present
-- together; a negative term is a way out — \"unless q <2\" — since
-- ¬(A ∧ B ∧ q ∉ R) is A ∧ B → q ∈ R. The dependers come first, as \"lsp-types
-- >=2.0.0.0 needs regex\", so no pronoun has to reach back for @p@. When the
-- only things present are the dependers themselves, \"needs regex, and …
-- compatible with lsp-types\" would say the same thing twice, and the shape is
-- \"no version of p suits d\", where \"suits\" carries the dependency.
gaveUpOn :: PackageName -> Incompatibility Var -> Text
gaveUpOn p node
    | not (null positives)
    , all ((`elem` dependers) . fst) positives =
        "No version of " <> pretty p <> " suits " <> listing (map (uncurry bare) positives) <> escape
    | null leaves =
        "No version of " <> pretty p <> " is compatible with " <> present <> escape
    | otherwise =
        needs <> ", and no version of " <> pretty p <> " is compatible with " <> present <> escape
  where
    positives = [(q, r) | (q, Positive r) <- Map.toList (incompTerms node)]
    negatives = [bare q r | (q, Negative r) <- Map.toList (incompTerms node)]
    present = case positives of
        []  -> "anything"
        [x] -> uncurry bare x
        xs  -> listing (map (uncurry bare) xs) <> " together"
    escape = case negatives of
        [] -> ""
        ns -> " unless " <> T.intercalate " or " ns
    -- The dependency leaves under the step whose dependee is @p@, one entry per
    -- depender with its ranges unioned: each leaf says @d ∈ Sᵢ@ depends on @p@,
    -- so @d ∈ ⋃S@ does.
    leaves =
        Map.toList
            (Map.fromListWith union [(d, s) | c <- externals node, Fact (CauseDependency d s g (q, _)) <- [incompCause c], Map.null g, q == p, d /= p])
    dependers = map (PackageVar . fst) leaves
    needs = case leaves of
        [(d, s)] -> namedP d s <> " needs " <> pretty p
        ds       -> listing [namedP d s | (d, s) <- ds] <> (if length ds == 2 then " both need " else " all need ") <> pretty p
