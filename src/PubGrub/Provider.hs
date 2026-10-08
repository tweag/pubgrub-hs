module PubGrub.Provider where


import           PubGrub.Incompatibility        (Incompatibility)
import           PubGrub.Value                  (Value, ValueSet)
import           PubGrub.Variable               (Var)



-- | The seam between the Cabal domain (a package index, @.cabal@ files, flags)
-- and the solver, which only ever sees package names, instances and
-- incompatibilities. This callback /is/ the seam: there is deliberately no
-- neutral problem type handed over up front, because materialising one would
-- mean reading every candidate's @.cabal@ — including the all-but-one that get
-- discarded.
--
-- The provider owns the instance domain, but cannot /enumerate/ it: a
-- 'PubGrub.InstanceSet.InstanceSet' is symbolic (a version range). So it works
-- the other way round: from the offered set, pick one instance the set admits,
-- read that release's dependencies, and translate them into incompatibilities
-- over instance sets, with each flag-guarded dependency naming the flag
-- variables it holds under. Data flows one way: the provider /writes/
-- incompatibilities and never reads the solver's store.
--
-- 'expand' makes the choice ("newest", "prefer installed", flag defaults) and
-- reports its consequences in one step, so the solver never holds one without
-- the other.
newtype Provider m = Provider
    { expand :: Var -> ValueSet -> m (Maybe Value, [Incompatibility])
      -- ^ Pick one value of the variable to commit to, and report what was
      -- learned on the way — /both/ regardless of whether a value was found.
      -- For a flag variable the value is the declared default where the set
      -- admits it, the other value otherwise, and nothing is reported.
      --
      -- Contract, which the solver depends on: the returned value MUST be a
      -- member of the given 'ValueSet' (the accumulated constraint on the
      -- variable — a hard precondition, not a hint). The solver immediately
      -- records it as a positive decision, so an out-of-range value
      -- contradicts the derivations that produced the set and corrupts the
      -- search. Answer 'Nothing' iff no value in the set qualifies. A
      -- wrong-but-in-range guess is not an error: on a later conflict the solver
      -- backtracks and re-asks with a strictly smaller set.
      --
      -- The incompatibilities are the instance's dependencies, widened from
      -- version ranges to instance sets, under the flags they are guarded by,
      -- plus one clause per automatic flag the release declares.
      --
      -- They need not be /only/ that, and this is why the list sits outside the
      -- 'Maybe'. The solver adds them to its store unexamined and never requires
      -- them to mention the decided value, and an incompatibility holds in
      -- every context by construction, so a provider that rejects candidates on
      -- the way to its answer may report /why/ it rejected them, and those facts
      -- prune and explain like any other. What it must not do is /decide/ a
      -- value it knows to be inadmissible.
      --
      -- __Answering @Nothing@ with facts is the case that matters.__ A release
      -- skipped because it cannot be built here is stated as an incompatibility.
      -- When the offered set holds nothing /but/ such releases, dropping those
      -- statements would make a report say \"no version for hpqtypes in >=1.13\"
      -- where the truth is that every release in that range needs a C library
      -- this machine lacks. On real Hackage problems this is the commonest way a
      -- popular package fails to resolve.
      --
      -- The solver still guarantees progress itself, and does not take the
      -- provider's word for coverage — see 'PubGrub.Solver.solve'.
    }
