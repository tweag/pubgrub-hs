{-# LANGUAGE LambdaCase   #-}
{-# LANGUAGE TypeFamilies #-}

-- Confidence spike for docs/flags-design.md §2.
--
-- Defines SourceConfigSet (as a DNF / union-of-cells) against the REAL
-- PubGrub.Lattice classes and the REAL PubGrub.VersionSet, then validates it is
-- a faithful Boolean algebra of sets by DENOTATION over a small finite universe
-- (3 versions x 2 flags = 12 total configs). Every law prints as PASS/FAIL.
--
-- This is a THROWAWAY validation harness, not part of the build. It is the seed
-- for the real property tests in phasing step 1 (§6). To run it:
--
--     printf ':load docs/flags-spike.hs\nmain\n:quit\n' | cabal repl pubgrub-hs
--
-- (cabal repl resolves the right Cabal-syntax and puts PubGrub.* on the path.)

module Main where

import           Data.List            (foldl')
import           Data.Map.Strict      (Map)
import qualified Data.Map.Strict      as Map
import           Data.Set             (Set)
import qualified Data.Set             as Set
import           Distribution.Version (Version, mkVersion)

import           PubGrub.Lattice
import           PubGrub.VersionSet   (VersionSet)
import qualified PubGrub.VersionSet   as VS

--------------------------------------------------------------------------------
-- Flag conjunction cell.  A cell's flag constraint is just a Map of pinned
-- flags (absent = unconstrained) plus a bottom sentinel.  NB: no `BoolSet` is
-- needed, and this is NOT a Boolean instance (it is not closed under neg).
--------------------------------------------------------------------------------

type Flag = Char
type Config = (Version, Map Flag Bool)  -- an element: version + TOTAL flag map

data FlagConj = FCBottom | FCConj (Map Flag Bool)
    deriving (Eq, Ord, Show)

fcTop :: FlagConj
fcTop = FCConj Map.empty

fcMeet :: FlagConj -> FlagConj -> FlagConj
fcMeet FCBottom _ = FCBottom
fcMeet _ FCBottom = FCBottom
fcMeet (FCConj a) (FCConj b)
    | and (Map.elems (Map.intersectionWith (==) a b)) = FCConj (Map.union a b)
    | otherwise = FCBottom

-- complement of a conjunction = union of single-flag flips
fcNeg :: FlagConj -> [FlagConj]
fcNeg FCBottom = [fcTop]
fcNeg (FCConj c)
    | Map.null c = []
    | otherwise = [FCConj (Map.singleton f (not b)) | (f, b) <- Map.toList c]

-- leniency: a constrained-but-undeclared flag is vacuously satisfied
fcMember :: Map Flag Bool -> FlagConj -> Bool
fcMember _ FCBottom = False
fcMember m (FCConj c) = all ok (Map.toList c)
  where
    ok (f, b) = maybe True (== b) (Map.lookup f m)

--------------------------------------------------------------------------------
-- Cell = versionset x flag-conjunction (a "rectangle" in version x flag space)
--------------------------------------------------------------------------------

data Cell = Cell VersionSet FlagConj
    deriving (Show)

cellEmpty :: Cell -> Bool
cellEmpty (Cell vs fc) = isBottom vs || fc == FCBottom

cellMeet :: Cell -> Cell -> Cell
cellMeet (Cell v1 f1) (Cell v2 f2) = Cell (v1 /\ v2) (fcMeet f1 f2)

cellMember :: Config -> Cell -> Bool
cellMember (v, m) (Cell vs fc) = VS.contains vs v && fcMember m fc

--------------------------------------------------------------------------------
-- SourceConfigSet = union of cells (DNF).  Normalization only drops empty
-- cells.  Eq / isBottom / isTop are SEMANTIC (not derived).
--------------------------------------------------------------------------------

newtype SCS = SCS [Cell]
    deriving (Show)

-- Normalize: drop empty cells, then drop cells subsumed by another kept cell.
-- Subsumption is tested by finite denotation over `universe` (spike-only, to
-- curb DNF cell-count blowup; it never changes membership, only prunes
-- redundant cells).
mkSCS :: [Cell] -> SCS
mkSCS = SCS . dedup . filter (not . cellEmpty)
  where
    key c = filter (`cellMember` c) universe
    sub xs ys = all (`elem` ys) xs
    dedup = go []
      where
        go seen [] = reverse seen
        go seen (c : cs)
            | any (\s -> sub (key c) (key s)) seen = go seen cs
            | otherwise = go (c : filter (\s -> not (sub (key s) (key c))) seen) cs

cellsOf :: SCS -> [Cell]
cellsOf (SCS cs) = cs

instance Lattice SCS where
    SCS a \/ SCS b = mkSCS (a ++ b)
    SCS a /\ SCS b = mkSCS [cellMeet x y | x <- a, y <- b]

instance BoundedLattice SCS where
    bottom = SCS []
    top = SCS [Cell VS.full fcTop]
    isBottom = null . cellsOf -- reliable: mkSCS drops all empty cells
    isTop s = isBottom (neg s) -- SEMANTIC, not (== top)

instance Boolean SCS where
    neg (SCS cs) = foldl' (/\) top (map negCell cs) -- De Morgan
      where
        negCell (Cell vs fc) =
            mkSCS (Cell (neg vs) fcTop : [Cell VS.full f | f <- fcNeg fc])

instance Eq SCS where
    a == b = subsetOf a b && subsetOf b a -- SEMANTIC (mutual subset)

instance Sets SCS where
    type Elem SCS = Config
    singleton (v, m) = SCS [Cell (VS.singleton v) (FCConj m)]
    member e s = any (cellMember e) (cellsOf s)

--------------------------------------------------------------------------------
-- Finite universe and denotation
--------------------------------------------------------------------------------

flags2 :: [Flag]
flags2 = ['a', 'b']

allAssignments :: [Map Flag Bool]
allAssignments =
    [Map.fromList (zip flags2 bs) | bs <- mapM (const [False, True]) flags2]

vers :: [Version]
vers = [mkVersion [1], mkVersion [2], mkVersion [3]]

universe :: [Config]
universe = [(v, m) | v <- vers, m <- allAssignments]

denot :: SCS -> Set Config
denot s = Set.fromList [e | e <- universe, member e s]

constrainFlag :: Flag -> Bool -> SCS
constrainFlag f b = SCS [Cell VS.full (FCConj (Map.singleton f b))]

testSets :: [SCS]
testSets =
    [bottom, top]
        ++ [singleton e | e <- universe]
        ++ [constrainFlag f b | f <- flags2, b <- [False, True]]
        ++ [SCS [Cell (VS.singleton (mkVersion [2])) fcTop]]
        ++ [neg (singleton e) | e <- take 3 universe]
        ++ [ singleton (universe !! 0) \/ singleton (universe !! 5)
           , singleton (universe !! 1) /\ constrainFlag 'a' True
           , constrainFlag 'a' True /\ constrainFlag 'b' False
           ]

--------------------------------------------------------------------------------

reportAll :: String -> [Bool] -> IO ()
reportAll name results =
    let n = length results
        bad = length (filter not results)
     in putStrLn $
            (if bad == 0 then "PASS  " else "FAIL  ")
                ++ name
                ++ "  ("
                ++ show (n - bad)
                ++ "/"
                ++ show n
                ++ ")"

main :: IO ()
main = do
    putStrLn "=== SPIKE: SourceConfigSet as a Boolean algebra of sets ==="
    let u = Set.fromList universe
        ts = testSets
        pairs = [(a, b) | a <- ts, b <- ts]
        tri = [(a, b, c) | a <- take 8 ts, b <- take 8 ts, c <- take 8 ts]
    putStrLn ("universe = " ++ show (length universe) ++ " configs, testSets = " ++ show (length ts))
    putStrLn "--- denotation homomorphism (algebra op == set op) ---"
    reportAll "denot(a\\/b) = denot a U denot b" [denot (a \/ b) == Set.union (denot a) (denot b) | (a, b) <- pairs]
    reportAll "denot(a/\\b) = denot a & denot b" [denot (a /\ b) == Set.intersection (denot a) (denot b) | (a, b) <- pairs]
    reportAll "denot(neg a) = U \\ denot a       " [denot (neg a) == Set.difference u (denot a) | a <- ts]
    reportAll "member e a = e in denot a        " [member e a == Set.member e (denot a) | a <- ts, e <- universe]
    reportAll "singleton e denotes {e}          " [denot (singleton e) == Set.singleton e | e <- universe]
    reportAll "isBottom a = (denot a empty)     " [isBottom a == Set.null (denot a) | a <- ts]
    reportAll "isTop a    = (denot a == U)      " [isTop a == (denot a == u) | a <- ts]
    reportAll "semantic (a==b)=(denot a==denot b)" [(a == b) == (denot a == denot b) | (a, b) <- pairs]
    putStrLn "--- abstract Boolean laws (via semantic ==) ---"
    reportAll "idempotent  \\/                   " [(a \/ a) == a | a <- ts]
    reportAll "idempotent  /\\                   " [(a /\ a) == a | a <- ts]
    reportAll "commutative \\/                   " [(a \/ b) == (b \/ a) | (a, b) <- pairs]
    reportAll "commutative /\\                   " [(a /\ b) == (b /\ a) | (a, b) <- pairs]
    reportAll "absorption a\\/(a/\\b)=a          " [(a \/ (a /\ b)) == a | (a, b) <- pairs]
    reportAll "absorption a/\\(a\\/b)=a          " [(a /\ (a \/ b)) == a | (a, b) <- pairs]
    reportAll "complement a/\\neg a = bottom     " [isBottom (a /\ neg a) | a <- ts]
    reportAll "complement a\\/neg a = top        " [isTop (a \/ neg a) | a <- ts]
    reportAll "double negation                  " [neg (neg a) == a | a <- ts]
    reportAll "De Morgan neg(a\\/b)=neg a/\\neg b" [neg (a \/ b) == (neg a /\ neg b) | (a, b) <- pairs]
    reportAll "associative \\/                   " [((a \/ b) \/ c) == (a \/ (b \/ c)) | (a, b, c) <- tri]
    reportAll "associative /\\                   " [((a /\ b) /\ c) == (a /\ (b /\ c)) | (a, b, c) <- tri]
    putStrLn "--- leniency & backtracking (targeted) ---"
    let onlyA v b = (v, Map.fromList [('a', b)]) -- a version that declares ONLY flag 'a'
    putStrLn $ "lenient   : (declares only a, a=True) satisfies constraint b=True  -> " ++ show (member (onlyA (mkVersion [1]) True) (constrainFlag 'b' True)) ++ "  (expect True)"
    putStrLn $ "strict    : (a=True) violates constraint a=False                   -> " ++ show (member (onlyA (mkVersion [1]) True) (constrainFlag 'a' False)) ++ "  (expect False)"
    let dec = singleton (mkVersion [2], Map.fromList [('a', True), ('b', True)]) :: SCS
        nd = neg dec
    putStrLn $ "backtrack : neg(decision) excludes the decided (v2,a,b)            -> " ++ show (member (mkVersion [2], Map.fromList [('a', True), ('b', True)]) nd) ++ "  (expect False)"
    putStrLn $ "backtrack : neg(decision) keeps (v2, a=False,b=True)               -> " ++ show (member (mkVersion [2], Map.fromList [('a', False), ('b', True)]) nd) ++ "  (expect True)"
    putStrLn $ "backtrack : neg(decision) keeps (v1, a=True,b=True)                -> " ++ show (member (mkVersion [1], Map.fromList [('a', True), ('b', True)]) nd) ++ "  (expect True)"
    putStrLn "--- semantic Eq necessity ---"
    let e0 = (mkVersion [1], Map.fromList [('a', False), ('b', False)])
        top2 = singleton e0 \/ neg (singleton e0)
    putStrLn $ "top2 == top (semantic) -> " ++ show (top2 == top) ++ "   [structural cells: top2=" ++ show (length (cellsOf top2)) ++ ", top=" ++ show (length (cellsOf top)) ++ " -> deriving Eq would say False]"
    putStrLn "=== SPIKE DONE ==="
