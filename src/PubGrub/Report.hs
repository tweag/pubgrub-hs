{-# LANGUAGE OverloadedStrings #-}

-- | Rendering a failed resolution as a human-readable proof.
--
-- A terminal 'Incompatibility' carries the 'IncompatCause' tree that produced
-- it, which is all this module needs: 'reportConflict' replays that tree as a
-- written argument. Ranges print in Cabal syntax (@>=1.0.0 && <2@), and a
-- declared range prints as its author spelled it (@^>=1.0.0@, see
-- 'PubGrub.VersionSet.declaredRange').
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
    , reportHeadline
    , wrapProof
    , styleProof
    , rangeToken
    , collapseNoInstances
    ) where

import           Control.Monad                  (guard)
import           Data.Char                      (isDigit)
import           Data.List                      (nub, unsnoc)
import qualified Data.Map.Strict                as Map
import           Data.Maybe                     (fromMaybe)
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Data.List.NonEmpty             (NonEmpty)
import qualified Data.List.NonEmpty             as NE
import           Distribution.Pretty            (prettyShow)
import           Distribution.Types.PackageName (PackageName)
import           PubGrub.Incompatibility        (IncompatCause (..),
                                                 Incompatibility (..),
                                                 UnbuildableReason (..))
import           PubGrub.InstanceSet            (InstanceSet, isEveryVersion)
import           PubGrub.Pretty                 (Pretty (..))
import           PubGrub.SetOps                 (SetOps (union), equivalent,
                                                 isSubsetOf)
import           PubGrub.Term                   (Term (..))

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

-- | Wrap every line of a rendered proof (or headline) at @width@ columns, with a
-- four-space hanging indent on continuation lines, and never inside a range.
--
-- A proof sentence is a mixture of prose and ranges, and a range broken across
-- lines — @>=0.10.8.1 &&@ at one end and @<0.10.9.0 ||@ at the other — is the
-- worst place a terminal can wrap it. So a range is an atom here: a token that
-- opens with a comparison, @&&@, @||@, @(installed)@ or a bare version sticks to
-- the token before it, and a break falls only between atoms. An atom too long for
-- a line of its own is broken before a @||@, the one seam a range has, and an atom
-- with no seam overflows rather than break inside.
--
-- 'reportConflict' does not wrap: it writes one sentence per line, so a reader
-- that counts sentences by the start of a line can tell a continuation line here
-- by its indent.
wrapProof :: Int -> Text -> Text
wrapProof width = T.intercalate "\n" . concatMap (wrapLine width) . T.lines

wrapLine :: Int -> Text -> [Text]
wrapLine width line
    | T.length line <= width = [line]
    | otherwise = zipWith (<>) ("" : repeat indent) (build True [] (atoms (T.words line)))
  where
    indent = T.replicate 4 " "
    room first = if first then width else width - T.length indent

    -- Greedy: an atom that fits joins the line, one that does not starts the next,
    -- and one that fits no line is split at a seam.
    build _ cur [] = [T.unwords cur | not (null cur)]
    build first cur (a : as)
        | T.length (T.unwords (cur ++ [a])) <= room first = build first (cur ++ [a]) as
        | not (null cur) = T.unwords cur : build False [] (a : as)
        | otherwise = case splitSeam (room first) a of
            (h, Just rest) -> h : build False [] (rest : as)
            (h, Nothing)   -> h : build False [] as

    -- The longest prefix of the atom's @||@-separated pieces that fits, and what is
    -- left; the whole atom when it has no seam that helps.
    splitSeam n a = case T.splitOn " || " a of
        pieces@(_ : _ : _) ->
            let prefixes = [(k, T.intercalate " || " (take k pieces)) | k <- [length pieces, length pieces - 1 .. 1]]
             in case [(k, t) | (k, t) <- prefixes, T.length t <= n] of
                    (k, t) : _ | k < length pieces -> (t, Just ("|| " <> T.intercalate " || " (drop k pieces)))
                    _ -> (a, Nothing)
        _ -> (a, Nothing)

    -- A preposition joins what is before it to its object: "depends on
    -- bytestring >=0.10.4 && <0.11" and "pinned to 4.21.0.0 (installed)" are one
    -- atom each, so neither "depends" nor "on" is left at the end of a line.
    atoms [] = []
    atoms (t : ts) = let (stuck, rest) = span rangeToken ts in go (t : stuck) rest
    go cur [] = [T.unwords cur]
    go cur (t : ts)
        | t `elem` ["on", "of", "to", "with"], (u : us) <- ts =
            let (stuck, rest) = span rangeToken us in go (cur ++ t : u : stuck) rest
        | otherwise = let (stuck, rest) = span rangeToken ts in T.unwords cur : go (t : stuck) rest

