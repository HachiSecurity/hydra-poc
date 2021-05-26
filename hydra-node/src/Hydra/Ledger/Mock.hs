{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeApplications #-}

-- | A mock implementation of a ledger
module Hydra.Ledger.Mock where

import Cardano.Prelude hiding (show)
import Codec.Serialise
import Hydra.Ledger
import Text.Read (Read (..))
import Text.Show (Show (..))

type Amount = Natural

-- | Simple mock transaction, which conflates value and identity
data MockTx = ValidTx Amount | InvalidTx
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

instance Read MockTx where
  readPrec =
    ValidTx <$> readPrec @Amount
      <|> pure InvalidTx

instance Show MockTx where
  show = \case
    ValidTx i -> show i
    InvalidTx -> "_|_"

type instance LedgerState MockTx = [MockTx]

mockLedger :: Ledger MockTx
mockLedger =
  Ledger
    { canApply = \st tx -> case st `seq` tx of
        ValidTx _ -> Valid
        InvalidTx -> Invalid ValidationError
    , applyTransaction = \st tx -> pure (tx : st)
    , initLedgerState = []
    }
