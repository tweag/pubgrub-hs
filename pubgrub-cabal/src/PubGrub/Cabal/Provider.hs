-- | The cabal provider rule: how a package's instances are enumerated and what
-- committing to one entails, stated as incompatibilities.
--
-- A package's instances are its installed units ('UsePreInstalled', from the
-- compiler's package database) together with its source releases (lazily,
-- through a 'ReleaseSource'). The choice is __strict prefer-installed__: if
-- the offered set admits an installed unit, commit to the newest such unit and
-- pin its whole transitive closure to the exact units it was built against;
-- otherwise pick the newest source release that can be built here and state
-- its dependencies, each widened to the installed units and source releases
-- its range admits.
--
-- 'mkExpand' takes its world as arguments, an installed database and a
-- 'ReleaseSource', so the same rule runs over an in-memory world as over
-- Hackage. Nothing here reads an index or a package database, and nothing here
-- needs more of the cabal ecosystem than @Cabal-syntax@: opening the index and
-- the compiler's world, and reading a release out of them, is the caller's
-- business.
module PubGrub.Cabal.Provider
    ( -- * The rule
      mkExpand
    , Preference
    , noPreference
    , widenTo
    , constrainTo

      -- * What it is given
    , ReleaseSource (..)
    , Release (..)
    , releaseOf
    , releaseOfStored
    , ParseError (..)

      -- * Slots
    , Slot
    , withSlots
    , slotRange
    , spanSlot
    , slotInstances
    ) where

import           Colog.Core                     (LogAction, (<&))
import           Control.Exception              (SomeException)
import           Data.List                      (find, sortOn)
import           Data.List.NonEmpty             (NonEmpty)
import qualified Data.List.NonEmpty             as NE
import qualified Data.Map.Strict                as Map
import           Data.Map.Strict                (Map)
import           Data.Maybe                     (catMaybes, fromMaybe,
                                                 listToMaybe)
import           Data.Ord                       (Down (..))
import           Data.Set                       (Set)
import qualified Data.Set                       as Set
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Distribution.Parsec.Error      (PError)
import           Distribution.Pretty            (prettyShow)
import           Distribution.Types.Condition   (Condition (..))
import           Distribution.Types.Dependency  (Dependency, depPkgName,
                                                 depVerRange)
import           Distribution.Types.Flag        (FlagName)
import           Distribution.Types.PackageName (PackageName)
import qualified Distribution.Types.Version     as Cabal
import           PubGrub.Cabal                  (Cabal, UnbuildableReason,
                                                 constraint, declaresFlag,
                                                 fromDependency, onlyInstalled,
                                                 unbuildable)
import           Distribution.Compiler          (CompilerInfo)
import           Distribution.System            (Platform)
import           Distribution.Types.GenericPackageDescription (GenericPackageDescription)
import           PubGrub.Cabal.Flatten          (FlagModel (..), Guard,
                                                 GuardedDeps, GuardedTools,
                                                 PkgConfigPresent, Stanzas,
                                                 StoredRelease (..),
                                                 componentDepsStored,
                                                 componentToolsStored,
                                                 expandGuard, toStored,
                                                 unbuildableStored)
import           PubGrub.Cabal.Installed        (InstalledDb (..),
                                                 InstalledEdge (..),
                                                 closureEdges,
                                                 installedInstancesOf,
                                                 isNonReinstallable,
                                                 toPreInstalled)
import           PubGrub.Incompatibility        (Incompatibility)
import           PubGrub.Cabal.PreInstalled     (PreInstalledPackage (..))
import           PubGrub.Cabal.InstanceSet            (HasVersion (..), Instance (..),
                                                 InstanceSet (..),
                                                 memberInstance,
                                                 singletonInstance,
                                                 sourceInstances)
import           PubGrub.Pretty                 (Pretty (pretty))
import           PubGrub.Cabal.Value                  (Value (..), ValueSet (..),
                                                 instanceSet, memberBool)
import           PubGrub.Cabal.Variable               (Flag (..), Var (..))
import           PubGrub.Cabal.Version                (Version)
import           PubGrub.Cabal.VersionSet             (VersionSet, contains)
import qualified PubGrub.Cabal.VersionSet             as VersionSet

