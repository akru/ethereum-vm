{-# LANGUAGE TemplateHaskell #-}

module Blockchain.Options where

import HFlags

defineFlag "debug" False "turn debug info on or off"
defineFlag "altGenBlock" False "use the alternate stablenet genesis block"
defineFlag "wrapTransactions" False "build dummy blocks using new transactions"
