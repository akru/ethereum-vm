{-# LANGUAGE OverloadedStrings #-}

module Blockchain.DB.ModifyStateDB (
  addToBalance,
  pay
) where

import Control.Monad
import Control.Monad.Trans
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import Blockchain.Data.Address
import Blockchain.Data.AddressStateDB
import Blockchain.DB.HashDB
import Blockchain.DB.MemAddressStateDB
import Blockchain.DB.StateDB
import Blockchain.VMOptions

--import Debug.Trace

addToBalance::(HasMemAddressStateDB m, HasHashDB m, HasStateDB m)=>
              Address->Integer->m Bool
addToBalance address val = do
  liftIO $ putStrLn $ "getting address: " ++ (show address)
  addressState <- getAddressState address

  let newVal = addressStateBalance addressState + val

  liftIO $ putStrLn $ "setting new balance: " ++ (show newVal)
  if newVal < 0
    then return False
    else do
    putAddressState address addressState{addressStateBalance = newVal}
    return True

pay::(HasMemAddressStateDB m, HasHashDB m, HasStateDB m)=>
     String->Address->Address->Integer->m Bool
pay description fromAddr toAddr val = do
  when flags_debug $ do
    liftIO $ putStrLn $ "payment: from " ++ show (pretty fromAddr) ++ " to " ++ show (pretty toAddr) ++ ": " ++ show val ++ ", " ++ description
    fromAddressState <- getAddressState fromAddr
    liftIO $ putStrLn $ "from Funds: " ++ show (addressStateBalance fromAddressState)
    toAddressState <- getAddressState toAddr
    liftIO $ putStrLn $ "to Funds: " ++ show (addressStateBalance toAddressState)
    when (addressStateBalance fromAddressState < val) $
       liftIO $ putStrLn "insufficient funds"

  fromAddressState <- getAddressState fromAddr
  if addressStateBalance fromAddressState < val
    then return False
    else do
    _ <- addToBalance fromAddr (-val)
    _ <- addToBalance toAddr val
    return True




  










