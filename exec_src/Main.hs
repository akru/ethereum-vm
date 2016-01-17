{-# LANGUAGE OverloadedStrings, TemplateHaskell, FlexibleContexts #-}

import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.State
import Control.Monad.Trans.Resource
import Data.Time.Clock
import qualified Data.ByteString as B
import qualified Data.Map as M
import qualified Database.LevelDB as DB
import qualified Database.Persist.Postgresql as SQL
import Database.PostgreSQL.Simple
import qualified Database.Esqueleto as E
import HFlags
import System.Directory
import System.FilePath
import System.IO

import Blockchain.BlockChain
import Blockchain.Constants
import Blockchain.Data.Address
import Blockchain.Data.BlockDB
import Blockchain.Data.DataDefs
import Blockchain.DB.DetailsDB
import Blockchain.Data.Transaction
import qualified Blockchain.Database.MerklePatricia as MP
import Blockchain.DB.SQLDB
import Blockchain.DBM
import Blockchain.VMOptions
import Blockchain.Trigger
import Blockchain.SHA
import Blockchain.Verifier
import Blockchain.VMContext
import qualified Network.Haskoin.Internals as H

coinbasePrvKey::H.PrvKey
Just coinbasePrvKey = H.makePrvKey 0xac3e8ce2ef31c3f45d5da860bcd9aee4b37a05c5a3ddee40dd061620c3dab380

getNextBlock::Block->[Transaction]->IO Block
getNextBlock b transactions = do
  ts <- getCurrentTime
  let bd = blockBlockData b
  return Block{
               blockBlockData=
               BlockData {
                 blockDataParentHash=blockHash b,
                 blockDataUnclesHash=hash$ B.pack [0xc0],
                 blockDataCoinbase=prvKey2Address coinbasePrvKey,
                 blockDataStateRoot = MP.SHAPtr "",
                 blockDataTransactionsRoot = MP.emptyTriePtr,
                 blockDataReceiptsRoot = MP.emptyTriePtr,
                 blockDataLogBloom = B.pack [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],         
                 blockDataDifficulty = nextDifficulty flags_useTestnet (blockDataNumber bd) (blockDataDifficulty bd) (blockDataTimestamp bd) ts,
                 blockDataNumber = blockDataNumber bd + 1,
                 blockDataGasLimit = blockDataGasLimit bd,
                 blockDataGasUsed = 0,
                 blockDataTimestamp = ts,  
                 blockDataExtraData = 0,
                 blockDataMixHash = SHA 0,
                 blockDataNonce = 5
               },
               blockReceiptTransactions=transactions,
               blockBlockUncles=[]
             }

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
      
      flip runStateT (Context
                           MP.MPDB{MP.ldb=sdb, MP.stateRoot=error "undefined stateroor"}
                           hdb
                           cdb
                           (sqlDB' dbs)
                           Nothing
                           M.empty) $ 
          forever $ do
            liftIO $ putStrLn "Getting Blocks"
            blocks <- getUnprocessedBlocks
            liftIO $ putStrLn "Getting Transaction Senders"
            transactionMap' <- fmap M.fromList $ getTransactionsForBlocks $ map fst5 blocks
            putTransactionMap transactionMap'
            liftIO $ putStrLn "Adding Blocks"
            addBlocks blocks

            when (length blocks < 100) $ liftIO $ waitForNewBlock conn

  return ()

fst5::(a, b, c, d, e)->a
fst5 (x, _, _, _, _) = x

getUnprocessedBlocks::ContextM [(E.Key Block, E.Key BlockDataRef, SHA, Block, Block)]
getUnprocessedBlocks = do
  db <- getSQLDB
  blocks <-
    runResourceT $
    flip SQL.runSqlPool db $ 
    E.select $
    E.from $ \(unprocessed `E.InnerJoin` block `E.InnerJoin` bd `E.InnerJoin` parentBD `E.InnerJoin` parent) -> do
      E.on (parentBD E.^. BlockDataRefBlockId E.==. parent E.^. BlockId) 
      E.on (bd E.^. BlockDataRefParentHash E.==. parentBD E.^. BlockDataRefHash) 
      E.on (bd E.^. BlockDataRefBlockId E.==. block E.^. BlockId)
      E.on (E.just (block E.^. BlockId) E.==. unprocessed E.?. UnprocessedBlockId)
      E.orderBy [E.asc (bd E.^. BlockDataRefNumber)]
      E.limit (fromIntegral flags_queryBlocks)
      return (block E.^. BlockId, bd E.^. BlockDataRefId, bd E.^. BlockDataRefHash, block, parent)
      
  return $ map f blocks

  where
    f::(E.Value (E.Key Block), E.Value (E.Key BlockDataRef), E.Value SHA, E.Entity Block, E.Entity Block)->(E.Key Block, E.Key BlockDataRef, SHA, Block, Block)
    f (bId, bdId, hash, b, p) = (E.unValue bId, E.unValue bdId, E.unValue hash, E.entityVal b, E.entityVal p)

getTransactionsForBlocks::[E.Key Block]->ContextM [(SHA, Address)]
getTransactionsForBlocks blockHashes = do
  db <- getSQLDB
  blocks <-
    runResourceT $
    flip SQL.runSqlPool db $ 
    E.select $
    E.from $ \t -> do
      E.where_ ((t E.^. RawTransactionBlockId) `E.in_` E.valList blockHashes)
      return (t E.^. RawTransactionTxHash, t E.^. RawTransactionFromAddress)
      
  return $ map f blocks

  where
    f::(E.Value SHA, E.Value Address)->(SHA, Address)
    f (h, a) = (E.unValue h, E.unValue a)

