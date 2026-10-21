-- | Reading a derivation: views of the tree a failed solve hands back, over
-- any 'Domain'.
--
-- The incompatibility a failed solve ends with carries the derivation that
-- produced it ('PubGrub.Incompatibility.Cause'): a tree whose leaves are
-- external facts and whose nodes each follow from their two children.
-- Everything here reads that shape and nothing inside a fact; what a leaf
-- /says/ is the domain's business.
--
-- The views are 'Rule's, functions that may decline, so that they compose in
-- one @do@ block in 'Maybe' with a renderer's own rules ("PubGrub.Report"): a
-- line reads a view, states a guard, and says a sentence.
module PubGrub.Derivation
    ( -- * Rules
      Rule
    , firstOf
    , symmetric
      -- * Views of a node
    , isDerived
    , derivedFrom
    , bothExternal
    , bothDerived
    , chainStep
      -- * Views of a leaf
    , asFact
    , asSeed
    , asNoValues
      -- * Walks
    , externals
    , everywhere
    , nearestRoot
    , runWhile
    , conflictSet
    ) where

import           Control.Applicative     ((<|>))
import           Control.Monad           (guard)
import           Data.Foldable           (asum)
import           Data.List               (minimumBy)
import qualified Data.Map.Strict         as Map
import           Data.Ord                (comparing)
import           Data.Set                (Set)
import qualified Data.Set                as Set
import           PubGrub.Incompatibility (Cause (..), Domain (..),
                                          Incompatibility (..))

-- | A rule reads an @a@ and either fires with a @b@ or declines.
type Rule a b = a -> Maybe b

-- | The first rule of the table that fires.
firstOf :: [Rule a b] -> Rule a b
firstOf rules x = asum [rule x | rule <- rules]

-- | A rule over a pair, tried both ways round: as given first.
symmetric :: Rule (a, a) b -> Rule (a, a) b
symmetric rule (x, y) = rule (x, y) <|> rule (y, x)

-- --------------------------------------------------------------------------
-- Views of a node
-- --------------------------------------------------------------------------

-- | Was this derived by the solver, rather than stated?
isDerived :: Incompatibility d -> Bool
isDerived c = case incompCause c of
    Derived _ _ -> True
    _           -> False

-- | The two causes of a derived step, in the order the solver joined them.
derivedFrom :: Rule (Incompatibility d) (Incompatibility d, Incompatibility d)
derivedFrom inc = case incompCause inc of
    Derived a b -> Just (a, b)
    _           -> Nothing

-- | A step whose causes are both external facts: the only kind of step that
-- opens a line of derivation.
bothExternal :: Rule (Incompatibility d) (Incompatibility d, Incompatibility d)
bothExternal inc = do
    (a, b) <- derivedFrom inc
    guard (not (isDerived a) && not (isDerived b))
    pure (a, b)

-- | A step whose causes are both derived: where the derivation branches.
bothDerived :: Rule (Incompatibility d) (Incompatibility d, Incompatibility d)
bothDerived inc = do
    (a, b) <- derivedFrom inc
    guard (isDerived a && isDerived b)
    pure (a, b)

-- | A step with one derived cause and one external fact, the derived cause
-- first: the step a linear chain is made of and the step every run walks.
chainStep :: Rule (Incompatibility d) (Incompatibility d, Incompatibility d)
chainStep inc = do
    (a, b) <- derivedFrom inc
    case (isDerived a, isDerived b) of
        (True, False) -> Just (a, b)
        (False, True) -> Just (b, a)
        _             -> Nothing

-- --------------------------------------------------------------------------
-- Views of a leaf
-- --------------------------------------------------------------------------

-- | The domain's fact at a leaf, whether it was a seed or stated by the
-- provider.
asFact :: Rule (Incompatibility d) (FactOf d)
asFact c = case incompCause c of
    Seed f -> Just f
    Fact f -> Just f
    _      -> Nothing

-- | A seed: what the solve was asked for.
asSeed :: Rule (Incompatibility d) (FactOf d)
asSeed c = case incompCause c of
    Seed f -> Just f
    _      -> Nothing

-- | A hole: a set of a variable's values the solver found nothing in.
asNoValues :: Rule (Incompatibility d) (VarOf d, SetOf d)
asNoValues c = case incompCause c of
    NoValues v s -> Just (v, s)
    _            -> Nothing

-- --------------------------------------------------------------------------
-- Walks
-- --------------------------------------------------------------------------

-- | The external facts at the leaves, in proof order.
externals :: Incompatibility d -> [Incompatibility d]
externals inc = case derivedFrom inc of
    Just (a, b) -> externals a ++ externals b
    Nothing     -> [inc]

-- | Every node of the tree the rule fires on, with its depth below the root, in
-- proof order.
everywhere :: Rule (Incompatibility d) a -> Incompatibility d -> [(Int, a)]
everywhere rule = go 0
  where
    go depth n =
        [(depth, a) | Just a <- [rule n]] ++ case derivedFrom n of
            Just (a, b) -> go (depth + 1) a ++ go (depth + 1) b
            Nothing     -> []

-- | Of some nodes with their depth, the one nearest the root; the first in proof
-- order on a tie.
nearestRoot :: [(Int, a)] -> Maybe a
nearestRoot [] = Nothing
nearestRoot cs = Just (snd (minimumBy (comparing fst) cs))

-- | Walk down the spine of chain steps while the rule fires on each step's
-- external fact. Answers with the node where the walk stopped (the input
-- itself when there was no run, and otherwise a derived node, since the walk
-- only descends into a chain step's derived cause) and what the rule read off
-- each fact, deepest first. An empty list means there was no run.
runWhile :: Rule (Incompatibility d) a -> Incompatibility d -> (Incompatibility d, [a])
runWhile rule = go []
  where
    go acc node = case chainStep node of
        Just (d, e) | Just a <- rule e -> go (a : acc) d
        _                              -> (node, acc)

-- | Every variable a failed solve's derivation mentions: the terminal
-- incompatibility's own terms, and the terms of every incompatibility it was
-- derived from, down to the external facts at the leaves.
--
-- This is the __conflict set__: the variables on the path to the conflict as
-- well as those in it. A caller that solved with some variables held at
-- earlier values (a lock file, say) reads it to decide which to release before
-- solving again. A held variable that is not in the set took no part in the
-- failure, and releasing it cannot help.
conflictSet :: Domain d => Incompatibility d -> Set (VarOf d)
conflictSet inc = Map.keysSet (incompTerms inc) <> case incompCause inc of
    Derived a b -> conflictSet a <> conflictSet b
    _           -> Set.empty
