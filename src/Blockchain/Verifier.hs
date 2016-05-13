{-# LANGUAGE OverloadedStrings, FlexibleContexts #-}

module Blockchain.Verifier (
  checkValidity,
  isNonceValid
  ) where

import Control.Monad
import Control.Monad.Trans.State
import Control.Monad.Trans.Resource

import Blockchain.Constants
import Blockchain.Data.AddressStateDB
import Blockchain.Data.BlockSummary
import Blockchain.Data.BlockDB
import Blockchain.Data.RLP
import Blockchain.Data.Transaction
import qualified Blockchain.Database.MerklePatricia.Internal as MP
import Blockchain.DB.MemAddressStateDB
import Blockchain.DB.StateDB
import Blockchain.Mining
import Blockchain.Mining.Normal
import Blockchain.Mining.Instant
import Blockchain.Mining.SHA
import Blockchain.SHA
import Blockchain.Util
import Blockchain.VMContext
import Blockchain.VMOptions

import Blockchain.Database.MerklePatriciaMem
import Blockchain.Database.KeyVal

import Data.NibbleString
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

checkParentChildValidity::(Monad m)=>Bool->Block->BlockSummary->m ()
checkParentChildValidity isHomestead Block{blockBlockData=c} parentBSum = do
    let nextDifficulty' = if isHomestead then homesteadNextDifficulty else nextDifficulty
    unless (blockDataDifficulty c == nextDifficulty' flags_testnet (bSumNumber parentBSum) (bSumDifficulty parentBSum) (bSumTimestamp parentBSum) (blockDataTimestamp c))
             $ fail $ "Block difficulty is wrong: got '" ++ show (blockDataDifficulty c) ++
                   "', expected '" ++
                   show (nextDifficulty' flags_testnet (bSumNumber parentBSum) (bSumDifficulty parentBSum) (bSumTimestamp parentBSum) (blockDataTimestamp c)) ++ "'"
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

verifier::Miner
verifier = (if (flags_miner == Normal) then normalMiner else if(flags_miner == Instant) then instantMiner else shaMiner)

addAllKVs::RLPSerializable obj=>MonadResource m=>MP.MPDB->[(Integer, obj)]->m MP.MPDB
addAllKVs x [] = return x
addAllKVs mpdb (x:rest) = do
  mpdb' <- MP.unsafePutKeyVal mpdb (byteString2NibbleString $ rlpSerialize $ rlpEncode $ fst x) (rlpEncode $ rlpSerialize $ rlpEncode $ snd x)
  addAllKVs mpdb' rest

blank :: MPMem
blank = initializeBlankMem

runKeyValMPMap :: (Monad m) => KeyValMPMap m a -> m (a,MPMem)
runKeyValMPMap action = runStateT action blank

fixit :: RLPSerializable obj => [(Integer, obj)] -> [(NibbleString,RLPObject)]
fixit = map (\(x,y) -> ( byteString2NibbleString . rlpSerialize . rlpEncode $ x,
                         rlpEncode . rlpSerialize . rlpEncode $ y ))

verifyTransactionRoot' :: (Monad m)=>Block->m (Bool, MP.StateRoot)
verifyTransactionRoot' b = do
    let zippedTXList = zip [0..] (blockReceiptTransactions b) :: [(Integer,Transaction)]
        fixedTXList = fixit zippedTXList

    vals <- runKeyValMPMap $
               mapM putKV $ fixedTXList

    let sr = mpStateRoot . last . fst $ vals 

    return (blockDataTransactionsRoot (blockBlockData b) == sr, sr)

verifyTransactionRoot::(MonadResource m, HasStateDB m)=>Block->m (Bool,MP.StateRoot)
verifyTransactionRoot b = do
  mpdb <- getStateDB
  MP.MPDB{MP.stateRoot=sr} <- addAllKVs mpdb{MP.stateRoot=MP.emptyTriePtr} $ zip [0..] $ blockReceiptTransactions b
  return (blockDataTransactionsRoot (blockBlockData b) == sr, sr)

verifyOmmersRoot::(MonadResource m, HasStateDB m)=>Block->m Bool
verifyOmmersRoot b = return $ blockDataUnclesHash (blockBlockData b) == hash (rlpSerialize $ RLPArray $ map rlpEncode $ blockBlockUncles b)

checkValidity::Monad m=>Bool->Bool->BlockSummary->Block->ContextM (m ())
checkValidity partialBlock isHomestead parentBSum b = do
  when (flags_transactionRootVerification) $ do
           trVerified <- verifyTransactionRoot b
           trVerifiedMem <- verifyTransactionRoot' b

              
 
           when (not (fst trVerified)) $ error "transactionRoot doesn't match transactions"
           when (not (fst trVerifiedMem)) $ error "memTransactionRoot doesn't match transactions"

  ommersVerified <- verifyOmmersRoot b
  when (not ommersVerified) $ error "ommersRoot doesn't match uncles"
  checkParentChildValidity isHomestead b parentBSum
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
