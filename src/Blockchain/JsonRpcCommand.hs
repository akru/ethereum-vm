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

import Blockchain.Data.Address
import Blockchain.Data.AddressStateDB
import Blockchain.Data.DataDefs
import Blockchain.DB.AddressStateDB
import Blockchain.DB.DetailsDB
import Blockchain.DB.HashDB
import Blockchain.DB.SQLDB
import Blockchain.DB.StateDB

runJsonRpcCommand::(MonadLogger m, HasStateDB m, HasHashDB m, HasSQLDB m)=>
                   String->B.ByteString->m ()
runJsonRpcCommand command theData = do
  liftIO $ putStrLn $ "running command: " ++ command ++ ": " ++ BC.unpack (B16.encode theData)
  bestBlock <- getBestBlock
  setStateDBStateRoot $ blockDataStateRoot $ blockBlockData bestBlock
  case decodeOrFail $ BL.fromStrict theData of
   Left (_, _, e) -> logErrorN $ T.pack $
                           "Bad Command sent from JsonRpc: " ++ show e
   Right ("", _, address) -> do
     addressState <- getAddressState address
     liftIO $ print $ addressStateBalance addressState
