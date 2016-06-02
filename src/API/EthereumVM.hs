{-# LANGUAGE OverloadedStrings, TemplateHaskell, FlexibleContexts #-}

module API.EthereumVM (
   evmAPIMain,
   EthereumVMStatus(..),
   statusAPI,
   StatusAPI
  ) where

import API.Route.Status
import API.Handler.Status
import API.Model.Status

import Servant
import Network.Wai
import Network.Wai.Handler.Warp

app :: Application
app = serve statusAPI statusGet
 
statusAPI :: Proxy StatusAPI
statusAPI = Proxy

evmAPIMain :: IO ()
evmAPIMain = run 8081 app