-- | A @.cabal@ file that could not be read: Cabal-syntax's own errors, with the
-- @cabal-version@ it managed to read, or whatever the source threw on the way to
-- the bytes.
--
-- 'mkExpand' warns and skips a release that answers with one; the release is then
-- outside the universe the solve runs over.
data ParseError
    = ParseError (Maybe Cabal.Version) (NonEmpty PError)
    | ParseException SomeException
    deriving Show

data Release = Release
    { relAutomatic :: [Flag]
    -- ^ the automatic flags, each a solver variable of its own. Empty under
    -- 'FixedFlags', where every flag is treated as manual.
    , relGuarded   :: GuardedDeps
    -- ^ the dependencies as flag-guarded groups; a guard mentions automatic
    -- flags only, everything else having been resolved
    , relUnbuildable :: [(Guard, NonEmpty UnbuildableReason)]
    -- ^ why, and under which flags, this release's library cannot be built
    -- here: @buildable@ and @pkgconfig-depends@ resolved against the machine,
    -- one entry per unusable library node with its guard
    -- (@PubGrub.Cabal.Flatten.unbuildableStored@). Empty means it can be built
    -- under every assignment. An entry whose guard holds however the flags
    -- fall, such as @Lit True@, rules the release out; any other rules out the
    -- flag values that reach it, and the rule states it as a guarded unit
    -- clause when it offers the release.
    , relTools :: GuardedTools
    -- ^ the build tools, flag-guarded. The rule does not read them: a planner
    -- solves the tools in a namespace of their own, from this list
    -- ('PubGrub.Cabal.Flatten.GuardedTools').
    , relSetup :: [Dependency]
    -- ^ the @setup-depends@, likewise ('PubGrub.Cabal.Flatten.setupDeps')
    }

-- | The reduction of a parsed description to what the rule reads: the one
-- route from a @.cabal@ file to a 'Release', for any tool that holds the
-- descriptions itself and builds a 'ReleaseSource' out of them.
--
-- The machine is an argument and never read here: the platform and compiler
-- resolve the @os@\/@arch@\/@impl@ conditions, and the @pkg-config@ predicate
-- decides buildability. The flag model decides which flags stay symbolic:
-- under 'FixedFlags' every flag is its declared default and 'relAutomatic' is
-- empty; under 'FlagPackages' each automatic flag is a solver variable and the
-- guards name it. The 'Stanzas' decide whether the release's test suites and
-- benchmarks count — 'PubGrub.Cabal.Flatten.noStanzas' for a dependency, and a
-- planner's choice for a local package. A caller that keeps releases in their
-- pre-environment form goes through 'releaseOfStored' instead, which is the
-- same function over that form.
releaseOf
    :: FlagModel
    -> Stanzas
    -> Platform
    -> CompilerInfo
    -> PkgConfigPresent
    -> GenericPackageDescription
    -> Release
releaseOf model stanzas platform compiler present =
    releaseOfStored model stanzas platform compiler present . toStored

-- | 'releaseOf' over the pre-environment form a derived index keeps
-- ('PubGrub.Cabal.Flatten.StoredRelease'). Everything a 'Release' holds is
-- independent of the flag assignment, so it is derived once per release and
-- reused for every assignment tried against it.
releaseOfStored
    :: FlagModel
    -> Stanzas
    -> Platform
    -> CompilerInfo
    -> PkgConfigPresent
    -> StoredRelease
    -> Release
releaseOfStored model stanzas platform compiler present sr =
    Release
        { relAutomatic = case model of
            FixedFlags   -> []
            FlagPackages -> [Flag f d | (f, d) <- srFlags sr, f `notElem` srManual sr]
        , relGuarded = componentDepsStored model stanzas platform compiler sr
        , relUnbuildable = unbuildableStored model present platform compiler sr
        , relTools = componentToolsStored model stanzas platform compiler sr
        , relSetup = srSetup sr
        }

-- | What a solve prefers, when the offered set admits it: for a package, a
-- version and an assignment of its automatic flags. It is tried before the
-- rule's own order (installed first, then newest). A preference chooses a value
-- and is never an incompatibility, so it cannot make a solve fail.
--
-- The main solve passes 'noPreference'. A solve for a build tool's or a
-- @Setup.hs@'s namespace passes the main plan's choices, so that where the two
-- can agree on a version and its flags they do, and one build serves both; where
-- the tool needs another version it gets it, without touching the main plan. A
-- flag the preference does not name is offered at its declared default.
type Preference = PackageName -> Maybe (Version, Map FlagName Bool)

