{-# LANGUAGE OverloadedStrings #-}

-- | The cabal domain's proofs: the standard PubGrub sentences in cabal's range
-- syntax, over the walker in "PubGrub.Report".
--
-- 'cabalFormatter' is the domain's half of that contract: the words
-- ("PubGrub.Cabal.Report.Wording"), a pass over the tree before the walk
-- ('collapseNoInstances'), and the rules that say a step in fewer lines than
-- the PubGrub algorithm's cases would. Three of those are this package's rather
-- than the algorithm's — 'samePairRun', 'wideningRun' and 'collapseNoInstances' —
-- and each carries its soundness argument where it is defined. The two clause
-- rules the algorithm names as special cases, 'chainOfTwo' and 'sharedDepender',
-- are here too rather than in the core, because what a dependency is the core
-- does not know.
--
-- The headline above the proof is "PubGrub.Cabal.Report.Headline"'s, and the
-- wrapping and colour the driver puts over both are
-- "PubGrub.Cabal.Report.Layout"'s.
module PubGrub.Cabal.Report
    ( cabalFormatter
    , reportConflict
    , reportHeadline
    , collapseNoInstances
      -- * Re-exported from "PubGrub.Cabal.Report.Layout"
    , wrapProof
    , styleProof
    , rangeToken
    ) where

import           Control.Monad                  (guard)
import qualified Data.Map.Strict                as Map
import           Data.Maybe                     (fromMaybe)
import           Data.Text                      (Text)
import           Distribution.Types.PackageName (PackageName)
import           PubGrub.Cabal                  (Cabal,
                                                 CabalFact (..))
import           PubGrub.Cabal.Report.Headline  (headline)
import           PubGrub.Cabal.Report.Layout    (rangeToken, styleProof,
                                                 wrapProof)
import           PubGrub.Cabal.Report.Rule
import           PubGrub.Cabal.Report.Wording   (bareP, dep, namedP,
                                                 summaryTerms, wording)
import           PubGrub.Incompatibility        (Cause (..),
                                                 Incompatibility (..),
                                                 priorCauseTerms)
import           PubGrub.Cabal.InstanceSet            (InstanceSet)
import           PubGrub.Report                 (Formatter (..), Line (..))
import qualified PubGrub.Report                 as Report
import           PubGrub.SetOps                 (isSubsetOf)
import           PubGrub.Term                   (Term (..))
import           PubGrub.Cabal.Value                  (ValueSet (..))
import           PubGrub.Cabal.Variable               (Var (..))

-- | The cabal domain's words and rules. The two run rules go before the
-- algorithm's every-other-step skip because they collapse what the skip would
-- print two facts at a time.
cabalFormatter :: Formatter Cabal
cabalFormatter =
    wording
        { prepare = collapseNoInstances
        , lineRules = [wideningRun, samePairRun]
        , clauseRules = joins
        }

-- | Render an incompatibility and its derivation as a human-readable proof.
reportConflict :: Incompatibility Cabal -> Text
reportConflict = Report.reportConflict cabalFormatter

-- | One or two lines to put above the proof: see "PubGrub.Cabal.Report.Headline".
reportHeadline :: Incompatibility Cabal -> Text
reportHeadline = headline . collapseNoInstances

-- --------------------------------------------------------------------------
-- The line rules
-- --------------------------------------------------------------------------

-- | __Rule 3, the same-pair run.__ Before the ordinary every-other-step skip,
-- look for a run of steps that all say the same kind of thing: this range of
-- @p@ depends on @q@, and so does the next range, and the next. That is one
-- fact about @p@ as a whole, and printing it a range at a time spends a line on
-- every adjacent pair in the history of @p@'s bound on @q@.
--
-- It is /not/ the PubGrub algorithm's collapsing of adjacent versions, which
-- merges facts with an __identical__ dependee range. Here the dependee ranges
-- differ — that is why the solver had to derive its way along them — and what
-- is printed is their union.
--
-- Stating the union of the facts is sound on its own — each says @p ∈ Sᵢ@
-- requires @q ∈ Rᵢ@, so @p ∈ ⋃S@ requires @q ∈ ⋃R@ — but a line may not claim
-- to justify more of @p@ than the step it is attached to concluded, and the
-- last two guards are what stop it: the conclusion really is \"p requires q\",
-- and the collapsed depender range is one it covers. 'isSubsetOf' is one-sided
-- the safe way: it can only refuse a collapse that would have been fine.
samePairRun :: Rule (Incompatibility Cabal) (Line Cabal)
samePairRun step = do
    (d, e) <- chainStep step
    (p, s, q, r) <- asDependency e
    let (rest, more) = runWhile (dependencyOn p q) d
    guard (not (null more))
    ss <- unions (s : map fst more)
    rs <- unions (r : map snd more)
    sInc <- concludesRequires p q step
    guard (ss `isSubsetOf` sInc)
    pure (Line (dep p ss q rs) (Just rest))
  where
    -- A fact about this @(depender, dependee)@ pair: its two ranges.
    dependencyOn p q e = do
        (p', s, q', r) <- asDependency e
        guard (p' == p && q' == q)
        pure (s, r)

-- | Is this step's conclusion of the shape \"p requires q\"? If so, the range of
-- @p@ it speaks for. Anything else and a collapsed sentence would be attached
-- to a claim it does not support.
concludesRequires :: PackageName -> PackageName -> Rule (Incompatibility Cabal) InstanceSet
concludesRequires p q step = case Map.toList (incompTerms step) of
    [(a, Positive s), (b, Negative _)] | (a, b) == (PackageVar p, PackageVar q) -> Just (vsInstances s)
    [(b, Negative _), (a, Positive s)] | (a, b) == (PackageVar p, PackageVar q) -> Just (vsInstances s)
    _ -> Nothing

-- | __Rule 4, the widening run.__ Rule 3 needs every fact in the run to name
-- the same dependee, and needs the step's conclusion to be the two-term \"p
-- requires q\". Neither holds on a problem with an /unconstrained/ target:
-- refuting one takes a walk along the target's whole version history, and
-- consecutive releases rarely fail over the same dependee. Such a walk folds in
-- one dependency of the target per line — on @base@, then @deepseq@, then
-- @template-haskell@ — while every other term stands still; another kind strikes
-- a dependee's slots off one at a time.
--
-- So collect the run by __depender alone__ and state it once. Each fact says
-- @p ∈ Sᵢ@ requires @qᵢ ∈ Rᵢ@, so their union says @p ∈ ⋃S@ requires
-- @q₁ ∈ ⋃R₁@ or … or @qₙ ∈ ⋃Rₙ@: if @p@ is in the union it is in some @Sᵢ@, and
-- that fact's own dependee is one of the disjuncts. Nothing else about @p@ is
-- claimed, which is why 'mergeFacts' refuses a run where some package is a
-- depender in one fact and a dependee in another — the argument is about one
-- depender and holds for nothing else.
--
-- Three facts at least. Two of them fit one line as they are, where the
-- ordinary skip already puts them, and naming both says strictly more than
-- naming their union — so the union has to buy a line to be worth taking. Rule
-- 3 still has the two-fact case where the dependee agrees.
--
-- __The guard is the operation, not a description of it.__ A line that stands
-- for a run has to arrive where the run arrived, and the only way to know that
-- is to go there: 'PubGrub.Incompatibility.priorCauseTerms' — the term algebra
-- 'PubGrub.Incompatibility.priorCause' itself runs, pivoting on the depender —
-- is applied once to the merged fact, and the collapse is taken only if the
-- result is term for term the conclusion this line is attached to. So the rule
-- needs no subset side-condition of its own, and it needs no case analysis over
-- what the run did: whether the depender __accumulated__ (@aeson@ climbing from
-- @\<0.8.0.1@ to @\<2.2.5.0@) or was __eliminated__ (@directory@ losing one slot
-- per fact until nothing was left), one step over the union lands where @n@
-- steps over the members landed, or the collapse does not happen.
wideningRun :: Rule (Incompatibility Cabal) (Line Cabal)
wideningRun step = do
    (d, e) <- chainStep step
    (p, _, _, _) <- asDependency e
    let (rest, more) = runWhile (dependencyOf p) d
    guard (length more >= 2)
    merged <- mergeFacts (e : more)
    guard (sameTerms (priorCauseTerms (PackageVar p) (incompTerms rest) merged) (incompTerms step))
    pure (Line (runFact p merged) (Just rest))
  where
    -- A fact with this depender, whatever it depends on.
    dependencyOf p e = do
        (p', _, _, _) <- asDependency e
        guard (p' == p)
        pure e

    -- The merged fact, as its sentence. With one dependee it is the shape rule
    -- 3 already prints, word for word, so a run that both rules could take
    -- reads the same either way; with several it is a requirement with
    -- alternatives, and \"requires\" rather than \"depends on\" because a union
    -- of declared dependencies is something the solver worked out, not
    -- something an author wrote (references/pubgrub.md:1005).
    runFact p terms = case Map.toList (Map.delete (PackageVar p) terms) of
        [(PackageVar q, Negative r)]
            | Just (Positive sp) <- Map.lookup (PackageVar p) terms -> dep p (vsInstances sp) q (vsInstances r)
        _ -> summaryTerms terms

-- --------------------------------------------------------------------------
-- The clause rules: two external facts as one premise
-- --------------------------------------------------------------------------

-- | Two external facts as one premise. Each fusion is guarded so that it cannot
-- say more than the facts do.
joins :: [Rule (Incompatibility Cabal, Incompatibility Cabal) Text]
joins =
    [ twoRequests
    , symmetric dependsOnNothing
    , symmetric requestsNothing
    , symmetric chainOfTwo
    , sharedDepender
    ]

-- | Two seeds close a proof together: \"baz >=1 && <2 and foo >=1 && <2 are
-- requested\", the standard \"depends on both\" sentence without a depender in
-- front of it.
twoRequests :: Rule (Incompatibility Cabal, Incompatibility Cabal) Text
twoRequests (c1, c2) = do
    (p1, r1) <- asRequest c1
    (p2, r2) <- asRequest c2
    pure (bareP p1 r1 <> " and " <> bareP p2 r2 <> " are requested")

-- | A dependency whose dependee range is one the solver has already found
-- empty. Naming both facts prints that range /twice/ in one sentence, and on a
-- real proof it is not short: haddock 2.29.1's base bound is seven windows, and
-- it would appear in full at both ends of the same line.
--
-- Saying it once is sound only when the dependency's whole range is inside the
-- empty one, which is what the 'isSubsetOf' checks. Where it is only partly
-- inside, the two facts stay separate — absorbing that case means widening the
-- term rather than dropping a clause, which is 'collapseNoInstances' proper and
-- not a rendering change.
dependsOnNothing :: Rule (Incompatibility Cabal, Incompatibility Cabal) Text
dependsOnNothing (fact, hole) = do
    (q', empty) <- asHole hole
    (p, s, q, r) <- asDependency fact
    guard (q == q' && r `isSubsetOf` empty)
    pure (dep p s q r <> ", which has no versions")

-- | A request whose whole range is empty reads the same way.
requestsNothing :: Rule (Incompatibility Cabal, Incompatibility Cabal) Text
requestsNothing (fact, hole) = do
    (p', empty) <- asHole hole
    (p, r) <- asRequest fact
    guard (p == p' && r `isSubsetOf` empty)
    pure (bareP p r <> " is requested, which has no versions")

-- | A __chain__ — the first fact's dependee is the second's depender — reads
-- \"a depends on b which depends on c\". That is only true if every instance the
-- first fact leaves open for the middle package is one the second fact speaks
-- about, hence the 'isSubsetOf'.
chainOfTwo :: Rule (Incompatibility Cabal, Incompatibility Cabal) Text
chainOfTwo (c1, c2) = do
    (p1, s1, q1, r1) <- asDependency c1
    (p2, s2, q2, r2) <- asDependency c2
    guard (q1 == p2 && r1 `isSubsetOf` s2)
    pure (dep p1 s1 q1 r1 <> " which depends on " <> bareP q2 r2)

-- | __One depender, two dependees__ reads \"a depends on both b and c\", for
-- which the two facts must be about the same instances of @a@.
sharedDepender :: Rule (Incompatibility Cabal, Incompatibility Cabal) Text
sharedDepender (c1, c2) = do
    (p1, s1, q1, r1) <- asDependency c1
    (p2, s2, q2, r2) <- asDependency c2
    guard (p1 == p2 && s1 == s2)
    pure (namedP p1 s1 <> " depends on both " <> bareP q1 r1 <> " and " <> bareP q2 r2)

-- --------------------------------------------------------------------------
-- Rule 5: the pre-pass
-- --------------------------------------------------------------------------

-- | Absorb \"no version for @p@ in @r@\" facts into the sibling they were resolved
-- against, and drop the step.
--
-- Intensional ranges are why these exist at all: a dependency's declared range is
-- put into a term verbatim, so the solver has to /separately/ learn that the range's
-- holes hold no releases, and each such discovery is a leaf of the derivation. They
-- are honest facts and they are noise.
--
-- __Why this is sound, and why it is not even a weakening.__ Resolving a unit clause
-- @{p ∈ r}@ against a dependency fact on the pivot @p@ unions the two terms about
-- @p@ and keeps the other side unchanged, so the step's own conclusion /already is/
-- that dependency with @p@'s term adjusted. The pass therefore does not recompute
-- anything: it keeps the derived node's terms exactly and re-labels them as the leaf
-- they are equivalent to. Nothing in the proof gets wider or narrower; a step that
-- said nothing new stops being a step. The argument is the PubGrub algorithm's
-- own — a fact about a version that does not exist constrains nothing.
--
-- Two cases are deliberately left alone:
--
--  * __both causes are holes.__ There is no dependency to absorb into, and two empty
--    ranges do not make a sentence.
--  * __the dependee's whole range is empty.__ Then the union over the pivot is ⊤, the
--    dependee entry drops out of the resolvent, and rebuilding would produce a
--    dependency fact whose dependee range is /gone/ — the proof would say \"haddock
--    >=2.29.1 is forbidden\" and never mention @base@. 'dependsOnNothing' renders
--    that case as \"depends on … , which has no versions\", which keeps the range,
--    so the guard here is that the node must still carry a term for both packages.
collapseNoInstances :: Incompatibility Cabal -> Incompatibility Cabal
collapseNoInstances inc = case incompCause inc of
    Derived c1 c2 ->
        let c1' = collapseNoInstances c1
            c2' = collapseNoInstances c2
            node = Incompatibility (incompTerms inc) (Derived c1' c2')
         in fromMaybe node (symmetric (absorb node) (c1', c2'))
    _ -> inc
  where
    -- @hole@ is a range known empty, @other@ the dependency fact it was resolved
    -- against. Answers with the node re-labelled as that dependency, over the
    -- node's own terms.
    absorb node (hole, other) = do
        (p, _) <- asHole hole
        (p1, q) <- dependencyPackages other
        guard (p == p1 || p == q)
        guard (Map.size (incompTerms node) == 2)
        s1 <- vsInstances <$> (positive =<< Map.lookup (PackageVar p1) (incompTerms node))
        r2 <- vsInstances <$> (negative =<< Map.lookup (PackageVar q) (incompTerms node))
        pure (Incompatibility (incompTerms node) (Fact (CauseDependency p1 s1 Map.empty (q, r2))))

    dependencyPackages c = case incompCause c of
        Fact (CauseDependency p1 _ g (q, _)) | p1 /= q, Map.null g -> Just (p1, q)
        _ -> Nothing
