{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

-- | Rendering a failed resolution as a human-readable proof.
--
-- A terminal 'Incompatibility' carries the 'IncompatCause' tree that produced
-- it, which is all this module needs: 'reportConflict' replays that tree as a
-- numbered argument. Ranges print in Cabal syntax (@>=1.0.0 && <2@).
module PubGrub.Report
    ( reportConflict
    ) where

import qualified Data.Map.Strict         as Map
import           Data.Text               (Text)
import qualified Data.Text               as T
import           PubGrub.Incompatibility (IncompatCause (..),
                                          Incompatibility (..))
import           PubGrub.Pretty          (Pretty (..))
import           PubGrub.Term            (Term (..))

-- | Render an incompatibility and its derivation as a human-readable proof.
--
-- Each derived ('DerivedFrom') step becomes a numbered line; a step references
-- the earlier lines it was derived from as @(n)@, while external leaf facts are
-- inlined. Post-order numbering guarantees every reference points backwards.
-- A sub-derivation that two steps share is rendered once for each.
reportConflict
    :: Incompatibility -> Text
reportConflict root = case incompCause root of
    CauseDerivedFrom c1 c2 ->
        let (r1, acc1, n1) = visit c1 [] (1 :: Int)
            (r2, acc2, n2) = visit c2 acc1 n1
            final = "Because " <> r1 <> " and " <> r2 <> ", " <> conclusion root <> "."
            steps = reverse ((n2, final) : acc2)
         in T.intercalate "\n" [T.pack (show n) <> ". " <> t | (n, t) <- steps]
    _ -> leaf root
  where
    -- Emit a line per derived step, threading the next free number and the
    -- lines accumulated so far (newest first). Returns how to refer to this
    -- node: @(n)@ for a derived step, or the inlined phrase for a leaf.
    visit inc acc n = case incompCause inc of
        CauseDerivedFrom c1 c2 ->
            let (r1, acc1, n1) = visit c1 acc n
                (r2, acc2, n2) = visit c2 acc1 n1
                line = "Because " <> r1 <> " and " <> r2 <> ", " <> summary inc
             in ("(" <> T.pack (show n2) <> ")", (n2, line) : acc2, n2 + 1)
        _ -> (leaf inc, acc, n)

    -- External facts at the leaves of the proof. We render these from the cause
    -- rather than the bare terms so each explains itself: an empty range is the
    -- range simply being unsatisfiable, not a conflict with anything else.
    leaf c = case incompCause c of
        CauseNoInstances p s -> "no version for " <> pretty p <> " in " <> pretty s
        _                    -> summary c

    -- The final line of the proof. A lone positive term here is the root being
    -- ruled out at its synthetic version, which reads better as plain failure.
    conclusion c = case Map.toList (incompTerms c) of
        [(_, Positive _)] -> "version solving failed"
        _                 -> summary c

    summary c = case Map.toList (incompTerms c) of
        [] -> "version solving failed"
        [(p, Positive r)] -> pretty p <> " " <> pretty r <> " is forbidden"
        [(p, Negative r)] -> pretty p <> " " <> pretty r <> " is required"
        [(p1, Positive r1), (p2, Negative r2)] -> dep p1 r1 p2 r2
        [(p2, Negative r2), (p1, Positive r1)] -> dep p1 r1 p2 r2
        terms -> T.intercalate " and " [showTerm p t | (p, t) <- terms] <> " are incompatible"

    -- Keep the depender's range so distinct derivation steps stay distinct
    -- ("assoc ==1.0.2 depends on …" vs "assoc >=1.0.2 && <1.1 depends on …").
    dep p1 r1 p2 r2 =
        pretty p1 <> " " <> pretty r1 <> " depends on " <> pretty p2 <> " " <> pretty r2
    showTerm p (Positive r) = pretty p <> " " <> pretty r
    showTerm p (Negative r) = pretty p <> " not " <> pretty r
