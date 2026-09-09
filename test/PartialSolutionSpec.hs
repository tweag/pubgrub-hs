-- | Differential tests for the partial solution's storage layer.
--
-- 'PubGrub.Solver.PartialSolution' indexes assignments by package and caches,
-- per package, the intersection of its assignments' terms and the instance it
-- was decided to be. The caches are what let unit propagation ask about a
-- package without scanning; they are also the only thing that can be wrong.
-- Backtracking is where they can be wrong most quietly: @intersectTerm@ cannot
-- be undone, so a package that loses assignments must have its term rebuilt
-- from the survivors, and a dropped decision must stop being remembered.
--
-- The model below is the naive implementation: one flat chronological list,
-- every query a scan. It has no caches to invalidate, so agreement with it is
-- exactly the property at issue.
module PartialSolutionSpec (tests) where

import qualified Data.Map.Strict                 as Map
import           Data.Maybe                      (mapMaybe)
import qualified Data.Set                        as Set
import           Distribution.Types.Flag         (mkFlagAssignment)
import           Distribution.Types.PackageName  (PackageName, mkPackageName)
import           Distribution.Types.Version      (mkVersion)
import qualified PubGrub.Version                 as V
import           Distribution.Types.VersionRange (earlierVersion,
                                                  orLaterVersion, thisVersion)
import           PubGrub.Incompatibility         (Incompatibility, anyTerm,
                                                  fromDependency, incompGet,
                                                  noInstances, notRoot)
import           PubGrub.InstanceSet             (Instance (..),
                                                  InstanceSet (..))
import           PubGrub.InstanceSet.SourceCell  (SourceCell (..))
import           PubGrub.SetOps                  (equivalent)
import           PubGrub.Solver                  (Assignment (..),
                                                  AssignmentKind (..),
                                                  PartialSolution (..),
                                                  addDecision, addDerivation,
                                                  assignmentTerm, backtrack,
                                                  decidedInstance, emptyPS,
                                                  extractSolution,
                                                  packageHistory,
                                                  termIntersectionForPackage,
                                                  undecidedPositive)
import           PubGrub.Term                    (Term (..), intersectTerm,
                                                  negateTerm)
import qualified PubGrub.VersionSet              as VersionSet
import           Test.Tasty                      (TestTree, testGroup)
import           Test.Tasty.QuickCheck           (Arbitrary (..), Gen, Property,
                                                  conjoin, counterexample,
                                                  elements, frequency,
                                                  testProperty)

-- --------------------------------------------------------------------------
-- The universe the scripts draw from
-- --------------------------------------------------------------------------

-- | Probe packages. Every query is checked for all of them, so keep the list
-- short — and keep it a superset of what the generators use, so that packages
-- which were never mentioned (the @Nothing@ / @⊤@ case) are checked too.
packages :: [PackageName]
packages = map mkPackageName ["a", "b", "c", "d"]

instances :: [Instance]
instances = [BuildSource (V.mkVersion [k]) (mkFlagAssignment []) | k <- [1 .. 3]]

-- | Range-shaped instance sets, built with the intensional constructor: one
-- cell carrying a version range, as the provider mints them.
sets :: [InstanceSet]
sets =
    [ InstanceSet{isInstalled = Set.empty, isSource = [SourceCell vs Map.empty]}
    | vs <-
        map
            VersionSet.fromVersionRange
            [ orLaterVersion (mkVersion [2])
            , earlierVersion (mkVersion [3])
            , thisVersion (mkVersion [2])
            ]
    ]

