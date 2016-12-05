module Blockchain.VM.Helpers where

import Blockchain.Data.DataDefs
import Blockchain.Data.BlockSummary
import Blockchain.Sequencer.Event

outputBlockToBlockSummary :: OutputBlock -> BlockSummary
outputBlockToBlockSummary b =
    BlockSummary {
      bSumParentHash = blockDataParentHash $ obBlockData b,
      bSumDifficulty = blockDataDifficulty $ obBlockData b,
      bSumTotalDifficulty = 0, -- blockDataTotalDifficulty $ blockBlockData b, -- todo why is this 0?
      bSumStateRoot = blockDataStateRoot $ obBlockData b,
      bSumGasLimit = blockDataGasLimit $ obBlockData b,
      bSumTimestamp = blockDataTimestamp $ obBlockData b,
      bSumNumber = blockDataNumber $ obBlockData b
    }
