module PubGrub.InstanceSet.SourceCell where

import qualified Data.Map.Merge.Strict       as Map
import           Data.Map.Strict             (Map)
import qualified Data.Map.Strict             as Map
import qualified Data.Text                   as T
import           Distribution.Types.Flag     (FlagAssignment, FlagName,
                                              mkFlagAssignment,
                                              showFlagAssignment,
                                              unFlagAssignment)
import           PubGrub.Index.SourcePackage (SourcePackage (..))
import           PubGrub.Pretty              (Pretty (..))
import           PubGrub.SetOps              (SetOps (..))
import           PubGrub.VersionSet          (VersionSet)
import qualified PubGrub.VersionSet          as VersionSet

-- | A version range together with pinned flags. A flag absent from the map is
-- unconstrained (both values are in the set). A cell is not closed under union
-- or difference, so it has no 'SetOps' instance; t'PubGrub.InstanceSet.InstanceSet',
-- a union of cells, is closed under all three and has one.
data SourceCell = SourceCell
    { scVersionSet :: VersionSet
    , scFlags      :: Map FlagName Bool
    }


-- | Intersect two cells. The result can be empty for a reason the version set
-- cannot express: if the cells pin the same flag to opposite values, no
-- assignment satisfies both. 'Nothing' is that contradiction.
intersectCell  :: SourceCell -> SourceCell -> Maybe SourceCell
intersectCell lhs rhs =
    mkCell <$> scFlags lhs `combine` scFlags rhs
    where
        mkCell flags =
            SourceCell  { scVersionSet = scVersionSet lhs `intersect` scVersionSet rhs
                        , scFlags      = flags
                        }

        -- Keep every pin from either side. One flag pinned to opposite values
        -- makes the whole result 'Nothing'.
        combine :: Map FlagName Bool -> Map FlagName Bool -> Maybe (Map FlagName Bool)
        combine =
            Map.mergeA
                Map.preserveMissing            -- pinned only by lhs
                Map.preserveMissing            -- pinned only by rhs
                (Map.zipWithAMatched agree)    -- pinned by both
          where
            agree _flag v1 v2
                | v1 == v2  = Just v1
                | otherwise = Nothing

-- | Cells are /not/ closed under difference, so the result is a disjunction. An
-- instance of @lhs@ avoids @rhs@ either by falling outside its version set, or —
-- among the versions the two share — by disagreeing with one of its pinned
-- flags. The second case contributes one cell per flag that can carry the
-- disagreement, which is where the @1 + |flags|@ growth comes from.
differenceCell :: SourceCell -> SourceCell -> [SourceCell]
differenceCell lhs rhs =
    filter (not . nullCell) $
        SourceCell { scVersionSet = scVersionSet lhs `difference` scVersionSet rhs
               , scFlags      = scFlags lhs
               }
        : [ SourceCell { scVersionSet = scVersionSet lhs `intersect` scVersionSet rhs
                       , scFlags      = Map.insert flag val (scFlags lhs)
                       }
          | (flag, val) <- Map.toList (scFlags lhs `combine` scFlags rhs)
          ]

    where
        -- For each flag rhs pins, the value an instance of lhs takes to escape
        -- rhs, giving one cell per flag. A flag lhs pins to rhs's value offers no
        -- escape and is dropped. A flag lhs pins to the opposite value is kept,
        -- since that cell lies wholly outside rhs.
        combine :: Map FlagName Bool -> Map FlagName Bool -> Map FlagName Bool
        combine =
            Map.merge
                Map.dropMissing                     -- pinned only by lhs: rhs leaves it free, so no escape needed
                (Map.mapMissing (\_ v -> not v))    -- pinned only by rhs: lhs escapes by taking the opposite
                (Map.zipWithMaybeMatched escape)    -- pinned by both
          where
            escape _flag v1 v2
                | v1 == v2  = Nothing   -- agrees, so this flag cannot carry the escape
                | otherwise = Just v1   -- already disagrees: lhs escapes as it stands

nullCell :: SourceCell -> Bool
nullCell sc = isEmpty (scVersionSet sc)

-- | Collapse cells that pin exactly the same flags:
-- @(V₁, F) ∨ (V₂, F) = (V₁ ∪ V₂, F)@. Sound because the two conjunctions are
-- identical, so only the version sets need joining.
--
-- Without it, 'union' on 'PubGrub.InstanceSet.InstanceSet' would only append
-- cells, and a long chain of 'PubGrub.Incompatibility.priorCause' derivations
-- would accumulate them without bound. It also sharpens reports: two derived
-- halves of a package (@<1.1.0@ and @>=1.1.0@) merge back into the whole,
-- which reads as "every version" rather than as a list of fragments.
mergeCells :: [SourceCell] -> [SourceCell]
mergeCells cells =
    [ SourceCell vs flags
    | (flags, vs) <- Map.toList (Map.fromListWith union [(scFlags c, scVersionSet c) | c <- cells])
    ]

singletonCell :: SourcePackage -> FlagAssignment -> SourceCell
singletonCell sp flags =
  SourceCell
      { scVersionSet = VersionSet.singletonVersionSet (spVersion sp)
      , scFlags = Map.fromList (unFlagAssignment flags)
      }

instance Pretty SourceCell where
    pretty sc =
        pretty (scVersionSet sc) <> T.pack (showFlagAssignment (mkFlagAssignment (Map.toList (scFlags sc))))
