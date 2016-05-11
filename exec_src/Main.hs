{-# LANGUAGE OverloadedStrings, TemplateHaskell, FlexibleContexts #-}

import Control.Monad.Logger
import HFlags

import Blockchain.Output
import Blockchain.VMOptions
import Executable.EthereumVM

main :: IO ()
main = do
  _ <- $initHFlags "Ethereum VM"
  flip runLoggingT printLogMsg ethereumVM
