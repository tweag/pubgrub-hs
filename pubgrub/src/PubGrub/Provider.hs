module PubGrub.Provider where


import           PubGrub.Incompatibility (Domain (..), Incompatibility)



-- | The seam between a problem domain (for cabal: a package index, @.cabal@
-- files, flags) and the solver, which only ever sees variables, values and
-- incompatibilities. This callback /is/ the seam: there is deliberately no
-- neutral problem type handed over up front, because materialising one would
-- mean reading every candidate's @.cabal@ — including the all-but-one that get
-- discarded.
--
-- The provider owns the value domain, but cannot /enumerate/ it: a set of
-- values may be symbolic (for cabal, a version range). So it works the other
-- way round: from the offered set, pick one value the set admits, read what
-- that choice entails, and state it as incompatibilities. Data flows one way:
-- the provider /writes/ incompatibilities and never reads the solver's store.
--
-- 'expand' makes the choice ("newest", "prefer installed", flag defaults) and
-- reports its consequences in one step, so the solver never holds one without
-- the other.
newtype Provider d m = Provider
    { expand :: VarOf d -> SetOf d -> m (Maybe (ValueOf d), [Incompatibility d])
      -- ^ Pick one value of the variable to commit to, and report what was
      -- learned on the way — /both/ regardless of whether a value was found.
      -- For a cabal flag variable the value is the declared default where the
      -- set admits it, the other value otherwise, and nothing is reported.
      --
      -- Contract, which the solver depends on: the returned value MUST be a
      -- member of the given set (the accumulated constraint on the
      -- variable — a hard precondition, not a hint). The solver immediately
      -- records it as a positive decision, so an out-of-range value
      -- contradicts the derivations that produced the set and corrupts the
      -- search. Answer 'Nothing' iff no value in the set qualifies. A
      -- wrong-but-in-range guess is not an error: on a later conflict the solver
      -- backtracks and re-asks with a strictly smaller set.
      --
      -- For cabal the incompatibilities are the instance's dependencies, widened
      -- from version ranges to instance sets, under the flags they are guarded
      -- by, plus one clause per automatic flag the release declares.
      --
      -- They need not be /only/ that, and this is why the list sits outside the
      -- 'Maybe'. The solver adds them to its store unexamined and never requires
      -- them to mention the decided value, and incompatibilities are
      -- context-independent by construction (each one is true of every
      -- solution, whatever has been decided so far) — so a provider that
      -- rejects candidates on the way to its answer may report /why/ it
      -- rejected them, and those facts prune and explain like any other.
      -- What it must not do is /decide/ a value it knows to be inadmissible.
      --
      -- __Answering @Nothing@ with facts is the case that matters.__ A release
      -- skipped because it cannot be built here is stated as an incompatibility,
      -- as PubGrub asks of any version that cannot be selected; when the
      -- offered set holds nothing /but/ such releases there is no instance to
      -- carry those statements out, and dropping them is what makes a report say
      -- \"no version for hpqtypes in >=1.13\" where the truth is that every
      -- release in that range needs a C library this machine lacks. That case is
      -- not a corner: on real Hackage problems it is the commonest way a popular
      -- package fails to resolve.
      --
      -- The solver still guarantees progress itself, and does not take the
      -- provider's word for coverage — see 'PubGrub.Solver.solve'.
    }
