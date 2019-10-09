{- SPDX-FileCopyrightText: 2019 Bitcoin Suisse
 -
 - SPDX-License-Identifier: LicenseRef-Proprietary
 -}
module Client.Types
  ( ClientConfigP (..)
  , ClientConfig
  , ClientConfigPartial
  , ForgeOperation (..)
  , InternalOperation (..)
  , MichelsonExpression (..)
  , OperationContent (..)
  , ParametersInternal (..)
  , Partial (..)
  , RunError (..)
  , RunMetadata (..)
  , RunOperation (..)
  , RunOperationInternal (..)
  , RunOperationResult (..)
  , RunRes (..)
  , TransactionOperation (..)
  , combineResults
  , partialParser
  , toConfigFilled
  , isAvailable
  , withDefault
  ) where

import Data.Aeson (FromJSON(..), ToJSON(..), object, withObject, genericParseJSON, genericToJSON, (.=), (.:), (.:?), (.!=))
import Data.Aeson.Casing (aesonPrefix, snakeCase)
import Data.Aeson.TH (deriveJSON)
import Data.List (isSuffixOf)
import Data.Text as T (isPrefixOf)
import Fmt (Buildable(..), (+|), (|+))
import GHC.TypeLits
import Options.Applicative
import Tezos.Base16ByteString (Base16ByteString(..))
import Tezos.Micheline
  (Expression(..), MichelinePrimAp(..), MichelinePrimitive(..))
import Tezos.Json (TezosWord64(..))

import Tezos.Address (Address)
import Tezos.Crypto (Signature, encodeBase58Check)

newtype MichelsonExpression = MichelsonExpression Expression
  deriving newtype FromJSON

instance Buildable MichelsonExpression where
  build (MichelsonExpression expr) = case expr of
    Expression_Int i -> build $ unTezosWord64 i
    Expression_String s -> build s
    Expression_Bytes b ->
      build $ encodeBase58Check $ unbase16ByteString b
    Expression_Seq s -> "(" +| buildSeq s |+ ")"
    Expression_Prim (MichelinePrimAp (MichelinePrimitive text) s) ->
      text <> " " |+ "(" +|
      buildSeq s +| ")"
    where
      buildSeq =
        mconcat . intersperse ", " . map
        (build . MichelsonExpression) . toList

data ForgeOperation = ForgeOperation
  { foBranch :: Text
  , foContents :: [TransactionOperation]
  }

instance ToJSON ForgeOperation where
  toJSON ForgeOperation{..} = object
    [ "branch" .= toString foBranch
    , "contents" .= toJSON foContents
    ]

data RunOperationInternal = RunOperationInternal
  { roiBranch :: Text
  , roiContents :: [TransactionOperation]
  , roiSignature :: Signature
  }

data RunOperation = RunOperation
  { roOperation :: RunOperationInternal
  , roChainId :: Text
  }

data RunRes = RunRes
  { rrOperationContents :: [OperationContent]
  }

instance FromJSON RunRes where
  parseJSON = withObject "preApplyRes" $ \o ->
    RunRes <$> o .: "contents"

data OperationContent = OperationContent RunMetadata

instance FromJSON OperationContent where
  parseJSON = withObject "operationCostContent" $ \o ->
    OperationContent <$> o .: "metadata"

data RunMetadata = RunMetadata
  { rmOperationResult :: RunOperationResult
  , rmInternalOperationResults :: [InternalOperation]
  }

instance FromJSON RunMetadata where
  parseJSON = withObject "metadata" $ \o ->
    RunMetadata <$> o .: "operation_result" <*>
    o .:? "internal_operation_results" .!= []

newtype InternalOperation = InternalOperation
  { unInternalOperation :: RunOperationResult }

instance FromJSON InternalOperation where
  parseJSON = withObject "internal_operation" $ \o ->
    InternalOperation <$> o .: "result"

