{-# Language ViewPatterns #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Unison.Util.Bytes where

import Data.Bits (shiftR, shiftL, (.|.))
import Data.Char
import Data.Memory.PtrMethods (memCompare, memEqual)
import Data.Monoid (Sum(..))
import Foreign.Ptr (Ptr, plusPtr)
import Foreign.Storable (poke)
import System.IO.Unsafe (unsafeDupablePerformIO)
import Unison.Prelude hiding (ByteString, empty)
import Basement.Block (Block)
import qualified Data.ByteString.Lazy as LB
import qualified Data.ByteArray as B
import qualified Data.ByteArray.Encoding as BE
import qualified Data.FingerTree as T
import qualified Data.Text as Text

-- Block is just `newtype Block a = Block ByteArray#`
type ByteString = Block Word8

-- Bytes type represented as a finger tree of ByteStrings.
-- Can be efficiently sliced and indexed, using the byte count
-- annotation at each subtree.
newtype Bytes = Bytes (T.FingerTree (Sum Int) (View ByteString))

null :: Bytes -> Bool
null (Bytes bs) = T.null bs

empty :: Bytes
empty = Bytes mempty

fromArray :: B.ByteArrayAccess ba => ba -> Bytes
fromArray = snoc empty

toArray :: forall bo . B.ByteArray bo => Bytes -> bo
toArray b = B.concat (map B.convert (chunks b) :: [bo])

toLazyByteString :: Bytes -> LB.ByteString
toLazyByteString b = LB.fromChunks $ map B.convert $ chunks b

size :: Bytes -> Int
size (Bytes bs) = getSum (T.measure bs)

chunks :: Bytes -> [View ByteString]
chunks (Bytes b) = toList b

fromChunks :: [View ByteString] -> Bytes
fromChunks = foldl' snocView empty

snocView :: Bytes -> View ByteString -> Bytes
snocView bs b | B.null b = bs
snocView (Bytes bs) b = Bytes (bs T.|> b)

cons :: B.ByteArrayAccess ba => ba -> Bytes -> Bytes
cons b bs | B.null b = bs
cons b (Bytes bs) = Bytes (view (B.convert b) T.<| bs)

snoc :: B.ByteArrayAccess ba => Bytes -> ba -> Bytes
snoc bs b | B.null b = bs
snoc (Bytes bs) b = Bytes (bs T.|> view (B.convert b))

flatten :: Bytes -> Bytes
flatten b = snoc mempty (B.concat (chunks b) :: ByteString)

take :: Int -> Bytes -> Bytes
take n (Bytes bs) = go (T.split (> Sum n) bs) where
  go (ok, s) = Bytes $ case T.viewl s of
    last T.:< _ ->
      if T.measure ok == Sum n then ok
      else ok T.|> takeView (n - getSum (T.measure ok)) last
    _ -> ok

drop :: Int -> Bytes -> Bytes
drop n b0@(Bytes bs) = go (T.dropUntil (> Sum n) bs) where
  go s = Bytes $ case T.viewl s of
    head T.:< tail ->
      if (size b0 - getSum (T.measure s)) == n then s
      else dropView (n - (size b0 - getSum (T.measure s))) head T.<| tail
    _ -> s

at :: Int -> Bytes -> Maybe Word8
at i bs = case Unison.Util.Bytes.drop i bs of
  -- todo: there's a more efficient implementation that does no allocation
  -- note: chunks guaranteed nonempty (see `snoc` and `cons` implementations)
  Bytes (T.viewl -> hd T.:< _) -> Just (B.index hd 0)
  _ -> Nothing

dropBlock :: Int -> Bytes -> Maybe (View ByteString, Bytes)
dropBlock nBytes chunks =
  go mempty chunks where
    go acc (Bytes chunks) =
      if B.length acc == nBytes then
        Just (view acc, (Bytes chunks))
      else if B.length acc >= nBytes then
        let v = view acc in
          Just ((takeView nBytes v), Bytes ((dropView nBytes v) T.<| chunks))
      else
        case chunks of
          (T.viewl -> (head T.:< tail)) -> go (acc <> (B.convert head)) (Bytes tail)
          _ -> Nothing


decodeNat64be :: Bytes -> Maybe (Word64, Bytes)
decodeNat64be bs = case dropBlock 8 bs of
  Just (head, rest) ->
    let
      b8 = B.index head 0
      b7 = B.index head 1
      b6 = B.index head 2
      b5 = B.index head 3
      b4 = B.index head 4
      b3 = B.index head 5
      b2 = B.index head 6
      b1 = B.index head 7
      b = shiftL (fromIntegral b8) 56
       .|.shiftL (fromIntegral b7) 48
       .|.shiftL (fromIntegral b6) 40
       .|.shiftL (fromIntegral b5) 32
       .|.shiftL (fromIntegral b4) 24
       .|.shiftL (fromIntegral b3) 16
       .|.shiftL (fromIntegral b2) 8
       .|.fromIntegral b1
    in
      Just(b, rest)
  Nothing -> Nothing

decodeNat64le :: Bytes -> Maybe (Word64, Bytes)
decodeNat64le bs = case dropBlock 8 bs of
  Just (head, rest) ->
    let
      b1 = B.index head 0
      b2 = B.index head 1
      b3 = B.index head 2
      b4 = B.index head 3
      b5 = B.index head 4
      b6 = B.index head 5
      b7 = B.index head 6
      b8 = B.index head 7
      b =  shiftL (fromIntegral b8) 56
       .|. shiftL (fromIntegral b7) 48
       .|. shiftL (fromIntegral b6) 40
       .|. shiftL (fromIntegral b5) 32
       .|. shiftL (fromIntegral b4) 24
       .|. shiftL (fromIntegral b3) 16
       .|. shiftL (fromIntegral b2) 8
       .|. fromIntegral b1
    in
      Just(b, rest)
  Nothing -> Nothing

decodeNat32be :: Bytes -> Maybe (Word64, Bytes)
decodeNat32be bs = case dropBlock 4 bs of
  Just (head, rest) ->
    let
      b4 = B.index head 0
      b3 = B.index head 1
      b2 = B.index head 2
      b1 = B.index head 3
      b =  shiftL (fromIntegral b4) 24
       .|. shiftL (fromIntegral b3) 16
       .|. shiftL (fromIntegral b2) 8
       .|. fromIntegral b1
    in
      Just(b, rest)
  Nothing -> Nothing

decodeNat32le :: Bytes -> Maybe (Word64, Bytes)
decodeNat32le bs = case dropBlock 4 bs of
  Just (head, rest) ->
    let
      b1 = B.index head 0
      b2 = B.index head 1
      b3 = B.index head 2
      b4 = B.index head 3
      b =  shiftL (fromIntegral b4) 24
       .|. shiftL (fromIntegral b3) 16
       .|. shiftL (fromIntegral b2) 8
       .|. fromIntegral b1
    in
      Just(b, rest)
  Nothing -> Nothing

decodeNat16be :: Bytes -> Maybe (Word64, Bytes)
decodeNat16be bs = case dropBlock 2 bs of
  Just (head, rest) ->
    let
      b2 = B.index head 0
      b1 = B.index head 1
      b =  shiftL (fromIntegral b2) 8
       .|. fromIntegral b1
    in
      Just(b, rest)
  Nothing -> Nothing

decodeNat16le :: Bytes -> Maybe (Word64, Bytes)
decodeNat16le bs = case dropBlock 2 bs of
  Just (head, rest) ->
    let
      b1 = B.index head 0
      b2 = B.index head 1
      b =  shiftL (fromIntegral b2) 8
       .|. fromIntegral b1
    in
      Just(b, rest)
  Nothing -> Nothing


fillBE :: Word64 -> Int -> Ptr Word8 -> IO ()
fillBE n 0 p = poke p (fromIntegral n) >> return ()
fillBE n i p = poke p (fromIntegral (shiftR n (i * 8)))
                   >> fillBE n (i - 1) (p `plusPtr` 1)
  
encodeNat64be :: Word64 -> Bytes
encodeNat64be n = Bytes (T.singleton (view (B.unsafeCreate 8 (fillBE n 7))))

encodeNat32be :: Word64 -> Bytes
encodeNat32be n = Bytes (T.singleton (view (B.unsafeCreate 4 (fillBE n 3))))

encodeNat16be :: Word64 -> Bytes
encodeNat16be n = Bytes (T.singleton (view (B.unsafeCreate 2 (fillBE n 1))))

fillLE :: Word64 -> Int -> Int -> Ptr Word8 -> IO ()
fillLE n i j p =
  if i == j then
    return ()
  else
    poke p (fromIntegral (shiftR n (i * 8))) >> fillLE n (i + 1) j (p `plusPtr` 1)

encodeNat64le :: Word64 -> Bytes
encodeNat64le n = Bytes (T.singleton (view (B.unsafeCreate 8 (fillLE n 0 8))))

encodeNat32le :: Word64 -> Bytes
encodeNat32le n = Bytes (T.singleton (view (B.unsafeCreate 4 (fillLE n 0 4))))

encodeNat16le :: Word64 -> Bytes
encodeNat16le n = Bytes (T.singleton (view (B.unsafeCreate 2 (fillLE n 0 2))))

toBase16 :: Bytes -> Bytes
toBase16 bs = foldl' step empty (chunks bs) where
  step bs b = snoc bs (BE.convertToBase BE.Base16 b :: ByteString)

fromBase16 :: Bytes -> Either Text.Text Bytes
fromBase16 bs = case traverse convert (chunks bs) of
  Left e -> Left (Text.pack e)
  Right bs -> Right (fromChunks (map view bs))
  where
    convert b = BE.convertFromBase BE.Base16 b :: Either String ByteString

toBase32, toBase64, toBase64UrlUnpadded :: Bytes -> Bytes
toBase32 = toBase BE.Base32
toBase64 = toBase BE.Base64
toBase64UrlUnpadded = toBase BE.Base64URLUnpadded

fromBase32, fromBase64, fromBase64UrlUnpadded :: Bytes -> Either Text.Text Bytes
fromBase32 = fromBase BE.Base32
fromBase64 = fromBase BE.Base64
fromBase64UrlUnpadded = fromBase BE.Base64URLUnpadded

fromBase :: BE.Base -> Bytes -> Either Text.Text Bytes
fromBase e bs = case BE.convertFromBase e (toArray bs :: ByteString) of
  Left e -> Left (Text.pack e)
  Right b -> Right $ snocView empty (view b)

toBase :: BE.Base -> Bytes -> Bytes
toBase e bs = snoc empty (BE.convertToBase e (toArray bs :: ByteString) :: ByteString)

toWord8s :: Bytes -> [Word8]
toWord8s bs = chunks bs >>= B.unpack

fromWord8s :: [Word8] -> Bytes
fromWord8s bs = fromArray (view $ B.pack bs :: View ByteString)

instance Monoid Bytes where
  mempty = Bytes mempty
  mappend (Bytes b1) (Bytes b2) = Bytes (b1 `mappend` b2)

instance Semigroup Bytes where (<>) = mappend

instance T.Measured (Sum Int) (View ByteString) where
  measure b = Sum (B.length b)

instance Show Bytes where
  show bs = toWord8s (toBase16 bs) >>= \w -> [chr (fromIntegral w)]

-- Produces two lists where the chunks have the same length
alignChunks :: B.ByteArrayAccess ba => [View ba] -> [View ba] -> ([View ba], [View ba])
alignChunks bs1 bs2 = (cs1, cs2)
  where
  cs1 = alignTo bs1 bs2
  cs2 = alignTo bs2 cs1
  alignTo :: B.ByteArrayAccess ba => [View ba] -> [View ba] -> [View ba]
  alignTo bs1 [] = bs1
  alignTo []  _  = []
  alignTo (hd1:tl1) (hd2:tl2)
    | len1 == len2 = hd1 : alignTo tl1 tl2
    | len1 < len2  = hd1 : alignTo tl1 (dropView len1 hd2 : tl2)
    | otherwise    = -- len1 > len2
                     let (hd1',hd1rem) = (takeView len2 hd1, dropView len2 hd1)
                     in hd1' : alignTo (hd1rem : tl1) tl2
    where
      len1 = B.length hd1
      len2 = B.length hd2

instance Eq Bytes where
  b1 == b2 | size b1 == size b2 =
    uncurry (==) (alignChunks (chunks b1) (chunks b2))
  _ == _ = False

-- Lexicographical ordering
instance Ord Bytes where
  b1 `compare` b2 = uncurry compare (alignChunks (chunks b1) (chunks b2))

--
-- Forked from: http://hackage.haskell.org/package/memory-0.15.0/docs/src/Data.ByteArray.View.html
-- which is already one of our dependencies. Forked because the view
-- type in the memory package doesn't expose its constructor which makes
-- it impossible to implement take and drop.
--
-- Module      : Data.ByteArray.View
-- License     : BSD-style
-- Maintainer  : Nicolas DI PRIMA <nicolas@di-prima.fr>
-- Stability   : stable
-- Portability : Good

view :: B.ByteArrayAccess bs => bs -> View bs
view bs = View 0 (B.length bs) bs

takeView, dropView :: B.ByteArrayAccess bs => Int -> View bs -> View bs
takeView k (View i n bs) = View i (min k n) bs
dropView k (View i n bs) = View (i + (k `min` n)) (n - (k `min` n)) bs

data View bytes = View
  { viewOffset :: !Int
  , viewSize   :: !Int
  , unView     :: !bytes
  }

instance B.ByteArrayAccess bytes => Eq (View bytes) where
  v1 == v2 = viewSize v1 == viewSize v2 && unsafeDupablePerformIO (
    B.withByteArray v1 $ \ptr1 ->
    B.withByteArray v2 $ \ptr2 -> memEqual ptr1 ptr2 (viewSize v1))

instance B.ByteArrayAccess bytes => Ord (View bytes) where
  compare v1 v2 = unsafeDupablePerformIO $
    B.withByteArray v1 $ \ptr1 ->
    B.withByteArray v2 $ \ptr2 -> do
      ret <- memCompare ptr1 ptr2 (min (viewSize v1) (viewSize v2))
      return $ case ret of
        EQ | B.length v1 >  B.length v2 -> GT
           | B.length v1 <  B.length v2 -> LT
           | B.length v1 == B.length v2 -> EQ
        _                               -> ret

instance B.ByteArrayAccess bytes => Show (View bytes) where
  show v = show (B.unpack v)

instance B.ByteArrayAccess bytes => B.ByteArrayAccess (View bytes) where
  length = viewSize
  withByteArray v f = B.withByteArray (unView v) $
    \ptr -> f (ptr `plusPtr` (viewOffset v))
