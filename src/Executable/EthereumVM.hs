{-# LANGUAGE OverloadedStrings, TemplateHaskell, FlexibleContexts #-}

module Executable.EthereumVM (
  ethereumVM
  ) where

import Control.Lens hiding (Context)
import Control.Monad
import Control.Monad.Logger
import Control.Monad.IO.Class
import Data.IORef
import Data.Maybe
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Database.Persist.Postgresql as SQL

import Network.Kafka
import Network.Kafka.Protocol
                    
import Blockchain.BlockChain
import Blockchain.Data.BlockDB
import Blockchain.Data.BlockSummary
import Blockchain.Data.Transaction
import Blockchain.DB.BlockSummaryDB
import Blockchain.DB.SQLDB
import Blockchain.EthConf
import Blockchain.VMOptions
import Blockchain.VMContext
import Blockchain.Sequencer.Event
import Blockchain.Sequencer.Kafka
import Blockchain.Stream.VMEvent
import Blockchain.Quarry

import Blockchain.VM.Helpers

ethereumVM::LoggingT IO ()
ethereumVM = do
  offsetIORef <- liftIO $ newIORef flags_startingBlock

  runContextM $ do
    addFirstBlockToBSum
    forever $ do
      logInfoN "Getting Blocks/Txs"
      seqEvents <- getUnprocessedKafkaEvents offsetIORef

      let blocks = [b | OEBlock b <- seqEvents]

      logInfoN "creating transactionMap"
      logInfoN "done creating transactionMap"

      forM_ blocks $ \b -> do
        putBSum (outputBlockHash b) (outputBlockToBlockSummary b)

      addBlocks False blocks


      when (not $ null [t | OETx t <- seqEvents]) $ do -- change NewUnminedBlockAvailable -> (OETx _ _ _ _ _)
        pool <- getSQLDB
        maybeBlock <- SQL.runSqlPool makeNewBlock pool

        case maybeBlock of
         Just quarryBlock -> do
           let block = quarryBlockToOutputBlock quarryBlock
           logInfoN $ "inserting a block from the unmined block list"
           addBlocks True [block]
         Nothing -> do
           logInfoN $ "returning without inserting any unmined blocks"
           return ()

  return ()

addFirstBlockToBSum::HasBlockSummaryDB m=>m ()
addFirstBlockToBSum = do
  Just (ChainBlock first:_) <- liftIO $ fetchVMEventsIO 0
  putBSum (blockHash first) (blockToBSum first)
  return ()

getUnprocessedKafkaEvents::(MonadIO m, MonadLogger m)=>
                           IORef Integer->m [OutputEvent]
getUnprocessedKafkaEvents offsetIORef = do
  offset <- liftIO $ readIORef offsetIORef
  logInfoN $ T.pack $ "Fetching sequenced blockchain events with offset " ++ (show offset)
  ret <-
      liftIO $ runKafkaConfigured "ethereum-vm" $ do
        seqEvents <- readSeqEvents $ Offset $ fromIntegral offset
        liftIO $ writeIORef offsetIORef $ offset + fromIntegral (length seqEvents)
   
        return seqEvents

  case ret of
    Left e -> error $ show e
    Right v -> do 
      logInfoN . T.pack $ "Got: " ++ (show . length $ v) ++ " unprocessed blocks/txs"
      return v
