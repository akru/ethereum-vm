{-# LANGUAGE OverloadedStrings #-}

module Blockchain.Trigger where

import Data.Int
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.Notification
import Data.ByteString.Char8 (unpack, pack)

waitForNewBlock::Connection->IO ()
waitForNewBlock conn = do
<<<<<<< HEAD
  Notification _ notifChannel notifData <- getNotification conn
  putStr $ "Trigger on " ++ (unpack notifChannel) ++ " data is: " ++ (unpack notifData) ++ "\n"
=======
  _ <- getNotification conn
>>>>>>> b424aae906a3ae75a4f41d155b8db8c8074e5ab6
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

                            
