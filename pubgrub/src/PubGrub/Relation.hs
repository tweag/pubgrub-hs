module PubGrub.Relation
    ( Relation (..)
    , relation
    , IncompatRelation (..)
    , incompRelation
    ) where

import qualified Data.Map.Strict         as Map
import           PubGrub.Incompatibility (Domain (..), Incompatibility (..))
import           PubGrub.SetOps          (SetOps (..))
import           PubGrub.Term            (Term (..))


-- | How a term stands relative to a reference term (both about the same
-- package). This is the primitive unit propagation reads off the partial
-- solution.
data Relation
    = -- | @subject ⊆ reference@: the reference already holds.
      Satisfied
    | -- | @subject ∩ reference = ∅@: they cannot both hold.
      Contradicted
    | -- | neither — the reference is still open.
      Inconclusive
    deriving (Eq, Show)

-- | Relation of @subject@ (typically what the partial solution has derived so
-- far for a package) to @reference@ (a term from an incompatibility). Both
-- tests are emptiness tests, so no equality on payloads is needed — and no
-- reliance on canonical representations either.
--
-- The examples use small @'Data.Set.Set' Int@ payloads:
--
-- >>> import PubGrub.Term
-- >>> import qualified Data.Set as Set
-- >>> relation (Positive (Set.fromList [3])) (Positive (Set.fromList [1..9]))
-- Satisfied
--
-- >>> relation (Positive (Set.fromList [3])) (Positive (Set.fromList [5..9]))
-- Contradicted
--
-- >>> relation (Positive (Set.fromList [1..9])) (Positive (Set.fromList [3]))
-- Inconclusive
--
-- Against a negative reference — "not in {5..9}" — an exact subject either
-- avoids the set or lands in it:
--
-- >>> relation (Positive (Set.fromList [3])) (Negative (Set.fromList [5..9]))
-- Satisfied
--
-- >>> relation (Positive (Set.fromList [6])) (Negative (Set.fromList [5..9]))
-- Contradicted
--
-- A negative subject is never satisfied by a positive reference — the /absent/
-- state always escapes it:
--
-- >>> relation (Negative (Set.fromList [5,6])) (Positive (Set.fromList [1..4]))
-- Inconclusive
relation :: SetOps a => Term a -> Term a -> Relation
relation subject reference
    | subject `isSubsetOf` reference = Satisfied
    | subject `isDisjoint` reference = Contradicted
    | otherwise = Inconclusive

-- --------------------------------------------------------------------------
-- Judging a whole incompatibility
-- --------------------------------------------------------------------------

-- | Relation of a partial solution (seen as a term lookup) to a whole
-- incompatibility.
data IncompatRelation v
    = ISatisfied
    | IContradicted v
    | -- | all terms satisfied but one (the named variable): the unit case
      IAlmostSatisfied v
    | IInconclusive
    deriving (Eq, Show)

-- | Judge an incompatibility against the partial solution. @lookupTerm v@ is
-- the accumulated term the partial solution holds for @v@, or 'Nothing' if
-- @v@ is unmentioned (equivalent to ⊤, and always inconclusive).
incompRelation
    :: Domain d
    => (VarOf d -> Maybe (Term (SetOf d)))
    -> Incompatibility d
    -> IncompatRelation (VarOf d)
incompRelation lookupTerm (Incompatibility m _) = Map.foldlWithKey' step ISatisfied m
  where
    -- A strict fold over the map rather than a walk over 'Map.toList': this runs
    -- for every clause on every visit, and the list cost a tenth of a large
    -- solve's allocation. A clause has a handful of terms, so once the answer is
    -- final the remaining terms are skipped by the first two equations rather
    -- than by stopping. Terms are judged in key order, which decides the
    -- variable a contradiction or an open term is reported on.
    step acc@(IContradicted _) _ _ = acc
    step IInconclusive _ _ = IInconclusive
    step acc v it =
        case lookupTerm v of
            Just term ->
                case relation term it of
                    Satisfied    -> acc
                    Contradicted -> IContradicted v
                    Inconclusive -> almost v acc
            Nothing -> almost v acc
    -- absent or inconclusive term: at most one allowed for AlmostSatisfied
    almost v ISatisfied = IAlmostSatisfied v
    almost _ _          = IInconclusive
