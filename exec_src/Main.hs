{-# LANGUAGE OverloadedStrings, TemplateHaskell, FlexibleContexts #-}

import Control.Lens hiding (Context)
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.State
import Control.Monad.Trans.Resource
import Data.IORef
import Data.Maybe
import qualified Data.Map as M
import qualified Database.LevelDB as DB
import Database.PostgreSQL.Simple
import HFlags

import Network.Kafka
import Network.Kafka.Consumer
import Network.Kafka.Protocol
                    
import System.Directory
import System.FilePath
import System.IO

import Blockchain.BlockSummaryCacheDB
import Blockchain.BlockChain
import Blockchain.Constants
import Blockchain.Data.BlockDB
import Blockchain.Data.RLP
import Blockchain.Data.Transaction
import qualified Blockchain.Database.MerklePatricia as MP
import Blockchain.DBM
import Blockchain.VMOptions
import Blockchain.Trigger
import Blockchain.VMContext

main::IO ()
main = do
  hSetBuffering stdout NoBuffering
  hSetBuffering stderr NoBuffering

  _ <- $initHFlags "The Ethereum Haskell Peer"

  homeDir <- getHomeDirectory
  createDirectoryIfMissing False $ homeDir </> dbDir "h"

  _ <-
    runResourceT $ do
      dbs <- openDBs
      sdb <- DB.open (homeDir </> dbDir "h" ++ stateDBPath)
             DB.defaultOptions{DB.createIfMissing=True, DB.cacheSize=1024}
      hdb <- DB.open (homeDir </> dbDir "h" ++ hashDBPath)
             DB.defaultOptions{DB.createIfMissing=True, DB.cacheSize=1024}
      cdb <- DB.open (homeDir </> dbDir "h" ++ codeDBPath)
             DB.defaultOptions{DB.createIfMissing=True, DB.cacheSize=1024}

      conn <- liftIO $ connectPostgreSQL "host=localhost dbname=eth user=postgres password=api port=5432"
      _ <- liftIO $ setupTrigger conn

      offsetIORef <- liftIO $ newIORef flags_startingBlock
           
      withBlockSummaryCacheDB (homeDir </> dbDir "h" ++ blockSummaryCacheDBPath) $ 
           flip runStateT (Context
                           MP.MPDB{MP.ldb=sdb, MP.stateRoot=error "undefined stateroor"}
                           hdb
                           cdb
                           (sqlDB' dbs)
                           Nothing
                           M.empty
                           M.empty
                           M.empty) $ 
           forever $ do
             liftIO $ putStrLn "Getting Blocks"
             blocks <- liftIO $ getUnprocessedKafkaBlocks offsetIORef

             liftIO $ putStrLn "creating transactionMap"
             let tm = M.fromList $ (map (\t -> (transactionHash t, fromJust $ whoSignedThisTransaction t)) . blockReceiptTransactions) =<< blocks
             putTransactionMap tm
             liftIO $ putStrLn "done creating transactionMap"

             forM_ blocks $ \b -> do
               putBSum (blockHash b) (blockToBSum b)
                       
             addBlocks $ map (\b -> (Nothing, Nothing, blockHash b, b, Nothing)) blocks

  return ()

getUnprocessedKafkaBlocks::IORef Integer->IO [Block]
getUnprocessedKafkaBlocks offsetIORef = do
  ret <-
      runKafka (mkKafkaState "qqqqkafkaclientidqqqq" ("127.0.0.1", 9092)) $ do
                              stateRequiredAcks .= -1
                              stateWaitSize .= 1
                              stateWaitTime .= 100000
                              --offset <- getLastOffset LatestTime 0 "thetopic"
                              offset <- liftIO $ readIORef offsetIORef
                              result <- fetch (Offset $ fromIntegral offset) 0 "thetopic"

                                        
                              let qq = concat $ map (map (_kafkaByteString . fromJust . _valueBytes . fifth5 . _messageFields .  _setMessage)) $ map _messageSetMembers $ map fourth4 $ head $ map snd $ _fetchResponseFields result

                              liftIO $ writeIORef offsetIORef (offset + fromIntegral (length qq))
                                       
                              return $ fmap (rlpDecode . rlpDeserialize) qq

  case ret of
    Left e -> error $ show e
    Right v -> return v

fourth4::(a, b, c, d)->d
fourth4 (_, _, _, x) = x

fifth5::(a, b, c, d, e)->e
fifth5 (_, _, _, _, x) = x
                                                             
                                
