module Hydra.Logic where

import Cardano.Prelude hiding (State)

import qualified Hydra.Logic.SimpleHead as SimpleHead
import Prelude (error)

data Event
  = ClientEvent ClientCommand
  | NetworkEvent HydraMessage
  | OnChainEvent OnChainTx
  deriving (Show)

data Effect
  = ClientEffect ClientInstruction
  | NetworkEffect HydraMessage
  | OnChainEffect OnChainTx
  | -- | Wait effect should be interpreted as a non-blocking interruption which
    -- retries on every state changes until the continuation returns Just{}.
    Wait (HeadState -> Maybe (HeadState, [Effect]))

data ClientCommand
  = Init
  | Commit
  | NewTx
  | Close
  | Contest
  deriving (Show)

data ClientInstruction
  = ReadyToCommit
  | AcceptingTx
  | CommandNotPossible
  deriving (Eq, Show)

data HydraMessage
  = ReqTx
  | AckTx
  | ConfTx
  | ReqSn
  | AckSn
  | ConfSn
  deriving (Show)

data OnChainTx
  = InitTx
  | CommitTx
  | CollectComTx
  | CloseTx
  | ContestTx
  | FanoutTx
  deriving (Show)

data HeadState
  = InitState
  | OpenState SimpleHead.State
  | ClosedState
  deriving (Eq, Show)

-- | Verification used to authenticate main chain transactions that are
-- restricted to members of the Head protocol instance, i.e. the commit
-- transaction. This key is named k_i in the paper and for Cardano, this is
-- currently a Ed25519 verification key
data OnChainVerificationKey

-- | Verification key to the signing key used for signing / acking transactions
-- off chain. This key is named K_i in the paper and can be aggregated with
-- other party member's 'HydraVerificationKey' to K_agg.
data HydraVerificationKey

-- | Identifes a party in a Hydra head.
type Party = (OnChainVerificationKey, HydraVerificationKey)

-- | Contains at least the contestation period and other things.
data HeadParameters = HeadParameters

-- | Decides when, how often and who is in charge of creating snapshots.
data SnapshotStrategy = SnapshotStrategy

-- | Assume: We know the party members and their verification keys. These need
-- to be exchanged somehow, eventually.
createHeadState :: [Party] -> HeadParameters -> SnapshotStrategy -> HeadState
createHeadState _ _ _ = InitState

-- | The heart of the Hydra head logic, a handler of all kinds of 'Event' in the
-- Hydra head. This may also be split into multiple handlers, i.e. one for hydra
-- network events, one for client events and one for main chain events, or by
-- sub-'State'.
update :: HeadState -> Event -> Maybe (HeadState, [Effect])
update st ev = case (st, ev) of
  (InitState{}  , ClientEvent Init ) -> pure init
  (OpenState st', ClientEvent Close) -> pure $ close st'
  (OpenState st', ClientEvent NewTx) ->
    pure . bimap OpenState (map mapEffect) $ SimpleHead.update
      st'
      SimpleHead.NewTxFromClient
  (OpenState st', NetworkEvent ReqTx) ->
    pure . bimap OpenState (map mapEffect) $ SimpleHead.update
      st'
      SimpleHead.ReqTxFromPeer
  _ -> Nothing

-- | NOTE: This is definitely not directly Open!
init :: (HeadState, [Effect])
init = (OpenState SimpleHead.mkState, [ClientEffect AcceptingTx])

close :: SimpleHead.State -> (HeadState, [Effect])
close _ = (ClosedState, [])

-- NOTE: This three things needs to be polymorphic in the output eventually, likely a
-- type-class with data-families for each sub-modules.

mapState :: HeadState -> Maybe SimpleHead.State
mapState = \case
  OpenState st' -> Just st'
  _ -> Nothing

mapEffect :: SimpleHead.Effect -> Effect
mapEffect = \case
  SimpleHead.MulticastReqTx -> NetworkEffect ReqTx
  SimpleHead.MulticastReqSn -> NetworkEffect ReqSn
  SimpleHead.MulticastConfTx -> NetworkEffect ConfTx
  SimpleHead.SendAckTx -> NetworkEffect AckTx
  SimpleHead.Wait continue ->
    Wait $ mapState >=> fmap (bimap OpenState (map mapEffect)) . continue
