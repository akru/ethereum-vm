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
import Control.Monad.Trans
import Control.Monad.Trans.Either
import qualified Data.ByteString as B
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Char8 as BC
import Data.List
import Data.Maybe
import qualified Data.Set as S
import Data.Time.Clock.POSIX
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))
import Text.Printf

import Control.Monad.Trans.Resource
import qualified Database.Persist.Postgresql as SQL
import qualified Database.Esqueleto as E
import Blockchain.DB.SQLDB

import qualified Blockchain.Colors as CL
import Blockchain.VMContext
import Blockchain.Data.Address
import Blockchain.Data.AddressStateDB
import Blockchain.Data.BlockDB
import Blockchain.Data.Code
import Blockchain.Data.DataDefs
import Blockchain.Data.DiffDB
import Blockchain.Data.Extra
import Blockchain.Data.Log
import Blockchain.Data.LogDB
import Blockchain.Data.UnprocessedDB
import Blockchain.Data.Transaction
import Blockchain.Data.TransactionResult
import qualified Blockchain.Database.MerklePatricia as MP
import Blockchain.DB.ModifyStateDB
import Blockchain.DB.StateDB
import Blockchain.Constants
import Blockchain.ExtWord
import Blockchain.Format
import Blockchain.SHA
import Blockchain.VMOptions
import Blockchain.Verifier
import Blockchain.VM
import Blockchain.VM.Code
import Blockchain.VM.OpcodePrices
import Blockchain.VM.VMState

import Debug.Trace

third4::(a,b,c,d)->c
third4 (_, _, x, _) = x

