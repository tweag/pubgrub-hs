module PubGrub.Provider where


import           Distribution.Types.PackageName (PackageName)
import           PubGrub.Incompatibility        (Incompatibility)
import           PubGrub.InstanceSet            (Instance, InstanceSet)



-- | The seam between the Cabal domain ('PubGrub.InstanceSet.Index',
-- 'PubGrub.InstanceSet.SourcePackage', …) and the solver, which only ever sees
-- package names, instances and incompatibilities. The provider owns the
-- instance domain: it enumerates each package's instances from the index (one
-- per pre-installed unit, one per buildable total flag assignment of each
-- source version), evaluates the conditional dependencies under each
-- instance's flag assignment, and translates the results — plus user
-- constraints — into incompatibilities over instance sets. Data flows one way:
-- the provider /writes/ incompatibilities and never reads the solver's store.
--
-- 'expand' makes the choice ("newest", "prefer installed", flag defaults) and
-- reports its consequences in one step, so the solver never holds one without
-- the other.
newtype Provider = Provider
    { expand :: PackageName -> InstanceSet -> Maybe (Instance, [Incompatibility])
      -- ^ Pick one instance of the package to commit to, together with the
      -- clauses it entails.
      --
      -- Contract, which the solver depends on: the returned instance MUST be a
      -- member of the given 'InstanceSet' (the accumulated constraint on the
      -- package — a hard precondition, not a hint). The solver immediately
      -- records it as a positive decision, so an out-of-range instance
      -- contradicts the derivations that produced the set and corrupts the
      -- search. Return 'Nothing' iff no instance in the set qualifies; the
      -- solver turns that into a "no instances" incompatibility and backtracks.
      -- A wrong-but-in-range guess is not an error: on a later conflict the
      -- solver backtracks and re-asks with a strictly smaller set.
      --
      -- The paired incompatibilities are the instance's dependencies, already
      -- unconditional (flags fixed by the instance) and widened from version
      -- ranges to instance sets.
    }
