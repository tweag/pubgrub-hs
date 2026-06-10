module PubGrub where
import           Data.Map.Strict      (Map)
import           Distribution.Version (Version, VersionRange, anyVersion,
                                       intersectVersionRanges, noVersion,
                                       unionVersionRanges, withinRange)

class (Eq p, Ord p, Show p) => Package p

class VersionSet vs where
  empty        :: vs             -- no versions satisfy this
  full         :: vs             -- all versions satisfy this
  complement   :: vs -> vs
  union        :: vs -> vs -> vs
  intersection :: vs -> vs -> vs
  contains     :: vs -> Version -> Bool

instance VersionSet VersionRange where
  empty        = noVersion
  full         = anyVersion
  complement   = flip intersectVersionRanges full . union noVersion
  union        = unionVersionRanges
  intersection = intersectVersionRanges
  contains     = flip withinRange

-- The external oracle: knows about packages and their dependencies.
class (Package p, VersionSet vs) => DependencyProvider dp p vs where
  -- Choose the best version of p that vs allows, or Nothing if it allows
  -- none.
  chooseVersion   :: dp -> p -> vs -> Maybe Version
  getDependencies :: dp -> p -> Version -> Map p vs

data Term vs
  = Positive vs   -- the selected version must lie within vs
  | Negative vs   -- the package is absent, or its version lies outside vs
  deriving (Eq, Show)

-- Does t2 imply t1? (Is t2 at least as constraining as t1?)
satisfies :: VersionSet vs => Term vs -> Term vs -> Bool
satisfies = undefined

-- Combine two terms for the same package (logical AND).
intersectTerms :: VersionSet vs => Term vs -> Term vs -> Term vs
intersectTerms = undefined
