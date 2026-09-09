-- | Incompatibilities: the solver's unit of knowledge.
module PubGrub.Incompatibility
    ( PackageTerm (..)
    , Incompatibility (..)
    , IncompatCause (..)
    , UnbuildableReason (..)
    , anyTerm
    , incompGet
    , notRoot
    , noInstances
    , onlyInstalled
    , unbuildable
    , fromDependency
    , IncompatRelation (..)
    , incompRelation
    , isTerminal
    , priorCause
    , priorCauseTerms
    ) where

import           Data.List.NonEmpty             (NonEmpty)
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Distribution.Types.PackageName
import           Distribution.Types.PkgconfigDependency (PkgconfigDependency)
import           PubGrub.Version                 (Version)
import           PubGrub.InstanceSet            (Instance, InstanceSet,
                                                 emptyInstanceSet,
                                                 memberInstance,
                                                 singletonInstance)
import           PubGrub.Relation               (Relation (..), relation)
import           PubGrub.Term                   (Term (..), intersectTerm,
                                                 isTopTerm, unionTerm)

-- --------------------------------------------------------------------------
-- PackageTerm
-- --------------------------------------------------------------------------

-- | One term about one package — an /assignment/, the unit the partial
-- solution records. A decision is the special case where the term is
-- @Positive@ of a singleton 'InstanceSet'.
--
-- Contrast 'Incompatibility', which also pairs packages with terms but makes
-- the opposite judgement: an assignment /asserts/ its term, an
-- incompatibility forbids its terms from all holding at once.
data PackageTerm = PackageTerm
    { termPackage   :: PackageName
    , termInstances :: Term InstanceSet
    }

-- | The always-true term ⊤ over instances: "absent, or any instance".
-- The identity used when a package is missing from an incompatibility's map.
anyTerm :: Term InstanceSet
anyTerm = Negative emptyInstanceSet

-- --------------------------------------------------------------------------
-- Incompatibility
-- --------------------------------------------------------------------------

-- | An incompatibility is a set of package terms that cannot /all/ hold
-- simultaneously:
--
-- @
-- Incompatibility m  ≡  ¬ (⋀ over (pkg, term) in m: term holds of pkg)
-- @
--
-- Equivalently (De Morgan) it is a /disjunction/ of negated terms — the only
-- place disjunction lives in this design. Reading it as an implication gives
-- the familiar dependency shape:
--
-- @
-- ¬(app ∈ {app-1} ∧ ¬(lib ∈ {lib-2,lib-3}))    -- "if app is instance app-1, lib is 2 or 3"
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
    { incompTerms :: Map PackageName (Term InstanceSet)
    , incompCause :: IncompatCause
    }

data IncompatCause
    = CauseRoot PackageName Instance                              -- notRoot
    | CauseNoInstances PackageName InstanceSet                    -- noInstances
    | CauseOnlyInstalled PackageName [Version]                    -- onlyInstalled
    | CauseUnbuildable PackageName InstanceSet (NonEmpty UnbuildableReason)  -- unbuildable
    | CauseDependency PackageName InstanceSet (PackageName, InstanceSet)  -- fromDependency
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

-- | The term an incompatibility states about @p@, if any.
incompGet :: PackageName -> Incompatibility -> Maybe (Term InstanceSet)
incompGet p (Incompatibility m _ ) = Map.lookup p m

-- Constructors ---------------------------------------------------------------

-- | The root seed: it is impossible for the root package to NOT be the
-- requested instance.
notRoot :: PackageName -> Instance -> Incompatibility
notRoot p i = Incompatibility (Map.singleton p (Negative (singletonInstance i))) (CauseRoot p i)

-- | The provider has nothing to offer in this instance set of the package, so
-- none of it can be selected.
noInstances :: PackageName -> InstanceSet -> Incompatibility
noInstances p s = Incompatibility (Map.singleton p (Positive s)) (CauseNoInstances p s)

-- | A package that may not be built from source at all: only an already-installed
-- unit of it can be selected. The term is /every source instance/ — any version,
-- no flags pinned — so the clause forbids the whole source side of the package at
-- once.
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
    Incompatibility (Map.singleton p (Positive anySource)) (CauseOnlyInstalled p installed)

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
-- Why the instances rather than the versions: the reason may be
-- assignment-dependent (@buildable: False@ under some flag assignment, a
-- @pkgconfig-depends@ guarded by a flag), so the /set/ is what carries the claim.
-- While flags are fixed at their defaults it is one unpinned cell per release
-- slot, which is every instance of that release; with flags searched it would be
-- the region where the release's buildability condition is false, and nothing
-- here would change.
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
unbuildable p s why = Incompatibility (Map.singleton p (Positive s)) (CauseUnbuildable p s why)