-- | A token of a rendered sentence that belongs to a range rather than to the
-- prose: a comparison, @&&@, @||@, @(installed)@, or a bare version (possibly
-- ending the sentence: @4.21.0.0@ or @4.21.0.0.@). 'wrapProof' keeps such a token
-- on the line of the token before it; 'styleProof' dims it.
rangeToken :: Text -> Bool
rangeToken u =
    any (`T.isPrefixOf` u) [">=", ">", "<", "==", "^>=", "&&", "||", "(installed)"]
        || isVersion u
  where
    isVersion t = let v = T.dropWhileEnd (== '.') t in not (T.null v) && T.all (\c -> isDigit c || c == '.') v

-- | Colour a wrapped proof for a terminal: ranges dim, so the package names stand
-- out by contrast and a reader can skim the names and skip the bounds; the
-- connective that opens a sentence bold, so the sentences can be told apart from
-- their continuation lines; and the conclusion — the \"So,\" line — and the
-- headline bold throughout. Nothing is coloured that is not already there:
-- stripping the escapes gives the input back.
--
-- Whether to apply it is the caller's decision, not this module's. Apply it only
-- on a terminal with @NO_COLOR@ unset and @TERM@ not @dumb@; anything that reads
-- the proof as text expects it plain.
styleProof :: Text -> Text
styleProof = T.intercalate "\n" . go False . T.lines
  where
    -- @wholeBold@: the line before was a headline or the conclusion, so a
    -- continuation of it is bold throughout as well.
    go _ [] = []
    go wholeBold (l : ls)
        | T.null l = l : go False ls
        | "    " `T.isPrefixOf` l = (if wholeBold then bold l else tokens 0 l) : go wholeBold ls
        | "No solution" `T.isPrefixOf` l || "So, because" `T.isPrefixOf` l = bold l : go True ls
        | otherwise = tokens (openerOf (T.words l)) l : go False ls

    tokens opener l =
        let (lead, body) = T.span (== ' ') l
            (op, rest) = splitAt opener (T.words body)
         in lead <> T.unwords (map bold op ++ dimRuns rest)

    -- A run of range tokens is one dimmed span.
    dimRuns [] = []
    dimRuns ws = case span rangeToken ws of
        ([], w : rest) -> w : dimRuns rest
        (run, rest)    -> dim (T.unwords run) : dimRuns rest

    -- How many leading tokens make up the connective: "Because", "And because",
    -- and "1. And because"; a continuation line has none.
    openerOf ws = case ws of
        (n : "And" : "because" : _) | isNumber n -> 3
        ("And" : "because" : _) -> 2
        ("Because" : _) -> 1
        _ -> 0
    isNumber n = case T.unsnoc n of
        Just (ds, '.') -> not (T.null ds) && T.all isDigit ds
        _              -> False
    bold t = "\ESC[1m" <> t <> "\ESC[0m"
    dim t = "\ESC[2m" <> t <> "\ESC[0m"

-- | Render an incompatibility and its derivation as a human-readable proof.
reportConflict :: Incompatibility -> Text
reportConflict = snd . renderReport

-- | One line to put above the proof: what was asked for, and the facts about this
-- machine the proof rests on.
--
-- The proof is read bottom-up — its first line is the deepest fact and the root
-- appears only on the last — so a reader of the matterhorn proof meets @hashable@
-- before learning that @base@ is the wall. This line says both first, in the
-- proof's own words: the request is the root's dependency facts as the proof
-- names them, and the walls are its world-fact leaves ('CauseOnlyInstalled',
-- 'CauseUnbuildable'), verbatim. It claims nothing the proof does not: every
-- named fact is a premise of the derivation below it.
--
--  > No solution for matterhorn ==90000.1.1: base is pinned to 4.21.0.0 (installed).
reportHeadline :: Incompatibility -> Text
reportHeadline = fst . renderReport