noPreference :: Preference
noPreference = const Nothing


-- | Where a package's /source releases/ come from: which versions exist, and how
-- to read one. These are the only two questions 'mkExpand' asks about the
-- source side; how a @.cabal@ file is found and reduced to a 'Release' is the
-- caller's business.
--
-- Installed units are deliberately /not/ here. They are not releases: they have
-- no flags to assign and no @.cabal@ to read, and they come from the compiler
-- rather than an index. 'mkExpand' takes them as a separate argument.
data ReleaseSource m = ReleaseSource
    { rsVersionsOf  :: PackageName -> Set Version
    -- ^ every version of this package the source has. A 'Set', so that "ordered"
    -- and "no duplicates" are properties of the answer rather than promises each
    -- caller has to keep — 'withSlots' asks which release comes /next/, and gets a
    -- silently wrong answer from an unordered list.
    , rsReadRelease :: PackageName -> Version -> m (Either ParseError Release)
    -- ^ the reduced form of one release. Only ever called for versions
    -- 'rsVersionsOf' reported.
    }

-- | The provider's @expand@: the whole candidate-selection and emission rule, over
-- an installed world and a source world.
--
-- The constraint is 'Monad' plus a text 'LogAction' for its one warning (an
-- unparseable release), and __not__ 'MonadIO': reading a release runs in
-- whatever @m@ the 'ReleaseSource' was built in, so an in-memory world can
-- drive the rule purely, and a tool with its own logging hands over an action
-- rather than adopting a monad.
--
-- Three kinds of question arrive:
--
--  * __a flag__ ('FlagVar'): answered from the variable alone. The declared
--    default rides in the flag's identity ('PubGrub.Cabal.Variable.Flag'), so it is
--    offered first where the set admits it and the other value otherwise.
--    Nothing is reported: the clause that made the flag a goal, and the guarded
--    dependencies that consult it, went out with its owner.
--  * __a package__ ('PackageVar') whose set admits an installed unit: strict
--    prefer-installed, newest such unit, with the unit's whole transitive closure
--    pinned to the exact units it was built against.
--  * __a package__ otherwise: the newest source release the set admits that can
--    be built here, with its dependencies, each under the flags it is guarded
--    by, and one 'declaresFlag' clause per automatic flag it declares.
mkExpand
    :: forall m
     . Monad m
    => LogAction m Text
    -> Preference
    -> InstalledDb
    -> ReleaseSource m
    -> Var
    -> ValueSet
    -> m (Maybe Value, [Incompatibility Cabal])
