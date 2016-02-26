{-# LANGUAGE OverloadedStrings #-}

module Blockchain.VM (
  runCodeFromStart,
  call,
  create
  ) where

import Prelude hiding (LT, GT, EQ)
import qualified Prelude as Ordering (Ordering(..))

import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans
import Control.Monad.Trans.Either
import Control.Monad.Trans.State
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Char
import Data.Function
import Data.Maybe
import qualified Data.Set as S
import Data.Time.Clock.POSIX
import Numeric
import Text.Printf

import Blockchain.BlockSummaryCacheDB
import qualified Blockchain.Colors as CL
import Blockchain.Format
import Blockchain.VMContext
import Blockchain.Data.Address
import Blockchain.Data.AddressStateDB
import Blockchain.Data.BlockDB
import Blockchain.Data.Code
import Blockchain.Data.Log
import qualified Blockchain.Database.MerklePatricia as MP
import Blockchain.DB.CodeDB
import Blockchain.DB.ModifyStateDB
import Blockchain.DB.StateDB
import Blockchain.ExtWord
import Blockchain.VMOptions
import Blockchain.SHA
import Blockchain.Util
import Blockchain.VM.Code
import Blockchain.VM.Environment
import Blockchain.VM.Memory
import Blockchain.VM.Opcodes
import Blockchain.VM.OpcodePrices
import Blockchain.VM.PrecompiledContracts
import Blockchain.VM.VMM
import Blockchain.VM.VMState

--import Debug.Trace

bool2Word256::Bool->Word256
bool2Word256 True = 1
bool2Word256 False = 0

{-
word2562Bool::Word256->Bool
word2562Bool 1 = True
word2562Bool _ = False
-}

binaryAction::(Word256->Word256->Word256)->VMM ()
binaryAction action = do
  x <- pop
  y <- pop
  push $ x `action` y

unaryAction::(Word256->Word256)->VMM ()
unaryAction action = do
  x <- pop
  push $ action x

pushEnvVar::Word256Storable a=>(Environment->a)->VMM ()
pushEnvVar f = do
  VMState{environment=env} <- lift get
  push $ f env

pushVMStateVar::Word256Storable a=>(VMState->a)->VMM ()
pushVMStateVar f = do
  state' <- lift get::VMM VMState
  push $ f state'

logN::Int->VMM ()
logN n = do
  offset <- pop
  theSize <- pop
  owner <- getEnvVar envOwner
  topics' <- sequence $ replicate n pop
  
  theData <- mLoadByteString offset theSize
  addLog Log{address=owner, bloom=0, logData=theData, topics=topics'}



dupN::Int->VMM ()
dupN n = do
  stack' <- lift $ fmap stack get
  if length stack' < n
    then do
    left StackTooSmallException
    else push $ stack' !! (n-1)


s256ToInteger::Word256->Integer
--s256ToInteger i | i < 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF = toInteger i
s256ToInteger i | i < 0x8000000000000000000000000000000000000000000000000000000000000000 = toInteger i
s256ToInteger i = toInteger i - 0x10000000000000000000000000000000000000000000000000000000000000000


swapn::Int->VMM ()
swapn n = do
  v1 <- pop
  vmState <- lift get
  if length (stack vmState) < n
    then do
      left StackTooSmallException 
    else do
      let (middle, v2:rest2) = splitAt (n-1) $ stack vmState
      lift $ put vmState{stack = v2:(middle++(v1:rest2))}

getByte::Word256->Word256->Word256
getByte whichByte val | whichByte < 32 = val `shiftR` (8*(31 - fromIntegral whichByte)) .&. 0xFF
getByte _ _ = 0;

signExtend::Word256->Word256->Word256
signExtend numBytes val | numBytes > 31 = val
signExtend numBytes val = baseValue + if highBitSet then highFilter else 0
  where
    lowFilter = 2^(8*numBytes+8)-1
    highFilter = (2^(256::Integer)-1) - lowFilter
    baseValue = lowFilter .&. val
    highBitSet =  val `shiftR` (8*fromIntegral numBytes + 7) .&. 1 == 1

safe_quot::Integral a=>a->a->a
safe_quot _ 0 = 0
safe_quot x y = x `quot` y

safe_mod::Integral a=>a->a->a
safe_mod _ 0 = 0
safe_mod x y = x `mod` y

safe_rem::Integral a=>a->a->a
safe_rem _ 0 = 0
safe_rem x y = x `rem` y


--For some strange reason, some ethereum tests (the VMTests) create an account when it doesn't
--exist....  This is a hack to mimic this behavior.
accountCreationHack::Address->VMM ()
accountCreationHack address' = do
  exists <- addressStateExists address'
  when (not exists) $ do
    vmState <- lift get
    when (not $ isNothing $ debugCallCreates vmState) $
      putAddressState address' blankAddressState



getBlockHashWithNumber::Integer->SHA->VMM (Maybe SHA)
getBlockHashWithNumber num h = do
  liftIO $ putStrLn $ "getBlockHashWithNumber, calling getBSum with " ++ format h
  bSum <- lift $ getBSum h
  case num `compare` bSumNumber bSum of
   Ordering.LT -> getBlockHashWithNumber num $ bSumParentHash bSum
   Ordering.EQ -> return $ Just h
   Ordering.GT -> return Nothing

{-
  | num == bSumNumber b = return $ Just b
getBlockHashWithNumber num b | num > bSumNumber b = return Nothing
getBlockHashWithNumber num b = do
  parentBlock <- getBSum $ bSumParentHash b
  getBlockWithNumber num $
    fromMaybe (error "missing parent block in call to getBlockWithNumber") parentBlock
-}



--TODO- This really should be in its own monad!
--The monad should manage everything in the VM and environment (extending the ContextM), and have pop and push operations, perhaps even automating pc incrementing, gas charges, etc.
--The code would simplify greatly, but I don't feel motivated to make the change now since things work.

runOperation::Operation->VMM ()
runOperation STOP = do
  vmState <- lift get
  lift $ put vmState{done=True}

runOperation ADD = binaryAction (+)
runOperation MUL = binaryAction (*)
runOperation SUB = binaryAction (-)
runOperation DIV = binaryAction safe_quot
runOperation SDIV = binaryAction ((fromIntegral .) . safe_quot `on` s256ToInteger)
runOperation MOD = binaryAction safe_mod
runOperation SMOD = binaryAction ((fromIntegral .) . safe_rem `on` s256ToInteger) --EVM mod corresponds to Haskell rem....  mod and rem only differ in how they handle negative numbers

runOperation ADDMOD = do
  v1 <- pop::VMM Word256
  v2 <- pop::VMM Word256
  modVal <- pop::VMM Word256

  push $ (toInteger v1 + toInteger v2) `safe_mod` toInteger modVal

runOperation MULMOD = do
  v1 <- pop::VMM Word256
  v2 <- pop::VMM Word256
  modVal <- pop::VMM Word256

  let ret = (toInteger v1 * toInteger v2) `safe_mod` toInteger modVal
  push ret


runOperation EXP = binaryAction (^)
runOperation SIGNEXTEND = binaryAction signExtend



runOperation NEG = unaryAction negate
runOperation LT = binaryAction ((bool2Word256 .) . (<))
runOperation GT = binaryAction ((bool2Word256 .) . (>))
runOperation SLT = binaryAction ((bool2Word256 .) . ((<) `on` s256ToInteger))
runOperation SGT = binaryAction ((bool2Word256 .) . ((>) `on` s256ToInteger))
runOperation EQ = binaryAction ((bool2Word256 .) . (==))
runOperation ISZERO = unaryAction (bool2Word256 . (==0))
runOperation AND = binaryAction (.&.)
runOperation OR = binaryAction (.|.)
runOperation XOR = binaryAction xor

runOperation NOT = unaryAction (0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF `xor`)

runOperation BYTE = binaryAction getByte

runOperation SHA3 = do
  p <- pop
  size <- pop
  theData <- unsafeSliceByteString p size
  let SHA theHash = hash theData
  push $ theHash

runOperation ADDRESS = pushEnvVar envOwner

runOperation BALANCE = do
  address' <- pop
  exists <- addressStateExists address'
  if exists
    then do
    addressState <- getAddressState address'
    push $ addressStateBalance addressState
    else do
    accountCreationHack address' --needed hack to get the tests working
    push (0::Word256)
    
runOperation ORIGIN = pushEnvVar envOrigin
runOperation CALLER = pushEnvVar envSender
runOperation CALLVALUE = pushEnvVar envValue

runOperation CALLDATALOAD = do
  p <- pop
  d <- getEnvVar envInputData

  let val = bytes2Integer $ appendZerosTo32 $ B.unpack $ B.take 32 $ safeDrop p $ d
  push val
    where
      appendZerosTo32 x | length x < 32 = x ++ replicate (32-length x) 0
      appendZerosTo32 x = x
      
runOperation CALLDATASIZE = pushEnvVar (B.length . envInputData)

runOperation CALLDATACOPY = do
  memP <- pop
  codeP <- pop
  size <- pop
  d <- getEnvVar envInputData
  
  mStoreByteString memP $ safeTake size $ safeDrop codeP $ d

runOperation CODESIZE = pushEnvVar (codeLength . envCode)

runOperation CODECOPY = do
  memP <- pop
  codeP <- pop
  size <- pop
  Code c <- getEnvVar envCode
  
  mStoreByteString memP $ safeTake size $ safeDrop codeP $ c

runOperation GASPRICE = pushEnvVar envGasPrice


runOperation EXTCODESIZE = do
  address' <- pop
  accountCreationHack address' --needed hack to get the tests working
  addressState <- getAddressState address'
  code <- fromMaybe B.empty <$> getCode (addressStateCodeHash addressState)
  push $ (fromIntegral (B.length code)::Word256)

runOperation EXTCODECOPY = do
  address' <- pop
  accountCreationHack address' --needed hack to get the tests working
  memOffset <- pop
  codeOffset <- pop
  size <- pop
  
  addressState <- getAddressState address'
  code <- fromMaybe B.empty <$> getCode (addressStateCodeHash addressState)
  mStoreByteString memOffset (safeTake size $ safeDrop codeOffset $ code)

runOperation BLOCKHASH = do
  number' <- pop::VMM Word256

  currentBlock <- getEnvVar envBlock
  let currentBlockNumber = blockDataNumber . blockBlockData $ currentBlock

  let inRange = not $ toInteger number' >= currentBlockNumber || 
                toInteger number' < currentBlockNumber - 256

  vmState <- lift get

  case (inRange, isRunningTests vmState) of
   (False, _) -> push (0::Word256)
   (True, False) -> do
          maybeBlockHash <- getBlockHashWithNumber (fromIntegral number') $ blockHash currentBlock
          case maybeBlockHash of
           Nothing -> push (0::Word256)
           Just theBlockHash -> push theBlockHash
   (True, True) -> do
          let SHA h = hash $ BC.pack $ show $ toInteger number'
          push h

runOperation COINBASE = pushEnvVar (blockDataCoinbase . blockBlockData . envBlock)
runOperation TIMESTAMP = do
  VMState{environment=env} <- lift get
  push $ ((round . utcTimeToPOSIXSeconds . blockDataTimestamp . blockBlockData . envBlock) env::Word256)


  
runOperation NUMBER = pushEnvVar (blockDataNumber . blockBlockData . envBlock)
runOperation DIFFICULTY = pushEnvVar (blockDataDifficulty . blockBlockData . envBlock)
runOperation GASLIMIT = pushEnvVar (blockDataGasLimit . blockBlockData . envBlock)

runOperation POP = do
  _ <- pop::VMM Word256
  return ()

runOperation LOG0 = logN 0
runOperation LOG1 = logN 1
runOperation LOG2 = logN 2
runOperation LOG3 = logN 3
runOperation LOG4 = logN 4

runOperation MLOAD = do
  p <- pop
  bytes <- mLoad p
  push $ (fromInteger (bytes2Integer bytes)::Word256)
  
runOperation MSTORE = do
  p <- pop
  val <- pop
  mStore p val

runOperation MSTORE8 = do
  p <- pop
  val <- pop::VMM Word256
  mStore8 p (fromIntegral $ val .&. 0xFF)

runOperation SLOAD = do
  p <- pop
  val <- getStorageKeyVal p
  push val
  
runOperation SSTORE = do
  p <- pop
  val <- pop::VMM Word256

  if val == 0
    then deleteStorageKey p
    else putStorageKeyVal p val

--TODO- refactor so that I don't have to use this -1 hack
runOperation JUMP = do
  p <- pop
  jumpDests <- getEnvVar envJumpDests

  if p `elem` jumpDests
    then setPC $ fromIntegral p - 1 -- Subtracting 1 to compensate for the pc-increment that occurs every step.
    else left InvalidJump

runOperation JUMPI = do
  p <- pop
  condition <- pop
  jumpDests <- getEnvVar envJumpDests
  
  case (p `elem` jumpDests, (0::Word256) /= condition) of
    (_, False) -> return ()
    (True, _) -> setPC $ fromIntegral p - 1
    _ -> left InvalidJump
  
runOperation PC = pushVMStateVar pc

runOperation MSIZE = do
  memSize <- getSizeInBytes
  push memSize

runOperation GAS = pushVMStateVar vmGasRemaining

runOperation JUMPDEST = return ()

runOperation (PUSH vals) =
  push $ (fromIntegral (bytes2Integer vals)::Word256)

runOperation DUP1 = dupN 1
runOperation DUP2 = dupN 2
runOperation DUP3 = dupN 3
runOperation DUP4 = dupN 4
runOperation DUP5 = dupN 5
runOperation DUP6 = dupN 6
runOperation DUP7 = dupN 7
runOperation DUP8 = dupN 8
runOperation DUP9 = dupN 9
runOperation DUP10 = dupN 10
runOperation DUP11 = dupN 11
runOperation DUP12 = dupN 12
runOperation DUP13 = dupN 13
runOperation DUP14 = dupN 14
runOperation DUP15 = dupN 15
runOperation DUP16 = dupN 16

runOperation SWAP1 = swapn 1
runOperation SWAP2 = swapn 2
runOperation SWAP3 = swapn 3
runOperation SWAP4 = swapn 4
runOperation SWAP5 = swapn 5
runOperation SWAP6 = swapn 6
runOperation SWAP7 = swapn 7
runOperation SWAP8 = swapn 8
runOperation SWAP9 = swapn 9
runOperation SWAP10 = swapn 10
runOperation SWAP11 = swapn 11
runOperation SWAP12 = swapn 12
runOperation SWAP13 = swapn 13
runOperation SWAP14 = swapn 14
runOperation SWAP15 = swapn 15
runOperation SWAP16 = swapn 16

runOperation CREATE = do
  value <- pop::VMM Word256
  input <- pop
  size <- pop

  owner <- getEnvVar envOwner
  block <- getEnvVar envBlock

  initCodeBytes <- unsafeSliceByteString input size

  vmState <- lift get

  callDepth' <- getCallDepth

  result <-
    case (callDepth' > 1023, debugCallCreates vmState) of
      (True, _) -> return Nothing
      (_, Nothing) -> create_debugWrapper block owner value initCodeBytes
      (_, Just _) -> do
        addressState' <- getAddressState owner

        let newAddress = getNewAddress_unsafe owner $ addressStateNonce addressState'
        
        if addressStateBalance addressState' < fromIntegral value
          then return Nothing
          else do
          --addToBalance' owner (-fromIntegral value)
          addDebugCallCreate DebugCallCreate {
            ccData=initCodeBytes,
            ccDestination=Nothing,
            ccGasLimit=vmGasRemaining vmState,
            ccValue=fromIntegral value
            }
          return $ Just newAddress

  case result of
    Just address' -> push address'
    Nothing -> push (0::Word256)

runOperation CALL = do
  gas <- pop::VMM Word256
  to <- pop
  value <- pop::VMM Word256
  inOffset <- pop
  inSize <- pop
  outOffset <- pop
  outSize <- pop::VMM Word256

  owner <- getEnvVar envOwner

  inputData <- unsafeSliceByteString inOffset inSize
  _ <- unsafeSliceByteString outOffset outSize --needed to charge for memory

  vmState <- lift get

  let stipend = if value > 0 then fromIntegral gCALLSTIPEND  else 0

  addressState <- getAddressState owner

  callDepth' <- getCallDepth

  (result, maybeBytes) <-
    case (callDepth' > 1023, fromIntegral value > addressStateBalance addressState, debugCallCreates vmState) of
      (True, _, _) -> do
        liftIO $ putStrLn $ CL.red "Call stack too deep."
        addGas $ fromIntegral stipend
        addGas $ fromIntegral gas
        return (0, Nothing)
      (_, True, _) -> do
        liftIO $ putStrLn $ CL.red "Not enough ether to transfer the value."
        addGas $ fromIntegral $ gas + fromIntegral stipend
        return (0, Nothing)
      (_, _, Nothing) -> do
        nestedRun_debugWrapper (fromIntegral gas + stipend) to to owner value inputData 
      (_, _, Just _) -> do
        addGas $ fromIntegral stipend
        --addToBalance' owner (-fromIntegral value)
        addGas $ fromIntegral gas
        addDebugCallCreate DebugCallCreate {
          ccData=inputData,
          ccDestination=Just to,
          ccGasLimit=fromIntegral gas + stipend,
          ccValue=fromIntegral value
          }
        return (1, Nothing)

  case maybeBytes of
    Nothing -> return ()
    Just bytes -> mStoreByteString outOffset $ B.take (fromIntegral outSize) bytes
  
  push result

runOperation CALLCODE = do

  gas <- pop::VMM Word256
  to <- pop
  value <- pop::VMM Word256
  inOffset <- pop
  inSize <- pop
  outOffset <- pop
  outSize <- pop::VMM Word256

  owner <- getEnvVar envOwner

  inputData <- unsafeSliceByteString inOffset inSize
  _ <- unsafeSliceByteString outOffset outSize --needed to charge for memory

  vmState <- lift get

  let stipend = if value > 0 then fromIntegral gCALLSTIPEND  else 0

--  toAddressExists <- lift $ lift $ lift $ addressStateExists to

--  let newAccountCost = if not toAddressExists then gCALLNEWACCOUNT else 0

--  useGas $ fromIntegral newAccountCost

  addressState <- getAddressState owner

  callDepth' <- getCallDepth

  (result, maybeBytes) <-
    case (callDepth' > 1023, fromIntegral value > addressStateBalance addressState, debugCallCreates vmState) of
      (True, _, _) -> do
        addGas $ fromIntegral gas
        return (0, Nothing)
      (_, True, _) -> do
        addGas $ fromIntegral gas
        addGas $ fromIntegral stipend
        when flags_debug $ liftIO $ putStrLn $ CL.red "Insufficient balance"
        return (0, Nothing)
      (_, _, Nothing) -> do
        nestedRun_debugWrapper (fromIntegral gas+stipend) owner to owner value inputData 
      (_, _, Just _) -> do
        --addToBalance' owner (-fromIntegral value)
        addGas $ fromIntegral stipend
        addGas $ fromIntegral gas
        addDebugCallCreate DebugCallCreate {
          ccData=inputData,
          ccDestination=Just $  owner,
          ccGasLimit=fromIntegral gas + stipend,
          ccValue=fromIntegral value
          }
        return (1, Nothing)

  case maybeBytes of
    Nothing -> return ()
    Just bytes -> mStoreByteString outOffset $ B.take (fromIntegral outSize) bytes
  
  push result

runOperation RETURN = do
  address' <- pop
  size <- pop
  
  --retVal <- mLoadByteString address' size
  retVal <- unsafeSliceByteString address' size

  setDone True
  setReturnVal $ Just retVal

runOperation SUICIDE = do
  address' <- pop
  owner <- getEnvVar envOwner
  addressState <- getAddressState $ owner

  let allFunds = addressStateBalance addressState
  pay' "transferring all funds upon suicide" owner address' allFunds

  putAddressState owner addressState{addressStateBalance = 0} --yellowpaper needs address emptied, in the case that the transfer address is the same as the suicide one

  
  addSuicideList owner
  setDone True


runOperation (MalformedOpcode opcode) = do
  when flags_debug $ liftIO $ putStrLn $ CL.red ("Malformed Opcode: " ++ showHex opcode "")
  left MalformedOpcodeException

runOperation x = error $ "Missing case in runOperation: " ++ show x

-------------------

opGasPriceAndRefund::Operation->VMM (Integer, Integer)

opGasPriceAndRefund LOG0 = do
  size <- getStackItem 1::VMM Word256
  return (gLOG + gLOGDATA * fromIntegral size, 0)
opGasPriceAndRefund LOG1 = do
  size <- getStackItem 1::VMM Word256
  return (gLOG + gLOGTOPIC + gLOGDATA * fromIntegral size, 0)
opGasPriceAndRefund LOG2 = do
  size <- getStackItem 1::VMM Word256
  return (gLOG + 2*gLOGTOPIC + gLOGDATA * fromIntegral size, 0)
opGasPriceAndRefund LOG3 = do
  size <- getStackItem 1::VMM Word256
  return (gLOG + 3*gLOGTOPIC + gLOGDATA * fromIntegral size, 0)
opGasPriceAndRefund LOG4 = do
  size <- getStackItem 1::VMM Word256
  return (gLOG + 4*gLOGTOPIC + gLOGDATA * fromIntegral size, 0)

opGasPriceAndRefund SHA3 = do
  size <- getStackItem 1::VMM Word256
  return (30+6*ceiling(fromIntegral size/(32::Double)), 0)

opGasPriceAndRefund EXP = do
    e <- getStackItem 1::VMM Word256
    if e == 0
      then return (gEXPBASE, 0)
      else return (gEXPBASE + gEXPBYTE*bytesNeeded e, 0)

    where
      bytesNeeded::Word256->Integer
      bytesNeeded 0 = 0
      bytesNeeded x = 1+bytesNeeded (x `shiftR` 8)


opGasPriceAndRefund CALL = do
  gas <- getStackItem 0::VMM Word256
  to <- getStackItem 1::VMM Word256
  val <- getStackItem 2::VMM Word256

  let toAddr = Address $ fromIntegral to

  toAccountExists <- addressStateExists toAddr

  self <- getEnvVar envOwner -- if an account being created calls itself, the go client doesn't charge the gCALLNEWACCOUNT fee, so we need to check if that case is occurring here

  return $ (
    fromIntegral gas +
    fromIntegral gCALL +
    (if toAccountExists || toAddr == self then 0 else fromIntegral gCALLNEWACCOUNT) +
--                       (if toAccountExists || to < 5 then 0 else gCALLNEWACCOUNT) +
    (if val > 0 then fromIntegral gCALLVALUETRANSFER else 0),
    0)


opGasPriceAndRefund CALLCODE = do
  gas <- getStackItem 0::VMM Word256
--  to <- getStackItem 1::VMM Word256
  val <- getStackItem 2::VMM Word256

--  toAccountExists <- lift $ lift $ lift $ addressStateExists $ Address $ fromIntegral to

  return
    (
      toInteger gas +
      gCALL +
      --(if toAccountExists then 0 else gCALLNEWACCOUNT) +
      (if val > 0 then toInteger gCALLVALUETRANSFER else 0),
      0
    )


opGasPriceAndRefund CODECOPY = do
    size <- getStackItem 2::VMM Word256
    return (gCODECOPYBASE + gCOPYWORD * ceiling (fromIntegral size / (32::Double)), 0)
opGasPriceAndRefund CALLDATACOPY = do
    size <- getStackItem 2::VMM Word256
    return (gCALLDATACOPYBASE + gCOPYWORD * ceiling (fromIntegral size / (32::Double)), 0)
opGasPriceAndRefund EXTCODECOPY = do
    size <- getStackItem 3::VMM Word256
    return (gEXTCODECOPYBASE + gCOPYWORD * ceiling (fromIntegral size / (32::Double)), 0)
opGasPriceAndRefund SSTORE = do
  p <- getStackItem 0
  val <- getStackItem 1
  oldVal <- getStorageKeyVal p
  case (oldVal, val) of
      (0, x) | x /= (0::Word256) -> return (20000, 0)
      (x, 0) | x /= 0 -> return (5000, 15000)
      _ -> return (5000, 0)
opGasPriceAndRefund SUICIDE = do
    owner <- getEnvVar envOwner
    currentSuicideList <- fmap suicideList $ lift get
    if owner `S.member` currentSuicideList
       then return (0, 0)
       else return (0, 24000)

{-opGasPriceAndRefund RETURN = do
  size <- getStackItem 1

  return (gTXDATANONZERO*size, 0)-}

opGasPriceAndRefund x = return (opGasPrice x, 0)

--missing stuff
--Glog 1 Partial payment for a LOG operation.
--Glogdata 1 Paid for each byte in a LOG operation’s data.
--Glogtopic 1 Paid for each topic of a LOG operation.

formatOp::Operation->String
formatOp (PUSH x) = "PUSH" ++ show (length x) -- ++ show x
formatOp x = show x


printDebugInfo::Environment->Word256->Word256->Int->Operation->VMState->VMState->VMM ()
--printDebugInfo env memBefore memAfter c op stateBefore stateAfter = do
printDebugInfo _ _ _15 _ op stateBefore stateAfter = do

  --CPP style trace
{-  liftIO $ putStrLn $ "EVM [ eth | " ++ show (callDepth stateBefore) ++ " | " ++ formatAddressWithoutColor (envOwner env) ++ " | #" ++ show c ++ " | " ++ map toUpper (showHex4 (pc stateBefore)) ++ " : " ++ formatOp op ++ " | " ++ show (vmGasRemaining stateBefore) ++ " | " ++ show (vmGasRemaining stateAfter - vmGasRemaining stateBefore) ++ " | " ++ show(toInteger memAfter - toInteger memBefore) ++ "x32 ]"
  liftIO $ putStrLn $ "EVM [ eth ] "-}

  --GO style trace
  liftIO $ putStrLn $ "PC " ++ printf "%08d" (toInteger $ pc stateBefore) ++ ": " ++ formatOp op ++ " GAS: " ++ show (vmGasRemaining stateAfter) ++ " COST: " ++ show (vmGasRemaining stateBefore - vmGasRemaining stateAfter)

  memByteString <- liftIO $ getMemAsByteString (memory stateAfter)
  liftIO $ putStrLn "    STACK"
  liftIO $ putStr $ unlines (padZeros 64 <$> flip showHex "" <$> (reverse $ stack stateAfter))
  liftIO $ putStr $ "    MEMORY\n" ++ showMem 0 (B.unpack $ memByteString)
  liftIO $ putStrLn $ "    STORAGE"
  kvs <- getAllStorageKeyVals
  liftIO $ putStrLn $ unlines (map (\(k, v) -> "0x" ++ showHexU (byteString2Integer $ nibbleString2ByteString k) ++ ": 0x" ++ showHexU (fromIntegral v)) kvs)


runCode::Int->VMM ()
runCode c = do
  memBefore <- getSizeInWords
  code <- getEnvVar envCode

  vmState <- lift get

  let (op, len) = getOperationAt code (pc vmState)
  --liftIO $ putStrLn $ "EVM [ 19:22" ++ show op ++ " #" ++ show c ++ " (" ++ show (vmGasRemaining state) ++ ")"

  (val, theRefund) <- opGasPriceAndRefund op

  useGas val
  addToRefund theRefund

  runOperation op

  memAfter <- getSizeInWords

  result <- lift get

  env <- lift $ fmap environment get

  when flags_createTransactionResults $
    vmTrace $
      "EVM [ eth | " ++ show (callDepth vmState) ++ " | " ++ formatAddressWithoutColor (envOwner env) ++ " | #" ++ show c ++ " | " ++ map toUpper (showHex4 (pc vmState)) ++ " : " ++ formatOp op ++ " | " ++ show (vmGasRemaining vmState) ++ " | " ++ show (vmGasRemaining result - vmGasRemaining result) ++ " | " ++ show(toInteger memAfter - toInteger memBefore) ++ "x32 ]\n"

  when flags_debug $ printDebugInfo (environment result) memBefore memAfter c op vmState result 

  case result of
    VMState{done=True} -> incrementPC len
    _ -> do
      incrementPC len
      runCode (c+1)

runCodeFromStart::VMM ()
runCodeFromStart = do
  code <- getEnvVar envCode
  theData <- getEnvVar envInputData

  when flags_debug $
     liftIO $ putStrLn $ "running code: " ++ tab (CL.magenta ("\n" ++ showCode 0 code))


  case code of
   PrecompiledCode x -> do
     ret <- callPrecompiledContract (fromIntegral x) theData
     vmState <- lift get
     lift $ put vmState{returnVal=Just ret}
     return ()
   _ -> do
     runCode 0

runVMM::Bool->S.Set Address->Int->Environment->Integer->VMM a->ContextM (Either VMException a, VMState)
runVMM isRunningTests' preExistingSuicideList callDepth' env availableGas f = do
  dbs' <- get
  vmState <- liftIO $ startingState isRunningTests' env dbs'

  result <- lift $ 
      flip runStateT vmState{
                         callDepth=callDepth',
                         vmGasRemaining=availableGas, 
                         suicideList=preExistingSuicideList} $
      runEitherT f

  case result of
      (Left e, vmState) -> do
          liftIO $ putStrLn $ CL.red $ "Exception caught (" ++ show e ++ "), reverting state"
          when flags_debug $ liftIO $ putStrLn "VM has finished running"
          return (Left e, vmState{logs=[]})
      (_, stateAfter) -> do
          setStateDBStateRoot $ MP.stateRoot $ contextStateDB $ dbs $ stateAfter
          when flags_debug $ liftIO $ putStrLn "VM has finished running"
          return result

--bool Executive::create(Address _sender, u256 _endowment, u256 _gasPrice, u256 _gas, bytesConstRef _init, Address _origin)

create::Bool->S.Set Address->Block->Int->Address->Address->Integer->Integer->Integer->Address->Code->ContextM (Either VMException Code, VMState)
create isRunningTests' preExistingSuicideList b callDepth' sender origin value' gasPrice' availableGas newAddress init' = do
  let env =
        Environment{
          envGasPrice=gasPrice',
          envBlock=b,
          envOwner = newAddress,
          envOrigin = origin,
          envInputData = B.empty,
          envSender = sender,
          envValue = value',
          envCode = init',
          envJumpDests = getValidJUMPDESTs init'
          }

  dbs' <- get

  vmState <- liftIO $ startingState isRunningTests' env dbs'

  success <- 
    if toInteger value' > 0
    then do
    --it is a statistical impossibility that a new account will be created with the same address as
    --an existing one, but the ethereum tests test this.  They want the VM to preserve balance
    --but clean out storage.
    --This will never actually matter, but I add it to pass the tests.
    newAddressState <- getAddressState newAddress
    putAddressState newAddress newAddressState{addressStateContractRoot=MP.emptyTriePtr}
    --This next line will actually create the account addressState data....
    --In the extremely unlikely even that the address already exists, it will preserve
    --the existing balance.
    pay "transfer value" sender newAddress $ fromIntegral value'
    else return True

  ret <- 
    if success
      then runVMM isRunningTests' preExistingSuicideList callDepth' env availableGas create'
      else return (Left InsufficientFunds, vmState)


  case ret of
    (Left e, vmState') -> do
      --if there was an error, addressStates were reverted, so the receiveAddress still should
      --have the value, and I can revert without checking for success.
      _ <- pay "revert value transfer" newAddress sender (fromIntegral value')

      deleteAddressState newAddress
      return (Left e, vmState'{vmGasRemaining=0}) --need to zero gas in the case of an exception
    _ -> return ret



create'::VMM Code
create' = do

  runCodeFromStart

  vmState <- lift get

  owner <- getEnvVar envOwner
  
  let codeBytes' = fromMaybe B.empty $ returnVal vmState
  when flags_debug $ liftIO $ putStrLn $ "Result: " ++ show codeBytes'

  
  if vmGasRemaining vmState < gCREATEDATA * toInteger (B.length codeBytes')
    then do
      liftIO $ putStrLn $ CL.red "Not enough ether to create contract, contract being thrown away (account was created though)"
      lift $ put vmState{returnVal=Nothing}
      assignCode "" owner
      return $ Code ""
    else do
      useGas $ gCREATEDATA * toInteger (B.length codeBytes')
      assignCode codeBytes' owner
      return $ Code codeBytes'

  where
    assignCode::B.ByteString->Address->VMM ()
    assignCode codeBytes' address' = do
      addCode codeBytes'
      newAddressState <- getAddressState address'
      putAddressState address' newAddressState{addressStateCodeHash=hash codeBytes'}




--bool Executive::call(Address _receiveAddress, Address _codeAddress, Address _senderAddress, u256 _value, u256 _gasPrice, bytesConstRef _data, u256 _gas, Address _originAddress)

call::Bool->S.Set Address->Block->Int->Address->Address->Address->Word256->Word256->B.ByteString->Integer->Address->ContextM (Either VMException B.ByteString, VMState)
call isRunningTests' preExistingSuicideList b callDepth' receiveAddress (Address codeAddress) sender value' gasPrice' theData availableGas origin = do

  addressState <- getAddressState $ Address codeAddress

  code <- 
    if 0 < codeAddress && codeAddress < 5
    then return $ PrecompiledCode $ fromIntegral codeAddress
    else Code <$> fromMaybe B.empty <$> getCode (addressStateCodeHash addressState)

  let env =
        Environment{
          envGasPrice=fromIntegral gasPrice',
          envBlock=b,
          envOwner = receiveAddress,
          envOrigin = origin,
          envInputData = theData,
          envSender = sender,
          envValue = fromIntegral value',
          envCode = code,
          envJumpDests = getValidJUMPDESTs code
          }

  runVMM isRunningTests' preExistingSuicideList callDepth' env availableGas $ call'



--bool Executive::call(Address _receiveAddress, Address _codeAddress, Address _senderAddress, u256 _value, u256 _gasPrice, bytesConstRef _data, u256 _gas, Address _originAddress)

call'::VMM B.ByteString
--call' callDepth' address codeAddress sender value' gasPrice' theData availableGas origin = do
call' = do
  value' <- getEnvVar envValue
  receiveAddress <- getEnvVar envOwner
  sender <- getEnvVar envSender
  theData <- getEnvVar envInputData
  let Address receiveAddressNumber = receiveAddress

  --TODO- Deal with this return value
  _ <- pay "call value transfer" sender receiveAddress (fromIntegral value')
    
  --whenM isDebugEnabled $ liftIO $ putStrLn $ "availableGas: " ++ show availableGas

  runCodeFromStart

  vmState <- lift get

  when flags_debug $ liftIO $ do
      let result = fromMaybe B.empty $ returnVal vmState
      --putStrLn $ "Result: " ++ format result
      putStrLn $ "Gas remaining: " ++ show (vmGasRemaining vmState) ++ ", needed: " ++ show (5*toInteger (B.length result))
      --putStrLn $ show (pretty address) ++ ": " ++ format result

  return (fromMaybe B.empty $ returnVal vmState)





create_debugWrapper::Block->Address->Word256->B.ByteString->VMM (Maybe Address)
create_debugWrapper block owner value initCodeBytes = do

  addressState <- getAddressState owner

  if fromIntegral value > addressStateBalance addressState
    then return Nothing
    else do
      newAddress <- getNewAddress owner

      let initCode = Code initCodeBytes
      
      origin <- getEnvVar envOrigin
      gasPrice <- getEnvVar envGasPrice

      gasRemaining <- getGasRemaining

      currentCallDepth <- getCallDepth
                          
      dbs' <- lift $ fmap dbs get

      currentVMState <- lift get
              
      let runEm::ContextM a->VMM (a, Context)
          runEm f = lift $ lift $ flip runStateT dbs' f
          callEm::ContextM (Either VMException Code, VMState)
          callEm = create (isRunningTests currentVMState) (suicideList currentVMState) block (currentCallDepth+1) owner origin (toInteger value) gasPrice gasRemaining newAddress initCode

      ((result, finalVMState), finalDBs) <- runEm callEm

      setStateDBStateRoot $ MP.stateRoot $ contextStateDB $ finalDBs
  
      setGasRemaining $ vmGasRemaining finalVMState

      case result of
        Left e -> do
          when flags_debug $ liftIO $ putStrLn $ CL.red $ show e
          return Nothing
        Right _ -> do

          forM_ (reverse $ logs finalVMState) addLog
          state' <- lift get
          lift $ put state'{suicideList = suicideList finalVMState}

          return $ Just newAddress





nestedRun_debugWrapper::Integer->Address->Address->Address->Word256->B.ByteString->VMM (Int, Maybe B.ByteString)
nestedRun_debugWrapper gas receiveAddress (Address address') sender value inputData = do
  
--  theAddressExists <- lift $ lift $ lift $ addressStateExists (Address address')

  currentCallDepth <- getCallDepth

  env <- lift $ fmap environment $ get

  dbs' <- lift $ fmap dbs get

  currentVMState <- lift get
          
  let runEm::ContextM a->VMM (a, Context)
      runEm f = lift $ lift $ flip runStateT dbs' f
      callEm::ContextM (Either VMException B.ByteString, VMState)
      callEm = call (isRunningTests currentVMState) (suicideList currentVMState) (envBlock env) (currentCallDepth+1) receiveAddress (Address address') sender value (fromIntegral $ envGasPrice env) inputData gas (envOrigin env)


  ((result, finalVMState), finalDBs) <- 
      runEm callEm
      
  setStateDBStateRoot $ MP.stateRoot $ contextStateDB $ finalDBs
  

  case result of
        Right retVal -> do
          forM_ (reverse $ logs finalVMState) addLog
          state' <- lift get
          lift $ put state'{suicideList = suicideList finalVMState}
          when flags_debug $
            liftIO $ putStrLn $ "Refunding: " ++ show (vmGasRemaining finalVMState)
          useGas (- vmGasRemaining finalVMState)
          addToRefund (refund finalVMState)
          return (1, Just retVal)
        Left e -> do
          when flags_debug $ liftIO $ putStrLn $ CL.red $ show e
          return (0, Nothing)
