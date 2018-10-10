{-
TorXakis - Model Based Testing
Copyright (c) 2015-2017 TNO and Radboud University
See LICENSE at root directory of this repository.
-}
-----------------------------------------------------------------------------
-- |
-- Module      :  TorXakis.ValExprContext
-- Copyright   :  (c) TNO and Radboud University
-- License     :  BSD3 (see the file license.txt)
-- 
-- Maintainer  :  pierre.vandelaar@tno.nl (ESI)
-- Stability   :  experimental
-- Portability :  portable
--
-- Context for ValExpr: all defined sorts, variables, and functions
-----------------------------------------------------------------------------
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module TorXakis.ValExpr.ValExprContext
( -- * ValExpr Context
  ValExprContext (..)
, MinimalValExprContext(MinimalValExprContext)
)
where
import           Control.DeepSeq        (NFData)
import           Data.Data              (Data)
import qualified Data.HashMap           as Map
import qualified Data.Text              as T
import           GHC.Generics           (Generic)

import           TorXakis.Error         ( MinError(MinError) )
import           TorXakis.Name          ( RefByName, toMapByName, repeatedByName )
import           TorXakis.Sort          ( SortContext (..), MinimalSortContext (..), elemSort, getSort )
import           TorXakis.VarDef        ( VarDef, MinimalVarDef )
import           TorXakis.FuncDef       ( FuncDef )
import           TorXakis.FuncSignature ( FuncSignature )


-- | A ValExprContext instance contains all definitions to work with value expressions and references thereof
class (SortContext (a v), VarDef v) => ValExprContext a v where
    -- | Accessor for Variable Definitions
    varDefs :: a v -> Map.Map (RefByName v) v

    -- | Add variable definitions to value expression context.
    --   A value expression context is returned when the following constraints are satisfied:
    --
    --   * The 'Name's of added variable definitions are unique
    --
    --   * All sorts of the added variables are known (within this context)
    --
    --   Otherwise an error is returned. The error reflects the violations of any of the aforementioned constraints.
    --
    -- Note that variables in the context are hidden when variables with the same names are added.
    addVarDefs :: a v -> [v] -> Either MinError (a v)

    -- | Accessor for Function Definitions
    funcDefs :: a v -> Map.Map FuncSignature (FuncDef v)

    -- | Add function definitions to value expression context.
    --   A value expression context is returned when the following constraints are satisfied:
    --
    --   * The signatures of the function definitions are unique.
    --
    --   * All references (both Sort and FunctionDefinition) are known
    --
    --   * The sort of all bodys of the added Function Definitions is in agreement with the function signature (its return type).
    --
    --   Otherwise an error is returned. The error reflects the violations of any of the aforementioned constraints.
    addFuncDefs :: a v -> [FuncDef v] -> Either MinError (a v)


-- | A minimal instance of 'ValExprContext'.
data MinimalValExprContext v = MinimalValExprContext { sortContext :: MinimalSortContext
                                                         -- var definitions
                                                     , _varDefs :: Map.Map (RefByName v) v
                                                         -- function definitions
                                                     , _funcDefs :: Map.Map FuncSignature (FuncDef v)
                                                     } deriving (Eq, Ord, Read, Show, Generic, NFData, Data)

instance SortContext (MinimalValExprContext MinimalVarDef) where
    empty = MinimalValExprContext (MinimalSortContext Map.empty) Map.empty Map.empty
    adtDefs ctx    = adtDefs (sortContext ctx)
    addAdtDefs ctx as = case addAdtDefs (sortContext ctx) as of
                          Left e     -> Left e
                          Right sctx -> Right $ ctx {sortContext = sctx} 

instance ValExprContext MinimalValExprContext MinimalVarDef where
    varDefs = _varDefs
    addVarDefs ctx vs 
        | not $ null nuVarNames    = Left $ MinError (T.pack ("Non unique variable names: " ++ show nuVarNames))
        | not $ null undefinedSort = Left $ MinError (T.pack ("Sorts not defined in context of variables: " ++ show undefinedSort))
        | otherwise                = Right $ ctx { _varDefs = Map.union (toMapByName vs) (_varDefs ctx) }
      where
        nuVarNames :: [MinimalVarDef]
        nuVarNames = repeatedByName vs

        undefinedSort :: [MinimalVarDef]
        undefinedSort = filter (not . elemSort ctx . getSort) vs

    funcDefs = _funcDefs
    addFuncDefs = undefined
