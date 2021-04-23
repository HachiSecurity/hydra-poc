{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE TypeApplications #-}

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
import Hydra.Ledger
import Hydra.Logic (
  ClientInstruction (..),
  Effect (ClientEffect, ErrorEffect, NetworkEffect, OnChainEffect, Wait),
  Event (NetworkEvent, OnChainEvent),
  HeadState (..),
  HydraMessage (AckSn, AckTx, ConfSn, ConfTx, MsgReqTx, ReqSn),
  LogicError (InvalidState),
  OnChainTx (..),
  ReqTx (ReqTx),
 )
import qualified Hydra.Logic as Logic
import qualified Hydra.Logic.SimpleHead as SimpleHead
import System.Console.Repline (CompleterStyle (Word0), ExitDecision (Exit), evalRepl)

--
-- General handlers of client commands or events.
--

-- | Monadic interface around 'Hydra.Logic.update'.
handleNextEvent ::
  Show (LedgerState tx) => -- TODO(SN): leaky abstraction of HydraHead
  Show tx =>
  MonadThrow m =>
  HydraNetwork tx m ->
  OnChain m ->
  ClientSide m ->
  HydraHead tx m ->
  Event tx ->
  m (Maybe (LogicError tx))
handleNextEvent HydraNetwork{broadcast} OnChain{postTx} ClientSide{showInstruction} HydraHead{modifyHeadState, ledger} e = do
  result <- modifyHeadState $ \s -> swap $ Logic.update ledger s e
  case result of
    Left err -> pure $ Just err
    Right out -> do
      forM_ out $ \case
        ClientEffect i -> showInstruction i
        NetworkEffect msg -> broadcast msg
        OnChainEffect tx -> postTx tx
        Wait _cont -> panic "TODO: wait and reschedule continuation"
        ErrorEffect ie -> panic $ "TODO: handle this error: " <> show ie
      pure Nothing

init ::
  MonadThrow m =>
  OnChain m ->
  HydraHead tx m ->
  ClientSide m ->
  m (Either (LogicError tx) ())
init OnChain{postTx} HydraHead{modifyHeadState, ledger} ClientSide{showInstruction} = do
  res <- modifyHeadState $ \s ->
    case s of
      InitState -> (Nothing, OpenState $ SimpleHead.mkState initLedgerState)
      _ -> (Just $ InvalidState s, s)
  case res of
    Just e -> pure $ Left e
    Nothing -> do
      postTx InitTx
      showInstruction AcceptingTx
      pure $ Right ()
 where
  Ledger{initLedgerState} = ledger

newTx :: Monad m => HydraHead tx m -> HydraNetwork tx m -> tx -> m ValidationResult
newTx hh@HydraHead{ledger} HydraNetwork{broadcast} tx = do
  mConfirmedLedger <- getConfirmedLedger hh
  case mConfirmedLedger of
    Nothing -> panic "TODO: Not in OpenState"
    Just confirmedLedger ->
      case canApply ledger confirmedLedger tx of
        Valid -> do
          broadcast (MsgReqTx $ ReqTx tx) $> Valid
        invalid ->
          return invalid

close ::
  MonadThrow m =>
  OnChain m ->
  HydraHead tx m ->
  m ()
close OnChain{postTx} hh = do
  -- TODO(SN): check that we are in open state
  putState hh ClosedState
  postTx CloseTx

data InvalidTransaction = InvalidTransaction
  deriving (Eq, Show)

handleReqTx :: Monad m => HydraHead tx m -> HydraNetwork tx m -> ReqTx tx -> m (Maybe InvalidTransaction)
handleReqTx hh@HydraHead{ledger} HydraNetwork{broadcast} (ReqTx tx) = do
  mConfirmedLedger <- getConfirmedLedger hh
  case mConfirmedLedger of
    Nothing -> panic "TODO: Not in OpenState"
    Just confirmedLedger ->
      -- TODO(SN): distinguish between 'valid-tx' and 'canApply', as well as 'wait' until applicable here
      case canApply ledger confirmedLedger tx of
        Valid -> broadcast AckTx $> Nothing
        _ -> pure $ Just InvalidTransaction

--
-- Some general event queue from which the Hydra head is "fed"
--

-- | The single, required queue in the system from which a hydra head is "fed".
-- NOTE(SN): this probably should be bounded and include proper logging
-- NOTE(SN): handle pattern, but likely not required as there is no need for an
-- alternative implementation
data EventQueue m e = EventQueue
  { putEvent :: e -> m ()
  , nextEvent :: m e
  }

createEventQueue :: IO (EventQueue IO e)
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
data HydraHead tx m = HydraHead
  { modifyHeadState :: forall a. (HeadState tx -> (a, HeadState tx)) -> m a
  , ledger :: Ledger tx
  }

getConfirmedLedger :: Monad m => HydraHead tx m -> m (Maybe (LedgerState tx))
getConfirmedLedger hh =
  queryHeadState hh <&> \case
    OpenState st -> Just (SimpleHead.confirmedLedger st)
    _ -> Nothing

queryHeadState :: HydraHead tx m -> m (HeadState tx)
queryHeadState = (`modifyHeadState` \s -> (s, s))

putState :: HydraHead tx m -> HeadState tx -> m ()
putState HydraHead{modifyHeadState} new =
  modifyHeadState $ \_old -> ((), new)

createHydraHead :: HeadState tx -> Ledger tx -> IO (HydraHead tx IO)
createHydraHead initialState ledger = do
  tv <- newTVarIO initialState
  pure HydraHead{modifyHeadState = atomically . stateTVar tv, ledger}

--
-- HydraNetwork handle to abstract over network access
--

-- | Handle to interface with the hydra network and send messages "off chain".
newtype HydraNetwork tx m = HydraNetwork
  { -- | Send a 'HydraMessage' to the whole hydra network.
    broadcast :: HydraMessage tx -> m ()
  }

-- | Connects to a configured set of peers and sets up the whole network stack.
createHydraNetwork :: Show tx => EventQueue IO (Event tx) -> IO (HydraNetwork tx IO)
createHydraNetwork EventQueue{putEvent} = do
  -- NOTE(SN): obviously we should connect to a known set of peers here and do
  -- really broadcast messages to them
  pure HydraNetwork{broadcast = simulatedBroadcast}
 where
  simulatedBroadcast msg = do
    putStrLn @Text $ "[Network] should broadcast " <> show msg
    let ma = case msg of
          MsgReqTx _ -> Just AckTx
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
createChainClient :: EventQueue IO (Event tx) -> IO (OnChain IO)
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
createClientSideRepl ::
  Show (LedgerState tx) => -- TODO(SN): leaky abstraction of HydraHead
  Show tx =>
  OnChain IO ->
  HydraHead tx IO ->
  HydraNetwork tx IO ->
  (FilePath -> IO tx) ->
  IO (ClientSide IO)
createClientSideRepl oc hh hn loadTx = do
  link =<< async runRepl
  pure cs
 where
  prettyInstruction = \case
    ReadyToCommit -> "Head initialized, commit funds to it using 'commit'"
    AcceptingTx -> "Head is open, now feed the hydra with your 'newtx'"

  runRepl = evalRepl (const $ pure prompt) replCommand [] Nothing Nothing (Word0 replComplete) replInit (pure Exit)

  cs =
    ClientSide
      { showInstruction = \ins -> putStrLn @Text $ "[ClientSide] " <> prettyInstruction ins
      }

  prompt = ">>> "

  -- TODO(SN): avoid redundancy
  commands = ["init", "commit", "newtx", "close", "contest"]

  replCommand c
    | c == "init" =
      liftIO $
        init oc hh cs >>= \case
          Left e -> putStrLn @Text $ "You dummy.. " <> show e
          Right _ -> pure ()
    | c == "close" = liftIO $ close oc hh
    -- c == "commit" =
    | c == "newtx" = liftIO $ loadTx "hardcoded/file/path" >>= void . newTx hh hn
    -- c == "contest" =
    | otherwise = liftIO $ putStrLn @Text $ "Unknown command, use any of: " <> show commands

  replComplete n = pure $ filter (n `isPrefixOf`) commands

  replInit = liftIO $ putStrLn @Text "Welcome to the Hydra Node REPL, you can even use tab completion! (Ctrl+D to exit)"
