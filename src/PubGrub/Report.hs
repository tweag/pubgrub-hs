{-# LANGUAGE OverloadedStrings #-}

-- | Rendering a failed resolution as a human-readable proof.
--
-- A terminal 'Incompatibility' carries the 'IncompatCause' tree that produced
-- it, which is all this module needs: 'reportConflict' replays that tree as a
-- written argument. Ranges print in Cabal syntax (@>=1.0.0 && <2@).
--
-- == Two rules keep the proof short
--
-- Replayed naively, one line per derived incompatibility and each naming one
-- external fact, a proof is too long to read to the end.
--
--  * __A chain of two external facts is one sentence.__ Where a dependency's
--    dependee is the depender of the next, the proof says \"@foo@ depends on
--    @bar@ /which depends on/ @baz@\" rather than naming @bar@ twice, and where
--    two facts share a depender it says \"depends on /both/ X and Y\". Both
--    live in @pair@.
--
--  * __Every other derived step is skipped.__ Where a step's derived cause has a
--    single derived cause of its own, that intermediate /conclusion/ is left out
--    and both external facts are named in one line. Since most derivation graphs
--    are linear chains, this halves them.
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
    , collapseNoInstances
    ) where

import           Control.Monad           (guard)
import qualified Data.Map.Strict         as Map
import           Data.Maybe             (fromMaybe)
import           Data.Text               (Text)
import qualified Data.Text               as T
import           PubGrub.Incompatibility (IncompatCause (..),
                                          Incompatibility (..))
import           PubGrub.Pretty          (Pretty (..))
import           PubGrub.SetOps          (equivalent, isSubsetOf)
import           PubGrub.Term            (Term (..))

-- | The proof under construction: its lines __newest first__, and the next free
-- line number.
data Out = Out
    { outLines :: [(Maybe Int, Text)]
    , outNext  :: !Int
    }

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
--    >=2.29.1 is forbidden\" and never mention @base@. @pair@ renders that case as
--    \"depends on … , which has no versions\", which keeps the range, so the guard
--    here is that the node must still carry a term for both packages.
--  * __the sibling is itself derived.__ Only an external dependency fact is
--    absorbed into; dropping the hole beside a derived sibling would print a
--    conclusion wider than the line's two causes justify.
collapseNoInstances :: Incompatibility -> Incompatibility
collapseNoInstances inc = case incompCause inc of
    CauseDerivedFrom c1 c2 ->
        let c1' = collapseNoInstances c1
            c2' = collapseNoInstances c2
            node = Incompatibility (incompTerms inc) (CauseDerivedFrom c1' c2')
         in fromMaybe node (absorb node c1' c2' `orElse` absorb node c2' c1')
    _ -> inc
  where
    orElse (Just x) _ = Just x
    orElse Nothing y  = y

    -- @hole@ is a range known empty, @other@ the dependency fact it was resolved
    -- against. Answers with the node re-labelled as that dependency, over the node's
    -- own terms.
    absorb node hole other = do
        p <- emptyRange hole
        (p1, q) <- dependencyPackages other
        guard (p == p1 || p == q)
        guard (Map.size (incompTerms node) == 2)
        s1 <- positive =<< Map.lookup p1 (incompTerms node)
        r2 <- negative =<< Map.lookup q (incompTerms node)
        pure (Incompatibility (incompTerms node) (CauseDependency p1 s1 (q, r2)))

    emptyRange c = case incompCause c of
        CauseNoInstances p _ -> Just p
        _                    -> Nothing

    dependencyPackages c = case incompCause c of
        CauseDependency p1 _ (q, _) | p1 /= q -> Just (p1, q)
        _                                     -> Nothing

    positive (Positive s) = Just s
    positive _            = Nothing
    negative (Negative s) = Just s
    negative _            = Nothing

