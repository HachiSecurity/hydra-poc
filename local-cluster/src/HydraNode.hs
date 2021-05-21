{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE TypeApplications #-}

module HydraNode where

import Cardano.Prelude
import Control.Concurrent.Async (
  forConcurrently_,
 )
import qualified Data.Text as Text
import Network.Socket (
  Family (AF_UNIX),
  SockAddr (SockAddrUnix),
  SocketType (Stream),
  close,
  connect,
  defaultProtocol,
  socket,
  socketToHandle,
 )
import System.IO (BufferMode (LineBuffering), hGetLine, hSetBuffering)
import System.Process (
  CreateProcess (..),
  proc,
  withCreateProcess,
 )
import System.Timeout (timeout)

data HydraNode = HydraNode
  { hydraNodeId :: Int
  , inputStream :: Handle
  , outputStream :: Handle
  }

sendRequest :: HydraNode -> Text -> IO ()
sendRequest HydraNode{hydraNodeId, inputStream} request =
  putText ("Tester sending to " <> show hydraNodeId <> ": " <> show request) >> hPutStrLn inputStream request

data WaitForResponseTimeout = WaitForResponseTimeout {nodeId :: Int, expectedResponse :: Text}
  deriving (Show)

instance Exception WaitForResponseTimeout

wait3sForResponse :: [HydraNode] -> Text -> IO ()
wait3sForResponse nodes expected = do
  forConcurrently_ nodes $ \HydraNode{hydraNodeId, outputStream} -> do
    -- The chain is slow...
    result <- timeout 3_000_000 $ tryNext outputStream
    maybe (throwIO $ WaitForResponseTimeout hydraNodeId expected) pure result
 where
  tryNext h = do
    result <- Text.pack <$> hGetLine h
    if result == expected
      then pure ()
      else tryNext h

withHydraNode :: Int -> (HydraNode -> IO ()) -> IO ()
withHydraNode hydraNodeId action = do
  withCreateProcess (hydraNodeProcess hydraNodeId) $
    \_stdin _stdout _stderr _ph -> do
      bracket (open $ "/tmp/hydra.socket." <> show hydraNodeId) close client
 where
  open addr =
    bracketOnError (socket AF_UNIX Stream defaultProtocol) close $ \sock -> do
      tryConnect sock addr
      return sock

  tryConnect sock addr =
    connect sock (SockAddrUnix addr) `catch` \(_ :: IOException) -> do
      threadDelay 100_000
      tryConnect sock addr

  client sock = do
    h <- socketToHandle sock ReadWriteMode
    hSetBuffering h LineBuffering
    action $ HydraNode hydraNodeId h h

data CannotStartHydraNode = CannotStartHydraNode Int deriving (Show)
instance Exception CannotStartHydraNode

hydraNodeProcess :: Int -> CreateProcess
hydraNodeProcess nodeId = proc "hydra-node" [show nodeId]

withMockChain :: IO () -> IO ()
withMockChain action = do
  withCreateProcess (proc "mock-chain" []) $
    \_in _out _err _handle -> do
      putText "Mock chain started"
      action
