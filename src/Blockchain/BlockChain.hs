{-# LANGUAGE OverloadedStrings, FlexibleContexts #-}

module Blockchain.BlockChain (
  addBlock,
  addBlocks,
  addTransaction,
  addTransactions,
  runCodeForTransaction
  ) where

import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Logger
import Control.Monad.Trans
import Control.Monad.Trans.Either
import qualified Data.ByteString as B
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Char8 as BC
import Data.List
import qualified Data.Map as M
import Data.Maybe
import qualified Data.Set as S
import qualified Data.Text as T
import Data.Time.Clock.POSIX
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))
import Text.Printf

import qualified Blockchain.Colors as CL
import Blockchain.Constants
import Blockchain.Data.Address
import Blockchain.Data.AddressStateDB
import Blockchain.Data.BlockDB
import Blockchain.Data.BlockSummary
import Blockchain.Data.Code
import Blockchain.Data.DataDefs
import Blockchain.Data.DiffDB
import Blockchain.Data.Extra
import Blockchain.Data.Log
import Blockchain.Data.LogDB
import Blockchain.Data.Transaction
import Blockchain.Data.TransactionResult
import qualified Blockchain.Database.MerklePatricia as MP
import qualified Blockchain.DB.AddressStateDB as NoCache
import Blockchain.DB.BlockSummaryDB
import Blockchain.DB.MemAddressStateDB
import Blockchain.DB.ModifyStateDB
import Blockchain.DB.StateDB
import Blockchain.DB.StorageDB
import Blockchain.ExtWord
import Blockchain.Format
import Blockchain.Stream.UnminedBlock
import Blockchain.VMContext
import Blockchain.VMOptions
import Blockchain.Verifier
import Blockchain.VM
import Blockchain.VM.Code
import Blockchain.VM.OpcodePrices
import Blockchain.VM.VMState

--import Debug.Trace

timeit::MonadIO m=>String->m a->m a
timeit message f = do
  before <- liftIO $ getPOSIXTime 
  ret <- f
  after <- liftIO $ getPOSIXTime 
  liftIO $ putStrLn $ "#### " ++ message ++ " time = " ++ printf "%.4f" (realToFrac $ after - before::Double) ++ "s"
  return ret

addBlocks::Bool->[Block]->ContextM ()
addBlocks _ [] = return ()
addBlocks isUnmined blocks = do
  _ <- forM (filter ((/= 0) . blockDataNumber . blockBlockData) blocks) $ \block ->
    timeit "Block insertion" $ addBlock isUnmined block

  liftIO $ putStrLn "done inserting, now will replace best if best is among the list"

  when (not isUnmined) $ 
    replaceBestIfBetter $ last blocks --last is OK, because we filter out blocks=[] in the case


setTitle::String->IO()
setTitle value = do
  putStr $ "\ESC]0;" ++ value ++ "\007"


addBlock::Bool->Block->ContextM ()
addBlock isUnmined b@Block{blockBlockData=bd, blockBlockUncles=uncles} = do
--  when (blockDataNumber bd > 100000) $ error "you have hit 100,000"
--  liftIO $ putStrLn $ "in addBlock with parentHash: " ++ (format . blockDataParentHash $ bd)

  bSum <- getBSum $ blockDataParentHash bd
  liftIO $ setTitle $ "Block #" ++ show (blockDataNumber bd)
  logInfoN $ T.pack $ "Inserting block #" ++ show (blockDataNumber bd) ++ " (" ++ format (blockHash b) ++ ")."
  setStateDBStateRoot $ bSumStateRoot bSum

  s1 <- addToBalance (blockDataCoinbase bd) $ rewardBase flags_testnet
  when (not s1) $ error "addToBalance failed even after a check in addBlock"

  forM_ uncles $ \uncle -> do
    s2 <- addToBalance (blockDataCoinbase bd) (rewardBase flags_testnet `quot` 32)
    when (not s2) $ error "addToBalance failed even after a check in addBlock"
        
    s3 <- addToBalance
          (blockDataCoinbase uncle)
          ((rewardBase flags_testnet * (8+blockDataNumber uncle - blockDataNumber bd )) `quot` 8)
    when (not s3) $ error "addToBalance failed even after a check in addBlock"

  let transactions = blockReceiptTransactions b

  addTransactions isUnmined b (blockDataGasLimit $ blockBlockData b) transactions

      --when flags_debug $ liftIO $ putStrLn $ "Removing accounts in suicideList: " ++ intercalate ", " (show . pretty <$> S.toList fullSuicideList)
      --forM_ (S.toList fullSuicideList) deleteAddressState

  flushMemStorageDB
  flushMemAddressStateDB

  db <- getStateDB

  b' <-
    if isUnmined
    then do
      logInfoN "Note: block is partial, instead of doing a stateRoot check, I will fill in the stateroot"
      let newBlockData = (blockBlockData b){blockDataStateRoot=MP.stateRoot db}
          newBlock = b{blockBlockData = newBlockData}
      produceUnminedBlocks [newBlock]
      logInfoN "stateRoot has been filled in"
      return newBlock
    else do
      when ((blockDataStateRoot (blockBlockData b) /= MP.stateRoot db)) $ do
        logInfoN $ T.pack $ "newStateRoot: " ++ format (MP.stateRoot db)
        error $ "stateRoot mismatch!!  New stateRoot doesn't match block stateRoot: " ++ format (blockDataStateRoot $ blockBlockData b)
      return b

  valid <- checkValidity isUnmined (blockIsHomestead b) bSum b'
  case valid of
    Right () -> return ()
    Left err -> error err

  logInfoN $ T.pack $ "Inserted block became #" ++ show (blockDataNumber $ blockBlockData b') ++ " (" ++ format (blockHash b') ++ ")."

