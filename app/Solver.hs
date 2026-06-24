{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Solver (
    runSolve,
    renderSolverMsg,
)
where

import           Colog                (LogAction (..), WithLog, logMsg,
                                       usingLoggerT)
import           Data.Foldable        (for_)
import qualified Data.Map.Strict      as Map
import           Data.Text            (Text)
import qualified Data.Text            as T
import           Distribution.Pretty  (prettyShow)
import           Distribution.Version (mkVersion)
import           HackageProvider      (HackageProvider (..), ResolveError (..))
import           Pkg                  (Pkg (..))
import           PubGrub.Report       (ReportEnv (..), reportConflictWith)
import           PubGrub.Solver       (SolveError (..), SolverMsg (..), solve)
import           PubGrub.Term         (Term (..))
import           PubGrub.Types        (incompTerms)
import qualified PubGrub.VersionSet   as VS
import           UnliftIO             (MonadUnliftIO, try)

renderSolverMsg :: SolverMsg Pkg VS.VersionSet -> Text
renderSolverMsg msg = case msg of
    Deciding (Pkg n) r -> "\ESC[2mdeciding " <> name n <> " " <> showRange r <> "\ESC[0m"
    Chose (Pkg n) v -> "  \ESC[32m\x2713\ESC[0m " <> name n <> "-" <> showVer v
    NoVersionFor (Pkg n) r -> "  \ESC[31m\x2717\ESC[0m no version for " <> name n <> " in " <> showRange r
    Conflict i -> "  \ESC[33m\x26A0\ESC[0m conflict: " <> renderIncompat i
    Backtracked n -> "  \ESC[2m\x21A9 backtracking to level " <> T.pack (show n) <> "\ESC[0m"
    _ -> "" -- Root payloads: no output
  where
    name = T.pack . prettyShow
    showVer = T.pack . prettyShow
    showRange = T.pack . prettyShow . VS.toVersionRange
    renderIncompat i = T.intercalate ", " [renderTerm p t | (p, t) <- Map.toList (incompTerms i)]
    renderTerm Root _               = "root"
    renderTerm (Pkg n) (Positive r) = name n <> " " <> showRange r
    renderTerm (Pkg n) (Negative r) = name n <> " not " <> showRange r

-- | Resolve the dependency closure of @target@ within @range@, printing a
-- startup banner and phase notes to stderr and the plan to stdout. Runs in 'App'.
runSolve
    :: forall m env
     . (MonadUnliftIO m, WithLog env Text m)
    => HackageProvider -> m ()
runSolve hp = do
    outcome <- do
        try (usingLoggerT (LogAction $ logMsg . renderSolverMsg) (solve hp Root (mkVersion [0])))
    case outcome of
        Left (ResolveError n v) ->
            logMsg ("Failed to parse " <> T.pack (prettyShow n) <> "-" <> T.pack (prettyShow v))
        Right (Left (NoSolution i)) -> do
            let env =
                    ReportEnv
                        { rePinned = \case
                            Pkg n -> Map.lookup n (hpBoot hp)
                            Root -> Nothing
                        , reIsRoot = \case
                            Root -> True
                            _ -> False
                        }
            logMsg $ T.unlines ["No solution:", reportConflictWith env i]
        Right (Right plan) -> do
            logMsg @Text "Resolved:"
            for_ (Map.toList plan) $ \case
                (Root, _) -> pure ()
                (Pkg n, v) -> logMsg ("  " <> T.pack (prettyShow n) <> " => " <> T.pack (prettyShow v))

            logMsg
                ( "\ESC[2mResolved "
                    <> T.pack (show (length [() | (Pkg _, _) <- Map.toList plan]))
                    <> " packages\ESC[0m"
                )
