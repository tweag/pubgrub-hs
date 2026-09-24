{-# LANGUAGE OverloadedStrings #-}

-- | The sentences a proof is made of: the standard PubGrub forms, in cabal's
-- range syntax.
--
-- The PubGrub algorithm leaves the wording to the implementation and names a
-- few special cases; these sentences follow its own examples. The sentences
-- are meant to be the same, not the same bytes: ranges print in Cabal syntax
-- (@>=1.0.0 && <2@), and a declared range prints as its author spelled it
-- (@^>=1.0.0@, see 'PubGrub.VersionSet.declaredRange').
--
-- Every function here answers a fragment with no connective in front of it and
-- no period after it, because the rules that use them put a fragment after a
-- \"Because\" of their own and the walker ends every line as a sentence. A
-- fragment must therefore never open with \"because\" or \"and\"; that is why an
-- unbuildable release \"needs pkg-config package libpq\" rather than \"cannot be
-- built because …\".
module PubGrub.Report.Wording
    ( -- * A package with its range
      named
    , bare
      -- * Facts
    , dep
    , requires
    , leaf
      -- * Conclusions
    , summary
    , summaryTerms
      -- * Lists
    , listing
    , anyOf
    ) where

import           Data.List                      (unsnoc)
import           Data.List.NonEmpty             (NonEmpty)
import qualified Data.List.NonEmpty             as NE
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Distribution.Pretty            (prettyShow)
import           Distribution.Types.PackageName (PackageName)
import           PubGrub.Incompatibility        (IncompatCause (..),
                                                 Incompatibility (..),
                                                 UnbuildableReason (..))
import           PubGrub.InstanceSet            (InstanceSet, isEveryVersion)
import           PubGrub.Pretty                 (Pretty (..))
import           PubGrub.Report.Rule            (asDependency)
import           PubGrub.Term                   (Term (..))

-- | A package with the set it is constrained to, as words. A set admitting every
-- version reads \"every version of foo\" where the sentence calls for it — as
-- the subject of \"depends on\" or \"requires\" — and the bare name where it
-- does not: \"foo is forbidden\", not \"every version of foo is forbidden\", and
-- \"depends on bar\" rather than \"depends on every version of bar\".
named :: PackageName -> InstanceSet -> Text
named p s
    | isEveryVersion s = "every version of " <> pretty p
    | otherwise        = pretty p <> " " <> pretty s

bare :: PackageName -> InstanceSet -> Text
bare p s
    | isEveryVersion s = pretty p
    | otherwise        = pretty p <> " " <> pretty s

-- | A dependency fact. The depender's range is kept so distinct derivation
-- steps stay distinct (\"assoc ==1.0.2 depends on …\" vs \"assoc >=1.0.2 && <1.1
-- depends on …\").
dep :: PackageName -> InstanceSet -> PackageName -> InstanceSet -> Text
dep p1 r1 p2 r2 = named p1 r1 <> " depends on " <> bare p2 r2

-- | A /derived/ two-term incompatibility. It says \"requires\", and keeps
-- \"depends on\" for the external fact: a dependency is declared in a @.cabal@
-- file, a requirement is what the solver worked out from one.
requires :: PackageName -> InstanceSet -> PackageName -> InstanceSet -> Text
requires p1 r1 p2 r2 = named p1 r1 <> " requires " <> bare p2 r2

-- | An external fact at a leaf of the proof. Rendered from the cause rather
-- than from the bare terms so that each explains itself: an empty range reads
-- as unsatisfiable rather than as a conflict with anything else; a
-- compiler-provided package names the version it is pinned to instead of
-- reading \"no version\", since the bound that failed is only legible against
-- that version and nothing else in the proof states it; and a release that
-- cannot be built here says so, and why, rather than looking absent.
leaf :: Incompatibility -> Text
leaf c = case incompCause c of
    CauseRequest p s -> bare p s <> " is requested"
    CauseNoInstances p s -> "no version for " <> pretty p <> " in " <> pretty s
    CauseOnlyInstalled p [] -> pretty p <> " is not installed and cannot be built from source"
    CauseOnlyInstalled p vs ->
        pretty p <> " is pinned to " <> T.intercalate " or " (map pretty vs) <> " (installed)"
    CauseUnbuildable p s why -> named p s <> " " <> reasons why
    _ -> case asDependency c of
        Just (p, s, q, r) -> dep p s q r
        Nothing           -> summary c

-- | Why a release cannot be built, as the predicate of its sentence: \"needs
-- pkg-config package libpq, which is not found\", and \"is marked buildable:
-- False\". The two are joined with \"and\" when both hold, and several modules
-- share one \"needs\".
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

-- | What an incompatibility says. A negative term is never written as
-- \"not …\": it says the package /must/ be in that set, and the sentence carries
-- the negation — \"foo requires bar >=2\", \"if foo and bar then baz <3\",
-- \"either foo <2 or bar <3\". The empty incompatibility reads \"version solving
-- failed\".
summary :: Incompatibility -> Text
summary c = summaryTerms (incompTerms c)

summaryTerms :: Map PackageName (Term InstanceSet) -> Text
summaryTerms ts = case Map.toList ts of
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

-- | \"a, b and c\"
listing :: [Text] -> Text
listing xs = case unsnoc xs of
    Just (front@(_ : _), l) -> T.intercalate ", " front <> " and " <> l
    _                       -> T.intercalate ", " xs

-- | \"a or b or c\"
anyOf :: [Text] -> Text
anyOf = T.intercalate " or "