mkExpand logA preference installedDb source = expand'
  where
    expand' :: Var -> ValueSet -> m (Maybe Value, [Incompatibility Cabal])
    expand' (FlagVar p (Flag f dflt)) set =
        let first = fromMaybe dflt (preference p >>= Map.lookup f . snd)
         in pure (listToMaybe [FlagValue b | b <- [first, not first], memberBool b (vsFlags set)], [])
    expand' (PackageVar pn) set = expandPackage pn (vsInstances set)

    -- The preferred release first, when there is one, the offered set admits it
    -- and the index has it ('Preference'). It goes through the same scan as the
    -- rule, over a list of one, so a preferred release that cannot be built here
    -- states why and falls through to the rule with its facts. A non-reinstallable
    -- package has no source release to prefer.
    expandPackage :: PackageName -> InstanceSet -> m (Maybe Value, [Incompatibility Cabal])
    expandPackage pn range =
        case preference pn of
            Just (v, _)
                | not (isNonReinstallable pn)
                , BuildSource v `memberInstance` range
                , Just slot <- lookup v (withSlots (rsVersionsOf source pn)) -> do
                    (chosen, stated) <- scan pn range [] [(v, slot)]
                    case chosen of
                        Just _  -> pure (chosen, stated)
                        Nothing -> fmap (stated ++) <$> expandByRule pn range
            _ -> expandByRule pn range

    -- An 'InstanceSet' is a symbolic description (a version range plus the
    -- installed units in it), not a container: membership is decidable but it
    -- cannot be enumerated. So enumerate the package's own instances — cheaply,
    -- from the installed db and the index's version map, without parsing any
    -- @.cabal@ — and keep those the offered set admits.
    expandByRule :: PackageName -> InstanceSet -> m (Maybe Value, [Incompatibility Cabal])
    expandByRule pn range = do
        let installedHere = [toPreInstalled u | u <- Map.findWithDefault [] pn (idbByName installedDb)]
            admissible = sortOn (Down . version) (filter (`Set.member` isInstalled range) installedHere)
        case listToMaybe admissible of
            Just chosen -> do
                incs <- consequencesOfUsePreInstalled chosen
                pure (Just (PackageValue (UsePreInstalled chosen)), onlyInstalledFact pn ++ incs)
            -- No admissible installed unit. For most packages that means falling
            -- through to source releases; for a non-reinstallable one there is
            -- nothing at all, because no release of it can be built against this
            -- compiler ('nonReinstallablePackages'). Without this case the solver
            -- would plan to build @base@ from Hackage, which cabal rejects.
            --
            -- The answer is 'Nothing', with the only-installed fact beside it, as
            -- the scan's facts ride out below: incompatibilities are
            -- context-independent, so one need not be about a decided instance.
            -- Without the fact the solver learns only that the range is empty,
            -- and the proof reads "no version for base in >=4.5 && <4.7" when
            -- the reason is that the compiler provides base. The fact replaces a
            -- clause rather than adding one: the solver's @banRest@ subtracts
            -- what the provider stated, and the fact covers every source
            -- instance, so the @noValues@ clause it would have added is empty.
            --
            -- Stating a boot fact changes the search, not only the wording; see
            -- 'onlyInstalledFact' for what stating all of them up front cost.
            Nothing
                | isNonReinstallable pn -> pure (Nothing, onlyInstalledFact pn)
                | otherwise -> scan pn range [] (withSlots (rsVersionsOf source pn))

    -- Releases newest first. One @.cabal@ read per release.
    --
    -- @stated@ accumulates the facts about releases the scan rejects on the
    -- way past. They ride out with whichever release it settles on, and with
    -- the @Nothing@ of an exhausted list, which is why 'expand' returns its
    -- clauses outside the 'Maybe': a range holding nothing but unbuildable
    -- releases is the commonest way a real Hackage package fails to resolve,
    -- and without these facts the report says "no version for hpqtypes in
    -- >=1.13" where cabal says "pkg-config package libpq-any, not found in
    -- the pkg-config database".
    scan :: PackageName -> InstanceSet -> [Incompatibility Cabal] -> [(Version, Slot)] -> m (Maybe Value, [Incompatibility Cabal])
    scan _ _ stated [] = pure (Nothing, reverse stated)
    scan pn range stated ((v, slot):rest) = do
        result <- rsReadRelease source pn v
        case result of
            -- A .cabal that fails to parse: warn and skip. The
            -- release is then outside the universe the solve runs
            -- over, which is why the warning has to be visible.
            Left err -> do
                logA
                    <& T.pack
                        ( "warning: ignoring "
                            ++ prettyShow pn
                            ++ "-"
                            ++ T.unpack (pretty v)
                            ++ " (unparseable .cabal: "
                            ++ show err
                            ++ ")"
                        )
                scan pn range stated rest
            -- A release whose library cannot be built here under any
            -- assignment is not a candidate: its @pkgconfig-depends@
            -- are unsatisfiable on this machine, or it declares
            -- @buildable: False@. Not warned about, because unlike an
            -- unparseable @.cabal@ this is an ordinary fact about the
            -- release, and cabal applies the same rule from the same
            -- pkg-config db.
            --
            -- It is /stated/ rather than skipped
            -- (references/pubgrub.md:475): without the clause the
            -- report reads "no version for p in range" when the
            -- versions exist and cannot be built here. With it, the
            -- proof line names the reason, the module @pkg-config@
            -- could not find, as cabal's own message does.
            --
            -- The clause is over the release's whole slot, and it is
            -- the /unconditional/ verdict: the reasons of every node
            -- whose guard holds under every assignment. A node unusable
            -- only under some flag values does not rule the release
            -- out; it rides out with the release below, as a guarded
            -- unit clause over the flags that reach it.
            Right release | Just why <- NE.nonEmpty (unconditionallyUnbuildable release) ->
                scan pn range (unbuildableFact pn slot why : stated) rest
            Right release
                | not (BuildSource v `memberInstance` range) -> scan pn range stated rest
                | otherwise -> do
                    -- The release is the instance. What rides out with
                    -- it is one 'declaresFlag' clause per automatic flag,
                    -- which makes each flag a goal of its own, and one
                    -- dependency clause per guarded occurrence and
                    -- disjunct of its guard, each naming the flags it
                    -- holds under. A dependency on the package itself is
                    -- dropped (see 'consequencesOfUsePreInstalled').
                    let flags = relAutomatic release
                        declared = [declaresFlag pn (slotInstances slot) f | f <- flags]
                        -- A library node unusable under some flag values:
                        -- the release with those values is banned, one
                        -- clause per disjunct of the guard, as for a
                        -- dependency. The release itself is still
                        -- offered, and propagation turns the clause into
                        -- the other value of the one open flag.
                        unbuildableUnder =
                            catMaybes
                                [ guardedUnbuildable pn slot flags pins why
                                | (guard, why) <- relUnbuildable release
                                , pins <- expandGuard guard
                                , not (Map.null pins)
                                ]
                    incs <-
                        sequence
                            [ guardedInc pn v slot flags guard pins dep
                            | (guard, deps) <- relGuarded release
                            , pins <- expandGuard guard
                            , dep <- deps
                            , depPkgName dep /= pn
                            ]
                    pure (Just (PackageValue (BuildSource v)), reverse stated ++ declared ++ unbuildableUnder ++ catMaybes incs)

    -- For a non-reinstallable package, the standing fact that it can __only__
    -- be an installed unit: no source release of it may be selected, whatever
    -- the range. Stated with the decision that commits to one of its installed
    -- units, and with the 'Nothing' for a range that admits none. Without it,
    -- every range of @base@ that admits only source releases costs a decision,
    -- a provider call answering 'Nothing' and a @noValues@ clause naming that
    -- one range. cabal states the same rule as a constraint up front
    -- (@PackagePropertyInstalled@ on each non-reinstallable package).
    --
    -- Stated on first use rather than up front for all eight packages, which
    -- is where cabal puts it: up front shortened @lens '<4'@'s proof to two
    -- lines but cost @aeson '<2'@ 41% more allocation and 466 more decisions,
    -- because the extra level-0 derivations change which satisfier conflict
    -- resolution picks. That is search-path luck rather than a principle
    -- (decision record decision-0024-the-no-version-rise-explained).
    onlyInstalledFact pn
        | isNonReinstallable pn = [onlyInstalled pn (installedVersionsOf pn) anySourceRelease]
        | otherwise = []

    -- Newest first, one entry per version: two units of one version are one
    -- version to the reader.
    installedVersionsOf pn =
        Set.toDescList
            (Set.fromList [pipVersion (toPreInstalled u) | u <- Map.findWithDefault [] pn (idbByName installedDb)])

    -- The fact that a release cannot be built in this environment: a unit
    -- clause banning every instance of its version __slot__
    -- (references/pubgrub.md:475). Adjacent slots touch, so when 'PubGrub.Store'
    -- merges a run of these the union has no hole between the releases and
    -- reads as the range the spec asks for. The store merges only facts that
    -- give the same reasons, so a release missing @libpq@ and one declaring
    -- @buildable: False@ stay two facts, each with its own sentence.
    unbuildableFact pn slot why = unbuildable pn (slotInstances slot) Map.empty why

    -- The reasons a release cannot be built under /any/ assignment: those of
    -- every entry whose guard has a disjunct with no pins, which is to say
    -- holds however the flags fall. In tree order, as 'unbuildableStored'
    -- gives them.
    unconditionallyUnbuildable release =
        concat
            [ NE.toList why
            | (guard, why) <- relUnbuildable release
            , Map.empty `elem` expandGuard guard
            ]

    -- The ban on a release under one disjunct of a node's guard, over the
    -- release's slot. The pins are looked up among the release's automatic
    -- flags as 'guardedInc' looks its own up, and a pin naming a flag the
    -- release does not declare drops the clause rather than widening it.
    guardedUnbuildable pn slot flags pins why =
        (\g -> unbuildable pn (slotInstances slot) (Map.fromList g) why)
            <$> traverse (asFlagOf flags) (Map.toList pins)

    -- Every source instance of a package: any version.
    anySourceRelease = sourceInstances VersionSet.fullVersionSet

    -- Committing to an installed unit fixes its whole transitive closure, so
    -- hand the solver every edge of that closure at once. Each edge names its
    -- own depender, so each is a genuine direct dependency: propagation chains
    -- through the closure in one fixpoint (rather than learning one hop per
    -- decision), and a report about any edge stays true.
    --
    -- A dependency of @p@ on @p@ itself is dropped rather than stated: on the
    -- source side by the @depPkgName dep /= pn@ filter above, and here by
    -- 'closureEdges', which emits no edge from a unit to itself. It is not a
    -- version constraint. @lens 1.7@ declares a dependency on @lens ==1.7@
    -- because one of its executables is built against its own library: an
    -- /intra-package/ edge, resolved inside the package. Stated as a fact it
    -- says something much stronger and false: that every instance of @lens@
    -- must be @1.7@.
    --
    -- This is cabal's rule. Its solver's @extendOpen@
    -- (@Distribution.Solver.Modular.Builder@) adds no goal and no edge when
    -- @qpn == qpn'@, /except/ for a setup dependency, where it adds a
    -- reverse-dependency edge so that the cycle makes the solver pick a
    -- different instance for the setup script; and @isInternal@
    -- (@Distribution.Solver.Modular.IndexConversion@) drops a
    -- @build-tool-depends@ on the package's own executable. Neither exception
    -- arises here, because this rule states no setup or build-tool
    -- dependencies: they ride in 'Release' for a planner to solve in a
    -- namespace of their own. Qualified goals would not subsume the rule
    -- either: a library dependency inherits its depender's qualifier
    -- (@qualifyDeps@'s @inheritedQ@), so an executable's dependency on its own
    -- library stays a self-dependency under any qualifier scheme.
    consequencesOfUsePreInstalled pip =
            pure
                [ fromDependency
                    fromName
                    (singletonInstance (UsePreInstalled fromPip))
                    Map.empty
                    toName
                    (singletonInstance (UsePreInstalled toPip))
                | InstalledEdge (fromName, fromPip) (toName, toPip) <-
                    closureEdges installedDb (pipUnitId pip)
                ]

    -- One guarded dependency occurrence of the decided release, under one
    -- disjunct of its guard, as an incompatibility over a range of depender
    -- releases: the release's __slot__ ('withSlots'), or a wider span.
    --
    -- references/pubgrub.md:456 asks for identical dependencies of adjacent
    -- versions of the depender to be /one/ incompatibility, "with an inclusive
    -- lower bound of the first version that has the dependency, and an
    -- exclusive upper bound of the first [version] that doesn't". Two mechanisms
    -- deliver it, and both run. 'spanningOccurrenceWith', below, reads the
    -- decided release's neighbours and widens the range while the occurrence
    -- is identical. 'PubGrub.Store' separately unions the depender terms of two
    -- facts that agree about the dependee and the guard, as they arrive, and
    -- slots make that union free: adjacent slots /touch/, so it is one
    -- contiguous interval rather than two with a hole between.
    --
    -- The walk is affordable because a neighbour read is a decode from the
    -- derived index rather than a parse (0.073 ms against 2.007 ms). It costs
    -- @pandoc@ 22.6 → 33.1 MB of residency and under 1% of allocation;
    -- docs/collapsing.md has the trade, and the ways to walk less if
    -- read-dominated problems ever matter more.
    --
    -- The guard's pins name flags; each is looked up among the release's
    -- automatic flags to recover its declaration. A pin naming a flag the
    -- release does not declare as automatic cannot occur, since manual and
    -- undeclared flags are resolved before a guard reaches here. If it did,
    -- the disjunct is dropped rather than stated with a widened antecedent,
    -- which would be the unsound direction.
    guardedInc pn v slot flags guard pins dep =
        case traverse (asFlagOf flags) (Map.toList pins) of
            Nothing -> pure Nothing
            Just g -> do
                dependers <- spanningOccurrenceWith (sameFlags guard flags) pn v slot guard dep
                pure . Just $
                    fromDependency
                        pn
                        (slotInstances dependers)
                        (Map.fromList g)
                        (depPkgName dep)
                        (widen (depPkgName dep) (VersionSet.fromVersionRange (depVerRange dep)))

    -- A pin by flag name, as its declaration among the release's automatic flags.
    asFlagOf flags (name, b) = (\f -> (f, b)) <$> find ((== name) . flagName) flags

    -- A neighbour spanned under a guard must declare the same automatic flags with
    -- the same defaults: the flag variables are named by both, so a neighbour that
    -- changed a default has different variables and must not be spanned. An
    -- unconditional occurrence does not care.
    sameFlags (Lit True) _ _ = True
    sameFlags _ flags neighbour = relAutomatic neighbour == flags

    -- The range to name a release's neighbours by: walk out from @v@ in both
    -- directions while each neighbour carries this same occurrence, then take
    -- the half-open range from the lowest such release up to the first release
    -- above the highest. This is references/pubgrub.md:456 done where the spec
    -- asks for it, at generation time, rather than left to 'PubGrub.Store' to
    -- rebuild one expanded release at a time.
    --
    -- "The same occurrence" is compared per /dependency/, not per group: a
    -- neighbour qualifies when any of its guarded groups has this guard and
    -- contains this exact 'Dependency'. Comparing whole groups would refuse to
    -- merge two releases that differ in something unrelated.
    --
    -- Requiring the guard to be __identical__ keeps this sound on the flag
    -- axis: every release in the span declares the flags the guard mentions,
    -- since one that did not could not have produced that guard; and @admit@
    -- requires the same defaults as well ('sameFlags').
    --
    -- Each neighbour tried costs a release read, so the walk is only as cheap
    -- as the 'ReleaseSource' makes a read. As a parse (2.0 ms and ~7.7 MB each)
    -- it took @pandoc@, a problem with a single conflict, from 167 reads to
    -- 2834 and from 22.9 MB of residency to 81.0 MB (docs/collapsing.md).
    spanningOccurrenceWith admit pn v slot guard dep = do
        lo <- walk Set.lookupLT v
        hi <- walk Set.lookupGT v
        pure $ case (lo, hi) of
            -- Nothing on either side carried it: the release's own slot.
            (l, h) | l == v && h == v -> slot
            (l, h) -> spanSlot (slotRange releases l (Set.lookupGT h releases))
      where
        releases = rsVersionsOf source pn

        -- The furthest release in one direction still carrying the occurrence.
        walk step from = case step from releases of
            Nothing -> pure from
            Just w -> do
                result <- rsReadRelease source pn w
                case result of
                    -- An unparseable neighbour stops the walk rather than being
                    -- stepped over: we cannot claim a fact about a release we cannot
                    -- read, and widening across it would do exactly that.
                    Right neighbour | carries neighbour, admit neighbour -> walk step w
                    _ -> pure from

        carries neighbour =
            any (\(g, ds) -> g == guard && dep `elem` ds) (relGuarded neighbour)

    widen = widenTo installedDb

-- | Widen a version range into an instance set: a dependency's declared range, or
-- a target's.
--
-- The installed side is a set of units, because the compiler's package
-- database is small and fully known. The source side is the declared range
-- itself rather than one entry per in-range version, so its size does not
-- grow with the number of releases on Hackage, and the range survives into the
-- incompatibility: a conflict report can say @>=1.0 && <2@ instead of
-- enumerating versions.
--
-- This admits versions the index does not have. That is harmless: the set
-- algebra never needs the universe of instances, and 'mkExpand' is the only
-- place the index is consulted, so an unsatisfiable dependency surfaces as
-- 'Nothing' from the provider rather than as an empty widening.
widenTo :: InstalledDb -> PackageName -> VersionSet -> InstanceSet
widenTo installedDb d vs =
    InstanceSet
        { isInstalled =
            Set.fromList
                [ pip
                | UsePreInstalled pip <- installedInstancesOf installedDb d
                , contains vs (version pip)
                ]
        , isSource = vs
        }

-- | A constraint seed over a package: if @p@ is in the plan, it is one of
-- @allowed@. The complement the clause bans is computed here because only this
-- side knows the package's universe: every installed unit of @p@ the compiler
-- has, and every source version.
--
-- Two callers, two shapes of @allowed@: a range from @--constraint@ or a
-- @constraints:@ stanza is widened with 'widenTo', so an installed unit in the
-- range stays admissible; a lock entry held at its version is
-- @'sourceInstances' (singleton v)@, which bans the installed units too, since
-- the lock recorded a source package.
constrainTo :: InstalledDb -> PackageName -> InstanceSet -> Incompatibility Cabal
constrainTo installedDb p allowed =
    constraint (PackageVar p) (instanceSet allowed) (instanceSet forbidden)
  where
    forbidden =
        InstanceSet
            { isInstalled =
                Set.fromList [pip | UsePreInstalled pip <- installedInstancesOf installedDb p]
                    `Set.difference` isInstalled allowed
            , isSource = VersionSet.complementVersionSet (isSource allowed)
            }

-- | Pair each release with its __version slot__: the half-open range reaching from
-- it up to the next release that exists, and unbounded for the newest. Newest
-- first, which is the order candidates are tried in.
--
-- Slots let a depender term be a range rather than a point at no cost in
-- @.cabal@ reads. A slot contains exactly one existing release, so a term over
-- @slot(v)@ denotes the same instances as one over @{v}@ among anything that can
-- be offered: the claim is about @v@ alone, and nothing is asserted about a
-- release that was not read. What the slot adds is that adjacent slots /touch/,
-- so 'PubGrub.Cabal.VersionSet.unionVersionSet' coalesces them and a difference
-- never leaves an empty hole between releases behind.
--
-- The bound is the next release in the __index__, not the next /usable/ one: a
-- skipped release (unparseable, say) still has dependencies of its own, so
-- widening across it would assert this release's dependencies of it.
--
-- It takes a 'Set' rather than a list because \"the next release that exists\"
-- is a question about the whole ordered collection, and a list would make its
-- order an unchecked precondition.
withSlots :: Set Version -> [(Version, Slot)]
withSlots releases =
    [ (v, Slot (slotRange releases v (Set.lookupGT v releases)))
    | v <- Set.toDescList releases
    ]

-- | The range from release @lo@ up to, and not including, the next release @hi@,
-- in the given set of releases. The package's __first__ release has no lower
-- bound at all, as the PubGrub algorithm omits the lower bound of a dependency
-- the first published version already has. Nothing is published below it, so
-- the two ranges hold the same releases; what differs is the complement.
-- Banning @>=0.1 && <2.4@ leaves @<0.1@ for the solver to discover empty and to
-- print as @no version for lens in <0.1@; banning @<2.4@ leaves nothing, and
-- the proof reads @lens <2.4@.
slotRange :: Set Version -> Version -> Maybe Version -> VersionSet
slotRange releases lo hi
    | Set.lookupMin releases == Just lo = VersionSet.belowVersionSet hi
    | otherwise = VersionSet.halfOpenVersionSet lo hi

-- | One release's slot, as a type of its own.
--
-- The distinction it carries is invisible at the level of ranges. The PubGrub
-- algorithm asks for identical dependencies of adjacent versions to be one
-- incompatibility over the run, not one per version: a depender term over a
-- __single version__ is the per-version form it rules out, and a depender term
-- over a __slot__ is what lets adjacent ones join into the run. Both are
-- intervals, so only a type stops one being passed where the other belongs.
--
-- The constructor is not exported, and only 'withSlots' and 'spanSlot' apply
-- it; 'slotInstances' is the only way back out.
newtype Slot = Slot VersionSet

-- | A slot spanning a __run of adjacent releases__ that all carry the same
-- dependency occurrence: the one incompatibility over the run that the PubGrub
-- algorithm asks for.
--
-- It is a 'Slot' for the same reason one release's slot is: the invariant the
-- type protects is that a depender term is never a single version, and a span
-- satisfies that more strongly. The caller establishes the run, by reading
-- every release in it; within this module, 'mkExpand' does so when it widens a
-- dependency's depender range.
spanSlot :: VersionSet -> Slot
spanSlot = Slot

-- | Every source instance of a slot: the depender term of a dependency fact, and
-- the term an unbuildable fact bans.
slotInstances :: Slot -> InstanceSet
slotInstances (Slot vs) = sourceInstances vs
