{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

-- | Transaction creation and fees

module Pos.Wallet.Web.Methods.Payment
       ( newPayment
       , getTxFee
       ) where

import           Universum

import           Control.Exception                (throw)
import           Control.Monad.Except             (runExcept)
import qualified Data.Map                         as M
import           Data.Time.Units                  (Second)
import           Mockable                         (concurrently, delay)
import           Servant.Server                   (err405, errReasonPhrase)
import           System.Wlog                      (logDebug)

import           Pos.Aeson.ClientTypes            ()
import           Pos.Aeson.WalletBackup           ()
import           Pos.Client.Txp.Addresses         (MonadAddresses (..))
import           Pos.Client.Txp.Balances          (getOwnUtxos)
import           Pos.Client.Txp.History           (TxHistoryEntry (..))
import           Pos.Client.Txp.Util              (computeTxFee, runTxCreator)
import           Pos.Communication                (SendActions (..), prepareMTx)
import           Pos.Configuration                (HasNodeConfiguration,
                                                   walletTxCreationDisabled)
import           Pos.Core                         (Coin, HasConfiguration,
                                                   getCurrentTimestamp)
import           Pos.Crypto                       (PassPhrase, ShouldCheckPassphrase (..),
                                                   checkPassMatches, hash,
                                                   withSafeSignerUnsafe)
import           Pos.Infra.Configuration          (HasInfraConfiguration)
import           Pos.Ssc.GodTossing.Configuration (HasGtConfiguration)
import           Pos.Txp                          (TxFee (..), Utxo, _txOutputs)
import           Pos.Txp.Core                     (TxAux (..), TxOut (..))
import           Pos.Update.Configuration         (HasUpdateConfiguration)
import           Pos.Util                         (eitherToThrow, maybeThrow)
import           Pos.Wallet.KeyStorage            (getSecretKeys)
import           Pos.Wallet.Web.Account           (GenSeed (..), getSKByAddressPure,
                                                   getSKById)
import           Pos.Wallet.Web.ClientTypes       (AccountId (..), Addr, CCoin, CId,
                                                   CTx (..), CWAddressMeta (..), Wal,
                                                   addrMetaToAccount, mkCCoin)
import           Pos.Wallet.Web.Error             (WalletError (..))
import           Pos.Wallet.Web.Methods.History   (addHistoryTx, constructCTx,
                                                   getCurChainDifficulty)
import qualified Pos.Wallet.Web.Methods.Logic     as L
import           Pos.Wallet.Web.Methods.Txp       (coinDistrToOutputs, rewrapTxError,
                                                   submitAndSaveNewPtx)
import           Pos.Wallet.Web.Mode              (MonadWalletWebMode, WalletWebMode,
                                                   convertCIdTOAddrs)
import           Pos.Wallet.Web.Pending           (mkPendingTx)
import           Pos.Wallet.Web.State             (AddressLookupMode (Ever, Existing),
                                                   NeedSorting (..))
import           Pos.Wallet.Web.State.State       (getPendingTxs)
import           Pos.Wallet.Web.Util              (decodeCTypeOrFail,
                                                   getAccountAddrsOrThrow,
                                                   getWalletAccountIds,
                                                   getWalletAddrsDetector)

newPayment
    :: MonadWalletWebMode m
    => SendActions m
    -> PassPhrase
    -> AccountId
    -> CId Addr
    -> Coin
    -> m CTx
newPayment sa passphrase srcAccount dstAccount coin =
    -- This is done for two reasons:
    -- 1. In order not to overflow relay.
    -- 2. To let other things (e. g. block processing) happen if
    -- `newPayment`s are done continuously.
    notFasterThan (6 :: Second) $
    sendMoney
        sa
        passphrase
        (AccountMoneySource srcAccount)
        (one (dstAccount, coin))
  where
    notFasterThan time action = fst <$> concurrently action (delay time)

getTxFee
     :: MonadWalletWebMode m
     => AccountId
     -> CId Addr
     -> Coin
     -> m CCoin
getTxFee srcAccount dstAccount coin = do
    pendingTxs <- getPendingTxs
    utxo <- getMoneySourceUtxo (AccountMoneySource srcAccount)
    outputs <- coinDistrToOutputs $ one (dstAccount, coin)
    TxFee fee <- rewrapTxError "Cannot compute transaction fee" $
        eitherToThrow =<< runTxCreator (computeTxFee pendingTxs utxo outputs)
    pure $ mkCCoin fee

data MoneySource
    = WalletMoneySource (CId Wal)
    | AccountMoneySource AccountId
    | AddressMoneySource CWAddressMeta
    deriving (Show, Eq)

getMoneySourceAddresses :: MonadWalletWebMode m => MoneySource -> m [CWAddressMeta]
getMoneySourceAddresses (AddressMoneySource addrId) = return $ one addrId
getMoneySourceAddresses (AccountMoneySource accId) =
    getAccountAddrsOrThrow Existing (NeedSorting False) accId
getMoneySourceAddresses (WalletMoneySource wid) =
    getWalletAccountIds wid >>=
    concatMapM (getMoneySourceAddresses . AccountMoneySource)

getSomeMoneySourceAccount :: MonadWalletWebMode m => MoneySource -> m AccountId
getSomeMoneySourceAccount (AddressMoneySource addrId) =
    return $ addrMetaToAccount addrId
getSomeMoneySourceAccount (AccountMoneySource accId) = return accId
getSomeMoneySourceAccount (WalletMoneySource wid) = do
    wAddr <- (head <$> getWalletAccountIds wid) >>= maybeThrow noWallets
    getSomeMoneySourceAccount (AccountMoneySource wAddr)
  where
    noWallets = InternalError "Wallet has no accounts"

getMoneySourceWallet :: MoneySource -> CId Wal
getMoneySourceWallet (AddressMoneySource addrId) = cwamWId addrId
getMoneySourceWallet (AccountMoneySource accId)  = aiWId accId
getMoneySourceWallet (WalletMoneySource wid)     = wid

getMoneySourceUtxo :: MonadWalletWebMode m => MoneySource -> m Utxo
getMoneySourceUtxo =
    getMoneySourceAddresses >=>
    mapM (decodeCTypeOrFail . cwamId) >=>
    getOwnUtxos

-- [CSM-407] It should be moved to `Pos.Wallet.Web.Mode`, but
-- to make it possible all this mess should be neatly separated
-- to modules and refactored
instance
    ( HasConfiguration
    , HasNodeConfiguration
    , HasInfraConfiguration
    , HasGtConfiguration
    , HasUpdateConfiguration
    )
    => MonadAddresses Pos.Wallet.Web.Mode.WalletWebMode
  where
    type AddrData Pos.Wallet.Web.Mode.WalletWebMode = (AccountId, PassPhrase)
    getNewAddress (accId, passphrase) = do
        cAddrMeta <- L.newAddress_ RandomSeed passphrase accId
        decodeCTypeOrFail (cwamId cAddrMeta)

sendMoney
    :: MonadWalletWebMode m
    => SendActions m
    -> PassPhrase
    -> MoneySource
    -> NonEmpty (CId Addr, Coin)
    -> m CTx
sendMoney SendActions{..} passphrase moneySource dstDistr = do
    when walletTxCreationDisabled $
        throwM err405
        { errReasonPhrase = "Transaction creation is disabled by configuration!"
        }

    let srcWallet = getMoneySourceWallet moneySource
    rootSk <- getSKById srcWallet
    checkPassMatches passphrase rootSk `whenNothing`
        throwM (RequestError "Passphrase doesn't match")

    logDebug "sendMoney: start retrieving addrs"

    addrMetas' <- getMoneySourceAddresses moneySource
    addrMetas <- nonEmpty addrMetas' `whenNothing`
        throwM (RequestError "Given money source has no addresses!")
    logDebug "sendMoney: retrieved addrs"

    srcAddrs <- convertCIdTOAddrs $ map cwamId addrMetas

    logDebug "sendMoney: processed addrs"

    let metasAndAdrresses = M.fromList $ zip (toList srcAddrs) (toList addrMetas)
    allSecrets <- getSecretKeys

    let getSigner addr = runIdentity $ do
          let addrMeta =
                  fromMaybe (error "Corresponding adress meta not found")
                            (M.lookup addr metasAndAdrresses)
          case runExcept $ getSKByAddressPure allSecrets (ShouldCheckPassphrase False) passphrase addrMeta of
              Left err -> throw err
              Right sk -> withSafeSignerUnsafe sk (pure passphrase) pure

    relatedAccount <- getSomeMoneySourceAccount moneySource
    outputs <- coinDistrToOutputs dstDistr
    pendingTxs <- getPendingTxs
    th <- rewrapTxError "Cannot send transaction" $ do
        logDebug "sendMoney: we're to prepareMTx"
        (txAux, inpTxOuts') <-
            prepareMTx pendingTxs getSigner srcAddrs outputs (relatedAccount, passphrase)
        logDebug "sendMoney: performed prepareMTx"

        ts <- Just <$> getCurrentTimestamp
        let tx = taTx txAux
            txHash = hash tx
            inpTxOuts = toList inpTxOuts'
            dstAddrs  = map txOutAddress . toList $
                        _txOutputs tx
            th = THEntry txHash tx Nothing inpTxOuts dstAddrs ts
        ptx <- mkPendingTx srcWallet txHash txAux th

        logDebug "sendMoney: performed mkPendingTx"
        submitAndSaveNewPtx enqueueMsg ptx
        logDebug "sendMoney: submitted and saved tx"

        return th

    addHistoryTx srcWallet th
    diff <- getCurChainDifficulty
    srcWalletAddrsDetector <- getWalletAddrsDetector Ever srcWallet

    logDebug "sendMoney: constructing response"
    fst <$> constructCTx srcWallet srcWalletAddrsDetector diff th
