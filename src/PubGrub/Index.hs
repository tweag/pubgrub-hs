module PubGrub.Index where

import           Data.Map                       (Map)
import           Distribution.Types.PackageName (PackageName)
import           PubGrub.Index.PreInstalled     (PreInstalledPackage)
import           PubGrub.Index.SourcePackage    (SourcePackage)


newtype IndexPackage = IndexPackage (Either PreInstalledPackage SourcePackage)
    deriving (Show)

newtype Index = Index (Map PackageName [IndexPackage])
    deriving (Show)
