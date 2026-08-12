module PubGrub.InstanceSet.SourceCell where

import           Data.List                  (sortOn)
import qualified Data.Map.Merge.Strict      as Map
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromMaybe)
import           Data.Ord                   (Down (..))
import qualified Data.Text                  as T
import           Distribution.Types.Flag    (FlagAssignment, FlagName,
                                             mkFlagAssignment, unFlagName)
import           PubGrub.Pretty             (Pretty (..))
import           PubGrub.SetOps             (SetOps (..), isSubsetOf)
import           PubGrub.VersionSet         (VersionSet)

-- | What a cell says about one flag. Three states, because a flag is declared by
-- a @(package, version)@ rather than by a package, so "the version has no such
-- flag" is a real thing to say about an instance and not an error case.
--
-- Together with /absence from the pin map/, which means unconstrained, that
-- makes four states per flag. The two are easy to confuse: 'NotDeclared' is a
-- statement about the package version, absence is a statement about the
-- constraint.
--
-- 'PinnedTo' alone would not be closed under negation: @not (f is on)@ is
-- @f is off@ /or/ @f is not declared@, and a two-valued pin drops the second
-- disjunct, silently losing from a 'differenceCell' every instance that lacks
-- the flag.
data FlagPin
    = PinnedTo Bool  -- ^ the version declares this flag, with this value
    | NotDeclared    -- ^ the version does not declare this flag at all
    deriving (Eq, Ord, Show)

-- | The two states a pin can escape to, i.e. the disjunction @not pin@ denotes.
-- Two, always — which is where the @1 + 2·|pins|@ growth of 'differenceCell'
-- comes from.
otherPins :: FlagPin -> [FlagPin]
otherPins (PinnedTo b) = [PinnedTo (not b), NotDeclared]
otherPins NotDeclared  = [PinnedTo False, PinnedTo True]

-- | A version range together with pinned flags. A flag absent from the map is
-- unconstrained (every 'FlagPin' state allowed). A cell is not closed under
-- union or difference, so it has no 'SetOps' instance;
-- t'PubGrub.InstanceSet.InstanceSet', a union of cells, is closed under all three
-- and has one.
--
-- The 'Ord' is /structural/, on the canonical 'VersionSet' and the pin map. It
-- gives a disjunction of cells a deterministic order (the DNF is otherwise in
-- derivation order) and keys 'mergeCells'. It is not semantic equality: empty
-- cells with different pins denote the same nothing yet compare unequal, which
-- is why 'PubGrub.InstanceSet.InstanceSet' has no 'Eq' and semantic questions go
-- through 'PubGrub.SetOps.equivalent'.
data SourceCell = SourceCell
    { scVersionSet :: VersionSet
    , scFlags      :: Map FlagName FlagPin
    }
    deriving (Eq, Ord)


-- | Intersect two cells. The result can be empty for a reason the version set
-- cannot express: if the cells pin the same flag to two different states, no
-- instance satisfies both. 'Nothing' is that contradiction.
--
-- All three states take part: @PinnedTo True@ contradicts @PinnedTo False@ and
-- also contradicts 'NotDeclared', since an instance either has the flag or does
-- not. So the test remains plain inequality.
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
        combine :: Map FlagName FlagPin -> Map FlagName FlagPin -> Maybe (Map FlagName FlagPin)
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
-- among the versions the two share — by failing one of @rhs@'s pins.
--
-- Failing a pin means being in one of the /two other/ states ('otherPins'), so
-- each flag @rhs@ pins contributes up to two cells rather than one, and the
-- growth is @1 + 2·|pins of rhs|@. Offering only the opposite 'Bool' would
-- silently drop the instances whose version does not declare the flag: they
-- escape @rhs@ via 'NotDeclared' and have no other route out.
differenceCell :: SourceCell -> SourceCell -> [SourceCell]
differenceCell lhs rhs =
    filter (not . nullCell) (outsideRange : concatMap escapesVia (Map.toList (scFlags rhs)))
  where
    -- Route one: a version @rhs@ does not cover at all. Keeps @lhs@'s own pins.
    outsideRange =
        lhs { scVersionSet = scVersionSet lhs `difference` scVersionSet rhs }

    sharedVersions = scVersionSet lhs `intersect` scVersionSet rhs

    -- Route two: a shared version, in a state this pin excludes. One cell per
    -- (flag, escape state) that @lhs@ does not already rule out.
    escapesVia (flag, pin) =
        [ SourceCell { scVersionSet = sharedVersions
                     , scFlags      = Map.insert flag escape (scFlags lhs)
                     }
        | escape <- otherPins pin
        , reachable flag escape
        ]

    -- Whether @lhs@ can be in that state at all. If @lhs@ leaves the flag free,
    -- yes. If @lhs@ already pins it, only that pin is reachable. When the pin is
    -- an escape, the 'Map.insert' above is a no-op and the cell is @lhs@ over the
    -- shared versions, wholly outside @rhs@. When @lhs@ pins the state @rhs@
    -- requires, neither escape is reachable and this flag offers no route out.
    reachable flag escape = maybe True (== escape) (Map.lookup flag (scFlags lhs))

nullCell :: SourceCell -> Bool
nullCell sc = isEmpty (scVersionSet sc)

