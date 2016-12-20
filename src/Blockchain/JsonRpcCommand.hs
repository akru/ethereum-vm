{-# LANGUAGE OverloadedStrings #-}

module Blockchain.JsonRpcCommand (
  runJsonRpcCommand
  ) where

import Control.Monad.IO.Class
import Control.Monad.Logger
import Data.Binary
import qualified Data.ByteString as B
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import Network.Kafka          
import Network.Kafka.Protocol 
import Network.Kafka.Producer 

import Blockchain.Data.Address
import Blockchain.Data.AddressStateDB
import Blockchain.Data.DataDefs
import Blockchain.DB.AddressStateDB
import Blockchain.DB.DetailsDB
import Blockchain.DB.HashDB
import Blockchain.DB.SQLDB
import Blockchain.DB.StateDB
import Blockchain.EthConf
import Blockchain.KafkaTopics
import Blockchain.Sequencer.Event

produceResponse::String->B.ByteString->IO ()
produceResponse id theData = do
    ret <-
      liftIO $ runKafkaConfigured "ethereum-vm" $
      produceMessages $
      [TopicAndMessage (lookupTopic "jsonrpcresponse") . makeMessage . BL.toStrict $ encode (id, theData)]
    case ret of
        Left e      -> error $ "Could not write txs to Kafka: " ++ show e
        Right resps -> return ()


runJsonRpcCommand::(MonadLogger m, HasStateDB m, HasHashDB m, HasSQLDB m)=>
                   JsonRpcCommand->m ()
runJsonRpcCommand c@JRCGetBalance{jrcAddress=addressBytes, jrcBlockString=blockString, jrcId=id} = do
  liftIO $ putStrLn $ "running command: " ++ show c
  bestBlock <- getBestBlock
  setStateDBStateRoot $ blockDataStateRoot $ blockBlockData bestBlock
  case decodeOrFail $ BL.fromStrict addressBytes of
   Left (_, _, e) -> logErrorN $ T.pack $
                           "Bad Command sent from JsonRpc: " ++ show e
   Right ("", _, address) -> do
     addressState <- getAddressState address
     let response = show $ addressStateBalance addressState
     liftIO $ produceResponse id $ BC.pack response
     liftIO $ putStrLn response
