{-# LANGUAGE OverloadedStrings, FlexibleContexts #-}

module Blockchain.Verifier (
  checkValidity,
  isNonceValid
  ) where

import Control.Monad

import Blockchain.BlockSummaryCacheDB
import Blockchain.Constants
import Blockchain.Data.AddressStateDB
import Blockchain.Data.BlockDB
import Blockchain.Data.RLP
import Blockchain.Data.Transaction
import Blockchain.DB.MemAddressStateDB
import Blockchain.Mining
import Blockchain.Mining.Dummy
import Blockchain.Mining.Instant
import Blockchain.Mining.SHA
import Blockchain.SHA
import Blockchain.VMContext
import Blockchain.VMOptions

--import Debug.Trace

{-
nextGasLimit::Integer->Integer->Integer
nextGasLimit oldGasLimit oldGasUsed = max (max 125000 3141592) ((oldGasLimit * 1023 + oldGasUsed *6 `quot` 5) `quot` 1024)
-}

nextGasLimitDelta::Integer->Integer
nextGasLimitDelta oldGasLimit  = oldGasLimit `div` 1024

checkUnclesHash::Block->Bool
checkUnclesHash b = blockDataUnclesHash (blockBlockData b) == hash (rlpSerialize $ RLPArray (rlpEncode <$> blockBlockUncles b))

--data BlockValidityError = BlockDifficultyWrong Integer Integer | BlockNumberWrong Integer Integer | BlockGasLimitWrong Integer Integer | BlockNonceWrong | BlockUnclesHashWrong
{-
instance Format BlockValidityError where
    --format BlockOK = "Block is valid"
    format (BlockDifficultyWrong d expected) = "Block difficulty is wrong, is '" ++ show d ++ "', expected '" ++ show expected ++ "'"
-}

checkParentChildValidity::(Monad m)=>Block->BlockSummary->m ()
checkParentChildValidity Block{blockBlockData=c} parentBSum = do
    unless (blockDataDifficulty c == nextDifficulty flags_testnet (bSumNumber parentBSum) (bSumDifficulty parentBSum) (bSumTimestamp parentBSum) (blockDataTimestamp c))
             $ fail $ "Block difficulty is wrong: got '" ++ show (blockDataDifficulty c) ++
                   "', expected '" ++
                   show (nextDifficulty flags_testnet (bSumNumber parentBSum) (bSumDifficulty parentBSum) (bSumTimestamp parentBSum) (blockDataTimestamp c)) ++ "'"
    unless (blockDataNumber c == bSumNumber parentBSum + 1) 
             $ fail $ "Block number is wrong: got '" ++ show (blockDataNumber c) ++ ", expected '" ++ show (bSumNumber parentBSum + 1) ++ "'"
    unless (blockDataGasLimit c <= bSumGasLimit parentBSum +  nextGasLimitDelta (bSumGasLimit parentBSum))
             $ fail $ "Block gasLimit is too high: got '" ++ show (blockDataGasLimit c) ++
                   "', should be less than '" ++ show (bSumGasLimit parentBSum +  nextGasLimitDelta (bSumGasLimit parentBSum)) ++ "'"
    unless (blockDataGasLimit c >= bSumGasLimit parentBSum - nextGasLimitDelta (bSumGasLimit parentBSum))
             $ fail $ "Block gasLimit is too low: got '" ++ show (blockDataGasLimit c) ++
                   "', should be less than '" ++ show (bSumGasLimit parentBSum -  nextGasLimitDelta (bSumGasLimit parentBSum)) ++ "'"
    unless (blockDataGasLimit c >= minGasLimit flags_testnet)
             $ fail $ "Block gasLimit is lower than minGasLimit: got '" ++ show (blockDataGasLimit c) ++ "', should be larger than " ++ show (minGasLimit flags_testnet::Integer)
    return ()

verifier = (if (flags_miner == Dummy) then dummyMiner else if(flags_miner == Instant) then instantMiner else shaMiner)

checkValidity::Monad m=>Bool->BlockSummary->Block->ContextM (m ())
checkValidity partialBlock parentBSum b = do
  checkParentChildValidity b parentBSum
  when (flags_miningVerification && not partialBlock) $ do
    let miningVerified = (verify verifier) b
    unless miningVerified $ fail "block falsely mined, verification failed"
  --nIsValid <- nonceIsValid' b
  --unless nIsValid $ fail $ "Block nonce is wrong: " ++ format b
  unless (checkUnclesHash b) $ fail "Block unclesHash is wrong"
  return $ return ()


{-
                    coinbase=prvKey2Address prvKey,
        stateRoot = SHA 0x9b109189563315bfeb13d4bfd841b129ff3fd5c85f228a8d9d8563b4dde8432e,
                    transactionsTrie = 0,
-}




isNonceValid::Transaction->ContextM Bool
isNonceValid t = do
  tAddr <- getTransactionAddress t
  --let tAddr = fromJust $ whoSignedThisTransaction t
  addressState <- getAddressState tAddr
  return $ addressStateNonce addressState == transactionNonce t
