{-# LANGUAGE OverloadedStrings, TemplateHaskell, FlexibleContexts #-}

import Control.Lens hiding (Context)
import Control.Monad
import Control.Monad.IO.Class
import Data.IORef
import Data.Maybe
import qualified Data.Map as M
import HFlags

import Network.Kafka
import Network.Kafka.Protocol
                    
import System.IO

import Blockchain.BlockSummaryCacheDB
import Blockchain.BlockChain
import Blockchain.Data.BlockDB
import Blockchain.Data.Transaction
import Blockchain.VMOptions
import Blockchain.VMContext

main::IO ()
main = do
  hSetBuffering stdout NoBuffering
  hSetBuffering stderr NoBuffering

  _ <- $initHFlags "The Ethereum Haskell Peer"

  offsetIORef <- liftIO $ newIORef flags_startingBlock

  runContextM $ forever $ do
    liftIO $ putStrLn "Getting Blocks"
    blocks <- liftIO $ getUnprocessedKafkaBlocks offsetIORef

    liftIO $ putStrLn "creating transactionMap"
    let tm = M.fromList $ (map (\t -> (transactionHash t, fromJust $ whoSignedThisTransaction t)) . blockReceiptTransactions) =<< blocks
    putWSTT $ fromMaybe (error "missing value in transaction map") . flip M.lookup tm . transactionHash
    liftIO $ putStrLn "done creating transactionMap"

    forM_ blocks $ \b -> do
      putBSum (blockHash b) (blockToBSum b)
                       
    addBlocks $ map (\b -> (blockHash b, b)) blocks


  return ()

getUnprocessedKafkaBlocks::IORef Integer->IO [Block]
getUnprocessedKafkaBlocks offsetIORef = do
  ret <-
      runKafka (mkKafkaState "ethereum-vm" ("127.0.0.1", 9092)) $ do
        stateRequiredAcks .= -1
        stateWaitSize .= 1
        stateWaitTime .= 100000
        --offset <- getLastOffset LatestTime 0 "thetopic"
        offset <- liftIO $ readIORef offsetIORef
        liftIO $ putStrLn $ "Fetching recently mined blocks with offset " ++ (show offset)
        result <- fetchBlocks $ Offset $ fromIntegral offset
        liftIO $ writeIORef offsetIORef $ offset + fromIntegral (length result)
        return result

  case ret of
    Left e -> error $ show e
    Right v -> return v
