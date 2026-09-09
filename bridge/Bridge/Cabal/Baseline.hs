-- | cabal's own modular solver, driven from /our/ index: the baseline the
-- PubGrub implementation is measured against.
--
-- Both solvers are handed the same installed database
-- ('Bridge.Cabal.InstalledPkg.getInstalledPackageIndex') and the same source
-- releases ('Bridge.Hackage.IndexHandle'), so a difference in verdict, time or
-- memory is a difference between the solvers and not between two ways of
-- reading Hackage.
--
-- __No @cabal-install@ dependency.__ Everything here comes from
-- @cabal-install-solver@ and @Cabal@. What the @Distribution.Client.*@ modules
-- would provide is done here instead:
--
--  * index acquisition, which must be ours, or the comparison would be between
--    index readers;
--  * @UserConstraint@ and @userToPackageConstraint@, CLI syntax we do not parse:
--    'targetConstraints' builds the 'PackageConstraint' values directly;
--  * @PackagePreference@ and @PackagesPreferenceDefault@, skipped by building
--    'PackagePreferences' directly;
--  * @defaultSolverConfig@, restated as 'defaultSolverConfig'. The setup-deps
--    Cabal bounds wait until setup dependencies are modelled.
--
-- The entry point is 'modularResolver', because it runs
-- 'Distribution.Solver.Modular.IndexConversion.convPIs', assembles the
-- constraint map and converts the solver's log into a 'Progress' itself.
-- Calling @Distribution.Solver.Modular.Solver.solve@ directly would mean
-- reproducing all three.
module Bridge.Cabal.Baseline
    ( -- * Running it
      solveWithCabal
    , outcome

      -- * The inputs, each of which has to be built rather than defaulted
    , sourcePackageIndex
    , defaultSolverConfig
    , targetConstraints
    , nonReinstallableConstraints
    , preferences
    ) where

import           Bridge.Hackage                   (IndexHandle (..), ParseError)
import           Data.Word                        (Word32)
import           Bridge.Installed                 (nonReinstallablePackages)
import qualified Data.Map.Strict                  as Map
import           Data.Set                         (Set)
import qualified Data.Set                         as Set
import           Distribution.Compiler            (CompilerInfo)
import           Distribution.Pretty              (prettyShow)
import           Distribution.Simple.PackageIndex (InstalledPackageIndex)
import           Distribution.Types.GenericPackageDescription (GenericPackageDescription)
import           Distribution.Solver.Modular      (PruneAfterFirstSuccess (..),
                                                   SolverConfig (..),
                                                   modularResolver)
import           Distribution.Solver.Types.ConstraintSource (ConstraintSource (..))
import           Distribution.Solver.Types.InstalledPreference (InstalledPreference (..))
import           Distribution.Solver.Types.LabeledPackageConstraint (LabeledPackageConstraint (..))
import           Distribution.Solver.Types.PackageConstraint (ConstraintScope (..),
                                                              PackageConstraint (..),
                                                              PackageProperty (..),
                                                              scopeToplevel)
import           Distribution.Solver.Types.PackageIndex (PackageIndex)
import           Distribution.Solver.Types.PkgConfigDb (PkgConfigDb)
import qualified Distribution.Solver.Types.PackageIndex as SolverIndex
import           Distribution.Solver.Types.PackagePreferences (PackagePreferences (..))
import           Distribution.Solver.Types.Progress (Progress, foldProgress)
import           Distribution.Solver.Types.ResolverPackage (ResolverPackage (..))
import           Distribution.Solver.Types.Settings (AvoidReinstalls (..),
                                                     CountConflicts (..),
                                                     EnableBackjumping (..),
                                                     FineGrainedConflicts (..),
                                                     IndependentGoals (..),
                                                     MinimizeConflictSet (..),
                                                     OnlyConstrained (..),
                                                     ReorderGoals (..),
                                                     ShadowPkgs (..),
                                                     SolveExecutables (..),
                                                     StrongFlags (..))
import           Distribution.Solver.Types.SourcePackage (SourcePackage (..))
import           Distribution.System              (Platform)
import           Distribution.Types.PackageId    (PackageIdentifier (..))
import           Distribution.Types.PackageName  (PackageName)
import           Distribution.Types.Version      (Version)
import           Distribution.Types.VersionRange (VersionRange)
import qualified Distribution.Verbosity          as Verbosity
import           System.IO.Unsafe                (unsafeInterleaveIO)

