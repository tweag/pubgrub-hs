-- | Holding a module of documentation to the code it shows: every code block
-- is a run of consecutive lines of a test module, and together the blocks
-- cover the module, so that the code a reader copies is code that compiles
-- and that the tests run.
--
-- The blocks need not come in the module's order, and a block may be a single
-- line: a recipe that adds one line to an instance an earlier recipe declared
-- shows that line alone, where the module has it inside the instance.
module DocCode (codeMatches) where

import           Data.List        (isPrefixOf, stripPrefix, tails)
import           Data.Maybe       (mapMaybe)
import qualified Data.Set         as Set
import           Test.Tasty.HUnit (Assertion, assertFailure)

-- | The code blocks of the documentation module against the test module.
codeMatches :: FilePath -> FilePath -> Assertion
codeMatches doc code = do
    blocks <- codeBlocks <$> readFile doc
    source <- nonBlank . lines <$> readFile code
    let placed = [(block, runOf block source) | block <- blocks]
    case [block | (block, Nothing) <- placed] of
        block : _ -> assertFailure ("not in " ++ code ++ ":\n" ++ unlines block)
        []        -> pure ()
    let covered = Set.fromList (concat [[i .. i + length block - 1] | (block, Just i) <- placed])
    case [l | (i, l) <- zip [0 ..] source, i `Set.notMember` covered] of
        l : _ -> assertFailure ("not shown by " ++ doc ++ ": " ++ l)
        []    -> pure ()

-- | The code blocks of a Haddock comment: each run of bird-track lines, as
-- the lines it holds, blank lines dropped.
codeBlocks :: String -> [[String]]
codeBlocks = go . lines
  where
    go ls = case dropWhile (not . isCode) ls of
        [] -> []
        rest ->
            let (block, after) = span isCode rest
             in nonBlank (mapMaybe (fmap (drop 1) . stripPrefix "-- >") block) : go after
    isCode = ("-- >" `isPrefixOf`)

nonBlank :: [String] -> [String]
nonBlank = filter (not . all (== ' '))

-- | Where a block appears as consecutive lines of the module, if it does.
runOf :: [String] -> [String] -> Maybe Int
runOf block source =
    case [i | (i, rest) <- zip [0 ..] (tails source), block `isPrefixOf` rest] of
        i : _ -> Just i
        []    -> Nothing
