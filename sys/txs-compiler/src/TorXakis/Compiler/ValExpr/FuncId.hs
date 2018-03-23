{-# LANGUAGE OverloadedStrings #-}
module TorXakis.Compiler.ValExpr.FuncId where

-- TODO: consider adding your own prelude.
import           Data.Map                         (Map)
import qualified Data.Map                         as Map
import           Data.Semigroup                   ((<>))

import           CstrId                           (CstrId, cstrsort, name)
import           FuncId                           (FuncId (FuncId))
import           Id                               (Id (Id))
import           SortId                           (SortId, sortIdBool,
                                                   sortIdString)
import           StdTDefs                         (fromStringName, toStringName)

import           TorXakis.Compiler.Data
import           TorXakis.Compiler.ValExpr.SortId
import           TorXakis.Parser.Data

cstrToIsCstrFuncId :: CstrId -> CompilerM FuncId
cstrToIsCstrFuncId cId = do
    fId <- getNextId
    return $ FuncId ("is" <> name cId) (Id fId) [cstrsort cId] sortIdBool

-- | Define the accessor function for a constructor, using the given field.
cstrToAccFuncId :: HasSortIds e
                => e
                -> CstrId    -- ^ Id of the containing constructor
                -> FieldDecl
                -> CompilerM FuncId
cstrToAccFuncId e cId f = do
    fId <- getNextId
    sId <- findSortIdM e (fieldSort f)
    return $ FuncId (fieldName f) (Id fId) [cstrsort cId] sId

funcDeclsToFuncIds :: HasSortIds e
                   => e -> [FuncDecl] -> CompilerM (Map (Loc FuncDeclE) FuncId)
funcDeclsToFuncIds e fs = do
    fIds <- traverse (funcDeclToFuncId e) fs
    return $ Map.fromList $ zip (getLoc <$> fs) fIds

funcDeclToFuncId :: HasSortIds e
                 => e -> FuncDecl -> CompilerM FuncId
funcDeclToFuncId  e f = do
    fId   <- getNextId
    aSids <- traverse (sortIdOfVarDeclM e) (funcParams f)
    rSid  <- findSortIdM e (funcRetSort f)
    return $ FuncId (funcName f) (Id fId) aSids rSid


-- | Make a 'FuncId' for a sort to string function.
sortToStringFuncId :: SortId -> CompilerM FuncId
sortToStringFuncId sId = do
    fId <- getNextId
    return $ FuncId toStringName (Id fId) [sId] sortIdString

-- | Make a 'FuncId' for a string to sort function.
sortFromStringFuncId :: SortId -> CompilerM FuncId
sortFromStringFuncId sId = do
    fId <- getNextId
    return $ FuncId fromStringName (Id fId) [sortIdString] sId

