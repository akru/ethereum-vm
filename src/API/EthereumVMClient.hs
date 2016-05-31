{-# LANGUAGE OverloadedStrings, TemplateHaskell, FlexibleContexts #-}

module API.EthereumVMClient (
   evmStatusRoute,
   EthereumVMStatus(..)
  ) where

import API.EthereumVM
import Control.Monad.Trans.Either

import Servant.Client
 
evmStatusRoute :: BaseUrl -> EitherT ServantError IO EthereumVMStatus
evmStatusRoute = client statusAPI