addBlocks::[(E.Key Block, E.Key BlockDataRef, SHA, Block, Block)]->ContextM ()
addBlocks [] = return ()
addBlocks blocks = do
  ret <-
    forM blocks $ \(bId, bdId, hash', block, parent) -> do
      before <- liftIO $ getPOSIXTime 
      (bId', bdId', hash', block') <- addBlock bId bdId hash' parent block
      after <- liftIO $ getPOSIXTime 

      liftIO $ putStrLn $ "#### Block insertion time = " ++ printf "%.4f" (realToFrac $ after - before::Double) ++ "s"
      return (bId', bdId', hash', block')

  let fullBlocks = filter ((/= SHA 1) . third4) ret

  -- before we ran only on (last $ lastBlock) but since we can't rely on the ordering, we seemed to have missed
  -- potential best blocks that were in the middle of the list 
  mapM_ (\(lastBId, lastBDId, _, lastBlock) -> replaceBestIfBetter (lastBId,lastBDId) lastBlock) fullBlocks

  let fst4 (x, _, _, _) = x

  _ <- deleteUnprocessed $ map fst4 ret

  return ()


setTitle::String->IO()
setTitle value = do
  putStr $ "\ESC]0;" ++ value ++ "\007"


addBlock::E.Key Block->E.Key BlockDataRef->SHA->Block->Block->ContextM (E.Key Block, E.Key BlockDataRef, SHA, Block)
addBlock bId bdId hash' parent b@Block{blockBlockData=bd, blockBlockUncles=uncles} = do
  liftIO $ setTitle $ "Block #" ++ show (blockDataNumber bd)
  liftIO $ putStrLn $ "Inserting block #" ++ show (blockDataNumber bd) ++ " (" ++ format (blockHash b) ++ ")."

  setStateDBStateRoot $ blockDataStateRoot $ blockBlockData parent
  s1 <- addToBalance (blockDataCoinbase bd) $ rewardBase flags_useTestnet
  when (not s1) $ error "addToBalance failed even after a check in addBlock"

  forM_ uncles $ \uncle -> do
    s2 <- addToBalance (blockDataCoinbase bd) (rewardBase flags_useTestnet `quot` 32)
    when (not s2) $ error "addToBalance failed even after a check in addBlock"
        
    s3 <- addToBalance
          (blockDataCoinbase uncle)
          ((rewardBase flags_useTestnet * (8+blockDataNumber uncle - blockDataNumber bd )) `quot` 8)
    when (not s3) $ error "addToBalance failed even after a check in addBlock"

  let transactions = blockReceiptTransactions b

  addTransactions b (blockDataGasLimit $ blockBlockData b) transactions

      --when flags_debug $ liftIO $ putStrLn $ "Removing accounts in suicideList: " ++ intercalate ", " (show . pretty <$> S.toList fullSuicideList)
      --forM_ (S.toList fullSuicideList) deleteAddressState

  db <- getStateDB

  (b', bId', bdID') <-
    if hash' == SHA 1
    then do
      liftIO $ putStrLn "Note: block is partial, instead of doing a stateRoot check, I will fill in the stateroot"
      let newBlockData = (blockBlockData b){blockDataStateRoot=MP.stateRoot db}
          newBlock = b{blockBlockData = newBlockData}
      --[(newBId, newBDId)] <- putBlocks [newBlock] True
      --deleteBlock bId bdId
      updateBlockDataStateRoot bId bdId newBlockData
      liftIO $ putStrLn "stateRoot has been filled in"
      
      --return (newBlock, newBId, newBDId)
      return (newBlock, bId, bdId)
    else do
      when ((blockDataStateRoot (blockBlockData b) /= MP.stateRoot db)) $ do
        liftIO $ putStrLn $ "newStateRoot: " ++ format (MP.stateRoot db)
        error $ "stateRoot mismatch!!  New stateRoot doesn't match block stateRoot: " ++ format (blockDataStateRoot $ blockBlockData b)
      return (b, bId, bdId)

  valid <- checkValidity (hash' == SHA 1) parent b'
  case valid of
    Right () -> return ()
    Left err -> error err

  liftIO $ putStrLn $ "Inserted block became #" ++ show (blockDataNumber $ blockBlockData b') ++ " (" ++ format (blockHash b') ++ ")."

  return (bId', bdID', hash', b')

updateBlockDataStateRoot::HasSQLDB m=>E.Key Block->E.Key BlockDataRef->BlockData->m ()
updateBlockDataStateRoot bid bdid newbd = do
  pool <- getSQLDB
  runResourceT $ flip SQL.runSqlPool pool $ do
    E.update $ \bd -> do
      E.where_ (bd E.^. BlockDataRefId E.==. E.val bdid)
      E.set bd [ BlockDataRefStateRoot E.=. E.val (blockDataStateRoot newbd) ]
      return ()
    E.update $ \b -> do
      E.where_ (b E.^. BlockId E.==. E.val bid)
      E.set b [ BlockBlockData E.=. E.val newbd ]
      return ()

addTransactions::Block->Integer->[Transaction]->ContextM ()
addTransactions _ _ [] = return ()
addTransactions b blockGas (t:rest) = do

  result <-
    printTransactionMessage t b $
      runEitherT $ addTransaction b blockGas t

  (_, remainingBlockGas) <-
    case result of
      Left e -> do
          liftIO $ putStrLn $ CL.red "Insertion of transaction failed!  " ++ e
          return (S.empty, blockGas)
      Right (resultState, g') -> return (suicideList resultState, g')

  addTransactions b remainingBlockGas rest

addTransaction::Block->Integer->Transaction->EitherT String ContextM (VMState, Integer)
addTransaction b remainingBlockGas t = do
  tAddr <- lift $ getTransactionAddress t

  nonceValid <- lift $ isNonceValid t

  let intrinsicGas' = intrinsicGas t
  when flags_debug $
    liftIO $ do
      putStrLn $ "bytes cost: " ++ show (gTXDATAZERO * (fromIntegral $ zeroBytesLength t) + gTXDATANONZERO * (fromIntegral (codeOrDataLength t) - (fromIntegral $ zeroBytesLength t)))
      putStrLn $ "transaction cost: " ++ show gTX
      putStrLn $ "intrinsicGas: " ++ show (intrinsicGas')

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

  when flags_debug $ liftIO $ putStrLn "running code"

  if success
      then do
        (result, newVMState') <- lift $ runCodeForTransaction b (transactionGasLimit t - intrinsicGas') tAddr theAddress t

        s1 <- lift $ addToBalance (blockDataCoinbase $ blockBlockData b) (transactionGasLimit t * transactionGasPrice t)
        when (not s1) $ error "addToBalance failed even after a check in addBlock"
        
        case result of
          Left e -> do
            when flags_debug $ liftIO $ putStrLn $ CL.red $ show e
            return (newVMState'{vmException = Just e}, remainingBlockGas - transactionGasLimit t)
          Right _ -> do
            let realRefund =
                  min (refund newVMState') ((transactionGasLimit t - vmGasRemaining newVMState') `div` 2)

            success' <- lift $ pay "VM refund fees" (blockDataCoinbase $ blockBlockData b) tAddr ((realRefund + vmGasRemaining newVMState') * transactionGasPrice t)

            when (not success') $ error "oops, refund was too much"

            when flags_debug $ liftIO $ putStrLn $ "Removing accounts in suicideList: " ++ intercalate ", " (show . pretty <$> S.toList (suicideList newVMState'))
            forM_ (S.toList $ suicideList newVMState') (lift . deleteAddressState)
                         
        
            return (newVMState', remainingBlockGas - (transactionGasLimit t - realRefund - vmGasRemaining newVMState'))
      else do
        s1 <- lift $ addToBalance (blockDataCoinbase $ blockBlockData b) (intrinsicGas' * transactionGasPrice t)
        when (not s1) $ error "addToBalance failed even after a check in addTransaction"
        addressState' <- lift $ getAddressState tAddr
        liftIO $ putStrLn $ "Insufficient funds to run the VM: need " ++ show (availableGas*transactionGasPrice t) ++ ", have " ++ show (addressStateBalance addressState')
        return
          (
            VMState{
               vmException=Just InsufficientFunds,
               vmGasRemaining=0,
               refund=0,
               debugCallCreates=Nothing,
               suicideList=S.empty,
               logs=[],
               returnVal=Nothing,
               dbs=undefined,
               pc=undefined,
               memory=undefined,
               stack=undefined,
               callDepth=undefined,
               done=undefined,
               theTrace=undefined,
               environment=undefined
               },
            remainingBlockGas
          )

runCodeForTransaction::Block->Integer->Address->Address->Transaction->ContextM (Either VMException B.ByteString, VMState)
runCodeForTransaction b availableGas tAddr newAddress ut | isContractCreationTX ut = do
  when flags_debug $ liftIO $ putStrLn "runCodeForTransaction: ContractCreationTX"

  (result, vmState) <-
    create S.empty b 0 tAddr tAddr (transactionValue ut) (transactionGasPrice ut) availableGas newAddress (transactionInit ut)

  return (const B.empty <$> result, vmState)

runCodeForTransaction b availableGas tAddr owner ut = do --MessageTX
  when flags_debug $ liftIO $ putStrLn $ "runCodeForTransaction: MessageTX caller: " ++ show (pretty $ tAddr) ++ ", address: " ++ show (pretty $ transactionTo ut)

  call S.empty b 0 owner owner tAddr
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

intrinsicGas::Transaction->Integer
intrinsicGas t = gTXDATAZERO * zeroLen + gTXDATANONZERO * (fromIntegral (codeOrDataLength t) - zeroLen) + gTX
    where
      zeroLen = fromIntegral $ zeroBytesLength t
--intrinsicGas t@ContractCreationTX{} = 5 * (fromIntegral (codeOrDataLength t)) + 500


printTransactionMessage::Transaction->Block->ContextM (Either String (VMState, Integer))->ContextM (Either String (VMState, Integer))
printTransactionMessage t b f = do
  tAddr <- getTransactionAddress t

  nonce <- fmap addressStateNonce $ getAddressState tAddr
  liftIO $ putStrLn $ CL.magenta "    =========================================================================="
  liftIO $ putStrLn $ CL.magenta "    | Adding transaction signed by: " ++ show (pretty tAddr) ++ CL.magenta " |"
  liftIO $ putStrLn $ CL.magenta "    |    " ++
    (
      if isMessageTX t
      then "MessageTX to " ++ show (pretty $ transactionTo t) ++ "              "
      else "Create Contract "  ++ show (pretty $ getNewAddress_unsafe tAddr nonce)
    ) ++ CL.magenta " |"


  stateRootBefore <- fmap MP.stateRoot getStateDB

  before <- liftIO $ getPOSIXTime 

  result <- f

  after <- liftIO $ getPOSIXTime 

  stateRootAfter <- fmap MP.stateRoot getStateDB

  when flags_createTransactionResults $ do
    mpdb <- getStateDB
    addrDiff <- addrDbDiff mpdb stateRootBefore stateRootAfter

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
             transactionResultContractsCreated=intercalate "," $ map formatAddress [x|CreateAddr x _ <- addrDiff],
             transactionResultContractsDeleted=intercalate "," $ map formatAddress [x|DeleteAddr x <- addrDiff],
             transactionResultStateDiff=show addrDiff,
             transactionResultTime=realToFrac $ after - before::Double,
             transactionResultNewStorage="",
             transactionResultDeletedStorage=""
             } 
    return ()

  --clearDebugMsg

  liftIO $ putStrLn $ CL.magenta "    |" ++ " t = " ++ printf "%.2f" (realToFrac $ after - before::Double) ++ "s                                                              " ++ CL.magenta "|"
  liftIO $ putStrLn $ CL.magenta "    =========================================================================="

  return result


indexMaybe::[a]->Int->Maybe a
indexMaybe _ i | i < 0 = error "indexMaybe called for i < 0"
indexMaybe [] _ = Nothing
indexMaybe (x:_) 0 = Just x
indexMaybe (_:rest) i = indexMaybe rest (i-1)



formatAddress::Address->String
formatAddress (Address x) = BC.unpack $ B16.encode $ B.pack $ word160ToBytes x

----------------

replaceBestIfBetter::(BlockId,BlockDataRefId)->Block->ContextM ()
replaceBestIfBetter (bId, blkDataId) b = do
  (oldStateRoot, bestNumber) <- getBestProcessedStateRoot

  let newNumber = blockDataNumber $ blockBlockData b

  liftIO $ putStrLn $ "newNumber = " ++ show newNumber ++ ", bestNumber = " ++ show bestNumber

  when (newNumber > bestNumber) $ do

    when flags_sqlDiff $ do
      let newStateRoot = blockDataStateRoot (blockBlockData b)
      sqlDiff blkDataId newNumber oldStateRoot newStateRoot
      
      putBestBlockId bId newNumber
