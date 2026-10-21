{-# LANGUAGE OverloadedStrings #-}

-- | The sentences a proof is made of: the standard PubGrub forms, in cabal's
-- range syntax.
--
-- The PubGrub algorithm leaves the wording to the implementation and names a
-- few special cases; these sentences follow its own examples. The sentences
-- are meant to be the same, not the same bytes: ranges print in Cabal syntax
-- (@>=1.0.0 && <2@), and a declared range prints as its author spelled it
-- (@^>=1.0.0@, see 'PubGrub.VersionSet.declared').
--
-- Every function here answers a fragment with no connective in front of it and
-- no period after it, because the rules that use them put a fragment after a
-- \"Because\" of their own and the walker ends every line as a sentence. A
-- fragment must therefore never open with \"because\" or \"and\"; that is why an
-- unbuildable release \"needs pkg-config package libpq\" rather than \"cannot be
-- built because …\".
module PubGrub.Cabal.Report.Wording
    ( -- * The words, as the walker takes them
      wording
      -- * A variable with its set
    , named
    , bare
      -- * A package with its range
    , namedP
    , bareP
      -- * Facts
    , dep
    , guardedDep
    , fact
    , hole
    , leaf
      -- * Conclusions
    , summary
    , summaryTerms
      -- * Re-exported from "PubGrub.Report"
    , listing
    , anyOf
    ) where

import           Data.List.NonEmpty             (NonEmpty)
import qualified Data.List.NonEmpty             as NE
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Distribution.Pretty            (prettyShow)
import           Distribution.Types.PackageName (PackageName)
import           PubGrub.Cabal                  (Cabal, CabalFact (..), Guard,
                                                 UnbuildableReason (..))
import           PubGrub.Cabal.InstanceSet      (InstanceSet, isEveryVersion)
import           PubGrub.Cabal.Value            (BoolSet (..), ValueSet (..))
import           PubGrub.Cabal.Variable         (Flag, Var (..))
import           PubGrub.Incompatibility        (Incompatibility (..))
import           PubGrub.Pretty                 (Pretty (..))
import           PubGrub.Report                 (Formatter (..), anyOf, listing,
                                                 summaryWith)
import qualified PubGrub.Report                 as Report
import           PubGrub.Term                   (Term)

-- | The cabal domain's words, with no rules and no pass: the half of a
-- 'Formatter' that this module owns. "PubGrub.Cabal.Report" adds the rest.
wording :: Formatter Cabal
wording =
    Formatter
        { sayFact = fact
        , sayNoValues = hole
        , sayTerms = summaryTerms
        , prepare = id
        , lineRules = []
        , clauseRules = []
        }

-- | A variable with the set it is constrained to, as words. A package set
-- admitting every version reads \"every version of foo\" where the sentence
-- calls for it — as the subject of \"depends on\" or \"requires\" — and the bare
-- name where it does not: \"foo is forbidden\", not \"every version of foo is
-- forbidden\", and \"depends on bar\" rather than \"depends on every version of
-- bar\". A flag reads as its owner with a sign: @foo +fast@, @foo -fast@, or
-- @foo flag fast@ when both values are in.
named :: Var -> ValueSet -> Text
named (PackageVar p) s = namedP p (vsInstances s)
named v s              = bare v s

bare :: Var -> ValueSet -> Text
bare (PackageVar p) s = bareP p (vsInstances s)
bare (FlagVar p f) s  = pretty p <> " " <> flagText f (vsFlags s)

namedP :: PackageName -> InstanceSet -> Text
namedP p s
    | isEveryVersion s = "every version of " <> pretty p
    | otherwise        = pretty p <> " " <> pretty s

bareP :: PackageName -> InstanceSet -> Text
bareP p s
    | isEveryVersion s = pretty p
    | otherwise        = pretty p <> " " <> pretty s

-- | What a set of a flag's values says: @+fast@, @-fast@, or the flag by name
-- when both values are in.
flagText :: Flag -> BoolSet -> Text
flagText f bs = case (allowsTrue bs, allowsFalse bs) of
    (True, False)  -> "+" <> pretty f
    (False, True)  -> "-" <> pretty f
    (True, True)   -> "flag " <> pretty f
    (False, False) -> "no value of " <> pretty f

-- | A guard as its flags with their required values: @+fast -tidy@.
guardText :: Guard -> Text
guardText g = T.unwords [(if b then "+" else "-") <> pretty f | (f, b) <- Map.toList g]

-- | A dependency fact. The depender's range is kept so distinct derivation
-- steps stay distinct (\"assoc ==1.0.2 depends on …\" vs \"assoc >=1.0.2 && <1.1
-- depends on …\").
dep :: PackageName -> InstanceSet -> PackageName -> InstanceSet -> Text
dep p1 r1 p2 r2 = namedP p1 r1 <> " depends on " <> bareP p2 r2

-- | A dependency fact under a flag guard: \"foo >=1 && <2 with +fast depends on
-- bar\". With an empty guard it is 'dep'.
guardedDep :: PackageName -> InstanceSet -> Guard -> PackageName -> InstanceSet -> Text
guardedDep p1 r1 g p2 r2
    | Map.null g = dep p1 r1 p2 r2
    | otherwise = namedP p1 r1 <> " with " <> guardText g <> " depends on " <> bareP p2 r2

-- | An external fact at a leaf of the proof, or what a derived node's terms
-- conclude. A fact is rendered from its cause rather than from its terms so
-- that it explains itself: an empty range reads as unsatisfiable rather than
-- as a conflict with anything else; a compiler-provided package names the
-- version it is pinned to, since the bound that failed is only legible against
-- that version and nothing else in the proof states it; and a release that
-- cannot be built here says so, and why, rather than looking absent.
leaf :: Incompatibility Cabal -> Text
leaf = Report.leaf wording

-- | What a fact says. The clause it is the cause of rides along for the one
-- case whose sentence depends on it.
fact :: CabalFact -> Incompatibility Cabal -> Text
fact f c = case f of
    CauseRequest p s -> bareP p s <> " is requested"
    CauseConstraint (PackageVar p) s -> pretty p <> " is constrained to " <> pretty (vsInstances s)
    CauseConstraint (FlagVar p f') s -> pretty p <> " is constrained to " <> flagText f' (vsFlags s)
    CauseOnlyInstalled p [] -> pretty p <> " is not installed and cannot be built from source"
    CauseOnlyInstalled p vs ->
        pretty p <> " is pinned to " <> T.intercalate " or " (map pretty vs) <> " (installed)"
    CauseUnbuildable p s g why
        | Map.null g -> namedP p s <> " " <> reasons why
        | otherwise -> namedP p s <> " with " <> guardText g <> " " <> reasons why
    CauseDeclaresFlag p s f' -> namedP p s <> " declares flag " <> pretty f'
    -- 'PubGrub.Cabal.fromDependency' drops the dependee's term when the
    -- dependency is unsatisfiable, and then there is no \"depends on\" left: the
    -- clause is a bare ban on the depender and reads as one.
    CauseDependency p s g (q, r)
        | Map.member (PackageVar q) (incompTerms c) -> guardedDep p s g q r
        | otherwise -> summary c

-- | The solver's own leaf: a range the solver found to hold no releases.
hole :: Var -> ValueSet -> Text
hole v s = "no version for " <> pretty v <> " in " <> pretty s

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

-- | What an incompatibility says: the standard sentences
-- ('PubGrub.Report.summaryWith') over cabal's names.
summary :: Incompatibility Cabal -> Text
summary c = summaryTerms (incompTerms c)

summaryTerms :: Map Var (Term ValueSet) -> Text
summaryTerms = summaryWith named bare
