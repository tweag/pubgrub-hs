{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies      #-}

module Cookbook where

import           Colog.Core            (LogAction (..))
import           Control.Monad         (guard)
import           Data.Functor.Identity (Identity (..))
import           Data.List             (find, sortOn)
import           Data.Map.Strict       (Map)
import qualified Data.Map.Strict       as Map
import           Data.Maybe            (isJust)
import           Data.Ord              (Down (..))
import qualified Data.Set              as Set
import           Data.Text             (Text)
import qualified Data.Text             as T
import           PubGrub
import           PubGrub.SetOps        (isSubsetOf, union)

newtype Name = Name Text
    deriving (Eq, Ord, Show)

data Said
    = Requested Name VersionSet
    | Constrained Name VersionSet
    | DependsOn Name VersionSet Name VersionSet
    | Unusable Name VersionSet Text

data Repo

instance Domain Repo where
    type VarOf Repo = Name
    type ValueOf Repo = Version
    type SetOf Repo = VersionSet
    type FactOf Repo = Said
    singleton _ = singletonVersionSet
    mergeRule = sameDependency

range :: [Int] -> [Int] -> VersionSet
range lo hi = halfOpenVersionSet (mkVersion lo) (Just (mkVersion hi))

request :: Name -> VersionSet -> Incompatibility Repo
request p s = Incompatibility (Map.singleton p (Negative s)) (Seed (Requested p s))

constrain :: Name -> VersionSet -> Incompatibility Repo
constrain p allowed =
    Incompatibility
        (Map.singleton p (Positive (complementVersionSet allowed)))
        (Seed (Constrained p allowed))

data Release = Release
    { needs  :: [(Name, VersionSet)]
    , broken :: Maybe Text
    }

type Index = Map Name [(Version, Release)]

slot :: [Version] -> Version -> VersionSet
slot versions x
    | all (>= x) versions = belowVersionSet next
    | otherwise = halfOpenVersionSet x next
  where
    next = find (> x) versions

dependsOn :: Name -> VersionSet -> Name -> VersionSet -> Incompatibility Repo
dependsOn p ps q qs =
    Incompatibility
        (Map.fromList [(p, Positive ps), (q, Negative qs)])
        (Fact (DependsOn p ps q qs))

provider :: Index -> Provider Repo Identity
provider index = Provider $ \p offered ->
    let releases = Map.findWithDefault [] p index
        versions = map fst releases
        newestFirst = sortOn (Down . fst) [r | r@(x, _) <- releases, offered `contains` x]
        (unusable, usable) = span (isJust . broken . snd) newestFirst
        reasons =
            [ Incompatibility (Map.singleton p (Positive (slot versions x))) (Fact (Unusable p (slot versions x) reason))
            | (x, Release{broken = Just reason}) <- unusable
            ]
     in Identity $ case usable of
            (x, release) : _ -> (Just x, reasons ++ [dependsOn p (slot versions x) q qs | (q, qs) <- needs release])
            []               -> (Nothing, reasons)

app, lib, util, extra :: Name
app = Name "app"
lib = Name "lib"
util = Name "util"
extra = Name "extra"

example :: Index
example =
    Map.fromList
        [ (app, [(mkVersion [1], Release [(lib, range [1] [2, 1])] Nothing)])
        , ( lib
          , [ (mkVersion [1], Release [(util, range [1] [3])] Nothing)
            , (mkVersion [2], Release [(util, range [1] [3])] Nothing)
            , (mkVersion [2, 1], Release [] (Just "it does not build here"))
            ]
          )
        , (util, [(mkVersion [1], Release [] Nothing), (mkVersion [2], Release [] Nothing)])
        , (extra, [(mkVersion [1], Release [] Nothing), (mkVersion [2], Release [] Nothing)])
        ]

plan :: Index -> [Incompatibility Repo] -> Maybe (Map Name Version)
plan index seeds = case runIdentity (solve mempty (provider index) seeds) of
    Right solution -> Just solution
    Left _         -> Nothing

sameDependency :: MergeRule Repo
sameDependency =
    MergeRule
        { mergeKey = \i -> case incompCause i of
            Fact (DependsOn p _ q qs) -> Just (p, q, qs)
            _                         -> Nothing
        , mergeWith = \old new -> case (incompCause old, incompCause new) of
            (Fact (DependsOn p ps q qs), Fact (DependsOn _ ps' _ _)) -> dependsOn p (ps `union` ps') q qs
            _ -> old
        }

name :: Name -> VersionSet -> Text
name (Name p) s = p <> " " <> pretty s

formatter :: Formatter Repo
formatter =
    Formatter
        { sayFact = \fact _ -> case fact of
            Requested p s       -> name p s <> " is requested"
            Constrained p s     -> name p s <> " is required by a constraint"
            DependsOn p ps q qs -> name p ps <> " depends on " <> name q qs
            Unusable p s reason -> name p s <> " cannot be used: " <> reason
        , sayNoValues = \p s -> "no version of " <> name p s <> " exists"
        , sayTerms = summaryWith name name
        , prepare = id
        , lineRules = []
        , clauseRules = [whichDependsOn]
        }

whichDependsOn :: Rule (Incompatibility Repo, Incompatibility Repo) Text
whichDependsOn = symmetric $ \(first, second) -> do
    DependsOn p ps q qs <- asFact first
    DependsOn q' qs' r rs <- asFact second
    guard (q == q' && qs `isSubsetOf` qs')
    pure (name p ps <> " depends on " <> name q qs <> " which depends on " <> name r rs)

why :: Index -> [Incompatibility Repo] -> Text
why index seeds = case runIdentity (solve mempty (provider index) seeds) of
    Right _                -> "There is a plan."
    Left (NoSolution root) -> reportConflict formatter root
    Left _                 -> "The solver failed unexpectedly."

searchLog :: Index -> [Incompatibility Repo] -> [Text]
searchLog index seeds = fst (solve logger (Provider expandLogged) seeds)
  where
    logger = LogAction $ \msg -> (describe msg, ())
    expandLogged p s = ([], runIdentity (expand (provider index) p s))

describe :: SolverMsg Repo -> [Text]
describe msg = case msg of
    Chose (Name p) x            -> [p <> " " <> pretty x]
    NoVersionFor (Name p) s     -> ["no " <> p <> " in " <> pretty s]
    Learned i                   -> ["learned: " <> sayTerms formatter (incompTerms i)]
    Backtracked level           -> ["back to level " <> T.pack (show level)]
    _                           -> []

solveWithLock :: Index -> Map Name Version -> [Incompatibility Repo] -> Either (SolveError Repo) (Map Name Version)
solveWithLock index lock requests = case attempt lock of
    Left (NoSolution root)
        | let involved = Map.keysSet lock `Set.intersection` conflictSet root
        , not (Set.null involved) ->
            attempt (Map.withoutKeys lock involved)
    result -> result
  where
    attempt held =
        runIdentity . solve mempty (provider index) $
            requests ++ [constrain p (singletonVersionSet x) | (p, x) <- Map.toList held]
