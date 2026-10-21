-- | PubGrub, the version-solving algorithm, over any domain.
--
-- New to the library? "PubGrub.Tutorial" takes you from an empty file to a
-- plan, and to an explanation of a failure.
--
-- The solver is 'solve': hand it a 'Provider' for your domain and the seeds —
-- the incompatibilities the solve is asked for — and it answers with a value
-- per variable, or with the terminal 'Incompatibility' whose derivation
-- explains why there is none. A domain is an instance of 'Domain': what a
-- variable, a value, a set of values and an external fact are. The derivation
-- is read with "PubGrub.Derivation" and rendered as a numbered proof with
-- "PubGrub.Report", in words a 'Formatter' supplies.
--
-- The algorithm is PubGrub's unit propagation, decision making and conflict
-- resolution, as published; the cabal instantiation lives in the
-- @pubgrub-cabal@ package. "PubGrub.Version" and "PubGrub.VersionSet" are
-- batteries for a domain whose values are versions.
module PubGrub
    ( -- * The domain
      Domain (..)
    , MergeRule (..)
    , noMerging
      -- * Terms and incompatibilities
    , module PubGrub.SetOps
    , module PubGrub.Term
    , Incompatibility (..)
    , Cause (..)
    , VarTerm (..)
    , incompGet
    , noValues
    , isSeed
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
import           PubGrub.SetOps
import           PubGrub.Solver          (SolveError (..), SolverMsg (..),
                                          solve)
import           PubGrub.Term
import           PubGrub.Version
import           PubGrub.VersionSet
