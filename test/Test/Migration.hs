{- SPDX-FileCopyrightText: 2019 Bitcoin Suisse
 -
 - SPDX-License-Identifier: LicenseRef-MIT-BitcoinSuisse
 -}

-- | General tests on migration machinery, not tied to any contract version.
module Test.Migration
  ( test_ownerCheck
  , test_notMigratingStatus
  , test_migratingStatus
  , test_migratingVersion
  ) where

import Test.Tasty (TestTree, testGroup)
import Util.Named

import qualified Lorentz as L
import Lorentz.Base ((#))
import Lorentz.Coercions (checkedCoerce)
import Lorentz.Contracts.TZBTC as TZBTC
import Lorentz.Contracts.TZBTC.Preprocess
import qualified Lorentz.Contracts.TZBTC.Types as TZBTCTypes
import Lorentz.Contracts.TZBTC.V0 (StoreTemplateV0)
import Lorentz.Contracts.Upgradeable.Common (UContractRouter, mkUContractRouter)
import Lorentz.Instr as Lorentz (drop, nil, pair)
import Lorentz.UParam (mkUParam)
import Lorentz.UStore.Migration
import Morley.Nettest
import Morley.Nettest.Tasty
import Tezos.Address (Address, ta)

import Test.TZBTC (dummyV1Parameters)

{-# ANN module ("HLint: ignore Reduce duplication" :: Text) #-}


-- Test that all administrative endpoints can only be called as owner
test_ownerCheck :: TestTree
test_ownerCheck = testGroup "TZBTC contract migration endpoints test"
  [ nettestScenarioCaps "Test call to administrative endpoints are only available to owner" $ do
      admin <- newAddress "admin"
      bob <- newAddress "bob"
      v0 <- originateSimple "tzbtc" (mkEmptyStorageV0 admin) tzbtcContract
      expectCustomError_ #senderIsNotOwner $ withSender bob $
        call v0 CallDefault $ fromFlatParameter $ EpwBeginUpgrade (#current .! 0, #new .! 1)
  , nettestScenarioCaps "Test call to `ApplyMigration` endpoints are only available to owner" $ do
      admin <- newAddress "admin"
      bob <- newAddress "bob"
      v0 <- originateSimple "tzbtc" (mkEmptyStorageV0 admin) tzbtcContract
      expectCustomError_ #senderIsNotOwner $ withSender bob $
        call v0 CallDefault $ fromFlatParameter $ EpwApplyMigration (checkedCoerce migrationScriptV1)
  , nettestScenarioCaps "Test call to `SetCode` endpoints are only available to owner" $ do
      admin <- newAddress "admin"
      bob <- newAddress "bob"
      v0 <- originateSimple "tzbtc" (mkEmptyStorageV0 admin) tzbtcContract
      expectCustomError_ #senderIsNotOwner $ withSender bob $
        call v0 CallDefault $ fromFlatParameter $ EpwSetCode emptyCode
  , nettestScenarioCaps "Test call to `EpwFinishUpgrade` endpoints are only available to owner" $ do
      admin <- newAddress "admin"
      bob <- newAddress "bob"
      v0 <- originateSimple "tzbtc" (mkEmptyStorageV0 admin) tzbtcContract
      expectCustomError_ #senderIsNotOwner $ withSender bob $
        call v0 CallDefault $ fromFlatParameter $ EpwFinishUpgrade
  ]

-- Test that migration entrypoints check a not migrating status
test_notMigratingStatus :: TestTree
test_notMigratingStatus = testGroup "TZBTC contract migration status not active check"
  [ nettestScenarioCaps "Test call to `ApplyMigration` that require a migrating state fails in non migrating state" $ do
      admin <- newAddress "admin"
      v0 <- originateSimple "tzbtc" (mkEmptyStorageV0 admin) tzbtcContract
      expectCustomError_ #upgContractIsNotMigrating $ withSender admin $
        call v0 CallDefault $ fromFlatParameter $ EpwApplyMigration (checkedCoerce migrationScriptV1)
  , nettestScenarioCaps "Test call to `EpwSetCode` that require a non-migrating state fails in migrating state" $ do
      admin <- newAddress "admin"
      v0 <- originateSimple "tzbtc" (mkEmptyStorageV0 admin) tzbtcContract
      expectCustomError_ #upgContractIsNotMigrating $ withSender admin $
        call v0 CallDefault $ fromFlatParameter $ EpwSetCode emptyCode
  , nettestScenarioCaps "Test call to `EpwFinishUpgrade` that require a non-migrating state fails in migrating state" $ do
      admin <- newAddress "admin"
      v0 <- originateSimple "tzbtc" (mkEmptyStorageV0 admin) tzbtcContract
      expectCustomError_ #upgContractIsNotMigrating $ withSender admin $
        call v0 CallDefault $ fromFlatParameter $ EpwFinishUpgrade
  ]

-- Test that other entrypoints respect migrating status and fail
test_migratingStatus :: TestTree
test_migratingStatus = testGroup "TZBTC contract migration status active check"
  [ nettestScenarioCaps "Test call to `Upgrade` that require a non-migrating state fails in migrating state" $ do
      admin <- newAddress "admin"
      v0 <- originateSimple "tzbtc" (mkEmptyStorageV0 admin) tzbtcContract
      withSender admin $ do
        call v0 CallDefault $ fromFlatParameter $ EpwBeginUpgrade (#current .! 0, #new .! 1)
        expectCustomError_ #upgContractIsMigrating $
          call v0 CallDefault $ fromFlatParameter $ Upgrade upgradeParamsV1
  , nettestScenarioCaps "Test call to `Run` that require a non-migrating state fails in migrating state" $ do
      admin <- newAddress "admin"
      v0 <- originateSimple "tzbtc" (mkEmptyStorageV0 admin) tzbtcContract
      withSender admin $ do
        call v0 CallDefault $ fromFlatParameter $ EpwBeginUpgrade (#current .! 0, #new .! 1)
        expectCustomError_ #upgContractIsMigrating $
          call v0 CallDefault $ fromFlatParameter $ Run $ mkUParam #callBurn (#value .! 100)
  , nettestScenarioCaps "Test call to `Burn` that require a non-migrating state fails in migrating state" $ do
      admin <- newAddress "admin"
      v0 <- originateSimple "tzbtc" (mkEmptyStorageV0 admin) tzbtcContract
      withSender admin $ do
        call v0 CallDefault $ fromFlatParameter $ EpwBeginUpgrade (#current .! 0, #new .! 1)
        expectCustomError_ #upgContractIsMigrating $
          call v0 CallDefault $ fromFlatParameter $ Burn (#value .! 100)
  ]

-- Test that migration bumps version
test_migratingVersion :: TestTree
test_migratingVersion = testGroup "TZBTC contract migration version check"
  -- TODO: use nettestScenarioCaps once cleveland dependency is updated
  [ nettestScenarioOnEmulatorCaps "Test EpwFinishUpgrade bumps version" $ do
      admin <- newAddress "admin"
      v0 <- originateSimple "tzbtc" (mkEmptyStorageV0 admin) tzbtcContract
      withSender admin $ do
        call v0 CallDefault $ fromFlatParameter $ EpwBeginUpgrade (#current .! 0, #new .! 1)
        call v0 CallDefault $ fromFlatParameter EpwFinishUpgrade
      storage <- getFullStorage v0
      assert ((TZBTCTypes.currentVersion . TZBTCTypes.fields) storage == 1)
        "Version was not updated"
  ]

upgradeParamsV1 :: OneShotUpgradeParameters TZBTCv0
upgradeParamsV1 = upgradeParametersV1 v1Parameters

-- Some constants
migrationScriptV1 :: MigrationScript StoreTemplateV0 StoreTemplateV1
migrationScriptV1 =
  manualConcatMigrationScripts $ migrationScriptsV1 v1Parameters

emptyCode :: UContractRouter ver
emptyCode = mkUContractRouter (Lorentz.drop # nil # pair)

redeemAddress_ :: Address
redeemAddress_ = [ta|tz1Mdd7rL6jGFAWCMUqatQ64K9pTpe8kazfy|]

v1Parameters :: V1Parameters
v1Parameters = dummyV1Parameters redeemAddress_ mempty
