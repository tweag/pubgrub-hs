{-# LANGUAGE OverloadedStrings #-}

-- | Rendering a failed resolution as a human-readable proof.
--
-- A terminal 'Incompatibility' carries the 'IncompatCause' tree that produced
-- it, which is all this module needs: 'reportConflict' replays that tree as a
-- written argument.
--
-- == How the proof is made
--
-- The walker, @derived@, visits a derived step and emits one line for it: a
-- connective, a __premise__, and what the step concludes. The premise is what
-- varies, and it is chosen by a __rule__ — the first of @lineRules@ to fire.
-- A rule is a @do@ block in 'Maybe', written in the vocabulary of
-- "PubGrub.Report.Rule": each line reads a view of the tree or states a guard,
-- and the last says the premise and names the sub-derivation, if any, the line
-- continues (@Line@). Two facts named together in one premise are joined by a
-- second table, @clauseRules@, in the same language. The sentences themselves
-- are "PubGrub.Report.Wording"'s, and the headline above the proof is
-- "PubGrub.Report.Headline"'s.
--
-- Two rules keep the proof short. Replayed naively, one line per derived
-- incompatibility and each naming one external fact, a proof is too long to
-- read to the end.
--
--  * __A chain of two external facts is one sentence__ (@chainOfTwo@,
--    @sharedDepender@). Where a dependency's dependee is the depender of the
--    next, the proof says \"@foo@ depends on @bar@ /which depends on/ @baz@\"
--    rather than naming @bar@ twice, and where two facts share a depender it
--    says \"depends on /both/ X and Y\".
--
--  * __Every other derived step is skipped__ (@everyOtherStep@). Where a step's
--    derived cause has a single derived cause of its own, that intermediate
--    /conclusion/ is left out and both external facts are named in one line.
--    Since most derivation graphs are linear chains, this halves them.
--
-- Three more rules shorten it further — @samePairRun@, @wideningRun@ and
-- 'collapseNoInstances' — and each carries its soundness argument where it is
-- defined.
--
-- == Line numbers are for joins only
--
-- Only an incompatibility that a later line refers back to is numbered, and in
-- a linear chain that is none of them. A number is minted in exactly one place
-- — @numberLast@, at a step with two derived causes — so a proof that never
-- branches carries no numbers at all.
--
-- A sub-derivation shared by two steps is not detected: 'Incompatibility' has no
-- identity to detect it with, so a shared node is explained twice instead of
-- being referred to.
module PubGrub.Report
    ( reportConflict
    , reportHeadline
    , collapseNoInstances
      -- * Re-exported from "PubGrub.Report.Layout"
    , wrapProof
    , styleProof
    , rangeToken
    ) where

import           Control.Monad                  (guard)
import qualified Data.Map.Strict                as Map
import           Data.Maybe                     (fromMaybe)
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Distribution.Types.PackageName (PackageName)
import           PubGrub.Incompatibility        (IncompatCause (..),
                                                 Incompatibility (..),
                                                 priorCauseTerms)
import           PubGrub.InstanceSet            (InstanceSet)
import           PubGrub.Report.Headline        (headline)
import           PubGrub.Value                  (ValueSet (..), packageSet)
import           PubGrub.Variable               (Var (..))
import           PubGrub.Report.Layout          (rangeToken, styleProof,
                                                 wrapProof)
import           PubGrub.Report.Rule
import           PubGrub.Report.Wording         (bareP, dep, leaf, namedP,
                                                 summary, summaryTerms)
import           PubGrub.SetOps                 (isSubsetOf)
import           PubGrub.Term                   (Term (..))

-- | Render an incompatibility and its derivation as a human-readable proof.
reportConflict :: Incompatibility -> Text
reportConflict root0
    | isDerived root = render (reverse (outLines (derived True root (Out [] 1))))
    -- The terminal incompatibility is itself an external fact: nothing was
    -- derived, so the fact is the whole explanation.
    | otherwise = leaf root
  where
    -- The holes go first: a derivation step that only established that a range
    -- is empty is not a step worth a line, and leaving them in is what stops
    -- the chain fusion from ever firing on a real problem.
    root = collapseNoInstances root0

    -- Every line is a sentence and ends as one. A blank line between two
    -- branches of a derivation (references/pubgrub.md:632) stays blank.
    render ls = T.intercalate "\n" [line n t | (n, t) <- ls]
    line _ "" = ""
    line n t  = prefix n <> t <> "."
    prefix Nothing  = ""
    prefix (Just n) = T.pack (show n) <> ". "

-- | One or two lines to put above the proof: see "PubGrub.Report.Headline".
reportHeadline :: Incompatibility -> Text
reportHeadline = headline . collapseNoInstances

-- --------------------------------------------------------------------------
-- The walker
-- --------------------------------------------------------------------------

-- | The proof under construction: its lines __newest first__, and the next free
-- line number.
data Out = Out
    { outLines :: [(Maybe Int, Text)]
    , outNext  :: !Int
    }

emit :: Text -> Out -> Out
emit t out = out{outLines = (Nothing, t) : outLines out}

-- | Give the line just emitted a number, so a later line can cite it. Numbers
-- are minted here and nowhere else.
numberLast :: Out -> (Int, Out)
numberLast out = case outLines out of
    ((Just n, t) : rest) -> (n, out{outLines = (Just n, t) : rest})
    ((Nothing, t) : rest) ->
        ( outNext out
        , out{outLines = (Just (outNext out), t) : rest, outNext = outNext out + 1}
        )
    -- Unreachable: every branch emits at least one line before this is called.
    -- Answering with the unused number keeps the proof well-formed if it ever is.
    [] -> (outNext out, out)

-- | Explain one derived incompatibility, ending with the line that concludes it.
-- @final@ marks the last line of the whole proof, which reads \"So, …\" and
-- concludes failure by name.
derived :: Bool -> Incompatibility -> Out -> Out
derived final inc out = case bothDerived inc of
    -- Case 1 (references/pubgrub.md:595): both causes derived — the derivation
    -- branches, and this is the only place a line number is wanted. Explain the
    -- first branch, number the line it ends on, then explain the second and close
    -- by referring back. The blank line between the two branches is the spec's
    -- (:632): it marks that a new line of derivation starts. No rule chooses
    -- this: it is the structure of the proof, not a way of saying a step.
    Just (c1, c2) ->
        let (n, out') = numberLast (derived False c1 out)
         in emit
                (opening (Just c2) <> summary c1 <> " (" <> T.pack (show n) <> "), " <> says inc)
                (derived False c2 (emit "" out'))
    Nothing -> case firstOf lineRules inc of
        Just (Line premise below) ->
            emit
                (opening below <> premise <> ", " <> says inc)
                (maybe out (\d -> derived False d out) below)
        -- Not reached: a derived step either branches, chains or joins two
        -- facts, and the last two rules of the table fire on any such step.
        Nothing -> emit (leaf inc) out
  where
    -- "So," marks the conclusion (references/pubgrub.md:1027); "Because" opens a
    -- line of derivation, which only a step with nothing below it does; "And
    -- because" continues one.
    opening below
        | final = "So, because "
        | Just _ <- below = "And because "
        | otherwise = "Because "
    says c
        | final = "version solving failed"
        | otherwise = summary c

-- --------------------------------------------------------------------------
-- The line rules
-- --------------------------------------------------------------------------

-- | What a rule proposes for one line of the proof.
data Line
    = Line
        Text
        -- ^ the premise, which goes after the connective
        (Maybe Incompatibility)
        -- ^ the sub-derivation the line continues, explained before it; a line
        -- that continues nothing opens a line of derivation

-- | The rules for a step that is not a branch, tried in this order. The two
-- run rules go before the ordinary skip because they collapse what the skip
-- would print two facts at a time; 'oneFact' is the spec's case 2.iii and
-- fires on any chain step, so the table is total over chain steps.
lineRules :: [Rule Incompatibility Line]
lineRules =
    [ twoFacts
    , wideningRun
    , samePairRun
    , everyOtherStep
    , oneFact
    ]

-- | Case 3: both causes are external. One line, and the only case that opens a
-- line of derivation rather than continuing one.
twoFacts :: Rule Incompatibility Line
twoFacts step = do
    (c1, c2) <- bothExternal step
    pure (Line (clause c1 c2) Nothing)

-- | Case 2.ii — the every-other-step skip. The derived cause's own conclusion
-- is left unsaid and the two external facts are named together here, which is
-- where a long linear chain loses half its lines.
everyOtherStep :: Rule Incompatibility Line
everyOtherStep step = do
    (d, e) <- chainStep step
    (dd, de) <- chainStep d
    pure (Line (clause de e) (Just dd))

-- | Case 2.iii: the derived cause branches or bottoms out, so it gets its own
-- lines and this one closes with the external fact alone.
oneFact :: Rule Incompatibility Line
oneFact step = do
    (d, e) <- chainStep step
    pure (Line (leaf e) (Just d))

-- | __The same-pair run.__ Before the ordinary every-other-step skip, look for a
-- run of steps that all say the same kind of thing: this range of @p@ depends on
-- @q@, and so does the next range, and the next. That is one fact about @p@ as a
-- whole, and printed a range at a time it walks one bound's history an adjacent
-- pair of releases at a time (four of @matterhorn@'s ten lines did this to
-- @hashable@).
--
-- It is /not/ the collapsing of adjacent versions' identical dependencies,
-- which merges facts with an __identical__ dependee range. Here the dependee
-- ranges differ — that is why the solver had to derive its way along them — and
-- what is printed is their union.
--
-- Stating the union of the facts is sound on its own — each says @p ∈ Sᵢ@
-- requires @q ∈ Rᵢ@, so @p ∈ ⋃S@ requires @q ∈ ⋃R@ — but a line may not claim
-- to justify more of @p@ than the step it is attached to concluded, and the
-- last two guards are what stop it: the conclusion really is \"p requires q\",
-- and the collapsed depender range is one it covers. 'isSubsetOf' is one-sided
-- the safe way: it can only refuse a collapse that would have been fine.
samePairRun :: Rule Incompatibility Line
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
concludesRequires :: PackageName -> PackageName -> Rule Incompatibility InstanceSet
concludesRequires p q step = case Map.toList (incompTerms step) of
    [(a, Positive (PackageSet s)), (b, Negative _)] | (a, b) == (PackageVar p, PackageVar q) -> Just s
    [(b, Negative _), (a, Positive (PackageSet s))] | (a, b) == (PackageVar p, PackageVar q) -> Just s
    _ -> Nothing

-- | __The widening run.__ The same-pair run needs every fact in the run to name
-- the same dependee, and needs the step's conclusion to be the two-term \"p
-- requires q\". Neither holds on a problem with an /unconstrained/ target:
-- refuting one takes a walk along the target's whole version history, and
-- consecutive releases rarely fail over the same dependee. @aeson@ against
-- @optparse-applicative ==0.15.1.0@ spent thirteen lines on that walk, folding
-- in one @aeson@ dependency each time while every other term stood still.
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
-- naming their union — so the union has to buy a line to be worth taking. The
-- same-pair run still takes two facts whose dependee agrees.
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
wideningRun :: Rule Incompatibility Line
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

    -- The merged fact, as its sentence. With one dependee it is the shape the
    -- same-pair run prints, word for word, so a run that both could take reads
    -- the same either way; with several it is a requirement with alternatives,
    -- and "requires" rather than "depends on" because a union of declared
    -- dependencies is something the solver worked out, not something an author
    -- wrote (references/pubgrub.md:1005).
    runFact p terms = case Map.toList (Map.delete (PackageVar p) terms) of
        [(PackageVar q, Negative (PackageSet r))]
            | Just (Positive (PackageSet sp)) <- Map.lookup (PackageVar p) terms -> dep p sp q r
        _ -> summaryTerms terms

-- --------------------------------------------------------------------------
-- The clause rules: two external facts as one premise
-- --------------------------------------------------------------------------

-- | Two external facts, as one clause: the first of 'clauseRules' to fire, or
-- the two facts side by side.
clause :: Incompatibility -> Incompatibility -> Text
clause c1 c2 = fromMaybe (leaf c1 <> " and " <> leaf c2) (firstOf clauseRules (c1, c2))

-- | Each fusion is guarded so that it cannot say more than the facts do.
clauseRules :: [Rule (Incompatibility, Incompatibility) Text]
clauseRules =
    [ twoRequests
    , symmetric dependsOnNothing
    , symmetric requestsNothing
    , symmetric chainOfTwo
    , sharedDepender
    ]

-- | Two seeds close a proof together: \"baz >=1 && <2 and foo >=1 && <2 are
-- requested\", the spec's \"depends on both\" sentence without a depender in
-- front of it.
twoRequests :: Rule (Incompatibility, Incompatibility) Text
twoRequests (c1, c2) = do
    (p1, r1) <- asRequest c1
    (p2, r2) <- asRequest c2
    pure (bareP p1 r1 <> " and " <> bareP p2 r2 <> " are requested")

-- | A dependency whose dependee range the solver has already found empty.
-- Naming both facts would print that range /twice/ in one sentence, and on a
-- real proof it is not short: haddock 2.29.1's bound on base is seven windows.
--
-- Saying it once is sound only when the dependency's whole range is inside the
-- empty one, which is what the 'isSubsetOf' checks. Where it is only partly
-- inside, the two facts stay separate — absorbing that case means widening the
-- term rather than dropping a clause, so it is not a rendering change.
dependsOnNothing :: Rule (Incompatibility, Incompatibility) Text
dependsOnNothing (fact, hole) = do
    (q', empty) <- asHole hole
    (p, s, q, r) <- asDependency fact
    guard (q == q' && r `isSubsetOf` empty)
    pure (dep p s q r <> ", which has no versions")

-- | A request whose whole range is empty reads the same way.
requestsNothing :: Rule (Incompatibility, Incompatibility) Text
requestsNothing (fact, hole) = do
    (p', empty) <- asHole hole
    (p, r) <- asRequest fact
    guard (p == p' && r `isSubsetOf` empty)
    pure (bareP p r <> " is requested, which has no versions")

-- | A __chain__ — the first fact's dependee is the second's depender — reads
-- \"a depends on b which depends on c\". That is only true if every instance the
-- first fact leaves open for the middle package is one the second fact speaks
-- about, hence the 'isSubsetOf'.
chainOfTwo :: Rule (Incompatibility, Incompatibility) Text
chainOfTwo (c1, c2) = do
    (p1, s1, q1, r1) <- asDependency c1
    (p2, s2, q2, r2) <- asDependency c2
    guard (q1 == p2 && r1 `isSubsetOf` s2)
    pure (dep p1 s1 q1 r1 <> " which depends on " <> bareP q2 r2)

-- | __One depender, two dependees__ reads \"a depends on both b and c\", for
-- which the two facts must be about the same instances of @a@.
sharedDepender :: Rule (Incompatibility, Incompatibility) Text
sharedDepender (c1, c2) = do
    (p1, s1, q1, r1) <- asDependency c1
    (p2, s2, q2, r2) <- asDependency c2
    guard (p1 == p2 && s1 == s2)
    pure (namedP p1 s1 <> " depends on both " <> bareP q1 r1 <> " and " <> bareP q2 r2)

-- --------------------------------------------------------------------------
-- The pre-pass
-- --------------------------------------------------------------------------

-- | Absorb \"no version for @p@ in @r@\" facts into the sibling they were resolved
-- against, and drop the step.
--
-- Intensional ranges are why these exist at all: a dependency's declared range is
-- put into a term verbatim, so the solver has to /separately/ learn that the range's
-- holes hold no releases, and each such discovery is a leaf of the derivation. They
-- are honest facts, and they are noise.
--
-- __Why this is sound, and why it is not even a weakening.__ Resolving a unit clause
-- @{p ∈ r}@ against a dependency fact on the pivot @p@ unions the two terms about
-- @p@ and keeps the other side unchanged, so the step's own conclusion /already is/
-- that dependency with @p@'s term adjusted. The pass therefore does not recompute
-- anything: it keeps the derived node's terms exactly and re-labels them as the leaf
-- they are equivalent to. Nothing in the proof gets wider or narrower; a step that
-- said nothing new stops being a step. A fact about a version that does not exist
-- constrains nothing.
--
-- Three cases are deliberately left alone:
--
--  * __both causes are holes.__ There is no dependency to absorb into, and two empty
--    ranges do not make a sentence.
--  * __the dependee's whole range is empty.__ Then the union over the pivot is ⊤, the
--    dependee entry drops out of the resolvent, and rebuilding would produce a
--    dependency fact whose dependee range is /gone/ — the proof would say \"haddock
--    >=2.29.1 is forbidden\" and never mention @base@. @dependsOnNothing@ renders
--    that case as \"depends on … , which has no versions\", which keeps the range,
--    so the guard here is that the node must still carry a term for both packages.
--  * __the sibling is itself derived.__ Only an external dependency fact is
--    absorbed into; dropping the hole beside a derived sibling would print a
--    conclusion wider than the line's two causes justify.
collapseNoInstances :: Incompatibility -> Incompatibility
collapseNoInstances inc = case incompCause inc of
    CauseDerivedFrom c1 c2 ->
        let c1' = collapseNoInstances c1
            c2' = collapseNoInstances c2
            node = Incompatibility (incompTerms inc) (CauseDerivedFrom c1' c2')
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
        s1 <- packageSet =<< positive =<< Map.lookup (PackageVar p1) (incompTerms node)
        r2 <- packageSet =<< negative =<< Map.lookup (PackageVar q) (incompTerms node)
        pure (Incompatibility (incompTerms node) (CauseDependency p1 s1 Map.empty (q, r2)))

    dependencyPackages c = case incompCause c of
        CauseDependency p1 _ g (q, _) | p1 /= q, Map.null g -> Just (p1, q)
        _                                                   -> Nothing
