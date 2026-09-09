-- | Tests for the index-state filter ('Bridge.Hackage.getRecordAt'): a package's
-- cache record decoded at a cutoff yields the releases that existed then, each
-- with the revision in force, and the latest surviving time.
--
-- The record goes through the real writer ('Bridge.Hackage.putRecord'), so the
-- hand-written decoder is held to the layout 'Data.Binary.put' produces.
module IndexStateSpec (tests) where

import           Bridge.Hackage                 (EpochTime, IndexState (..),
                                                 getRecordAt, parseIndexState,
                                                 putRecord, showIndexState,
                                                 toEpoch)
import           Data.Binary.Get                (runGetOrFail)
import           Data.Binary.Put                (runPut)
import           Data.Word                      (Word32)
import           Distribution.Types.PackageName (PackageName, mkPackageName)
import           Distribution.Types.Version     (Version, mkVersion)
import           Test.Tasty                     (TestTree, testGroup)
import           Test.Tasty.HUnit               (assertBool, assertFailure,
                                                 testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "index-state"
        [ testCase "at the head, the last revision is in force" $
            at Nothing @?= Right (Just 300, [(v 1, 13), (v 2, 21)])
        , testCase "between two revisions, the earlier one is in force" $
            at (Just 250) @?= Right (Just 200, [(v 1, 12), (v 2, 21)])
        , testCase "at exactly a revision's time, it is in force" $
            at (Just 200) @?= Right (Just 200, [(v 1, 12), (v 2, 21)])
        , testCase "a release uploaded after the cutoff does not exist" $
            at (Just 120) @?= Right (Just 100, [(v 1, 11)])
        , testCase "before every entry, the package is empty and there is no latest" $
            at (Just 50) @?= Right (Nothing, [])
        , testCase "the latest surviving time is the maximum over revisions in force" $
            -- v2's only entry (t=150) survives at cutoff 180; v1's in-force entry is
            -- at 100. So the state the run is really at is 150, not 100.
            at (Just 180) @?= Right (Just 150, [(v 1, 11), (v 2, 21)])
        , testCase "the revisions after the one in force are skipped, not misread" $
            -- Three revisions of v1 and then v2: if the skip were off by a byte,
            -- v2 would not decode, or would decode wrongly.
            at (Just 100) @?= Right (Just 100, [(v 1, 11)])
        , testCase "versions out of order fail to decode rather than build a bad set" $
            case decode Nothing (name, [(v 2, [(100, 1)]), (v 1, [(100, 2)])]) of
                Left _  -> pure ()
                Right r -> assertFailure ("decoded an unsorted record: " ++ show r)
        , testCase "parseIndexState reads cabal's timestamp syntax and prints it back" $
            case parseIndexState "2016-09-24T17:47:48Z" of
                Right (IndexAt t) -> showIndexState (toEpoch t) @?= "2016-09-24T17:47:48Z"
                other             -> assertFailure ("unexpected: " ++ show other)
        , testCase "parseIndexState rejects what is not a timestamp" $
            assertBool "accepted 'yesterday'" (either (const True) (const False) (parseIndexState "yesterday"))
        ]
  where
    name :: PackageName
    name = mkPackageName "pkg"

    v :: Int -> Version
    v n = mkVersion [n]

    -- v1 uploaded at 100 (block 11), revised at 200 (12) and 300 (13);
    -- v2 uploaded at 150 (block 21), never revised. Revisions are newest first,
    -- as the cache keeps them.
    record :: (PackageName, [(Version, [(EpochTime, Word32)])])
    record = (name, [(v 1, [(300, 13), (200, 12), (100, 11)]), (v 2, [(150, 21)])])

    at :: Maybe EpochTime -> Either String (Maybe EpochTime, [(Version, Word32)])
    at cutoff = decode cutoff record

    decode cutoff r =
        case runGetOrFail (getRecordAt cutoff) (runPut (putRecord r)) of
            Left (_, _, err)                -> Left err
            Right (_, _, (pn, t, vs, blks)) | pn == name -> Right (t, zip vs blks)
                                            | otherwise  -> Left "wrong package name"
