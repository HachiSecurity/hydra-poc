module Hydra.Ledger where

import Cardano.Prelude hiding (undefined)
import Prelude (undefined)

import Cardano.Ledger.Mary (MaryEra)
import Cardano.Slotting.EpochInfo (fixedSizeEpochInfo)
import Cardano.Slotting.Slot (SlotNo (SlotNo))
import Ouroboros.Consensus.Shelley.Protocol (StandardCrypto)
import Shelley.Spec.Ledger.API (Globals (..), Network (Testnet))
import qualified Shelley.Spec.Ledger.API as Ledger
import Shelley.Spec.Ledger.BaseTypes (UnitInterval, mkActiveSlotCoeff, mkUnitInterval)
import Shelley.Spec.Ledger.PParams (emptyPParams)
import Shelley.Spec.Ledger.Slot (EpochSize (EpochSize), SlotNo)

type family LedgerState tx

data Ledger tx = Ledger
  { canApply :: LedgerState tx -> tx -> ValidationResult
  , initLedgerState :: LedgerState tx
  }

-- | Either valid or an error which we get from the ledger-specs tx validation.
data ValidationResult
  = Valid
  | Invalid ValidationError
  deriving (Eq, Show)

data ValidationError = ValidationError deriving (Eq, Show)

--
-- Cardano ledger
--

-- | A standard 'MaryEra' ledger environment.
mkCardanoMaryLedgerEnv :: Ledger.LedgersEnv (MaryEra StandardCrypto)
mkCardanoMaryLedgerEnv =
  Ledger.LedgersEnv
    { Ledger.ledgersSlotNo = SlotNo 1
    , Ledger.ledgersPp = emptyPParams
    , Ledger.ledgersAccount = panic "Not implemented"
    }

type instance LedgerState (Ledger.Tx era) = Ledger.LedgerState era

cardanoLedger :: Ledger.ApplyTx era => Ledger.LedgersEnv era -> Ledger (Ledger.Tx era)
cardanoLedger env =
  Ledger
    { canApply = validateTx env
    , initLedgerState = undefined
    }

validateTx ::
  Ledger.ApplyTx era =>
  Ledger.LedgersEnv era ->
  Ledger.LedgerState era ->
  Ledger.Tx era ->
  ValidationResult
validateTx env ls tx =
  either (Invalid . toValidationError) (const Valid) $
    Ledger.applyTxsTransition globals env (pure tx) ls
 where
  -- toValidationError :: ApplyTxError -> ValidationError
  toValidationError = const ValidationError

--
-- From: shelley/chain-and-ledger/shelley-spec-ledger-test/src/Test/Shelley/Spec/Ledger/Utils.hs
--

-- TODO(SN): not hard-code these obviously
globals :: Globals
globals =
  Globals
    { epochInfo = fixedSizeEpochInfo $ EpochSize 100
    , slotsPerKESPeriod = 20
    , stabilityWindow = 33
    , randomnessStabilisationWindow = 33
    , securityParameter = 10
    , maxKESEvo = 10
    , quorum = 5
    , maxMajorPV = 1000
    , maxLovelaceSupply = 45 * 1000 * 1000 * 1000 * 1000 * 1000
    , activeSlotCoeff = mkActiveSlotCoeff . unsafeMkUnitInterval $ 0.9
    , networkId = Testnet
    }

-- | You vouch that argument is in [0; 1].
unsafeMkUnitInterval :: Ratio Word64 -> UnitInterval
unsafeMkUnitInterval r =
  fromMaybe (panic "could not construct unit interval") $ mkUnitInterval r
