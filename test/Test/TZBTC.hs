{- SPDX-FileCopyrightText: 2019 Bitcoin Suisse
 -
 - SPDX-License-Identifier: LicenseRef-Proprietary
 -}
module Test.TZBTC
  ( test_acceptOwnership
  , test_addOperator
  , test_adminCheck
  , test_burn
  , test_migration
  , test_migrationManager
  , test_mint
  , test_approvableLedger
  , test_pause
  , test_removeOperator
  , test_setRedeemAddress
  , test_transferOwnership
  , test_unpause_
  , test_bookkeeping
  ) where

import Fmt (pretty)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, assertBool, assertFailure, testCase)
import Test.Tasty.Hspec (testSpec)
import qualified Data.Map as Map
import Data.Set
import Data.Singletons (SingI(..))
import qualified Data.Set as Set
import Named (arg)

import Lorentz
import Lorentz.Contracts.Consumer
import Lorentz.Contracts.TZBTC
import qualified Lorentz.Contracts.TZBTC.Agent as Agent
import Lorentz.Contracts.TZBTC.Types
import Lorentz.Test.Integrational
import Michelson.Interpret (ContractEnv(..), MichelsonFailed(..))
import Michelson.Test
  ( ContractPropValidator, contractProp, dummyContractEnv)
