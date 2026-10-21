-- | The partial solution: every assignment the search has made, indexed by
-- variable so that each of the algorithm's questions about one variable is a
-- lookup rather than a scan.
module PubGrub.PartialSolution
    ( Assignment (..)
    , AssignmentKind (..)
    , assignmentTerm
    , decidedValue
    , VarAssignments (..)
    , PartialSolution (..)
    , emptyPS
    , addDecision
    , addDerivation
    , backtrack
    , termIntersectionFor
    , psRelation
    , extractSolution
    , undecidedPositive
    , varHistory
    ) where

import           Control.Applicative     ((<|>))
import           Data.Foldable           (Foldable (..))
import           Data.List               (sortOn)
import           Data.Map.Strict         (Map)
import qualified Data.Map.Strict         as Map
import           Data.Maybe              (mapMaybe)
import           Data.Sequence           (Seq)
import qualified Data.Sequence           as Seq
import           PubGrub.Incompatibility (Domain (..), Incompatibility (..),
                                          incompGet)
import           PubGrub.Relation        (IncompatRelation, incompRelation)
import           PubGrub.Term            (Term (..), anyTerm, intersectTerm,
                                          negateTerm)

-- --------------------------------------------------------------------------
-- Partial solution
-- --------------------------------------------------------------------------

-- | A single entry in the partial solution: one variable, at one decision
-- level, with the reason it is there.
data Assignment d = Assignment
    { aIndex :: !Int
    , aLevel :: !Int
    , aVar   :: VarOf d
    , aKind  :: AssignmentKind d
    }

-- | Why an assignment is in the partial solution, and what it asserts: a
-- decision (a freely chosen singleton instance) or a derivation (a term forced
-- by unit propagation, with the incompatibility that forced it).
--
-- The two shapes are a sum /inside/ the record rather than two constructors of
-- it because they carry different payloads: sharing @aIndex@, @aLevel@ and
-- @aVar@ across two constructors is what would make the payload fields
-- partial selectors, and a partial selector is a crash waiting for the wrong
-- constructor.
data AssignmentKind d
    = Decision (ValueOf d)
    | Derivation (Term (SetOf d)) (Incompatibility d)

-- | The term contributed by an assignment; for a decision, @Positive@ of the
-- singleton.
assignmentTerm :: Domain d => Assignment d -> Term (SetOf d)
assignmentTerm a = case aKind a of
    Decision i     -> Positive (singleton (aVar a) i)
    Derivation t _ -> t

-- | The value a decision decides; 'Nothing' for a derivation.
decidedValue :: Assignment d -> Maybe (ValueOf d)
decidedValue a = case aKind a of
    Decision i   -> Just i
    Derivation{} -> Nothing

-- | Everything recorded about one variable: its own assignments oldest-first,
-- the intersection of their terms, and the value it was decided to be if it
-- has been decided.
--
-- @vaTerm@ is a cache of @foldl1 intersectTerm (assignmentTerm <$> vaHistory)@
-- and @vaDecision@ a cache of the (at most one) decision in @vaHistory@;
-- keeping them is what lets propagation ask about a variable without scanning
-- the partial solution. Invariant: a record exists only for a variable with a
-- non-empty history.
data VarAssignments d = VarAssignments
    { vaHistory  :: Seq (Assignment d)
    , vaTerm     :: Term (SetOf d)
    , vaDecision :: Maybe (ValueOf d)
    }

-- | Assignments are indexed by variable, and within a variable stored
-- oldest-first (chronological), so the satisfier search reads them in order
-- without reversing; @psLevel@ is the current decision level; @psNextIndex@ is
-- a monotone counter giving chronological order /across/ variables.
data PartialSolution d = PartialSolution
    { psVariables :: Map (VarOf d) (VarAssignments d)
    , psLevel     :: !Int
    , psNextIndex :: !Int
    }

emptyPS :: PartialSolution d
emptyPS = PartialSolution{psVariables = Map.empty, psLevel = 0, psNextIndex = 0}

-- | Add one assignment to a variable's record, creating the record if this is
-- the variable's first assignment. The caches move with it: the term folds in
-- by intersection, the decision is remembered.
extendVar :: Domain d => Assignment d -> Maybe (VarAssignments d) -> VarAssignments d
extendVar a Nothing =
    VarAssignments
        { vaHistory = Seq.singleton a
        , vaTerm = assignmentTerm a
        , vaDecision = decidedValue a
        }
extendVar a (Just pa) =
    pa
        { vaHistory = vaHistory pa Seq.|> a
        , vaTerm = intersectTerm (vaTerm pa) (assignmentTerm a)
        , vaDecision = decidedValue a <|> vaDecision pa
        }

