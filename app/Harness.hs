{-# LANGUAGE OverloadedStrings #-}

-- | The harness: the one command that produces both deliverables.
--
-- It drives the @pubgrub@ executable as a child process — once per solver, per
-- problem, per repetition — reads what the child prints, and writes two markdown
-- reports: @benchmark.md@ over @bench/problems.txt@ and @showcase.md@ over
-- @bench/unsat-problems.txt@. See @docs/harness-plan.md@ for why it is a separate
-- executable and why it measures a child rather than calling the solvers itself
-- (peak memory is a per-process number).
--
-- It measures; it does not decide. @scripts/gate.sh@ decides whether a change is
-- kept.
--
-- @cabal run pubgrub-harness@                              — both sets, three reps
-- @cabal run pubgrub-harness -- --set corpus --reps 1@
-- @cabal run pubgrub-harness -- 'lens <4'@                 — one problem
--
-- Two traps this file is built around. The proof carries a real NUL byte (the
-- synthetic root's name), so every child log is read as bytes and decoded
-- leniently, never as a locale 'String'. And the driver's exit code says nothing —
-- it is 0 for a plan and 0 for a proof of no plan — so the verdict is read from the
-- text, exactly as @scripts/gate.sh@ reads it.
module Main (main) where

import Control.Exception (IOException, try)
import Control.Monad (forM, forM_, unless, when)
import Data.ByteString qualified as BS
import Data.Char (isAlphaNum, isDigit)
import Data.List (dropWhileEnd, nub, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing, listToMaybe, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time (defaultTimeLocale, formatTime, getZonedTime)
import GHC.IO.Handle (hDuplicate)
import Numeric (showFFloat)
import Options.Applicative (Parser, auto, eitherReader, execParser, fullDesc, header,
                            help, helper, info, long, many, metavar, option, optional,
                            progDesc, showDefault, strArgument, strOption, value)
import System.Directory (createDirectoryIfMissing, doesFileExist, getModificationTime)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath ((</>))
import System.IO (IOMode (..), hPutStrLn, hSetEncoding, stderr, stdout, utf8,
                  withBinaryFile)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc,
                       readProcess, readProcessWithExitCode, waitForProcess)
import Text.Read (readMaybe)

-- --------------------------------------------------------------------------
-- Options

data SetChoice = SetBench | SetCorpus | SetBoth
    deriving (Eq, Show)

data Options = Options
    { optExe        :: Maybe FilePath
    , optReps       :: Int
    , optOutput     :: FilePath
    , optTimeout    :: Int
    , optIndexState :: Maybe String
    , optSet        :: SetChoice
    , optProblems   :: [String]
    }

optionsParser :: Parser Options
optionsParser =
    Options
        <$> optional (strOption (long "exe" <> metavar "PATH"
                <> help "The pubgrub driver (default: $PUBGRUB_EXE, else `cabal list-bin pubgrub`)"))
        <*> option auto (long "reps" <> metavar "N" <> value 3 <> showDefault
                <> help "Runs per problem and solver; times are medians over them")
        <*> strOption (long "output" <> metavar "DIR" <> value "bench/output" <> showDefault
                <> help "Where the per-run logs and the two reports go")
        <*> option auto (long "timeout" <> metavar "SECONDS" <> value 300 <> showDefault
                <> help "Per-run timeout")
        <*> optional (strOption (long "index-state" <> metavar "TIMESTAMP"
                <> help "Passed to every run as --index-state, so both reports are made against the index as it was then (default: the state pinned in bench/index-state; 'head' for everything the local index holds)"))
        <*> option (eitherReader parseSet) (long "set" <> metavar "bench|corpus|both"
                <> value SetBoth <> help "Which problem set(s) to run (default: both)")
        <*> many (strArgument (metavar "PROBLEM"
                <> help "A problem as one string: comma-separated targets, each '<package> [range]', e.g. 'hlint, hadolint ==2.15.1'. Given, the sets are not read"))
  where
    parseSet "bench"  = Right SetBench
    parseSet "corpus" = Right SetCorpus
    parseSet "both"   = Right SetBoth
    parseSet other    = Left ("expected bench, corpus or both, got " ++ other)

-- | Everything a run needs, resolved once.
data Config = Config
    { cfgExe        :: FilePath
    , cfgReps       :: Int
    , cfgOutput     :: FilePath
    , cfgTimeout    :: Int
    , cfgIndexState :: Maybe String
      -- ^ the @--index-state@ every run is given, if one was
    , cfgNewLines   :: Bool
      -- ^ whether the driver accepts @--stats@ and @--plan@. A driver from before
      -- those landed rejects them outright, so they are probed for once and omitted
      -- when absent; the report then says its counters, phases and plans are missing.
    }

-- --------------------------------------------------------------------------
-- Problems

data ProblemSet = Bench | Corpus
    deriving (Eq, Show)

data Problem = Problem
    { probArgs     :: [String]
      -- ^ one argument per target, exactly as the driver takes them: a target is a
      -- package with an optional version range, and the range holds spaces, so the
      -- line is split on commas and never on whitespace.
    , probNote     :: Text
      -- ^ the line's comment, after the @#@
    , probExcluded :: Bool
      -- ^ the comment carries @showcase:exclude@: run and measured, not shown
    , probSets     :: [ProblemSet]
    }

-- | The problem as its file line spells it, and as a reader must retype it:
-- targets separated by commas.
probText :: Problem -> Text
probText = T.intercalate ", " . map T.pack . probArgs

-- | The log basename: every non-alphanumeric character becomes @-@.
probBase :: Problem -> FilePath
probBase p = map (\c -> if isAlphaNum c then c else '-') (T.unpack (probText p))

-- | One problem-file line. Strip the comment, trim, drop blanks; what is left is
-- a comma-separated list of targets, each a package with an optional version
-- range. The comment is kept as the note.
--
-- Splitting on commas rather than whitespace is what makes @hlint, hadolint
-- ==2.15.1@ two targets and @hadolint ==2.15.1@ one.
parseProblemLine :: ProblemSet -> Text -> Maybe Problem
parseProblemLine set line
    | null args = Nothing
    | otherwise = Just Problem
        { probArgs     = args
        , probNote     = note
        , probExcluded = "showcase:exclude" `elem` T.words note
        , probSets     = [set]
        }
  where
    (body, rest) = T.breakOn "#" line
    note = T.strip (T.drop 1 rest)
    args = [ T.unpack t | t <- map T.strip (T.splitOn "," body), not (T.null t) ]

readProblems :: ProblemSet -> FilePath -> IO [Problem]
readProblems set path = mapMaybe (parseProblemLine set) . T.lines <$> readTextFile path

-- --------------------------------------------------------------------------
-- One run of the child

data Solver = Ours | Cabal
    deriving (Eq, Ord, Show)

solverTag :: Solver -> String
solverTag Ours  = "ours"
solverTag Cabal = "cabal"

data Verdict = Sat | Unsat | Timeout | Failed Int
    deriving (Eq, Show)

verdictText :: Verdict -> Text
verdictText Sat        = "sat"
verdictText Unsat      = "UNSAT"
verdictText Timeout    = "TIMEOUT"
verdictText (Failed n) = "exit " <> T.pack (show n)

-- | The provider's closing line, by name: @read N .cabal files, decoded D from the
-- derived index, served R repeat lookups from cache@.
data Reads = Reads
    { rdParses  :: Integer
    , rdDecoded :: Integer
    , rdReused  :: Integer
    }
    deriving (Eq, Show)

-- | A @plan:@ line. The qualifier is present only if the driver prints one
-- (@plan: setup mtl 2.2.2 source@); without it, cabal's two domains show through
-- as one name with two versions.
data PlanLine = PlanLine
    { plQualifier :: Maybe Text
    , plName      :: Text
    , plVersion   :: Text
    , plKind      :: Text
    }
    deriving (Eq, Show)

data Run = Run
    { runVerdict   :: Verdict
    , runWall      :: Maybe Double          -- ^ seconds, from @/usr/bin/time %e@
    , runRss       :: Maybe Integer         -- ^ KB, from @/usr/bin/time %M@
    , runAlloc     :: Maybe Integer         -- ^ bytes, from @+RTS -s@
    , runResidency :: Maybe Integer         -- ^ bytes, from @+RTS -s@
    , runStats     :: Maybe [(Text, Text)]  -- ^ the @stats:@ line, as key=value pairs
    , runPhases    :: Maybe [(Text, Double)]
    , runReads     :: Maybe Reads
    , runIndexState :: Maybe Text           -- ^ the child's @index-state:@ line: the state the run was really at
    , runPlan      :: Maybe [PlanLine]      -- ^ 'Nothing' when no @plan:@ line was printed
    , runHeadline  :: Maybe Text            -- ^ the line above our proof: the request and the walls
    , runProof     :: [Text]                -- ^ our proof as printed: sentences, their continuation lines, and the blank line between branches
    , runMessage   :: [Text]                -- ^ cabal's @Could not resolve dependencies:@ block
    }
    deriving (Show)

-- | Parse one run from the child's exit code and the three files it left.
parseRun :: Int -> Text -> Text -> Text -> Run
parseRun code logText timeText rtsText = Run
    { runVerdict   = verdict
    , runWall      = wall
    , runRss       = rss
    , runAlloc     = rtsNumber "bytes allocated"
    , runResidency = rtsNumber "bytes maximum residency"
    , runStats     = keyValues <$> firstWithPrefix "stats:"
    , runPhases    = firstWithPrefix "phases:" >>= traverse readPhase . keyValues
    , runReads     = firstJust (map parseReads ls)
    , runIndexState = T.strip <$> firstWithPrefix "index-state:"
    , runPlan      = case mapMaybe parsePlanLine ls of
                        [] -> Nothing
                        ps -> Just ps
    , runHeadline  = listToMaybe (filter ("No solution" `T.isPrefixOf`) ls)
    , runProof     = proofBlock ls
    , runMessage   = cabalBlock ls
    }
  where
    ls = T.lines logText

    -- The rule of scripts/gate.sh, in that order.
    verdict
        | code == 124        = Timeout
        | any unsatLine ls   = Unsat
        | code /= 0          = Failed code
        | otherwise          = Sat
    unsatLine l =
        "version solving failed" `T.isInfixOf` l
            || "Because" `T.isPrefixOf` l
            || "no plan" `T.isInfixOf` l

    -- GNU time prefixes "Command exited with non-zero status N" on failure, so
    -- the numbers are on the last non-blank line.
    (wall, rss) = case reverse (filter (not . T.null) (T.lines timeText)) of
        (l : _) | [e, m] <- T.words l -> (readT e, readT m)
        _                             -> (Nothing, Nothing)

    rtsNumber what =
        firstJust [ readT (T.filter (/= ',') w)
                  | l <- T.lines rtsText
                  , what `T.isInfixOf` l
                  , (w : _) <- [T.words l]
                  ]

    firstWithPrefix p = firstJust (map (T.stripPrefix p) ls)
    readPhase (k, v) = (,) k <$> readT v

readT :: Read a => Text -> Maybe a
readT = readMaybe . T.unpack

firstJust :: [Maybe a] -> Maybe a
firstJust ms = case [x | Just x <- ms] of
    (x : _) -> Just x
    []      -> Nothing

-- | @k=v@ pairs. A value may be empty (@depth=@ on a run with no conflicts).
keyValues :: Text -> [(Text, Text)]
keyValues = map split . T.words
  where
    split w = let (k, v) = T.breakOn "=" w in (k, T.drop 1 v)

-- | The provider's closing line, matched by name and not by field position, as
-- @bench/summarise.awk@ does: the line has gained a clause twice.
parseReads :: Text -> Maybe Reads
parseReads l
    | "read " `T.isPrefixOf` l && ".cabal files" `T.isInfixOf` l =
        Reads <$> after "read" <*> after "decoded" <*> after "served"
    | otherwise = Nothing
  where
    ws = T.words l
    after k = case dropWhile (/= k) ws of
        (_ : v : _) -> readT v
        _           -> Nothing

parsePlanLine :: Text -> Maybe PlanLine
parsePlanLine l = do
    rest <- T.stripPrefix "plan:" l
    case T.words rest of
        [n, v, k]    -> Just (PlanLine Nothing n v k)
        [q, n, v, k] -> Just (PlanLine (Just q) n v k)
        _            -> Nothing

-- | The proof as the driver printed it: from its first sentence to its last,
-- keeping the wrapped continuation lines (they start with the indent) and the
-- blank line the reporter puts between two branches of a derivation. Sentences
-- are counted by 'isProofLine', so neither kind of extra line is counted.
proofBlock :: [Text] -> [Text]
proofBlock ls = dropWhileEnd T.null (takeWhile inProof (dropWhile (not . isProofLine) ls))
  where
    inProof l = isProofLine l || T.null l || " " `T.isPrefixOf` l

-- | A proof sentence, by the connective it opens with and NOT by a leading number:
-- the reporter numbers only the conclusions it refers back to.
isProofLine :: Text -> Bool
isProofLine l = any (`T.isPrefixOf` body) ["Because", "And because", "So, because", "Thus,"]
  where
    (digits, rest) = T.span isDigit l
    body | not (T.null digits), Just r <- T.stripPrefix ". " rest = r
         | otherwise = l

-- | cabal's explanation: from @Could not resolve dependencies:@ to the end, minus
-- that line, non-blank lines only — the count @scripts/gate.sh@ makes. The gate
-- never asks for @--stats@ or @--plan@, so the @stats:@, @phases:@ and @plan:@
-- lines the harness asks for are dropped here to keep the two counts equal.
cabalBlock :: [Text] -> [Text]
cabalBlock ls = case dropWhile (not . T.isInfixOf "Could not resolve dependencies:") ls of
    []         -> []
    (_ : rest) -> filter keep rest
  where
    keep l = not (T.null l) && not (any (`T.isPrefixOf` l) ["stats:", "phases:", "plan:", "index-state:"])

-- --------------------------------------------------------------------------
-- Running

-- | Spawn @cmd args@ with stdout and stderr into one file; the exit code.
captureTo :: FilePath -> FilePath -> [String] -> IO Int
captureTo path cmd args =
    withBinaryFile path WriteMode $ \h -> do
        h' <- hDuplicate h
        (_, _, _, ph) <- createProcess (proc cmd args) { std_out = UseHandle h, std_err = UseHandle h' }
        code <- waitForProcess ph
        pure (case code of
            ExitSuccess   -> 0
            ExitFailure n -> n)

-- | Read a file as bytes and decode leniently: a proof carries a NUL byte, and
-- the locale is nobody's business. Missing file: empty.
readTextFile :: FilePath -> IO Text
readTextFile path = do
    ok <- doesFileExist path
    if ok then TE.decodeUtf8With lenientDecode <$> BS.readFile path else pure ""

runChild :: Config -> Problem -> Solver -> Int -> IO Run
runChild cfg prob solver rep = do
    let stem = cfgOutput cfg </> "runs" </> (probBase prob ++ "." ++ solverTag solver ++ "." ++ show rep)
        logPath  = stem ++ ".log"
        timePath = stem ++ ".time"
        rtsPath  = stem ++ ".rts"
        args =
            ["-f", "%e %M", "-o", timePath, "timeout", show (cfgTimeout cfg), cfgExe cfg]
                ++ ["--cabal" | solver == Cabal]
                ++ (if cfgNewLines cfg then ["--stats", "--plan", "lines"] else [])
                ++ maybe [] (\st -> ["--index-state", st]) (cfgIndexState cfg)
                ++ probArgs prob
                ++ ["+RTS", "-s" ++ rtsPath, "-RTS"]
    code <- captureTo logPath "/usr/bin/time" args
    parseRun code <$> readTextFile logPath <*> readTextFile timePath <*> readTextFile rtsPath

-- --------------------------------------------------------------------------
-- Summarising the repetitions of one (problem, solver)

data Measured = Measured
    { mVerdict   :: Verdict
    , mWall      :: Maybe Double            -- ^ median seconds
    , mRss       :: Maybe Double            -- ^ median KB
    , mAlloc     :: Maybe Double            -- ^ median bytes
    , mResidency :: Maybe Double            -- ^ median bytes
    , mPhases    :: Maybe [(Text, Double)]  -- ^ median per phase
    , mStats     :: Maybe [(Text, Text)]
    , mReads     :: Maybe Reads
    , mIndexState :: Maybe Text            -- ^ the state the runs were really at, as the driver said
    , mPlan      :: Maybe [PlanLine]
    , mHeadline  :: Maybe Text
    , mProof     :: [Text]
    , mMessage   :: [Text]
    , mMissing   :: [Text]                  -- ^ contract lines the driver did not print
    , mVaried    :: [Text]                  -- ^ deterministic values that varied across reps
    }

-- | The middle of the sorted list, or the mean of the two middles. Written by
-- pattern matching on the upper half so that no index can be out of range.
median :: [Double] -> Maybe Double
median xs = case splitAt (n `div` 2) sorted of
    (_, [])                       -> Nothing
    (lower, upper : _) | even n   -> Just ((lastOr upper lower + upper) / 2)
                       | otherwise -> Just upper
  where
    sorted = sort xs
    n = length xs
    lastOr d = foldl (\_ x -> x) d

-- | The first run and the rest: reps is at least 1, and the type says so.
summarise :: Solver -> Run -> [Run] -> Measured
summarise solver r0 rest = Measured
    { mVerdict   = runVerdict r0
    , mWall      = medianOf runWall
    , mRss       = medianOf (fmap fromIntegral . runRss)
    , mAlloc     = medianOf (fmap fromIntegral . runAlloc)
    , mResidency = medianOf (fmap fromIntegral . runResidency)
    , mPhases    = phaseMedians <$> runPhases r0
    , mStats     = runStats r0
    , mReads     = runReads r0
    , mIndexState = runIndexState r0
    , mPlan      = runPlan r0
    , mHeadline  = runHeadline r0
    , mProof     = runProof r0
    , mMessage   = runMessage r0
    , mMissing   = missing
    , mVaried    = varied
    }
  where
    runs = r0 : rest
    medianOf f = median (mapMaybe f runs)
    phaseMedians ps =
        [ (k, v)
        | (k, _) <- ps
        , Just v <- [median (mapMaybe (lookup k . fromMaybe [] . runPhases) runs)]
        ]
    missing =
        ["stats:" | isNothing (runStats r0)]
            ++ ["phases:" | isNothing (runPhases r0)]
            ++ ["plan:" | runVerdict r0 == Sat, isNothing (runPlan r0)]
            ++ ["read N .cabal files" | solver == Ours, isNothing (runReads r0)]
    varied =
        same "verdict" runVerdict
            ++ same "stats" runStats
            ++ same "read counters" runReads
            ++ same "plan" runPlan
            ++ same "headline" runHeadline
            ++ same "proof" runProof
            ++ same "cabal's message" runMessage
    same :: Eq a => Text -> (Run -> a) -> [Text]
    same name f
        | all ((== f r0) . f) rest = []
        | otherwise = [name <> " varied across repetitions"]

measure :: Config -> Problem -> Solver -> IO Measured
measure cfg prob solver = do
    r0 <- one 1
    rest <- forM [2 .. cfgReps cfg] one
    pure (summarise solver r0 rest)
  where
    one rep = do
        r <- runChild cfg prob solver rep
        hPutStrLn stderr $
            T.unpack (T.justifyLeft 34 ' ' (probText prob))
                ++ " " ++ T.unpack (T.justifyLeft 5 ' ' (T.pack (solverTag solver)))
                ++ " " ++ show rep ++ "/" ++ show (cfgReps cfg)
                ++ "  " ++ T.unpack (verdictText (runVerdict r))
                ++ maybe "" (\w -> "  " ++ showFFloat (Just 2) w " s") (runWall r)
        pure r

-- --------------------------------------------------------------------------
-- The environment header

data Env = Env
    { envDate      :: Text
    , envIndex     :: Text
    , envGhc       :: Text
    , envPkgConfig :: [(Text, Maybe Bool)]
    }

pkgConfigNames :: [String]
pkgConfigNames =
    [ "libpq", "libzmq", "blas", "lapack", "cairo", "pango", "gtk+-2.0", "gtk+-3.0"
    , "gtk4", "gio-2.0", "zlib", "libsodium", "libgit2" ]

tryIO :: IO a -> IO (Either IOException a)
tryIO = try

collectEnv :: IO Env
collectEnv = do
    now <- getZonedTime
    let indexPath = "_cache/01-index.tar"
    haveIndex <- doesFileExist indexPath
    index <-
        if haveIndex
            then T.pack . formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC" <$> getModificationTime indexPath
            else pure "unknown (no _cache/01-index.tar)"
    ghc <- either (const "unknown") (T.strip . T.pack) <$> tryIO (readProcess "ghc" ["--numeric-version"] "")
    pkgs <- forM pkgConfigNames $ \name -> do
        r <- tryIO (readProcessWithExitCode "pkg-config" ["--exists", name] "")
        pure (T.pack name, either (const Nothing) (\(c, _, _) -> Just (c == ExitSuccess)) r)
    pure Env
        { envDate      = T.pack (formatTime defaultTimeLocale "%Y-%m-%d %H:%M %Z" now)
        , envIndex     = index
        , envGhc       = ghc
        , envPkgConfig = pkgs
        }

type Result = (Problem, Measured, Measured)   -- ^ problem, ours, cabal's

headerLines :: Config -> Env -> [Result] -> [Text]
headerLines cfg env results =
    [ "## Environment"
    , ""
    , "- generated: " <> envDate env
    , "- index-state: " <> indexStateLine
    , "- Hackage index snapshot: " <> envIndex env <> " (mtime of `_cache/01-index.tar`)"
    , "- GHC: " <> envGhc env
    , "- pkg-config present: " <> names True <> "; absent: " <> names False
    , "- repetitions per problem and solver: " <> tshow (cfgReps cfg)
    , "- driver: `" <> T.pack (cfgExe cfg) <> "`"
    , ""
    , "## Restrictions"
    , ""
    , "Both solvers run under the same three restrictions, and a number quoted without"
    , "them is misleading however honest it is."
    , ""
    , "- **Both solvers run with every flag pinned to its declared default.** That is a"
    , "  restriction of the problem, not a property of either solver. It makes the"
    , "  comparison fair, because neither side can flip a flag to escape. It also makes"
    , "  some real failures unreachable."
    , "- **One version per package name.** Our decisions are per package name. One solve"
    , "  yields one version of `mtl`. cabal solves qualified goals, so each executable"
    , "  and each setup dependency gets its own domain, and a cabal plan can name one"
    , "  package twice."
    , "- **cabal solves setup and build-tool dependencies and we do not.** On a package"
    , "  with a custom `Setup.hs` the two solvers answer different questions."
    , ""
    , "## How to read the numbers"
    , ""
    , "- Elapsed times are medians of " <> tshow (cfgReps cfg) <> " single run(s) on a desktop where"
    , "  run-to-run noise is ±25%. Total allocation is the stable stand-in for time."
    , "- Residency is `maximum residency` from `+RTS -s`. RSS is `%M` from `/usr/bin/time`."
    , "- Phases are the child's own clock: `world` opens the index, the installed database"
    , "  and the pkg-config database; `index` is cabal's `sourcePackageIndex` build (zero"
    , "  for ours); `solve` is the search; `render` is printing the answer."
    , "- Counts are deterministic. The harness asserts they did not vary across repetitions."
    ]
    ++ warningLines cfg results
  where
    names want = case [n | (n, Just p) <- envPkgConfig env, p == want] of
        [] -> "none"
        ns -> T.intercalate ", " ns
    tshow :: Show a => a -> Text
    tshow = T.pack . show
    -- What every run said it was at. One value is the reproducible case; more
    -- than one means the index moved under the harness, which a pinned
    -- `--index-state` prevents.
    indexStateLine = case nub [st | (_, ours, cabal) <- results, m <- [ours, cabal], Just st <- [mIndexState m]] of
        []   -> "unknown (the driver printed no `index-state:` line)" <> requested
        [st] -> "`" <> st <> "`" <> requested
        sts  -> "**varied across runs**: " <> T.intercalate "; " (map (\st -> "`" <> st <> "`") sts) <> requested
    requested = case cfgIndexState cfg of
        Nothing -> " (not pinned: everything the local index held; pass `--index-state` to reproduce)"
        Just r  -> " (pinned with `--index-state " <> T.pack r <> "`)"

warningLines :: Config -> [Result] -> [Text]
warningLines cfg results
    | null warnings = []
    | otherwise = ["", "## Warnings", ""] ++ map ("- " <>) warnings
  where
    warnings = driver ++ parses ++ missing ++ varied
    driver =
        [ "the driver does not accept `--stats` or `--plan` (a build from before those"
          <> " landed): search counters, phases and plans are absent below"
        | not (cfgNewLines cfg) ]
    parses =
        [ "the derived index is behind the Hackage index: "
          <> T.intercalate ", " stale
          <> " parsed `.cabal` files. Re-run `cabal run pubgrub-index` before quoting anything"
        | not (null stale) ]
    stale = [ probText p | (p, ours, _) <- results, Just r <- [mReads ours], rdParses r > 0 ]
    -- One line per (solver, set of absent lines), not one per problem: an old
    -- driver misses the same lines on every problem.
    missing =
        [ T.pack (solverTag s) <> " did not print " <> T.intercalate ", " (map tick ms)
            <> " on " <> onWhich ps
        | ((s, ms), ps) <- Map.toList (Map.fromListWith (flip (++))
            [ ((s, mMissing m), [probText p])
            | (p, ours, cabal) <- results
            , (s, m) <- [(Ours, ours), (Cabal, cabal)]
            , not (null (mMissing m)) ]) ]
    onWhich ps
        | length ps == length results = "every problem"
        | otherwise = T.pack (show (length ps)) <> " problem(s): " <> T.intercalate ", " (map tick ps)
    varied =
        [ "**not reproducible:** `" <> probText p <> "` (" <> T.pack (solverTag s) <> "): " <> T.intercalate "; " vs
        | (p, ours, cabal) <- results
        , (s, m) <- [(Ours, ours), (Cabal, cabal)]
        , let vs = mVaried m
        , not (null vs) ]

-- --------------------------------------------------------------------------
-- Rendering helpers

dash :: Text
dash = "—"

fixed :: Int -> Maybe Double -> Text
fixed n = maybe dash (\x -> T.pack (showFFloat (Just n) x ""))

seconds, megabytes, gigabytes :: Maybe Double -> Text
seconds = fixed 2
megabytes = fixed 1 . fmap (/ 1e6)
gigabytes = fixed 2 . fmap (/ 1e9)

count :: Maybe Integer -> Text
count = maybe dash (T.pack . show)

tick :: Text -> Text
tick t = "`" <> t <> "`"

table :: [Text] -> [[Text]] -> [Text]
table hdr rows = row hdr : row (map (const "---") hdr) : map row rows
  where
    row cells = "| " <> T.intercalate " | " cells <> " |"

fenced :: [Text] -> [Text]
fenced body = ["```text"] ++ body ++ ["```"]

-- | The proof as a reader sees it: the synthetic root's NUL byte is dropped, so
-- @\0root ==0@ renders as @root ==0@. Counts are made on the raw lines.
readable :: Text -> Text
readable = T.filter (/= '\0')

statInt :: Text -> Measured -> Maybe Integer
statInt k m = mStats m >>= lookup k >>= readT

phase :: Text -> Measured -> Maybe Double
phase k m = mPhases m >>= lookup k

bothVerdict :: Measured -> Measured -> Text
bothVerdict ours cabal
    | mVerdict ours == mVerdict cabal = "both " <> verdictText (mVerdict ours)
    | otherwise = "ours " <> verdictText (mVerdict ours) <> ", cabal " <> verdictText (mVerdict cabal)

-- --------------------------------------------------------------------------
-- Report 1: the benchmark

benchmarkReport :: Config -> Env -> [Result] -> [Text]
benchmarkReport cfg env results =
    [ "# Benchmark report"
    , ""
    , "Generated by `pubgrub-harness` on " <> envDate env <> ", over `bench/problems.txt`."
    , "" ]
    ++ headerLines cfg env results
    ++ [ ""
       , "## Results"
       , ""
       , "Medians over " <> T.pack (show (cfgReps cfg)) <> " run(s). Times in seconds, residency in MB, allocation in GB."
       , "" ]
    ++ table
        [ "problem", "verdict", "ours", "cabal", "our world/solve", "cabal world/index/solve"
        , "our residency", "cabal residency", "our allocation", "cabal allocation"
        , "our proof", "cabal's message" ]
        [ [ tick (probText p)
          , bothVerdict ours cabal
          , seconds (mWall ours)
          , seconds (mWall cabal)
          , seconds (phase "world" ours) <> " / " <> seconds (phase "solve" ours)
          , seconds (phase "world" cabal) <> " / " <> seconds (phase "index" cabal) <> " / " <> seconds (phase "solve" cabal)
          , megabytes (mResidency ours)
          , megabytes (mResidency cabal)
          , gigabytes (mAlloc ours)
          , gigabytes (mAlloc cabal)
          , if mVerdict ours == Unsat then count (Just (fromIntegral (length (filter isProofLine (mProof ours))))) else dash
          , if mVerdict cabal == Unsat then count (Just (fromIntegral (length (mMessage cabal)))) else dash
          ]
        | (p, ours, cabal) <- results ]
    ++ [ ""
       , "## Search counts"
       , ""
       , "Our solver's counts on the same runs. `parses` must be zero: a non-zero count"
       , "means the derived index is behind the Hackage index."
       , "" ]
    ++ table
        [ "problem", "decisions", "conflicts", "no-version", "decoded", "parses" ]
        [ [ tick (probText p)
          , count (statInt "deciding" ours)
          , count (statInt "conflicts" ours)
          , count (statInt "noversion" ours)
          , count (rdDecoded <$> mReads ours)
          , count (rdParses <$> mReads ours)
          ]
        | (p, ours, _) <- results ]
    ++ [ ""
       , "## Plan diffs"
       , ""
       , "Library domain only, which is the only one we solve. A package cabal plans at"
       , "more than one version is its qualified goals showing through, not a disagreement."
       ]
    ++ concat
        [ ["", "### " <> tick (probText p), ""] ++ planDiff ours cabal
        | (p, ours, cabal) <- results
        , mVerdict ours == Sat || mVerdict cabal == Sat ]

planDiff :: Measured -> Measured -> [Text]
planDiff ours cabal
    | mVerdict ours /= Sat || mVerdict cabal /= Sat =
        ["- skipped: " <> bothVerdict ours cabal]
    | otherwise = case (mPlan ours, mPlan cabal) of
        (Nothing, _) -> ["- unavailable: the driver printed no `plan:` lines for ours"]
        (_, Nothing) -> ["- unavailable: the driver printed no `plan:` lines for cabal"]
        (Just ps, Just cs) ->
            let ourMap = versionsOf (filter (not . isRoot) ps)
                libLines = [c | c <- cs, not (isRoot c), maybe True (== "lib") (plQualifier c)]
                otherLines = [c | c <- cs, not (isRoot c), maybe False (/= "lib") (plQualifier c)]
                cabalMap = versionsOf libLines
                onlyOurs = Map.keys (ourMap `Map.difference` cabalMap)
                onlyCabal = Map.keys (cabalMap `Map.difference` ourMap)
                shared = Map.toList (Map.intersectionWith (,) ourMap cabalMap)
                disagree = [ (n, o, c) | (n, (o, c)) <- shared, Set.null (o `Set.intersection` c) ]
                multi = [ (n, c) | (n, c) <- Map.toList cabalMap, Set.size c > 1 ]
                doubled = [ (n, o) | (n, o) <- Map.toList ourMap, Set.size o > 1 ]
                agree = length shared - length disagree
                findings =
                    [ "- only in ours: " <> listNames onlyOurs | not (null onlyOurs) ]
                    ++ [ "- only in cabal's: " <> listNames onlyCabal | not (null onlyCabal) ]
                    ++ [ "- disagree: " <> tick n <> " ours " <> versions o <> ", cabal " <> versions c
                       | (n, o, c) <- disagree ]
                    ++ [ "- cabal plans " <> T.pack (show (Set.size c)) <> " versions (qualified goals): "
                            <> tick n <> " " <> versions c
                       | (n, c) <- multi ]
                    ++ [ "- ours lists more than one version of " <> tick n <> " " <> versions o <> ", which should not happen"
                       | (n, o) <- doubled ]
                    ++ [ "- cabal's other domains: "
                            <> T.intercalate ", " [ fromMaybe "" (plQualifier c) <> " " <> plName c <> " " <> plVersion c | c <- otherLines ]
                       | not (null otherLines) ]
            in ("- agree on " <> T.pack (show agree) <> " packages") : findings
  where
    isRoot l = T.any (== '\0') (plName l)
    versionsOf :: [PlanLine] -> Map Text (Set Text)
    versionsOf = Map.fromListWith Set.union . map (\l -> (plName l, Set.singleton (plVersion l)))
    listNames = T.intercalate ", " . map tick
    versions = T.intercalate "/" . Set.toList

-- --------------------------------------------------------------------------
-- Report 2: the showcase

showcaseReport :: Config -> Env -> [Result] -> [Text]
showcaseReport cfg env results =
    [ "# Explanation showcase"
    , ""
    , "Generated by `pubgrub-harness` on " <> envDate env <> ", over `bench/unsat-problems.txt`."
    , "For every problem, what each solver said. `ours` counts proof sentences; `cabal`"
    , "counts the non-blank lines of its `Could not resolve dependencies:` block, its"
    , "actual explanation and not the whole log. A proof is shown as the driver"
    , "prints it, wrapped at 80 columns with a hanging indent; a continuation line is"
    , "not a sentence and is not counted. A sentence can run to 400 characters and"
    , "cabal's lines are unwrapped, so each count is also given as screen lines: the"
    , "non-blank lines of our proof as printed, and cabal's lines at 80 columns, each"
    , "counted as the number of 80-column rows it fills. The line above each of our proofs"
    , "names the request and the facts about this machine the proof rests on; it is"
    , "not a sentence of the proof and is not counted, as cabal's `Could not resolve"
    , "dependencies:` line is not. The synthetic root's NUL byte is dropped from the"
    , "rendered proofs; the counts are made on the raw output."
    , "" ]
    ++ headerLines cfg env results
    ++ [ ""
       , "## Excluded from the showcase"
       , ""
       , "These stay in the corpus and the gate, and are run and measured here, but are"
       , "not rendered: each is unsatisfiable for more than one reason; the two solvers"
       , "explain different facts, so lengths do not compare."
       , "" ]
    ++ (if null excluded then ["- none"] else [ "- " <> tick (probText p) | (p, _, _) <- excluded ])
    ++ [ ""
       , "## Summary"
       , ""
       , "**Shorter on " <> tshow shorter <> " of " <> tshow (length comparable)
            <> " comparable problems: " <> tshow ourTotal <> " proof sentences against cabal's "
            <> tshow cabalTotal <> " lines.** On screen lines at 80 columns, "
            <> tshow ourScreenTotal <> " against " <> tshow cabalScreenTotal
            <> ", shorter on " <> tshow shorterOnScreen <> " of " <> tshow (length comparable) <> "."
       , "" ]
    ++ table
        [ "target", "note", "our sentences", "our screen lines", "cabal lines", "cabal screen lines" ]
        [ [ tick (probText p), probNote p, sentences ours, screen ours, lines' cabal, screenAt80 cabal ]
        | (p, ours, cabal) <- comparable ]
    ++ [ "", "## The problems" ]
    ++ concat
        [ [ ""
          , "### " <> tick (probText p)
          , "" ]
          ++ [ "_" <> probNote p <> "_" | not (T.null (probNote p)) ]
          ++ [ ""
          , "**pubgrub-hs** (" <> sentences ours <> " sentences, " <> verdictText (mVerdict ours) <> ")"
          , "" ]
          ++ fenced (if null (mProof ours) then ["(no proof)"] else withHeadline ours (map readable (mProof ours)))
          ++ [ ""
             , "**cabal** (" <> lines' cabal <> " lines, " <> verdictText (mVerdict cabal) <> ")"
             , "" ]
          ++ fenced (if null (mMessage cabal) then ["(no message)"] else mMessage cabal)
          ++ [ ""
             , sentences ours <> " sentences against " <> lines' cabal <> " lines; "
                <> screen ours <> " screen lines against " <> screenAt80 cabal <> "." ]
        | (p, ours, cabal) <- comparable ]
  where
    withHeadline m body = maybe body (\h -> readable h : "" : body) (mHeadline m)
    excluded = [ r | r@(p, _, _) <- results, probExcluded p ]
    comparable = [ r | r@(p, _, _) <- results, not (probExcluded p) ]
    ourCount (_, ours, _) = length (filter isProofLine (mProof ours))
    cabalCount (_, _, cabal) = length (mMessage cabal)
    bothUnsat (_, ours, cabal) = mVerdict ours == Unsat && mVerdict cabal == Unsat
    shorter = length [ r | r <- comparable, bothUnsat r, ourCount r < cabalCount r ]
    ourTotal = sum (map ourCount comparable)
    -- Screen lines: ours as printed (wrapped at 80 off a terminal, blank lines
    -- dropped); cabal's at 80 columns, an unwrapped line counting for every row it
    -- fills.
    ourScreen (_, ours, _) = length (filter (not . T.null) (mProof ours))
    cabalScreen (_, _, cabal) = sum [ max 1 ((T.length l + 79) `div` 80) | l <- mMessage cabal ]
    screen m = tshow (length (filter (not . T.null) (mProof m)))
    screenAt80 m = tshow (sum [ max 1 ((T.length l + 79) `div` 80) | l <- mMessage m ])
    shorterOnScreen = length [ r | r <- comparable, bothUnsat r, ourScreen r < cabalScreen r ]
    ourScreenTotal = sum (map ourScreen comparable)
    cabalScreenTotal = sum (map cabalScreen comparable)
    cabalTotal = sum (map cabalCount comparable)
    sentences m = tshow (length (filter isProofLine (mProof m)))
    lines' m = tshow (length (mMessage m))
    tshow :: Show a => a -> Text
    tshow = T.pack . show

-- --------------------------------------------------------------------------
-- Main

main :: IO ()
main = do
    hSetEncoding stdout utf8
    hSetEncoding stderr utf8
    opts <- execParser (info (helper <*> optionsParser) infoMod)
    when (optReps opts < 1) $ do
        hPutStrLn stderr "--reps must be at least 1"
        exitFailure

    exe <- resolveExe (optExe opts)
    indexState <- resolveIndexState (optIndexState opts)
    newLines <- probeDriver exe
    unless newLines $
        hPutStrLn stderr ("note: " ++ exe ++ " does not accept --stats/--plan; counters, phases and plans will be absent")
    let cfg = Config
            { cfgExe        = exe
            , cfgReps       = optReps opts
            , cfgOutput     = optOutput opts
            , cfgTimeout    = optTimeout opts
            , cfgIndexState = indexState
            , cfgNewLines   = newLines
            }

    problems <- selectProblems opts
    when (null problems) $ do
        hPutStrLn stderr "no problems to run"
        exitFailure
    createDirectoryIfMissing True (cfgOutput cfg </> "runs")

    -- The throwaway: the first run of the day may refresh the index and rebuild the
    -- version cache, and that is not what any number here is about.
    hPutStrLn stderr "warm-up: vector (not recorded)"
    _ <- captureTo (cfgOutput cfg </> "runs" </> "warm-up.log") exe ["vector"]

    results <- forM problems $ \p -> do
        ours <- measure cfg p Ours
        cabal <- measure cfg p Cabal
        pure (p, ours, cabal)

    env <- collectEnv
    let inSet s = [ r | r@(p, _, _) <- results, s `elem` probSets p ]
        bench = inSet Bench
        corpus = inSet Corpus
        write name ls = do
            let path = cfgOutput cfg </> name
            BS.writeFile path (TE.encodeUtf8 (T.unlines ls))
            hPutStrLn stderr ("wrote " ++ path)
    unless (null bench) $ write "benchmark.md" (benchmarkReport cfg env bench)
    unless (null corpus) $ write "showcase.md" (showcaseReport cfg env corpus)

    let varied = [ (p, s, v) | (p, ours, cabal) <- results, (s, m) <- [(Ours, ours), (Cabal, cabal)], v <- mVaried m ]
    forM_ varied $ \(p, s, v) ->
        hPutStrLn stderr ("NOT REPRODUCIBLE: " ++ T.unpack (probText p) ++ " (" ++ solverTag s ++ "): " ++ T.unpack v)
    unless (null varied) exitFailure
  where
    infoMod = fullDesc
        <> progDesc "Run both solvers over the problem sets and write the benchmark report and the explanation showcase"
        <> header "pubgrub-harness - the measuring half of the deliverables"

-- | @--index-state@, else the state pinned in @bench/index-state@, else none.
-- @head@ means none: everything the local index holds, refreshed weekly.
-- The pin is what makes two harness runs comparable across a refresh, and the
-- gate reads the same file.
resolveIndexState :: Maybe String -> IO (Maybe String)
resolveIndexState (Just "head") = pure Nothing
resolveIndexState (Just st)     = pure (Just st)
resolveIndexState Nothing = do
    pinned <- T.lines <$> readTextFile "bench/index-state"
    pure $ case [ v | l <- pinned, let v = T.unpack (T.strip (fst (T.breakOn "#" l))), not (null v) ] of
        (v : _) -> Just v
        []      -> Nothing

-- | @--exe@, else @$PUBGRUB_EXE@, else what cabal built.
resolveExe :: Maybe FilePath -> IO FilePath
resolveExe (Just path) = pure path
resolveExe Nothing = do
    fromEnv <- lookupEnv "PUBGRUB_EXE"
    case fromEnv of
        Just path | not (null path) -> pure path
        _ -> do
            r <- tryIO (readProcess "cabal" ["list-bin", "pubgrub"] "")
            case r of
                Right out | not (null (trim out)) -> pure (trim out)
                _ -> do
                    hPutStrLn stderr "cannot locate the pubgrub executable; pass --exe or set PUBGRUB_EXE"
                    exitFailure
  where
    trim = T.unpack . T.strip . T.pack

-- | Does the driver know @--stats@ and @--plan@? Its @--help@ says.
probeDriver :: FilePath -> IO Bool
probeDriver exe = do
    r <- tryIO (readProcessWithExitCode exe ["--help"] "")
    pure $ case r of
        Right (_, out, err) -> "--stats" `T.isInfixOf` T.pack (out ++ err) && "--plan" `T.isInfixOf` T.pack (out ++ err)
        Left _ -> False

-- | Positional problems, if any, belong to both reports; otherwise the chosen sets.
selectProblems :: Options -> IO [Problem]
selectProblems opts
    | not (null (optProblems opts)) =
        pure [ p { probSets = [Bench, Corpus] }
             | s <- optProblems opts
             , Just p <- [parseProblemLine Bench (T.pack s)] ]
    | otherwise = do
        bench <- if optSet opts /= SetCorpus then readProblems Bench "bench/problems.txt" else pure []
        corpus <- if optSet opts /= SetBench then readProblems Corpus "bench/unsat-problems.txt" else pure []
        pure (bench ++ corpus)
