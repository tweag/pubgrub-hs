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
    depsAt,
    flattenDeps,
    defaultFlags,
    expandGuard,
    prettyMap,
    parseCondition,
    Guard,
) where

import           Control.Applicative                          (Alternative (..))
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
import           Distribution.Types.GenericPackageDescription (GenericPackageDescription (..))
import           Distribution.Types.PackageName               (PackageName)
import           Distribution.Version                         (withinRange)
import           PubGrub.VersionSet                           (VersionSet)
import qualified PubGrub.VersionSet                           as VS

type Guard = Condition FlagName

-- | A package's dependencies as flag-guarded groups: each dependency list is
-- active exactly when its 'Condition' over flag names holds. The environment
-- (OS, arch, compiler) is already resolved away, so guards mention only flags.
type GuardedDeps = [(Guard, [Dependency])]

-- | Resolve the fixed environment: OS, arch and compiler conditions become
-- concrete @Right@ booleans; flag conditions stay symbolic as @Left flag@.
envConfVar :: Platform -> CompilerInfo -> ConfVar -> Either FlagName Bool
envConfVar (Platform arch os) compiler = \case
    OS o -> Right (o == os)
    Arch a -> Right (a == arch)
    Impl flavor range ->
        let CompilerId f v = compilerInfoId compiler
         in Right (f == flavor && withinRange v range)
    PackageFlag f -> Left f

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

-- | Flatten one component's conditional tree, pushing each branch condition
-- (with the environment resolved) down as an accumulated flag guard.
flattenComponent
    :: (ConfVar -> Either FlagName Bool)
    -> CondTree ConfVar [Dependency] a
    -> GuardedDeps
flattenComponent env = go (Lit True)
  where
    go guard (CondNode _data deps branches) =
        (guard, deps) : concatMap (goBranch guard) branches
    goBranch guard (CondBranch cond ifTrue mIfFalse) =
        let (cond', _free) = simplifyCondition cond env
            whenTrue = go (guard `cAnd` cond') ifTrue
            whenFalse = maybe [] (go (guard `cAnd` cNot cond')) mIfFalse
         in whenTrue ++ whenFalse

-- | Flatten the library, sub-library and executable conditional dependency
-- trees to flag-guarded groups, resolving OS\/arch\/compiler conditions against
-- the given platform and compiler. Test-suites, benchmarks and foreign
-- libraries are intentionally excluded.
componentDeps :: Platform -> CompilerInfo -> GenericPackageDescription -> GuardedDeps
componentDeps platform compiler gpd =
    concat $
        [flattenComponent env t | t <- maybeToList (condLibrary gpd)]
            ++ [flattenComponent env t | (_, t) <- condSubLibraries gpd]
            ++ [flattenComponent env t | (_, t) <- condExecutables gpd]
  where
    env = envConfVar platform compiler

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
