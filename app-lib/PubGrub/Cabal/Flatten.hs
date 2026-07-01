{-# LANGUAGE LambdaCase #-}

-- | Extract a GenericPackageDescription's dependencies as a function of its
-- flag assignment, without Cabal's @finalizePD@ (which also does dependency
-- resolution and flag defaulting we don't want).
--
-- The conditional dependency tree is flattened to 'GuardedDeps' — a list of
-- @(flag guard, deps)@ groups — with the fixed environment (operating system,
-- architecture, compiler) already resolved and only flag conditions left
-- symbolic. 'depsAt' then evaluates those guards at a concrete flag assignment.
module PubGrub.Cabal.Flatten (
    GuardedDeps,
    componentDeps,
    depsAt,
    flattenDeps,
) where

import           Data.Map.Strict                              (Map)
import qualified Data.Map.Strict                              as Map
import           Data.Maybe                                   (maybeToList)
import           Distribution.Compiler                        (CompilerId (..),
                                                               CompilerInfo,
                                                               compilerInfoId)
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
import           Distribution.Types.Flag                      (FlagName,
                                                               flagDefault,
                                                               flagName)
import           Distribution.Types.GenericPackageDescription (GenericPackageDescription (..))
import           Distribution.Types.PackageName               (PackageName)
import           Distribution.Version                         (withinRange)
import           PubGrub.VersionSet                           (VersionSet)
import qualified PubGrub.VersionSet                           as VS

-- | A package's dependencies as flag-guarded groups: each dependency list is
-- active exactly when its 'Condition' over flag names holds. The environment
-- (OS, arch, compiler) is already resolved away, so guards mention only flags.
type GuardedDeps = [(Condition FlagName, [Dependency])]

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
evalCond :: Map FlagName Bool -> Condition FlagName -> Bool
evalCond flags = go
  where
    go (Var f)    = Map.findWithDefault False f flags
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
depsAt :: Map FlagName Bool -> GuardedDeps -> Map PackageName VersionSet
depsAt flags guarded =
    Map.fromListWith
        VS.intersection
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
flattenDeps :: Platform -> CompilerInfo -> GenericPackageDescription -> Map PackageName VersionSet
flattenDeps platform compiler gpd =
    depsAt (defaultFlags gpd) (componentDeps platform compiler gpd)
