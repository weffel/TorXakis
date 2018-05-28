{-
TorXakis - Model Based Testing
Copyright (c) 2015-2017 TNO and Radboud University
See LICENSE at root directory of this repository.
-}

-----------------------------------------------------------------------------
-- |
-- Module      :  TxsSim
-- Copyright   :  TNO and Radboud University
-- License     :  BSD3
-- Maintainer  :  jan.tretmans
-- Stability   :  experimental
--
-- Core Module TorXakis API:
-- Simulation Mode
-----------------------------------------------------------------------------

-- {-# LANGUAGE OverloadedStrings #-}
-- {-# LANGUAGE ViewPatterns        #-}

module TxsSim

( -- * set up TorXakis core
  txsSetCore

  -- * initialize TorXakis core
, txsInitCore

  -- * terminate TorXakis core
, txsTermitCore

{-

  -- * Mode
  -- ** start testing
, txsSetTest

  -- *** test Input Action
, txsTestIn

  -- *** test Output Action
, txsTestOut

  -- *** test number of Actions
, txsTestN

  -- ** start simulating
, txsSetSim

  -- *** simulate number of Actions
, txsSimN

  -- ** stop stepping
, txsStopNW

  -- ** stop testing, simulating
, txsStopEW

-}
  -- *  TorXakis definitions loaded into the core.
, txsGetTDefs
, txsGetSigs
, txsGetCurrentModel
{-
  -- ** set all torxakis definitions
, txsSetTDefs


  -- * Parameters
  -- ** get all parameter values
, txsGetParams

  -- ** get value of parameter
, txsGetParam

  -- ** set value of parameter
, txsSetParam

  -- * set random seed
, txsSetSeed

-}

  -- * evaluation of value expression
, txsEval

{-

  -- * Solving
  -- ** finding a solution for value expression
, txsSolve

  -- ** finding an unique solution for value expression
, txsUniSolve

  -- ** finding a random solution for value expression
, txsRanSolve

  -- * show item
, txsShow


  -- * give path
, txsPath


  -- * give menu
, txsMenu


  -- * give action to mapper
, txsMapper

  -- * test purpose for N complete coverage
, txsNComp

  -- * LPE transformation
, txsLPE

-}

)

-- ----------------------------------------------------------------------------------------- --
-- import

where

-- import           Control.Arrow
-- import           Control.Monad
-- import           Control.Monad.State
-- import qualified Data.List           as List
-- import qualified Data.Map            as Map
-- import           Data.Maybe
-- import           Data.Monoid
-- import qualified Data.Set            as Set
-- import qualified Data.Text           as T
-- import           System.IO
-- import           System.Random

-- import from local
-- import           CoreUtils
-- import           Ioco
-- import           Mapper
-- import           NComp
-- import           Purpose
-- import           Sim
-- import           Step
-- import           Test

-- import           Config              (Config)
-- import qualified Config

-- import from behave(defs)
-- import qualified Behave
-- import qualified BTree
-- import           Expand              (relabel)

-- import from coreenv
-- import           EnvCore             (modeldef)
-- import qualified EnvCore             as IOC
-- import qualified EnvData
-- import qualified ParamCore

-- import from defs
-- import qualified Sigs
-- import qualified TxsDDefs
-- import qualified TxsDefs
-- import qualified TxsShow
-- import           TxsUtils

-- import from solve
-- import qualified FreeVar
-- import qualified SMT
-- import qualified Solve
-- import qualified Solve.Params
-- import qualified SolveDefs
-- import qualified SMTData

-- import from value
-- import qualified Eval

-- import from lpe
-- import qualified LPE
-- import qualified LPE

-- import from valexpr
-- import qualified SortId
-- import qualified SortOf
-- import           ConstDefs
-- import           VarId


-- ----------------------------------------------------------------------------------------- --
-- | Set Simulating Mode.
--
--   Only possible when in Initing Mode.
txsSetSim :: IOC.EWorld ew
          => D.ModelDef                           -- ^ model definition.
          -> Maybe D.MapperDef                    -- ^ optional mapper definition.
          -> ew                                   -- ^ external world.
          -> IOC.IOC (Either EnvData.Msg ())
txsSetSim moddef mapdef eworld  =  do
     envc <- get
     case IOC.state envc of
       IOC.Initing { IOC.smts      = smts
                   , IOC.tdefs     = tdefs
                   , IOC.sigs      = sigs
                   , IOC.putmsgs  = putmsgs
                   }
         -> do IOC.putCS IOC.SimSet { IOC.smts      = smts
                                    , IOC.tdefs     = tdefs
                                    , IOC.sigs      = sigs
                                    , IOC.modeldef  = moddef
                                    , IOC.mapperdef = mapdef
                                    , IOC.eworld    = eworld
                                    , IOC.putmsgs   = putmsgs
                                    }
               Right <$> putmsgs [ EnvData.TXS_CORE_USER_INFO
                                   "Simulating Mode set" ]
       _ -> return $ Left $ EnvData.TXS_CORE_USER_ERROR
                            "Simulating Mode must be set from Initing mode"

-- ----------------------------------------------------------------------------------------- --
-- | Shut Simulating Mode.
--
--   Only possible when in SimSet Mode.
txsShutSim :: IOC.IOC (Either EnvData.Msg ())
txsShutSim  =  do
     envc <- get
     case IOC.state envc of
       IOC.SimSet { IOC.smts      = smts
                  , IOC.tdefs     = tdefs
                  , IOC.sigs      = sigs
                  , IOC.modeldef  = _moddef
                  , IOC.mapperdef = _mapdef
                  , IOC.eworld    = _eworld
                  , IOC.putmsgs   = putmsgs
                  }
         -> do IOC.putCS IOC.Initing { IOC.smts     = smts
                                     , IOC.tdefs    = tdefs
                                     , IOC.sigs     = sigs
                                     , IOC.putmsgs  = putmsgs
                                     }
               Right <$> putmsgs [ EnvData.TXS_CORE_USER_INFO
                                   "Simulating Mode shut" ]
       _ -> return $ Left $ EnvData.TXS_CORE_USER_ERROR
                            "Simulating Mode must be shut from SimSet Mode"

-- ----------------------------------------------------------------------------------------- --
-- | Start simulating.
--
--   Only possible when in SimSet Mode.
txsStartSim :: IOC.IOC (Either EnvData.Msg ())
txsStartSim  =  do
     envc <- get
     case IOC.state envc of
       IOC.SimSet { IOC.smts = smts
                  , IOC.tdefs = tdefs
                  , IOC.sigs = sigs
                  , IOC.modeldef  = moddef
                  , IOC.mapperdef = mapdef
                  , IOC.eworld    = eworld
                  , IOC.putmsgs = putmsgs
                  }
         -> do IOC.putCS IOC.Simuling { IOC.smts      = smts
                                      , IOC.tdefs     = tdefs
                                      , IOC.sigs      = sigs
                                      , IOC.modeldef  = moddef
                                      , IOC.mapperdef = mapdef
                                      , IOC.eworld    = eWorld
                                      , IOC.behtrie   = []
                                      , IOC.inistate  = 0
                                      , IOC.curstate  = 0
                                      , IOC.modsts    = []
                                      , IOC.mapsts    = []
                                      , IOC.putmsgs   = putmsgs
                                      }
               (maybt,mt) <- startSimulator moddef mapdef
               case maybt of
                 Nothing
                   -> Right <$> putmsgs [ EnvData.TXS_CORE_SYSTEM_INFO
                                          "Starting Simulating Mode failed" ]
                 Just bt
                   -> do eworld' <- IOC.startW eworld
                         IOC.putCS IOC.Simuling { IOC.smts      = smts
                                                , IOC.tdefs     = tdefs
                                                , IOC.sigs      = sigs
                                                , IOC.modeldef  = moddef
                                                , IOC.mapperdef = mapdef
                                                , IOC.eworld    = eworld'
                                                , IOC.behtrie   = []
                                                , IOC.inistate  = 0
                                                , IOC.curstate  = 0
                                                , IOC.modsts    = bt
                                                , IOC.mapsts    = mt
                                                , IOC.putmsgs   = putmsgs
                                                }
                         Right <$> putmsgs [ EnvData.TXS_CORE_USER_INFO
                                             "Simulating Mode started" ]
                         return eWorld'
       _ -> return $ Left $ EnvData.TXS_CORE_USER_ERROR
                            "Simulating Mode must be started from SimSet Mode"


startSimulator :: TxsDefs.ModelDef
               -> Maybe TxsDefs.MapperDef
               -> IOC.IOC ( Maybe BTree.BTree, BTree.BTree )

startSimulator (TxsDefs.ModelDef minsyncs moutsyncs msplsyncs mbexp)
               Nothing  =
     let allSyncs = minsyncs ++ moutsyncs ++ msplsyncs
     in do
       envb            <- filterEnvCtoEnvB
       (maybt', envb') <- lift $ runStateT (Behave.behInit allSyncs mbexp) envb
       writeEnvBtoEnvC envb'
       return ( maybt', [] )

startSimulator (TxsDefs.ModelDef minsyncs moutsyncs msplsyncs mbexp)
               (Just (TxsDefs.MapperDef achins achouts asyncsets abexp))  =
     let { mins  = Set.fromList minsyncs
         ; mouts = Set.fromList moutsyncs
         ; ains  = Set.fromList $ filter (not . Set.null)
                       [ sync `Set.intersection` Set.fromList achins  | sync <- asyncsets ]
         ; aouts = Set.fromList $ filter (not . Set.null)
                       [ sync `Set.intersection` Set.fromList achouts | sync <- asyncsets ]
         }
      in if     mouts `Set.isSubsetOf` ains
             && mins  `Set.isSubsetOf` aouts
           then do let allSyncs = minsyncs ++ moutsyncs ++ msplsyncs
                   envb            <- filterEnvCtoEnvB
                   (maybt',envb' ) <- lift $ runStateT (Behave.behInit allSyncs  mbexp) envb
                   (maymt',envb'') <- lift $ runStateT (Behave.behInit asyncsets abexp) envb'
                   writeEnvBtoEnvC envb''
                   case (maybt',maymt') of
                     (Nothing , _       ) -> do
                          IOC.putMsgs [ EnvData.TXS_CORE_USER_ERROR "Tester model failed" ]
                          return ( Nothing, [] )
                     (_       , Nothing ) -> do
                          IOC.putMsgs [ EnvData.TXS_CORE_USER_ERROR "Tester mapper failed" ]
                          return ( Nothing, [] )
                     (Just _, Just mt') ->
                          return ( maybt', mt' )
           else do IOC.putMsgs [ EnvData.TXS_CORE_USER_ERROR "Inconsistent definitions" ]
                   return ( Nothing, [] )

-- ----------------------------------------------------------------------------------------- --
-- | Stop simulating.
--
--   Only possible when in Simuling Mode.
txsStopSim :: IOC.IOC (Either EnvData.Msg ())
txsStopSim  =  do
     envc <- get
     case IOC.state envc of
       IOC.Simuling { IOC.smts      = smts
                    , IOC.tdefs     = tdefs
                    , IOC.sigs      = sigs
                    , IOC.modeldef  = moddef
                    , IOC.mapperdef = mapdef
                    , IOC.eworld    = eworld
                    , IOC.behtrie   = _behtrie
                    , IOC.inistate  = _inistate
                    , IOC.curstate  = _curstate
                    , IOC.modsts    = _modsts
                    , IOC.mapsts    = _mapsts
                    , IOC.putmsgs   = putmsgs
                    }
         -> do eworld' <- IOC.stopW eworld
               IOC.putCS IOC.SimSet { IOC.smts      = smts
                                    , IOC.tdefs     = tdefs
                                    , IOC.sigs      = sigs
                                    , IOC.modeldef  = moddef
                                    , IOC.mapperdef = mapdef
                                    , IOC.eworld    = eworld'
                                    , IOC.putmsgs   = putmsgs
                                    }
               Right <$> putmsgs [ EnvData.TXS_CORE_USER_INFO
                                   "Simulating Mode stopped" ]
       _ -> return $ Left $ EnvData.TXS_CORE_USER_ERROR
                            "Simulating Mode must be stopped from Simulating Mode"

-- ----------------------------------------------------------------------------------------- --
-- | Simulate system by observing input action from External World.
--
--   Only possible when Simuling.
txsSimActIn :: IOC.IOC (Either EnvData.Msg DD.Verdict)
txsSimActIn  =  do
     envc <- get
     case IOC.state envc of
       IOC.Simuling {}
         -> do (_, verdict) <- Sim.simAfroW 1 1
               return $ Right verdict
       _ -> return $ Left $ EnvData.TXS_CORE_USER_ERROR
                            "Simulating input only in Simulating Mode"

-- ----------------------------------------------------------------------------------------- --
-- | Simulate system by sending provided output action to External World.
--
--   Only possible when Simuling
txsSimActOut :: DD.Action                                 -- ^ output action to world.
             -> IOC.IOC (Either EnvData.Msg DD.Verdict)   -- ^ verdict of simulation.
txsSimActOut act  =  do
     envc <- get
     case IOC.state envc of
       IOC.Simuling { IOC.putmsgs = putmsgs }
         -> do putmsgs [ EnvData.TXS_CORE_USER_INFO
                         "NOTE: doing specified action not implemented yet; " ++
                         "doing random action instead" ]
               (_,verdict) <- Sim.simAtoW 1 1
               return $ Right verdict
       _ -> return $ Left $ EnvData.TXS_CORE_USER_ERROR
                            "Testing with action only in Testing Mode (without Test Purpose)"

-- ----------------------------------------------------------------------------------------- --
-- | Simulate system by sending output action according to offer-pattern to External World.
--
--   Only possible when Simuling.
txsSimOfferOut :: D.Offer                           -- ^ Offer-pattern to step in model.
               -> IOC.IOC (Either EnvData.Msg DD.Verdict)
txsSimOfferOut offer  =  do
     envc <- get
     case IOC.state envc of
       IOC.Simuling { IOC.putmsgs = putmsgs }
         -> do mact <- randOff2Act offer
               case mact of
                 Nothing
                   -> do putmsgs [ EnvData.TXS_CORE_USER_INFO
                                   "Could not generate action for simulating with output" ]
                         return $ Right DD.NoVerdict
                 Just act
                   -> do putmsgs [ EnvData.TXS_CORE_USER_INFO
                                   "NOTE: doing specified offer not implemented yet; " ++
                                   "doing random action instead" ]
                         (_,verdict) <- Sim.simAtoW 1 1
                         return $ Right verdict
       _ -> return $ Left $ EnvData.TXS_CORE_USER_ERROR
                            "Simulating with offer only in Simulating Mode"

-- ----------------------------------------------------------------------------------------- --

XXXXXX

-- | Test SUT with the provided input action.









-- | stop testing, simulating, or stepping.
-- returns txscore to the initialized state, when no External World running.
-- See 'txsSetStep'.
txsStopNOEW :: IOC.IOC ()
txsStopNOEW  =  do
     envc <- get
     let cState = IOC.state envc
     case cState of
       IOC.Stepping { }
         -> do put envc { IOC.state = IOC.Initing { IOC.smts    = IOC.smts    cState
                                                  , IOC.tdefs   = IOC.tdefs   cState
                                                  , IOC.sigs    = IOC.sigs    cState
                                                  , IOC.putmsgs = IOC.putmsgs cState
                        }                         }
               IOC.putMsgs [ EnvData.TXS_CORE_USER_INFO "Stepping stopped" ]
       _ -> do                         -- IOC.Idling, IOC.Initing IOC.Testing, IOC.Simuling --
               IOC.putMsgs [ EnvData.TXS_CORE_USER_ERROR "txsStopNW only in Stepping mode" ]


-- | stop testing, simulating.
-- returns txscore to the initialized state, when External World running.
-- See 'txsSetTest', 'txsSetSim', respectively.
txsStopEW :: (IOC.EWorld ew)
          => ew                                         -- ^ external world.
          -> IOC.IOC ew                                 -- ^ modified external world.
txsStopEW eWorld  =  do
     envc <- get
     let cState = IOC.state envc
     case cState of
       IOC.Testing { }
         -> do put envc { IOC.state = IOC.Initing { IOC.smts    = IOC.smts    cState
                                                  , IOC.tdefs   = IOC.tdefs   cState
                                                  , IOC.sigs    = IOC.sigs    cState
                                                  , IOC.putmsgs = IOC.putmsgs cState
                        }                         }
               eWorld' <- IOC.stopW eWorld
               IOC.putMsgs [ EnvData.TXS_CORE_USER_INFO "Testing stopped" ]
               return eWorld'
       IOC.Simuling { }
         -> do put envc { IOC.state = IOC.Initing { IOC.smts    = IOC.smts    cState
                                                  , IOC.tdefs   = IOC.tdefs   cState
                                                  , IOC.sigs    = IOC.sigs    cState
                                                  , IOC.putmsgs = IOC.putmsgs cState
                        }                         }
               eWorld' <- IOC.stopW eWorld
               IOC.putMsgs [ EnvData.TXS_CORE_USER_INFO "Simulation stopped" ]
               return eWorld'
       _ -> do                         -- IOC.Idling, IOC.Initing IOC.Testing, IOC.Simuling --
               IOC.putMsgs [ EnvData.TXS_CORE_USER_ERROR
                             "txsStopEW only in Testing or Simuling mode" ]
               return eWorld

-}


-}

-- ----------------------------------------------------------------------------------------- --

{-





-- | Simulate model with the provided number of actions.
-- core action.
--
-- Only possible in simulation modus (see 'txsSetSim').
txsSimN :: Int                      -- ^ number of actions to simulate model.
        -> IOC.IOC TxsDDefs.Verdict -- ^ Verdict of simulation with number of actions.
txsSimN depth  =  do
     envc <- get
     case IOC.state envc of
       IOC.Simuling {} -> Sim.simN depth 1
       _ -> do
         IOC.putMsgs [ EnvData.TXS_CORE_USER_ERROR "Not in Simulator mode" ]
         return TxsDDefs.NoVerdict

-}

-- ----------------------------------------------------------------------------------------- --





-- ----------------------------------------------------------------------------------------- --
--                                                                                           --
-- ----------------------------------------------------------------------------------------- --

