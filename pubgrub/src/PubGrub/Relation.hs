module PubGrub.Relation
    ( Relation (..)
    , relation
    ) where

import           PubGrub.SetOps (SetOps (..))
import           PubGrub.Term   (Term (..))


-- | How a term stands relative to a reference term (both about the same
-- package). This is the primitive unit propagation reads off the partial
-- solution.
data Relation
    = -- | @subject ⊆ reference@: the reference already holds.
      Satisfied
    | -- | @subject ∩ reference = ∅@: they cannot both hold.
      Contradicted
    | -- | neither — the reference is still open.
      Inconclusive
    deriving (Eq, Show)

-- | Relation of @subject@ (typically what the partial solution has derived so
-- far for a package) to @reference@ (a term from an incompatibility). Both
-- tests are emptiness tests, so no equality on payloads is needed — and no
-- reliance on canonical representations either.
--
-- The examples use small @'Data.Set.Set' Int@ payloads:
--
-- >>> import PubGrub.Term
-- >>> import qualified Data.Set as Set
-- >>> relation (Positive (Set.fromList [3])) (Positive (Set.fromList [1..9]))
-- Satisfied
--
-- >>> relation (Positive (Set.fromList [3])) (Positive (Set.fromList [5..9]))
-- Contradicted
--
-- >>> relation (Positive (Set.fromList [1..9])) (Positive (Set.fromList [3]))
-- Inconclusive
--
-- Against a negative reference — "not in {5..9}" — an exact subject either
-- avoids the set or lands in it:
--
-- >>> relation (Positive (Set.fromList [3])) (Negative (Set.fromList [5..9]))
-- Satisfied
--
-- >>> relation (Positive (Set.fromList [6])) (Negative (Set.fromList [5..9]))
-- Contradicted
--
-- A negative subject is never satisfied by a positive reference — the /absent/
-- state always escapes it:
--
-- >>> relation (Negative (Set.fromList [5,6])) (Positive (Set.fromList [1..4]))
-- Inconclusive
relation :: SetOps a => Term a -> Term a -> Relation
relation subject reference
    | subject `isSubsetOf` reference = Satisfied
    | subject `isDisjoint` reference = Contradicted
    | otherwise = Inconclusive
