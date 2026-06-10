{-# LANGUAGE DerivingStrategies     #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE NamedFieldPuns         #-}

module PubGrub.Solver
  ( -- * Provider
    DependencyProvider (..)
    -- * Partial solution
  , Assignment (..)
  , assignmentTerm
  , PartialSolution (..)
  , emptyPS
  , addDecision
  , addDerivation
  , backtrack
  , termIntersectionForPackage
  , relation
  , extractSolution
  , undecidedPositive
  ) where

import           Data.List            (foldl')
import           Data.Map.Strict      (Map)
import qualified Data.Map.Strict      as Map
import           Data.Maybe           (mapMaybe)
import           Distribution.Version (Version)

import           PubGrub.Types
import           PubGrub.VersionSet   (VersionSet)
import qualified PubGrub.VersionSet   as VS

-- | The oracle: pick a version in a range and report a version's dependencies.
class Package p => DependencyProvider dp p | dp -> p where
  chooseVersion   :: dp -> p -> VersionSet -> Maybe Version
  getDependencies :: dp -> p -> Version -> Map p VersionSet

-- | A single entry in the partial solution.
data Assignment p
  = Decision
      { aIndex   :: !Int
      , aLevel   :: !Int
      , aPackage :: p
      , aVersion :: Version
      }
  | Derivation
      { aIndex   :: !Int
      , aLevel   :: !Int
      , aPackage :: p
      , aTerm    :: Term
      , aCause   :: Incompatibility p
      }
  deriving stock (Show)

-- | The term contributed by an assignment.
assignmentTerm :: Assignment p -> Term
assignmentTerm Decision{aVersion} = exactTerm aVersion
assignmentTerm Derivation{aTerm}  = aTerm

-- | Assignments are stored newest-first; @psLevel@ is the current decision
-- level; @psNextIndex@ is a monotone counter giving chronological order.
data PartialSolution p = PartialSolution
  { psAssignments :: [Assignment p]
  , psLevel       :: !Int
  , psNextIndex   :: !Int
  }
  deriving stock (Show)

emptyPS :: PartialSolution p
emptyPS = PartialSolution { psAssignments = [], psLevel = 0, psNextIndex = 0 }

-- | Record a decision (a guess); increments the decision level.
addDecision :: p -> Version -> PartialSolution p -> PartialSolution p
addDecision p v ps@PartialSolution{psAssignments, psLevel, psNextIndex} =
  ps { psAssignments = Decision psNextIndex (psLevel + 1) p v : psAssignments
     , psLevel = psLevel + 1
     , psNextIndex = psNextIndex + 1
     }

-- | Record a derivation: the negation of @cause@'s term for @p@, at the
-- current level.
addDerivation :: Ord p => p -> Incompatibility p -> PartialSolution p -> PartialSolution p
addDerivation p cause ps@PartialSolution{psAssignments, psLevel, psNextIndex} =
  let term = maybe anyTerm negateTerm (incompGet p cause)
  in ps { psAssignments = Derivation psNextIndex psLevel p term cause : psAssignments
        , psNextIndex = psNextIndex + 1
        }

-- | Backtrack: drop every assignment strictly above the target level.
backtrack :: Int -> PartialSolution p -> PartialSolution p
backtrack level ps@PartialSolution{psAssignments} =
  ps { psAssignments = filter ((<= level) . aLevel) psAssignments
     , psLevel = level
     }

-- | Intersection of all terms recorded for a package (Nothing if absent).
termIntersectionForPackage :: Ord p => PartialSolution p -> p -> Maybe Term
termIntersectionForPackage PartialSolution{psAssignments} p =
  case [ assignmentTerm a | a <- psAssignments, aPackage a == p ] of
    []       -> Nothing
    (t : ts) -> Just (foldl' intersectTerms t ts)

-- | Relation of the whole partial solution to an incompatibility.
relation :: Ord p => PartialSolution p -> Incompatibility p -> IncompatRelation p
relation ps = incompRelation (termIntersectionForPackage ps)

-- | The decisions, as a solution map.
extractSolution :: Ord p => PartialSolution p -> Map p Version
extractSolution PartialSolution{psAssignments} =
  Map.fromList [ (aPackage a, aVersion a) | a@Decision{} <- psAssignments ]

-- | Packages that have a positive accumulated term but no decision yet,
-- with that positive range. Chronological (oldest first) for determinism.
undecidedPositive :: Ord p => PartialSolution p -> [(p, VersionSet)]
undecidedPositive ps@PartialSolution{psAssignments} =
  let decided = [ aPackage a | a@Decision{} <- psAssignments ]
      pkgs = uniqueOldestFirst [ aPackage a | a <- reverse psAssignments ]
  in mapMaybe positive (filter (`notElem` decided) pkgs)
  where
    positive p = case termIntersectionForPackage ps p of
      Just (Positive r) -> Just (p, r)
      _                 -> Nothing
    uniqueOldestFirst = go []
      where go seen [] = reverse seen
            go seen (x:xs) | x `elem` seen = go seen xs
                           | otherwise     = go (x:seen) xs
