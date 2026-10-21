-- | The provider: how the solver learns about the world, one variable at a
-- time.
module PubGrub.Provider
    ( Provider (..)
    ) where

import           PubGrub.Incompatibility (Domain (..), Incompatibility)


-- | What the solver asks of the world. It never sees the world itself, only
-- variables, sets of values and incompatibilities, and it asks about one
-- variable when it needs to: there is no problem description handed over up
-- front, so a provider reads only what the search reaches.
--
-- The question is always the same: here is a variable, and the set of values
-- it may still take; commit to one of them, and say what that choice entails.
-- The set may be symbolic, a range rather than a list, so the provider is not
-- asked to enumerate it: it picks a value the set admits, by whatever
-- preference it has (the newest version, an installed one, a default).
--
-- @m@ is the provider's own monad: 'Data.Functor.Identity.Identity' for a world
-- held in memory, 'IO' for one read from disk.
newtype Provider v m = Provider
    { expand :: v -> SetOf v -> m (Maybe (ValueOf v), [Incompatibility v])
      -- ^ Pick a value of the variable from the set, and state what is known
      -- on the way: typically the chosen value's dependencies.
      --
      -- __The value must be in the set.__ The set is everything the solver
      -- has derived about the variable, and the solver records the value as a
      -- decision at once, so a value outside it contradicts what the solver
      -- already knows. The solver checks, and stops the solve with
      -- 'PubGrub.Solver.BadValue' rather than go on. A value in the set that
      -- turns out wrong is not an error: on a later conflict the solver
      -- backtracks and asks again with a smaller set.
      --
      -- Answer 'Nothing' when no value in the set can be chosen. The solver
      -- then states that the variable takes no value in the set, so the same
      -- set is never offered twice.
      --
      -- __The incompatibilities are facts.__ The solver adds them to what it
      -- knows without examining them, and each must be true of every solution,
      -- whatever has been decided so far. They need not mention the chosen
      -- value. So a provider that passes over values on the way to its answer
      -- may say why it passed them over, and those facts prune the search and
      -- explain a failure like any other. A fact should have a positive term,
      -- or a single negative one: a fact of two or more negative terms and
      -- nothing else says that one of several variables must have a value
      -- without saying which, and the search never acts on it.
      --
      -- This matters most when the answer is 'Nothing'. If every value in the
      -- set was rejected for a reason (it cannot be built here, it needs
      -- something missing), state the reasons: the solver uses them, and
      -- states \"no value\" only for what they do not cover. A failure is then
      -- explained by what was wrong with the values, not by their absence.
    }
