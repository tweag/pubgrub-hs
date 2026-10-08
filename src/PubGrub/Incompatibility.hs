{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE TypeFamilyDependencies #-}

-- | Incompatibilities: the solver's unit of knowledge, over any 'Domain'.
--
-- The solver is written once, over a domain it knows only through the class
-- below: variables, their values, the sets a term ranges over, and the causes a
-- clause carries. The cabal domain — package names and flags, instances and
-- Booleans, the facts a @.cabal@ file states — is "PubGrub.Cabal".
module PubGrub.Incompatibility
    ( -- * The domain
      Domain (..)
    , MergeRule (..)
    , noMerging
      -- * Terms about variables
    , VarTerm (..)
    , anyTermFor
      -- * Incompatibilities
    , Incompatibility (..)
    , incompGet
    , noInstances
      -- * Judging against the partial solution
    , IncompatRelation (..)
    , incompRelation
      -- * Resolution
    , priorCause
    , priorCauseTerms
    ) where

import           Data.Kind        (Type)
import           Data.Map.Strict  (Map)
import qualified Data.Map.Strict  as Map
import           PubGrub.Relation (Relation (..), relation)
import           PubGrub.SetOps   (SetOps (..))
import           PubGrub.Term     (Term (..), intersectTerm, isTopTerm,
                                   unionTerm)

-- --------------------------------------------------------------------------
-- Domain
-- --------------------------------------------------------------------------

-- | A problem domain: everything the solver needs to know about what it is
-- solving over, and nothing it does not. The algorithm — unit propagation,
-- conflict resolution, the decision loop — reads variables only through 'Ord',
-- sets only through 'SetOps', and causes only through the three operations
-- here. What a variable, a value or a cause /is/ never reaches it.
--
-- One type fixes the variable, set and cause types together. The variable type
-- is declared injective so that a variable alone names its domain, which is what
-- lets 'emptySet' and 'singleton' take a variable and nothing else.
class (Ord (VarOf d), SetOps (SetOf d)) => Domain d where
    -- | The variables the solver assigns values to.
    type VarOf d = (v :: Type) | v -> d
    -- | The values a variable takes.
    type ValueOf d
    -- | A set of values of one variable: what a 'Term' ranges over.
    type SetOf d
    -- | Why an incompatibility holds. Provenance only: no solver decision
    -- consults it, and it never affects what an incompatibility means.
    type CauseOf d

    -- | The empty set of the variable's kind. The ⊤ term for a variable is its
    -- negation ('anyTermFor'), and it takes the variable because a domain may
    -- have sets of more than one kind.
    emptySet :: VarOf d -> SetOf d

    -- | The set holding exactly one value of the variable — the shape of a
    -- decision.
    singleton :: VarOf d -> ValueOf d -> SetOf d

    -- | The cause of a resolvent: the two incompatibilities it was derived
    -- from, in the order 'priorCause' took them.
    derivedCause :: Incompatibility d -> Incompatibility d -> CauseOf d

    -- | The cause of a ban on a set of a variable's values, which the solver
    -- states when the provider has nothing to offer inside it ('noInstances').
    noInstancesCause :: VarOf d -> SetOf d -> CauseOf d

    -- | Is this a seed — one of the incompatibilities the solve was asked for?
    -- A conflict that rests on the seeds' own derivations alone is the end of
    -- the search ("PubGrub.Solver").
    isRequest :: Incompatibility d -> Bool

    -- | Which clauses say the same thing, and the clause that says it once.
    -- "PubGrub.Store" applies it as clauses arrive. The default merges nothing.
    mergeRule :: MergeRule d
    mergeRule = noMerging

-- | A merge rule: two clauses with the same key are the same knowledge in two
-- pieces, and 'mergeWith' is the one clause that holds both. The key type is
-- the domain's own business, hence the existential; "PubGrub.Store" only ever
-- compares keys.
data MergeRule d = forall k. Ord k => MergeRule
    { mergeKey  :: Incompatibility d -> Maybe k
      -- ^ the key of a clause that may take part in a merge
    , mergeWith :: Incompatibility d -> Incompatibility d -> Incompatibility d
      -- ^ the existing clause and the arriving one, both carrying the same key,
      -- to the clause that replaces the existing one
    }

-- | No two clauses merge.
noMerging :: MergeRule d
noMerging = MergeRule{mergeKey = const (Nothing :: Maybe ()), mergeWith = const}

-- --------------------------------------------------------------------------
-- VarTerm
-- --------------------------------------------------------------------------

-- | One term about one variable — an /assignment/, the unit the partial
-- solution records. A decision is the special case where the term is
-- @Positive@ of a singleton.
--
-- Contrast 'Incompatibility', which also pairs variables with terms but makes
-- the opposite judgement: an assignment /asserts/ its term, an
-- incompatibility forbids its terms from all holding at once.
data VarTerm d = VarTerm
    { termVar :: VarOf d
    , termSet :: Term (SetOf d)
    }

-- | The always-true term ⊤ for a variable: \"absent, or any value\". The
-- identity used when a variable is missing from an incompatibility's map. It
-- takes the variable because the empty set has a kind ('emptySet').
anyTermFor :: Domain d => VarOf d -> Term (SetOf d)
anyTermFor v = Negative (emptySet v)

-- --------------------------------------------------------------------------
-- Incompatibility
-- --------------------------------------------------------------------------

-- | An incompatibility is a set of terms that cannot /all/ hold
-- simultaneously:
--
-- @
-- Incompatibility m  ≡  ¬ (⋀ over (var, term) in m: term holds of var)
-- @
--
-- Equivalently (De Morgan) it is a /disjunction/ of negated terms — the only
-- place disjunction lives in this design. Reading it as an implication gives
-- the familiar dependency shape:
--
-- @
-- ¬(app ∈ {app-1} ∧ ¬(lib ∈ {lib-2,lib-3}))    -- "if app is app-1, lib is 2 or 3"
-- @
--
-- Canonical-form corollaries: an entry that is ⊤ ('PubGrub.Term.isTopTerm')
-- says nothing and must be dropped from the map; an entry that is ⊥
-- ('PubGrub.Term.isBottomTerm') makes the conjunction unsatisfiable, so the
-- whole incompatibility is vacuously true — it should not be emitted at all.
-- An incompatibility with an /empty/ map is ¬⊤ = always violated: the shape
-- of "no solution exists".
--
-- Alongside its terms, every incompatibility records /why/ it holds
-- ('CauseOf'), which is what lets a failed resolution be rendered as a
-- numbered proof ("PubGrub.Report"). The cause is provenance only: no solver
-- decision consults it, and it never affects what an incompatibility means.
data Incompatibility d = Incompatibility
    { incompTerms :: Map (VarOf d) (Term (SetOf d))
    , incompCause :: CauseOf d
    }

-- | The term an incompatibility states about @v@, if any.
incompGet :: Domain d => VarOf d -> Incompatibility d -> Maybe (Term (SetOf d))
incompGet v (Incompatibility m _) = Map.lookup v m

-- | The provider has nothing to offer in this set of values of the variable,
-- so none of it can be selected.
noInstances :: Domain d => VarOf d -> SetOf d -> Incompatibility d
noInstances v s = Incompatibility (Map.singleton v (Positive s)) (noInstancesCause v s)

-- Judging against the partial solution -----------------------------------------

-- | How an incompatibility relates to the partial solution.
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
incompRelation lookupTerm (Incompatibility m _) = go ISatisfied (Map.toList m)
  where
    go acc [] = acc
    go acc ((v, it) : rest) =
        case lookupTerm v of
            Just term ->
                case relation term it of
                    Satisfied    -> go acc rest
                    Contradicted -> IContradicted v
                    Inconclusive -> almost v acc rest
            Nothing -> almost v acc rest
    -- absent or inconclusive term: at most one allowed for AlmostSatisfied
    almost v ISatisfied rest = go (IAlmostSatisfied v) rest
    almost _ _ _             = IInconclusive

-- | Rule of Resolution. From the current incompatibility and the cause of the
-- satisfier (sharing @pivot@), derive their resolvent: union the shared
-- variable's terms, intersect every other variable's terms, and drop the shared
-- entry if the union becomes ⊤.
priorCause
    :: Domain d
    => Incompatibility d
    -- ^ current incompatibility
    -> Incompatibility d
    -- ^ satisfier's cause
    -> VarOf d
    -- ^ shared (pivot) variable
    -> Incompatibility d
priorCause current@(Incompatibility cur _) satCause@(Incompatibility sat _) pivot =
    Incompatibility (priorCauseTerms pivot cur sat) (derivedCause current satCause)

-- | The terms a 'priorCause' arrives at, without the derivation node: the pivot's
-- two terms unioned, every other variable's intersected, and the pivot dropped
-- where the union says nothing.
--
-- Split out so that "PubGrub.Report" can replay a step rather than describe one.
-- Its widening rule collapses a run of steps into a single line, and the line is
-- only printed when this function, run once over the run's merged fact, lands
-- exactly on the terms the run arrived at — so the check is the operation itself,
-- not a second account of it.
priorCauseTerms
    :: Domain d
    => VarOf d
    -- ^ shared (pivot) variable
    -> Map (VarOf d) (Term (SetOf d))
    -- ^ terms of the current incompatibility
    -> Map (VarOf d) (Term (SetOf d))
    -- ^ terms of the satisfier's cause
    -> Map (VarOf d) (Term (SetOf d))
priorCauseTerms pivot cur sat = finalTerms
  where
    merged =
        Map.unionWith
            intersectTerm
            (Map.delete pivot cur)
            (Map.delete pivot sat)
    t1 = Map.findWithDefault (anyTermFor pivot) pivot cur
    t2 = Map.findWithDefault (anyTermFor pivot) pivot sat
    unioned = unionTerm t1 t2
    finalTerms
        | isTopTerm unioned = merged
        | otherwise = Map.insert pivot unioned merged
