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
import           Distribution.Types.PackageName (mkPackageName)
import           Distribution.Version           (mkVersion)
import           HackageProvider                (HackageProvider,
                                                 ResolveError (..))
import           Pkg                            (Pkg (..))
import           Provider                       (Combined)
import           PubGrub.Choice                 (Choice (..), ChoiceSet,
                                                 ChoiceSource (..),
                                                 Repository (..))
import qualified PubGrub.Pretty                 as P
import           PubGrub.Report                 (ReportEnv (..),
                                                 reportConflictWith)
import           PubGrub.Solver                 (SolveError (..),
                                                 SolverMsg (..), solve)
import           PubGrub.Term                   (Term (..))
import           PubGrub.Types                  (incompTerms)
import           UnliftIO                       (MonadUnliftIO, try)

renderSolverMsg :: SolverMsg Pkg ChoiceSet -> Text
renderSolverMsg msg = case msg of
    Deciding (Pkg n) r -> "\ESC[2mdeciding " <> name n <> " " <> P.pretty r <> "\ESC[0m"
    Chose (Pkg n) v -> "  \ESC[32m\x2713\ESC[0m " <> name n <> "-" <> P.pretty v
    NoVersionFor (Pkg n) r -> "  \ESC[31m\x2717\ESC[0m no version for " <> name n <> " in " <> P.pretty r
    Conflict i -> "  \ESC[33m\x26A0\ESC[0m conflict: " <> renderIncompat i
    Backtracked n -> "  \ESC[2m\x21A9 backtracking to level " <> T.pack (show n) <> "\ESC[0m"
    _ -> "" -- Root payloads: no output
  where
    name = T.pack . prettyShow
    renderIncompat i = T.intercalate ", " [renderTerm p t | (p, t) <- Map.toList (incompTerms i)]
    renderTerm Root _               = "root"
    renderTerm (Pkg n) (Positive r) = name n <> " " <> P.pretty r
    renderTerm (Pkg n) (Negative r) = name n <> " not " <> P.pretty r

-- | The synthetic root element passed to the solver. The combiner's
-- @expand Root@ produces a 'Source' element at version 0; membership for source
-- choices is by version, so this value need only live in the source world at
-- version 0 for the term logic to line up.
rootChoice :: Choice
rootChoice = Source (ChoiceSource (mkPackageName "root") (mkVersion [0]) Hackage)

-- | Resolve the dependency closure of the combined provider's target, printing
-- phase notes to stderr and the plan to stdout.
runSolve
    :: forall m env
     . (MonadUnliftIO m, WithLog env Text m)
    => Combined HackageProvider -> m ()
runSolve combined = do
    outcome <- do
        try (usingLoggerT (LogAction $ logMsg . renderSolverMsg) (solve combined Root rootChoice))
    case outcome of
        Left (ResolveError n v) ->
            logMsg ("Failed to parse " <> T.pack (prettyShow n) <> "-" <> T.pack (prettyShow v))
        Right (Left (NoSolution i)) -> do
            let env =
                    ReportEnv
                        { rePinned = const Nothing
                        , reIsRoot = \case
                            Root -> True
                            _ -> False
                        }
            logMsg $ T.unlines ["No solution:", reportConflictWith env i]
        Right (Right plan) -> do
            logMsg @Text "Resolved:"
            for_ (Map.toList plan) $ \case
                (Root, _) -> pure ()
                (Pkg n, choice) -> logMsg ("  " <> T.pack (prettyShow n) <> " => " <> P.pretty choice)

            logMsg
                ( "\ESC[2mResolved "
                    <> T.pack (show (length [() | (Pkg _, _) <- Map.toList plan]))
                    <> " packages\ESC[0m"
                )
