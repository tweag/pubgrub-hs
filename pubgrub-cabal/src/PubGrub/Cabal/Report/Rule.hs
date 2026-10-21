-- | The little language the reporting rules are written in.
--
-- A rule is a partial function: handed a piece of the derivation tree, it
-- either fires with what it makes of that piece or declines. It is written as a
-- @do@ block in 'Maybe', in which every line does one of three things:
--
--  * __reads a view__ of the tree — 'chainStep', 'asDependency', 'runWhile' —
--    and declines if the tree is not that shape;
--  * __states a guard__ that keeps the sentence sound — 'guard' over
--    'PubGrub.SetOps.isSubsetOf', 'sameTerms' — and declines if it fails;
--  * __says the sentence__, on its last line.
--
-- A table of rules is tried in order by 'firstOf' and the first to fire wins, so
-- the order of a table is part of its meaning and is written down where the
-- table is. A rule over a pair of facts that does not care which is which is
-- wrapped in 'symmetric'.
--
-- Nothing here renders text. The views are read-only and the guards are
-- predicates, so a rule cannot change what the proof claims, only how it is
-- said; the soundness argument of each rule is made where the rule is written,
-- and this module supplies the vocabulary the argument is made in.
module PubGrub.Cabal.Report.Rule
    ( -- * Re-exported from "PubGrub.Derivation"
      Rule
    , firstOf
    , symmetric
    , isDerived
    , derivedFrom
    , bothExternal
    , bothDerived
    , chainStep
    , externals
    , everywhere
    , nearestRoot
    , runWhile
      -- * Views of an external fact
    , asRequest
    , asHole
    , asDependency
      -- * Views of terms
    , positive
    , negative
    , unions
    , sameTerm
    , sameTerms
    , mergeFacts
    ) where

import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Distribution.Types.PackageName (PackageName)
import           PubGrub.Cabal                  (CabalFact (..), Var (..))
import           PubGrub.Cabal.InstanceSet      (InstanceSet)
import           PubGrub.Cabal.Value            (ValueSet (..))
import           PubGrub.Derivation
import           PubGrub.Incompatibility        (Incompatibility (..))
import           PubGrub.SetOps                 (SetOps (union))
import           PubGrub.Term                   (Term (..))

-- --------------------------------------------------------------------------
-- Views of an external fact
-- --------------------------------------------------------------------------

-- | A seed: the package and the range it was requested in.
asRequest :: Rule (Incompatibility Var) (PackageName, InstanceSet)
asRequest c = case asSeed c of
    Just (CauseRequest p s) -> Just (p, s)
    _                       -> Nothing

-- | A hole: a range the solver found to hold no releases.
asHole :: Rule (Incompatibility Var) (PackageName, InstanceSet)
asHole c = case asNoValues c of
    Just (PackageVar p, s) -> Just (p, vsInstances s)
    _                      -> Nothing

-- | An /unconditional/ dependency fact whose dependee term survived, as
-- @(depender, its range, dependee, its range)@. A fact under a flag guard is not
-- this view: every rule built on it reads the fact as "p in S depends on q in
-- R", which a guarded fact does not say, and such facts are rendered from their
-- cause instead. 'PubGrub.Incompatibility.fromDependency' drops the dependee
-- term when the dependency is unsatisfiable, and then there is no \"depends on\"
-- left to render: the clause is a bare ban on the depender and reads as one.
asDependency :: Rule (Incompatibility Var) (PackageName, InstanceSet, PackageName, InstanceSet)
asDependency c = case asFact c of
    Just (CauseDependency p s g (q, r))
        | q /= p, Map.null g, Map.member (PackageVar q) (incompTerms c) -> Just (p, s, q, r)
    _ -> Nothing

-- --------------------------------------------------------------------------
-- Views of terms
-- --------------------------------------------------------------------------

positive :: Term a -> Maybe a
positive (Positive s) = Just s
positive _            = Nothing

negative :: Term a -> Maybe a
negative (Negative s) = Just s
negative _            = Nothing

-- | The union of every set in the list, joined from the right in the order
-- given; nothing for an empty list.
unions :: [InstanceSet] -> Maybe InstanceSet
unions []       = Nothing
unions (s : ss) = Just (go s ss)
  where
    go x []       = x
    go x (y : ys) = x `union` go y ys

-- | Two terms of the same polarity over equivalent sets. 'equivalent' is the
-- semantic test: 'InstanceSet' is non-canonical, so two terms that mean the
-- same thing rarely look the same.
sameTerm :: Term ValueSet -> Term ValueSet -> Bool
sameTerm = (==)

-- | Two term maps naming the same packages, term for term the same.
sameTerms :: Map Var (Term ValueSet) -> Map Var (Term ValueSet) -> Bool
sameTerms = (==)

-- | The facts of a run as one term map: every set unioned, polarity kept. A
-- package that is a depender in one fact and a dependee in another has no
-- merged term, and refusing to merge those is what keeps the union argument of
-- the widening rule honest — it holds for a run with /one/ depender and nothing
-- else.
mergeFacts :: [Incompatibility Var] -> Maybe (Map Var (Term ValueSet))
mergeFacts = foldr step (Just Map.empty)
  where
    step f acc = acc >>= combineWith sameWay (incompTerms f)
    sameWay (Positive x) (Positive y) = Just (Positive (x `union` y))
    sameWay (Negative x) (Negative y) = Just (Negative (x `union` y))
    sameWay _ _                       = Nothing

-- | Combine two term maps package by package, keeping the terms only one of
-- them names and failing the whole map where @f@ fails on a shared one.
combineWith
    :: (Term ValueSet -> Term ValueSet -> Maybe (Term ValueSet))
    -> Map Var (Term ValueSet)
    -> Map Var (Term ValueSet)
    -> Maybe (Map Var (Term ValueSet))
combineWith f a b = sequenceA (Map.unionWith comb (Just <$> a) (Just <$> b))
  where
    comb mx my = do
        x <- mx
        y <- my
        f x y
