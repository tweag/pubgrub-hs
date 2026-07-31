module PubGrub.Provider where


import           Distribution.Types.PackageName (PackageName)
import           PubGrub.Incompatibility        (Incompatibility)
import           PubGrub.InstanceSet            (Instance, InstanceSet)



-- | The seam between the Cabal domain (a package index, @.cabal@ files, flags)
-- and the solver, which only ever sees package names, instances and
-- incompatibilities. This callback /is/ the seam: there is deliberately no
-- neutral problem type handed over up front, because materialising one would
-- mean reading every candidate's @.cabal@ — including the all-but-one that get
-- discarded.
--
-- The provider owns the instance domain, but cannot /enumerate/ it: an
-- 'InstanceSet' is symbolic (version ranges × flag pins), and a package's
-- source instances are one per total flag assignment of each version. So it
-- works the other way round: from the offered set, pick one instance the set
-- admits, evaluate that version's conditional dependencies under the
-- assignment it fixes, and translate the results into incompatibilities over
-- instance sets. Data flows one way: the provider /writes/ incompatibilities
-- and never reads the solver's store.
--
-- 'expand' makes the choice ("newest", "prefer installed", flag defaults) and
-- reports its consequences in one step, so the solver never holds one without
-- the other.
newtype Provider m = Provider
    { expand :: PackageName -> InstanceSet -> m (Maybe (Instance, [Incompatibility]))
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