addTransactions::Bool->Block->Integer->[Transaction]->ContextM ()
addTransactions _ _ _ [] = return ()
addTransactions isUnmined b blockGas (t:rest) = do
  result <-
    printTransactionMessage isUnmined t b $
      runEitherT $ addTransaction False b blockGas t

  (_, remainingBlockGas) <-
    case result of
      Left e -> do
          logInfoN $ T.pack $ CL.red "Insertion of transaction failed!  " ++ e
          return (S.empty, blockGas)
      Right (resultState, g') -> return (suicideList resultState, g')

  addTransactions isUnmined b remainingBlockGas rest

blockIsHomestead::Block->Bool
blockIsHomestead b = blockDataNumber (blockBlockData b) >= gHomesteadFirstBlock

addTransaction::Bool->Block->Integer->Transaction->EitherT String ContextM (VMState, Integer)
addTransaction isRunningTests' b remainingBlockGas t = do
  --let tAddr = fromJust $ whoSignedThisTransaction t
  tAddr <- lift $ getTransactionAddress t

  nonceValid <- lift $ isNonceValid t

  let isHomestead = blockIsHomestead b
      intrinsicGas' = intrinsicGas isHomestead t

  when flags_debug $
    lift $ do
      logInfoN $ T.pack $ "bytes cost: " ++ show (gTXDATAZERO * (fromIntegral $ zeroBytesLength t) + gTXDATANONZERO * (fromIntegral (codeOrDataLength t) - (fromIntegral $ zeroBytesLength t)))
      logInfoN $ T.pack $ "transaction cost: " ++ show gTX
      logInfoN $ T.pack $ "intrinsicGas: " ++ show (intrinsicGas')

  addressState <- lift $ getAddressState tAddr

  when (transactionGasLimit t * transactionGasPrice t + transactionValue t > addressStateBalance addressState) $ left "sender doesn't have high enough balance"
  when (intrinsicGas' > transactionGasLimit t) $ left "intrinsic gas higher than transaction gas limit"
  when (transactionGasLimit t > remainingBlockGas) $ left "block gas has run out"
  when (not nonceValid) $ left $ "nonce incorrect, got " ++ show (transactionNonce t) ++ ", expected " ++ show (addressStateNonce addressState)

  let availableGas = transactionGasLimit t - intrinsicGas'    

  theAddress <-
    if isContractCreationTX t
    then lift $ getNewAddress tAddr
    else do
      lift $ incrementNonce tAddr
      return $ transactionTo t
  
  success <- lift $ addToBalance tAddr (-transactionGasLimit t * transactionGasPrice t)

  when flags_debug $ lift $ logInfoN "running code"

  if success
      then do
        (result, newVMState') <- lift $ runCodeForTransaction isRunningTests' isHomestead b (transactionGasLimit t - intrinsicGas') tAddr theAddress t

        s1 <- lift $ addToBalance (blockDataCoinbase $ blockBlockData b) (transactionGasLimit t * transactionGasPrice t)
        when (not s1) $ error "addToBalance failed even after a check in addBlock"
        
        case result of
          Left e -> do
            when flags_debug $ lift $ logInfoN $ T.pack $ CL.red $ show e
            return (newVMState'{vmException = Just e}, remainingBlockGas - transactionGasLimit t)
          Right _ -> do
            let realRefund =
                  min (refund newVMState') ((transactionGasLimit t - vmGasRemaining newVMState') `div` 2)

            success' <- lift $ pay "VM refund fees" (blockDataCoinbase $ blockBlockData b) tAddr ((realRefund + vmGasRemaining newVMState') * transactionGasPrice t)

            when (not success') $ error "oops, refund was too much"

            when flags_debug $ lift $ logInfoN $ T.pack $ "Removing accounts in suicideList: " ++ intercalate ", " (show . pretty <$> S.toList (suicideList newVMState'))
            forM_ (S.toList $ suicideList newVMState') $ \address' -> do
              lift $ purgeStorageMap address'
              lift $ deleteAddressState address'
                         
        
            return (newVMState', remainingBlockGas - (transactionGasLimit t - realRefund - vmGasRemaining newVMState'))
      else do
        s1 <- lift $ addToBalance (blockDataCoinbase $ blockBlockData b) (intrinsicGas' * transactionGasPrice t)
        when (not s1) $ error "addToBalance failed even after a check in addTransaction"
        addressState' <- lift $ getAddressState tAddr
        lift $ logInfoN $ T.pack $ "Insufficient funds to run the VM: need " ++ show (availableGas*transactionGasPrice t) ++ ", have " ++ show (addressStateBalance addressState')
        return
          (
            VMState{
               vmException=Just InsufficientFunds,
               vmGasRemaining=0,
               refund=0,
               suicideList=S.empty,
               logs=[],
               returnVal=Nothing,
               dbs=error "dbs not set",
               pc=error "pc not set",
               memory=error "memory not set",
               stack=error "stack not set",
               callDepth=error "callDepth not set",
               done=error "done not set",
               theTrace=error "theTrace not set",
               environment=error "environment not set",
               isRunningTests=isRunningTests',
               vmIsHomestead=error "isHomestead is not set",
               debugCallCreates=Nothing
               },
            remainingBlockGas
          )

runCodeForTransaction::Bool->Bool->Block->Integer->Address->Address->Transaction->ContextM (Either VMException B.ByteString, VMState)
runCodeForTransaction isRunningTests' isHomestead b availableGas tAddr newAddress ut | isContractCreationTX ut = do
  when flags_debug $ logInfoN "runCodeForTransaction: ContractCreationTX"

  (result, vmState) <-
    create isRunningTests' isHomestead S.empty b 0 tAddr tAddr (transactionValue ut) (transactionGasPrice ut) availableGas newAddress (transactionInit ut)

  return (const B.empty <$> result, vmState)

runCodeForTransaction isRunningTests' isHomestead b availableGas tAddr owner ut = do --MessageTX
  when flags_debug $ logInfoN $ T.pack $ "runCodeForTransaction: MessageTX caller: " ++ show (pretty $ tAddr) ++ ", address: " ++ show (pretty $ transactionTo ut)

  call isRunningTests' isHomestead False S.empty b 0 owner owner tAddr
          (fromIntegral $ transactionValue ut) (fromIntegral $ transactionGasPrice ut)
          (transactionData ut) (fromIntegral availableGas) tAddr

----------------


codeOrDataLength::Transaction->Int
codeOrDataLength t | isMessageTX t = B.length $ transactionData t
codeOrDataLength t = codeLength $ transactionInit t --is ContractCreationTX

zeroBytesLength::Transaction->Int
zeroBytesLength t | isMessageTX t = length $ filter (==0) $ B.unpack $ transactionData t
zeroBytesLength t = length $ filter (==0) $ B.unpack codeBytes' --is ContractCreationTX
                  where
                    Code codeBytes' = transactionInit t

intrinsicGas::Bool->Transaction->Integer
intrinsicGas isHomestead t = gTXDATAZERO * zeroLen + gTXDATANONZERO * (fromIntegral (codeOrDataLength t) - zeroLen) + (txCost t)
    where
      zeroLen = fromIntegral $ zeroBytesLength t
      txCost t' | isMessageTX t' = gTX
      txCost _ = if isHomestead then gCREATETX else gTX


printTransactionMessage::Bool->Transaction->Block->ContextM (Either String (VMState, Integer))->ContextM (Either String (VMState, Integer))
printTransactionMessage isUnmined t b f = do
  tAddr <- getTransactionAddress t
  --let tAddr = fromJust $ whoSignedThisTransaction t

  nonce <- fmap addressStateNonce $ getAddressState tAddr
  logInfoN $ T.pack $ CL.magenta "    =========================================================================="
  logInfoN $ T.pack $ CL.magenta "    | Adding transaction signed by: " ++ show (pretty tAddr) ++ CL.magenta " |"
  logInfoN $ T.pack $ CL.magenta "    |    " ++
    (
      if isMessageTX t
      then "MessageTX to " ++ show (pretty $ transactionTo t) ++ "              "
      else "Create Contract "  ++ show (pretty $ getNewAddress_unsafe tAddr nonce)
    ) ++ CL.magenta " |"


  --stateRootBefore <- fmap MP.stateRoot getStateDB

  beforeMap <- getAddressStateDBMap

  before <- liftIO $ getPOSIXTime 

  result <- f

  after <- liftIO $ getPOSIXTime 

  afterMap <- getAddressStateDBMap
 
  --stateRootAfter <- fmap MP.stateRoot getStateDB
      
  unless isUnmined $
    when flags_createTransactionResults $ do
      let beforeAddresses = S.fromList [ x | (x, ASModification _) <-  M.toList beforeMap ]
          beforeDeletes = S.fromList [ x | (x, ASDeleted) <-  M.toList beforeMap ]
          afterAddresses = S.fromList [ x | (x, ASModification _) <-  M.toList afterMap ]
          afterDeletes = S.fromList [ x | (x, ASDeleted) <-  M.toList afterMap ]
          modified = S.toList $ (afterAddresses S.\\ afterDeletes) S.\\ (beforeAddresses S.\\ beforeDeletes)

      newAddresses <- filterM (fmap not . NoCache.addressStateExists) modified

      --mpdb <- getStateDB
      --addrDiff <- addrDbDiff mpdb stateRootBefore stateRootAfter

      let (resultString, response, theTrace', theLogs) =
            case result of 
              Left err -> (err, "", [], []) --TODO keep the trace when the run fails
              Right (state', _) -> ("Success!", BC.unpack $ B16.encode $ fromMaybe "" $ returnVal state', unlines $ reverse $ theTrace state', logs state')

      forM_ theLogs $ \log' -> do
        putLogDB $ LogDB (transactionHash t) tAddr (topics log' `indexMaybe` 0) (topics log' `indexMaybe` 1) (topics log' `indexMaybe` 2) (topics log' `indexMaybe` 3) (logData log') (bloom log')
                                   
      _ <- putTransactionResult $
             TransactionResult {
               transactionResultBlockHash=blockHash b,
               transactionResultTransactionHash=transactionHash t,
               transactionResultMessage=resultString,
               transactionResultResponse=response,
               transactionResultTrace=theTrace',
               transactionResultGasUsed=0,
               transactionResultEtherUsed=0,
               transactionResultContractsCreated=intercalate "," $ map formatAddress newAddresses,
               transactionResultContractsDeleted=intercalate "," $ map formatAddress $ S.toList $ (beforeAddresses S.\\ afterAddresses) `S.union` (afterDeletes S.\\ beforeDeletes),
               transactionResultStateDiff="", --BC.unpack $ BL.toStrict $ Aeson.encode addrDiff,
               transactionResultTime=realToFrac $ after - before::Double,
               transactionResultNewStorage="",
               transactionResultDeletedStorage=""
               } 
      return ()

  --clearDebugMsg

  logInfoN $ T.pack $ CL.magenta "    |" ++ " t = " ++ printf "%.2f" (realToFrac $ after - before::Double) ++ "s                                                              " ++ CL.magenta "|"
  logInfoN $ T.pack $ CL.magenta "    =========================================================================="

  return result


indexMaybe::[a]->Int->Maybe a
indexMaybe _ i | i < 0 = error "indexMaybe called for i < 0"
indexMaybe [] _ = Nothing
indexMaybe (x:_) 0 = Just x
indexMaybe (_:rest) i = indexMaybe rest (i-1)



formatAddress::Address->String
formatAddress (Address x) = BC.unpack $ B16.encode $ B.pack $ word160ToBytes x

----------------

replaceBestIfBetter::Block->ContextM ()
replaceBestIfBetter b = do
  (_, oldBestBlock) <- getBestBlockInfo

  let newNumber = blockDataNumber $ blockBlockData b
      newStateRoot = blockDataStateRoot $ blockBlockData b

  logInfoN $ T.pack $ "newNumber = " ++ show newNumber ++ ", oldBestNumber = " ++ show (blockDataNumber oldBestBlock)

  when (newNumber > blockDataNumber oldBestBlock) $ do

    when flags_sqlDiff $ do
      sqlDiff newNumber (blockDataStateRoot oldBestBlock) newStateRoot
      putBestBlockInfo (blockHash b) (blockBlockData b)