-- | Dependency incompatibility: @package@ in @instances@ requires @dep@ in
-- @depSet@ — encoded @{ package: Positive instances, dep: Negative depSet }@.
-- The instance sets are minted by the provider (a @.cabal@ dependency
-- constrains versions; the provider widens that to instances). If @depSet@ is
-- empty the dependency is unsatisfiable and the entry would be ⊤, so it is
-- dropped, leaving a unit ban on @package@.
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
fromDependency :: PackageName -> InstanceSet -> PackageName -> InstanceSet -> Incompatibility
fromDependency pkgName pkgSet depName depSet =
    Incompatibility
        (if isTopTerm (Negative depSet)
            then Map.singleton pkgName (Positive pkgSet)
            else
                Map.fromListWith
                    intersectTerm
                    [(pkgName, Positive pkgSet), (depName, Negative depSet)])
        (CauseDependency pkgName pkgSet (depName, depSet))

-- Judging against the partial solution -----------------------------------------

-- | How an incompatibility relates to the partial solution.
data IncompatRelation
    = ISatisfied
    | IContradicted PackageName
    | -- | all terms satisfied but one (the named package): the unit case
      IAlmostSatisfied PackageName
    | IInconclusive
    deriving (Eq, Show)

-- | Judge an incompatibility against the partial solution. @lookupTerm p@ is
-- the accumulated term the partial solution holds for @p@, or 'Nothing' if
-- @p@ is unmentioned (equivalent to 'anyTerm', and always inconclusive).
incompRelation
    :: (PackageName -> Maybe (Term InstanceSet))
    -> Incompatibility
    -> IncompatRelation
incompRelation lookupTerm (Incompatibility m _) = go ISatisfied (Map.toList m)
  where
    go acc [] = acc
    go acc ((p, it) : rest) =
        case lookupTerm p of
            Just term ->
                case relation term it of
                    Satisfied    -> go acc rest
                    Contradicted -> IContradicted p
                    Inconclusive -> almost p acc rest
            Nothing -> almost p acc rest
    -- absent or inconclusive term: at most one allowed for AlmostSatisfied
    almost p ISatisfied rest = go (IAlmostSatisfied p) rest
    almost _ _ _             = IInconclusive

-- | Does this incompatibility end the solve: is it empty, or does it forbid
-- the root instance?
isTerminal :: PackageName -> Instance -> Incompatibility -> Bool
isTerminal rootPkg rootI (Incompatibility m _) =
    case Map.toList m of
        []          -> True
        [(p, term)] -> p == rootPkg && termContains term rootI
        _           -> False
  where
    termContains (Positive s) i = i `memberInstance` s
    termContains (Negative s) i = not (i `memberInstance` s)

-- | Rule of Resolution. From the current incompatibility and the cause of the
-- satisfier (sharing @package@), derive their resolvent: union the shared
-- package's terms, intersect every other package's terms, and drop the shared
-- entry if the union becomes ⊤.
priorCause
    :: Incompatibility
    -- ^ current incompatibility
    -> Incompatibility
    -- ^ satisfier's cause
    -> PackageName
    -- ^ shared (pivot) package
    -> Incompatibility
priorCause current@(Incompatibility cur _) satCause@(Incompatibility sat _) package =
    Incompatibility (priorCauseTerms package cur sat) (CauseDerivedFrom current satCause)

-- | The terms a 'priorCause' arrives at, without the derivation node: the pivot's
-- two terms unioned, every other package's intersected, and the pivot dropped
-- where the union says nothing.
--
-- Split out so that a caller can replay a step rather than describe one: a
-- reporter that collapses a run of steps into one line can check that this
-- function, run once over the run's merged fact, lands exactly on the terms the
-- run arrived at — so the check is the operation itself, not a second account
-- of it.
priorCauseTerms
    :: PackageName
    -- ^ shared (pivot) package
    -> Map PackageName (Term InstanceSet)
    -- ^ terms of the current incompatibility
    -> Map PackageName (Term InstanceSet)
    -- ^ terms of the satisfier's cause
    -> Map PackageName (Term InstanceSet)
priorCauseTerms package cur sat = finalTerms
  where
    merged =
        Map.unionWith
            intersectTerm
            (Map.delete package cur)
            (Map.delete package sat)
    t1 = Map.findWithDefault anyTerm package cur
    t2 = Map.findWithDefault anyTerm package sat
    unioned = unionTerm t1 t2
    finalTerms
        | isTopTerm unioned = merged
        | otherwise = Map.insert package unioned merged
