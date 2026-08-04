-- | The installed (boot) package world, from a compiler's global package db.
--
-- Indexes @[InstalledPkg]@ for what the provider needs of it: all installed
-- units of a package name, which become the 'UsePreInstalled' instances it may
-- offer ('installedInstancesOf'), and the unit graph, which says what choosing
-- one of them commits to ('closureEdges').
module Bridge.Installed
    ( InstalledDb(..)
    , mkInstalledDb
    , installedInstancesOf
    , toPreInstalled
    , InstalledEdge(..)
    , closureEdges
    ) where

import           Bridge.Cabal.InstalledPkg      (InstalledPkg (..))
import           Data.Function                  (on)
import           Data.List                      (nubBy)
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Data.Set                       (Set)
import qualified Data.Set                       as Set
import           Distribution.Types.PackageName (PackageName)
import           Distribution.Types.UnitId      (UnitId)
import           PubGrub.Index.PreInstalled     (PreInstalledPackage (..))
import           PubGrub.InstanceSet            (Instance (..))

data InstalledDb = InstalledDb
    { idbById   :: Map UnitId InstalledPkg
    , idbByName :: Map PackageName [InstalledPkg]
    }

mkInstalledDb :: [InstalledPkg] -> InstalledDb
mkInstalledDb pkgs =
    InstalledDb
        { idbById = Map.fromList [(ipUnitId p, p) | p <- pkgs]
        , idbByName = Map.fromListWith (++) [(ipName p, [p]) | p <- pkgs]
        }

toPreInstalled :: InstalledPkg -> PreInstalledPackage
toPreInstalled p =
    PreInstalledPackage
        { pipUnitId = ipUnitId p
        , pipVersion = ipVersion p
        , pipDependencies = ipDepends p
        }

-- | Every installed unit of a package, as a 'UsePreInstalled' instance.
installedInstancesOf :: InstalledDb -> PackageName -> [Instance]
installedInstancesOf db p =
    [UsePreInstalled (toPreInstalled u) | u <- Map.findWithDefault [] p (idbByName db)]

-- --------------------------------------------------------------------------
-- The unit graph
-- --------------------------------------------------------------------------

-- | One dependency edge between installed units. Both ends carry the package
-- name that names them as solver variables, since that is what an
-- incompatibility is keyed by.
data InstalledEdge = InstalledEdge
    { ieFrom :: (PackageName, PreInstalledPackage)
    , ieTo   :: (PackageName, PreInstalledPackage)
    }
    deriving (Eq, Show)

-- | Every dependency edge in the reflexive-transitive closure of a unit.
--
-- An installed unit is a compiled artifact linked against exactly these units,
-- transitively: none of it is a search question. Emitting the whole edge set
-- when the unit is chosen lets unit propagation chain through the closure in a
-- single fixpoint, instead of learning one hop per decision.
--
-- Each edge names its /own/ depender, not the unit the walk started from, so
-- every edge is a genuine direct dependency and reports about it stay true.
--
-- Deterministic: depth-first in the order @ipDepends@ lists them, each unit
-- expanded once. The visited set keeps the walk finite on a cycle (GHC's db is
-- a DAG; this is defensive). A unit depending on itself is dropped separately:
-- an incompatibility whose two terms name the same package collapses to a
-- single bogus term.
--
-- A 'UnitId' absent from the db contributes no edge. That is vacuous while only
-- @[GlobalPackageDB]@ is read ('Bridge.Cabal.InstalledPkg.getInstalledPackages'),
-- and is where dependencies would go missing silently if the db set widened.
closureEdges :: InstalledDb -> UnitId -> [InstalledEdge]
closureEdges db root = go (Set.singleton root) (lookupUnit root)
  where
    go :: Set UnitId -> [InstalledPkg] -> [InstalledEdge]
    go _ [] = []
    go seen (u : queued) =
        let deps = nubBy ((==) `on` ipUnitId) (concatMap lookupUnit (ipDepends u))
            (seen', fresh) = foldl' enqueue (seen, []) deps
         in [ InstalledEdge (named u) (named d)
            | d <- deps
            , ipUnitId d /= ipUnitId u
            ]
                ++ go seen' (reverse fresh ++ queued)

    enqueue (seen, acc) d
        | Set.member (ipUnitId d) seen = (seen, acc)
        | otherwise                    = (Set.insert (ipUnitId d) seen, d : acc)

    lookupUnit uid = maybe [] pure (Map.lookup uid (idbById db))
    named u = (ipName u, toPreInstalled u)
