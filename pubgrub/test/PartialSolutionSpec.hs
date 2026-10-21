-- | Differential tests for the partial solution's storage layer.
--
-- 'PubGrub.PartialSolution.PartialSolution' indexes assignments by variable and
-- caches, per variable, the intersection of its assignments' terms and the
-- value it was decided to be. The caches are what let unit propagation ask
-- about a variable without scanning; they are also the only thing that can be
-- wrong. Backtracking is where they can be wrong most quietly: @intersectTerm@
-- cannot be undone, so a variable that loses assignments must have its term
-- rebuilt from the survivors, and a dropped decision must stop being
-- remembered.
--
-- The model below is the naive implementation: one flat chronological list,
-- every query a scan. It has no caches to invalidate, so agreement with it is
-- exactly the property at issue.
module PartialSolutionSpec (tests) where

import qualified Data.Map.Strict         as Map
import           Data.Maybe              (mapMaybe)
import           Data.Set                (Set)
import qualified Data.Set                as Set
import           PubGrub.Incompatibility (Incompatibility, incompGet, noValues)
import           PubGrub.PartialSolution (Assignment (..), AssignmentKind (..),
                                          PartialSolution (..), addDecision,
                                          addDerivation, assignmentTerm,
                                          backtrack, decidedValue, emptyPS,
                                          extractSolution, termIntersectionFor,
                                          undecidedPositive, varHistory)
import           PubGrub.SetOps          (equivalent)
import           PubGrub.Term            (Term (..), anyTerm, intersectTerm,
                                          negateTerm)
import           Test.Tasty              (TestTree, testGroup)
import           Test.Tasty.QuickCheck   (Arbitrary (..), Gen, Property,
                                          conjoin, counterexample, elements,
                                          frequency, testProperty)
import           Toy                     (Pkg (..), needs, wants)

-- --------------------------------------------------------------------------
-- The universe the scripts draw from
-- --------------------------------------------------------------------------

-- | Probe packages. Every query is checked for all of them, so keep the list
-- short — and keep it a superset of what the generators use, so that packages
-- which were never mentioned (the @Nothing@ / @⊤@ case) are checked too.
packages :: [Pkg]
packages = map Pkg ["a", "b", "c", "d"]

instances :: [Int]
instances = [1 .. 3]

-- | Range-shaped sets over the versions 1 to 3: at least 2, below 3, exactly 2.
sets :: [Set Int]
sets = map Set.fromList [[2, 3], [1, 2], [2]]

-- | The incompatibilities a derivation can be caused by: unit bans (which
-- derive a negative term), \"no versions\" (positive), and real two-package
-- dependencies — so that deriving for a package the incompatibility does /not/
-- mention (⊤, the term-absent case) is reachable too.
incompatibilities :: [Incompatibility Pkg]
incompatibilities =
    [wants p [i] | p <- packages, i <- instances]
        ++ [noValues p s | p <- packages, s <- sets]
        ++ [ needs p 2 q (Set.toList t)
           | (p, q) <- zip packages (drop 1 packages)
           , t <- sets
           ]

atIndex :: [a] -> Int -> Maybe a
atIndex xs n = case drop (n `mod` max 1 (length xs)) xs of
    x : _ -> Just x
    []    -> Nothing

-- --------------------------------------------------------------------------
-- Op scripts
-- --------------------------------------------------------------------------

-- | One step of a script. Indices are taken modulo the universe's size, and a
-- backtrack level modulo the current level plus one, so every generated script
-- is meaningful without a shrink-hostile precondition.
--
-- Deciding a package twice is allowed on purpose: the solver never does it
-- (a decided package's term is a singleton, which is never inconclusive, so it
-- is never chosen again), but the caches should not depend on that.
data Op
    = OpDecide Int Int
    | OpDerive Int Int
    | OpBacktrack Int
    deriving (Show)

instance Arbitrary Op where
    arbitrary =
        frequency
            [ (3, OpDecide <$> ix <*> ix)
            , (6, OpDerive <$> ix <*> ix)
            , (2, OpBacktrack <$> ix)
            ]
      where
        ix = elements [0 .. 11] :: Gen Int
    shrink (OpDecide a b)  = [OpDecide a' b' | (a', b') <- shrink (a, b)]
    shrink (OpDerive a b)  = [OpDerive a' b' | (a', b') <- shrink (a, b)]
    shrink (OpBacktrack a) = map OpBacktrack (shrink a)

-- | The model: one flat chronological list of assignments.
data Model = Model
    { mAssignments :: [Assignment Pkg]
    , mLevel       :: Int
    , mNextIndex   :: Int
    }

emptyModel :: Model
emptyModel = Model{mAssignments = [], mLevel = 0, mNextIndex = 0}

mDecide :: Pkg -> Int -> Model -> Model
mDecide p i (Model as l n) =
    Model (as ++ [Assignment n (l + 1) p (Decision i)]) (l + 1) (n + 1)

mDerive :: Pkg -> Incompatibility Pkg -> Model -> Model
mDerive p cause (Model as l n) =
    Model (as ++ [Assignment n l p (Derivation term cause)]) l (n + 1)
  where
    term = maybe anyTerm negateTerm (incompGet p cause)

mBacktrack :: Int -> Model -> Model
mBacktrack level (Model as _ n) = Model (filter ((<= level) . aLevel) as) level n

mHistory :: Model -> Pkg -> [Assignment Pkg]
mHistory m p = filter ((== p) . aVar) (mAssignments m)

mTerm :: Model -> Pkg -> Maybe (Term (Set Int))
mTerm m p = case map assignmentTerm (mHistory m p) of
    []     -> Nothing
    t : ts -> Just (foldl intersectTerm t ts)

