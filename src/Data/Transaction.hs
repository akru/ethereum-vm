{-# LANGUAGE OverloadedStrings #-}

module Data.Transaction (
  Transaction(..),
  codeOrDataLength
  ) where

import qualified Data.ByteString as B

import Data.Address
import VM.Code
import Colors
import Format
import Data.RLP
import Util
--import VM

--import Debug.Trace


data Transaction =
  MessageTX {
    tNonce::Integer,
    gasPrice::Integer,
    tGasLimit::Integer,
    to::Address,
    value::Integer,
    tData::B.ByteString
    } |
  ContractCreationTX {
    tNonce::Integer,
    gasPrice::Integer,
    tGasLimit::Integer,
    value::Integer,
    tInit::Code
    } deriving (Show)

instance Format Transaction where
  format MessageTX{tNonce=n, gasPrice=gp, tGasLimit=gl, to=to', value=v, tData=d} =
    blue "Message Transaction" ++
    tab (
      "\n" ++
      "tNonce: " ++ show n ++ "\n" ++
      "gasPrice: " ++ show gp ++ "\n" ++
      "tGasLimit: " ++ show gl ++ "\n" ++
      "to: " ++ format to' ++ "\n" ++
      "value: " ++ show v ++ "\n" ++
      "tData: " ++ tab ("\n" ++ format d) ++ "\n")
  format ContractCreationTX{tNonce=n, gasPrice=gp, tGasLimit=gl, value=v, tInit=init'} =
    blue "Contract Creation Transaction" ++
    tab (
      "\n" ++
      "tNonce: " ++ show n ++ "\n" ++
      "gasPrice: " ++ show gp ++ "\n" ++
      "tGasLimit: " ++ show gl ++ "\n" ++
      "value: " ++ show v ++ "\n" ++
      "tInit: " ++ tab ("\n" ++ format init') ++ "\n")

instance RLPSerializable Transaction where
  rlpDecode (RLPArray [n, gp, gl, toAddr, val, i]) | rlpDecode toAddr == (0::Integer) =
    ContractCreationTX {
      tNonce = rlpDecode n,
      gasPrice = rlpDecode gp,
      tGasLimit = rlpDecode gl,
      value = rlpDecode val,
      tInit = rlpDecode i
      }
  rlpDecode (RLPArray [n, gp, gl, toAddr, val, i]) =
    MessageTX {
      tNonce = rlpDecode n,
      gasPrice = rlpDecode gp,
      tGasLimit = rlpDecode gl,
      to = rlpDecode toAddr,
      value = rlpDecode val,
      tData = rlpDecode i
      }
  rlpDecode x = error ("rlpDecode for Transaction called on non block object: " ++ show x)

  rlpEncode MessageTX{tNonce=n, gasPrice=gp, tGasLimit=gl, to=to', value=v, tData=d} =
      RLPArray [
        rlpEncode n,
        rlpEncode gp,
        rlpEncode gl,
        rlpEncode to',
        rlpEncode v,
        rlpEncode d
        ]
  rlpEncode ContractCreationTX{tNonce=n, gasPrice=gp, tGasLimit=gl, value=v, tInit=init'} =
      RLPArray [
        rlpEncode n,
        rlpEncode gp,
        rlpEncode gl,
        rlpEncode $ Address 0,
        rlpEncode v,
        rlpEncode init'
        ]

codeOrDataLength::Transaction->Int
codeOrDataLength MessageTX{tData=d} = B.length d
codeOrDataLength ContractCreationTX{tInit=d} = codeLength d