import Michelson.Text (mt)
import Michelson.Typed (Instr, InstrWrapC, AppendCtorField, GetCtorField, ToTs, Value, Value'(..))
import Michelson.Typed.Scope (checkOpPresence, OpPresence(..))
import Lorentz.Contracts.ManagedLedger.Proxy (SaneParameter (..))
import Lorentz.Contracts.ManagedLedger.Test (ApprovableLedger(..), approvableLedgerSpec, originateManagedLedger)
import Util.Named

lContract :: Instr (ToTs '[(Parameter, Storage)]) (ToTs (ContractOut Storage))
lContract = (unI tzbtcContract)

newOperatorAddress :: Address
newOperatorAddress = genesisAddress1

adminAddress :: Address
adminAddress = genesisAddress3

redeemAddress_ :: Address
redeemAddress_ = adminAddress

replaceAddress :: Address
replaceAddress = genesisAddress2

contractAddress :: Address
contractAddress = genesisAddress4

alice :: Address
alice = genesisAddress6

bob :: Address
bob = genesisAddress5

initialSupply :: Natural
initialSupply = 500

storage :: Storage
storage =
  mkStorage adminAddress redeemAddress_
    (Map.fromList [(redeemAddress_, initialSupply)]) mempty

contractPropWithSender
  :: Address
  -> ContractPropValidator (ToT Storage) prop
  -> Parameter
  -> Storage
  -> prop
contractPropWithSender address_ check param initSt =
  contractProp lContract check
    (dummyContractEnv { ceSender = address_ })
    param
    initSt

assertFailureMessage
  :: Either MichelsonFailed ([Operation], Value (ToT Storage))
  -> MText
  -> String
  -> Assertion
assertFailureMessage res msg tstMsg = case res of
  Right (_, _) ->
    assertFailure "Contract did not fail as expected"
  Left err -> case err of
    MichelsonFailedWith (VPair ((VC (CvString t)), _)) -> do
      assertEqual tstMsg msg t
    a -> assertFailure $ "Unexpected contract failure: " <> pretty a

test_approvableLedger :: IO TestTree
test_approvableLedger = testSpec "TZBTC contract approvable ledger tests" $
  approvableLedgerSpec $ ApprovableLedger
    { alOriginate = originateAl
    , alMkParam = toTZBTCParameter
    }
  where
    originateAl :: Address -> Natural -> IntegrationalScenarioM (ContractAddr Parameter)
    originateAl admin_ balance_ =
      originateManagedLedger mkStorage' tzbtcContract admin_ balance_
    mkStorage' admin_ balance_ =
      mkStorage admin_ admin_ balance_ mempty

    toTZBTCParameter :: SaneParameter -> Parameter
    toTZBTCParameter =
      \case
        STransfer tp -> EntrypointsWithoutView $ Transfer tp
        SApprove app -> EntrypointsWithoutView $ Approve app
        SGetAllowance v ->
          EntrypointsWithView $ GetAllowance v
        SGetTotalSupply v ->
          EntrypointsWithView $ GetTotalSupply v
        SGetBalance v ->
          EntrypointsWithView $ GetBalance v

test_adminCheck :: TestTree
test_adminCheck = testGroup "TZBTC contract admin check test"
  [ testCase "Fails with `SenderNotAdmin` if sender is not administrator for `addOperator` call" $
      contractPropWithSender bob validate'
        (EntrypointsWithoutView $
         AddOperator (#operator .! newOperatorAddress)) storage
  , testCase
      "Fails with `SenderNotAdmin` if sender is not administrator for `removeOperator` call" $
      contractPropWithSender bob validate'
        (EntrypointsWithoutView $
         RemoveOperator (#operator .! newOperatorAddress)) storage
  , testCase
      "Fails with `SenderNotAdmin` if sender is not administrator for `startMigrateFrom` call" $
      contractPropWithSender bob validate'
        (EntrypointsWithoutView $
         StartMigrateFrom (#migrationManager .! contractAddress)) storage
  , testCase
      "Fails with `SenderNotAdmin` if sender is not administrator for `transferOwnership` call" $
      contractPropWithSender bob validate'
        (EntrypointsWithoutView $
         TransferOwnership (#newOwner .! adminAddress)) storage
  , testCase
      "Fails with `SenderNotAdmin` if sender is not administrator for `setRedeemAddress` call" $
      contractPropWithSender bob validate'
        (EntrypointsWithoutView $
         SetRedeemAddress (#redeem .! redeemAddress_)) storage
  ]
  where
    validate' :: ContractPropValidator (ToT Storage) Assertion
    validate' (res, _) =
      assertFailureMessage
        res [mt|SenderIsNotAdmin|]
        "Contract did not fail with 'SenderIsNotAdmin' message"

test_addOperator :: TestTree
test_addOperator = testGroup "TZBTC contract `addOperator` test"
  [ testCase
      "Call to `addOperator` Adds new operator to the set of operators" $
      contractPropWithSender adminAddress
        validateAdd (EntrypointsWithoutView $
                     AddOperator (#operator .! newOperatorAddress)) storage
  ]
  where
    validateAdd :: ContractPropValidator (ToT Storage) Assertion
    validateAdd (res, _) =
      case res of
        Left err -> assertFailure $ "Unexpected contract failure: " <> pretty err
        Right (_operations, storage_) ->
          assertBool "Contract did not add operator address to the set" $
            member newOperatorAddress ((operators.fields) $ fromVal storage_)

test_removeOperator :: TestTree
test_removeOperator = testGroup "TZBTC contract `removeOperator` test"
  [ testCase
      "Call to `removeOperator` removes operator from the set of operators" $
      contractPropWithSender adminAddress
        validateRemove
        (EntrypointsWithoutView $
         RemoveOperator (#operator .! operatorToRemove)) storageWithOperator
  ]
  where
    operatorToRemove = replaceAddress
    storageWithOperator =
      mkStorage adminAddress redeemAddress_
        mempty (Set.fromList [operatorToRemove])
    validateRemove :: ContractPropValidator (ToT Storage) Assertion
    validateRemove (res, _) =
      case res of
        Left err -> assertFailure $ "Unexpected contract failure: " <> pretty err
        Right (_operations, storage_) ->
          assertBool "Contract did note remove operator address from the set" $
            Prelude.not $ member operatorToRemove ((operators.fields) $ fromVal storage_)

test_setRedeemAddress :: TestTree
test_setRedeemAddress = testGroup "TZBTC contract `setRedeemAddress` test"
  [ testCase
      "Call to `setRedeemAddress` updates redeemAddress" $
      contractPropWithSender adminAddress
        validate_ (EntrypointsWithoutView $
                   SetRedeemAddress (#redeem .! newRedeemAddress)) storage
  ]
  where
    newRedeemAddress = replaceAddress
    validate_ :: ContractPropValidator (ToT Storage) Assertion
    validate_ (res, _) =
      case res of
        Left err -> assertFailure $ "Unexpected contract failure: " <> pretty err
        Right (_operations, rstorage) ->
          assertEqual
            "Contract did set redeem address to expected value"
            newRedeemAddress
            ((redeemAddress.fields) $ fromVal rstorage)

test_transferOwnership :: TestTree
test_transferOwnership = testGroup "TZBTC contract `transferOwnership` test"
  [ testCase
      "Call to `transferOwnership` updates `newOwner`" $
      contractPropWithSender adminAddress
        validate_ (EntrypointsWithoutView $
                   TransferOwnership (#newOwner .! newOwnerAddress)) storage
  ]
  where
    newOwnerAddress = replaceAddress
    validate_ :: ContractPropValidator (ToT Storage) Assertion
    validate_ (res, _) =
      case res of
        Left err -> assertFailure $ "Unexpected contract failure: " <> pretty err
        Right (_operations, rstorage) ->
          assertEqual
            "Contract did not set newOwner field to the expected value"
            (Just newOwnerAddress)
            ((newOwner.fields) $ fromVal rstorage)

test_acceptOwnership :: TestTree
test_acceptOwnership = testGroup "TZBTC contract `acceptOwnership` test"
  [ testCase
      "Call to `acceptOwnership` get denied on contract that is not in transfer mode" $
      contractPropWithSender newOwnerAddress
        validateNotInTransfer (EntrypointsWithoutView $
                               AcceptOwnership ()) storage
  , testCase
      "Call to `acceptOwnership` fails for random caller" $
      contractPropWithSender badSenderAddress
        validateBadSender (EntrypointsWithoutView $
                           AcceptOwnership ()) storageInTranferOwnership
  , testCase
      "Call to `acceptOwnership` fails for current admin" $
      contractPropWithSender adminAddress
        validateBadSender (EntrypointsWithoutView $
                           AcceptOwnership ()) storageInTranferOwnership
  , testCase
      "Call to `acceptOwnership` updates admin with address of new owner \
      \and resets `newOwner` field" $
      contractPropWithSender newOwnerAddress
        validateGoodOwner (EntrypointsWithoutView $
                           AcceptOwnership ()) storageInTranferOwnership
  ]
  where
    newOwnerAddress = replaceAddress
    badSenderAddress = bob
    storageInTranferOwnership = let
      f = fields storage
      in storage { fields = f { newOwner = Just newOwnerAddress } }

    validateNotInTransfer :: ContractPropValidator (ToT Storage) Assertion
    validateNotInTransfer (res, _) =
      assertFailureMessage
        res [mt|NotInTransferOwnershipMode|]
          "Contract did not fail with 'NotInTransferOwnershipMode' message"

    validateBadSender :: ContractPropValidator (ToT Storage) Assertion
    validateBadSender (res, _) =
      assertFailureMessage
        res [mt|SenderIsNotNewOwner|]
          "Contract did not fail with 'SenderIsNotNewOwner' message"

    validateGoodOwner :: ContractPropValidator (ToT Storage) Assertion
    validateGoodOwner (res, _) =
      case res of
        Left err -> assertFailure $ "Unexpected contract failure: " <> pretty err
        Right (_operations, rstorage) -> do
          assertEqual
            "Contract did not set admin to the address from newOwner field"
             newOwnerAddress
             ((admin.fields) $ fromVal rstorage)
          assertEqual
            "Contract did not set newOwner field to None"
             Nothing
             ((newOwner.fields) $ fromVal rstorage)

test_burn :: TestTree
test_burn = testGroup "TZBTC contract `burn` test"
  [ testCase
      "Call to `burn` from admin gets denied with `SenderIsNotOperator`" $
      contractPropWithSender adminAddress
        validateFail_ (EntrypointsWithoutView $
                       Burn (#value .! 100)) storageWithOperator
  , testCase
      "Call to `burn` from random address gets denied with `SenderIsNotOperator`" $
      contractPropWithSender bob
        validateFail_ (EntrypointsWithoutView $
                       Burn (#value .! 100)) storageWithOperator

  , testCase
      "Call to `burn` from operator, burns from `redeemAddress` and update `totalBurned` \
      \ and `totalSupply` fields correctly" $
      contractPropWithSender newOperatorAddress
        validate_ (EntrypointsWithoutView $
                   Burn (#value .! 100)) storageWithOperator
  ]
  where
    storageWithOperator =
      mkStorage adminAddress redeemAddress_
        (Map.fromList [(redeemAddress_, initialSupply)])
          (Set.fromList [newOperatorAddress])
    validateFail_ :: ContractPropValidator (ToT Storage) Assertion
    validateFail_ (res, _) =
      assertFailureMessage
        res [mt|SenderIsNotOperator|]
          "Contract did not fail with 'SenderIsNotOperator' message"

    validate_ :: ContractPropValidator (ToT Storage) Assertion
    validate_ (res, _) =
      case res of
        Left err -> assertFailure $ "Unexpected contract failure: " <> pretty err
        Right (_operations, rstorage) -> do
          assertEqual
            "Contract's `burn` operation reduced the balance in redeem address by expected amount"
             (Just 400  :: Maybe Natural)
             (((arg #balance) . fst)
                <$> (Map.lookup redeemAddress_ $ unBigMap $
                  ledger $ (fromVal rstorage :: Storage)))
          assertEqual
            "Contract's `burn` operation did not update `totalBurned` field correctly."
             100
             (totalBurned $ fields $ (fromVal rstorage :: Storage))
          assertEqual
            "Contract's `burn` operation did not update `totalSupply` field correctly"
             400
             (totalSupply $ fields $ (fromVal rstorage :: Storage))

test_mint :: TestTree
test_mint = testGroup "TZBTC contract `mint` test"
  [ testCase
      "Call to `mint` from admin gets denied with `SenderIsNotOperator`" $
      contractPropWithSender adminAddress
        validateFail_ (EntrypointsWithoutView $
                       Burn (#value .! 100)) storageWithOperator
  , testCase
      "Call to `mint` from random address gets denied with `SenderIsNotOperator`" $
      contractPropWithSender bob
        validateFail_ (EntrypointsWithoutView $
                       Burn (#value .! 100)) storageWithOperator
  , testCase
      "Call to `mint` adds value to `to` parameter in input and update `totalMinted` \
      \ and `totalSupply` fields correctly" $
      contractPropWithSender newOperatorAddress
        validate_ (EntrypointsWithoutView $
                   Mint (#to .! alice, #value .! 200)) storageWithOperator
  ]
  where
    storageWithOperator =
      mkStorage adminAddress redeemAddress_
        (Map.fromList [(redeemAddress_, initialSupply)])
        (Set.fromList [newOperatorAddress])
    validateFail_ :: ContractPropValidator (ToT Storage) Assertion
    validateFail_ (res, _) =
      assertFailureMessage
        res [mt|SenderIsNotOperator|]
          "Contract did not fail with 'SenderIsNotOperator' message"

    validate_ :: ContractPropValidator (ToT Storage) Assertion
    validate_ (res, _) =
      case res of
        Left err -> assertFailure $ "Unexpected contract failure: " <> pretty err
        Right (_operations, rstorage) -> do
          assertEqual
            "Contract's `mint` operation credited the target account with the  expected amount"
             (Just 200  :: Maybe Natural)
             (((arg #balance) . fst)
                <$> (Map.lookup alice $ unBigMap $
                  ledger $ (fromVal rstorage :: Storage)))
          assertEqual
            "Contract's `mint` operation did not update `totalMinted` field correctly."
             700
             (totalMinted $ fields $ (fromVal rstorage :: Storage))
          assertEqual
            "Contract's `mint` operation did not update `totalSupply` field correctly"
             700
             (totalSupply $ fields $ (fromVal rstorage :: Storage))

test_pause :: TestTree
test_pause = testGroup "TZBTC contract `pause` permission test"
  [ testCase
      "Call to `pause` from admin gets denied with `SenderIsNotOperator`" $
      contractPropWithSender adminAddress
        validateFail_ (EntrypointsWithoutView $ Pause ()) storageWithOperator
  , testCase
      "Call to `pause` from random address gets denied with `SenderIsNotOperator`" $
      contractPropWithSender bob
        validateFail_ (EntrypointsWithoutView $ Pause ()) storageWithOperator
  , testCase
      "Call to `pause` as operator is allowed" $
      contractPropWithSender newOperatorAddress
        validate_ (EntrypointsWithoutView $ Pause ()) storageWithOperator
  , testCase
      "Call to `transfer` in a paused contract is denied" $
      integrationalTestExpectation $ do
        c <- lOriginate tzbtcContract "TZBTC Contract" storageWithOperator (toMutez 1000)
        -- Mint some coins for alice.
        withSender newOperatorAddress $ lCall c (EntrypointsWithoutView $ Mint (#to .! alice, #value .! 200))
        -- Pause the contract
        withSender newOperatorAddress $ lCall c (EntrypointsWithoutView $ Pause ())
        -- Alice attempts to transfer to bob
        withSender alice $
          lCall c (EntrypointsWithoutView $ Transfer ((#from .! alice, #to .! bob, #value .! 100)))
        validate . Left $
          lExpectCustomError_ #tokenOperationsArePaused
  ]
  where
    storageWithOperator =
      mkStorage adminAddress redeemAddress_
        (Map.fromList [(redeemAddress_, initialSupply)])
        (Set.fromList [newOperatorAddress])
    validateFail_ :: ContractPropValidator (ToT Storage) Assertion
    validateFail_ (res, _) =
      assertFailureMessage
        res [mt|SenderIsNotOperator|]
          "Contract did not fail with 'SenderIsNotOperator' message"

    validate_ :: ContractPropValidator (ToT Storage) Assertion
    validate_ (res, _) =
      case res of
        Left err -> assertFailure $ "Unexpected contract failure: " <> pretty err
        Right (_operations, rstorage) ->
          assertEqual
            "Contract's `pause` operation executed with out error"
             True
             (paused $ fields $ (fromVal rstorage :: Storage))

test_unpause_ :: TestTree
test_unpause_ = testGroup "TZBTC contract `unpause` permission test"
  [ testCase
      "Call to `unpause` as operator gets denied with `SenderIsNotAdmin`" $
      contractPropWithSender newOperatorAddress
        validateFail_ (EntrypointsWithoutView $ Unpause ()) storageWithOperator
  , testCase
      "Call to `unpause` from random address gets denied with `SenderIsNotAdmin`" $
      contractPropWithSender bob
        validateFail_ (EntrypointsWithoutView $ Unpause ()) storageWithOperator
  , testCase
      "Call to `unpause` as admin is allowed" $
      contractPropWithSender adminAddress
        validate_ (EntrypointsWithoutView $ Unpause ()) storageWithOperator
  ]
  where
    storageWithOperator =
      mkStorage adminAddress redeemAddress_
        (Map.fromList [(redeemAddress_, initialSupply)])
        (Set.fromList [newOperatorAddress])
    validateFail_ :: ContractPropValidator (ToT Storage) Assertion
    validateFail_ (res, _) =
      assertFailureMessage
        res [mt|SenderIsNotAdmin|]
        "Contract did not fail with 'SenderIsNotAdmin' message"

    validate_ :: ContractPropValidator (ToT Storage) Assertion
    validate_ (res, _) =
      case res of
        Left err -> assertFailure $ "Unexpected contract failure: " <> pretty err
        Right (_operations, rstorage) ->
          assertEqual
            "Contract's `unpause` operation executed with out error"
             False
             (paused $ fields $ (fromVal rstorage :: Storage))

test_bookkeeping :: TestTree
test_bookkeeping = testGroup "TZBTC contract bookkeeping views test"
  [ testCase
      "calling book keeping views returns expected result" $
        integrationalTestExpectation $ do
          v1 <- originateContract
          consumer <- lOriginateEmpty contractConsumer "consumer"
          withSender newOperatorAddress $ do
            -- Mint and burn some tokens
            lCall v1 (EntrypointsWithoutView $ Mint (#to .! alice, #value .! 130))
            lCall v1 (EntrypointsWithoutView $ Burn (#value .! 20))
          lCall v1 $ EntrypointsWithView $ GetTotalSupply (View () consumer)
          lCall v1 $ EntrypointsWithView $ GetTotalMinted (View () consumer)
          lCall v1 $ EntrypointsWithView $ GetTotalBurned (View () consumer)
          -- Check expectations
          validate . Right $
            lExpectViewConsumerStorage consumer [610, 630, 20]
  ]
  where
    originateContract :: IntegrationalScenarioM (ContractAddr Parameter)
    originateContract =
      lOriginate tzbtcContract "TZBTC Contract" st (toMutez 1000)
    st :: Storage
    st = mkStorage adminAddress redeemAddress_
        (Map.fromList [(redeemAddress_, initialSupply)]) (Set.fromList [newOperatorAddress])

-- Migration tests

storageV1 :: Storage
storageV1 =
  mkStorage adminAddress redeemAddress_
    (Map.fromList [(alice, initialSupply)])
          (Set.fromList [newOperatorAddress])

storageV2 :: Storage
storageV2 =
  mkStorage adminAddress redeemAddress_ mempty mempty

originateV1 :: IntegrationalScenarioM (ContractAddr Parameter)
originateV1 =
  lOriginate tzbtcContract "UserUpgradeable V1" storageV1 (toMutez 1000)

originateV2 :: IntegrationalScenarioM (ContractAddr Parameter)
originateV2 =
  lOriginate tzbtcContract "UserUpgradeable V2" storageV2 (toMutez 1000)

originateAgent
  :: forall v2.
  ( InstrWrapC v2 "cMintForMigration"
  , AppendCtorField
      (GetCtorField v2 "cMintForMigration")
      '[] ~ '[("to" :! Address, "value" :! Natural)]
  , KnownValue v2, NoOperation v2, NoBigMap v2)
  => Address
  -> ContractAddr v2
  -> IntegrationalScenarioM Address
originateAgent oldContract newContract =
  case checkOpPresence (sing @(ToT v2)) of
    OpAbsent ->
      unContractAddress <$>
        lOriginate (Agent.agentContract @v2)
        "Migration Agent" agentStorage (toMutez 1000)
    OpPresent ->
      error "Cannot originate contract with operations in parameter"
    where
      agentStorage = Agent.StorageFields
        { oldVersion = oldContract
        , newVersion = newContract
        }

test_migration :: TestTree
test_migration = testGroup "TZBTC contract migration tests"
  [ testCase
      "call `migrate` to unprepared contract is denied" $
        integrationalTestExpectation $ do
          v1 <- originateV1
          withSender alice $ lCall v1 (EntrypointsWithoutView $ Migrate ())
          validate . Left $
            lExpectCustomError_ #migrationNotEnabled
  , testCase
      "call to `migrate` from an empty accounts address fails" $
        integrationalTestExpectation $ do
          v1 <- originateV1
          v2 <- originateV2
          agent <- originateAgent (unContractAddress v1) v2
          withSender newOperatorAddress $ lCall v1 (EntrypointsWithoutView $ Pause ())
          withSender adminAddress $ do
            lCall v1 (EntrypointsWithoutView $
                      StartMigrateTo (#migrationManager .! agent) )
            lCall v1 (EntrypointsWithoutView $ Unpause ())
          withSender bob $ lCall v1 (EntrypointsWithoutView $ Migrate ())
          validate . Left $
            lExpectCustomError_ #noBalanceToMigrate
 , testCase
     "call `startMigrateTo` to from non admin address fails" $
       integrationalTestExpectation $ do
         v1 <- originateV1
         v2 <- originateV2
         agent <- originateAgent (unContractAddress v1) v2
         withSender newOperatorAddress $ lCall v1 (EntrypointsWithoutView $ Pause ())
         withSender bob $ lCall v1 (EntrypointsWithoutView $
                                    StartMigrateTo $ (#migrationManager .! agent))
         withSender adminAddress $ lCall v1 (EntrypointsWithoutView $ Unpause ())
         validate . Left $
           lExpectCustomError_ #senderIsNotAdmin
 , testCase
     "call `startMigrateFrom` to from non admin address fails" $
       integrationalTestExpectation $ do
         v1 <- originateV1
         v2 <- originateV2
         agent <- originateAgent (unContractAddress v1) v2
         withSender bob $ lCall v2 (EntrypointsWithoutView $
                                    StartMigrateFrom $ (#migrationManager .! agent))
         validate . Left $
           lExpectCustomError_ #senderIsNotAdmin
 , testCase
     "call `startMigrateTo` from admin saves the address of migration manager proxy" $
       integrationalTestExpectation $ do
         v1 <- originateV1
         v2 <- originateV2
         agent <- originateAgent (unContractAddress v1) v2
         withSender newOperatorAddress $ lCall v1 (EntrypointsWithoutView $ Pause ())
         withSender adminAddress $ do
           lCall v1 (EntrypointsWithoutView $
                     StartMigrateTo $ (#migrationManager .! agent))
           lCall v1 (EntrypointsWithoutView $ Unpause ())
         validate . Right $
           lExpectStorageConst v1 $ let
            oldFields = fields storageV1
            in storageV1
              { fields = oldFields { migrationManagerOut = Just agent }}
 , testCase
     "call `startMigrateTo` to unpaused contract is denied with `ContractIsNotPaused` error" $
       integrationalTestExpectation $ do
         v1 <- originateV1
         v2 <- originateV2
         agent <- originateAgent (unContractAddress v1) v2
         withSender adminAddress $ lCall v1 (EntrypointsWithoutView $
                                             StartMigrateTo $ (#migrationManager .! agent))
         validate . Left $
           lExpectCustomError_ #tokenOperationsAreNotPaused
 , testCase
     "multple calls `startMigrateTo` from admin stores the address of the last call" $
       integrationalTestExpectation $ do
         v1 <- originateV1
         v2 <- originateV2
         agent <- originateAgent (unContractAddress v2) v1
         agent2 <- originateAgent (unContractAddress v1) v2
         withSender newOperatorAddress $ lCall v1 (EntrypointsWithoutView $ Pause ())
         withSender adminAddress $ do
           lCall v1 (EntrypointsWithoutView $
                     StartMigrateTo $ (#migrationManager .! agent))
           lCall v1 (EntrypointsWithoutView $ StartMigrateTo $
                     (#migrationManager .! agent2))
           lCall v1 (EntrypointsWithoutView $ Unpause ())
         validate . Right $
           lExpectStorageConst v1 $ let
            oldFields = fields storageV1
            in storageV1
              { fields = oldFields { migrationManagerOut = Just agent2 }}
 , testCase
     "call `startMigrateFrom` from admin saves the address of migration agent proxy" $
       integrationalTestExpectation $ do
         v1 <- originateV1
         v2 <- originateV2
         agent <- originateAgent (unContractAddress v1) v2
         withSender adminAddress $ lCall v2 (EntrypointsWithoutView $
                                             StartMigrateFrom $ (#migrationManager .! agent))
         validate . Right $
           lExpectStorageConst v2 $ let
            oldFields = fields storageV2
            in storageV2
              { fields = oldFields { migrationManagerIn = Just agent }}
 , testCase
     "multiple calls to `startMigrateFrom` from admin saves the address from the last call" $
       integrationalTestExpectation $ do
         v1 <- originateV1
         v2 <- originateV2
         agent <- originateAgent (unContractAddress v2) v1
         agent2 <- originateAgent (unContractAddress v1) v2
         withSender adminAddress $ do
           lCall v2 (EntrypointsWithoutView $
                     StartMigrateFrom $ (#migrationManager .! agent))
           lCall v2 (EntrypointsWithoutView $
                     StartMigrateFrom $ (#migrationManager .! agent2))
         validate . Right $
           lExpectStorageConst v2 $ let
            oldFields = fields storageV2
            in storageV2
              { fields = oldFields { migrationManagerIn = Just agent2 }}
 , testCase
     "call `mintForMigration` from random address to new contract is denied" $
       integrationalTestExpectation $ do
         v1 <- originateV1
         v2 <- originateV2
         agent <- originateAgent (unContractAddress v1) v2
         withSender adminAddress $ lCall v2 (EntrypointsWithoutView $
                                             StartMigrateFrom $ (#migrationManager .! agent))
         withSender bob $ lCall v2 (EntrypointsWithoutView $
                                    MintForMigration $ (#to .! alice, #value .! 100))
         validate . Left $
           lExpectCustomError_ #senderIsNotAgent

 , testCase
     "call `mintForMigration` from agent address to new contract mints tokens" $
       integrationalTestExpectation $ do
         v1 <- originateV1
         v2 <- originateV2
         agent <- originateAgent (unContractAddress v1) v2
         withSender adminAddress $ lCall v2 (EntrypointsWithoutView $
                                             StartMigrateFrom $ (#migrationManager .! agent))
         withSender agent $ lCall v2 (EntrypointsWithoutView $
                                      MintForMigration $ (#to .! alice, #value .! 250))
         consumer <- lOriginateEmpty contractConsumer "consumer"
         lCall v2 $ EntrypointsWithView $ GetBalance (View alice consumer)
         validate . Right $
           lExpectViewConsumerStorage consumer [250]
 , testCase
     "call `mintForMigration` to contract that does not have migration agent set is denied" $
       integrationalTestExpectation $ do
         v2 <- originateV2
         withSender bob $ lCall v2 (EntrypointsWithoutView $
                                    MintForMigration $ (#to .! alice, #value .! 100))
         validate . Left $
           lExpectCustomError_ #migrationNotEnabled
  ]

test_migrationManager :: TestTree
test_migrationManager = testGroup "TZBTC migration manager tests"
  [ testCase
      "migration manager stores addesses of both old and new contracts" $
        integrationalTestExpectation $ do
          v1 <- originateV1
          v2 <- originateV2
          agent <- originateAgent (unContractAddress v1) v2
          validate . Right $
            lExpectStorageConst (ContractAddr agent) $
              Agent.StorageFields
                { oldVersion = unContractAddress v1
                , newVersion = v2
                }
  , testCase
      "calling migration manager from random address is denied" $
        integrationalTestExpectation $ do
          v1 <- originateV1
          v2 <- originateV2
          agent <- originateAgent (unContractAddress v1) v2
          withSender bob $ lCall (ContractAddr @Agent.Parameter agent) (alice, 100)
          validate . Left $
            lExpectCustomError_ #migrationBadOrigin
  , testCase
      "calling migrate on old version burns tokens in old version and mint them in new" $
        integrationalTestExpectation $ do
          v1 <- originateV1
          v2 <- originateV2
          agent <- originateAgent (unContractAddress v1) v2
          consumer <- lOriginateEmpty contractConsumer "consumer"
          withSender newOperatorAddress $ lCall v1 (EntrypointsWithoutView $ Pause ())
          withSender adminAddress $ do
            lCall v1 (EntrypointsWithoutView $
                      StartMigrateTo $ (#migrationManager .! agent))
            lCall v2 (EntrypointsWithoutView $
                      StartMigrateFrom $ (#migrationManager .! agent))
            lCall v1 (EntrypointsWithoutView $ Unpause ())
          lCall v1 $ EntrypointsWithView $ GetBalance (View alice consumer)
          lCall v2 $ EntrypointsWithView $ GetBalance (View alice consumer)
          withSender alice $ lCall v1 (EntrypointsWithoutView $ Migrate ())
          lCall v1 $ EntrypointsWithView $ GetBalance (View alice consumer)
          lCall v2 $ EntrypointsWithView $ GetBalance (View alice consumer)
          validate . Right $
            lExpectViewConsumerStorage consumer [500, 0, 0, 500]
  , testCase
      "calling migrate on paused contract fails with `OperationsArePaused` error" $
        integrationalTestExpectation $ do
          v1 <- originateV1
          v2 <- originateV2
          agent <- originateAgent (unContractAddress v1) v2
          withSender newOperatorAddress $ do
            lCall v1 (EntrypointsWithoutView $ Pause ())
          withSender adminAddress $ do
            lCall v1 (EntrypointsWithoutView $
                      StartMigrateTo $ (#migrationManager .! agent))
            lCall v2 (EntrypointsWithoutView $
                      StartMigrateFrom $ (#migrationManager .! agent))
          withSender alice $ lCall v1 (EntrypointsWithoutView $
                                       Migrate ())
          validate . Left $
            lExpectCustomError_ #tokenOperationsArePaused
  ]
