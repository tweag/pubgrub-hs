-- | Incompatibilities: the solver's unit of knowledge.
module PubGrub.Incompatibility
    ( VarTerm (..)
    , Incompatibility (..)
    , IncompatCause (..)
    , Guard
    , UnbuildableReason (..)
    , anyTermFor
    , incompGet
    , request
    , isRequest
    , noInstances
    , onlyInstalled
    , unbuildable
    , fromDependency
    , declaresFlag
    , IncompatRelation (..)
    , incompRelation
    , priorCause
    , priorCauseTerms
    ) where

import           Data.List.NonEmpty             (NonEmpty)
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Distribution.Types.PackageName
import           Distribution.Types.PkgconfigDependency (PkgconfigDependency)
import           PubGrub.InstanceSet            (InstanceSet,
                                                 emptyInstanceSet)
import           PubGrub.Relation               (Relation (..), relation)
import           PubGrub.Term                   (Term (..), intersectTerm,
                                                 isTopTerm, unionTerm)
import           PubGrub.Value                  (ValueSet (..), boolSet,
                                                 bothValues, noValues)
import           PubGrub.Variable               (Flag, Var (..))
import           PubGrub.Version                (Version)

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
data VarTerm = VarTerm
    { termVar :: Var
    , termSet :: Term ValueSet
    }

-- | The always-true term ⊤ for a variable: \"absent, or any value\". The
-- identity used when a variable is missing from an incompatibility's map. It
-- takes the variable because the empty set has a kind: a term about a flag is
-- combined with sets of Booleans, a term about a package with sets of instances.
anyTermFor :: Var -> Term ValueSet
anyTermFor (PackageVar _) = Negative (PackageSet emptyInstanceSet)
anyTermFor (FlagVar _ _)  = Negative (FlagSet noValues)

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
-- ('IncompatCause'), which is what lets a failed resolution be rendered as a
-- numbered proof ("PubGrub.Report"). The cause is provenance only: no solver
-- decision consults it, and it never affects what an incompatibility means.
data Incompatibility = Incompatibility
    { incompTerms :: Map Var (Term ValueSet)
    , incompCause :: IncompatCause
    }

-- | The flags a dependency holds under, each with the value it needs. Empty for
-- an unconditional dependency. Every flag is one of the depender's own.
type Guard = Map Flag Bool

data IncompatCause
    = CauseRequest PackageName InstanceSet                        -- request
    | CauseNoInstances Var ValueSet                               -- noInstances
    | CauseOnlyInstalled PackageName [Version]                    -- onlyInstalled
    | CauseUnbuildable PackageName InstanceSet (NonEmpty UnbuildableReason)  -- unbuildable
    | CauseDependency PackageName InstanceSet Guard (PackageName, InstanceSet)  -- fromDependency
    | CauseDeclaresFlag PackageName InstanceSet Flag              -- declaresFlag
    | CauseDerivedFrom Incompatibility Incompatibility            -- priorCause

-- | Why a release's library cannot be built on this machine: one entry per
-- thing that rules it out, read off the library's @BuildInfo@ at the flag
-- assignment in force. A release can carry several — two missing @pkg-config@
-- modules, say — and the proof names each, which is why the cause holds a
-- non-empty list rather than one reason.
--
-- The @pkg-config@ dependency is kept whole, name and range, so the proof can
-- spell it as the @.cabal@ did.
data UnbuildableReason
    = NotBuildable
      -- ^ the library declares @buildable: False@
    | MissingPkgConfig PkgconfigDependency
      -- ^ a @pkgconfig-depends@ this machine's @pkg-config@ cannot satisfy
    deriving (Eq, Ord, Show)

-- | The term an incompatibility states about @v@, if any.
incompGet :: Var -> Incompatibility -> Maybe (Term ValueSet)
incompGet v (Incompatibility m _) = Map.lookup v m

-- Constructors ---------------------------------------------------------------

