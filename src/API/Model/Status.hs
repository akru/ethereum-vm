
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -fno-warn-unused-binds  #-}

module API.Model.Status ( 
    EthereumVMStatus(..),
    VMBaseStatus(..)
   ) where

import Data.Aeson.TH
import Blockchain.Data.StatusClass

data VMBaseStatus = VMBaseStatus {
    vmMessage :: String,
    vmTimestamp :: String 
} deriving (Eq, Show, Read)

data EthereumVMStatus = EthereumVMStatus (Either String VMBaseStatus) deriving (Show,Read,Eq)

$(deriveJSON defaultOptions ''VMBaseStatus)
$(deriveJSON defaultOptions ''EthereumVMStatus)

instance Status EthereumVMStatus where
    isOperational (EthereumVMStatus (Left _)) = False
    isOperational (EthereumVMStatus (Right _)) = True
    label _ = "EthereumVM"
    message (EthereumVMStatus (Left msg)) = msg
    message (EthereumVMStatus (Right (VMBaseStatus msg _))) = msg 
