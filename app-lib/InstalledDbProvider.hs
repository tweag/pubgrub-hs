{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies          #-}

-- | The installed-world dependency provider, backed by the compiler's package
-- database. Its set type is 'Pow UnitId': a constraint names a finite set of
-- installed unit-ids, and a cofinite set is never expanded. 'expand' commits to
-- the newest instance in the set and reports its dependencies, which are
-- themselves exact installed unit-ids.
module InstalledDbProvider (
    InstalledDbProvider,
    mkInstalledDbProvider,
    installedInRange,
) where

import           Data.List                      (maximumBy)
import           Data.List.NonEmpty             (NonEmpty)
import qualified Data.List.NonEmpty             as NE
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Data.Ord                       (comparing)
import qualified Data.Set                       as Set
import           Distribution.Types.PackageName (PackageName)
import           Distribution.Types.UnitId      (UnitId)
import           PubGrub.Cabal.InstalledDb      (InstalledPkg (..))
import           PubGrub.Lattice                (singleton, (\/))
import           PubGrub.Pow                    (Pow (..))
import           PubGrub.Solver                 (DependencyProvider (..))
import           PubGrub.VersionSet             (VersionSet)
import qualified PubGrub.VersionSet             as VS

-- | An index over one package db: each installed unit-id mapped to its record,
-- and each package name to its unit-ids.
data InstalledDbProvider = InstalledDbProvider
    { pdbById   :: Map UnitId InstalledPkg
    , pdbByName :: Map PackageName (NonEmpty UnitId)
    }

mkInstalledDbProvider :: [InstalledPkg] -> InstalledDbProvider
mkInstalledDbProvider pkgs =
    InstalledDbProvider
        { pdbById = Map.fromList [(ipUnitId p, p) | p <- pkgs]
        , pdbByName =
            Map.fromList
                [ (ipName (NE.head g), NE.map ipUnitId g)
                | g <- NE.groupAllWith ipName pkgs
                ]
        }

-- | The installed unit-ids of @name@ whose version lies in @range@.
installedInRange :: InstalledDbProvider -> PackageName -> VersionSet -> Pow UnitId
installedInRange pdb name range =
    Incl
        ( Set.fromList
            [ uid
            | uid <- maybe [] NE.toList (Map.lookup name (pdbByName pdb))
            , Just p <- [Map.lookup uid (pdbById pdb)]
            , VS.contains range (ipVersion p)
            ]
        )

instance (Monad m) => DependencyProvider InstalledDbProvider PackageName (Pow UnitId) m where
    expand pdb _name sel = pure $ case sel of
        Incl uids ->
            let inDb = Set.filter (`Map.member` pdbById pdb) uids
                pairs = [(uid, ipVersion p) | uid <- Set.toList inDb, Just p <- [Map.lookup uid (pdbById pdb)]]
             in case pairs of
                    [] -> Nothing
                    _ ->
                        let (chosen, _) = maximumBy (comparing snd) pairs
                         in Just (chosen, depsOf chosen)
        _ -> Nothing
      where
        depsOf uid =
            Map.fromListWith
                (\/)
                [ (ipName dep, singleton duid)
                | duid <- maybe [] ipDepends (Map.lookup uid (pdbById pdb))
                , Just dep <- [Map.lookup duid (pdbById pdb)]
                ]
