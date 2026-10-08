{-# LANGUAGE LambdaCase #-}

-- | Extract a GenericPackageDescription's dependencies as a function of its
-- flag assignment, without Cabal's @finalizePD@ (which also does dependency
-- resolution and flag defaulting we don't want).
--
-- The conditional dependency tree is flattened to 'GuardedDeps' — a list of
-- @(flag guard, deps)@ groups — with the fixed environment (operating system,
-- architecture, compiler) already resolved and only flag conditions left
-- symbolic. 'depsAt' then evaluates those guards at a concrete flag assignment.
--
-- == What a /guard/ is
--
-- A /guard/ is the flag condition attached to a group of dependencies: the
-- @if@ of a @.cabal@ file, after the parts that do not depend on flags have been
-- evaluated away. Given this library stanza, on a non-Windows platform:
--
-- > library
-- >   build-depends: base >=4.14, containers
-- >
-- >   if flag(simd)
-- >     build-depends: simd-utils ==0.3
-- >   else
-- >     build-depends: fallback-impl >=1
-- >
-- >   if os(windows) && flag(fast)
-- >     build-depends: win-fast-io
--
-- 'componentDeps' yields these groups, whose first components are the guards:
--
-- > (Lit True,          [base >=4.14, containers])
-- > (Var simd,          [simd-utils ==0.3])
-- > (CNot (Var simd),   [fallback-impl >=1])
--
-- and a fourth, @(Lit False, [win-fast-io])@: the @os(windows)@ block keeps a
-- guard that no flag assignment satisfies, so it never contributes.
--
-- Four properties, each relied on elsewhere:
--
-- * /Flags only/. @envConfVar@ resolves operating system, architecture and
--   compiler to a concrete boolean and leaves only @PackageFlag@ symbolic, so a
--   guard is always a formula over flag /names/.
-- * /A formula, not a flag/. @flag(a) && !flag(b)@ is one guard mentioning two
--   flags. Do not picture one flag per guard.
-- * /Accumulated down the tree/. @flattenComponent@ starts at @Lit True@ and
--   pushes conditions down: the @if@ branch gets @guard \`cAnd\` cond@, the
--   @else@ branch @guard \`cAnd\` cNot cond@. A dependency nested two levels deep
--   carries both conditions conjoined; nesting produces a longer formula, not
--   nested structure.
-- * /Per release, not per package/. A guard comes from one @.cabal@ file, so it
--   mentions only flags /that/ release declares. This is why a pin derived from a
--   guard under a known version is two-valued — the flag is known to exist, so
--   @NotDeclared@ cannot arise (@docs\/decision-semantics.md@ §7).
--
-- Note @Lit True@ is a real guard, not the absence of one: every component has an
-- unconditional block and its guard is exactly @Lit True@.
--
-- == Flags are resolved here, not by the solver
--
-- Everything above describes 'componentDeps', which a search over flags needs.
-- The solver is fed 'componentDepsAtDefaults' instead ('Bridge.Provider' makes
-- the call): every flag is treated as /manual/ and fixed at its declared
-- default, so no guard reaches the solver. See that function for why the
-- downstream machinery needs no other change.
--
-- Terminology, since the specifications distinguish these and
-- @docs\/flags-semantics.md@ §4.2 turns on the difference:
--
-- * a /flag/ is a declared name with a default;
-- * a /guard/ is a boolean formula over flag names;
-- * a /guarded dependency occurrence/ is one guard paired with /one/
--   dependency — §4.2's unit, and what an incompatibility may be built from;
-- * 'GuardedDeps' is the whole flat list for a release.
--
-- The same package may appear under several guards (an unconditional @q >=1@ and
-- a guarded @q <3@). 'depsAt' intersects those into one range, where §4.2 wants
-- them kept as separate facts.
module Bridge.Cabal.Flatten (
    GuardedDeps,
    componentDeps,
    componentDepsAtDefaults,
    buildableCondition,
    unbuildableAtDefaults,
    depsAt,
    flattenDeps,
    defaultFlags,
    expandGuard,
    prettyMap,
    parseCondition,
    Guard,

    -- * The pre-environment form
    --
    -- | What a @.cabal@ parse yields once everything the /environment/ decides is
    -- still undecided: the conditional trees as they were written, with
    -- 'ConfVar' guards unresolved. This is the form a derived index stores,
    -- because parsing is 106x the cost of flattening and only the flatten
    -- depends on the machine ('envConfVar' resolves @os@\/@arch@\/@impl@, and
    -- 'buildableCondition' additionally resolves @pkgconfig-depends@).
    --
    -- The two @Stored@ resolvers below run the /same/ 'flattenWith' over the
    -- /same/ trees as their 'GenericPackageDescription' counterparts, so they
    -- agree by construction rather than by a second implementation kept in step.
    -- @test\/StoredSpec.hs@ asserts it anyway, on hand-written @.cabal@ sources.
    StoredRelease (..),
    LibNode (..),
    toStored,
    componentDepsAtDefaultsStored,
    FlagModel (..),
    componentDepsStored,
    unbuildableAtDefaultsStored,
) where

import           Control.Applicative                          (Alternative (..))
import           Control.Monad                                 (void)
import           GHC.Generics                                 (Generic)
import           Data.Bool                                    (bool)
import           Data.Char                                    (isAlphaNum)
import qualified Data.Map.Merge.Strict                        as Map
import           Data.Map.Strict                              (Map)
import qualified Data.Map.Strict                              as Map
import           Data.Maybe                                   (catMaybes,
                                                               fromMaybe,
                                                               maybeToList)
import           Distribution.Compat.CharParsing              (CharParsing (..),
                                                               between, munch1,
                                                               sepByNonEmpty,
                                                               spaces)
import qualified Distribution.Compat.CharParsing              as P
import           Distribution.Compiler                        (CompilerId (..),
                                                               CompilerInfo,
                                                               compilerInfoId)
import           Distribution.Parsec                          (CabalParsing,
                                                               Parsec (..))
import           Distribution.Simple.Utils                    (lowercase)
import           Distribution.System                          (Platform (..))
import           Distribution.Types.Condition                 (Condition (..),
                                                               cAnd, cNot,
                                                               simplifyCondition)
import           Distribution.Solver.Types.PkgConfigDb        (PkgConfigDb,
                                                               pkgConfigPkgIsPresent)
import           Distribution.PackageDescription.Configuration (addBuildableCondition)
import           Distribution.Types.Executable                (Executable (buildInfo))
import           Distribution.Types.ForeignLib                (ForeignLib (foreignLibBuildInfo))
import           Distribution.Types.BuildInfo                 (BuildInfo (..))
import           Distribution.Types.CondTree                  (CondBranch (..),
                                                               CondTree (..))
import           Distribution.Types.ConfVar                   (ConfVar (..))
import           Distribution.Types.Dependency                (Dependency,
                                                               depPkgName,
                                                               depVerRange)
import           Distribution.Types.Flag                      (FlagAssignment,
                                                               FlagName,
                                                               PackageFlag (..),
                                                               lookupFlagAssignment,
                                                               mkFlagAssignment,
                                                               mkFlagName,
                                                               unFlagName)
import           Distribution.Types.Library                   (Library (..))
import           Distribution.Types.PkgconfigDependency        (PkgconfigDependency (..))
import           Distribution.Types.GenericPackageDescription (GenericPackageDescription (..))
import           Distribution.Types.PackageName               (PackageName)
import           Distribution.Version                         (withinRange)
import           PubGrub.Cabal                                (UnbuildableReason (..))
import           PubGrub.VersionSet                           (VersionSet)
import qualified PubGrub.VersionSet                           as VS

type Guard = Condition FlagName

-- | A package's dependencies as flag-guarded groups: each dependency list is
-- active exactly when its 'Condition' over flag names holds. The environment
-- (OS, arch, compiler) is already resolved away, so guards mention only flags.
type GuardedDeps = [(Guard, [Dependency])]

-- | Resolve the fixed environment: OS, arch and compiler conditions become
-- concrete @Right@ booleans.
--
-- What becomes of a /flag/ condition is the caller's choice, and it is the only
-- difference between 'componentDeps' (@Left@, symbolic) and
-- 'componentDepsAtDefaults' (@Right@, resolved).
envConfVar
    :: (FlagName -> Either FlagName Bool)
    -> Platform
    -> CompilerInfo
    -> ConfVar
    -> Either FlagName Bool
envConfVar flagEnv (Platform arch os) compiler = \case
    OS o -> Right (o == os)
    Arch a -> Right (a == arch)
    Impl flavor range ->
        let CompilerId f v = compilerInfoId compiler
         in Right (f == flavor && withinRange v range)
    PackageFlag f -> flagEnv f

-- | Evaluate a flag-only condition. A flag not present in the assignment
-- defaults to 'False' (guards only mention declared flags, so a total
-- assignment always covers them).
evalCond :: FlagAssignment -> Condition FlagName -> Bool
evalCond flags = go
  where
    go (Var f)    = fromMaybe False (lookupFlagAssignment f flags)
    go (Lit b)    = b
    go (CNot c)   = not (go c)
    go (COr a b)  = go a || go b
    go (CAnd a b) = go a && go b

-- | Walk one component's conditional tree, pushing each branch condition (with
-- the environment resolved) down as an accumulated flag guard, and taking @at@
-- from every node along the way.
--
-- What is taken is a parameter because two different things are read off the same
-- tree in the same shape: the @build-depends@ ('flattenComponent') and the
-- @BuildInfo@ that decides whether the node can be built here at all
-- ('buildableCondition'). One walk, described once.
flattenWith
    :: (ConfVar -> Either FlagName Bool)
    -> (CondTree ConfVar [Dependency] a -> b)
    -> CondTree ConfVar [Dependency] a
    -> [(Guard, b)]
flattenWith env at = go (Lit True)
  where
    go guard node@(CondNode _data _deps branches) =
        (guard, at node) : concatMap (goBranch guard) branches
    goBranch guard (CondBranch cond ifTrue mIfFalse) =
        let (cond', _free) = simplifyCondition cond env
            whenTrue = go (guard `cAnd` cond') ifTrue
            whenFalse = maybe [] (go (guard `cAnd` cNot cond')) mIfFalse
         in whenTrue ++ whenFalse

-- | Flatten one component's conditional tree to its flag-guarded dependency
-- groups.
flattenComponent
    :: (ConfVar -> Either FlagName Bool)
    -> CondTree ConfVar [Dependency] a
    -> GuardedDeps
flattenComponent env = flattenWith env condTreeConstraints

-- | Flatten the library, sub-library, foreign-library and executable conditional
-- dependency trees to flag-guarded groups, resolving OS\/arch\/compiler conditions
-- against the given platform and compiler.
--
-- Those four are exactly the components
-- @Distribution.Solver.Modular.IndexConversion.convGPD@ includes unconditionally.
-- Test-suites and benchmarks are excluded, as they are there: cabal puts them behind
-- a @Stanza@ that a plain @cabal build@ never enables, so a solve for a build plan
-- does not drag in a package's own test dependencies.
--
-- __A component that is not buildable contributes nothing__, and the gate is
-- Cabal-syntax's own 'addBuildableCondition' — the very function
-- @Distribution.Solver.Modular.IndexConversion.convGPD@ pipes every component
-- through before converting it. It rewrites a tree to @if <buildable> then
-- <tree>@, to the empty tree where @buildable:@ is statically @False@, and leaves
-- it alone where it is statically @True@; so the condition joins the guards
-- already being accumulated and costs nothing where nothing is conditional.
--
-- Without the gate, a dependency is read out of a stanza that is never built.
-- @http2-5.4.4@'s @hpack-encode@ declares @aeson >=2@ and closes with
-- @if flag(devel) … else buildable: False@; with @devel@ off cabal drops the
-- stanza, and keeping it is enough to make @optparse-applicative ==0.15.1.0@
-- alongside @warp@ unsolvable here and solvable for cabal.
--
-- The /library's/ buildability is deliberately not gated here. It is a stronger
-- fact — an unbuildable library makes the whole release unusable, not merely
-- dependency-free — and 'unbuildableAtDefaults' already carries it to the solver
-- with the reason attached, which is what lets a proof name the missing
-- @pkg-config@ module.
componentDeps :: Platform -> CompilerInfo -> GenericPackageDescription -> GuardedDeps
componentDeps = componentDepsWith Left

-- | 'componentDeps' with every flag resolved at its __declared default__, which is
-- how the solver is fed: flags are parsed and applied, but treated as manual, so
-- none of them is a search dimension.
--
-- The result is still a 'GuardedDeps', and deliberately so — nothing downstream
-- changes shape. Every guard folds to a literal (@simplifyCondition@ has no free
-- variables left, and @cAnd@\/@cNot@ collapse literals), and 'expandGuard' already
-- maps those two literals to exactly what is wanted:
--
-- * @Lit True@ becomes @[Map.empty]@ — one candidate assignment with /no/ pins, so
--   'Bridge.Provider' emits a dependency over a version range with the flag
--   component unconstrained;
-- * @Lit False@ becomes @[]@, and the provider drops a group whose expansion is
--   empty, so the dead branch is discarded rather than carried.
--
-- So no pinned cell is ever built, 'PubGrub.InstanceSet' degenerates to one
-- flag-free cell per operand, and each release offers exactly one instance: itself
-- under its defaults.
--
-- An /undeclared/ flag named by a condition resolves to 'False', matching the
-- convention 'evalCond' already documents and @test\/FlattenSpec.hs@ pins down. It
-- should not arise — a guard mentions only flags its own release declares.
--
-- The counterpart on the baseline's side is 'Bridge.Hackage.lookupGPD', which marks
-- every flag manual so cabal's own @enforceManualFlags@ pins it to the same
-- 'flagDefault'. Two mechanisms, one rule: both solvers see the same index.
componentDepsAtDefaults :: Platform -> CompilerInfo -> GenericPackageDescription -> GuardedDeps
componentDepsAtDefaults platform compiler gpd =
    componentDepsWith atDefault platform compiler gpd
  where
    defaults = defaultFlags gpd
    atDefault f = Right (Map.findWithDefault False f defaults)

componentDepsWith
    :: (FlagName -> Either FlagName Bool)
    -> Platform
    -> CompilerInfo
    -> GenericPackageDescription
    -> GuardedDeps
componentDepsWith flagEnv platform compiler gpd =
    concat $
        [flattenComponent env t | t <- maybeToList (condLibrary gpd)]
            ++ [flattenComponent env (gateOnBuildable libBuildInfo t) | (_, t) <- condSubLibraries gpd]
            ++ [flattenComponent env (gateOnBuildable foreignLibBuildInfo t) | (_, t) <- condForeignLibs gpd]
            ++ [flattenComponent env (gateOnBuildable buildInfo t) | (_, t) <- condExecutables gpd]
  where
    env = envConfVar flagEnv platform compiler

-- | Cabal-syntax's 'addBuildableCondition', named for what it does here: put a
-- component's dependencies under the condition that the component is buildable.
-- Taking the function from Cabal-syntax rather than restating it is the same rule
-- the @pkg-config@ predicate follows — a paraphrase is a second implementation to
-- keep in step.
gateOnBuildable
    :: Monoid a
    => (a -> BuildInfo)
    -> CondTree ConfVar [Dependency] a
    -> CondTree ConfVar [Dependency] a
gateOnBuildable = addBuildableCondition

-- | Evaluate the guards at a concrete flag assignment and merge the resulting
-- dependency ranges (intersecting duplicate constraints on the same package).
depsAt :: FlagAssignment -> GuardedDeps -> Map PackageName VersionSet
depsAt flags guarded =
    Map.fromListWith
        VS.intersectionVersionSet
        [ (depPkgName d, VS.fromVersionRange (depVerRange d))
        | (guard, deps) <- guarded
        , evalCond flags guard
        , d <- deps
        ]

-- | Each declared flag mapped to its default value.
defaultFlags :: GenericPackageDescription -> Map FlagName Bool
defaultFlags gpd = Map.fromList [(flagName f, flagDefault f) | f <- genPackageFlags gpd]

-- | Under what condition on its flags this release's __library__ can be built on
-- this machine.
--
-- Two things make a node unusable, and both are read off its @BuildInfo@:
-- @buildable: False@, and a @pkgconfig-depends@ this machine cannot satisfy. A
-- node under guard @C@ that is unusable means the release requires @not C@, so the
-- answer is the conjunction of @not C@ over every unusable node — @Lit True@ when
-- there are none.
--
-- == Why this is a condition and not a boolean
--
-- @pkg-config@ is a /constant/ of the machine, like OS and arch: the solver does
-- not choose it, so it can be resolved once rather than searched. But what it
-- resolves to is not "buildable" or "not buildable" — it is a statement about
-- which /flag assignments/ remain, because @pkgconfig-depends@ lives inside
-- flag-guarded blocks:
--
-- > if flag(pkg-config)
-- >   pkgconfig-depends: zlib-any
--
-- With flags fixed at their defaults there is one assignment and
-- 'unbuildableAtDefaults' collapses this to a verdict with its reasons. Keeping
-- the condition lets flag search come back without redoing the analysis: a
-- search over flags has to /satisfy/ this condition rather than evaluate it
-- (@docs\/flags-semantics.md@ O6).
--
-- == Why the library only
--
-- A dependency needs the library; an unbuildable executable does not make the
-- package unusable as a dependency. Note this is deliberately narrower than
-- 'componentDeps', which does collect executables' dependencies — that
-- over-approximates, and over-approximating /buildability/ would exclude releases
-- rather than merely constrain them.
--
-- == 'Nothing' means no @pkg-config@ executable
--
-- Not "assume satisfied". That is cabal's reading of the same value
-- (@Distribution.Solver.Modular.Validate@ rejects every @pkgconfig-depends@ when
-- the db is absent), and taking the db and the predicate from cabal rather than
-- restating them is what keeps the two solvers on one environment — the same
-- argument that makes the shared index reader load-bearing.
buildableCondition
    :: Maybe PkgConfigDb
    -> Platform
    -> CompilerInfo
    -> GenericPackageDescription
    -> Condition FlagName
buildableCondition db platform compiler gpd =
    foldr cAnd (Lit True) $
        [ cNot guard
        | (guard, isBuildable, pcs) <- libraryNodes platform compiler gpd
        , not (null (unusable db isBuildable pcs))
        ]

-- | Why the release's library cannot be built here at its declared defaults —
-- the question to ask while flags are treated as manual. Empty means it can.
--
-- This is 'buildableCondition' evaluated at the defaults, with the reasons kept
-- instead of folded away: a node whose guard holds at the defaults contributes
-- whatever makes it unusable, in tree order. @null@ of the result is exactly the
-- condition's value at the defaults, since a node is unusable when and only when
-- it gives a reason.
unbuildableAtDefaults
    :: Maybe PkgConfigDb
    -> Platform
    -> CompilerInfo
    -> GenericPackageDescription
    -> [UnbuildableReason]
unbuildableAtDefaults db platform compiler gpd =
    unbuildableNodes
        db
        (mkFlagAssignment (Map.toList (defaultFlags gpd)))
        (libraryNodes platform compiler gpd)

-- | The library's nodes with what decides their buildability: the guard, the
-- @buildable@ field, and the @pkgconfig-depends@.
libraryNodes
    :: Platform
    -> CompilerInfo
    -> GenericPackageDescription
    -> [(Guard, Bool, [PkgconfigDependency])]
libraryNodes platform compiler gpd =
    [ (guard, buildable bi, pkgconfigDepends bi)
    | tree <- maybeToList (condLibrary gpd)
    , (guard, bi) <- flattenWith env (libBuildInfo . condTreeData) tree
    ]
  where
    env = envConfVar Left platform compiler

-- | The reasons the nodes in force at @flags@ give, in tree order.
unbuildableNodes
    :: Maybe PkgConfigDb
    -> FlagAssignment
    -> [(Guard, Bool, [PkgconfigDependency])]
    -> [UnbuildableReason]
unbuildableNodes db flags nodes =
    [ reason
    | (guard, isBuildable, pcs) <- nodes
    , evalCond flags guard
    , reason <- unusable db isBuildable pcs
    ]

-- | What makes one node unusable: @buildable: False@, and each @pkgconfig-depends@
-- the machine's @pkg-config@ cannot satisfy. Empty when the node is usable.
--
-- A 'Nothing' db fails every @pkgconfig-depends@ — no @pkg-config@ executable is
-- a statement about the machine, not permission to assume the module is there —
-- and the reason still names the module, which is what the reader has to
-- install either way.
unusable :: Maybe PkgConfigDb -> Bool -> [PkgconfigDependency] -> [UnbuildableReason]
unusable db isBuildable pcs =
    [NotBuildable | not isBuildable]
        ++ [MissingPkgConfig d | d <- pcs, not (present d)]
  where
    present (PkgconfigDependency n range) =
        maybe False (\d -> pkgConfigPkgIsPresent d n range) db

-- | Dependencies of a package version at its /default/ flag values, as a
-- version-set map. (Convenience: 'depsAt' the defaults over 'componentDeps'.)
flattenDeps :: Platform -> CompilerInfo -> FlagAssignment -> GenericPackageDescription -> Map PackageName VersionSet
flattenDeps platform compiler flags gpd =
    depsAt flags (componentDeps platform compiler gpd)

-- | A guard in disjunctive normal form: a list of partial flag assignments
-- whose disjunction is the guard. A flag an assignment does not mention is
-- free, and the disjuncts may overlap. @[]@ means the guard never holds;
-- @[Map.empty]@ means it always holds.
expandGuard :: Condition FlagName -> [Map FlagName Bool]
expandGuard = go
  where
    go (Var f)    = [Map.singleton f True]
    go (Lit b)    = [Map.empty | b]
    go (COr a b)  = go a ++ go b
    go (CAnd a b) = catMaybes
        [ Map.mergeA
            Map.preserveMissing
            Map.preserveMissing
            (Map.zipWithAMatched (\_ a' b' -> if a' == b' then Just a' else Nothing))
            x y
        | x <- go a
        , y <- go b
        ]
    go (CNot (Var f))    = [Map.singleton f False]
    go (CNot (Lit b))    = [Map.empty | not b]
    go (CNot (CAnd a b)) = go (COr (CNot a) (CNot b))
    go (CNot (COr a b))  = go (CAnd (CNot a) (CNot b))
    go (CNot (CNot c))   = go c

parseCondition :: CabalParsing m => m (Condition FlagName)
parseCondition = condOr
  where
    condOr = foldl1 COr <$> sepByNonEmpty condAnd (oper "||")
    condAnd = foldl1 CAnd <$> sepByNonEmpty cond (oper "&&")
    cond = sp >> (flagCond <|> boolLiteral <|> inparens condOr <|> notCond)
    inparens = between (P.char '(' >> sp) (sp >> P.char ')' >> sp)
    notCond = CNot <$> (P.char '!' >> sp >> cond)
    flagCond = Var <$> (string "flag" >> sp >> inparens flagIdent)
    boolLiteral = Lit <$> parsec
    flagIdent = mkFlagName . lowercase <$> munch1 isIdentChar
    isIdentChar c = isAlphaNum c || c == '_' || c == '-'
    oper s = sp >> string s >> sp
    sp = spaces

prettyMap :: [Map FlagName Bool] -> String
prettyMap = unwords . map (\m -> "{" ++ unwords [ bool "-" "+" b ++ unFlagName f | (f, b) <- Map.toList m ] ++ "}")

-- >>> import Distribution.Parsec (explicitEitherParsec)
-- >>> test s = either error (prettyMap . expandGuard) (explicitEitherParsec parseCondition s)
-- >>> test "flag(a) && !flag(b)"
-- "{+a -b}"
-- >>> test "True"
-- "{}"
-- >>> test "False"
-- ""
-- >>> test "flag(a) || flag(b)"
-- "{+a} {+b}"
-- >>> test "flag(a) && flag(b)"
-- "{+a +b}"
-- >>> test "flag(a) && !flag(b)"
-- "{+a -b}"
-- >>> test "!(flag(a) && flag(b))"
-- "{-a} {-b}"
-- >>> test "!(flag(a) || flag(b))"
-- "{-a -b}"


-- --------------------------------------------------------------------------
-- The pre-environment form
-- --------------------------------------------------------------------------

-- | The bits of a library node's @BuildInfo@ that decide buildability. Nothing
-- else from a 'BuildInfo' is ever consulted, so nothing else is kept.
data LibNode = LibNode
    { lnBuildable :: Bool
    , lnPkgConfig :: [PkgconfigDependency]
    }
    deriving (Eq, Show, Generic)

-- | One release, parsed and no further. The trees are Cabal-syntax's own, so the
-- resolvers below are the existing walk rather than a paraphrase of it.
--
-- The library tree keeps a 'LibNode' because buildability is read off the library
-- only; the others keep @()@, since 'flattenComponent' reads
-- 'condTreeConstraints' and never the node data.
data StoredRelease = StoredRelease
    { srFlags   :: [(FlagName, Bool)]
    , srManual  :: [FlagName]
    -- ^ the flags declared @manual: True@, which stay at their defaults even
    -- when automatic flags are searched
    , srLibrary :: Maybe (CondTree ConfVar [Dependency] LibNode)
    , srOthers  :: [CondTree ConfVar [Dependency] ()]
    }
    deriving (Eq, Show, Generic)

-- | Reduce a parsed description to the form a derived index stores.
toStored :: GenericPackageDescription -> StoredRelease
toStored gpd =
    StoredRelease
        { srFlags = [(flagName f, flagDefault f) | f <- genPackageFlags gpd]
        , srManual = [flagName f | f <- genPackageFlags gpd, flagManual f]
        , srLibrary = fmap (fmap libNode) (condLibrary gpd)
        , srOthers =
            [void (gateOnBuildable libBuildInfo t) | (_, t) <- condSubLibraries gpd]
                ++ [void (gateOnBuildable foreignLibBuildInfo t) | (_, t) <- condForeignLibs gpd]
                ++ [void (gateOnBuildable buildInfo t) | (_, t) <- condExecutables gpd]
        }
  where
    libNode lib =
        let bi = libBuildInfo lib
         in LibNode{lnBuildable = buildable bi, lnPkgConfig = pkgconfigDepends bi}

-- | 'componentDepsAtDefaults' over a stored release.
componentDepsAtDefaultsStored :: Platform -> CompilerInfo -> StoredRelease -> GuardedDeps
componentDepsAtDefaultsStored platform compiler sr =
    concat $
        [flattenComponent env t | t <- maybeToList (srLibrary sr)]
            ++ [flattenComponent env t | t <- srOthers sr]
  where
    defaults = Map.fromList (srFlags sr)
    env = envConfVar (\f -> Right (Map.findWithDefault False f defaults)) platform compiler

-- | Which flags the solver searches.
data FlagModel
    = FixedFlags
      -- ^ every flag at its declared default ('componentDepsAtDefaultsStored')
    | FlagPackages
      -- ^ each automatic flag is a solver variable of its own
      -- ('PubGrub.Variable.FlagVar'); manual flags stay at their defaults
    deriving (Eq, Show)

-- | The guarded dependencies of a stored release under a flag model. Under
-- 'FlagPackages' the manual flags are resolved to their defaults and only
-- automatic flags remain symbolic in the guards.
componentDepsStored :: FlagModel -> Platform -> CompilerInfo -> StoredRelease -> GuardedDeps
componentDepsStored FixedFlags platform compiler sr = componentDepsAtDefaultsStored platform compiler sr
componentDepsStored FlagPackages platform compiler sr =
    concat $
        [flattenComponent env t | t <- maybeToList (srLibrary sr)]
            ++ [flattenComponent env t | t <- srOthers sr]
  where
    defaults = Map.fromList (srFlags sr)
    -- A manual flag is its default; a flag the release does not declare is
    -- 'False', the convention 'evalCond' documents; only an automatic flag stays
    -- symbolic, so a guard reaching the provider names automatic flags only.
    flagEnv f
        | f `elem` srManual sr = Right (Map.findWithDefault False f defaults)
        | Map.member f defaults = Left f
        | otherwise = Right False
    env = envConfVar flagEnv platform compiler

-- | 'unbuildableAtDefaults' over a stored release.
unbuildableAtDefaultsStored
    :: Maybe PkgConfigDb -> Platform -> CompilerInfo -> StoredRelease -> [UnbuildableReason]
unbuildableAtDefaultsStored db platform compiler sr =
    unbuildableNodes
        db
        (mkFlagAssignment (srFlags sr))
        [ (guard, lnBuildable ln, lnPkgConfig ln)
        | tree <- maybeToList (srLibrary sr)
        , (guard, ln) <- flattenWith env condTreeData tree
        ]
  where
    env = envConfVar Left platform compiler
