{-# LANGUAGE OverloadedStrings #-}

-- | Rendering a failed resolution as a human-readable proof, over any 'Domain'.
--
-- A terminal t'Incompatibility' carries the 'Cause' tree that produced it, which
-- is all this module needs: 'reportConflict' replays that tree as PubGrub's
-- argument for why no solution exists, one line per step it keeps, ending
-- \"So, because …, version solving failed\".
--
-- == What is fixed and what is the domain's
--
-- The wording is the domain's; the /shape/ of the argument is fixed: which
-- steps get a line, which are skipped, where a line number is minted and where
-- a blank line falls. The shape is here, written once. The words come from a
-- t'Formatter' the domain supplies (what a fact says, what a /hole/, a set of
-- values in which the provider had nothing, says, and what a set of terms
-- concludes), together with any rules of its own that say a step in fewer
-- lines than the standard cases would, and a pass over the tree before the walk
-- begins.
--
-- == How the proof is made
--
-- The walker visits each derived step and writes one line for it: a
-- connective, a __premise__, and what the step concludes. The premise is what
-- varies, and it is chosen by a __rule__ — the first of the line rules to fire.
-- A rule is a @do@ block in 'Maybe', written in the vocabulary of
-- "PubGrub.Derivation": each line reads a view of the tree or states a guard,
-- and the last says the premise and names the sub-derivation, if any, the line
-- continues (@Line@). Two facts named together in one premise are joined by a
-- second table, the clause rules, in the same language.
--
-- Two rules keep the proof short, and both are PubGrub's own. Neither is
-- cosmetic: a proof is only useful if it is read to the end, and the naive
-- replay of the derivation tree — one line per derived incompatibility, each
-- naming one external fact — is too long for that.
--
--  * __A chain of two external facts is one sentence__: a domain's clause rules.
--    Where a dependency's dependee is the depender of the next, the proof writes
--    \"@foo@ depends on @bar@ /which depends on/ @baz@\" rather than naming
--    @bar@ twice, and where two facts share a depender it writes \"depends on
--    /both/ X and Y\". What a dependency is, the core does not know, so these
--    rules belong to the domain's t'Formatter'.
--
--  * __Every other derived step is skipped__. Where a step's derived cause has
--    a single derived cause of its own, that intermediate /conclusion/ is left
--    out and both external facts are named in one line. Most derivation graphs
--    are linear chains, so this halves them without losing anything a reader
--    needs.
--
-- == Line numbers are for joins only
--
-- A line is numbered only if a later line refers back to it, and in a linear
-- chain none does. A number is given only at a step with two derived causes,
-- so a proof that never branches carries no numbers at all.
--
-- A sub-derivation that two steps share is explained twice rather than
-- referred to: an t'Incompatibility' has no identity to recognise it by.
module PubGrub.Report
    ( -- * The domain's words
      Formatter (..)
    , Line (..)
    , leaf
    , summaryWith
    , listing
    , anyOf
      -- * The proof
    , reportConflict
    ) where

import           Data.List               (unsnoc)
import           Data.Map.Strict         (Map)
import qualified Data.Map.Strict         as Map
import           Data.Maybe              (fromMaybe)
import           Data.Text               (Text)
import qualified Data.Text               as T
import           PubGrub.Derivation      (Rule, bothDerived, bothExternal,
                                          chainStep, firstOf, isDerived)
import           PubGrub.Incompatibility (Cause (..), Domain (..),
                                          Incompatibility (..))
import           PubGrub.Term            (Term (..))

-- --------------------------------------------------------------------------
-- The domain's words
-- --------------------------------------------------------------------------

-- | What a domain says, and the rules of its own it adds to the standard ones.
--
-- Every field that says something answers with a fragment: no connective in
-- front of it and no full stop after it, because the walker puts its own
-- \"Because\" before a fragment and ends every line as a sentence. A fragment
-- must therefore never open with \"because\" or \"and\".
data Formatter d = Formatter
    { sayFact     :: FactOf d -> Incompatibility d -> Text
      -- ^ a leaf that states a fact, a seed's or the provider's; the
      -- incompatibility it is the cause of comes with it, for a fact whose
      -- sentence depends on which of its terms survived
    , sayNoValues :: VarOf d -> SetOf d -> Text
      -- ^ the solver's own leaf: nothing to offer in this set
    , sayTerms    :: Map (VarOf d) (Term (SetOf d)) -> Text
      -- ^ what a set of terms concludes; 'summaryWith' is the standard sentences
    , prepare     :: Incompatibility d -> Incompatibility d
      -- ^ a pass over the tree before the walk; 'id' for none
    , lineRules   :: [Rule (Incompatibility d) (Line d)]
      -- ^ the domain's own ways of saying a step that is not a branch, tried
      -- before the standard rules for a chain of steps; a rule must keep the
      -- proof sound on its own, and can check that it does by replaying the
      -- steps it covers with 'PubGrub.Incompatibility.priorCauseTerms'
    , clauseRules :: [Rule (Incompatibility d, Incompatibility d) Text]
      -- ^ the domain's ways of saying two external facts as one premise, tried
      -- in order; the fallback names them side by side
    }

-- | What a rule proposes for one line of the proof.
data Line d
    = Line
        Text
        -- ^ the premise, which goes after the connective
        (Maybe (Incompatibility d))
        -- ^ the sub-derivation the line continues, explained before it; a line
        -- that continues nothing opens a line of derivation

-- | An external fact at a leaf of the proof, in the domain's words; a derived
-- node, which is not a leaf, reads as what its terms conclude.
leaf :: Formatter d -> Incompatibility d -> Text
leaf fmt c = case incompCause c of
    Seed f       -> sayFact fmt f c
    Fact f       -> sayFact fmt f c
    NoValues v s -> sayNoValues fmt v s
    Derived _ _  -> sayTerms fmt (incompTerms c)

-- | What an incompatibility says, in PubGrub's standard sentences, given how
-- the domain names a variable with its set: @named@ where the sentence calls
-- for the full form (\"every version of foo\") and @bare@ where it does not. A
-- negative term is never written as \"not …\": it says the variable /must/ be
-- in that set, and the sentence carries the negation — \"foo requires bar >=2\",
-- \"if foo and bar then baz <3\", \"either foo <2 or bar <3\". The empty
-- incompatibility is failure by name: \"version solving failed\".
summaryWith
    :: (VarOf d -> SetOf d -> Text)
    -> (VarOf d -> SetOf d -> Text)
    -> Map (VarOf d) (Term (SetOf d))
    -> Text
summaryWith named bare ts = case Map.toList ts of
    [] -> "version solving failed"
    [(p, Positive r)] -> bare p r <> " is forbidden"
    [(p, Negative r)] -> bare p r <> " is required"
    [(p1, Positive r1), (p2, Negative r2)] -> requires p1 r1 p2 r2
    [(p2, Negative r2), (p1, Positive r1)] -> requires p1 r1 p2 r2
    [(p1, Positive r1), (p2, Positive r2)] -> bare p1 r1 <> " is incompatible with " <> bare p2 r2
    [(p1, Negative r1), (p2, Negative r2)] -> "either " <> bare p1 r1 <> " or " <> bare p2 r2
    terms ->
        let positives = [(p, r) | (p, Positive r) <- terms]
            negatives = [bare p r | (p, Negative r) <- terms]
         in case (positives, negatives) of
                ([(p, r)], _ : _) -> named p r <> " requires " <> anyOf negatives
                (_ : _, _ : _) ->
                    "if " <> T.intercalate " and " (map (uncurry bare) positives)
                        <> " then " <> anyOf negatives
                (_, []) -> "one of " <> anyOf (map (uncurry bare) positives) <> " must be false"
                ([], _) -> "one of " <> anyOf negatives <> " must be true"
  where
    -- A /derived/ two-term incompatibility. The spec says \"requires\" here and
    -- keeps \"depends on\" for the external fact (@:1005@, both in one line): a
    -- dependency is declared, a requirement is what the solver worked out.
    requires p1 r1 p2 r2 = named p1 r1 <> " requires " <> bare p2 r2

-- | \"a, b and c\"
listing :: [Text] -> Text
listing xs = case unsnoc xs of
    Just (front@(_ : _), l) -> T.intercalate ", " front <> " and " <> l
    _                       -> T.intercalate ", " xs

-- | \"a or b or c\"
anyOf :: [Text] -> Text
anyOf = T.intercalate " or "

-- --------------------------------------------------------------------------
-- The proof
-- --------------------------------------------------------------------------

-- | Render an incompatibility and its derivation as a human-readable proof.
reportConflict :: Domain d => Formatter d -> Incompatibility d -> Text
reportConflict fmt root0
    | isDerived root = render (reverse (outLines (derived fmt True root (Out [] 1))))
    -- The terminal incompatibility is itself an external fact: nothing was
    -- derived, so the fact is the whole explanation.
    | otherwise = leaf fmt root
  where
    root = prepare fmt root0

    -- Every line is a sentence and ends as one. A blank line between two
    -- branches of a derivation (references/pubgrub.md:632) stays blank.
    render ls = T.intercalate "\n" [line n t | (n, t) <- ls]
    line _ "" = ""
    line n t  = prefix n <> t <> "."
    prefix Nothing  = ""
    prefix (Just n) = T.pack (show n) <> ". "

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
derived :: Domain d => Formatter d -> Bool -> Incompatibility d -> Out -> Out
derived fmt final inc out = case bothDerived inc of
    -- Case 1 (references/pubgrub.md:595): both causes derived — the derivation
    -- branches, and this is the only place a line number is wanted. Explain the
    -- first branch, number the line it ends on, then explain the second and close
    -- by referring back. The blank line between the two branches is the spec's
    -- (:632): it marks that a new line of derivation starts. No rule chooses
    -- this: it is the structure of the proof, not a way of saying a step.
    Just (c1, c2) ->
        let (n, out') = numberLast (derived fmt False c1 out)
         in emit
                (opening (Just c2) <> summary c1 <> " (" <> T.pack (show n) <> "), " <> says inc)
                (derived fmt False c2 (emit "" out'))
    Nothing -> case firstOf rules inc of
        Just (Line premise below) ->
            emit
                (opening below <> premise <> ", " <> says inc)
                (maybe out (\d -> derived fmt False d out) below)
        -- Not reached: a derived step either branches, chains or joins two
        -- facts, and the last two rules of the table fire on any such step.
        Nothing -> emit (leaf fmt inc) out
  where
    -- The domain's rules go between the spec's case 3 and its case 2: a run
    -- rule collapses what the ordinary skip would print two facts at a time,
    -- and the spec's 2.iii fires on any chain step, so the table is total over
    -- chain steps. Case 3 fires only on a step both of whose causes are
    -- external, which no chain rule reads, so its place in the table is free.
    rules = twoFacts fmt : lineRules fmt ++ [everyOtherStep fmt, oneFact fmt]

    summary c = sayTerms fmt (incompTerms c)

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
-- The spec's cases
-- --------------------------------------------------------------------------

-- | Both causes are external. One line, and the only case that opens a line
-- of derivation rather than continuing one.
twoFacts :: Formatter d -> Rule (Incompatibility d) (Line d)
twoFacts fmt step = do
    (c1, c2) <- bothExternal step
    pure (Line (clause fmt c1 c2) Nothing)

-- | One cause is derived, from a derived cause and an external fact of its
-- own: the every-other-step skip. The derived cause's own conclusion is left
-- unsaid and the two external facts are named together here, which is where a
-- long linear chain loses half its lines.
everyOtherStep :: Formatter d -> Rule (Incompatibility d) (Line d)
everyOtherStep fmt step = do
    (d, e) <- chainStep step
    (dd, de) <- chainStep d
    pure (Line (clause fmt de e) (Just dd))

-- | One cause is derived and one external, and the derived cause branches or
-- bottoms out, so it gets its own lines and this one closes with the external
-- fact alone.
oneFact :: Formatter d -> Rule (Incompatibility d) (Line d)
oneFact fmt step = do
    (d, e) <- chainStep step
    pure (Line (leaf fmt e) (Just d))

-- | Two external facts, as one clause: the first of the domain's clause rules
-- to fire, or the two facts side by side.
clause :: Formatter d -> Incompatibility d -> Incompatibility d -> Text
clause fmt c1 c2 = fromMaybe (leaf fmt c1 <> " and " <> leaf fmt c2) (firstOf (clauseRules fmt) (c1, c2))
