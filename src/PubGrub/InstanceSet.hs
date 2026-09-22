module PubGrub.InstanceSet where

import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Data.Set                       (Set)
import qualified Data.Set                       as Set
import qualified Data.Text                      as T
import           Distribution.Types.Flag        (FlagAssignment, FlagName,
                                                 showFlagAssignment,
                                                 unFlagAssignment)
import           PubGrub.Version                (Version)
import           PubGrub.Index.PreInstalled     (PreInstalledPackage (..))
import           PubGrub.InstanceSet.SourceCell (FlagPin (..), SourceCell (..),
                                                 differenceCell, intersectCell,
                                                 mergeCells, nullCell,
                                                 pinnedCell, pruneCells)
import           PubGrub.Pretty                 (Pretty (..))
import           PubGrub.SetOps                 (SetOps (..))
import qualified PubGrub.VersionSet             as VersionSet

-- | A pre-installed unit carries a version, and so does an 'Instance' — this is
-- what lets the 'PubGrub.Provider.Provider' turn a @.cabal@ dependency's
-- 'PubGrub.VersionSet.VersionSet' into the corresponding set of instances.
class HasVersion a where
    version :: a -> Version

instance HasVersion PreInstalledPackage where
    version = pipVersion

-- Package Instance ------------------------------------------------------------

-- | The value domain of a solver variable: one concrete, fully-determined way
-- of having a package — use a specific pre-installed unit, or build a source
-- release under a flag assignment. The assignment must be /total/ over the
-- package's declared flags (a 'Provider' invariant, not enforced here), so an
-- instance has no conditionals left.
--
-- An 'Instance' /identifies/ a way of having a package; it does not describe
-- one, and carries no dependencies. Those come from the 'Provider', which owns
-- the index the identifier points into, so enumerating a package's instances
-- parses no @.cabal@ file, and no instance has to stand for dependencies it
-- does not know.
--
-- The two identifiers differ in shape because the two halves of an
-- 'InstanceSet' do. A unit ID is global and the installed half is an explicit
-- set, so identity is all it needs. A source release is identified only
-- /relative to its package name/, and stays structured because the source half
-- is symbolic: membership tests the version against a range and the assignment
-- against pinned flags.
data Instance
    = UsePreInstalled PreInstalledPackage
    | BuildSource Version FlagAssignment
    deriving (Show, Eq)

instance HasVersion Instance where
    version (UsePreInstalled pip) = version pip
    version (BuildSource v _)     = v

instance Pretty Instance where
    pretty (UsePreInstalled pip) = T.pack "installed:" <> pretty (pipUnitId pip)
    pretty (BuildSource v fa)    = pretty v <> T.pack (showFlagAssignment fa)

-- | A set of 'Instance's of one package: the value a solver term ranges over.
--
-- The two halves are represented differently because they differ in kind. The
-- installed half is /extensional/: the installed database is small and fully
-- known, so it is a plain 'Set' of units. The source half is /intensional/: a
-- dependency's declared range admits versions the index may not even have, so
-- it is kept as a disjunction of 'SourceCell's, each a version range crossed
-- with pinned flags, and never enumerated. A cell keeps its range, so a report
-- can still be phrased in ranges after the set algebra has run.
--
-- The cell list is a disjunctive normal form and is /not/ canonical: two
-- different lists can denote the same set, so there is deliberately no 'Eq' or
-- 'Ord' instance. Use 'PubGrub.SetOps.equivalent' for semantic equality.
-- 'isEmpty' is one-sided: it may answer "not empty" for a set that is empty in
-- fact, because seeing that needs the index, but it never claims emptiness
-- wrongly.
data InstanceSet = InstanceSet
    { isInstalled :: Set PreInstalledPackage
    -- ^ The pre-installed units in the set, extensionally.
    , isSource    :: [SourceCell]
    -- ^ The source releases in the set, as a disjunction of cells. Not
    -- canonical; see above.
    }

-- Every operation prunes with 'pruneCells', 'difference' once per rhs cell, so
-- an rhs with no source cells passes the lhs through untouched. Correctness
-- does not need any of this: the union of cells is deliberately not canonical,
-- and the solver only asks emptiness questions. But the cell count does not
-- track the denotation, so without pruning at each step a chain of derivations
-- grows a disjunction of thousands of cells describing a handful of instances.
-- Pruning only at the end would be too late, since the blow-up is in the
-- intermediate results.
instance SetOps InstanceSet where
    union lhs rhs  =
        InstanceSet
            { isInstalled = isInstalled lhs `Set.union` isInstalled rhs
            , isSource    = pruneCells (mergeCells (isSource lhs <> isSource rhs))
            }
    intersect lhs rhs =
        InstanceSet
            { isInstalled = isInstalled lhs `Set.intersection` isInstalled rhs
            , isSource    = pruneCells
                [ cell
                | x <- isSource lhs
                , y <- isSource rhs
                , Just cell <- [intersectCell x y]   -- drops contradictory flag pins
                , not (nullCell cell)
                ]
            }
    difference lhs rhs
        = InstanceSet
            { isInstalled = isInstalled lhs `Set.difference` isInstalled rhs
            , isSource    = foldl' (\xs y -> pruneCells (concatMap (`differenceCell` y) xs)) (isSource lhs) (isSource rhs)
            }
    isEmpty is = Set.null (isInstalled is) && all nullCell (isSource is)

