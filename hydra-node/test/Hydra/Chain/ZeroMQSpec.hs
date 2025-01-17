{-# LANGUAGE TypeApplications #-}

module Hydra.Chain.ZeroMQSpec where

import Hydra.Prelude
import Test.Hydra.Prelude hiding (shouldReturn)

import Control.Concurrent (newChan, readChan, writeChan)
import Control.Monad.Class.MonadSTM (newEmptyTMVarIO, putTMVar, takeTMVar)
import Control.Monad.Class.MonadTimer (timeout)
import Hydra.Chain (HeadParameters (HeadParameters), OnChainTx (OnInitTx), PostChainTx (InitTx))
import Hydra.Chain.ZeroMQ (catchUpTransactions, mockChainClient, runChainSync, startChain)
import Hydra.Ledger.Simple (SimpleTx)
import Hydra.Logging (nullTracer)
import Test.Util (shouldReturn)

spec :: Spec
spec =
  parallel $
    describe "Mock 0MQ-Based Chain" $ do
      let sentTx = InitTx $ HeadParameters 10 [1, 2]
          receivedTx = OnInitTx 10 [1, 2]
          numberOfTxs :: Int
          numberOfTxs = 3

      it "publish transactions received from a client given chain is started" $ do
        withMockZMQChain 54321 54322 54323 $ \syncAddress _catchUpAddress postAddress -> do
          mvar <- newEmptyTMVarIO
          void $
            concurrently
              ( -- we lack proper synchronisation so better give chain sync time to join the party
                threadDelay 0.5 >> mockChainClient @SimpleTx postAddress nullTracer sentTx
              )
              (within3second $ runChainSync @SimpleTx syncAddress (atomically . putTMVar mvar) nullTracer)

          within3second (atomically $ takeTMVar mvar) `shouldReturn` Just receivedTx

      it "catches up transacions with mock chain" $ do
        chan <- newChan
        withMockZMQChain 54324 54325 54326 $ \_syncAddress catchUpAddress postAddress -> do
          forM_ [1 .. numberOfTxs] $ const $ mockChainClient @SimpleTx postAddress nullTracer sentTx
          catchUpTransactions @SimpleTx catchUpAddress (writeChan chan) nullTracer
          within3second (forM [1 .. numberOfTxs] (const $ readChan chan))
            `shouldReturn` Just [receivedTx, receivedTx, receivedTx]

withMockZMQChain :: Int -> Int -> Int -> (String -> String -> String -> IO ()) -> IO ()
withMockZMQChain syncPort catchUpPort postPort action =
  withAsync (startChain @SimpleTx syncAddress catchUpAddress postAddress nullTracer) $ \_ -> do
    action syncAddress catchUpAddress postAddress
 where
  syncAddress = "tcp://127.0.0.1:" <> show syncPort
  catchUpAddress = "tcp://127.0.0.1:" <> show catchUpPort
  postAddress = "tcp://127.0.0.1:" <> show postPort

within3second :: IO a -> IO (Maybe a)
within3second = timeout 3
