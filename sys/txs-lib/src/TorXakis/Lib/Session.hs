{-
TorXakis - Model Based Testing
Copyright (c) 2015-2017 TNO and Radboud University
See LICENSE at root directory of this repository.
-}

-- |
{-# LANGUAGE DeriveAnyClass  #-}
{-# LANGUAGE DeriveGeneric   #-}
{-# LANGUAGE TemplateHaskell #-}
module TorXakis.Lib.Session where

import           Control.Concurrent            (ThreadId)
import           Control.Concurrent.MVar       (MVar)
import           Control.Concurrent.STM.TChan  (TChan)
import           Control.Concurrent.STM.TQueue (TQueue)
import           Control.Concurrent.STM.TVar   (TVar)
import           Control.DeepSeq               (NFData)
import           Control.Exception             (SomeException)
import qualified Data.Char                     as Char
import qualified Data.Map                      as Map
import           GHC.Generics                  (Generic)
import           Lens.Micro.TH                 (makeLenses)

import           ChanId                        (ChanId)
import           ConstDefs                     (Const)
import           EnvCore                       (EnvC, initEnvC)
import           EnvData                       (Msg)
import           ParamCore                     (Params)
import           Sigs                          (Sigs, empty)
import           TxsDDefs                      (Action, Verdict)
import           TxsDefs                       (TxsDefs, empty)
import           VarId                         (VarId)

newtype ToWorldMapping = ToWorldMapping
    { -- Send some data to the external world, getting some action as a response
      _sendToW   :: [Const] -> IO (Maybe Action)
    }
    deriving (Generic, NFData)
makeLenses ''ToWorldMapping

-- | TODO: put in the right place:
data WorldConnDef = WorldConnDef
    { _toWorldMappings :: Map.Map ChanId ToWorldMapping
    , _initWorld       :: TChan Action -> IO [ThreadId]
    -- , _closeWorld      :: [ThreadId] -> IO ()
    }
makeLenses ''WorldConnDef

-- TODO: '_tdefs' '_sigs', and '_wConnDef' should be placed in a data structure
-- having a name like 'SessionEnv', since they won't change once a 'TorXakis'
-- file is compiled.
newtype SessionSt = SessionSt
    { _envCore :: EnvC
    } deriving (Generic, NFData)

makeLenses ''SessionSt

-- | The session, which maintains the state of a TorXakis model.
data Session = Session
    { _sessionState   :: TVar SessionSt
    , _sessionMsgs    :: TQueue Msg
    , _pendingIOC     :: MVar () -- ^ Signal that a pending IOC operation is taking place.
    , _verdicts       :: TQueue (Either SomeException Verdict)
    , _fromWorldChan  :: TChan Action
    , _wConnDef       :: WorldConnDef
    , _worldListeners :: [ThreadId]
    }

makeLenses ''Session

-- * Session state manipulation
emptySessionState :: SessionSt
emptySessionState = SessionSt initEnvC
