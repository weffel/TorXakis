{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies      #-}
module TorXakis.Compiler.Defs.ProcDef where

import           Control.Arrow                      (second)
import           Control.Monad.Error.Class          (liftEither, throwError)
import           Data.List                          (find)
import           Data.Map                           (Map)
import qualified Data.Map                           as Map
import           Data.Semigroup                     ((<>))
import           Data.Text                          (Text)
import qualified Data.Text                          as T

import qualified BehExprDefs                        as Beh
import           ChanId                             (ChanId)
import           FuncDef                            (FuncDef)
import           FuncId                             (FuncId)
import           FuncTable                          (Handler, Signature)
import           Id                                 (Id (Id))
import qualified ProcId
import           SortId                             (SortId)
import qualified SortId
import           StatId                             (StatId (StatId))
import qualified StatId
import           StautDef                           (translate)
import           TxsDefs                            (ExitSort (..),
                                                     ProcDef (ProcDef),
                                                     ProcId (ProcId), VEnv)
import           ValExpr                            (ValExpr)
import           VarId                              (VarId, varsort)

import           TorXakis.Compiler.Data
import           TorXakis.Compiler.Data.ProcDecl
import           TorXakis.Compiler.Data.VarDecl
import           TorXakis.Compiler.Defs.BehExprDefs
import           TorXakis.Compiler.Defs.ChanId
import           TorXakis.Compiler.Error
import           TorXakis.Compiler.Maps
import           TorXakis.Compiler.Maps.DefinesAMap
import           TorXakis.Compiler.Maps.VarRef
import           TorXakis.Compiler.MapsTo
import           TorXakis.Compiler.ValExpr.Common
import           TorXakis.Compiler.ValExpr.FuncDef
import           TorXakis.Compiler.ValExpr.SortId
import           TorXakis.Compiler.ValExpr.ValExpr
import           TorXakis.Compiler.ValExpr.VarId
import           TorXakis.Parser.Data

procDeclsToProcDefMap :: ( MapsTo Text SortId mm
                         , MapsTo (Loc VarRefE) (Either (Loc VarDeclE) [Loc FuncDeclE]) mm
                         , MapsTo (Loc FuncDeclE) (Signature, Handler VarId) mm
                         , MapsTo (Loc ProcDeclE) ProcInfo mm
                         , In (Loc FuncDeclE, Signature) (Contents mm) ~ 'False
                         , In (Loc VarDeclE, VarId) (Contents mm) ~ 'False
                         , In (Loc ChanDeclE, ChanId) (Contents mm) ~ 'False
                         , In (Loc ChanRefE, Loc ChanDeclE) (Contents mm) ~ 'False
                         , In (ProcId, ()) (Contents mm) ~ 'False
                         , In (Loc VarDeclE, SortId) (Contents mm) ~ 'False )
                      => mm
                      -> [ProcDecl]
                      -> CompilerM (Map ProcId ProcDef)
procDeclsToProcDefMap mm ps = do
    let pms = innerMap mm
    gProcDeclsToProcDefMap pms emptyMpd ps
    where
      emptyMpd = Map.empty :: Map ProcId ProcDef
      gProcDeclsToProcDefMap :: Map (Loc ProcDeclE) ProcInfo
                             -> Map ProcId ProcDef
                             -> [ProcDecl]
                             -> CompilerM (Map ProcId ProcDef)
      gProcDeclsToProcDefMap pms mpd rs = do
          (ls, rs') <- traverseCatch (mkpIdPDefM pms) rs
          case (ls, rs') of
              ([], _) -> return $ Map.fromList rs' <> innerMap mpd
              (_, []) -> throwError Error
                  { _errorType = ProcessNotDefined
                  , _errorLoc = NoErrorLoc
                  , _errorMsg = T.pack (show (snd <$> ls))
                  }
              (_, _ ) -> gProcDeclsToProcDefMap pms (Map.fromList rs' <.+> mpd) (fst <$> ls)

      mkpIdPDefM :: Map (Loc ProcDeclE) ProcInfo
                 -> ProcDecl
                 -> CompilerM (ProcId, ProcDef)
      mkpIdPDefM pms pd = do
          ProcInfo pId chIds pvIds <- pms .@ getLoc pd :: CompilerM ProcInfo
          -- Scan for channel references and declarations
          chDecls <- getMap () pd :: CompilerM (Map (Loc ChanRefE) (Loc ChanDeclE))
          let chIdsM = Map.fromList chIds
          let body = procDeclBody pd
              mpd' = Map.fromList $ zip (allProcIds pms) (repeat ())
              fshs :: Map (Loc FuncDeclE) (Signature, Handler VarId)
              fshs = innerMap mm
              fss = fst <$> fshs
              paramTypes = Map.fromList (fmap (second varsort) pvIds)

          bTypes  <- Map.fromList <$>
              inferVarTypes (  Map.fromList pvIds
                            :& mm
                            :& paramTypes
                            :& mpd'
                            :& chDecls
                            :& fss
                            :& chIdsM ) body
          bvIds   <- mkVarIds bTypes body
          let mm' = (bTypes `Map.union` paramTypes)
                    :& Map.fromList (pvIds ++ bvIds)
                    :& mm
                    :& mpd'
                    :& chDecls
                    :& chIdsM
          bvds <- liftEither $ varDefsFromExp mm' pd
          b       <- toBExpr mm' bvds body
          -- NOTE that it is crucial that the order of the channel parameters
          -- declarations is preserved!
          procChIds <- traverse (chIdsM .@) (getLoc <$> procDeclChParams pd)
          let pvIds' = snd <$> pvIds
          return ( pId, ProcDef procChIds pvIds' b )

-- | TODO: remove the unnecessary constraints.
stautDeclsToProcDefMap :: ( MapsTo Text SortId mm
                          , MapsTo (Loc VarRefE) (Either (Loc VarDeclE) [Loc FuncDeclE]) mm
                          , MapsTo (Loc FuncDeclE) (Signature, Handler VarId) mm
                          , MapsTo (Loc ProcDeclE) ProcInfo mm
                          , In (Loc FuncDeclE, Signature) (Contents mm) ~ 'False
                          , In (Loc VarDeclE, VarId) (Contents mm) ~ 'False
                          , In (Text, ChanId) (Contents mm) ~ 'False
                          , In (Loc ChanDeclE, ChanId) (Contents mm) ~ 'False
                          , In (Loc ChanRefE, Loc ChanDeclE) (Contents mm) ~ 'False
                          , In (ProcId, ()) (Contents mm) ~ 'False
                          , In (Loc VarDeclE, SortId) (Contents mm) ~ 'False )
                       => mm
                       -> [StautDecl]
                       -> CompilerM (Map ProcId ProcDef)
stautDeclsToProcDefMap mm ts = Map.fromList . concat <$>
    traverse (stautDeclsToProcDefs (innerMap mm)) ts
    where
      stautDeclsToProcDefs :: Map (Loc ProcDeclE) ProcInfo
                           -> StautDecl
                           -> CompilerM [(ProcId, ProcDef)]
      stautDeclsToProcDefs pms staut = do
          p@(ProcInfo pId chIds pvIds) <- mm .@ asProcDeclLoc staut :: CompilerM ProcInfo
          (ProcInfo pIdStd _ _)        <- mm .@ ExtraAut "std" (asProcDeclLoc staut) :: CompilerM ProcInfo
          (ProcInfo pIdStdi _ _)       <- mm .@ ExtraAut "stdi" (asProcDeclLoc staut) :: CompilerM ProcInfo
          let chIdsM = Map.fromList chIds
          procChIds <- traverse (chIdsM .@) (getLoc <$> stautDeclChParams staut)
          let pvIds' = snd <$> pvIds
          (stIds, innerVars, initS, vEnv, trans) <- stautItemToBExpr p
          -- Now we create the other two non-standard automata
          id0   <- getNextId
          id1   <- getNextId
          let trans' = reverse trans -- TODO: only needed for compatibility with the old compiler.
              (pd, iStaut) = translate (Map.empty :: Map.Map FuncId (FuncDef VarId))
                                   (Id id0)
                                   (Id id1)
                                   (ProcId.name pId)
                                   procChIds
                                   (snd <$> pvIds)
                                   (ProcId.procexit pId)
                                   stIds
                                   innerVars
                                   trans'
                                   initS
                                   vEnv
          return [ (pId, ProcDef procChIds pvIds' (Beh.stAut initS vEnv trans'))
                 , (pIdStd, pd)
                 , (pIdStdi, ProcDef procChIds pvIds' iStaut)
                 ]
          where
            -- | Compile the list of @StautItem@'s to a triple of the initial state,
            -- a local variables map, and a list of transitions.
            stautItemToBExpr:: ProcInfo -> CompilerM ([StatId], [VarId], StatId, VEnv, [Beh.Trans])
            stautItemToBExpr (ProcInfo pId chIds pvIds) = do
                -- Collect all the explicit variable declarations.
                innerVSIds <- getMap mm (stautDeclInnerVars staut)
                             :: CompilerM (Map (Loc VarDeclE) SortId)
                innerVIds <- getMap (innerVSIds :& mm) (stautDeclInnerVars staut)
                             :: CompilerM (Map (Loc VarDeclE) VarId)
                -- Collect all the implicit variable declarations (declared in offers).
                let mpd = Map.fromList $ zip (allProcIds pms) (repeat ())
                chDecls <- getMap () staut
                let fshs :: Map (Loc FuncDeclE) (Signature, Handler VarId)
                    fshs = innerMap mm
                    fss = fst <$> fshs

                implVSIds <- Map.fromList <$>
                    inferVarTypes ( Map.fromList pvIds
                                  :& mm
                                  :& Map.fromList (fmap (second varsort) pvIds) -- TODO: reduce dup.
                                  :& mpd
                                  :& chDecls
                                  :& Map.fromList chIds
                                  :& fss
                                  )
                                  (stautTrans staut)
                implVids  <- mkVarIds implVSIds (stautTrans staut)
                let extraVIds = innerVIds `Map.union` Map.fromList implVids
                -- Collect all the state declarations.
                -- TODO: check that there are no duplicated states.
                stIds    <- traverse stateDeclToStateId (stautDeclStates staut)
                -- Make sure there is a unique initial state.
                InitStateDecl iniStRef uds <- getUniqueInitialStateDecl
                iniSt    <- lookupStatId iniStRef stIds
                initVEnv <- stUpdatesToVEnv extraVIds uds
                trans    <- mkTransitions stIds chDecls extraVIds
                return (stIds, Map.elems innerVIds, iniSt, initVEnv, trans)
                where
                  stateDeclToStateId :: StateDecl -> CompilerM StatId
                  stateDeclToStateId st = do
                      stId <- getNextId
                      return $ StatId (stateDeclName st) (Id stId) pId

                  getUniqueInitialStateDecl :: CompilerM InitStateDecl
                  getUniqueInitialStateDecl =
                      case stautInitStates staut of
                          [initStDecl] -> return initStDecl
                          [] -> throwError Error
                              { _errorType = NoDefinition
                              , _errorLoc   = getErrorLoc staut
                              , _errorMsg  = "No initial state declaration"
                              }
                          _  -> throwError Error
                              { _errorType = MultipleDefinitions
                              , _errorLoc  = getErrorLoc staut
                              , _errorMsg  = "Multiple initial state declarations"
                              }

                  lookupStatId :: StateRef -> [StatId] -> CompilerM StatId
                  lookupStatId sr sts = maybe throwE return mElem
                      where mElem = find ((stateRefName sr ==) . StatId.name) sts
                            throwE = throwError Error
                                { _errorType = UndefinedRef
                                , _errorLoc = getErrorLoc sr
                                , _errorMsg = "Could not find the state"
                                }

                  stUpdatesToVEnv :: Map (Loc VarDeclE) VarId
                                  -> [StUpdate]
                                  -> CompilerM VEnv
                  stUpdatesToVEnv lVIds uds = Map.fromList . concat <$>
                      -- TODO: check that there are no overlapping updates
                      -- (more than one update to the same variable).
                      traverse (stUpdateToVEnv lVIds) uds

                  stUpdateToVEnv :: Map (Loc VarDeclE) VarId
                                 -> StUpdate
                                 -> CompilerM [(VarId, ValExpr VarId)]
                  stUpdateToVEnv lVIds (StUpdate vrs e) = do
                      -- Lookup the variable declarations that correspond to the references.
                      vIds <- traverse (findVarIdM (lVIds :& mm)) (getLoc <$> vrs)
                      case vIds of
                          [] -> return []
                          v:_ -> do
                              let mm' = (pvIds <.++> lVIds) :& mm
                              evds <- liftEither $ varDefsFromExp mm' e
                              vExp <- liftEither $
                                  expDeclToValExpr_2 evds (varsort v) e
                              return (zip vIds (repeat vExp))

                  mkTransitions :: [StatId]
                                -> Map (Loc ChanRefE) (Loc ChanDeclE)
                                -> Map (Loc VarDeclE) VarId
                                -> CompilerM [Beh.Trans]
                  mkTransitions stIds chDecls lVIds =
                      traverse mkTransition (stautTrans staut)
                      where
                        mkTransition :: Transition -> CompilerM Beh.Trans
                        mkTransition (Transition fSr ofrD updD tSr) = do
                            from <- lookupStatId fSr stIds
                            to   <- lookupStatId tSr stIds
                            let
                                allVIds = pvIds <.++> lVIds
                                allVSIds = Map.map varsort allVIds
                                mm' = (chIds .& allVIds)
                                      :& allVSIds
                                      :& chDecls
                                      :& mm
                            ovds <- liftEither $ varDefsFromExp mm' ofrD
                            ofr  <- toActOffer mm' ovds ofrD
                            upd  <- stUpdatesToVEnv allVIds updD
                            return $ Beh.Trans from ofr upd to



-- TODO: experiment

-- procDeclsToProcDefMap_2 :: Map (Loc VarRefE) (Either (Loc VarDeclE) [Loc FuncDeclE])
--                        -> Map (Loc VarDeclE) VarId
--                        -> Map (Loc FuncDeclE) (Signature, Handler VarId)
--                        -> Map (Loc ProcDeclE) ProcInfo
--                        -> [ProcDecl]
--                        -> CompilerM (Map ProcId ProcDef)
-- procDeclsToProcDefMap_2 vdecls vids fshs pinfs ps =
--     gProcDeclsToProcDefMap emptyMpd ps
--     where
--       emptyMpd = Map.empty :: Map ProcId ProcDef
--       gProcDeclsToProcDefMap :: Map ProcId ProcDef -- ^ Process definitions obtained so far.
--                              -> [ProcDecl]
--                              -> CompilerM (Map ProcId ProcDef)
--       gProcDeclsToProcDefMap pdefs rs = do
--           (ls, rs') <- traverseCatch mkpIdPDefM rs
--           case (ls, rs') of
--               ([], _) -> return $ Map.fromList rs' <> innerMap pdefs
--               (_, []) -> throwError Error
--                   { _errorType = ProcessNotDefined
--                   , _errorLoc = NoErrorLoc
--                   , _errorMsg = T.pack (show (snd <$> ls))
--                   }
--               (_, _ ) -> gProcDeclsToProcDefMap (Map.fromList rs' <.+> pdefs) (fst <$> ls)

--       mkpIdPDefM :: ProcDecl -> CompilerM (ProcId, ProcDef)
--       mkpIdPDefM pd = do
--           ProcInfo pId chIds pvIds <- pinfs .@ getLoc pd :: CompilerM ProcInfo
--           -- Scan for channel references and declarations
--           chDecls <- getMap () pd :: CompilerM (Map (Loc ChanRefE) (Loc ChanDeclE))
--           let chIdsM = Map.fromList chIds
--               mpd' = Map.fromList $ zip (allProcIds pinfs) (repeat ())
--               fss = fst <$> fshs

--           b  <- toBExpr_2 (procDeclBody pd)
--           -- TODO: And we might need some of these maps (  vids
--           --               :& mpd'
--           --               :& chDecls
--           --               :& chIdsM
--           --               )

--           -- NOTE that it is crucial that the order of the channel parameters
--           -- declarations is preserved!
--           procChIds <- traverse (chIdsM .@) (getLoc <$> procDeclChParams pd)
--           let pvIds' = snd <$> pvIds
--           return ( pId, ProcDef procChIds pvIds' b )
