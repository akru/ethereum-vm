{-# LANGUAGE OverloadedStrings, TemplateHaskell, FlexibleContexts, FlexibleInstances, TypeSynonymInstances #-}

module Executable.EthereumVM (
  ethereumVM
  ) where

import Control.Monad
import Control.Monad.Logger
import Control.Monad.IO.Class
import Data.IORef
import qualified Data.Text as T

import Network.Kafka.Protocol
                    
import Blockchain.BlockChain
import Blockchain.Data.BlockSummary
import Blockchain.DB.BlockSummaryDB
import Blockchain.EthConf
import Blockchain.JsonRpcCommand
import Blockchain.VMOptions
import Blockchain.VMContext
import Blockchain.Sequencer.Event
import Blockchain.Sequencer.Kafka
import Blockchain.Stream.UnminedBlock (produceUnminedBlocks)

import qualified Blockchain.Bagger as Bagger

ethereumVM::LoggingT IO ()
ethereumVM = do
  offsetIORef <- liftIO $ newIORef flags_startingBlock
  runContextM $ do
        Bagger.setCalculateIntrinsicGas calculateIntrinsicGas'
        firstBlock <- getFirstBlockFromSequencer
        let firstBlockSHA  = outputBlockHash firstBlock
            firstBlockHead = obBlockData firstBlock
        putBSum firstBlockSHA (blockHeaderToBSum firstBlockHead)
        Bagger.processNewBestBlock firstBlockSHA firstBlockHead -- bootstrap Bagger with genesis block
        forever $ do
            logInfoN "Getting Blocks/Txs"
            seqEvents <- getUnprocessedKafkaEvents offsetIORef

            let newCommands = [(command, theData, blockString, id) | OEJsonRpcCommand command theData blockString id <- seqEvents]
            forM_ newCommands $ \(c, d, b, i) -> runJsonRpcCommand c d b i
            
            let newTXs = [t | OETx t <- seqEvents]
            unless (null newTXs) $ logInfoN (T.pack ("adding " ++ (show $ length newTXs) ++ " txs to mempool")) >> Bagger.addTransactionsToMempool newTXs

            let blocks = [b | OEBlock b <- seqEvents]
            forM_ blocks $ \b -> putBSum (outputBlockHash b) (blockHeaderToBSum $ obBlockData b)
            addBlocks False blocks

            newBlock <- Bagger.makeNewBlock
            produceUnminedBlocks [(outputBlockToBlock newBlock)]

            return ()

getFirstBlockFromSequencer :: (MonadLogger m, HasBlockSummaryDB m) => m OutputBlock
getFirstBlockFromSequencer = do
    dummyIORef      <- liftIO $ newIORef (0 :: Integer)
    (OEBlock block) <- head <$> getUnprocessedKafkaEvents dummyIORef
    return block

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
