{-# LANGUAGE OverloadedStrings, TypeSynonymInstances, FlexibleInstances #-}

module Blockchain.VMContext (
  Context(..),
  ContextM,
  runContextM,
--  getDebugMsg,
--  clearDebugMsg,
  getCachedBestProcessedBlock,
  putCachedBestProcessedBlock,      
  getTransactionAddress,
  putWSTT,
  incrementNonce,
  getNewAddress,
  purgeStorageMap
  ) where


import Control.Monad.IO.Class
import Control.Monad.Logger    (runNoLoggingT)
import Control.Monad.Trans.Resource
import Control.Monad.State
import qualified Data.ByteString.Char8 as BC
import qualified Data.Map as M
import Data.Maybe
import qualified Database.LevelDB as DB
import qualified Database.Persist.Postgresql as SQL
import System.Directory
import System.FilePath
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>), (</>))


import Blockchain.BlockSummaryCacheDB
import Blockchain.Data.Address
import Blockchain.Data.AddressStateDB
import Blockchain.Data.BlockDB
import Blockchain.Data.Transaction
import qualified Blockchain.Database.MerklePatricia as MP
import Blockchain.DB.CodeDB
import Blockchain.DB.HashDB
import Blockchain.DB.MemAddressStateDB
import Blockchain.DB.StorageDB
import Blockchain.DB.SQLDB
import Blockchain.DB.StateDB
import Blockchain.Constants
import Blockchain.EthConf
import Blockchain.ExtWord
import Blockchain.VMOptions
import Blockchain.SHA

--import Debug.Trace

data Context =
  Context {
    contextStateDB::MP.MPDB,
    contextHashDB::HashDB,
    contextCodeDB::CodeDB,
    contextSQLDB::SQLDB,
    cachedBestProcessedBlock::Maybe Block,
    contextWhoSignedThisTransaction::Transaction->Address,
    contextAddressStateDBMap::M.Map Address AddressStateModification,
    contextStorageMap::M.Map (Address, Word256) Word256
    }

type ContextM = StateT Context (BlockSummaryCacheT (ResourceT IO))

instance HasStateDB ContextM where
  getStateDB = do
    cxt <- get
    return $ contextStateDB cxt
  setStateDBStateRoot sr = do
    cxt <- get
    put cxt{contextStateDB=(contextStateDB cxt){MP.stateRoot=sr}}

instance HasMemAddressStateDB ContextM where
  getAddressStateDBMap = do
    cxt <- get
    return $ contextAddressStateDBMap cxt
  putAddressStateDBMap theMap = do
    cxt <- get
    put $ cxt{contextAddressStateDBMap=theMap}

           
instance HasStorageDB ContextM where
  getStorageDB = do
    cxt <- get
    return $ (MP.ldb $ contextStateDB cxt, --storage and states use the same database!
              contextStorageMap cxt)
  putStorageMap theMap = do
    cxt <- get
    put cxt{contextStorageMap=theMap}

instance HasHashDB ContextM where
  getHashDB = fmap contextHashDB get

instance HasCodeDB ContextM where
  getCodeDB = fmap contextCodeDB get

instance HasSQLDB ContextM where
  getSQLDB = fmap contextSQLDB get

connStr'::SQL.ConnectionString
connStr' = BC.pack $ "host=localhost dbname=eth user=postgres password=api port=" ++ show (port $ sqlConfig ethConf)

runContextM f = do
  homeDir <- getHomeDirectory
  createDirectoryIfMissing False $ homeDir </> dbDir "h"

  _ <-
    runResourceT $ do
      sdb <- DB.open (homeDir </> dbDir "h" ++ stateDBPath)
             DB.defaultOptions{DB.createIfMissing=True, DB.cacheSize=1024}
      hdb <- DB.open (homeDir </> dbDir "h" ++ hashDBPath)
             DB.defaultOptions{DB.createIfMissing=True, DB.cacheSize=1024}
      cdb <- DB.open (homeDir </> dbDir "h" ++ codeDBPath)
             DB.defaultOptions{DB.createIfMissing=True, DB.cacheSize=1024}

      conn <- runNoLoggingT  $ SQL.createPostgresqlPool connStr' 20

      withBlockSummaryCacheDB (homeDir </> dbDir "h" ++ blockSummaryCacheDBPath) $ 
        runStateT f (Context
                     MP.MPDB{MP.ldb=sdb, MP.stateRoot=error "stateroot not set"}
                     hdb
                     cdb
                     conn
                     Nothing
                     (error "contextWhoSignedThisTransaction not set")
                     M.empty
                     M.empty)

  return ()

{-
getDebugMsg::ContextM String
getDebugMsg = do
  cxt <- get
  return $ concat $ reverse $ vmTrace cxt

clearDebugMsg::ContextM ()
clearDebugMsg = do
  cxt <- get
  put cxt{vmTrace=[]}
-}

getCachedBestProcessedBlock::ContextM (Maybe Block)
getCachedBestProcessedBlock = do
  cxt <- get
  return $ cachedBestProcessedBlock cxt

putCachedBestProcessedBlock::Block->ContextM ()
putCachedBestProcessedBlock b = do
  cxt <- get
  put cxt{cachedBestProcessedBlock=Just b}

getTransactionAddress::Transaction->ContextM Address
getTransactionAddress t = do
  cxt <- get
  return $ contextWhoSignedThisTransaction cxt t

putWSTT::(Transaction->Address)->ContextM ()
putWSTT wstt = do
  cxt <- get
  put cxt{contextWhoSignedThisTransaction=wstt}

incrementNonce::(HasMemAddressStateDB m, HasStateDB m, HasHashDB m)=>
                Address->m ()
incrementNonce address = do
  addressState <- getAddressState address
  putAddressState address addressState{ addressStateNonce = addressStateNonce addressState + 1 }

getNewAddress::(HasMemAddressStateDB m, HasStateDB m, HasHashDB m)=>
               Address->m Address
getNewAddress address = do
  addressState <- getAddressState address
  when flags_debug $ liftIO $ putStrLn $ "Creating new account: owner=" ++ show (pretty address) ++ ", nonce=" ++ show (addressStateNonce addressState)
  let newAddress = getNewAddress_unsafe address (addressStateNonce addressState)
  incrementNonce address
  return newAddress

purgeStorageMap::HasStorageDB m=>Address->m ()
purgeStorageMap address = do
  (_, storageMap) <- getStorageDB
  putStorageMap $ M.filterWithKey (\key _ -> fst key /= address) storageMap