-- | The incompatibilities a derivation can be caused by: unit bans (which
-- derive a negative term), \"no instances\" (positive), and real two-package
-- dependencies — so that deriving for a package the incompatibility does /not/
-- mention (⊤, the term-absent case) is reachable too.
incompatibilities :: [Incompatibility]
incompatibilities =
    [notRoot p i | p <- packages, i <- instances]
        ++ [noInstances p s | p <- packages, s <- sets]
        ++ [ fromDependency p s q t
           | (p, q) <- zip packages (drop 1 packages)
           , s <- take 1 sets
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
    { mAssignments :: [Assignment]
    , mLevel       :: Int
    , mNextIndex   :: Int
    }

emptyModel :: Model
emptyModel = Model{mAssignments = [], mLevel = 0, mNextIndex = 0}

mDecide :: PackageName -> Instance -> Model -> Model
mDecide p i (Model as l n) =
    Model (as ++ [Assignment n (l + 1) p (Decided i)]) (l + 1) (n + 1)

mDerive :: PackageName -> Incompatibility -> Model -> Model
mDerive p cause (Model as l n) =
    Model (as ++ [Assignment n l p (Derived term cause)]) l (n + 1)
  where
    term = maybe anyTerm negateTerm (incompGet p cause)

mBacktrack :: Int -> Model -> Model
mBacktrack level (Model as _ n) = Model (filter ((<= level) . aLevel) as) level n

mHistory :: Model -> PackageName -> [Assignment]
mHistory m p = filter ((== p) . aPackage) (mAssignments m)

mTerm :: Model -> PackageName -> Maybe (Term InstanceSet)
mTerm m p = case map assignmentTerm (mHistory m p) of
    []     -> Nothing
    t : ts -> Just (foldl intersectTerm t ts)

mSolution :: Model -> Map.Map PackageName Instance
mSolution m =
    Map.fromList
        [(aPackage a, i) | a <- mAssignments m, Just i <- [decidedInstance a]]

mUndecidedPositive :: Model -> [(PackageName, InstanceSet)]
mUndecidedPositive m =
    mapMaybe positive (filter (`notElem` decided) pkgs)
  where
    decided = [aPackage a | a <- mAssignments m, Just _ <- [decidedInstance a]]
    pkgs = uniqueOldestFirst [aPackage a | a <- mAssignments m]
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
step :: Op -> (PartialSolution, Model) -> (PartialSolution, Model)
step op (ps, m) = case op of
    OpDecide pi_ ii -> case (atIndex packages pi_, atIndex instances ii) of
        (Just p, Just i) -> (addDecision p i ps, mDecide p i m)
        _                -> (ps, m)
    OpDerive pi_ ci -> case (atIndex packages pi_, atIndex incompatibilities ci) of
        (Just p, Just c) -> (addDerivation p c ps, mDerive p c m)
        _                -> (ps, m)
    OpBacktrack k ->
        let level = k `mod` (psLevel ps + 1)
         in (backtrack level ps, mBacktrack level m)

-- --------------------------------------------------------------------------
-- Comparisons
-- --------------------------------------------------------------------------

-- | Terms are compared up to set equivalence, not structurally: 'InstanceSet'
-- is a non-canonical DNF and has no lawful @Eq@.
termEquiv :: Term InstanceSet -> Term InstanceSet -> Bool
termEquiv (Positive x) (Positive y) = equivalent x y
termEquiv (Negative x) (Negative y) = equivalent x y
termEquiv _ _                       = False

maybeTermEquiv :: Maybe (Term InstanceSet) -> Maybe (Term InstanceSet) -> Bool
maybeTermEquiv Nothing Nothing   = True
maybeTermEquiv (Just x) (Just y) = termEquiv x y
maybeTermEquiv _ _               = False

-- | An assignment's identity, ignoring the term (compared separately, by
-- equivalence).
key :: Assignment -> (Int, Int, PackageName, Maybe Instance)
key a = (aIndex a, aLevel a, aPackage a, decidedInstance a)

check :: String -> Bool -> Property
check what = counterexample ("mismatch: " ++ what)

-- | Every query, on both, for every probe package.
agree :: PartialSolution -> Model -> Property
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
            ("packageHistory " ++ show p)
            (map key (packageHistory ps p) == map key (mHistory m p))
        , check
            ("packageHistory terms " ++ show p)
            ( and
                [ termEquiv (assignmentTerm x) (assignmentTerm y)
                | (x, y) <- zip (packageHistory ps p) (mHistory m p)
                ]
            )
        , check
            ("termIntersectionForPackage " ++ show p)
            (maybeTermEquiv (termIntersectionForPackage ps p) (mTerm m p))
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

tests :: TestTree
tests =
    testGroup
        "PartialSolution (indexed vs flat-list model)"
        [ testProperty "every query agrees with the naive model, op by op" runScript
        , testProperty "…on scripts that backtrack heavily" $
            runScript . interleaveBacktracks
        ]
