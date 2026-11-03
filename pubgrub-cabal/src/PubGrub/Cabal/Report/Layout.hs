{-# LANGUAGE OverloadedStrings #-}

-- | Two layers a caller can put over a rendered proof: wrapping to the
-- terminal's width, and colour. Neither changes a word. 'PubGrub.Report' itself
-- does neither, so its output stays plain text, one sentence per line, for a
-- tool that compares proofs or counts their sentences.
module PubGrub.Cabal.Report.Layout
    ( wrapProof
    , styleProof
    , rangeToken
    ) where

import           Data.Char (isDigit)
import           Data.Text (Text)
import qualified Data.Text as T

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
-- 'PubGrub.Report.reportConflict' does not wrap: its output is one sentence per
-- line, so a reader can count sentences by the connective that opens a line. A
-- continuation line starts with the indent and opens with no connective.
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
-- Whether to apply it is the caller's decision, not this module's; the usual
-- test is a terminal, with @NO_COLOR@ unset and @TERM@ not @dumb@. Off a
-- terminal a proof should stay plain text.
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
    -- and either with a line number, "1. Because"; a continuation line has none.
    openerOf ws = case ws of
        (n : "And" : "because" : _) | isNumber n -> 3
        (n : "Because" : _) | isNumber n         -> 2
        ("And" : "because" : _)                  -> 2
        ("Because" : _)                          -> 1
        _                                        -> 0
    isNumber n = case T.unsnoc n of
        Just (ds, '.') -> not (T.null ds) && T.all isDigit ds
        _              -> False
    bold t = "\ESC[1m" <> t <> "\ESC[0m"
    dim t = "\ESC[2m" <> t <> "\ESC[0m"