-- | @a `subsumes` b@: every instance @b@ denotes, @a@ denotes too.
--
-- The two coordinates run in opposite directions. @a@'s version set must be the
-- /wider/ one, but @a@'s pins must be the /weaker/ ones — a submap of @b@'s —
-- because a pin is a constraint, so fewer pins means more instances. (Same
-- direction as 'PubGrub.InstanceSet.memberFlagAssignment', for the same
-- reason.)
--
-- Sufficient, not necessary: @(V, ∅)@ is also covered by
-- @(V, f↦True) ∨ (V, f↦False)@, but that is a property of the disjunction
-- rather than of either cell, and 'pruneCells' does not look for it.
--
-- The pin test comes first deliberately: it is a submap check on maps of at most
-- a handful of flags, while the version-set test is a 'difference' plus an
-- emptiness check, and every 'VersionSet' operation currently round-trips through
-- Cabal's 'Distribution.Types.VersionRange.VersionRange' syntax. 'pruneCells' runs
-- this for every pair it keeps, so the order of the conjunction is not a detail.
subsumes :: SourceCell -> SourceCell -> Bool
subsumes a b =
    scFlags a `Map.isSubmapOf` scFlags b
        && scVersionSet b `isSubsetOf` scVersionSet a

-- | Drop cells that another cell of the same disjunction already covers, and
-- put what survives in a deterministic order.
--
-- Size control, and load-bearing. 'differenceCell' turns one cell into up to
-- @1 + 2·|pins|@ cells, so 'PubGrub.SetOps.difference' multiplies the cell count
-- while the /denotation/ only shrinks: a set denoting two flag assignments was
-- measured holding 40897 cells. Pruning after each operation keeps the count
-- near the number of genuinely distinct pin maps instead.
--
-- Sound whatever the input order, since a cell is only dropped when a surviving
-- cell denotes everything it does. The order matters only for how much gets
-- pruned in one pass: cells are visited widest-first, and a superset can sort
-- below a subset only when the two version sets share a reach and a start (see
-- the 'Ord' on 'PubGrub.VersionSet.VersionSet'), which is why a kept cell is
-- also re-checked against the newcomer.
pruneCells :: [SourceCell] -> [SourceCell]
pruneCells = foldl' keep [] . sortOn Down . filter (not . nullCell)
  where
    keep kept c
        | any (`subsumes` c) kept = kept
        | otherwise               = c : filter (not . subsumes c) kept

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

-- | Complete a cell's pins into a total assignment over the flags a version
-- declares, given those flags and their defaults: the pinned value where the
-- cell gives one, the declared default where it does not. This is the rule every
-- provider needs when turning an offered cell into a candidate instance, so it
-- lives here rather than being reinvented per provider.
--
-- A 'NotDeclared' pin yields no value, so the default is used and the resulting
-- instance then fails /that cell's/ membership test — correctly, since a version
-- which declares the flag can never satisfy a cell demanding it not be declared.
-- Callers test membership against the whole offered set, so another cell may
-- still admit the candidate; that is why this returns an assignment rather than
-- refusing.
assignmentFrom :: [(FlagName, Bool)] -> SourceCell -> FlagAssignment
assignmentFrom declared sc =
    mkFlagAssignment [(f, fromMaybe def (pinnedValue f)) | (f, def) <- declared]
  where
    pinnedValue f = case Map.lookup f (scFlags sc) of
        Just (PinnedTo b) -> Just b
        Just NotDeclared  -> Nothing
        Nothing           -> Nothing

-- | The cell of one version range, with these flags pinned. Flags absent from
-- the map are left __free__, not pinned 'NotDeclared', so how much the cell
-- denotes is decided entirely by how much the caller pins:
--
--  * a __total__ assignment over the version's declared flags gives one instance.
--    That is 'PubGrub.InstanceSet.singletonBuildSource', and the totality is the
--    caller's obligation: an under-pinned cell silently denotes many instances
--    (see 'PubGrub.InstanceSet.singletonInstance').
--  * a __guard's__ pins give every instance of the version satisfying that guard,
--    whatever the flags the guard never mentions are set to. That is what keeps
--    irrelevant flags out of a depender term.
--
-- Leaving unmentioned flags free is exact in both cases as long as the range holds
-- __one existing release__, since then there is no release in the cell whose
-- declared flags differ. That is why the provider passes a release's
-- 'PubGrub.VersionSet.halfOpenVersionSet' slot rather than the whole declared
-- range: the slot reaches up to the next release in the index, so it contains the
-- same single release a singleton would, while still touching its neighbour.
-- 'NotDeclared' becomes necessary only once a cell spans releases that disagree
-- about which flags exist.
pinnedCell :: VersionSet -> Map FlagName Bool -> SourceCell
pinnedCell vs pins =
    SourceCell
        { scVersionSet = vs
        , scFlags = PinnedTo <$> pins
        }

instance Pretty SourceCell where
    pretty sc =
        T.unwords (pretty (scVersionSet sc) : map pin (Map.toList (scFlags sc)))
      where
        -- 'NotDeclared' spells itself out: it appears in explanations, where a
        -- terse marker would read as an internal detail rather than as a fact
        -- about the package.
        pin (f, PinnedTo True)  = T.pack ('+' : unFlagName f)
        pin (f, PinnedTo False) = T.pack ('-' : unFlagName f)
        pin (f, NotDeclared)    = T.pack ("(no " ++ unFlagName f ++ " flag)")
