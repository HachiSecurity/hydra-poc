{-# LANGUAGE TypeApplications #-}

module IntegrationSpec where

import Cardano.Prelude
import Control.Concurrent.STM (modifyTVar, newTVarIO, readTVarIO)
import Hydra.Ledger (Ledger (..), LedgerState, ValidationError (..), ValidationResult (Invalid, Valid))
import Hydra.Logic (ClientRequest (..), Event (OnChainEvent))
import Hydra.Node (EventQueue (..), HydraNode (..), OnChain (..), createHydraNode, handleCommand, runHydraNode)
import Test.Hspec (
  Spec,
  describe,
  expectationFailure,
  it,
  shouldReturn,
 )

spec :: Spec
spec = describe "Integrating one ore more hydra-nodes" $ do
  describe "Sanity tests of test suite" $ do
    it "is Ready when started" $ do
      n <- simulatedChain >>= startHydraNode
      queryNodeState n `shouldReturn` Ready

    it "is NotReady when stopped" $ do
      n <- simulatedChain >>= startHydraNode
      stopHydraNode n
      queryNodeState n `shouldReturn` NotReady

  describe "Hydra node integration" $ do
    it "does accept Init command" $ do
      n <- simulatedChain >>= startHydraNode
      sendCommand n Init `shouldReturn` ()

    it "does accept commits after successful Init" $ do
      n <- simulatedChain >>= startHydraNode
      sendCommand n Init
      sendCommand n Commit

    it "does accept a tx after the head is opened between many nodes" $ do
      chain <- simulatedChain
      n1 <- startHydraNode chain
      n2 <- startHydraNode chain
      sendCommand n1 Init
      sendCommand n1 Commit
      -- The second node can only commit after having observed the 'Init'
      -- transaction from the first node. We expect this commit to block until
      -- that moment.
      sendCommand n2 Commit
      sendCommand n2 (NewTx ValidTx)

data NodeState = NotReady | Ready
  deriving (Eq, Show)

data HydraProcess m = HydraProcess
  { stopHydraNode :: m ()
  , sendCommand :: ClientRequest MockTx -> m ()
  , queryNodeState :: m NodeState
  }

simulatedChain :: IO (HydraNode MockTx IO -> IO (OnChain IO))
simulatedChain = do
  queues <- newTVarIO []
  pure $ \HydraNode{eq} -> do
    atomically $ modifyTVar queues (eq :)
    pure $ OnChain{postTx = \tx -> readTVarIO queues >>= mapM_ (`putEvent` OnChainEvent tx)}

startHydraNode :: (HydraNode MockTx IO -> IO (OnChain IO)) -> IO (HydraProcess IO)
startHydraNode connectToChain = do
  node <- testHydraNode
  cc <- connectToChain node
  let testNode = node{oc = cc}
  nodeThread <- async $ forever $ runHydraNode testNode
  pure
    HydraProcess
      { stopHydraNode = cancel nodeThread
      , queryNodeState =
          poll nodeThread >>= \case
            Nothing -> pure Ready
            Just _ -> pure NotReady
      , sendCommand =
          handleCommand testNode >=> \case
            Right () -> pure ()
            Left _ -> expectationFailure "sendCommand failed"
      }
 where
  testHydraNode :: IO (HydraNode MockTx IO)
  testHydraNode = createHydraNode mockLedger

data MockTx = ValidTx | InvalidTx
  deriving (Eq, Show)

type instance LedgerState MockTx = ()

mockLedger :: Ledger MockTx
mockLedger =
  Ledger
    { canApply = \st tx -> case st `seq` tx of
        ValidTx -> Valid
        InvalidTx -> Invalid ValidationError
    , initLedgerState = ()
    }