-- | Run cabal's solver for these targets. The result is its 'Progress': a stream
-- of log lines ending in either its failure message or a plan.
--
-- Nothing is forced here, which is deliberate — see 'sourcePackageIndex' on why
-- the caller decides how much of the index gets parsed.
solveWithCabal
    :: SolverConfig
    -> Platform
    -> CompilerInfo
    -> InstalledPackageIndex
    -> Maybe PkgConfigDb
    -- ^ what @pkg-config@ reports on this machine, from
    -- 'Bridge.Provider.wPkgConfig'. 'Nothing' is /not/ neutral: cabal takes it to
    -- mean that no @pkg-config@ executable exists and rejects every
    -- @pkgconfig-depends@, which pushes cabal into automatic flag flips our solver
    -- never makes.
    -> PackageIndex (SourcePackage ())
    -> [(PackageName, VersionRange)]
    -- ^ the targets, with the range each is constrained to
    -> Progress String String [ResolverPackage ()]
solveWithCabal config platform cinfo installed pkgConfig source targets =
    modularResolver
        config
        platform
        cinfo
        installed
        source
        pkgConfig
        (preferences targetNames)
        (targetConstraints targets ++ nonReinstallableConstraints)
        targetNames
  where
    targetNames = Set.fromList (map fst targets)

-- | Fold a run down to how many log lines it produced and what it came to —
-- cabal's own failure message, which is the text the explanation deliverable
-- compares against, or a plan.
--
-- The lines are counted rather than kept: the log of a hard solve is large, and
-- holding it while the solver runs would put the log in the memory measurement.
outcome :: Progress String String a -> (Int, Either String a)
outcome = foldProgress (\_ (n, r) -> (n + 1, r)) (\e -> (0, Left e)) (\a -> (0, Right a))

-- | Every release in our index as a cabal @SourcePackage@, with its @.cabal@
-- parsed __on demand__.
--
-- The laziness is what makes the run possible: the index holds ~152k releases,
-- and cabal's solver inspects only the ones it reaches. 'srcpkgDescription' is
-- documented lazy for this reason, and 'Distribution.Solver.Modular.Index.Index'
-- keeps its @PInfo@ values lazy too, so a description is parsed only when the
-- solver looks at that version. The spine is forced: one 'SourcePackage' record
-- per release exists before the solve starts. That is cabal's index model, and
-- its cost is worth reporting separately from the solve.
--
-- 'unsafeInterleaveIO' defers each read, so it must happen inside the caller's
-- 'Bridge.Hackage.withHackageIndex' bracket. Forcing a description after the
-- bracket closes is a use-after-free, and the only guard is that this index is
-- consumed by a solve that runs inside the bracket.
--
-- A release whose @.cabal@ does not parse throws when its description is
-- forced. Our own provider skips such a release with a warning
-- (@docs\/flags-semantics.md@ §1.5); a @SourcePackage@ has no way to say "not
-- really here", so in that one case the two solvers disagree about the
-- universe, loudly rather than silently.
sourcePackageIndex :: IndexHandle -> IO (PackageIndex (SourcePackage ()))
sourcePackageIndex handle =
    SolverIndex.fromList
        <$> sequence
            [ sourcePackage pn v blk
            | (pn, versions) <- Map.toList (ihVersions handle)
            , v <- Set.toList versions
            , Just blk <- [ihBlockOf handle pn v]
            ]
  where
    -- The block is looked up now and the deferred read is given it, so the
    -- deferred read closes over nothing but the open index. Deferring the
    -- lookup instead kept the whole version map alive through every one of
    -- these ~150k thunks for the length of cabal's solve: 22 MB of cabal's
    -- peak residency on @vector@, charged to the wrong solver.
    sourcePackage pn v blk = do
        description <- unsafeInterleaveIO (parsed pn v blk)
        pure
            SourcePackage
                { srcpkgPackageId = PackageIdentifier pn v
                , srcpkgDescription = description
                , srcpkgSource = ()
                , srcpkgDescrOverride = Nothing
                }

    -- Selected once, here, so that the thunks capture the reader and not the
    -- handle it came from; capturing the handle is capturing the map.
    readBlock = ihReadBlock handle

    parsed :: PackageName -> Version -> Word32 -> IO GenericPackageDescription
    parsed pn v blk = either (fail . unparseable pn v) pure =<< readBlock pn v blk

    unparseable :: PackageName -> Version -> ParseError -> String
    unparseable pn v err =
        "cabal baseline: "
            ++ prettyShow pn
            ++ "-"
            ++ prettyShow v
            ++ " has an unparseable .cabal, which our own provider skips: "
            ++ show err

