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
import Blockchain.Stream.VMEvent
import Blockchain.Quarry

ethereumVM::LoggingT IO ()
ethereumVM = do
  offsetIORef <- liftIO $ newIORef flags_startingBlock

  runContextM $ do
    addFirstBlockToBSum
    forever $ do
      logInfoN "Getting Blocks"
      vmEvents <- getUnprocessedKafkaBlocks offsetIORef

      let blocks = [b | ChainBlock b <- vmEvents]

      logInfoN "creating transactionMap"
      let tm = M.fromList $ (map (\t -> (transactionHash t, fromJust $ whoSignedThisTransaction t)) . blockReceiptTransactions) =<< blocks
      putWSTT $ fromMaybe (error "missing value in transaction map") . flip M.lookup tm . transactionHash
      logInfoN "done creating transactionMap"

      forM_ blocks $ \b -> do
        putBSum (blockHash b) (blockToBSum b)
            
      addBlocks False blocks


      when (not $ null [1::Integer | NewUnminedBlockAvailable <- vmEvents]) $ do
        pool <- getSQLDB
        maybeBlock <- SQL.runSqlPool makeNewBlock pool

        case maybeBlock of
         Just block -> do
           let tm' = M.fromList $ (map (\t -> (transactionHash t, fromJust $ whoSignedThisTransaction t)) . blockReceiptTransactions) =<< [block]
           putWSTT $ fromMaybe (error "missing value in transaction map") . flip M.lookup tm' . transactionHash
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

getUnprocessedKafkaBlocks::(MonadIO m, MonadLogger m)=>
                           IORef Integer->m [VMEvent]
getUnprocessedKafkaBlocks offsetIORef = do
  offset <- liftIO $ readIORef offsetIORef
  logInfoN $ T.pack $ "Fetching recently mined blocks with offset " ++ (show offset)
  ret <-
      liftIO $ runKafkaConfigured "ethereum-vm" $ do
        stateRequiredAcks .= -1
        stateWaitSize .= 1
        stateWaitTime .= 100000
        --offset <- getLastOffset LatestTime 0 "thetopic"
        vmEvents <- fetchVMEvents $ Offset $ fromIntegral offset
        liftIO $ writeIORef offsetIORef $ offset + fromIntegral (length vmEvents)
   
        return vmEvents

  case ret of
    Left e -> error $ show e
    Right v -> do 
      logInfoN . T.pack $ "Got: " ++ (show . length $ v) ++ " unprocessed blocks"
      return v
