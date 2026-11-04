{-# LANGUAGE TypeFamilies #-}

-- | The cabal domain: the solver instantiated for cabal packages.
--
-- A variable is a package name or one automatic flag of a package; a value is
-- an instance (a pre-installed unit or a source release) or a Boolean, and a set
-- of values is a set of instances or a set of Booleans ("PubGrub.Cabal.Value").
-- The facts are what a @.cabal@ file states, what this machine rules out and
-- what the request asks for. The provider states facts through the constructors
-- here, and the domain's 'mergeRule' rebuilds a merged clause through them, so a
-- clause's cause agrees with its terms. What the solver learns from the facts is
-- the core's own 'Cause'.
module PubGrub.Cabal
    ( -- * Variables
      Flag (..)
    , Var (..)
    , varPackage
      -- * Facts
    , CabalFact (..)
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
      -- * The answer
    , foldFlags
    ) where

import           Data.List.NonEmpty                     (NonEmpty)
import qualified Data.List.NonEmpty                     as NE
import           Data.Map.Strict                        (Map)
import qualified Data.Map.Strict                        as Map
import           Data.Set                               (Set)
import qualified Data.Set                               as Set
import qualified Data.Text                              as T
import           Distribution.Types.Flag                (FlagName,
                                                         insertFlagAssignment,
                                                         mkFlagAssignment)
import           Distribution.Types.PackageName         (PackageName)
import           Distribution.Types.PkgconfigDependency (PkgconfigDependency)
import           PubGrub.Cabal.InstanceSet              (Instance (..),
                                                         InstanceSet)
import           PubGrub.Cabal.Pretty                   ()
import           PubGrub.Cabal.Value                    (Resolved (..),
                                                         Value (..), ValueSet,
                                                         boolSet, bothValues,
                                                         flagSet, instanceSet,
                                                         singletonValue)
import           PubGrub.Cabal.Version                  (Version)
import           PubGrub.Incompatibility                (Cause (..),
                                                         Domain (..),
                                                         Incompatibility (..),
                                                         MergeRule (MergeRule),
                                                         fact, seed)
import           PubGrub.Pretty                         (Pretty (..))
import           PubGrub.SetOps                         (SetOps (..))
import           PubGrub.Term                           (Term (..))

-- --------------------------------------------------------------------------
-- Variables
-- --------------------------------------------------------------------------


-- | A flag as a @.cabal@ file declares it: a name and a default. The @manual@
-- marking is not here because a manual flag never reaches the solver: it is
-- resolved at its default when a release is flattened.
--
-- A flag variable is identified by this /declaration/, not by the release that
-- declares it. Two releases that declare @fast@ with the same default share the
-- variable, so a guarded dependency they both carry can be stated once over
-- both, as one incompatibility over adjacent versions; a release that changed
-- the default declares a different flag and gets a variable of its own. At most
-- one release of a package is ever in a plan, so the shared variable is always
-- that release's flag. Carrying the default in the identity lets the provider
-- offer it first from the variable alone, without knowing which release was
-- decided.
data Flag = Flag
    { flagName    :: FlagName
    , flagDefault :: Bool
    }
    deriving (Eq, Ord, Show)

-- | A solver variable.
data Var
    = PackageVar PackageName
    | FlagVar PackageName Flag
      -- ^ an automatic flag of the package, searched alongside its version
    deriving (Eq, Ord, Show)

-- | The package a variable belongs to: itself, or the owner of the flag.
varPackage :: Var -> PackageName
varPackage (PackageVar p) = p
varPackage (FlagVar p _)  = p

instance Pretty Flag where
    pretty = pretty . flagName

-- | @foo@, or @foo:fast@ for a flag. The set a flag term ranges over says on or
-- off; the variable alone only says which flag.
instance Pretty Var where
    pretty (PackageVar p) = pretty p
    pretty (FlagVar p f)  = pretty p <> T.pack ":" <> pretty f

-- --------------------------------------------------------------------------
-- The domain
-- --------------------------------------------------------------------------

-- | The domain of cabal packages: its variables are 'Var', a package or a
-- flag, and that type names the instantiation, as in @t'Incompatibility' Var@.
instance Domain Var where
    type ValueOf Var = Value
    type SetOf Var = ValueSet
    type FactOf Var = CabalFact

    singleton _ = singletonValue

    mergeRule = MergeRule mergeKey mergeWith

-- --------------------------------------------------------------------------
-- Facts
-- --------------------------------------------------------------------------

-- | The flags a dependency holds under, each with the value it needs. Empty for
-- an unconditional dependency. Every flag is one of the depender's own.
type Guard = Map Flag Bool

-- | What a leaf of a cabal proof says. The two seeds are stated as
-- 'Seed's, the rest as 'Fact's; the solver's own leaf — no release in a
-- range — is the core's 'NoValues', and a derived step is its 'Derived'.
data CabalFact
    = CauseRequest PackageName InstanceSet                        -- request
    | CauseOnlyInstalled PackageName [Version]                    -- onlyInstalled
    | CauseUnbuildable PackageName InstanceSet Guard (NonEmpty UnbuildableReason)  -- unbuildable
    | CauseDependency PackageName InstanceSet Guard (PackageName, InstanceSet)  -- fromDependency
    | CauseDeclaresFlag PackageName InstanceSet Flag              -- declaresFlag
    | CauseConstraint Var ValueSet                                -- constraint: the set allowed

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
-- level 0 before anything is decided; "PubGrub.Solver" recognises a conflict that
-- rests on those derivations alone as the end of the search.
request :: PackageName -> InstanceSet -> Incompatibility Var
request p s = seed (CauseRequest p s) (PackageVar p) (Negative (instanceSet s))

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
constraint :: Var -> ValueSet -> ValueSet -> Incompatibility Var
constraint v allowed forbidden = seed (CauseConstraint v allowed) v (Positive forbidden)

-- | A flag held at a value: @p:f@ is @b@ if it is in play at all. A 'constraint'
-- over the flag's own variable, as a user's @--constraint 'p +f'@ is.
flagConstraint :: PackageName -> Flag -> Bool -> Incompatibility Var
flagConstraint p f b =
    constraint (FlagVar p f) (flagSet (boolSet b)) (flagSet (boolSet (not b)))

-- | A package that may not be built from source at all: only an already-installed
-- unit of it can be selected. The term is /every source instance/ — any version
-- — so the clause forbids the whole source side of the package at once.
--
-- This is a fact about the world rather than about a range, which is why it has
-- its own cause. Rendered as 'NoValues' it would read \"no version for base in
-- >=0\", which is false-sounding and unhelpful: there are plenty of versions of
-- @base@, and the reason none may be used is that the compiler provides it.
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
onlyInstalled :: PackageName -> [Version] -> InstanceSet -> Incompatibility Var
onlyInstalled p installed anySource =
    fact (CauseOnlyInstalled p installed) [(PackageVar p, Positive (instanceSet anySource))]

-- | Instances that cannot be built in this environment, and so must never be
-- selected. This is the PubGrub algorithm's rule for a version that cannot be
-- selected: instead of its dependencies, state an incompatibility saying that
-- it, and any adjacent versions that cannot be selected either, should never be
-- selected.
--
-- @{ p: Positive instances, f₁: Positive {b₁}, … }@
--
-- The guard is the flags the verdict holds under, as for 'fromDependency': a
-- @pkgconfig-depends@ or a @buildable: False@ inside a flag-guarded block of the
-- library rules out the flag values that reach it, not the release. With the
-- release decided and one of the guard's flags open, propagation derives the
-- other value for that flag, and the release stays in the plan under it. An
-- empty guard is the unconditional case: the release is never selected, and
-- the provider states it instead of the release's dependencies.
--
-- It is stated rather than the release silently skipped because of the report:
-- a release that is merely absent leaves the solver to discover that its range
-- is empty, which reads as \"no version for foo in …\" when the versions exist
-- and cannot be built here.
--
-- The adjacent versions are not gathered here. The domain's 'mergeRule' merges two of
-- these facts about the same package under the same guard and with the same
-- reasons into one clause over the union of their instances, and when the
-- instances are adjacent release slots the union is one contiguous range. Two
-- runs ruled out for different reasons stay two facts, so the proof never
-- attributes one release's missing module to another.
--
-- The reasons are there for the proof only, like the installed versions of
-- 'onlyInstalled': the clause's terms are the ban, and the reasons are what the
-- sentence says instead of a bare \"cannot be built\".
unbuildable :: PackageName -> InstanceSet -> Guard -> NonEmpty UnbuildableReason -> Incompatibility Var
unbuildable p s guard why =
    fact
        (CauseUnbuildable p s guard why)
        ( (PackageVar p, Positive (instanceSet s))
            : [(FlagVar p f, Positive (flagSet (boolSet b))) | (f, b) <- Map.toList guard]
        )

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
-- rather than of those in @V@. The provider states a release's dependency on its
-- own package only when the range excludes that release, as a ban on it.
fromDependency :: PackageName -> InstanceSet -> Guard -> PackageName -> InstanceSet -> Incompatibility Var
fromDependency pkgName pkgSet guard depName depSet =
    fact
        (CauseDependency pkgName pkgSet guard (depName, depSet))
        ( (PackageVar pkgName, Positive (instanceSet pkgSet))
            : (PackageVar depName, Negative (instanceSet depSet))
            : [(FlagVar pkgName f, Positive (flagSet (boolSet b))) | (f, b) <- Map.toList guard]
        )

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
declaresFlag :: PackageName -> InstanceSet -> Flag -> Incompatibility Var
declaresFlag p s f =
    fact
        (CauseDeclaresFlag p s f)
        [ (PackageVar p, Positive (instanceSet s))
        , (FlagVar p f, Negative (flagSet bothValues))
        ]

-- --------------------------------------------------------------------------
-- Merging
-- --------------------------------------------------------------------------

-- | What has to match for two clauses to be merged.
--
-- Three shapes qualify. A dependency fact ('MergeDep') matches on the depender
-- package, the dependee package, the guard, and the __dependee instance set__,
-- which must be identical rather than merely overlapping. A flag declaration
-- ('MergeDeclares') matches on the package and the flag. An unbuildable fact
-- ('MergeUnbuildable') matches on the package, the guard and the __reasons__:
-- there is no dependee term to agree about, and two of them giving the same
-- reasons under the same flags are the same fact about two runs of releases;
-- merging them is how the adjacent versions of 'unbuildable' are gathered.
-- Merging two runs ruled out for different reasons would put one release's
-- missing module on the other's range in the proof. The reasons compare as a
-- set, so their order in the @.cabal@ does not keep two identical facts apart.
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
    | MergeUnbuildable PackageName Guard (Set UnbuildableReason)
    deriving (Eq, Ord)

-- | The key of a clause that may take part in a merge: a dependency fact, a
-- flag declaration or an unbuildable fact.
--
-- A clause is keyed by its /cause/ rather than by its term map, because the
-- term map may have lost what is needed: 'fromDependency' drops the dependee
-- entry when the dependency is unsatisfiable, and the unit ban that remains does
-- not say which dependee it came from. The cause still names it, so two such
-- clauses about the same dependee merge.
mergeKey :: Incompatibility Var -> Maybe MergeKey
mergeKey i = case incompCause i of
    Fact (CauseDependency p _ g (q, depSet)) -> Just (MergeDep p q g depSet)
    Fact (CauseDeclaresFlag p _ f)           -> Just (MergeDeclares p f)
    Fact (CauseUnbuildable p _ g why)        -> Just (MergeUnbuildable p g (Set.fromList (NE.toList why)))
    _                                        -> Nothing

-- | The union of two clauses carrying the same key, rebuilt through the
-- constructor of their kind so that the cause stays a leaf cause with the
-- unioned term ('PubGrub.Store' says why that matters).
mergeWith :: Incompatibility Var -> Incompatibility Var -> Incompatibility Var
mergeWith c new = case (incompCause c, incompCause new) of
    (Fact (CauseDependency p aSet g (q, depSet)), Fact (CauseDependency _ bSet _ _)) ->
        fromDependency p (aSet `union` bSet) g q depSet
    (Fact (CauseDeclaresFlag p aSet f), Fact (CauseDeclaresFlag _ bSet _)) ->
        declaresFlag p (aSet `union` bSet) f
    -- Two unit clauses banning instances of the same package: ¬(p ∈ A) and
    -- ¬(p ∈ B) is ¬(p ∈ A∪B), so the union claims nothing new. Slots touch, so
    -- for runs of adjacent unbuildable releases the union is one contiguous
    -- range, which is what references/pubgrub.md:476 asks to be stated.
    -- The key made the two reason sets equal, so the existing clause's
    -- reasons are the merged clause's.
    (Fact (CauseUnbuildable p aSet g why), Fact (CauseUnbuildable _ bSet _ _)) ->
        unbuildable p (aSet `union` bSet) g why
    -- Unreachable: equal keys imply the same kind of cause. If it were
    -- reached, the newer clause would be lost.
    _ -> c

-- --------------------------------------------------------------------------
-- The answer
-- --------------------------------------------------------------------------

-- | Fold the solver's answer into one entry per package: each decided flag
-- goes into the flag assignment of its owner, which must be a source release.
-- A flag whose owner is not in the answer, or not built from source, is dropped;
-- neither can happen, since a flag is only ever decided under its owner.
foldFlags :: Map Var Value -> Map PackageName Resolved
foldFlags decided = Map.foldrWithKey fold owners decided
  where
    owners =
        Map.fromList
            [ (p, resolved i)
            | (PackageVar p, PackageValue i) <- Map.toList decided
            ]
    resolved (UsePreInstalled pip) = Installed pip
    resolved (BuildSource v)       = Built v (mkFlagAssignment [])
    fold (FlagVar p f) (FlagValue b) = Map.adjust (withFlag f b) p
    fold _ _                         = id
    withFlag f b (Built v fa) = Built v (insertFlagAssignment (flagName f) b fa)
    withFlag _ _ r            = r
