{-# LANGUAGE OverloadedStrings, TypeSynonymInstances, FlexibleInstances #-}

module Blockchain.VMContext (
  Context(..),
  ContextM,
--  getDebugMsg,
--  clearDebugMsg,
  getCachedBestProcessedBlock,
  putCachedBestProcessedBlock,      
  getTransactionAddress,
  putTransactionMap,
  incrementNonce,
  getNewAddress
  ) where


import Control.Monad.IO.Class
import Control.Monad.Trans.Resource
import Control.Monad.State
import qualified Data.Map as M
import Data.Maybe
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>), (</>))

import Blockchain.BlockSummaryCacheDB
import Blockchain.Data.Address
import Blockchain.Data.AddressStateDB
import Blockchain.Data.BlockDB
import Blockchain.Data.Transaction
import qualified Blockchain.Database.MerklePatricia as MPDB
import Blockchain.DB.CodeDB
import Blockchain.DB.HashDB
import Blockchain.DB.MemAddressStateDB
import Blockchain.DB.StorageDB
import Blockchain.DB.SQLDB
import Blockchain.DB.StateDB
import Blockchain.ExtWord
import Blockchain.VMOptions
import Blockchain.SHA

--import Debug.Trace

data Context =
  Context {
    contextStateDB::MPDB.MPDB,
    contextHashDB::HashDB,
    contextCodeDB::CodeDB,
    contextSQLDB::SQLDB,
    cachedBestProcessedBlock::Maybe Block,
    transactionMap::M.Map SHA Address,
    contextAddressStateDBMap::M.Map Address AddressStateModification,
    contextStorageMap::M.Map (Address, Word512) Word512
    }

type ContextM = StateT Context (BlockSummaryCacheT (ResourceT IO))

instance HasStateDB ContextM where
  getStateDB = do
    cxt <- get
    return $ contextStateDB cxt
  setStateDBStateRoot sr = do
    cxt <- get
    put cxt{contextStateDB=(contextStateDB cxt){MPDB.stateRoot=sr}}

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
    return $ (MPDB.ldb $ contextStateDB cxt, --storage and states use the same database!
              contextStorageMap cxt)
instance HasHashDB ContextM where
  getHashDB = fmap contextHashDB get

instance HasCodeDB ContextM where
  getCodeDB = fmap contextCodeDB get

instance HasSQLDB ContextM where
  getSQLDB = fmap contextSQLDB get

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
  return $ fromMaybe (error "missing value in transaction map") $ M.lookup (transactionHash t) (transactionMap cxt)

putTransactionMap::M.Map SHA Address->ContextM ()
putTransactionMap tm = do
  cxt <- get
  put cxt{transactionMap=tm}

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











