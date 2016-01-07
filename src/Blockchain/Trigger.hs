{-# LANGUAGE OverloadedStrings #-}

module Blockchain.Trigger where

import Data.Int
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.Notification

waitForNewBlock::Connection->IO ()
waitForNewBlock conn = do
  _ <- getNotification conn
  return ()
                  
setupTrigger::Connection->IO Int64
setupTrigger conn = do
    withTransaction conn $ execute conn
                        "drop trigger if exists newBlock on Block;\n\
                        \create or replace function newBlock() returns trigger language plpgsql as $$\
                        \begin\n\
                        \ perform pg_notify('new_block', NULL);\n\
                        \ return null;\n\
                        \end\n\
                        \$$;\n\
                        \create trigger newBlock after insert on Block for each row execute procedure newBlock();\n\
                        \listen new_block;\n" ()

                            