-- | Rebuild a record from a history, recomputing both caches. 'Nothing' for an
-- empty history, which has no record.
fromHistory :: Domain d => Seq (Assignment d) -> Maybe (VarAssignments d)
fromHistory = foldl' (\acc a -> Just (extendVar a acc)) Nothing

-- | File an assignment under its variable and consume its index.
recordAssignment :: Domain d => Assignment d -> PartialSolution d -> PartialSolution d
recordAssignment a ps@PartialSolution{psVariables, psNextIndex} =
    ps
        { psVariables = Map.alter (Just . extendVar a) (aVar a) psVariables
        , psNextIndex = psNextIndex + 1
        }

-- | Record a decision (a guess); increments the decision level.
addDecision :: Domain d => VarOf d -> ValueOf d -> PartialSolution d -> PartialSolution d
addDecision p i ps@PartialSolution{psLevel, psNextIndex} =
    recordAssignment
        (Assignment psNextIndex (psLevel + 1) p (Decision i))
        ps{psLevel = psLevel + 1}

-- | Record a derivation: the negation of @cause@'s term for @p@, at the
-- current level.
addDerivation :: Domain d => VarOf d -> Incompatibility d -> PartialSolution d -> PartialSolution d
addDerivation p cause ps@PartialSolution{psLevel, psNextIndex} =
    let term = maybe anyTerm negateTerm (incompGet p cause)
     in recordAssignment (Assignment psNextIndex psLevel p (Derivation term cause)) ps

-- | Backtrack: drop every assignment strictly above the target level.
--
-- Levels are non-decreasing along a history (a derivation takes the current
-- level, a decision the next, and backtracking only lowers it), so what is
-- dropped is always a suffix — which is why this splits the history from the
-- right instead of filtering it: a variable that drops nothing keeps its history
-- as it stands, rather than paying to rebuild an identical one.
--
-- A variable that does lose assignments must have both its caches rebuilt from
-- the survivors — @intersectTerm@ cannot be undone, so the accumulated term is
-- recomputed, and a dropped decision must stop being remembered. A variable that
-- loses all of them loses its record.
backtrack :: Domain d => Int -> PartialSolution d -> PartialSolution d
backtrack level ps@PartialSolution{psVariables} =
    ps
        { psVariables = Map.mapMaybe prune psVariables
        , psLevel = level
        }
  where
    prune pa = case Seq.spanr ((> level) . aLevel) (vaHistory pa) of
        (dropped, kept)
            | Seq.null dropped -> Just pa
            | otherwise -> fromHistory kept

-- | Intersection of all terms recorded for a variable ('Nothing' if the
-- variable is unmentioned, which judges as 'anyTerm' = ⊤).
termIntersectionFor :: Domain d => PartialSolution d -> VarOf d -> Maybe (Term (SetOf d))
termIntersectionFor PartialSolution{psVariables} p =
    vaTerm <$> Map.lookup p psVariables

-- | Relation of the whole partial solution to an incompatibility.
psRelation :: Domain d => PartialSolution d -> Incompatibility d -> IncompatRelation (VarOf d)
psRelation ps = incompRelation (termIntersectionFor ps)

-- | The decisions, as a solution map.
extractSolution :: PartialSolution d -> Map (VarOf d) (ValueOf d)
extractSolution PartialSolution{psVariables} = Map.mapMaybe vaDecision psVariables

-- | Variables that have a positive accumulated term but no decision yet, with
-- that positive set. Ordered by first mention (oldest first) for
-- determinism.
undecidedPositive :: PartialSolution d -> [(VarOf d, SetOf d)]
undecidedPositive PartialSolution{psVariables} =
    map snd (sortOn fst (mapMaybe candidate (Map.toList psVariables)))
  where
    candidate (p, pa) = case (vaDecision pa, vaTerm pa) of
        (Nothing, Positive r) -> Just (firstIndex pa, (p, r))
        _                     -> Nothing
    -- The variable's first mention, which is what the order is keyed on. A
    -- record always has a non-empty history, so the fallback is unreachable.
    firstIndex pa = maybe maxBound aIndex (Seq.lookup 0 (vaHistory pa))

-- | All assignments for a variable, oldest first. The satisfier search walks
-- this list.
varHistory :: Domain d => PartialSolution d -> VarOf d -> [Assignment d]
varHistory PartialSolution{psVariables} p =
    maybe [] (toList . vaHistory) (Map.lookup p psVariables)
