{-# LANGUAGE CPP        #-}
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
-- * /Accumulated down the tree/. 'flattenWith' starts at @Lit True@ and
--   pushes conditions down: the @if@ branch gets @guard \`cAnd\` cond@, the
--   @else@ branch @guard \`cAnd\` cNot cond@. A dependency nested two levels deep
--   carries both conditions conjoined; nesting produces a longer formula, not
--   nested structure.
-- * /Per release, not per package/. A guard comes from one @.cabal@ file, so it
--   mentions only flags /that/ release declares, and a flag term built from it
--   names one of the depender's own flags.
--
-- Note @Lit True@ is a real guard, not the absence of one: every component has an
-- unconditional block and its guard is exactly @Lit True@.
--
-- == One walk, two entry points
--
-- Everything is read off the __pre-environment form__, 'StoredRelease': the
-- component trees as the @.cabal@ file wrote them, with the environment's
-- conditions unresolved and each node reduced to what is ever consulted. The
-- description-taking functions ('componentDeps', 'buildableCondition', …) go
-- through 'toStored' and the @Stored@ ones take the form directly, which is what a
-- derived index keeps; so the two cannot disagree, because they are one walk
-- rather than two kept in step.
--
-- Terminology:
--
-- * a /flag/ is a declared name with a default;
-- * a /guard/ is a boolean formula over flag names;
-- * a /guarded dependency occurrence/ is one guard paired with /one/
--   dependency, the unit an incompatibility is built from;
-- * 'GuardedDeps' is the whole flat list for a release.
--
-- The same package may appear under several guards (an unconditional @q >=1@ and
-- a guarded @q <3@). 'depsAt' intersects those into one range; the provider
-- states each occurrence as a separate fact.
module PubGrub.Cabal.Flatten (
    GuardedDeps,
    Stanzas (..),
    noStanzas,
    allStanzas,
    componentDeps,
    componentDepsAtDefaults,
    buildableCondition,
    PkgConfigPresent,
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
    -- 'ConfVar' conditions unresolved. This is the form a derived index stores,
    -- because parsing is 106x the cost of flattening and only the flatten
    -- depends on the machine ('envConfVar' resolves @os@\/@arch@\/@impl@, and
    -- 'buildableCondition' additionally resolves @pkgconfig-depends@).
    StoredRelease (..),
    LibNode (..),
    Node (..),
    Tree (..),
    Branch (..),
    toStored,
    componentDepsAtDefaultsStored,
    FlagModel (..),
    componentDepsStored,
    componentToolsStored,
    unbuildableStored,
    unbuildableAtDefaultsStored,

    -- * Build tools and setup dependencies
    GuardedTools,
    componentTools,
    componentToolsAtDefaults,
    toolsAt,
    desugarBuildTool,
    setupDeps,
) where

import           Control.Applicative                          (Alternative (..))
import           GHC.Generics                                 (Generic)
import           Data.Bool                                    (bool)
import           Data.Char                                    (isAlphaNum, toLower)
import           Data.List.NonEmpty                           (NonEmpty)
import qualified Data.List.NonEmpty                           as NE
import qualified Data.Map.Merge.Strict                        as Map
import           Data.Map.Strict                              (Map)
import qualified Data.Map.Strict                              as Map
import           Data.Maybe                                   (catMaybes,
                                                               fromMaybe,
                                                               mapMaybe,
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
import           Distribution.System                          (Platform (..))
import           Distribution.Types.Condition                 (Condition (..),
                                                               cAnd, cNot,
                                                               simplifyCondition)
import           Distribution.PackageDescription.Configuration (addBuildableCondition)
import           Distribution.Types.Executable                (Executable (buildInfo))
import           Distribution.Types.ExeDependency              (ExeDependency (..))
import           Distribution.Types.LegacyExeDependency        (LegacyExeDependency (..))
import           Distribution.Types.PackageDescription         (PackageDescription (..))
import           Distribution.Types.PackageId                  (PackageIdentifier (..))
import           Distribution.Types.SetupBuildInfo             (SetupBuildInfo (..))
import           Distribution.Types.UnqualComponentName        (UnqualComponentName,
                                                               mkUnqualComponentName)
import           Distribution.Types.ForeignLib                (ForeignLib (foreignLibBuildInfo))
import           Distribution.Types.TestSuite                 (TestSuite (testBuildInfo))
import           Distribution.Types.Benchmark                 (Benchmark (benchmarkBuildInfo))
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
                                                               mkFlagName,
                                                               unFlagName)
import           Distribution.Types.Library                   (Library (..))
import           Distribution.Types.PkgconfigDependency        (PkgconfigDependency (..))
import           Distribution.Types.GenericPackageDescription (GenericPackageDescription (..))
import           Distribution.Types.PackageName               (PackageName,
                                                               mkPackageName)
import           Distribution.Version                         (withinRange)
import           PubGrub.Cabal                                (UnbuildableReason (..))
import           PubGrub.Cabal.VersionSet                           (VersionSet)
import qualified PubGrub.Cabal.VersionSet                           as VS

type Guard = Condition FlagName

-- | A package's dependencies as flag-guarded groups: each dependency list is
-- active exactly when its 'Condition' over flag names holds. The environment
-- (OS, arch, compiler) is already resolved away, so guards mention only flags.
type GuardedDeps = [(Guard, [Dependency])]

-- | What this machine's @pkg-config@ answers for a @pkgconfig-depends@: whether a
-- module of that name is present in a version the range admits.
--
-- A predicate rather than a database so that the caller decides where the answer
-- comes from (a @pkg-config@ database, a list in a test) and this module needs
-- nothing but @Cabal-syntax@. __No @pkg-config@ executable is @const False@__,
-- not @const True@: cabal reads the same situation that way, rejecting every
-- @pkgconfig-depends@ when the database is absent, and a missing module still
-- has to be named in the proof.
type PkgConfigPresent = PkgconfigDependency -> Bool

-- | Which optional stanzas a reduction reads beside the four components cabal
-- includes unconditionally (library, sub-libraries, foreign libraries,
-- executables): the test suites, the benchmarks, both or neither.
--
-- A test suite or benchmark is behind a stanza that a plain @cabal build@ never
-- enables, and a planner enables it __per package__: @cabal test@ resolves the
-- test suites of the local packages and never those of their dependencies. So
-- the choice is made where a release is reduced, by whoever reduces it, and a
-- solve for a build plan passes 'noStanzas' for every release. What the stanzas
-- add is read the same way as the rest: flag-guarded, gated on their own
-- @buildable:@ ('gateOnBuildable'), their build tools alongside
-- ('componentTools'). A test suite's dependency on its own package's library
-- is an intra-package edge, which the provider rule drops, as it does for an
-- executable.
data Stanzas = Stanzas
    { withTests      :: Bool
    , withBenchmarks :: Bool
    }
    deriving (Eq, Show)

-- | The four unconditional components only: a release as a dependency.
noStanzas :: Stanzas
noStanzas = Stanzas{withTests = False, withBenchmarks = False}

-- | The test suites and the benchmarks too: a local package under @cabal test@
-- and @cabal bench@.
allStanzas :: Stanzas
allStanzas = Stanzas{withTests = True, withBenchmarks = True}

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

-- --------------------------------------------------------------------------
-- The conditional tree
-- --------------------------------------------------------------------------

-- | One component's conditional tree, in the shape the @.cabal@ file wrote it:
-- a node's own fields, then its @if@ blocks, each with an optional @else@.
--
-- Cabal-syntax's own @CondTree@ with the node reduced to what this module ever
-- reads. It is ours rather than Cabal-syntax's for two reasons. It is what a
-- derived index stores, and a stored form keyed to another package's type
-- changes shape with that package — Cabal-syntax 3.18 dropped @CondTree@'s
-- constraints parameter, which is the one this module read. And it keeps the
-- node's dependencies where Cabal-syntax keeps them, on the @BuildInfo@: that
-- parameter was only ever a copy of @targetBuildDepends@ (the parser filled it
-- from there, and cabal's own solver reads the field in 3.18 where it read the
-- copy before), so reading the field is the same answer on either side of the
-- change. 'fromCondTree' is the one place the Cabal-syntax version is consulted.
data Tree a = Tree
    { treeData     :: a
    , treeBranches :: [Branch a]
    }
    deriving (Eq, Show, Generic, Functor)

-- | An @if@ block: its condition, the tree under it, and the @else@ tree if
-- there is one. The condition is over 'ConfVar', unresolved: resolving
-- @os@\/@arch@\/@impl@ is the walk's business ('flattenWith'), not the tree's.
data Branch a = Branch
    { branchCondition :: Condition ConfVar
    , branchIfTrue    :: Tree a
    , branchIfFalse   :: Maybe (Tree a)
    }
    deriving (Eq, Show, Generic, Functor)

#if MIN_VERSION_Cabal_syntax(3,18,0)
type CabalTree a = CondTree ConfVar a
#else
type CabalTree a = CondTree ConfVar [Dependency] a
#endif

-- | Cabal-syntax's tree as ours, with each node reduced by @f@. The only
-- function in the package that depends on which Cabal-syntax it was built
-- against.
fromCondTree :: (a -> b) -> CabalTree a -> Tree b
#if MIN_VERSION_Cabal_syntax(3,18,0)
fromCondTree f (CondNode x branches) = Tree (f x) (map branch branches)
#else
fromCondTree f (CondNode x _constraints branches) = Tree (f x) (map branch branches)
#endif
  where
    branch (CondBranch cond ifTrue ifFalse) =
        Branch cond (fromCondTree f ifTrue) (fmap (fromCondTree f) ifFalse)

-- | Walk one component's conditional tree, pushing each branch condition (with
-- the environment resolved) down as an accumulated flag guard, and taking @at@
-- from every node along the way.
--
-- What is taken is a parameter because several different things are read off
-- the same tree in the same shape: the @build-depends@ ('componentDeps'), the
-- build tools ('componentTools'), and what decides whether the node can be built
-- here at all ('buildableCondition'). One walk, described once.
flattenWith
    :: (ConfVar -> Either FlagName Bool)
    -> (a -> b)
    -> Tree a
    -> [(Guard, b)]
flattenWith env at = go (Lit True)
  where
    go guard (Tree x branches) =
        (guard, at x) : concatMap (goBranch guard) branches
    goBranch guard (Branch cond ifTrue mIfFalse) =
        let (cond', _free) = simplifyCondition cond env
            whenTrue = go (guard `cAnd` cond') ifTrue
            whenFalse = maybe [] (go (guard `cAnd` cNot cond')) mIfFalse
         in whenTrue ++ whenFalse

-- | Flatten the library, sub-library, foreign-library and executable conditional
-- dependency trees to flag-guarded groups, resolving OS\/arch\/compiler conditions
-- against the given platform and compiler.
--
-- Those four are exactly the components cabal's solver includes
-- unconditionally. Test-suites and benchmarks are read only when the 'Stanzas'
-- ask for them, as they are there: cabal puts them behind a stanza that a plain
-- @cabal build@ never enables, so a solve for a build plan does not drag in a
-- package's own test dependencies, and a planner enables them per local package.
--
-- __A component that is not buildable contributes nothing__, and the gate is
-- Cabal-syntax's own 'addBuildableCondition', the function cabal's solver
-- applies to every component before converting it. It rewrites a tree to
-- @if <buildable> then <tree>@, to the empty tree where @buildable:@ is
-- statically @False@, and leaves it alone where it is statically @True@; so the
-- condition joins the guards already being accumulated and costs nothing where
-- nothing is conditional.
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
componentDeps :: Stanzas -> Platform -> CompilerInfo -> GenericPackageDescription -> GuardedDeps
componentDeps stanzas platform compiler = depsWith Left stanzas platform compiler . toStored

-- | 'componentDeps' with every flag resolved at its __declared default__: flags
-- are parsed and applied, but treated as manual, so none of them is a search
-- dimension.
--
-- The result is still a 'GuardedDeps', and deliberately so — nothing downstream
-- changes shape. Every guard folds to a literal (@simplifyCondition@ has no free
-- variables left, and @cAnd@\/@cNot@ collapse literals), and 'expandGuard' already
-- maps those two literals to exactly what is wanted:
--
-- * @Lit True@ becomes @[Map.empty]@: one disjunct with /no/ pins, so the
--   dependency is stated with no flag term;
-- * @Lit False@ becomes @[]@: no disjunct, so the dead branch is discarded rather
--   than carried.
--
-- So no flag becomes a solver variable, and each release is planned under its
-- defaults.
--
-- An /undeclared/ flag named by a condition resolves to 'False', matching the
-- convention 'evalCond' documents. It should not arise — a guard mentions only
-- flags its own release declares.
componentDepsAtDefaults :: Stanzas -> Platform -> CompilerInfo -> GenericPackageDescription -> GuardedDeps
componentDepsAtDefaults stanzas platform compiler = componentDepsAtDefaultsStored stanzas platform compiler . toStored

-- | The guarded dependencies of a stored release, with each flag resolved as
-- @flagEnv@ says.
depsWith
    :: (FlagName -> Either FlagName Bool)
    -> Stanzas
    -> Platform
    -> CompilerInfo
    -> StoredRelease
    -> GuardedDeps
depsWith flagEnv stanzas platform compiler sr =
    concat [flattenWith env nodeDeps t | t <- componentTrees stanzas sr]
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
    -> CabalTree a
    -> CabalTree a
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
-- 'unbuildableAtDefaults' evaluates this at the declared defaults, keeping the
-- reasons. A search over flags does not evaluate it: 'unbuildableStored' keeps
-- each unusable node's guard, so only the flag values that reach the node are
-- ruled out.
--
-- == Why the library only
--
-- A dependency needs the library; an unbuildable executable does not make the
-- package unusable as a dependency. Note this is deliberately narrower than
-- 'componentDeps', which does collect executables' dependencies — that
-- over-approximates, and over-approximating /buildability/ would exclude releases
-- rather than merely constrain them.
--
-- == No @pkg-config@ executable means @const False@
--
-- Not "assume satisfied". See 'PkgConfigPresent': that is cabal's reading of the
-- same situation.
buildableCondition
    :: PkgConfigPresent
    -> Platform
    -> CompilerInfo
    -> GenericPackageDescription
    -> Condition FlagName
buildableCondition db platform compiler gpd =
    foldr cAnd (Lit True) $
        [ cNot guard
        | (guard, isBuildable, pcs) <- libraryNodes platform compiler (toStored gpd)
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
    :: PkgConfigPresent
    -> Platform
    -> CompilerInfo
    -> GenericPackageDescription
    -> [UnbuildableReason]
unbuildableAtDefaults db platform compiler = unbuildableAtDefaultsStored db platform compiler . toStored

-- | The library's nodes with what decides their buildability: the guard, the
-- @buildable@ field, and the @pkgconfig-depends@.
libraryNodes
    :: Platform
    -> CompilerInfo
    -> StoredRelease
    -> [(Guard, Bool, [PkgconfigDependency])]
libraryNodes platform compiler sr =
    [ (guard, lnBuildable ln, lnPkgConfig ln)
    | tree <- maybeToList (srLibrary sr)
    , (guard, ln) <- flattenWith env id tree
    ]
  where
    env = envConfVar Left platform compiler

-- | What makes one node unusable: @buildable: False@, and each @pkgconfig-depends@
-- the machine's @pkg-config@ cannot satisfy. Empty when the node is usable.
--
-- The reason names the module, which is what the reader has to install either
-- way, whether the machine lacks it or lacks @pkg-config@ itself.
unusable :: PkgConfigPresent -> Bool -> [PkgconfigDependency] -> [UnbuildableReason]
unusable present isBuildable pcs =
    [NotBuildable | not isBuildable]
        ++ [MissingPkgConfig d | d <- pcs, not (present d)]

-- | Dependencies of a package version at a flag assignment, as a version-set
-- map. (Convenience: 'depsAt' over 'componentDeps'.)
flattenDeps :: Stanzas -> Platform -> CompilerInfo -> FlagAssignment -> GenericPackageDescription -> Map PackageName VersionSet
flattenDeps stanzas platform compiler flags gpd =
    depsAt flags (componentDeps stanzas platform compiler gpd)

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
    flagIdent = mkFlagName . map toLower <$> munch1 isIdentChar
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
-- Build tools and setup dependencies
-- --------------------------------------------------------------------------

-- | A release's build-tool dependencies as flag-guarded groups, the shape of
-- 'GuardedDeps': each 'ExeDependency' names the package, the executable and the
-- range, as @build-tool-depends@ writes it.
--
-- __Not a dependency of the release in this solver's eyes__, and kept out of
-- 'GuardedDeps' on purpose. A build tool runs at build time and its dependencies
-- never reach the code it generates, so cabal solves it in a namespace of its
-- own, and a planner over this solver does the same with a solve of its own,
-- seeded from this list and preferring the main plan's choices
-- ('PubGrub.Cabal.Provider.Preference'). The main solve reads nothing here.
--
-- What is in the list is what cabal's own solver keeps: @build-tool-depends@ as
-- written, plus the legacy @build-tools@ names cabal knows how to translate
-- ('desugarBuildTool'), minus a dependency on one of the release's own
-- executables, which is internal and no solver's business.
type GuardedTools = [(Guard, [ExeDependency])]

-- | Cabal's @Distribution.Simple.BuildToolDepends.desugarBuildToolSimple@,
-- restated because that module is in @Cabal@ and this package is Cabal-syntax
-- only. A legacy @build-tools@ name is one of the release's own executables, or
-- one of eight tools known to be the executable of a package of the same name, or
-- nothing a solver can act on: a program found on the @PATH@ at configure time.
-- The eight are those of Cabal 3.16 and later, which dropped @greencard@.
desugarBuildTool :: PackageName -> [UnqualComponentName] -> LegacyExeDependency -> Maybe ExeDependency
desugarBuildTool self exes (LegacyExeDependency name range)
    | tool `elem` exes = Just (ExeDependency self tool range)
    | name `elem` allowlist = Just (ExeDependency (mkPackageName name) tool range)
    | otherwise = Nothing
  where
    tool = mkUnqualComponentName name
    allowlist = ["hscolour", "haddock", "happy", "alex", "hsc2hs", "c2hs", "cpphs", "hspec-discover"]

-- | The build tools one node declares that are another package's.
toolsOf :: PackageName -> [UnqualComponentName] -> BuildInfo -> [ExeDependency]
toolsOf self exes bi =
    [ d
    | d@(ExeDependency p _ _) <- buildToolDepends bi ++ mapMaybe (desugarBuildTool self exes) (buildTools bi)
    , p /= self
    ]

-- | The release's build tools, flag-guarded, read off the same component
-- trees as 'componentDeps' — the same 'Stanzas' choice — and gated on
-- buildability the same way.
componentTools :: Stanzas -> Platform -> CompilerInfo -> GenericPackageDescription -> GuardedTools
componentTools stanzas platform compiler = toolsWith Left stanzas platform compiler . toStored

-- | 'componentTools' with every flag at its declared default.
componentToolsAtDefaults :: Stanzas -> Platform -> CompilerInfo -> GenericPackageDescription -> GuardedTools
componentToolsAtDefaults stanzas platform compiler = componentToolsStored FixedFlags stanzas platform compiler . toStored

-- | The guarded build tools of a stored release, with each flag resolved as
-- @flagEnv@ says.
toolsWith
    :: (FlagName -> Either FlagName Bool)
    -> Stanzas
    -> Platform
    -> CompilerInfo
    -> StoredRelease
    -> GuardedTools
toolsWith flagEnv stanzas platform compiler sr =
    concat [flattenWith env nodeTools t | t <- componentTrees stanzas sr]
  where
    env = envConfVar flagEnv platform compiler

-- | The build tools in force at a flag assignment: 'depsAt' for 'GuardedTools',
-- without the merge, since a tool is named rather than ranged over. A dead
-- branch (a guard that folded to @Lit False@) is dropped here, as 'depsAt' and
-- 'expandGuard' drop it for dependencies.
toolsAt :: FlagAssignment -> GuardedTools -> [ExeDependency]
toolsAt flags guarded = [d | (guard, ds) <- guarded, evalCond flags guard, d <- ds]

-- | The release's @setup-depends@: the dependencies of its @Setup.hs@, which is
-- never linked against the release's library and is solved in a namespace of its
-- own, like a build tool. Unconditional, as Cabal-syntax keeps it. Empty for a
-- @build-type@ that is not @Custom@ or @Hooks@, or that declares none.
setupDeps :: GenericPackageDescription -> [Dependency]
setupDeps gpd = maybe [] setupDepends (setupBuildInfo (packageDescription gpd))

ownName :: GenericPackageDescription -> PackageName
ownName = pkgName . package . packageDescription

ownExecutables :: GenericPackageDescription -> [UnqualComponentName]
ownExecutables gpd = [n | (n, _) <- condExecutables gpd]

-- --------------------------------------------------------------------------
-- The pre-environment form
-- --------------------------------------------------------------------------

-- | The bits of a library node's @BuildInfo@ that are ever consulted: its
-- dependencies, what decides buildability, and the build tools. Nothing else is
-- kept.
data LibNode = LibNode
    { lnDeps      :: [Dependency]
    , lnBuildable :: Bool
    , lnPkgConfig :: [PkgconfigDependency]
    , lnTools     :: [ExeDependency]
    }
    deriving (Eq, Show, Generic)

-- | What is kept of any other component's node: its dependencies and its build
-- tools. Buildability is already in the guards ('gateOnBuildable').
data Node = Node
    { nodeDeps  :: [Dependency]
    , nodeTools :: [ExeDependency]
    }
    deriving (Eq, Show, Generic)

-- | One release, parsed and no further. The trees are the @.cabal@ file's own
-- ('Tree'), so the resolvers over them are the existing walk rather than a
-- paraphrase of it.
data StoredRelease = StoredRelease
    { srFlags   :: [(FlagName, Bool)]
    , srManual  :: [FlagName]
    -- ^ the flags declared @manual: True@, which stay at their defaults even
    -- when automatic flags are searched
    , srLibrary :: Maybe (Tree LibNode)
    , srOthers  :: [Tree Node]
    -- ^ the sub-libraries, foreign libraries and executables, each gated on its
    -- own buildability
    , srTests   :: [Tree Node]
    -- ^ the test suites, gated likewise; read only under 'withTests'
    , srBenchmarks :: [Tree Node]
    -- ^ the benchmarks, gated likewise; read only under 'withBenchmarks'
    , srSetup   :: [Dependency]
    -- ^ 'setupDeps'
    }
    deriving (Eq, Show, Generic)

-- | Reduce a parsed description to the form a derived index stores.
toStored :: GenericPackageDescription -> StoredRelease
toStored gpd =
    StoredRelease
        { srFlags = [(flagName f, flagDefault f) | f <- genPackageFlags gpd]
        , srManual = [flagName f | f <- genPackageFlags gpd, flagManual f]
        , srLibrary = fromCondTree libNode <$> condLibrary gpd
        , srOthers =
            [other libBuildInfo t | (_, t) <- condSubLibraries gpd]
                ++ [other foreignLibBuildInfo t | (_, t) <- condForeignLibs gpd]
                ++ [other buildInfo t | (_, t) <- condExecutables gpd]
        , srTests = [other testBuildInfo t | (_, t) <- condTestSuites gpd]
        , srBenchmarks = [other benchmarkBuildInfo t | (_, t) <- condBenchmarks gpd]
        , srSetup = setupDeps gpd
        }
  where
    tools = toolsOf (ownName gpd) (ownExecutables gpd)
    libNode lib =
        let bi = libBuildInfo lib
         in LibNode
                { lnDeps = targetBuildDepends bi
                , lnBuildable = buildable bi
                , lnPkgConfig = pkgconfigDepends bi
                , lnTools = tools bi
                }
    other bi = fromCondTree (node . bi) . gateOnBuildable bi
    node bi = Node{nodeDeps = targetBuildDepends bi, nodeTools = tools bi}

-- | The component trees a reduction reads, as one shape: the library, then
-- the sub-libraries, foreign libraries and executables, then the optional
-- stanzas asked for, tests before benchmarks.
componentTrees :: Stanzas -> StoredRelease -> [Tree Node]
componentTrees stanzas sr =
    [fmap asNode t | t <- maybeToList (srLibrary sr)]
        ++ srOthers sr
        ++ (if withTests stanzas then srTests sr else [])
        ++ (if withBenchmarks stanzas then srBenchmarks sr else [])
  where
    asNode ln = Node{nodeDeps = lnDeps ln, nodeTools = lnTools ln}

-- | 'componentDepsAtDefaults' over a stored release.
componentDepsAtDefaultsStored :: Stanzas -> Platform -> CompilerInfo -> StoredRelease -> GuardedDeps
componentDepsAtDefaultsStored = componentDepsStored FixedFlags

-- | Which flags the solver searches.
data FlagModel
    = FixedFlags
      -- ^ every flag at its declared default ('componentDepsAtDefaultsStored')
    | FlagPackages
      -- ^ each automatic flag is a solver variable of its own
      -- ('PubGrub.Variable.FlagVar'); manual flags stay at their defaults
    deriving (Eq, Show)

-- | What a flag resolves to under a model. Under 'FixedFlags' every flag is its
-- default. Under 'FlagPackages' a manual flag is its default and only an
-- automatic flag stays symbolic, so a guard reaching the provider names
-- automatic flags only. A flag the release does not declare is 'False' under
-- either, the convention 'evalCond' documents.
storedFlagEnv :: FlagModel -> StoredRelease -> FlagName -> Either FlagName Bool
storedFlagEnv model sr f
    | model == FlagPackages, Map.member f defaults, f `notElem` srManual sr = Left f
    | otherwise = Right (Map.findWithDefault False f defaults)
  where
    defaults = Map.fromList (srFlags sr)

-- | The guarded dependencies of a stored release under a flag model.
componentDepsStored :: FlagModel -> Stanzas -> Platform -> CompilerInfo -> StoredRelease -> GuardedDeps
componentDepsStored model stanzas platform compiler sr =
    depsWith (storedFlagEnv model sr) stanzas platform compiler sr

-- | The guarded build tools of a stored release under a flag model
-- ('componentTools').
componentToolsStored :: FlagModel -> Stanzas -> Platform -> CompilerInfo -> StoredRelease -> GuardedTools
componentToolsStored model stanzas platform compiler sr =
    toolsWith (storedFlagEnv model sr) stanzas platform compiler sr

-- | Why, and under which flags, a stored release's library cannot be built
-- here: one entry per unusable library node, with its guard resolved under the
-- flag model and its reasons in tree order. A node under a dead branch is
-- dropped.
--
-- Under 'FixedFlags' every guard folds to a literal, so each entry's guard is
-- @Lit True@ and the whole is the verdict 'unbuildableAtDefaults' gives. Under
-- 'FlagPackages' an entry whose guard names an automatic flag is a verdict
-- about the flag values that reach the node, and the provider states it as a
-- guarded unit clause over the release ('PubGrub.Cabal.unbuildable') rather
-- than ruling the release out.
unbuildableStored
    :: FlagModel
    -> PkgConfigPresent
    -> Platform
    -> CompilerInfo
    -> StoredRelease
    -> [(Guard, NonEmpty UnbuildableReason)]
unbuildableStored model db platform compiler sr =
    [ (guard, why)
    | tree <- maybeToList (srLibrary sr)
    , (guard, ln) <- flattenWith env id tree
    , guard /= Lit False
    , Just why <- [NE.nonEmpty (unusable db (lnBuildable ln) (lnPkgConfig ln))]
    ]
  where
    env = envConfVar (storedFlagEnv model sr) platform compiler

-- | 'unbuildableAtDefaults' over a stored release: 'unbuildableStored' under
-- 'FixedFlags', where every guard left is @Lit True@, flattened to its reasons.
unbuildableAtDefaultsStored
    :: PkgConfigPresent -> Platform -> CompilerInfo -> StoredRelease -> [UnbuildableReason]
unbuildableAtDefaultsStored db platform compiler sr =
    concat [NE.toList why | (_, why) <- unbuildableStored FixedFlags db platform compiler sr]