-- | Render an incompatibility and its derivation as a human-readable proof.
reportConflict :: Incompatibility -> Text
reportConflict root0 = case incompCause root of
    CauseDerivedFrom _ _ ->
        render (reverse (outLines (derived True root (Out [] 1))))
    -- The terminal incompatibility is itself an external fact: nothing was
    -- derived, so the fact is the whole explanation.
    _ -> leaf root
  where
    -- The holes go first: a derivation step that only established that a range is
    -- empty is not a step worth a line, and leaving them in is what stops the chain
    -- fusion below from ever firing on a real problem.
    root = collapseNoInstances root0

    render ls = T.intercalate "\n" [prefix n <> t | (n, t) <- ls]
    prefix Nothing  = ""
    prefix (Just n) = T.pack (show n) <> ". "

    -- Explain one derived incompatibility, ending with the line that concludes it.
    -- @final@ marks the last line of the whole proof, which reads "So, …".
    derived final inc out = case incompCause inc of
        CauseDerivedFrom c1 c2 -> case (isDerived c1, isDerived c2) of
            -- Case 3 (references/pubgrub.md:668): both causes are external. One
            -- line, and the only case that opens a line of derivation rather than
            -- continuing one.
            (False, False) ->
                emit (opening final "Because " <> pair c1 c2 <> ", " <> says final inc) out
            -- Case 2 (references/pubgrub.md:641): one derived cause, one external
            -- fact.
            (True, False) -> oneDerived final c1 c2 inc out
            (False, True) -> oneDerived final c2 c1 inc out
            -- Case 1 (references/pubgrub.md:595): both causes derived — the
            -- derivation branches, and this is the only place a line number is
            -- wanted. Explain the first branch, number the line it ends on, then
            -- explain the second and close by referring back.
            (True, True) ->
                let (n, out') = numberLast (derived False c1 out)
                 in emit
                        ( opening final "And because "
                            <> summary c1
                            <> " ("
                            <> T.pack (show n)
                            <> "), "
                            <> says final inc
                        )
                        (derived False c2 out')
        -- Not reached: 'derived' is only ever called on a derived node.
        _ -> emit (leaf inc) out

    -- Case 2, with @d@ the derived cause and @e@ the external fact.
    oneDerived final d e inc out = case chainStep d of
        -- Case 2.ii — the every-other-step skip. @d@'s own conclusion is left
        -- unsaid and the two external facts are named together here, which is
        -- where a long linear chain loses half its lines.
        Just (pd, pe) ->
            emit
                (opening final "And because " <> pair pe e <> ", " <> says final inc)
                (derived False pd out)
        -- Case 2.iii: @d@ branches or bottoms out, so it gets its own lines and
        -- this one closes with the external fact alone.
        Nothing ->
            emit
                (opening final "And because " <> leaf e <> ", " <> says final inc)
                (derived False d out)

    -- A derived node that can be folded into its parent's line: exactly one
    -- derived cause and one external fact. Answers with the pair, the derived
    -- cause first.
    chainStep inc = case incompCause inc of
        CauseDerivedFrom a b -> case (isDerived a, isDerived b) of
            (True, False) -> Just (a, b)
            (False, True) -> Just (b, a)
            _             -> Nothing
        _ -> Nothing

    -- "So," instead of "And" marks the conclusion rather than another step
    -- (references/pubgrub.md:1027).
    opening final base = if final then "So, because " else base

    emit t out = out{outLines = (Nothing, t) : outLines out}

    -- Give the line just emitted a number, so a later line can cite it. Numbers
    -- are minted here and nowhere else.
    numberLast out = case outLines out of
        ((Just n, t) : rest) -> (n, out{outLines = (Just n, t) : rest})
        ((Nothing, t) : rest) ->
            ( outNext out
            , out{outLines = (Just (outNext out), t) : rest, outNext = outNext out + 1}
            )
        -- Unreachable: every branch emits at least one line before this is called.
        -- Answering with the unused number keeps the proof well-formed if it ever is.
        [] -> (outNext out, out)

    isDerived c = case incompCause c of
        CauseDerivedFrom _ _ -> True
        _                    -> False

    -- Two external facts, as one clause. Two fusions, each guarded so that it
    -- cannot say more than the facts do:
    --
    --  * a __chain__ — the first fact's dependee is the second's depender — reads
    --    "a depends on b which depends on c". That is only true if every instance
    --    the first fact leaves open for the middle package is one the second fact
    --    speaks about, hence the 'isSubsetOf';
    --  * __one depender, two dependees__ reads "a depends on both b and c", for
    --    which the two facts must be about the same instances of @a@.
    --
    -- 'PubGrub.SetOps.isEmpty' on an 'InstanceSet' is one-sided — it may fail to
    -- notice that a set is empty — so both guards can only fail to fuse where they
    -- could have. Neither can fuse where it should not.
    pair c1 c2 = case (emptyRangeFor c1 c2, emptyRangeFor c2 c1) of
        -- A dependency whose dependee range the solver has already found empty.
        -- Naming both facts would print that range /twice/ in one sentence, and
        -- on a real proof it is not short: haddock 2.29.1's bound on base is
        -- seven windows.
        --
        -- Saying it once is sound only when the dependency's whole range is inside
        -- the empty one, which is what the 'isSubsetOf' checks. Where it is only
        -- partly inside, the two facts stay separate — absorbing that case means
        -- widening the term rather than dropping a clause, so it is not a
        -- rendering change.
        (Just one, _) -> one
        (_, Just one) -> one
        _ -> pairDeps c1 c2

    -- @dep@'s dependee range known empty by @hole@?
    emptyRangeFor dep' hole = case (asDependency dep', incompCause hole) of
        (Just (p, s, q, r), CauseNoInstances q' empty)
            | q == q', r `isSubsetOf` empty ->
                Just (dep p s q r <> ", which has no versions")
        _ -> Nothing

    pairDeps c1 c2 = case (asDependency c1, asDependency c2) of
        (Just (p1, s1, q1, r1), Just (p2, s2, q2, r2))
            | q1 == p2, r1 `isSubsetOf` s2 -> chain p1 s1 q1 r1 q2 r2
            | q2 == p1, r2 `isSubsetOf` s1 -> chain p2 s2 q2 r2 q1 r1
            | p1 == p2, s1 `equivalent` s2 ->
                pretty p1
                    <> " "
                    <> pretty s1
                    <> " depends on both "
                    <> pretty q1
                    <> " "
                    <> pretty r1
                    <> " and "
                    <> pretty q2
                    <> " "
                    <> pretty r2
        _ -> leaf c1 <> " and " <> leaf c2

    chain p s q r q' r' =
        dep p s q r <> " which depends on " <> pretty q' <> " " <> pretty r'

    -- A dependency fact whose dependee term survived. 'fromDependency' drops that
    -- term when the dependency is unsatisfiable, and then there is no "depends on"
    -- left to render: the clause is a bare ban on the depender and reads as one.
    asDependency c = case incompCause c of
        CauseDependency p s (q, r)
            | q /= p, Map.member q (incompTerms c) -> Just (p, s, q, r)
        _ -> Nothing

    -- External facts at the leaves of the proof. Rendered from the cause rather
    -- than from the bare terms so that each explains itself: an empty range is the
    -- range being unsatisfiable rather than a conflict with anything else, a
    -- package that is only installed says it cannot be built from source, and a
    -- release that cannot be built here says /that/ rather than looking absent
    -- (references/pubgrub.md:475).
    leaf c = case incompCause c of
        CauseNoInstances p s -> "no version for " <> pretty p <> " in " <> pretty s
        CauseOnlyInstalled p -> pretty p <> " cannot be built from source"
        CauseUnbuildable p s -> pretty p <> " " <> pretty s <> " cannot be built here"
        _ -> case asDependency c of
            Just (p, s, q, r) -> dep p s q r
            Nothing           -> summary c

    -- What a line concludes. On the proof's last line a lone positive term is the
    -- root being ruled out at its synthetic version, which reads better as plain
    -- failure.
    says final c
        | final = case Map.toList (incompTerms c) of
            [(_, Positive _)] -> "version solving failed"
            _                 -> summary c
        | otherwise = summary c

    summary c = case Map.toList (incompTerms c) of
        [] -> "version solving failed"
        [(p, Positive r)] -> pretty p <> " " <> pretty r <> " is forbidden"
        [(p, Negative r)] -> pretty p <> " " <> pretty r <> " is required"
        [(p1, Positive r1), (p2, Negative r2)] -> requires p1 r1 p2 r2
        [(p2, Negative r2), (p1, Positive r1)] -> requires p1 r1 p2 r2
        terms -> T.intercalate " and " [showTerm p t | (p, t) <- terms] <> " are incompatible"

    -- Keep the depender's range so distinct derivation steps stay distinct
    -- ("assoc ==1.0.2 depends on …" vs "assoc >=1.0.2 && <1.1 depends on …").
    dep p1 r1 p2 r2 =
        pretty p1 <> " " <> pretty r1 <> " depends on " <> pretty p2 <> " " <> pretty r2

    -- A /derived/ two-term incompatibility. The spec says "requires" here and
    -- keeps "depends on" for the external fact (references/pubgrub.md:1005,
    -- both in one line): a dependency is declared in a @.cabal@ file, a
    -- requirement is what the solver worked out from one.
    requires p1 r1 p2 r2 =
        pretty p1 <> " " <> pretty r1 <> " requires " <> pretty p2 <> " " <> pretty r2

    showTerm p (Positive r) = pretty p <> " " <> pretty r
    showTerm p (Negative r) = pretty p <> " not " <> pretty r
