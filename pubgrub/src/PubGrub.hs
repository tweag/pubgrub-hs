-- | PubGrub is a version-solving algorithm. Given a set of requests,
-- it finds a value for every variable or explains why there is none.
-- This module re-exports everything a user of the library needs.
--
-- = Where to start
--
-- * To learn the library by building something with it, follow
--   "PubGrub.Tutorial".
-- * For a task in hand (versions and ranges, requests and constraints, a
--   provider over an index, explanations in a domain's words, watching the
--   search, releasing a lock), see the recipes in "PubGrub.Cookbook".
-- * For what each name means, read on: the sections below are the reference,
--   and the modules they come from say more.
--
-- = How the solver sees a problem
--
-- A /domain/ says what the solver is solving over ('Domain'): the variables,
-- the values each can take, sets of values, and the facts it can be told. In a
-- package manager the variables are packages and the values their versions,
-- but nothing in the solver depends on that.
--
-- All the solver knows is a collection of /incompatibilities/: sets of
-- /terms/, one per variable, that cannot all be true. A term says something
-- about one variable's value: @'Positive' s@, it has a value in the set @s@;
-- @'Negative' s@, it has none in @s@, or no value at all. A request, a
-- dependency and a conflict are all incompatibilities ("PubGrub.Incompatibility"
-- lists their shapes).
--
-- A solve starts from the request, a list of incompatibilities marked as
-- seeds, and repeats two steps. /Propagation/ derives from the
-- incompatibilities what each variable must or must not be. When it has
-- nothing more to derive, a /decision/ takes a variable that must have a value
-- and has none, and asks the provider for one ('expand'); it answers with a
-- value and with the incompatibilities that value brings, its dependencies
-- for instance, and the search goes on. The world is read one variable at a
-- time, only as far as the search reaches.
--
-- When the incompatibilities rule out what has been decided, there is a
-- /conflict/. The solver does not just undo the last decision: by resolving
-- incompatibilities against each other it derives a new one that says why the
-- conflict happened, keeps it, and goes back to the point where the new
-- incompatibility forces a different choice. What it learned is never
-- forgotten, so the search does not walk into the same conflict twice.
--
-- Every derived incompatibility remembers the two it came from. When a
-- conflict rests on the seeds alone, no decision can be undone to avoid it, and
-- the solve fails. The incompatibility it ends with is the root of a tree of
-- reasoning whose leaves are the facts the solver was given: the proof that
-- there is no solution. "PubGrub.Derivation" reads that tree, and
-- "PubGrub.Report" writes it out as numbered sentences that the domain words.
--
-- = Modules
--
-- * "PubGrub.Incompatibility": the domain, incompatibilities and their causes.
-- * "PubGrub.Term" and "PubGrub.SetOps": terms, and the set operations a
--   domain's sets provide. The class is re-exported here and its methods are
--   not, since @empty@, @union@ and @intersect@ are names every other set
--   library uses too: a domain that writes an instance imports
--   "PubGrub.SetOps" for them.
-- * "PubGrub.Provider": the provider and its contract.
-- * "PubGrub.Solver": 'solve'.
-- * "PubGrub.Derivation" and "PubGrub.Report": reading a failure, and writing
--   it out.
-- * "PubGrub.Version", "PubGrub.VersionSet" and "PubGrub.Pretty": values and
--   sets for a domain whose values are versions, and their rendering.
--
-- The domain of Haskell packages is the @pubgrub-cabal@ package.
module PubGrub
    ( -- * The domain
      Domain (..)
    , MergeRule (..)
    , noMerging
      -- * Terms and incompatibilities
    , SetOps
    , module PubGrub.Term
    , Incompatibility (..)
    , Cause (..)
    , incompGet
    , noValues
    , isSeed
    , incompatibility
    , seed
    , fact
      -- * The provider
    , Provider (..)
      -- * Solving
    , solve
    , SolveError (..)
    , SolverMsg (..)
      -- * Reading a failure
    , module PubGrub.Derivation
    , module PubGrub.Report
      -- * Rendering
    , Pretty (..)
      -- * Versions
    , module PubGrub.Version
    , module PubGrub.VersionSet
    ) where

import           PubGrub.Derivation
import           PubGrub.Incompatibility
import           PubGrub.Pretty
import           PubGrub.Provider
import           PubGrub.Report
import           PubGrub.SetOps          (SetOps)
import           PubGrub.Solver          (SolveError (..), SolverMsg (..),
                                          solve)
import           PubGrub.Term
import           PubGrub.Version
import           PubGrub.VersionSet