mSolution :: Model -> Map.Map Pkg Int
mSolution m =
    Map.fromList
        [(aVar a, i) | a <- mAssignments m, Just i <- [decidedValue a]]

mUndecidedPositive :: Model -> [(Pkg, Set Int)]
mUndecidedPositive m =
    mapMaybe positive (filter (`notElem` decided) pkgs)
  where
    decided = [aVar a | a <- mAssignments m, Just _ <- [decidedValue a]]
    pkgs = uniqueOldestFirst [aVar a | a <- mAssignments m]
    positive p = case mTerm m p of
        Just (Positive r) -> Just (p, r)
        _                 -> Nothing
    uniqueOldestFirst = go []
      where
        go seen [] = reverse seen
        go seen (x : xs)
            | x `elem` seen = go seen xs
            | otherwise = go (x : seen) xs

-- | Apply one op to both, so a script drives them in lockstep.
step :: Op -> (PartialSolution Pkg, Model) -> (PartialSolution Pkg, Model)
step op (ps, m) = case op of
    OpDecide pi_ ii -> case (atIndex packages pi_, atIndex instances ii) of
        (Just p, Just i) -> (addDecision p i ps, mDecide p i m)
        _                -> (ps, m)
    OpDerive pi_ ci -> case (atIndex packages pi_, atIndex incompatibilities ci) of
        (Just p, Just c) -> (addDerivation p c ps, mDerive p c m)
        _                -> (ps, m)
    OpBacktrack k ->
        let level = k `mod` (psLevel ps + 1)
         in (snd (backtrack level ps), mBacktrack level m)

-- --------------------------------------------------------------------------
-- Comparisons
-- --------------------------------------------------------------------------

-- | Terms are compared up to set equivalence, which with canonical sets is
-- equality; the semantic form says what is being compared.
termEquiv :: Term (Set Int) -> Term (Set Int) -> Bool
termEquiv (Positive x) (Positive y) = equivalent x y
termEquiv (Negative x) (Negative y) = equivalent x y
termEquiv _ _                       = False

maybeTermEquiv :: Maybe (Term (Set Int)) -> Maybe (Term (Set Int)) -> Bool
maybeTermEquiv Nothing Nothing   = True
maybeTermEquiv (Just x) (Just y) = termEquiv x y
maybeTermEquiv _ _               = False

-- | An assignment's identity, ignoring the term (compared separately, by
-- equivalence).
key :: Assignment Pkg -> (Int, Int, Pkg, Maybe Int)
key a = (aIndex a, aLevel a, aVar a, decidedValue a)

check :: String -> Bool -> Property
check what = counterexample ("mismatch: " ++ what)

-- | Every query, on both, for every probe package.
agree :: PartialSolution Pkg -> Model -> Property
agree ps m =
    conjoin $
        [ check "psLevel" (psLevel ps == mLevel m)
        , check "extractSolution" (extractSolution ps == mSolution m)
        , check
            "undecidedPositive (packages)"
            (map fst (undecidedPositive ps) == map fst (mUndecidedPositive m))
        , check
            "undecidedPositive (sets)"
            ( and
                [ equivalent x y
                | ((_, x), (_, y)) <- zip (undecidedPositive ps) (mUndecidedPositive m)
                ]
            )
        ]
            ++ concatMap perPackage packages
  where
    perPackage p =
        [ check
            ("varHistory " ++ show p)
            (map key (varHistory ps p) == map key (mHistory m p))
        , check
            ("varHistory terms " ++ show p)
            ( and
                [ termEquiv (assignmentTerm x) (assignmentTerm y)
                | (x, y) <- zip (varHistory ps p) (mHistory m p)
                ]
            )
        , check
            ("termIntersectionFor " ++ show p)
            (maybeTermEquiv (termIntersectionFor ps p) (mTerm m p))
        ]

-- | Run a script, checking after every op — so the first divergence is
-- reported at the op that caused it, not at the end of the script.
runScript :: [Op] -> Property
runScript ops =
    conjoin
        [ counterexample ("after " ++ show op) (agree ps m)
        | (op, (ps, m)) <- zip ops (drop 1 (scanl (flip step) (emptyPS, emptyModel) ops))
        ]

-- | Unbiased scripts mostly backtrack to a level near the top, because levels
-- only rise a step at a time; a rebuild needs a backtrack that actually drops
-- something. Sprinkling extra backtracks in is what forces them.
interleaveBacktracks :: [Op] -> [Op]
interleaveBacktracks ops =
    concat
        [ if n `mod` 3 == (2 :: Int) then [op, OpBacktrack n] else [op]
        | (n, op) <- zip [0 ..] ops
        ]

-- | 'backtrack' names exactly the variables whose history it shortened: from
-- every state a script reaches, to every level there is.
movedAreTheShortened :: [Op] -> Property
movedAreTheShortened ops =
    conjoin
        [ counterexample ("backtracking to " ++ show level ++ " after " ++ show n ++ " ops") $
            Set.fromList moved == Set.fromList [p | p <- packages, length (varHistory ps' p) < length (varHistory ps p)]
        | (n, (ps, _)) <- zip [0 :: Int ..] (scanl (flip step) (emptyPS, emptyModel) ops)
        , level <- [0 .. psLevel ps]
        , let (moved, ps') = backtrack level ps
        ]

tests :: TestTree
tests =
    testGroup
        "PartialSolution (indexed vs flat-list model)"
        [ testProperty "every query agrees with the naive model, op by op" runScript
        , testProperty "…on scripts that backtrack heavily" $
            runScript . interleaveBacktracks
        , testProperty "backtrack names exactly the variables it moved" movedAreTheShortened
        ]
