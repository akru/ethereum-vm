{-# LANGUAGE OverloadedStrings, TemplateHaskell, FlexibleContexts #-}

module API.EthereumVM (
   evmAPIMain
  ) where

import API.Route.Status
import API.Handler.Status

import Servant
import Network.Wai
import Network.Wai.Handler.Warp

app :: Application
app = serve statusAPI statusGet
 
statusAPI :: Proxy StatusAPI
statusAPI = Proxy

evmAPIMain :: IO ()
evmAPIMain = run 8081 app
