{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module PowSpec (tests) where

import qualified Data.Set              as Set
import           PubGrub.Lattice
import           PubGrub.Pow           (Pow (..))
import           Test.Tasty            (TestTree, testGroup)
import           Test.Tasty.QuickCheck (Arbitrary (..), Gen, elements, listOf,
                                        testProperty, (===))

-- Small domain so cofinite sets are exercised.
genElem :: Gen Int
genElem = elements [0 .. 5]

instance Arbitrary (Pow Int) where
    arbitrary = do
        wrap <- elements [Incl, Excl]
        xs <- listOf genElem
        pure (wrap (Set.fromList xs))

-- Reference membership over the test domain {0..5}.
ref :: Pow Int -> Set.Set Int
ref p = Set.fromList [x | x <- [0 .. 5], member x p]

tests :: TestTree
tests =
    testGroup
        "Pow"
        [ testProperty "neg is involutive" $ \(p :: Pow Int) ->
            ref (neg (neg p)) === ref p
        , testProperty "neg complements membership" $ \(p :: Pow Int) ->
            ref (neg p) === Set.difference (Set.fromList [0 .. 5]) (ref p)
        , testProperty "join is union of membership" $ \(a :: Pow Int) b ->
            ref (a \/ b) === Set.union (ref a) (ref b)
        , testProperty "meet is intersection of membership" $ \(a :: Pow Int) b ->
            ref (a /\ b) === Set.intersection (ref a) (ref b)
        , testProperty "bottom is empty" $
            ref (bottom :: Pow Int) === Set.empty
        , testProperty "top is the whole domain" $
            ref (top :: Pow Int) === Set.fromList [0 .. 5]
        , testProperty "member of singleton" $ \(x :: Int) ->
            member x (singleton x :: Pow Int) === True
        , -- 'ref' only sees the finite domain {0..5}, so it cannot witness global
          -- emptiness: a cofinite @Excl {0..5}@ is empty within the domain yet is
          -- not the global 'bottom'. So check 'isBottom'/'isTop' against the
          -- canonical representatives directly (only the empty 'Incl' is bottom;
          -- only the empty 'Excl' is top).
          testProperty "isBottom holds only for the empty Incl set" $ \(p :: Pow Int) ->
            isBottom p === (case p of Incl s -> Set.null s; Excl _ -> False)
        , testProperty "isTop holds only for the empty Excl set" $ \(p :: Pow Int) ->
            isTop p === (case p of Excl s -> Set.null s; Incl _ -> False)
        ]