-- | cabal-install's solver defaults, restated because they live in
-- @Distribution.Client.Dependency@ (@cabal-install@). Each is a fidelity
-- question for the comparison:
--
--  * @maxBackjumps = Just 4000@ is cabal's documented default (@--max-backjumps@).
--    Our solver has no such limit, which matters for any problem that hits it.
--  * @solveExecutables = True@ makes cabal solve build-tool dependencies, which
--    ours does not, so on a problem where this bites the two are solving
--    different problems. Check before quoting such a case.
--  * @countConflicts@ and @fineGrainedConflicts@ are cabal's conflict-driven
--    heuristics, on by default. They are the closest thing in cabal to PubGrub's
--    conflict resolution, so turning them off would flatter us.
--  * @independentGoals = False@, @shadowPkgs = False@, @strongFlags = False@,
--    @avoidReinstalls = False@, @reorderGoals = False@, @onlyConstrained = None@:
--    all cabal's defaults.
defaultSolverConfig :: SolverConfig
defaultSolverConfig =
    SolverConfig
        { reorderGoals = ReorderGoals False
        , countConflicts = CountConflicts True
        , fineGrainedConflicts = FineGrainedConflicts True
        , minimizeConflictSet = MinimizeConflictSet False
        , independentGoals = IndependentGoals False
        , avoidReinstalls = AvoidReinstalls False
        , shadowPkgs = ShadowPkgs False
        , strongFlags = StrongFlags False
        , onlyConstrained = OnlyConstrainedNone
        , maxBackjumps = Just 4000
        , enableBackjumping = EnableBackjumping True
        , solveExecutables = SolveExecutables True
        , goalOrder = Nothing
        , solverVerbosity = Verbosity.normal
        , pruneAfterFirstSuccess = PruneAfterFirstSuccess False
        }

-- | The targets as constraints. A target @aeson '<2'@ is a top-level version
-- constraint on @aeson@, which is what our own driver's range argument means.
targetConstraints :: [(PackageName, VersionRange)] -> [LabeledPackageConstraint]
targetConstraints targets =
    [ LabeledPackageConstraint
        (PackageConstraint (scopeToplevel pn) (PackagePropertyVersion range))
        ConstraintSourceUserTarget
    | (pn, range) <- targets
    ]

-- | Packages that may never be built from source, as constraints.
--
-- Without them the baseline is __more permissive than cabal-install__: on
-- @aeson '<2'@ it planned to build @base-4.15.1.0@, @ghc-prim-0.7.0@ and
-- @ghc-bignum-1.3@ from Hackage, none of which can be rebuilt against a given
-- GHC. That changes verdicts, not just plans: a problem whose only solution
-- needs an older @base@ has none once @base@ is pinned.
--
-- The shape is cabal-install's own: 'ScopeAnyQualifier' binds in /every/
-- qualified domain (the library's and @Setup.hs@'s alike), and
-- 'PackagePropertyInstalled' means "an installed instance or nothing".
--
-- The names come from 'Bridge.Installed.nonReinstallablePackages', which our own
-- provider reads too, so the two solvers cannot drift apart on which packages
-- are buildable.
nonReinstallableConstraints :: [LabeledPackageConstraint]
nonReinstallableConstraints =
    [ LabeledPackageConstraint
        (PackageConstraint (ScopeAnyQualifier pn) PackagePropertyInstalled)
        ConstraintSourceNonReinstallablePackage
    | pn <- Set.toList nonReinstallablePackages
    ]

-- | Prefer the newest release of a target and the installed unit of anything
-- else: cabal's @PreferLatestForSelected@ default, and the closest match to our
-- own rule (strictly prefer installed, otherwise the newest source release).
--
-- No version preferences and no stanza preferences: neither solver reads
-- @preferred-versions@ yet, and neither builds test suites.
preferences :: Set PackageName -> PackageName -> PackagePreferences
preferences targets pn =
    PackagePreferences
        []
        (if pn `Set.member` targets then PreferLatest else PreferInstalled)
        []
