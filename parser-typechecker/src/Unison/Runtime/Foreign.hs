{-# language GADTs #-}
{-# language BangPatterns #-}
{-# language PatternGuards #-}
{-# language ScopedTypeVariables #-}

module Unison.Runtime.Foreign
  ( Foreign(..)
  , HashAlgorithm(..)
  , unwrapForeign
  , maybeUnwrapForeign
  , wrapBuiltin
  , maybeUnwrapBuiltin
  , unwrapBuiltin
  , BuiltinForeign(..)
  , Tls(..)
  , Failure(..)
  ) where

import Control.Concurrent (ThreadId, MVar)
import Data.Text (Text, unpack)
import Data.Tagged (Tagged(..))
import Network.Socket (Socket)
import qualified Network.TLS as TLS (ClientParams, Context, ServerParams)
import qualified Data.X509 as X509
import System.IO (Handle)
import Unison.Util.Bytes (Bytes)
import Unison.Reference (Reference)
import Unison.Referent (Referent)
import Unison.Runtime.ANF (SuperGroup, Value)
import Unison.Symbol (Symbol)
import qualified Unison.Type as Ty
import qualified Crypto.Hash as Hash
import Unsafe.Coerce

data Foreign where
  Wrap :: Reference -> !e -> Foreign

promote :: (a -> a -> r) -> b -> c -> r
promote (~~) x y = unsafeCoerce x ~~ unsafeCoerce y

ref2eq :: Reference -> Maybe (a -> b -> Bool)
ref2eq r
  | r == Ty.textRef = Just $ promote ((==) @Text)
  | r == Ty.termLinkRef = Just $ promote ((==) @Referent)
  | r == Ty.typeLinkRef = Just $ promote ((==) @Reference)
  | r == Ty.bytesRef = Just $ promote ((==) @Bytes)
  -- Note: MVar equality is just reference equality, so it shouldn't
  -- matter what type the MVar holds.
  | r == Ty.mvarRef = Just $ promote ((==) @(MVar ()))
  | otherwise = Nothing

ref2cmp :: Reference -> Maybe (a -> b -> Ordering)
ref2cmp r
  | r == Ty.textRef = Just $ promote (compare @Text)
  | r == Ty.termLinkRef = Just $ promote (compare @Referent)
  | r == Ty.typeLinkRef = Just $ promote (compare @Reference)
  | r == Ty.bytesRef = Just $ promote (compare @Bytes)
  | otherwise = Nothing

instance Eq Foreign where
  Wrap rl t == Wrap rr u
    | rl == rr , Just (~~) <- ref2eq rl = t ~~ u
  _ == _ = error "Eq Foreign"

instance Ord Foreign where
  Wrap rl t `compare` Wrap rr u
    | rl == rr, Just cmp <- ref2cmp rl = cmp t u
  compare (Wrap rl1 _) (Wrap rl2 _) =
    error $ "Attempting to compare two values of different types: "
         <> show (rl1, rl2)

instance Show Foreign where
  showsPrec p !(Wrap r v)
    = showParen (p>9)
    $ showString "Wrap " . showsPrec 10 r . showString " " . contents
    where
    contents
      | r == Ty.textRef = shows (unpack (unsafeCoerce v))
      | otherwise = showString "_"

unwrapForeign :: Foreign -> a
unwrapForeign (Wrap _ e) = unsafeCoerce e

maybeUnwrapForeign :: Reference -> Foreign -> Maybe a
maybeUnwrapForeign rt (Wrap r e)
  | rt == r = Just (unsafeCoerce e)
  | otherwise = Nothing

class BuiltinForeign f where
  foreignRef :: Tagged f Reference

instance BuiltinForeign Text where foreignRef = Tagged Ty.textRef
instance BuiltinForeign Bytes where foreignRef = Tagged Ty.bytesRef
instance BuiltinForeign Handle where foreignRef = Tagged Ty.fileHandleRef
instance BuiltinForeign Socket where foreignRef = Tagged Ty.socketRef
instance BuiltinForeign ThreadId where foreignRef = Tagged Ty.threadIdRef
instance BuiltinForeign TLS.ClientParams where foreignRef = Tagged Ty.tlsClientConfigRef
instance BuiltinForeign TLS.ServerParams where foreignRef = Tagged Ty.tlsServerConfigRef
instance BuiltinForeign X509.SignedCertificate where foreignRef = Tagged Ty.tlsSignedCertRef
instance BuiltinForeign X509.PrivKey where foreignRef = Tagged Ty.tlsPrivateKeyRef
instance BuiltinForeign FilePath where foreignRef = Tagged Ty.filePathRef
instance BuiltinForeign TLS.Context where foreignRef = Tagged Ty.tlsRef
instance BuiltinForeign (SuperGroup Symbol) where
  foreignRef = Tagged Ty.codeRef
instance BuiltinForeign Value where foreignRef = Tagged Ty.valueRef

data HashAlgorithm where
  -- Reference is a reference to the hash algorithm
  HashAlgorithm :: Hash.HashAlgorithm a => Reference -> a -> HashAlgorithm

newtype Tls = Tls TLS.Context

data Failure a = Failure Reference Text a

instance BuiltinForeign HashAlgorithm where foreignRef = Tagged Ty.hashAlgorithmRef

wrapBuiltin :: forall f. BuiltinForeign f => f -> Foreign
wrapBuiltin x = Wrap r x
  where
  Tagged r = foreignRef :: Tagged f Reference

unwrapBuiltin :: BuiltinForeign f => Foreign -> f
unwrapBuiltin (Wrap _ x) = unsafeCoerce x

maybeUnwrapBuiltin :: forall f. BuiltinForeign f => Foreign -> Maybe f
maybeUnwrapBuiltin (Wrap r x)
  | r == r0 = Just (unsafeCoerce x)
  | otherwise = Nothing
  where
  Tagged r0 = foreignRef :: Tagged f Reference
