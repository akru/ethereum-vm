{-# LANGUAGE TemplateHaskell #-}

module Blockchain.Options where

import HFlags

defineFlag "debug" False "turn debug info on or off"
defineFlag "altGenBlock" False "use the alternate stablenet genesis block"
defineFlag "useTestnet" False "connect to testnet"
defineFlag "wrapTransactions" False "build dummy blocks using new transactions"
defineFlag "createTransactionResults" False "stores transaction results in the SQL DB"
defineFlag "sqlDiff" False "runs sqlDiff and updates account state and storage in SQL DB"
