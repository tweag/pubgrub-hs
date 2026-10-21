-- | Holding a module of documentation to the code it shows: its code blocks,
-- put together, are a test module line for line, so that the code a reader
-- copies is code that compiles and that the tests run.
module DocCode (codeMatches) where

import           Data.List        (stripPrefix)
import           Data.Maybe       (mapMaybe)
import           Test.Tasty.HUnit (Assertion, (@?=))

-- | The code blocks of the documentation module against the test module, as
-- the first line where they part.
codeMatches :: FilePath -> FilePath -> Assertion
codeMatches doc code = do
    blocks <- birdTracks <$> readFile doc
    source <- nonBlank . lines <$> readFile code
    firstDifference blocks source @?= Nothing

-- | The code blocks of a Haddock comment, as the lines of the file they
-- assemble into, blank lines dropped.
birdTracks :: String -> [String]
birdTracks = nonBlank . mapMaybe (fmap (drop 1) . stripPrefix "-- >") . lines

nonBlank :: [String] -> [String]
nonBlank = filter (not . all (== ' '))

-- | The first line where two files part, the documentation's first; an empty
-- line stands for the end of a file that stopped early.
firstDifference :: [String] -> [String] -> Maybe (String, String)
firstDifference (x : xs) (y : ys)
    | x == y = firstDifference xs ys
    | otherwise = Just (x, y)
firstDifference [] [] = Nothing
firstDifference xs ys = Just (concat (take 1 xs), concat (take 1 ys))
