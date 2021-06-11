{-# LANGUAGE TypeApplications #-}

module Main where

import Cardano.Prelude hiding (Option, option)

import Control.Concurrent.STM (newBroadcastTChanIO, writeTChan)
import Hydra.API.Server (runAPIServer)
import Hydra.Chain.ZeroMQ (createMockChainClient)
import Hydra.HeadLogic (
  Environment (..),
  Event (..),
  HeadParameters (..),
  SnapshotStrategy (..),
  createHeadState,
 )
import qualified Hydra.Ledger.Mock as Ledger
import Hydra.Logging
import Hydra.Logging.Messages (HydraLog (..))
import Hydra.Logging.Monitoring (withMonitoring)
import Hydra.Network.BroadcastToSelf (withBroadcastToSelf)
import Hydra.Network.Heartbeat (withHeartbeat)
import Hydra.Network.Ouroboros (withOuroborosNetwork)
import Hydra.Node (
  EventQueue (..),
  HydraNode (..),
  createEventQueue,
  createHydraHead,
  runHydraNode,
 )
import Hydra.Option (Option (..), parseHydraOptions)

main :: IO ()
main = do
  Option{nodeId, verbosity, host, port, peers, apiHost, apiPort, monitoringPort} <- identifyNode <$> parseHydraOptions
  withTracer verbosity show $ \tracer' ->
    withMonitoring monitoringPort tracer' $ \tracer -> do
      let env = Environment nodeId NoSnapshots
      eq <- createEventQueue
      let headState = createHeadState [] (HeadParameters 3 mempty)
      hh <- createHydraHead headState Ledger.mockLedger
      oc <- createMockChainClient eq (contramap MockChain tracer)
      withNetwork nodeId host port peers (putEvent eq . NetworkEvent) $
        \hn -> do
          responseChannel <- newBroadcastTChanIO
          let sendResponse = atomically . writeTChan responseChannel
          let node = HydraNode{eq, hn, hh, oc, sendResponse, env}
          race_
            (runAPIServer apiHost apiPort responseChannel node (contramap APIServer tracer))
            (runHydraNode (contramap Node tracer) node)
 where
  withNetwork nodeId host port peers =
    withHeartbeat nodeId $ withBroadcastToSelf $ withOuroborosNetwork (show host, port) peers

identifyNode :: Option -> Option
identifyNode opt@Option{verbosity = Verbose "HydraNode", nodeId} = opt{verbosity = Verbose $ "HydraNode-" <> show nodeId}
identifyNode opt = opt
