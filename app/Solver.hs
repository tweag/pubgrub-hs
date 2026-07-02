{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Solver (
    runSolve,
    renderSolverMsg,
)
where

import           Colog                          (LogAction (..), WithLog,
                                                 logMsg, usingLoggerT)
import           Data.Foldable                  (for_)
import qualified Data.Map.Strict                as Map
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Distribution.Pretty            (prettyShow)
import           Distribution.Types.PackageName (PackageName)
import           Provider                       (Combined)
import           PubGrub.Choice                 (Choice, ChoiceSet)
import           PubGrub.Incompatibility        (incompTerms)
import qualified PubGrub.Pretty                 as P
import           PubGrub.Report                 (ReportEnv (..),
                                                 reportConflictWith)
import           PubGrub.Solver                 (SolveError (..),
                                                 SolverMsg (..), solve)
import           PubGrub.Term                   (Term (..))
import           SourceProvider                 (ResolveError (..),
                                                 SourceProvider)
import           UnliftIO                       (MonadUnliftIO, try)

renderSolverMsg :: SolverMsg PackageName ChoiceSet -> Text
renderSolverMsg msg = case msg of
    Deciding n r -> "\ESC[2mdeciding " <> name n <> " " <> P.pretty r <> "\ESC[0m"
    Chose n v -> "  \ESC[32m\x2713\ESC[0m " <> name n <> " => " <> P.pretty v
    NoVersionFor n r -> "  \ESC[31m\x2717\ESC[0m no version for " <> name n <> " in " <> P.pretty r
    Conflict i -> "  \ESC[33m\x26A0\ESC[0m conflict: " <> renderIncompat i
    Backtracked n -> "  \ESC[2m\x21A9 backtracking to level " <> T.pack (show n) <> "\ESC[0m"
  where
    name = T.pack . prettyShow
    renderIncompat i = T.intercalate ", " [renderTerm p t | (p, t) <- Map.toList (incompTerms i)]
    renderTerm n (Positive r) = name n <> " " <> P.pretty r
    renderTerm n (Negative r) = name n <> " not " <> P.pretty r

-- | Resolve the dependency closure of the combined provider's target, printing
-- phase notes to stderr and the plan to stdout.
runSolve
    :: forall m env
     . (MonadUnliftIO m, WithLog env Text m)
    => Combined SourceProvider -> PackageName -> Choice -> m ()
runSolve combined rootPkg rootChoice = do
    outcome <- do
        try (usingLoggerT (LogAction $ logMsg . renderSolverMsg) (solve combined rootPkg rootChoice))
    case outcome of
        Left (ResolveError n v) ->
            logMsg ("Failed to parse " <> T.pack (prettyShow n) <> "-" <> T.pack (prettyShow v))
        Right (Left (NoSolution i)) -> do
            let env =
                    ReportEnv
                        { rePinned = const Nothing
                        }
            logMsg $ T.unlines ["No solution:", reportConflictWith env i]
        Right (Right plan) -> do
            logMsg @Text "Resolved:"
            for_ (Map.toList plan) $ \case
                (n, choice) -> logMsg ("  " <> T.pack (prettyShow n) <> " => " <> P.pretty choice)

            logMsg
                ( "\ESC[2mResolved "
                    <> T.pack (show (length [() | (_, _) <- Map.toList plan]))
                    <> " packages\ESC[0m"
                )