renderReport :: Incompatibility -> (Text, Text)
renderReport root0 = (headline, proof)
  where
    proof = case incompCause root of
        CauseDerivedFrom _ _ ->
            render (reverse (outLines (derived True root (Out [] 1))))
        -- The terminal incompatibility is itself an external fact: nothing was
        -- derived, so the fact is the whole explanation.
        _ -> leaf root

    headline = T.concat ["No solution", forWhat, walls, "."]
      where
        forWhat = case requests of
            [] -> ""
            rs -> " for " <> T.intercalate " and " rs
        walls = case nub [leaf c | c <- externals root, isWorld c] of
            [] -> ""
            ws -> ": " <> T.intercalate "; " ws
        -- What the root asked for, as the proof itself names it. A root dependency
        -- the proof never reaches is not the one that failed.
        requests = nub [bare p r | c <- externals root, Just (rp, _, p, r) <- [asDependency c], Just rp == rootPkg]
        isWorld c = case incompCause c of
            CauseOnlyInstalled{} -> True
            CauseUnbuildable{}   -> True
            _                    -> False

    -- The external facts at the leaves, in proof order.
    externals inc = case incompCause inc of
        CauseDerivedFrom a b -> externals a ++ externals b
        _                    -> [inc]

    -- The holes go first: a derivation step that only established that a range is
    -- empty is not a step worth a line, and leaving them in is what stops the chain
    -- fusion below from ever firing on a real problem.
    root = collapseNoInstances root0

    -- The terminal incompatibility's one positive term names the root package
    -- (references/pubgrub.md:518). The root is written by name alone, without its
    -- synthetic version (:1025), and without the NUL byte the bridge prefixes to
    -- keep that name from colliding with a real package's.
    rootPkg = case Map.toList (incompTerms root0) of
        [(p, Positive _)] -> Just p
        _                 -> Nothing

    -- Every line is a sentence and ends as one. A blank line between two branches
    -- of a derivation (references/pubgrub.md:632) stays blank.
    render ls = T.intercalate "\n" [line n t | (n, t) <- ls]
    line _ "" = ""
    line n t  = prefix n <> t <> "."
    prefix Nothing  = ""
    prefix (Just n) = T.pack (show n) <> ". "

    -- A package with the set it is constrained to, as words. A set admitting every
    -- version reads "every version of foo" (references/pubgrub.md:1013) where the
    -- sentence calls for it — as the subject of "depends on" or "requires" — and
    -- the bare name where it does not: pub writes "foo is forbidden", not "every
    -- version of foo is forbidden", and "depends on bar" rather than "depends on
    -- every version of bar".
    named :: PackageName -> InstanceSet -> Text
    named p s
        | Just p == rootPkg = rootLabel p
        | isEveryVersion s  = "every version of " <> pretty p
        | otherwise         = pretty p <> " " <> pretty s

    bare :: PackageName -> InstanceSet -> Text
    bare p s
        | Just p == rootPkg = rootLabel p
        | isEveryVersion s  = pretty p
        | otherwise         = pretty p <> " " <> pretty s

    rootLabel = T.filter (/= '\0') . pretty

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
            -- The blank line between the two branches is the spec's (:632): it
            -- marks that a new line of derivation starts.
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
                        (derived False c2 (emit "" out'))
        -- Not reached: 'derived' is only ever called on a derived node.
        _ -> emit (leaf inc) out

    -- Case 2, with @d@ the derived cause and @e@ the external fact.
    --
    -- Before the ordinary every-other-step skip, look for a __run__ of steps that
    -- all say the same kind of thing: this range of @p@ depends on @q@, and so does
    -- the next range, and the next. That is one fact about @p@ as a whole, and
    -- printed a range at a time it walks one bound's history an adjacent pair of
    -- releases at a time (four of @matterhorn@'s ten lines did this to @hashable@).
    --
    -- It is /not/ the same thing as references/pubgrub.md:456's collapsing, which
    -- merges facts with an __identical__ dependee range. Here the dependee ranges
    -- differ — that is why the solver had to derive its way along them — and what is
    -- printed is their union.
    oneDerived final d e inc out
        | Just (p, s, q, r) <- asDependency e
        , (rest', extra@(_ : _)) <- depRun p q d
        , let ss = foldr1 union (s : map fst extra)
        , let rs = foldr1 union (r : map snd extra)
        , -- Only when the conclusion really is "p requires q", and the collapsed
          -- depender range is one the conclusion covers. Stating the union of the
          -- facts is sound on its own — each says @p ∈ Sᵢ@ requires @q ∈ Rᵢ@, so
          -- @p ∈ ⋃S@ requires @q ∈ ⋃R@ — but a line may not claim to justify more
          -- of @p@ than the step it is attached to concluded, and this is what stops
          -- it. 'isSubsetOf' is one-sided the safe way: it can only refuse a
          -- collapse that would have been fine.
          concludesRequires p q inc
        , Just (Positive sInc) <- Map.lookup p (incompTerms inc)
        , ss `isSubsetOf` sInc =
            emit
                (opening final "And because " <> dep p ss q rs <> ", " <> says final inc)
                (derived False rest' out)
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

    -- Walk down the derived spine collecting external dependency facts that are all
    -- about the same @(depender, dependee)@ package pair. Answers where the run
    -- bottoms out and what it collected; an empty collection means there was no run
    -- and the ordinary cases apply.
    depRun p q = go []
      where
        go acc node = case chainStep node of
            Just (pd, pe)
                | Just (p', s, q', r) <- asDependency pe
                , p' == p
                , q' == q ->
                    go ((s, r) : acc) pd
            _ -> (node, acc)

    -- Is this step's conclusion of the shape "p requires q"? Anything else and the
    -- collapsed sentence would be attached to a claim it does not support.
    concludesRequires p q inc = case Map.toList (incompTerms inc) of
        [(a, Positive _), (b, Negative _)] -> (a, b) == (p, q)
        [(b, Negative _), (a, Positive _)] -> (a, b) == (p, q)
        _                                  -> False

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
                named p1 s1
                    <> " depends on both "
                    <> bare q1 r1
                    <> " and "
                    <> bare q2 r2
        _ -> leaf c1 <> " and " <> leaf c2

    chain p s q r q' r' =
        dep p s q r <> " which depends on " <> bare q' r'

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
    -- compiler-provided package names the version it is pinned to instead of
    -- reading "no version" — the bound that failed is only legible against that
    -- version, and nothing else in the proof states it — and a release that cannot
    -- be built here says /that/, and why, rather than looking absent
    -- (references/pubgrub.md:475).
    leaf c = case incompCause c of
        CauseNoInstances p s -> "no version for " <> pretty p <> " in " <> pretty s
        CauseOnlyInstalled p [] -> pretty p <> " is not installed and cannot be built from source"
        CauseOnlyInstalled p vs ->
            pretty p <> " is pinned to " <> T.intercalate " or " (map pretty vs) <> " (installed)"
        CauseUnbuildable p s why -> named p s <> " " <> reasons why
        _ -> case asDependency c of
            Just (p, s, q, r) -> dep p s q r
            Nothing           -> summary c

    -- Why a release cannot be built, as the predicate of its sentence: \"needs
    -- pkg-config package libpq, which is not found\", and \"is marked buildable:
    -- False\". The two are joined with \"and\" when both hold, and several modules
    -- share one \"needs\". Not \"cannot be built because …\": the chain form puts
    -- this leaf after a \"Because\" of its own, and two in one sentence read badly.
    --
    -- The module is spelled as Cabal-syntax prints the @pkgconfig-depends@ field:
    -- @libpq@ unbounded, @zlib >=1.2@ with its range. Cabal's own message reads
    -- \"pkg-config package libpq-any, not found in the pkg-config database\"; the
    -- @-any@ is its spelling of the empty range, and is not copied.
    reasons :: NonEmpty UnbuildableReason -> Text
    reasons why =
        T.intercalate " and " $
            ["is marked buildable: False" | NotBuildable `elem` why] ++ needs
      where
        needs = case [T.pack (prettyShow d) | MissingPkgConfig d <- NE.toList why] of
            []  -> []
            [m] -> ["needs pkg-config package " <> m <> ", which is not found"]
            ms  -> ["needs pkg-config packages " <> listing ms <> ", which are not found"]
        -- "libpq, zlib and openssl"
        listing ms = case unsnoc ms of
            Just (front@(_ : _), l) -> T.intercalate ", " front <> " and " <> l
            _                       -> T.intercalate ", " ms

    -- What a line concludes. On the proof's last line a lone positive term is the
    -- root being ruled out at its synthetic version, which reads better as plain
    -- failure.
    says final c
        | final = case Map.toList (incompTerms c) of
            [(_, Positive _)] -> "version solving failed"
            _                 -> summary c
        | otherwise = summary c

    -- What an incompatibility says, in pub's own forms (the spec leaves the
    -- wording to the implementation, references/pubgrub.md:677; these are pub's,
    -- in cabal's range syntax). A negative term is never written as "not …": it
    -- says the package /must/ be in that set, and the sentence carries the
    -- negation — "foo requires bar >=2", "if foo and bar then baz <3", "either
    -- foo <2 or bar <3".
    summary c = case Map.toList (incompTerms c) of
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
                anyOf = T.intercalate " or "
             in case (positives, negatives) of
                    ([(p, r)], _ : _) -> named p r <> " requires " <> anyOf negatives
                    (_ : _, _ : _) ->
                        "if " <> T.intercalate " and " (map (uncurry bare) positives)
                            <> " then " <> anyOf negatives
                    (_, []) -> "one of " <> anyOf (map (uncurry bare) positives) <> " must be false"
                    ([], _) -> "one of " <> anyOf negatives <> " must be true"

    -- Keep the depender's range so distinct derivation steps stay distinct
    -- ("assoc ==1.0.2 depends on …" vs "assoc >=1.0.2 && <1.1 depends on …").
    dep p1 r1 p2 r2 = named p1 r1 <> " depends on " <> bare p2 r2

    -- A /derived/ two-term incompatibility. The spec says "requires" here and
    -- keeps "depends on" for the external fact (references/pubgrub.md:1005,
    -- both in one line): a dependency is declared in a @.cabal@ file, a
    -- requirement is what the solver worked out from one.
    requires p1 r1 p2 r2 = named p1 r1 <> " requires " <> bare p2 r2
