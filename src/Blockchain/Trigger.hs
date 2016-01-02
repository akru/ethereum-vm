{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}
module Blockchain.Trigger (waitForNewBlock, setupTrigger) where

import Blockchain.Data.DataDefs
import Blockchain.Database.MerklePatricia
import Control.Monad
import Control.Monad.Logger
import qualified Data.ByteString.Char8 as BC
import Data.Int
import Database.Esqueleto hiding (Connection)
import Database.Persist.Postgresql (withPostgresqlConn, runSqlConn)
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.Notification

-- Exported

waitForNewBlock :: Connection -> IO ()
waitForNewBlock conn = do
  listenTrigger conn
  Notification _ notifChannel notifData <- getNotification conn
  return ()
                                           
setupTrigger :: Connection -> IO ()
setupTrigger conn = withTransaction conn $ sequence_ $ map ($ conn) [
  clearTrigger, createTriggerFunction, createTrigger
  ]

-- Internal

clearTrigger :: Connection -> IO Int64
clearTrigger conn = execute conn "drop trigger if exists newBlock on Block" ()

createTriggerFunction :: Connection -> IO Int64
createTriggerFunction conn =
  execute conn
  ("create or replace function newBlock() returns trigger language plpgsql as $$\
   \begin\n\
   \ perform pg_notify('new_block', NULL);\n\
   \ return null;\n\
   \end\n\
   \$$")
  ()

createTrigger :: Connection -> IO Int64
createTrigger conn =
  execute conn "create trigger newBlock after insert on Block for each row execute procedure newBlock()" ()

listenTrigger :: Connection -> IO Int64
listenTrigger conn = execute conn "listen new_block" ()

-- Global constant names

--triggerName = "newBestNotify" :: String
--bestBlockDB = "extra" :: String
--bestBlockKey = "bestBlockNumber" :: String
--bestBlockKeyCol = "the_key" :: String
--bestBlockNotify = "bestBlockNotify" :: String
