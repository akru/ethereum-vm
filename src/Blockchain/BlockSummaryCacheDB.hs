{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, UndecidableInstances, GeneralizedNewtypeDeriving, FlexibleContexts, MultiParamTypeClasses, TypeFamilies #-}

module Blockchain.BlockSummaryCacheDB (
    BlockSummaryCacheT,
    BlockSummary(..),
    blockToBSum,
    withBlockSummaryCacheDB,
    getBSum,
    putBSum
  ) where

import Control.Monad
import Control.Monad.Base
import Control.Monad.Trans
import Control.Monad.Trans.Control
import Control.Monad.Trans.Resource
import Control.Monad.Trans.State
import Data.Binary
import qualified Data.ByteString.Lazy as BL
import Data.Maybe
import Data.Time
import qualified Database.LevelDB as LDB
    
import Blockchain.Data.DataDefs
import Blockchain.Data.RLP
import qualified Blockchain.Database.MerklePatricia as MP
import Blockchain.SHA
                
class HasBlockSummaryCacheDB m where
    getBlockSummaryCacheDB::m LDB.DB
    
newtype BlockSummaryCacheT m r = BlockSummaryCacheT{runBlockSummaryCacheDBT::LDB.DB->m r}

withBlockSummaryCacheDB::MonadResource m=>FilePath->BlockSummaryCacheT m r->m r
withBlockSummaryCacheDB filename f = do
  db <- LDB.open filename LDB.defaultOptions{LDB.createIfMissing=True}
  runBlockSummaryCacheDBT f db

data BlockSummary = BlockSummary {
      bSumDifficulty::Integer,
      bSumTotalDifficulty::Int,
      bSumStateRoot::MP.SHAPtr,
      bSumGasLimit::Integer,
      bSumTimestamp::UTCTime,
      bSumNumber::Integer
    }

blockToBSum::Block->BlockSummary
blockToBSum b = 
    BlockSummary {
      bSumDifficulty = blockDataDifficulty $ blockBlockData b,
      bSumTotalDifficulty = 0, -- blockDataTotalDifficulty $ blockBlockData b,
      bSumStateRoot = blockDataStateRoot $ blockBlockData b,
      bSumGasLimit = blockDataGasLimit $ blockBlockData b,
      bSumTimestamp = blockDataTimestamp $ blockBlockData b,
      bSumNumber = blockDataNumber $ blockBlockData b
    }

instance RLPSerializable BlockSummary where
    rlpEncode = undefined
    rlpDecode = undefined
                  
getBSum::(MonadResource m, HasBlockSummaryCacheDB m)=>SHA->m BlockSummary
getBSum blockHash = do
  db <- getBlockSummaryCacheDB
  fmap (rlpDecode . rlpDeserialize . fromMaybe (error "missing value in block summary DB")) $ LDB.get db LDB.defaultReadOptions $ BL.toStrict $ encode blockHash

putBSum::(MonadResource m, HasBlockSummaryCacheDB m)=>SHA->BlockSummary->m ()
putBSum blockHash bSum = do
  db <- getBlockSummaryCacheDB
  LDB.put db LDB.defaultWriteOptions (BL.toStrict $ encode blockHash) (rlpSerialize $ rlpEncode bSum)



---------------------------------------
    
instance Functor m=>Functor (BlockSummaryCacheT m) where
    fmap f1 (BlockSummaryCacheT f2) = BlockSummaryCacheT (fmap f1 . f2)
instance (Monad m, Applicative m)=>Applicative (BlockSummaryCacheT m) where
    pure x = BlockSummaryCacheT $ const $ pure x
    (<*>)= ap
instance Monad m=>Monad (BlockSummaryCacheT m) where
    (BlockSummaryCacheT f1) >>= f2 = BlockSummaryCacheT $ \val -> do
      ret1 <- f1 val
      let BlockSummaryCacheT f3 = f2 ret1
      f3 val
                        
-----------

instance Monad m=>HasBlockSummaryCacheDB (BlockSummaryCacheT m) where
    getBlockSummaryCacheDB = BlockSummaryCacheT return

instance MonadTrans BlockSummaryCacheT where
    lift m = BlockSummaryCacheT (const m) 

instance (HasBlockSummaryCacheDB m, Monad m)=>HasBlockSummaryCacheDB (StateT a m) where
    getBlockSummaryCacheDB = lift getBlockSummaryCacheDB

instance (HasBlockSummaryCacheDB m, Monad m)=>HasBlockSummaryCacheDB (ResourceT m) where
    getBlockSummaryCacheDB = lift getBlockSummaryCacheDB


instance MonadResource m=>MonadResource (BlockSummaryCacheT m) where
    liftResourceT = lift . liftResourceT
    
instance MonadTransControl (BlockSummaryCacheT) where
    type StT (BlockSummaryCacheT) a = a
    liftWith f = BlockSummaryCacheT $ \r -> f $ \t -> runBlockSummaryCacheDBT t r
    restoreT = BlockSummaryCacheT . const
instance (MonadBaseControl IO m) => MonadBaseControl IO (BlockSummaryCacheT m) where
    type StM (BlockSummaryCacheT m) a = ComposeSt (BlockSummaryCacheT) m a; 
    liftBaseWith = defaultLiftBaseWith;   
    restoreM     = defaultRestoreM;       
                                                                                                                
instance MonadBase IO m=>MonadBase IO (BlockSummaryCacheT m) where
    liftBase = lift . liftBase
instance MonadIO m=>MonadIO (BlockSummaryCacheT m) where
    liftIO = lift . liftIO
instance MonadThrow m=>MonadThrow (BlockSummaryCacheT m) where
    throwM=lift . throwM
