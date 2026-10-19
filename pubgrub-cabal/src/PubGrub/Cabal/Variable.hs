-- | What the solver assigns values to.
--
-- A solver variable is a package name, or one automatic flag of a package. A
-- flag is identified by its /declaration/: its name together with its declared
-- default. Two releases that declare @fast@ with the same default share the
-- variable, so a guarded dependency they both carry can be stated once over
-- both, as one incompatibility over a range of releases; a release that
-- changed the default declares a different flag and gets a variable of its
-- own. At most one release of a package is ever in a plan, so the shared
-- variable is always that release's flag.
--
-- Carrying the default in the identity is what lets the provider offer it first
-- without knowing which release was decided: it reads the variable and nothing
-- else. Manual flags are never variables; they are resolved at their defaults
-- when a release is flattened.
module PubGrub.Cabal.Variable
    ( Flag (..)
    , Var (..)
    , varPackage
    ) where

import qualified Data.Text                      as T
import           Distribution.Types.Flag        (FlagName)
import           Distribution.Types.PackageName (PackageName)
import           PubGrub.Cabal.Pretty           ()
import           PubGrub.Pretty                 (Pretty (..))

-- | A flag as a @.cabal@ file declares it: a name and a default. The @manual@
-- marking is not here because a manual flag never reaches the solver.
data Flag = Flag
    { flagName    :: FlagName
    , flagDefault :: Bool
    }
    deriving (Eq, Ord, Show)

-- | A solver variable.
data Var
    = PackageVar PackageName
    | FlagVar PackageName Flag
      -- ^ an automatic flag of the package, searched alongside its version
    deriving (Eq, Ord, Show)

-- | The package a variable belongs to: itself, or the owner of the flag.
varPackage :: Var -> PackageName
varPackage (PackageVar p) = p
varPackage (FlagVar p _)  = p

instance Pretty Flag where
    pretty = pretty . flagName

-- | @foo@, or @foo:fast@ for a flag. The set a flag term ranges over says on or
-- off; the variable alone only says which flag.
instance Pretty Var where
    pretty (PackageVar p) = pretty p
    pretty (FlagVar p f)  = pretty p <> T.pack ":" <> pretty f
