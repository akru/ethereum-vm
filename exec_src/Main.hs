{-# LANGUAGE OverloadedStrings, TemplateHaskell, FlexibleContexts #-}

import Control.Lens hiding (Context)
import Control.Monad
import Control.Monad.IO.Class
import Data.IORef
import Data.Maybe
import qualified Data.Map as M
import qualified Database.Persist.Postgresql as SQL
import HFlags

import Network.Kafka
import Network.Kafka.Protocol
                    
import System.IO

import Blockchain.BlockSummaryCacheDB
import Blockchain.BlockChain
import Blockchain.Data.BlockDB
import Blockchain.Data.Transaction
import Blockchain.DB.SQLDB
import Blockchain.VMOptions
import Blockchain.VMContext
import Blockchain.Stream.VMEvent

import Blockchain.Quarry

main::IO ()
main = do
  hSetBuffering stdout NoBuffering
  hSetBuffering stderr NoBuffering

  _ <- $initHFlags "The Ethereum Haskell Peer"

  offsetIORef <- liftIO $ newIORef flags_startingBlock

  runContextM $ forever $ do
    liftIO $ putStrLn "Getting Blocks"
    vmEvents <- liftIO $ getUnprocessedKafkaBlocks offsetIORef

    let blocks = [b | ChainBlock b <- vmEvents]

    liftIO $ putStrLn "creating transactionMap"
    let tm = M.fromList $ (map (\t -> (transactionHash t, fromJust $ whoSignedThisTransaction t)) . blockReceiptTransactions) =<< blocks
    putWSTT $ fromMaybe (error "missing value in transaction map") . flip M.lookup tm . transactionHash
    liftIO $ putStrLn "done creating transactionMap"

    forM_ blocks $ \b -> do
      putBSum (blockHash b) (blockToBSum b)
                       
    addBlocks $ map (\b -> (blockHash b, b)) blocks

    when (not $ null [1 | NewUnminedBlockAvailable <- vmEvents]) $ do
      pool <- getSQLDB
      block <- SQL.runSqlPool makeNewBlock pool
      let tm = M.fromList $ (map (\t -> (transactionHash t, fromJust $ whoSignedThisTransaction t)) . blockReceiptTransactions) =<< [block]
      putWSTT $ fromMaybe (error "missing value in transaction map") . flip M.lookup tm . transactionHash
      addBlocks [(blockHash block, block)]


  return ()

getUnprocessedKafkaBlocks::IORef Integer->IO [VMEvent]
getUnprocessedKafkaBlocks offsetIORef = do
  ret <-
      runKafka (mkKafkaState "ethereum-vm" ("127.0.0.1", 9092)) $ do
        stateRequiredAcks .= -1
        stateWaitSize .= 1
        stateWaitTime .= 100000
        --offset <- getLastOffset LatestTime 0 "thetopic"
        offset <- liftIO $ readIORef offsetIORef
        liftIO $ putStrLn $ "Fetching recently mined blocks with offset " ++ (show offset)
        vmEvents <- fetchVMEvents $ Offset $ fromIntegral offset
        liftIO $ writeIORef offsetIORef $ offset + fromIntegral (length vmEvents)
        return vmEvents

  case ret of
    Left e -> error $ show e
    Right v -> return v
