{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TypeFamilies       #-}

-- | The source-configuration set: the set type for the source world once flags
-- are folded in. An element is a 'SourceConfig' (a version plus a total flag
-- assignment); a 'SourceConfigSet' is a set of such points, represented as a
-- disjunctive normal form (a union of cells, each a version set paired with a
-- flag conjunction).
--
-- The representation is a Boolean algebra: @neg@ is total. One flag
-- conjunction per version set would not be, because the complement of a
-- conjunction is a disjunction. 'Eq', 'isBottom' and 'isTop' are /semantic/,
-- not derived, because two structurally distinct unions can denote the same set.
module PubGrub.SourceConfig (
    SourceConfig (..),
    FlagConj (..),
    fcTop,
    SourceConfigSet,
    mkCell,
    cellsOf,
    versionsOf,
) where

import           Data.Map.Strict         (Map)
import qualified Data.Map.Strict         as Map
import qualified Data.Text               as T
import           Distribution.Types.Flag (FlagName, unFlagName)
import           Distribution.Version    (Version)

import           PubGrub.Lattice
import           PubGrub.Pretty          (Pretty (..))
import           PubGrub.VersionSet      (VersionSet)
import qualified PubGrub.VersionSet      as VS

--------------------------------------------------------------------------------
-- Elements and the flag axis
--------------------------------------------------------------------------------

-- | A concrete source decision: a version plus a /total/ flag assignment over
-- exactly the flags that version declares.
data SourceConfig = SourceConfig
    { scVersion :: !Version
    , scFlags   :: !(Map FlagName Bool)
    }
    deriving stock (Eq, Ord, Show)

-- | A constraint on the flag axis: a conjunction of pinned flags (absent key =
-- unconstrained), or the contradictory bottom. This is intentionally /not/ a
-- 'Boolean' — it is not closed under complement (that is why the enclosing set
-- is a DNF).
data FlagConj
    = FCBottom
    | FCConj (Map FlagName Bool)
    deriving stock (Eq, Ord, Show)

-- | The unconstrained flag conjunction (top).
fcTop :: FlagConj
fcTop = FCConj Map.empty

-- | Conjunction of two flag constraints; a disagreement on a shared flag is a
-- contradiction ('FCBottom').
fcMeet :: FlagConj -> FlagConj -> FlagConj
fcMeet FCBottom _ = FCBottom
fcMeet _ FCBottom = FCBottom
fcMeet (FCConj a) (FCConj b)
    | and (Map.intersectionWith (==) a b) = FCConj (Map.union a b)
    | otherwise = FCBottom

-- | Complement of a conjunction, as a /union/ of single-flag flips (one cell per
-- pinned flag). @neg top = bottom@ is the empty union.
fcNeg :: FlagConj -> [FlagConj]
fcNeg FCBottom = [fcTop]
fcNeg (FCConj c)
    | Map.null c = []
    | otherwise = [FCConj (Map.singleton f (not b)) | (f, b) <- Map.toList c]

-- | Membership of a total flag assignment. A pinned flag the assignment does
-- not mention is satisfied, because each version declares its own flags.
fcMember :: Map FlagName Bool -> FlagConj -> Bool
fcMember _ FCBottom = False
fcMember m (FCConj c) = all (\(f, b) -> maybe True (== b) (Map.lookup f m)) (Map.toList c)

-- | @fcImplies x y@ iff @x@'s assignment set is a subset of @y@'s (i.e. @x@ is
-- at least as constrained as @y@).
fcImplies :: FlagConj -> FlagConj -> Bool
fcImplies FCBottom _            = True
fcImplies _ FCBottom            = False
fcImplies (FCConj a) (FCConj b) = Map.isSubmapOf b a

--------------------------------------------------------------------------------
-- Cells
--------------------------------------------------------------------------------

-- | A single cell of the DNF: @version-set × flag-conjunction@.
data SourceCell = SourceCell !VersionSet !FlagConj
    deriving stock (Show)

cellEmpty :: SourceCell -> Bool
cellEmpty (SourceCell vs fc) = isBottom vs || fc == FCBottom

cellMeet :: SourceCell -> SourceCell -> SourceCell
cellMeet (SourceCell v1 f1) (SourceCell v2 f2) = SourceCell (v1 /\ v2) (fcMeet f1 f2)

cellMember :: SourceConfig -> SourceCell -> Bool
cellMember (SourceConfig v m) (SourceCell vs fc) = VS.contains vs v && fcMember m fc

-- | @cellSubset small big@ iff @small@'s point set is contained in @big@'s.
cellSubset :: SourceCell -> SourceCell -> Bool
cellSubset (SourceCell v1 f1) (SourceCell v2 f2) = subsetOf v1 v2 && fcImplies f1 f2

--------------------------------------------------------------------------------
-- The set
--------------------------------------------------------------------------------

-- | A set of 'SourceConfig' points, as a union of cells. The constructor is
-- hidden so every value stays normalised (empty and subsumed cells dropped).
newtype SourceConfigSet = SourceConfigSet [SourceCell]
    deriving stock (Show)

-- | Smart constructor: drop empty cells, then drop any cell another contains.
-- Neither step changes the denotation; together they bound the cell count,
-- which @neg@ would otherwise blow up.
mkSCS :: [SourceCell] -> SourceConfigSet
mkSCS = SourceConfigSet . foldl' insertCell [] . filter (not . cellEmpty)
  where
    insertCell kept c
        | any (c `cellSubset`) kept = kept
        | otherwise = c : filter (\k -> not (k `cellSubset` c)) kept

-- | A single-cell set: all versions in the given set, with the given flag
-- conjunction.
mkCell :: VersionSet -> FlagConj -> SourceConfigSet
mkCell vs fc = mkSCS [SourceCell vs fc]

-- | The normalised cells of a set, as @(versionSet, flagConj)@ pairs
-- (introspection, testing).
cellsOf :: SourceConfigSet -> [(VersionSet, FlagConj)]
cellsOf (SourceConfigSet cs) = [(vs, fc) | SourceCell vs fc <- cs]

-- | The versions the set admits, ignoring flags — the projection onto the
-- version axis. (Every stored cell is non-empty, so each contributes its whole
-- version range.)
versionsOf :: SourceConfigSet -> VersionSet
versionsOf (SourceConfigSet cs) = foldr (\/) bottom [vs | SourceCell vs _ <- cs]

instance Lattice SourceConfigSet where
    SourceConfigSet a \/ SourceConfigSet b = mkSCS (a ++ b)
    SourceConfigSet a /\ SourceConfigSet b = mkSCS [cellMeet x y | x <- a, y <- b]

instance BoundedLattice SourceConfigSet where
    bottom = SourceConfigSet []
    top = SourceConfigSet [SourceCell VS.full fcTop]
    isBottom (SourceConfigSet cs) = null cs -- mkSCS drops every empty cell
    isTop s = isBottom (neg s)

instance Boolean SourceConfigSet where
    neg (SourceConfigSet cs) = foldl' (/\) top (map negCell cs) -- De Morgan
      where
        negCell (SourceCell vs fc) =
            mkSCS (SourceCell (neg vs) fcTop : [SourceCell VS.full f | f <- fcNeg fc])

-- | Semantic equality (mutual subset) — deliberately not derived.
instance Eq SourceConfigSet where
    a == b = subsetOf a b && subsetOf b a

instance Sets SourceConfigSet where
    type Elem SourceConfigSet = SourceConfig
    singleton (SourceConfig v m) = mkSCS [SourceCell (VS.singleton v) (FCConj m)]
    member e (SourceConfigSet cs) = any (cellMember e) cs

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

instance Pretty SourceConfig where
    pretty (SourceConfig v flags) = pretty v <> foldMap renderFlag (Map.toList flags)
      where
        renderFlag (f, b) = " " <> (if b then "+" else "-") <> T.pack (unFlagName f)

-- | A union of cells renders as its version ranges, joined by @|@.
instance Pretty SourceConfigSet where
    pretty s = case cellsOf s of
        [] -> "∅"
        cs -> T.intercalate " | " [pretty vs | (vs, _fc) <- cs]
