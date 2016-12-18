
module Blockchain.JsonRpcCommand (
  runJsonRpcCommand
  ) where

import qualified Data.ByteString as B

runJsonRpcCommand::String->B.ByteString->IO ()
runJsonRpcCommand command theData = do
  putStrLn "running command"

