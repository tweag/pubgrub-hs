{-# LANGUAGE TypeFamilies #-}

-- | The cabal domain: the solver instantiated for cabal packages.
--
-- A variable is a package name or one automatic flag of a package
-- ('PubGrub.Variable'); a value is an instance or a Boolean, and a set of
-- values is a set of instances or a set of Booleans ('PubGrub.Value'). The
-- causes are the facts a @.cabal@ file states, plus what the solver learns from
-- them. The constructors here are the only way a fact of this domain is built:
-- the provider states facts through them, and 'PubGrub.Store' rebuilds a merged
-- clause through them, so a clause's cause always agrees with its terms.
module PubGrub.Cabal
    ( Cabal
      -- * Causes
    , IncompatCause (..)
    , Guard
    , UnbuildableReason (..)
      -- * Constructors
    , request
    , constraint
    , flagConstraint
    , onlyInstalled
    , unbuildable
    , fromDependency
    , declaresFlag
      -- * Reading a failure
    , conflictSet
    ) where

import           Data.List.NonEmpty                     (NonEmpty)
import qualified Data.List.NonEmpty                     as NE
import           Data.Map.Strict                        (Map)
import qualified Data.Map.Strict                        as Map
import           Data.Set                               (Set)
import qualified Data.Set                               as Set
import           Distribution.Types.PackageName         (PackageName)
import           Distribution.Types.PkgconfigDependency (PkgconfigDependency)
import           PubGrub.Incompatibility                (Domain (..),
                                                         Incompatibility (..),
                                                         MergeRule (MergeRule))
import           PubGrub.InstanceSet                    (InstanceSet)
import           PubGrub.SetOps                         (SetOps (..))
import           PubGrub.Term                           (Term (..),
                                                         intersectTerm,
                                                         isTopTerm)
import           PubGrub.Value                          (Value, ValueSet, boolSet,
                                                         bothValues, flagSet,
                                                         instanceSet,
                                                         singletonValue)
import           PubGrub.Variable                       (Flag, Var (..))
import           PubGrub.Version                        (Version)

-- --------------------------------------------------------------------------
-- The domain
-- --------------------------------------------------------------------------

-- | The domain of cabal packages. A type with no values: it names the
-- instantiation, as in @'Incompatibility' Cabal@.
data Cabal

instance Domain Cabal where
    type VarOf Cabal = Var
    type ValueOf Cabal = Value
    type SetOf Cabal = ValueSet
    type CauseOf Cabal = IncompatCause

    singleton _ = singletonValue

    derivedCause = CauseDerivedFrom

    noInstancesCause = CauseNoInstances

    isRequest i = case incompCause i of
        CauseRequest{}    -> True
        CauseConstraint{} -> True
        _                 -> False

    mergeRule = MergeRule mergeKey mergeWith

-- --------------------------------------------------------------------------
-- Causes
-- --------------------------------------------------------------------------

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
    | CauseConstraint Var ValueSet                                -- constraint: the set allowed
    | CauseDerivedFrom (Incompatibility Cabal) (Incompatibility Cabal)  -- priorCause

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

-- --------------------------------------------------------------------------
-- Constructors
-- --------------------------------------------------------------------------

-- | A seed: what the solve is asked for. It is impossible for @p@ to be
-- /outside/ @s@, which forces @p@ into the plan at an instance in @s@. One per
-- target. The PubGrub algorithm opens with one incompatibility on a synthetic
-- root package; this states the request directly instead, so no package stands
-- in front of the targets to be printed, planned and filtered out again.
--
-- A seed is a unit clause, so propagation turns it into a derivation at decision
-- level 0 before anything is decided; 'PubGrub.Solver' recognises a conflict that
-- rests on those derivations alone as the end of the search.
request :: PackageName -> InstanceSet -> Incompatibility Cabal
request p s = Incompatibility (Map.singleton (PackageVar p) (Negative (instanceSet s))) (CauseRequest p s)

-- | A constraint: if @v@ is in the plan at all, it is in @allowed@. It is
-- impossible for @v@ to be in @forbidden@, the complement of @allowed@ in the
-- variable's universe:
--
-- @{ v: Positive forbidden }@
--
-- The other seed. A 'request' forces its package /into/ the plan; a constraint
-- says nothing about whether the package is chosen, only what it may be if it is
-- — @cabal build --constraint@, a @constraints:@ stanza, and a lock entry a
-- planner holds at its version. Propagation turns it into the level-0 derivation
-- @Negative forbidden@, which is \"absent, or in @allowed@\", so a package nobody
-- depends on is left alone; and because it is a seed, a conflict that rests on
-- it together with the requests is terminal ('PubGrub.Solver.solve'), and the
-- proof closes on \"@v@ is constrained to @allowed@\".
--
-- Both sets are taken because the core's set operations have no complement: a
-- package's universe holds the installed units of the compiler, which only the
-- provider side knows. 'PubGrub.Cabal.Provider.constrainTo' computes the
-- complement from a 'PubGrub.Cabal.Installed.InstalledDb'; 'flagConstraint' is
-- the two-valued case, which needs nothing.
constraint :: Var -> ValueSet -> ValueSet -> Incompatibility Cabal
constraint v allowed forbidden =
    Incompatibility (Map.singleton v (Positive forbidden)) (CauseConstraint v allowed)

-- | A flag held at a value: @p:f@ is @b@ if it is in play at all. A 'constraint'
-- over the flag's own variable, as cabal's @--constraint 'p +f'@ is.
flagConstraint :: PackageName -> Flag -> Bool -> Incompatibility Cabal
flagConstraint p f b =
    constraint (FlagVar p f) (flagSet (boolSet b)) (flagSet (boolSet (not b)))

-- | A package that may not be built from source at all: only an already-installed
-- unit of it can be selected. The term is /every source instance/ — any version
-- — so the clause forbids the whole source side of the package at once.
--
-- This is a fact about the world rather than about a range, which is why it has
-- its own cause. Rendered as 'CauseNoInstances' it would read \"no version for
-- base in >=0\", which is false-sounding and unhelpful: there are plenty of
-- versions of @base@, and the reason none may be used is that the compiler
-- provides it.
--
-- The installed versions are there for the proof only. The clause bans the
-- source side and says nothing about the installed units, but a reader of
-- \"@base@ cannot be built from source\" has to know which @base@ /is/ installed
-- to see why a bound on it fails; cabal's message names it too
-- (@base-4.21.0.0\/installed-5b43@). An empty list is a boot package with no
-- installed unit at all, and the proof says that instead.
--
-- The provider states it for the non-reinstallable boot packages
-- ('PubGrub.Cabal.Installed.nonReinstallablePackages'); the core only needs the
-- shape.
onlyInstalled :: PackageName -> [Version] -> InstanceSet -> Incompatibility Cabal
onlyInstalled p installed anySource =
    Incompatibility (Map.singleton (PackageVar p) (Positive (instanceSet anySource))) (CauseOnlyInstalled p installed)

-- | Instances that cannot be built in this environment, and so must never be
-- selected. This is the PubGrub algorithm's rule for a version that cannot be
-- selected: instead of its dependencies, state an incompatibility saying that
-- it, and any adjacent versions that cannot be selected either, should never be
-- selected.
--
-- It is stated rather than the release silently skipped because of the report:
-- a release that is merely absent leaves the solver to discover that its range
-- is empty, which reads as \"no version for foo in …\" when the versions exist
-- and cannot be built here.
--
-- The adjacent versions are not gathered here. 'PubGrub.Store' merges two of
-- these facts about the same package and with the same reasons into one clause
-- over the union of their instances, and when the instances are adjacent
-- release slots the union is one contiguous range. Two runs ruled out for
-- different reasons stay two facts, so the proof never attributes one release's
-- missing module to another.
--
-- The reasons are there for the proof only, like the installed versions of
-- 'onlyInstalled': the clause's term is the ban, and the reasons are what the
-- sentence says instead of a bare \"cannot be built\".
unbuildable :: PackageName -> InstanceSet -> NonEmpty UnbuildableReason -> Incompatibility Cabal
unbuildable p s why = Incompatibility (Map.singleton (PackageVar p) (Positive (instanceSet s))) (CauseUnbuildable p s why)

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
-- If @depSet@ is empty the dependency is unsatisfiable and its term is always
-- true, so it is left out, leaving a ban on the depender under the guard.
--
-- When @package == dep@, a __self-dependency__, both terms are about one
-- variable, and since an incompatibility is a conjunction of its terms they
-- must be /intersected/, which is why the map is built with 'Map.fromListWith'
-- and not 'Map.fromList': @intersectTerm (Positive V) (Negative R) =
-- Positive (V \\ R)@, exactly \"no instance of p in @V@ falls outside its own
-- requirement @R@\". Keeping only one of the two terms would be wrong:
-- @{p: Negative R}@ alone asserts \"p must be in R\" of every instance of @p@
-- rather than of those in @V@. The provider drops a release's dependency on its
-- own package before it gets here, as cabal does, so this case is the safety
-- net rather than the rule.
fromDependency :: PackageName -> InstanceSet -> Guard -> PackageName -> InstanceSet -> Incompatibility Cabal
fromDependency pkgName pkgSet guard depName depSet =
    Incompatibility
        ( Map.fromListWith
            intersectTerm
            ( (PackageVar pkgName, Positive (instanceSet pkgSet))
                : [(FlagVar pkgName f, Positive (flagSet (boolSet b))) | (f, b) <- Map.toList guard]
                ++ [(PackageVar depName, Negative (instanceSet depSet)) | not (isTopTerm (Negative (instanceSet depSet)))]
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
declaresFlag :: PackageName -> InstanceSet -> Flag -> Incompatibility Cabal
declaresFlag p s f =
    Incompatibility
        ( Map.fromList
            [ (PackageVar p, Positive (instanceSet s))
            , (FlagVar p f, Negative (flagSet bothValues))
            ]
        )
        (CauseDeclaresFlag p s f)

-- --------------------------------------------------------------------------
-- Merging
-- --------------------------------------------------------------------------

-- | What has to match for two clauses to be merged.
--
-- Three shapes qualify. A dependency fact ('MergeDep') matches on the depender
-- package, the dependee package, the guard, and the __dependee instance set__,
-- which must be identical rather than merely overlapping. A flag declaration
-- ('MergeDeclares') matches on the package and the flag. An unbuildable fact
-- ('MergeUnbuildable') matches on the package and the __reasons__: it is a unit
-- clause, so there is no second term to agree about, and two of them giving the
-- same reasons are the same fact about two runs of releases; merging them is how
-- the adjacent versions of 'unbuildable' are gathered. Merging two runs ruled
-- out for different reasons would put one release's missing module on the
-- other's range in the proof. The reasons compare as a set, so their order in
-- the @.cabal@ does not keep two identical facts apart.
--
-- The dependee set is compared with 'Eq', which 'InstanceSet' has lawfully:
-- both of its halves are canonical. The depender term is in no key: it is what
-- the merge grows.
data MergeKey
    = MergeDep PackageName PackageName Guard InstanceSet
      -- ^ a dependency fact merges only with one under the /same/ guard, so
      -- the guard's terms are identical on both sides and the union argument
      -- in 'PubGrub.Store' holds term for term
    | MergeDeclares PackageName Flag
      -- ^ two releases declaring the same flag: one clause over both
    | MergeUnbuildable PackageName (Set UnbuildableReason)
    deriving (Eq, Ord)

-- | The key of a clause that may take part in a merge: a dependency fact, a
-- flag declaration or an unbuildable fact.
--
-- A clause is keyed by its /cause/ rather than by its term map, because the
-- term map may have lost what is needed: 'fromDependency' drops the dependee
-- entry when the dependency is unsatisfiable, and the unit ban that remains does
-- not say which dependee it came from. The cause still names it, so two such
-- clauses about the same dependee merge.
mergeKey :: Incompatibility Cabal -> Maybe MergeKey
mergeKey i = case incompCause i of
    CauseDependency p _ g (q, depSet) -> Just (MergeDep p q g depSet)
    CauseDeclaresFlag p _ f           -> Just (MergeDeclares p f)
    CauseUnbuildable p _ why          -> Just (MergeUnbuildable p (Set.fromList (NE.toList why)))
    _                                 -> Nothing

-- | The union of two clauses carrying the same key, rebuilt through the
-- constructor of their kind so that the cause stays a leaf cause with the
-- unioned term ('PubGrub.Store' says why that matters).
mergeWith :: Incompatibility Cabal -> Incompatibility Cabal -> Incompatibility Cabal
mergeWith c new = case (incompCause c, incompCause new) of
    (CauseDependency p aSet g (q, depSet), CauseDependency _ bSet _ _) ->
        fromDependency p (aSet `union` bSet) g q depSet
    (CauseDeclaresFlag p aSet f, CauseDeclaresFlag _ bSet _) ->
        declaresFlag p (aSet `union` bSet) f
    -- Two unit clauses banning instances of the same package: ¬(p ∈ A) and
    -- ¬(p ∈ B) is ¬(p ∈ A∪B), so the union claims nothing new. Slots touch, so
    -- for runs of adjacent unbuildable releases the union is one contiguous
    -- range, which is what references/pubgrub.md:476 asks to be stated.
    -- The key made the two reason sets equal, so the existing clause's
    -- reasons are the merged clause's.
    (CauseUnbuildable p aSet why, CauseUnbuildable _ bSet _) ->
        unbuildable p (aSet `union` bSet) why
    -- Unreachable: equal keys imply the same kind of cause. If it were
    -- reached, the newer clause would be lost.
    _ -> c

-- --------------------------------------------------------------------------
-- Reading a failure
-- --------------------------------------------------------------------------

-- | Every variable a failed solve's derivation mentions: the terminal
-- incompatibility's own terms, and the terms of every incompatibility it was
-- derived from, down to the external facts at the leaves.
--
-- This is the __conflict set__ in cabal's sense — the packages on the path to the
-- conflict as well as those in it — and it is what a planner holding a lock
-- reads to decide which held packages to release before solving again. A held
-- package that is not in the set took no part in the failure, and releasing it
-- cannot help.
conflictSet :: Incompatibility Cabal -> Set Var
conflictSet inc = Map.keysSet (incompTerms inc) <> case incompCause inc of
    CauseDerivedFrom a b -> conflictSet a <> conflictSet b
    _                    -> Set.empty
