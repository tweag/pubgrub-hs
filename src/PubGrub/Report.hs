{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

-- | Rendering a failed resolution as a human-readable proof. Turns the terminal
-- 'Incompatibility' and its derivation tree into numbered explanatory lines.
module PubGrub.Report (
    ReportEnv (..),
    defaultReportEnv,
    reportConflict,
    reportConflictWith,
) where

import qualified Data.Map.Strict         as Map
import           Data.Text               (Text)
import qualified Data.Text               as T
import           PubGrub.Incompatibility (IncompatCause (..),
                                          Incompatibility (..))
import           PubGrub.Lattice         (Sets (Elem))
import           PubGrub.Pretty          (Pretty (..))
import           PubGrub.Term            (Term (..))

-- | Caller-supplied context for rendering a conflict. The solver is generic
-- over the package type, but a good report needs facts only the caller knows:
-- which packages are the synthetic root, and which are fixed by the compiler
-- (boot packages) rather than chosen from a range.
newtype ReportEnv p s = ReportEnv
    { rePinned :: p -> Maybe (Elem s)
    -- ^ The element a package is pinned to by the compiler, if it is a boot
    -- package. Used to explain an empty range as "provided by the compiler as
    -- X" instead of the misleading "no version for …".
    }

-- | A context in which no package is pinned and none is the synthetic root.
defaultReportEnv :: ReportEnv p s
defaultReportEnv = ReportEnv{rePinned = const Nothing}

-- | 'reportConflictWith' using 'defaultReportEnv'.
reportConflict :: (Pretty s, Pretty (Elem s), Pretty p) => Incompatibility p s -> Text
reportConflict = reportConflictWith defaultReportEnv

-- | Render an incompatibility and its derivation as a human-readable proof.
--
-- Each derived ('DerivedFrom') step becomes a numbered line; a step references
-- the earlier lines it was derived from as @(n)@, while external leaf facts are
-- inlined. Post-order numbering guarantees every reference points backwards.
-- A sub-derivation that two steps share is rendered once for each.
reportConflictWith
    :: forall p s
     . (Pretty s, Pretty (Elem s), Pretty p)
    => ReportEnv p s -> Incompatibility p s -> Text
reportConflictWith env root = case incompCause root of
    DerivedFrom c1 c2 ->
        let (r1, acc1, n1) = visit c1 [] 1
            (r2, acc2, n2) = visit c2 acc1 n1
            final = "Because " <> r1 <> " and " <> r2 <> ", " <> conclusion root <> "."
            steps = reverse ((n2, final) : acc2)
         in T.intercalate "\n" [T.pack (show n) <> ". " <> t | (n, t) <- steps]
    _ -> leaf root
  where
    -- Emit a line per derived step, threading the next free number and the
    -- lines accumulated so far (newest first). Returns how to refer to this
    -- node: @(n)@ for a derived step, or the inlined phrase for a leaf.
    visit
        :: Incompatibility p s -> [(Int, Text)] -> Int -> (Text, [(Int, Text)], Int)
    visit inc acc n = case incompCause inc of
        DerivedFrom c1 c2 ->
            let (r1, acc1, n1) = visit c1 acc n
                (r2, acc2, n2) = visit c2 acc1 n1
                line = "Because " <> r1 <> " and " <> r2 <> ", " <> summary inc
             in ("(" <> T.pack (show n2) <> ")", (n2, line) : acc2, n2 + 1)
        _ -> (leaf inc, acc, n)

    -- External facts at the leaves of the proof. We render these from the cause
    -- rather than the bare terms so each explains itself: an empty range is the
    -- range simply being unsatisfiable, not a conflict with anything else — and
    -- for a compiler-provided package, we say so rather than "no version".
    leaf c = case incompCause c of
        NoVersions p s -> case rePinned env p of
            Just v ->
                pretty p
                    <> " is provided by the compiler as "
                    <> pretty v
                    <> ", which does not satisfy "
                    <> pretty s
            Nothing -> "no version for " <> pretty p <> " " <> pretty s
        _ -> summary c

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
    -- ("assoc ==1.0.2 depends on …" vs "assoc >=1.0.2 && <1.1 depends on …"),
    -- but omit it for the root, whose synthetic version means nothing.
    dep p1 r1 p2 r2 =
        pretty p1 <> pretty r1 <> " depends on " <> pretty p2 <> " " <> pretty r2
    showTerm p (Positive r) = pretty p <> " " <> pretty r
    showTerm p (Negative r) = pretty p <> " not " <> pretty r