data RunError
  = RuntimeError Address
  | ScriptRejected MichelsonExpression
  | BadContractParameter Address
  | InvalidConstant MichelsonExpression MichelsonExpression
  | InconsistentTypes MichelsonExpression MichelsonExpression
  | InvalidPrimitive [Text] Text
  | InvalidSyntacticConstantError MichelsonExpression MichelsonExpression
  | UnexpectedContract

instance FromJSON RunError where
  parseJSON = withObject "preapply error" $ \o -> do
    id' <- o .: "id"
    case id' of
      x | "runtime_error" `isSuffixOf` x ->
          RuntimeError <$> o .: "contract_handle"
      x | "script_rejected" `isSuffixOf` x ->
          ScriptRejected <$> o .: "with"
      x | "bad_contract_parameter" `isSuffixOf` x ->
          BadContractParameter <$> o .: "contract"
      x | "invalid_constant" `isSuffixOf` x ->
          InvalidConstant <$> o .: "expected_type" <*> o .: "wrong_expression"
      x | "inconsistent_types" `isSuffixOf` x ->
          InconsistentTypes <$> o .: "first_type" <*> o .: "other_type"
      x | "invalid_primitive" `isSuffixOf` x ->
          InvalidPrimitive <$> o .: "expected_primitive_names" <*> o .: "wrong_primitive_name"
      x | "invalidSyntacticConstantError" `isSuffixOf` x ->
          InvalidSyntacticConstantError <$> o .: "expectedForm" <*> o .: "wrongExpression"
      x | "unexpected_contract" `isSuffixOf` x ->
          pure UnexpectedContract
      _ -> fail ("unknown id: " <> id')

instance Buildable RunError where
  build = \case
    RuntimeError addr -> "Runtime error for contract: " +| addr |+ ""
    ScriptRejected expr -> "Script rejected with: " +| expr |+ ""
    BadContractParameter addr -> "Bad contract parameter for: " +| addr |+ ""
    InvalidConstant expectedType expr ->
      "Invalid type: " +| expectedType |+ "\n" +|
      "For: " +| expr |+ ""
    InconsistentTypes type1 type2 ->
      "Inconsistent types: " +| type1 |+ " and " +| type2 |+ ""
    InvalidPrimitive expectedPrimitives wrongPrimitive ->
      "Invalid primitive: " +| wrongPrimitive |+ "\n" +|
      "Expecting on of: " +|
      mconcat (map ((<> " ") . build) expectedPrimitives) |+ ""
    InvalidSyntacticConstantError expectedForm wrongExpression ->
      "Invalid syntatic constant error, expecting: " +| expectedForm |+ "\n" +|
      "But got: " +| wrongExpression |+ ""
    UnexpectedContract ->
      build ("When parsing script, a contract type was found in \
             \the storage or parameter field." :: Text)

data RunOperationResult
  = RunOperationApplied TezosWord64 TezosWord64
  | RunOperationFailed [RunError]

combineResults :: RunOperationResult -> RunOperationResult -> RunOperationResult
combineResults (RunOperationApplied c1 c2) (RunOperationApplied c3 c4) =
  RunOperationApplied (c1 + c3) (c2 + c4)
combineResults (RunOperationApplied _ _) (RunOperationFailed e) =
  RunOperationFailed e
combineResults (RunOperationFailed e) (RunOperationApplied _ _) =
  RunOperationFailed e
combineResults (RunOperationFailed e1) (RunOperationFailed e2) =
  RunOperationFailed $ e1 <> e2

instance FromJSON RunOperationResult where
  parseJSON = withObject "operation_costs" $ \o -> do
    status <- o .: "status"
    case status of
      "applied" -> RunOperationApplied <$> o .: "consumed_gas" <*> o .: "storage_size"
      "failed" -> RunOperationFailed <$> o .: "errors"
      "backtracked" ->
        RunOperationFailed <$> o .:? "errors" .!= []
      _ -> fail ("unexpected status " ++ status)

data ParametersInternal = ParametersInternal
  { piEntrypoint :: Text
  , piValue :: Expression
  }

data TransactionOperation = TransactionOperation
  { toKind :: Text
  , toSource :: Address
  , toFee :: TezosWord64
  , toCounter :: TezosWord64
  , toGasLimit :: TezosWord64
  , toStorageLimit :: TezosWord64
  , toAmount :: TezosWord64
  , toDestination :: Address
  , toParameters :: ParametersInternal
  }

data ConfigSt = ConfigFilled | ConfigPartial

data Partial (label :: Symbol) a = Available a | Unavilable

type family ConfigC (a :: ConfigSt) b (label :: Symbol) where
  ConfigC 'ConfigFilled a _ = a
  ConfigC 'ConfigPartial a label = Partial label a

type ClientConfig = ClientConfigP 'ConfigFilled

type ClientConfigPartial = ClientConfigP 'ConfigPartial

data ClientConfigP f = ClientConfig
  { ccNodeAddress :: ConfigC f Text "url to the tezos node"
  , ccNodePort :: ConfigC f Int "`rpc port of the tezos node"
  , ccContractAddress :: ConfigC f Address "contract address"
  , ccMultisigAddress :: Maybe Address
  , ccUserAddress :: ConfigC f Address "user address"
  , ccUserAlias :: ConfigC f Text "user alias"
  , ccTezosClientExecutable :: ConfigC f FilePath "tezos-client executable path"
  } deriving Generic

toPartial :: Maybe a -> Partial s a
toPartial (Just a) = Available a
toPartial Nothing = Unavilable

isAvailable :: Partial s a -> Bool
isAvailable (Available _) = True
isAvailable _ = False

partialParser :: Parser a -> Parser (Partial s a)
partialParser p = toPartial <$> optional p

withDefault :: a -> Partial s a -> a
withDefault _ (Available a) = a
withDefault a _ = a

toConfigFilled :: ClientConfigPartial -> Maybe ClientConfig
toConfigFilled p = ClientConfig
  <$> (toMaybe $ ccNodeAddress p)
  <*> (toMaybe $ ccNodePort p)
  <*> (toMaybe $ ccContractAddress p)
  <*> (pure $ ccMultisigAddress p)
  <*> (toMaybe $ ccUserAddress p)
  <*> (toMaybeText $ ccUserAlias p)
  <*> (toMaybe $ ccTezosClientExecutable p)
  where
    toMaybe :: Partial s a -> Maybe a
    toMaybe (Available a) = Just a
    toMaybe _ = Nothing
    toMaybeText :: Partial s Text -> Maybe Text
    -- Check for place holders
    toMaybeText (Available a) = if T.isPrefixOf "-- " a then Nothing else Just a
    toMaybeText _ = Nothing

instance {-# OVERLAPS #-} (ToJSON a, KnownSymbol l) => ToJSON (Partial l a) where
  toJSON v = case v of
    Available a -> toJSON a
    Unavilable -> toJSON $ "-- Required field: " ++ (symbolVal (Proxy @l) ++ ", Replace this placeholder with proper value --")

instance (ToJSON a, KnownSymbol l) => ToJSON (Partial l (Maybe a)) where
  toJSON v = case v of
    Available a -> toJSON a
    Unavilable -> toJSON $ "-- Optional field: " ++ (symbolVal (Proxy @l) ++ ", Replace this placeholder with proper value or `null` if not required --")

instance ToJSON ClientConfigPartial where
  toJSON = genericToJSON (aesonPrefix snakeCase)

instance ToJSON ClientConfig where
  toJSON = genericToJSON (aesonPrefix snakeCase)

instance FromJSON ClientConfig where
  parseJSON = genericParseJSON (aesonPrefix snakeCase)

deriveJSON (aesonPrefix snakeCase) ''ParametersInternal
deriveJSON (aesonPrefix snakeCase) ''TransactionOperation
deriveJSON (aesonPrefix snakeCase) ''RunOperationInternal
deriveJSON (aesonPrefix snakeCase) ''RunOperation