-- | A seed: what the solve is asked for. It is impossible for @p@ to be
-- /outside/ @s@, which forces @p@ into the plan at an instance in @s@. One per
-- target. Seeds take the place of the algorithm's opening incompatibility on a
-- synthetic root package, with the request stated directly, so no package stands
-- in front of the targets to be printed, planned and filtered out again.
--
-- A seed is a unit clause, so propagation turns it into a derivation at decision
-- level 0 before anything is decided; "PubGrub.Solver" recognises a conflict that
-- rests on those derivations alone as the end of the search.
request :: PackageName -> InstanceSet -> Incompatibility
request p s = Incompatibility (Map.singleton (PackageVar p) (Negative (PackageSet s))) (CauseRequest p s)

-- | Is this a seed?
isRequest :: Incompatibility -> Bool
isRequest i = case incompCause i of
    CauseRequest{} -> True
    _              -> False

-- | The provider has nothing to offer in this set of values of the variable,
-- so none of it can be selected.
noInstances :: Var -> ValueSet -> Incompatibility
noInstances v s = Incompatibility (Map.singleton v (Positive s)) (CauseNoInstances v s)

-- | A package that may not be built from source at all: only an already-installed
-- unit of it can be selected. The term is /every source instance/ — any version
-- — so the clause forbids the whole source side of the package at once.
--
-- This is a fact about the world rather than about a range, which is why it has its
-- own cause. Rendered as 'CauseNoInstances' it would read \"no version for base in
-- >=0\", which is both false-sounding and unhelpful: there are plenty of versions of
-- @base@, and the reason none may be used is that the compiler provides it.
--
-- The installed versions ride along for the proof's sake only. The clause's term
-- says nothing about them — it bans the source side, and the installed units are
-- whatever the assignment's other clauses admit — but a reader of \"@base@ cannot be
-- built from source\" still has to know which @base@ /is/ installed to see why a
-- bound on it fails. An empty list is a boot package with no installed unit at
-- all, which the proof says instead.
--
-- Which packages it applies to is the provider's decision (for cabal, the
-- non-reinstallable boot packages). The core only needs to know the shape.
onlyInstalled :: PackageName -> [Version] -> InstanceSet -> Incompatibility
onlyInstalled p installed anySource =
    Incompatibility (Map.singleton (PackageVar p) (Positive (PackageSet anySource))) (CauseOnlyInstalled p installed)

-- | Instances that cannot be built in this environment at all, and so must never
-- be selected. The provider states this /instead of/ a release's dependencies:
-- an unselectable version's dependencies are not added at all.
--
-- Like 'onlyInstalled' this is a fact about the world rather than about a range.
-- What makes it worth stating rather than silently skipping the release is the
-- report: a release that is merely absent leaves the solver to discover that its
-- range is empty, which reads as \"no version for foo in …\" when the truth is
-- that the versions exist and cannot be built here.
--
-- Adjacent unbuildable versions need not be stated together: adjacent slots
-- touch, so "PubGrub.Store" unions two of these into one contiguous clause as
-- they arrive, exactly as it does for dependency facts — when they give the same
-- reasons. Two runs ruled out for different reasons stay two facts, so that the
-- proof never attributes one release's missing module to another.
--
-- The reasons ride along for the proof's sake only, like the installed versions
-- of 'onlyInstalled': the clause's term is the ban, and the reasons are what
-- the sentence says instead of a bare \"cannot be built\".
unbuildable :: PackageName -> InstanceSet -> NonEmpty UnbuildableReason -> Incompatibility
unbuildable p s why = Incompatibility (Map.singleton (PackageVar p) (Positive (PackageSet s))) (CauseUnbuildable p s why)

