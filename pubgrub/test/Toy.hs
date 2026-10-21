{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies      #-}

module Toy where

import           Data.Functor.Identity (Identity, runIdentity)
import           Data.List             (maximumBy)
import           Data.Map.Strict       (Map)
import qualified Data.Map.Strict       as Map
import           Data.Ord              (comparing)
import           Data.Set              (Set)
import qualified Data.Set              as Set
import           Data.Text             (Text)
import qualified Data.Text             as T
import qualified Data.Text.IO          as T
import           PubGrub

newtype Pkg = Pkg String
    deriving (Eq, Ord, Show)

data ToyFact
    = Wants Pkg (Set Int)
    | Needs Pkg Int Pkg (Set Int)

instance Domain Pkg where

    type ValueOf Pkg = Int
    type SetOf Pkg = Set Int
    type FactOf Pkg = ToyFact
    singleton _ v = Set.singleton v

wants :: Pkg -> [Int] -> Incompatibility Pkg
wants p vs = seed (Wants p (Set.fromList vs)) p (Negative (Set.fromList vs))

needs :: Pkg -> Int -> Pkg -> [Int] -> Incompatibility Pkg
needs p v q ws =
    fact (Needs p v q (Set.fromList ws)) [(p, Positive (Set.singleton v)), (q, Negative (Set.fromList ws))]

type World = Map Pkg [(Int, [(Pkg, [Int])])]

app, lib, util :: Pkg
app = Pkg "app"
lib = Pkg "lib"
util = Pkg "util"

world :: World
world =
    Map.fromList
        [ (app, [(1, [(lib, [1, 2])])])
        , (lib, [(1, [(util, [1])]), (2, [(util, [2])])])
        , (util, [(1, [])])
        ]

provider :: World -> Provider Pkg Identity
provider w = Provider $ \p offered ->
    pure $ case [(v, deps) | (v, deps) <- Map.findWithDefault [] p w, v `Set.member` offered] of
        [] -> (Nothing, [])
        candidates ->
            let (v, deps) = maximumBy (comparing fst) candidates
             in (Just v, [needs p v q ws | (q, ws) <- deps])

plan :: World -> [Incompatibility Pkg] -> Maybe (Map Pkg Int)
plan w seeds = case runIdentity (solve mempty (provider w) seeds) of
    Right solution -> Just solution
    Left _         -> Nothing

broken :: World
broken = Map.insert util [(3, [])] world

versions :: Set Int -> Text
versions vs = T.intercalate " or " (map (T.pack . show) (Set.toList vs))

name :: Pkg -> Set Int -> Text
name (Pkg p) vs = T.pack p <> " " <> versions vs

formatter :: Formatter Pkg
formatter = mkFormatter says hole name
  where
    says (Wants p vs) _     = name p vs <> " is requested"
    says (Needs p v q ws) _ = name p (Set.singleton v) <> " depends on " <> name q ws
    hole (Pkg p) vs = T.pack p <> " has no version " <> versions vs

why :: World -> [Incompatibility Pkg] -> Text
why w seeds = case runIdentity (solve mempty (provider w) seeds) of
    Right _                -> "There is a plan."
    Left (NoSolution root) -> reportConflict formatter root
    Left _                 -> "The solver failed unexpectedly."

explain :: World -> [Incompatibility Pkg] -> IO ()
explain w seeds = T.putStrLn (why w seeds)
