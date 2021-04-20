{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-deferred-type-errors #-}

-- | Top-level module to run a single Hydra node.
module Hydra.Node where

import Cardano.Prelude
import Control.Concurrent.STM (
  newTQueueIO,
  newTVarIO,
  readTQueue,
  stateTVar,
  writeTQueue,
 )
import Control.Exception.Safe (MonadThrow)
import Hydra.Logic (
  ClientInstruction (..),
  Effect (ClientEffect, ErrorEffect, NetworkEffect, OnChainEffect, Wait),
  Event (NetworkEvent, OnChainEvent),
  HeadState (..),
  HydraMessage (AckSn, AckTx, ConfSn, ConfTx, ReqSn, ReqTx),
  LogicError (InvalidState),
  OnChainTx (..),
 )
import qualified Hydra.Logic as Logic
import qualified Hydra.Logic.SimpleHead as SimpleHead
import System.Console.Repline (CompleterStyle (Word0), ExitDecision (Exit), evalRepl)

--
-- General handlers of client commands or events.
--

-- | Monadic interface around 'Hydra.Logic.update'.
handleNextEvent ::
  MonadThrow m =>
  EventQueue m ->
  HydraNetwork m ->
  OnChain m ->
  ClientSide m ->
  HydraHead m ->
  m ()
handleNextEvent EventQueue{nextEvent} HydraNetwork{broadcast} OnChain{postTx} ClientSide{showInstruction} HydraHead{modifyHeadState} = do
  e <- nextEvent
  out <- modifyHeadState $ \s -> swap $ Logic.update s e
  forM_ out $ \case
    ClientEffect i -> showInstruction i
    NetworkEffect msg -> broadcast msg
    OnChainEffect tx -> postTx tx
    Wait _cont -> panic "TODO: wait and reschedule continuation"
    ErrorEffect ie -> panic $ "TODO: handle this error: " <> show ie

init ::
  MonadThrow m =>
  OnChain m ->
  HydraHead m ->
  ClientSide m ->
  m ()
init OnChain{postTx} HydraHead{modifyHeadState} ClientSide{showInstruction} = do
  res <- modifyHeadState $ \s ->
    case s of
      InitState -> (Nothing, OpenState SimpleHead.mkState)
      _ -> (Just $ InvalidState s, s)
  case res of
    Just _ -> showInstruction CommandNotPossible
    Nothing -> do
      postTx InitTx
      showInstruction AcceptingTx

close ::
  MonadThrow m =>
  OnChain m ->
  HydraHead m ->
  m ()
close OnChain{postTx} hh = do
  -- TODO(SN): check that we are in open state
  putState hh ClosedState
  postTx CloseTx

--
-- Some general event queue from which the Hydra head is "fed"
--

-- | The single, required queue in the system from which a hydra head is "fed".
-- NOTE(SN): this probably should be bounded and include proper logging
-- NOTE(SN): handle pattern, but likely not required as there is no need for an
-- alternative implementation
data EventQueue m = EventQueue
  { putEvent :: Event -> m ()
  , nextEvent :: m Event
  }

createEventQueue :: IO (EventQueue IO)
createEventQueue = do
  q <- newTQueueIO
  pure
    EventQueue
      { putEvent = atomically . writeTQueue q
      , nextEvent = atomically $ readTQueue q
      }

--
-- HydraHead handle to manage a single hydra head state concurrently
--

-- | Handle to access and modify a Hydra Head's state.
newtype HydraHead m = HydraHead
  { modifyHeadState :: forall a. (HeadState -> (a, HeadState)) -> m a
  }

queryHeadState :: HydraHead m -> m HeadState
queryHeadState = (`modifyHeadState` \s -> (s, s))

putState :: HydraHead m -> HeadState -> m ()
putState HydraHead{modifyHeadState} new =
  modifyHeadState $ \_old -> ((), new)

createHydraHead :: HeadState -> IO (HydraHead IO)
createHydraHead initialState = do
  tv <- newTVarIO initialState
  pure HydraHead{modifyHeadState = atomically . stateTVar tv}

--
-- HydraNetwork handle to abstract over network access
--

-- | Handle to interface with the hydra network and send messages "off chain".
newtype HydraNetwork m = HydraNetwork
  { -- | Send a 'HydraMessage' to the whole hydra network.
    broadcast :: HydraMessage -> m ()
  }

-- | Connects to a configured set of peers and sets up the whole network stack.
createHydraNetwork :: EventQueue IO -> IO (HydraNetwork IO)
createHydraNetwork EventQueue{putEvent} = do
  -- NOTE(SN): obviously we should connect to a known set of peers here and do
  -- really broadcast messages to them
  pure HydraNetwork{broadcast = simulatedBroadcast}
 where
  simulatedBroadcast msg = do
    putStrLn @Text $ "[Network] should broadcast " <> show msg
    let ma = case msg of
          ReqTx -> Just AckTx
          AckTx -> Just ConfTx
          ConfTx -> Nothing
          ReqSn -> Just AckSn
          AckSn -> Just ConfSn
          ConfSn -> Nothing
    case ma of
      Just answer -> do
        putStrLn @Text $ "[Network] simulating answer " <> show answer
        putEvent $ NetworkEvent answer
      Nothing -> pure ()

--
-- OnChain handle to abstract over chain access
--

data ChainError = ChainError
  deriving (Exception, Show)

-- | Handle to interface with the main chain network
newtype OnChain m = OnChain
  { -- | Construct and send a transaction to the main chain corresponding to the
    -- given 'OnChainTx' event.
    -- Does at least throw 'ChainError'.
    postTx :: MonadThrow m => OnChainTx -> m ()
  }

-- | Connects to a cardano node and sets up things in order to be able to
-- construct actual transactions using 'OnChainTx' and send them on 'postTx'.
createChainClient :: EventQueue IO -> IO (OnChain IO)
createChainClient EventQueue{putEvent} = do
  -- NOTE(SN): obviously we should construct and send transactions, e.g. using
  -- plutus instead
  pure OnChain{postTx = simulatedPostTx}
 where
  simulatedPostTx tx = do
    putStrLn @Text $ "[OnChain] should post tx for " <> show tx
    let ma = case tx of
          InitTx -> Nothing
          CommitTx -> Just CollectComTx -- simulate other peer collecting
          CollectComTx -> Nothing
          CloseTx -> Just ContestTx -- simulate other peer contesting
          ContestTx -> Nothing
          FanoutTx -> Nothing
    case ma of
      Just answer -> void . async $ do
        threadDelay 1000000
        putStrLn @Text $ "[OnChain] simulating  " <> show answer
        putEvent $ OnChainEvent answer
      Nothing -> pure ()

--
-- ClientSide handle to abstract over the client side.. duh.
--

newtype ClientSide m = ClientSide
  { showInstruction :: ClientInstruction -> m ()
  }

-- | A simple command line based read-eval-process-loop (REPL) to have a chat
-- with the Hydra node.
--
-- NOTE(SN): This clashes a bit when other parts of the node do log things, but
-- spreading \r and >>> all over the place is likely not what we want
createClientSideRepl :: OnChain IO -> HydraHead IO -> IO (ClientSide IO)
createClientSideRepl oc hh = do
  link =<< async runRepl
  pure cs
 where
  prettyInstruction = \case
    ReadyToCommit -> "Head initialized, commit funds to it using 'commit'"
    AcceptingTx -> "Head is open, now feed the hydra with your 'newtx'"
    CommandNotPossible -> "You dummy .. use a different command."

  runRepl = evalRepl (const $ pure prompt) replCommand [] Nothing Nothing (Word0 replComplete) replInit (pure Exit)

  cs =
    ClientSide
      { showInstruction = \ins -> putStrLn @Text $ "[ClientSide] " <> prettyInstruction ins
      }

  prompt = ">>> "

  -- TODO(SN): avoid redundancy
  commands = ["init", "commit", "newtx", "close", "contest"]

  replCommand c
    | c == "init" = liftIO $ init oc hh cs
    | c == "close" = liftIO $ close oc hh
    -- c == "commit" =
    -- c == "newtx" =
    -- c == "contest" =
    | otherwise = liftIO $ putStrLn @Text $ "Unknown command, use any of: " <> show commands

  replComplete n = pure $ filter (n `isPrefixOf`) commands

  replInit = liftIO $ putStrLn @Text "Welcome to the Hydra Node REPL, you can even use tab completion! (Ctrl+D to exit)"