-- | Dependency incompatibility: @package@ in @instances@, with each flag of
-- @guard@ at the value it names, requires @dep@ in @depSet@:
--
-- @{ package: Positive instances, f₁: Positive {b₁}, …, dep: Negative depSet }@
--
-- The guard's terms are /positive/: they are antecedents, like the depender's
-- own term, and a positive singleton over a flag is \"the flag is in play and has
-- this value\". With the depender decided and the dependee out of range, unit
-- propagation derives @Negative {b}@ for the one open flag — \"absent or the
-- other value\" — and the owner's standing 'declaresFlag' clause narrows that to
-- the other value. With the flags in place instead, it derives the dependee's
-- range. An empty guard is an unconditional dependency, the common case.
--
-- A guard is a conjunction. A disjunctive @.cabal@ condition is several of
-- these, one per disjunct, each of which implies the dependency on its own.
--
-- If @depSet@ is empty the dependency is unsatisfiable and the entry would be ⊤,
-- so it is dropped, leaving a ban on the depender under the guard.
--
-- __'Map.fromListWith', not 'Map.fromList'__, and it is load-bearing when
-- @package == dep@ — a __self-dependency__. Both entries are then about one
-- variable, and an incompatibility is a conjunction of its terms, so the entry
-- has to be their /intersection/:
-- @intersectTerm (Positive V) (Negative R) = Positive (V \\ R)@, exactly the
-- clause \"no instance of p in @V@ whose own requirement @R@ it falls outside
-- of\". 'Map.fromList' would keep the last binding instead, dropping the
-- @Positive@ depender term and turning the conditional fact into the
-- unconditional unit clause @{p: Negative R}@ — \"p must be in R\", asserted of
-- every instance of @p@ rather than of the ones in @V@.
--
-- A provider should drop a self-dependency before it gets here, so this is the
-- guard rather than the rule. Keeping it correct rather than rejecting it also
-- keeps 'PubGrub.Store.mergeInto', which rebuilds through this constructor,
-- safe by construction.
fromDependency :: PackageName -> InstanceSet -> Guard -> PackageName -> InstanceSet -> Incompatibility
fromDependency pkgName pkgSet guard depName depSet =
    Incompatibility
        ( Map.fromListWith
            intersectTerm
            ( (PackageVar pkgName, Positive (PackageSet pkgSet))
                : [(FlagVar pkgName f, Positive (FlagSet (boolSet b))) | (f, b) <- Map.toList guard]
                ++ [(PackageVar depName, Negative (PackageSet depSet)) | not (isTopTerm (Negative (PackageSet depSet)))]
            )
        )
        (CauseDependency pkgName pkgSet guard (depName, depSet))

-- | A release declares an automatic flag: @package@ in @instances@ requires the
-- flag to be in play, at either value:
--
-- @{ package: Positive instances, flag: Negative {False, True} }@
--
-- This is what makes a flag a goal — propagation derives a positive term for
-- it the moment its owner is decided, and the provider is then asked to decide
-- it, offering the declared default first. Nothing else ever derives a positive
-- term for a flag, so a flag is only ever decided while a release declaring it
-- is decided, and a learned clause that mentions it under a wider term about
-- the owner is inert for the owner's other releases.
declaresFlag :: PackageName -> InstanceSet -> Flag -> Incompatibility
declaresFlag p s f =
    Incompatibility
        ( Map.fromList
            [ (PackageVar p, Positive (PackageSet s))
            , (FlagVar p f, Negative (FlagSet bothValues))
            ]
        )
        (CauseDeclaresFlag p s f)

-- Judging against the partial solution -----------------------------------------

-- | How an incompatibility relates to the partial solution.
data IncompatRelation
    = ISatisfied
    | IContradicted Var
    | -- | all terms satisfied but one (the named variable): the unit case
      IAlmostSatisfied Var
    | IInconclusive
    deriving (Eq, Show)

-- | Judge an incompatibility against the partial solution. @lookupTerm v@ is
-- the accumulated term the partial solution holds for @v@, or 'Nothing' if
-- @v@ is unmentioned (equivalent to ⊤, and always inconclusive).
incompRelation
    :: (Var -> Maybe (Term ValueSet))
    -> Incompatibility
    -> IncompatRelation
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
    :: Incompatibility
    -- ^ current incompatibility
    -> Incompatibility
    -- ^ satisfier's cause
    -> Var
    -- ^ shared (pivot) variable
    -> Incompatibility
priorCause current@(Incompatibility cur _) satCause@(Incompatibility sat _) pivot =
    Incompatibility (priorCauseTerms pivot cur sat) (CauseDerivedFrom current satCause)

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
    :: Var
    -- ^ shared (pivot) variable
    -> Map Var (Term ValueSet)
    -- ^ terms of the current incompatibility
    -> Map Var (Term ValueSet)
    -- ^ terms of the satisfier's cause
    -> Map Var (Term ValueSet)
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
