-- | Incompatibilities: the solver's unit of knowledge.
module PubGrub.Incompatibility
    ( PackageTerm (..)
    , Incompatibility (..)
    , IncompatCause (..)
    , anyTerm
    , incompGet
    , notRoot
    , noInstances
    , onlyInstalled
    , fromDependency
    , IncompatRelation (..)
    , incompRelation
    , isTerminal
    , priorCause
    ) where

import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Distribution.Types.PackageName
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
    | CauseOnlyInstalled PackageName                              -- onlyInstalled
    | CauseDependency PackageName InstanceSet (PackageName, InstanceSet)  -- fromDependency
    | CauseDerivedFrom Incompatibility Incompatibility            -- priorCause

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
-- Which packages it applies to is the provider's decision (for cabal, the
-- non-reinstallable boot packages). The core only needs to know the shape.
onlyInstalled :: PackageName -> InstanceSet -> Incompatibility
onlyInstalled p anySource =
    Incompatibility (Map.singleton p (Positive anySource)) (CauseOnlyInstalled p)

-- | Dependency incompatibility: @package@ in @instances@ requires @dep@ in
-- @depSet@ — encoded @{ package: Positive instances, dep: Negative depSet }@.
-- The instance sets are minted by the provider (a @.cabal@ dependency
-- constrains versions; the provider widens that to instances). If @depSet@ is
-- empty the dependency is unsatisfiable and the entry would be ⊤, so it is
-- dropped, leaving a unit ban on @package@.
fromDependency :: PackageName -> InstanceSet -> PackageName -> InstanceSet -> Incompatibility
fromDependency pkgName pkgSet depName depSet =
    Incompatibility
        (if isTopTerm (Negative depSet)
            then Map.singleton pkgName (Positive pkgSet)
            else Map.fromList [(pkgName, Positive pkgSet), (depName, Negative depSet)])
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
    Incompatibility finalTerms (CauseDerivedFrom current satCause)
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
