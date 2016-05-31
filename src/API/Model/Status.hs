
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}

module API.Model.Status where

import Data.Aeson.TH

data EthereumVMStatus = EthereumVMStatus {
    message :: String,
    timestamp :: String   -- replace with UTCTime
} deriving (Eq, Show)

$(deriveJSON defaultOptions ''EthereumVMStatus)
