{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module SolverSpec (tests) where

import           Colog                 (LogAction, usingLoggerT)
import           Data.Functor.Identity (Identity, runIdentity)
import           Data.List             (isInfixOf, sortBy)
import           Data.Map.Strict       (Map)
import qualified Data.Map.Strict       as Map
import           Data.Maybe            (listToMaybe)
import           Data.Ord              (Down (..), comparing)
import           Distribution.Version  (Version, mkVersion)
import qualified Distribution.Version
import           PubGrub.Solver
import           PubGrub.Types
import           PubGrub.VersionSet    (VersionSet)
import qualified PubGrub.VersionSet    as VS
import           Test.Tasty            (TestTree, testGroup)
import           Test.Tasty.HUnit      (assertBool, testCase, (@?=))

instance Package String

-- | An in-memory registry: package -> version -> its dependencies.
newtype Registry = Registry (Map String (Map Version (Map String VersionSet)))

instance Monad m => DependencyProvider Registry String m where
  chooseVersion (Registry regMap) p range =
    let vs = maybe [] Map.keys (Map.lookup p regMap)
    in pure (listToMaybe (sortBy (comparing Down) (filter (VS.contains range) vs)))
  getDependencies (Registry regMap) p ver =
    pure (Map.findWithDefault Map.empty ver (Map.findWithDefault Map.empty p regMap))

v :: [Int] -> Version
v = mkVersion

geq :: [Int] -> VersionSet
geq = VS.fromVersionRange . Distribution.Version.orLaterVersion . mkVersion

noLog :: LogAction Identity (SolverMsg String)
noLog = mempty

reg :: [(String, [([Int], [(String, VersionSet)])])] -> Registry
reg xs = Registry $ Map.fromList
  [ (p, Map.fromList [ (mkVersion ver, Map.fromList deps) | (ver, deps) <- versions ])
  | (p, versions) <- xs ]

tests :: TestTree
tests = testGroup "Solver"
  [ testCase "rule of resolution combines { p1:t1, p2:¬t2 } and { p2:t2, p3:t3 }" $
      let t1 = Positive (VS.singleton (v [1]))
          t2 = Positive (VS.singleton (v [2]))
          t3 = Positive (VS.singleton (v [3]))
          i1 = Incompatibility
                 (Map.fromList [("p1", t1), ("p2", negateTerm t2)])
                 (FromDependencyOf "p1" VS.full "p2" VS.full)
          i2 = Incompatibility
                 (Map.fromList [("p2", t2), ("p3", t3)])
                 (FromDependencyOf "p2" VS.full "p3" VS.full)
      in incompTerms (priorCause i1 i2 "p2") @?= Map.fromList [("p1", t1), ("p3", t3)]

  , testCase "trivial: root with no deps" $
      let r = reg [("root", [([1], [])])]
      in runIdentity (usingLoggerT noLog (solve r "root" (v [1]))) @?= Right (Map.fromList [("root", v [1])])

  , testCase "transitive: root -> a -> b" $
      let r = reg
            [ ("root", [([1], [("a", VS.full)])])
            , ("a",    [([1], [("b", VS.full)])])
            , ("b",    [([1], [])])
            ]
      in runIdentity (usingLoggerT noLog (solve r "root" (v [1])))
           @?= Right (Map.fromList [("root", v [1]), ("a", v [1]), ("b", v [1])])

  , testCase "backtracking: newest a (2) conflicts, falls back to a (1)" $
      let r = reg
            [ ("root", [([1], [("a", VS.full), ("b", geq [2])])])
            , ("a", [ ([2], [("b", VS.fromVersionRange (Distribution.Version.earlierVersion (mkVersion [2])))])
                    , ([1], [("b", VS.full)]) ])
            , ("b", [ ([2], []), ([1], []) ])
            ]
      in runIdentity (usingLoggerT noLog (solve r "root" (v [1])))
           @?= Right (Map.fromList [("root", v [1]), ("a", v [1]), ("b", v [2])])

  , testCase "unsat: conflicting text requirements (report mentions text)" $
      let r = reg
            [ ("root", [([1], [("aeson", geq [2,2]), ("servant", VS.full)])])
            , ("aeson", [([2,2], [("text", geq [2,0])])])
            , ("servant", [([0,20], [("text", VS.fromVersionRange (Distribution.Version.earlierVersion (mkVersion [2,0])))])])
            , ("text", [([2,0], []), ([1,2], [])])
            ]
      in case runIdentity (usingLoggerT noLog (solve r "root" (v [1]))) of
           Right s -> assertBool ("expected unsat, got " ++ show s) False
           Left (NoSolution i) ->
             let msg = reportConflict i
             in assertBool ("report should mention text: " ++ msg)
                  ("text" `isInfixOf` msg)

  , testCase "no valid version: dependency range has no package version" $
      let r = reg
            [ ("root", [([1], [("a", geq [5])])])
            , ("a", [([1], [])])
            ]
      in case runIdentity (usingLoggerT noLog (solve r "root" (v [1]))) of
           Left _  -> pure ()
           Right s -> assertBool ("expected unsat, got " ++ show s) False
  ]
