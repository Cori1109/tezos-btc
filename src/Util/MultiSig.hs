{- SPDX-FileCopyrightText: 2019 Bitcoin Suisse
 -
 - SPDX-License-Identifier: LicenseRef-Proprietary
 -}
{-# OPTIONS_GHC -Wno-orphans #-}

module Util.MultiSig
  ( Package(..)
  , MSigParameter
  , MSigParamMain
  , MSigPayload
  , addSignature
  , decodePackage
  , encodePackage
  , mkPackage
  , mkMultiSigParam
  , getOpDescription
  , mergePackages
  , getBytesToSign
  , getToSign
  , fetchSrcParam
  )
where

import Prelude hiding (drop, toStrict, (>>))

import Data.Aeson (eitherDecodeStrict, encode)
import Data.Aeson.Casing (aesonPrefix, camelCase)
import Data.Aeson.TH (deriveJSON)
import Data.ByteString.Lazy as LBS (toStrict)
import Data.List (lookup)
import Fmt (Buildable(..), Builder, blockListF, pretty, (|+))
import Text.Hex (decodeHex, encodeHex)
import qualified Text.Show (show)

import Client.Util (addTezosBytesPrefix)
import Lorentz
import Lorentz.Contracts.TZBTC as TZBTC
import Lorentz.Contracts.TZBTC.Types as TZBTC
import Lorentz.Contracts.Multisig
import Michelson.Interpret.Unpack
import Tezos.Crypto

-- The work flow consist of first calling the `mkPackage` function with the
-- required parameters to get a `Package` object which will hold the byte string
-- to be signed along with the environment to recreate the original action, along
-- with a place holder for storing the signatures. This can be json encoded and
-- written to a file using the `encodePackage` function.
--
-- Signatures can be added to the file using the `addSignature` function.
--
-- After collecting enough signatures, the file can be passed to
-- `mkMultiSigParam` function, which will create a multi-sig contract param.
-- This to param, when used in a call to the multisig contract make it validate
-- the signatures and call the action in the main contract.

-- | This is the structure that will be serialized and signed on. We are using
-- this particular type because the multisig contract extracts the payload,
-- `MSigPayload` from its parameter, pair it with the contracts address
-- (self), then serialize and check the signatures provided on that serialized
-- data.
type ToSign = (Address, MSigPayload)

-- | The type that will represent the actual data that will be provide to
-- signers. We are using this, instead of just providing the byte sequence,
-- because we need the `TcOriginatedContracts` map to recreate the original
-- payload from the serialized bytesequence. So this information along with
-- the signatures should be enough to actually execute the transaction at the
-- multisig contract.
--
-- Note that we are also collecting the public key associated with a signature.
-- This is because the multisig expects the signatures to be ordered in the
-- exact same way as the keys in its storage. If a signature is not available
-- then it expects a Nothing value in its place.
data Package = Package
  { pkToSign :: !Text  -- ^ Hex encoded byte sequence that should be signed
  , pkSignatures :: ![(PublicKey, Signature)] -- ^ Field to hold signatures and public keys as they are collected.
  }

instance Buildable (PublicKey, Signature) where
  build (pk, sig) =  ("Public key: " :: String)
                  |+ (formatPublicKey pk)
                  |+ ("\nSignature: " :: String)
                  |+ (build $ formatSignature sig)

instance Buildable Package where
  build p =
    ("Operation:" :: String)
    |+ ("\n------------------\n" :: String) |+ (getOpDescription p) |+ newLine
    |+ ("\nIncluded Signatures:" :: String)
    |+ ("\n--------------------\n" :: String) |+ (blockListF $ build <$> pkSignatures p)
    where
      newLine = "\n" :: String

-- | Match packed parameter with the signed bytesequence and if it matches,
-- return it, or else return an error. The idea is that the source parameter
-- is meaningless (and probably dangerous) if it does not match with the
-- packed bytesequence that is being signed on.
fetchSrcParam
  :: Package
  -> Either UnpackageError (TZBTC.Parameter SomeTZBTCVersion)
fetchSrcParam package =
  case decodeHex $ pkToSign package of
    Just hexDecoded ->
      case fromVal @ToSign
          <$> unpackValue' hexDecoded of
        Right (_, (_, action)) ->
          case action of
            Operation (safeParameter, _) ->
              Right (TZBTC.SafeEntrypoints safeParameter)
            _ -> error "Unsupported multisig operation"
        Left err -> Left $ UnpackFailure err
    Nothing -> Left HexDecodingFailure

checkIntegrity
  :: Package
  -> Bool
checkIntegrity = isRight . fetchSrcParam

-- | Get Operation description from serialized value
getOpDescription
  :: Package -> Builder
getOpDescription p = case fetchSrcParam p of
  Right param -> build param
  Left err -> build err

-- | Make the `Package` value from input parameters.
mkPackage
  :: forall msigAddr. (ToTAddress MSigParameter msigAddr)
  => msigAddr
  -> Counter
  -> TAddress (TZBTC.Parameter SomeTZBTCVersion)
  -> TZBTC.SafeParameter SomeTZBTCVersion -> Package
mkPackage msigAddress counter tzbtc param
  = let msigParam = Operation (param, tzbtc)
        msigTAddr = (toTAddress @MSigParameter) msigAddress
    -- Create the package for required action
    in Package
      {
        -- Wrap the parameter with multisig address and replay attack counter,
        -- forming a structure that the multi-sig contract will ultimately
        -- verify the included signatures against
        pkToSign = encodeToSign $ (toAddress msigTAddr, (counter, msigParam))
      , pkSignatures = [] -- No signatures when creating package
      }

mergeSignatures
  :: Package
  -> Package
  -> Maybe Package
mergeSignatures p1 p2 =
  -- If the payloads are same, then merge the signatures from both
  -- packages and form a new package with both the signatures.
  if pkToSign p1 == pkToSign p2
    then Just $ p1 { pkSignatures = pkSignatures p1 ++ pkSignatures p2 }
    else Nothing

mergePackages
  :: NonEmpty Package
  -> Either UnpackageError Package
mergePackages (p :| ps) = maybeToRight PackageMergeFailure $
  foldM mergeSignatures p ps

getBytesToSign :: Package -> Text
getBytesToSign Package{..} = addTezosBytesPrefix pkToSign

-- | Extract the signable component from package. This is a structure
-- with the packed parameter that represent the action, the multi-sig contract
-- address, and the replay attack prevention counter.
getToSign :: Package -> Either UnpackageError ToSign
getToSign Package{..} =
  case decodeHex pkToSign of
    Just hexDecoded ->
      case fromVal @ToSign <$> unpackValue' hexDecoded of
        Right toSign -> Right toSign
        Left err -> Left $ UnpackFailure err
    Nothing -> Left HexDecodingFailure

-- | Errors that can happen when package is de-serialized back to the multi-sig
-- contract param
data UnpackageError
  = HexDecodingFailure
  | UnpackFailure UnpackError
  | PackageMergeFailure
  | BadSrcParameterFailure -- If the bundled operation differes from the one that is being signed for
  | UnexpectedParameterWithView

instance Buildable UnpackageError where
  build = \case
    HexDecodingFailure -> "Error decoding hex encoded string"
    PackageMergeFailure -> "Provied packages had different action/enviroments"
    BadSrcParameterFailure -> "ERROR!! The bundled operation does not match the byte sequence that is being signed."
    UnpackFailure err -> build err
    UnexpectedParameterWithView -> "Unexpected parameter with View in package"

instance Show UnpackageError where
  show = pretty

instance Exception UnpackageError where
  displayException = pretty

-- | Encode package
encodePackage
  :: Package
  -> ByteString
encodePackage = toStrict . encode

-- | Decode package
decodePackage
  :: ByteString
  -> Either String Package
decodePackage = eitherDecodeStrict

-- | Add signature to package.
addSignature
  :: Package
  -> (PublicKey, Signature)
  -> Either String Package
addSignature package sig =
  if checkIntegrity package then let
    -- ^ Checks if the included source parameter matches with the
    -- signable payload.
    existing = pkSignatures package
    in Right $ package { pkSignatures = sig:existing }
  else Left "WARNING!! Cannot add signature as the integrity of the multi-sig package could not be verified"

-- | Given a value of type `Package`, and a list of public keys,
-- make the actual parameter that the multi-sig contract can be called with.
-- The list of public keys should be in the same order that the contract has
-- them in it's storage.
mkMultiSigParam
  :: [PublicKey]
  -> NonEmpty Package
  -> Either UnpackageError ((TAddress MSigParameter), MSigParamMain)
mkMultiSigParam pks packages = do
  package <- mergePackages packages
  toSign <- getToSign package
  return $ mkParameter toSign (pkSignatures package)
  where
    mkParameter
      :: ToSign
      -> [(PublicKey, Signature)]
      -> (TAddress MSigParameter, MSigParamMain)
    mkParameter (address_, payload) sigs =
      -- There should be as may signatures in the submitted request
      -- as there are keys in the contract's storage. Not all keys should
      -- be present, but they should be marked as absent using Nothing values [1].
      -- So we pad the list with Nothings to make up for missing signatures.
      (toTAddress address_, (payload, sortSigs sigs))
    sortSigs :: [(PublicKey, Signature)] -> [Maybe Signature]
    sortSigs sigs = flip lookup sigs <$> pks

encodeToSign :: ToSign -> Text
encodeToSign ts = (encodeHex $ lPackValue ts)

deriveJSON (aesonPrefix camelCase) ''Package