-- | The empty instance set. @Negative emptyInstanceSet@ is the always-true
-- term ⊤; @Positive emptyInstanceSet@ is the never-true term ⊥.
emptyInstanceSet :: InstanceSet
emptyInstanceSet = InstanceSet { isInstalled = Set.empty, isSource = [] }

-- | The set containing exactly one instance — the shape of a decision.
-- @singletonInstance (BuildSource v fa)@ is a cell pinning every flag in @fa@,
-- so it is a singleton only if @fa@ is total over the package's declared flags:
-- a cell denotes every value of a flag it leaves unpinned.
singletonInstance :: Instance -> InstanceSet
singletonInstance (UsePreInstalled pip) = singletonUsePreInstalled pip
singletonInstance (BuildSource v flags) = singletonBuildSource v flags

singletonUsePreInstalled :: PreInstalledPackage -> InstanceSet
singletonUsePreInstalled pip =
    InstanceSet { isInstalled = Set.singleton pip, isSource = [] }

-- | One source instance: a single version under a single assignment. It is a
-- singleton only if the assignment is total over the version's declared flags.
--
-- This is what a __decision__ is made of, and the only place a single version
-- becomes an instance set.
singletonBuildSource :: Version -> FlagAssignment -> InstanceSet
singletonBuildSource v flags =
    InstanceSet
        { isInstalled = Set.empty
        , isSource =
            [ pinnedCell
                (VersionSet.singletonVersionSet v)
                (Map.fromList (unFlagAssignment flags))
            ]
        }

-- | Does the set contain this instance?
memberInstance :: Instance -> InstanceSet -> Bool
memberInstance (UsePreInstalled pip) is =
    Set.member pip (isInstalled is)
memberInstance (BuildSource v fa) is = any inCell (isSource is)
    where
        inCell (SourceCell vs flags) =
            vs `VersionSet.contains` v
            && flags `memberFlagAssignment` fa

-- | Does an assignment satisfy a cell's pins? Every pin must be met; flags the
-- cell leaves free are unconstrained.
--
-- Note the direction: the quantifier runs over the /pins/, not the assignment.
-- Quantifying over the assignment would demand that every assigned flag also be
-- pinned, so an unpinned cell would contain nothing rather than everything.
--
-- A 'NotDeclared' pin is decided from the assignment alone, with no index
-- lookup: the assignment is /exact/ over the version's declared flags, so its
-- keys are the flags that version declares.
memberFlagAssignment :: Map FlagName FlagPin -> FlagAssignment -> Bool
memberFlagAssignment pins fa = all satisfied (Map.toList pins)
  where
    assigned = Map.fromList (unFlagAssignment fa)
    satisfied (f, PinnedTo b)  = Map.lookup f assigned == Just b
    satisfied (f, NotDeclared) = Map.notMember f assigned

-- | Does the set admit every source instance of its package? True of the root's
-- term and of a depender that spans the whole version list. The report writes
-- such a set as "every version of foo".
--
-- One-sided, like 'isEmpty': a set can admit everything without any single cell
-- saying so, and this answers 'False' then. For a renderer that is the safe
-- direction, because it then prints the range instead of the phrase.
isEveryVersion :: InstanceSet -> Bool
isEveryVersion is =
    any (\c -> Map.null (scFlags c) && scVersionSet c == VersionSet.fullVersionSet) (isSource is)

instance Pretty InstanceSet where
    pretty is = T.intercalate (T.pack " or ") (installed <> map pretty (isSource is))
      where
        -- An installed unit whose version a flag-free source cell admits is one of
        -- that cell's versions, and naming it separately tells a reader nothing:
        -- "deepseq 1.5.1.0 (installed) or >=1.4.3.0 && <1.6" is the same set as
        -- "deepseq >=1.4.3.0 && <1.6". The unit id is never shown. It is a hash,
        -- and the version is what a reader can act on.
        covered pip =
            any
                (\c -> Map.null (scFlags c) && VersionSet.contains (scVersionSet c) (pipVersion pip))
                (isSource is)
        installed =
            [ pretty (pipVersion pip) <> T.pack " (installed)"
            | pip <- Set.toList (isInstalled is)
            , not (covered pip)
            ]
