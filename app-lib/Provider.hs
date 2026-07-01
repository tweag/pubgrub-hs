{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternSynonyms       #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}

-- | The combined installed and source dependency provider. It resolves over
-- 'ChoiceSet', the product of the installed world (@Pow UnitId@, from an
-- 'InstalledDbProvider') and the source world (a version with its flag
-- assignment). The source provider it wraps answers over versions alone.
--
-- The policy prefers installed: when the constraint admits an installed
-- instance, it commits to it and pins its dependencies to exact unit-ids.
-- Otherwise it falls back to a source release, whose dependencies span both
-- worlds: a range, plus the installed instances within it.
module Provider (Combined (..)) where

import qualified Data.Map.Strict                as Map
import           Distribution.Types.PackageName (PackageName)
import           Distribution.Version           (mkVersion)
import           InstalledDbProvider            (InstalledDbProvider,
                                                 installedInRange)
import           Pkg                            (Pkg (..))
import           PubGrub.Choice                 (ChoiceSet (..),
                                                 pattern Installed,
                                                 pattern Source)
import           PubGrub.Lattice                (bottom)
import           PubGrub.Solver                 (DependencyProvider (..))
import           PubGrub.SourceConfig           (SourceConfig (..), fcTop,
                                                 mkCell, versionsOf)
import           PubGrub.VersionSet             (VersionSet)

-- | @cTarget@ and @cRange@ are the root's single dependency: the package
-- being solved for, and its range.
data Combined src = Combined
    { cDb     :: InstalledDbProvider
    , cSource :: src
    , cTarget :: PackageName
    , cRange  :: VersionSet
    }

instance
    (Monad m, DependencyProvider src Pkg VersionSet m)
    => DependencyProvider (Combined src) Pkg ChoiceSet m
    where
    -- The synthetic root depends on the target across both worlds.
    expand c Root _ =
        let dep =
                ChoiceSet
                    ( installedInRange (cDb c) (cTarget c) (cRange c)
                    , mkCell (cRange c) fcTop
                    )
            root = Source (SourceConfig (mkVersion [0]) mempty)
         in pure (Just (root, Map.singleton (Pkg (cTarget c)) dep))
    expand c p (ChoiceSet (inst, src)) = do
        mi <- expand (cDb c) p inst -- Maybe (UnitId, Map Pkg (Pow UnitId))
        case mi of
            Just (uid, ideps) ->
                -- An installed instance's dependencies are exact unit-ids,
                -- with no source half.
                pure (Just (Installed uid, fmap installedDep ideps))
            Nothing -> do
                -- The source provider is version-only; project the flag axis away.
                ms <- expand (cSource c) p (versionsOf src) -- Maybe (Version, Map Pkg VersionSet)
                pure (fmap sourceResult ms)
      where
        installedDep i = ChoiceSet (i, bottom)
        -- A source choice decides no flags (they are defaulted downstream), and
        -- its dependency ranges admit any flag assignment.
        sourceResult (v, sdeps) =
            ( Source (SourceConfig v mempty)
            , Map.mapWithKey liftSourceDep sdeps
            )
        -- A source dependency spans both worlds: its range (any flags), plus any
        -- installed instance falling within that range.
        liftSourceDep (Pkg dn) range =
            ChoiceSet (installedInRange (cDb c) dn range, mkCell range fcTop)
        liftSourceDep Root range = ChoiceSet (bottom, mkCell range fcTop)
