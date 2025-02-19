{-# language LambdaCase #-}
{-# language BangPatterns #-}
{-# language PatternSynonyms #-}

module Unison.Runtime.ANF.Serialize where

import Prelude hiding (putChar, getChar)

import Basement.Block (Block)

import Control.Applicative (liftA2)
import Control.Monad

import Data.Bits (Bits)
import Data.Bytes.Put
import Data.Bytes.Get hiding (getBytes)
import qualified Data.Bytes.Get as Ser
import Data.Bytes.VarInt
import Data.Bytes.Serial
import Data.Bytes.Signed (Unsigned)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Foldable (traverse_)
import Data.Functor ((<&>))
import Data.Map as Map (Map, fromList, lookup, toList)
import Data.Serialize.Put (runPutLazy)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8, decodeUtf8)
import Data.Word (Word8, Word16, Word64)
import Data.Int (Int64)

import qualified Data.ByteArray as BA
import qualified Data.Sequence as Seq
import qualified Data.ByteString.Lazy as L

import GHC.Stack

import Unison.Hash (Hash)
import Unison.Util.EnumContainers as EC
import Unison.Reference (Reference(..), pattern Derived, Id(..))
import Unison.Referent (Referent, pattern Ref, pattern Con)
import Unison.ABT.Normalized (Term(..))
import Unison.Runtime.Exception
import Unison.Runtime.ANF as ANF hiding (Tag)
import Unison.Var (Var(..), Type(ANFBlank))

import qualified Unison.Util.Bytes as Bytes
import qualified Unison.Hash as Hash
import qualified Unison.ConstructorType as CT

data TmTag
  = VarT | ForceT | AppT | HandleT
  | ShiftT | MatchT | LitT
  | NameRefT | NameVarT
  | LetDirT | LetIndT

data FnTag
  = FVarT | FCombT | FContT | FConT | FReqT | FPrimT

data MtTag
  = MIntT | MTextT | MReqT | MEmptyT | MDataT | MSumT

data LtTag
  = IT | NT | FT | TT | CT | LMT | LYT

data BLTag = TextT | ListT | TmLinkT | TyLinkT | BytesT

data VaTag = PartialT | DataT | ContT | BLitT
data CoTag = KET | MarkT | PushT

unknownTag :: String -> a
unknownTag t = exn $ "unknown " ++ t ++ " word"

class Tag t where
  tag2word :: t -> Word8
  word2tag :: Word8 -> t

instance Tag TmTag where
  tag2word = \case
    VarT -> 1
    ForceT -> 2
    AppT -> 3
    HandleT -> 4
    ShiftT -> 5
    MatchT -> 6
    LitT -> 7
    NameRefT -> 8
    NameVarT -> 9
    LetDirT -> 10
    LetIndT -> 11
  word2tag = \case
    1 -> VarT
    2 -> ForceT
    3 -> AppT
    4 -> HandleT
    5 -> ShiftT
    6 -> MatchT
    7 -> LitT
    8 -> NameRefT
    9 -> NameVarT
    10 -> LetDirT
    11 -> LetIndT
    _ -> unknownTag "TmTag"

instance Tag FnTag where
  tag2word = \case
    FVarT -> 0
    FCombT -> 1
    FContT -> 2
    FConT -> 3
    FReqT -> 4
    FPrimT -> 5

  word2tag = \case
    0 -> FVarT
    1 -> FCombT
    2 -> FContT
    3 -> FConT
    4 -> FReqT
    5 -> FPrimT
    _ -> unknownTag "FnTag"

instance Tag MtTag where
  tag2word = \case
    MIntT -> 0
    MTextT -> 1
    MReqT -> 2
    MEmptyT -> 3
    MDataT -> 4
    MSumT -> 5

  word2tag = \case
    0 -> MIntT
    1 -> MTextT
    2 -> MReqT
    3 -> MEmptyT
    4 -> MDataT
    5 -> MSumT
    _ -> unknownTag "MtTag"

instance Tag LtTag where
  tag2word = \case
    IT -> 0
    NT -> 1
    FT -> 2
    TT -> 3
    CT -> 4
    LMT -> 5
    LYT -> 6

  word2tag = \case
    0 -> IT
    1 -> NT
    2 -> FT
    3 -> TT
    4 -> CT
    5 -> LMT
    6 -> LYT
    _ -> unknownTag "LtTag"

instance Tag BLTag where
  tag2word = \case
    TextT -> 0
    ListT -> 1
    TmLinkT -> 2
    TyLinkT -> 3
    BytesT -> 4

  word2tag = \case
    0 -> TextT
    1 -> ListT
    2 -> TmLinkT
    3 -> TyLinkT
    4 -> BytesT
    t -> unknownTag "BLTag" t

instance Tag VaTag where
  tag2word = \case
    PartialT -> 0
    DataT -> 1
    ContT -> 2
    BLitT -> 3

  word2tag = \case
    0 -> PartialT
    1 -> DataT
    2 -> ContT
    3 -> BLitT
    t -> unknownTag "VaTag" t

instance Tag CoTag where
  tag2word = \case
    KET -> 0
    MarkT -> 1
    PushT -> 2
  word2tag = \case
    0 -> KET
    1 -> MarkT
    2 -> PushT
    t -> unknownTag "CoTag" t

putTag :: MonadPut m => Tag t => t -> m ()
putTag = putWord8 . tag2word

getTag :: MonadGet m => Tag t => m t
getTag = word2tag <$> getWord8

index :: Eq v => [v] -> v -> Maybe Word64
index ctx u = go 0 ctx
  where
  go !_ [] = Nothing
  go  n (v:vs)
    | v == u = Just n
    | otherwise = go (n+1) vs

deindex :: HasCallStack => [v] -> Word64 -> v
deindex [] _ = exn "deindex: bad index"
deindex (v:vs) n
  | n == 0 = v
  | otherwise = deindex vs (n-1)

putIndex :: MonadPut m => Word64 -> m ()
putIndex = serialize . VarInt

getIndex :: MonadGet m => m Word64
getIndex = unVarInt <$> deserialize

putVar :: MonadPut m => Eq v => [v] -> v -> m ()
putVar ctx v
  | Just i <- index ctx v = putIndex i
  | otherwise = exn "putVar: variable not in context"

getVar :: MonadGet m => [v] -> m v
getVar ctx = deindex ctx <$> getIndex

putArgs :: MonadPut m => Eq v => [v] -> [v] -> m ()
putArgs ctx is = putFoldable (putVar ctx) is

getArgs :: MonadGet m => [v] -> m [v]
getArgs ctx = getList (getVar ctx)

putCCs :: MonadPut m => [Mem] -> m ()
putCCs ccs = putLength n *> traverse_ putCC ccs
  where
  n = length ccs
  putCC UN = putWord8 0
  putCC BX = putWord8 1

getCCs :: MonadGet m => m [Mem]
getCCs = getList $ getWord8 <&> \case
  0 -> UN
  1 -> BX
  _ -> exn "getCCs: bad calling convention"

putGroup :: MonadPut m => Var v => SuperGroup v -> m ()
putGroup (Rec bs e)
  = putLength n *> traverse_ (putComb ctx) cs *> putComb ctx e
  where
  n = length ctx
  (ctx, cs) = unzip bs

getGroup :: MonadGet m => Var v => m (SuperGroup v)
getGroup = do
  l <- getLength
  let n = fromIntegral l
      vs = getFresh <$> take l [0..]
  cs <- replicateM l (getComb vs n)
  Rec (zip vs cs) <$> getComb vs n

putComb :: MonadPut m => Var v => [v] -> SuperNormal v -> m ()
putComb ctx (Lambda ccs (TAbss us e))
  = putCCs ccs *> putNormal (us++ctx) e

getFresh :: Var v => Word64 -> v
getFresh n = freshenId n $ typed ANFBlank

getComb :: MonadGet m => Var v => [v] -> Word64 -> m (SuperNormal v)
getComb ctx frsh0 = do
  ccs <- getCCs
  let us = zipWith (\_ -> getFresh) ccs [frsh0..]
      frsh = frsh0 + fromIntegral (length ccs)
  Lambda ccs . TAbss us <$> getNormal (us++ctx) frsh

putNormal :: MonadPut m => Var v => [v] -> ANormal v -> m ()
putNormal ctx tm = case tm of
  TVar v -> putTag VarT *> putVar ctx v
  TFrc v -> putTag ForceT *> putVar ctx v
  TApp f as -> putTag AppT *> putFunc ctx f *> putArgs ctx as
  THnd rs h e
    -> putTag HandleT *> putRefs rs *> putVar ctx h *> putNormal ctx e
  TShift r v e
    -> putTag ShiftT *> putReference r *> putNormal (v:ctx) e
  TMatch v bs -> putTag MatchT *> putVar ctx v *> putBranches ctx bs
  TLit l -> putTag LitT *> putLit l
  TName v (Left r) as e
    -> putTag NameRefT *> putReference r *> putArgs ctx as
    *> putNormal (v:ctx) e
  TName v (Right u) as e
    -> putTag NameVarT *> putVar ctx u *> putArgs ctx as
    *> putNormal (v:ctx) e
  TLets Direct us ccs l e
    -> putTag LetDirT *> putCCs ccs *> putNormal ctx l
    *> putNormal (us ++ ctx) e
  TLets (Indirect w) us ccs l e
    -> putTag LetIndT *> putWord16be w *> putCCs ccs *> putNormal ctx l
    *> putNormal (us ++ ctx) e
  _ -> exn "putNormal: malformed term"

getNormal :: MonadGet m => Var v => [v] -> Word64 -> m (ANormal v)
getNormal ctx frsh0 = getTag >>= \case
  VarT -> TVar <$> getVar ctx
  ForceT -> TFrc <$> getVar ctx
  AppT -> TApp <$> getFunc ctx <*> getArgs ctx
  HandleT -> THnd <$> getRefs <*> getVar ctx <*> getNormal ctx frsh0
  ShiftT ->
    flip TShift v <$> getReference <*> getNormal (v:ctx) (frsh0+1)
    where v = getFresh frsh0
  MatchT -> TMatch <$> getVar ctx <*> getBranches ctx frsh0
  LitT -> TLit <$> getLit
  NameRefT ->
    TName v . Left
      <$> getReference
      <*> getArgs ctx
      <*> getNormal (v:ctx) (frsh0+1)
    where v = getFresh frsh0
  NameVarT ->
    TName v . Right
      <$> getVar ctx
      <*> getArgs ctx
      <*> getNormal (v:ctx) (frsh0+1)
    where v = getFresh frsh0
  LetDirT -> do
    ccs <- getCCs
    let l = length ccs
        frsh = frsh0 + fromIntegral l
        us = getFresh <$> take l [frsh0..]
    TLets Direct us ccs
      <$> getNormal ctx frsh0
      <*> getNormal (us++ctx) frsh
  LetIndT -> do
    w <- getWord16be
    ccs <- getCCs
    let l = length ccs
        frsh = frsh0 + fromIntegral l
        us = getFresh <$> take l [frsh0..]
    TLets (Indirect w) us ccs
      <$> getNormal ctx frsh0
      <*> getNormal (us++ctx) frsh

putFunc :: MonadPut m => Var v => [v] -> Func v -> m ()
putFunc ctx f = case f of
  FVar v -> putTag FVarT *> putVar ctx v
  FComb r -> putTag FCombT *> putReference r
  FCont v -> putTag FContT *> putVar ctx v
  FCon r c -> putTag FConT *> putReference r *> putCTag c
  FReq r c -> putTag FReqT *> putReference r *> putCTag c
  FPrim (Left p) -> putTag FPrimT *> putPOp p
  FPrim _ -> exn "putFunc: can't serialize foreign func"

getFunc :: MonadGet m => Var v => [v] -> m (Func v)
getFunc ctx = getTag >>= \case
  FVarT -> FVar <$> getVar ctx
  FCombT -> FComb <$> getReference
  FContT -> FCont <$> getVar ctx
  FConT -> FCon <$> getReference <*> getCTag
  FReqT -> FReq <$> getReference <*> getCTag
  FPrimT -> FPrim . Left <$> getPOp

putPOp :: MonadPut m => POp -> m ()
putPOp op
  | Just w <- Map.lookup op pop2word = putWord16be w
  | otherwise = exn "putPOp: unknown POp"

getPOp :: MonadGet m => m POp
getPOp = getWord16be >>= \w -> case Map.lookup w word2pop of
  Just op -> pure op
  Nothing -> exn "getPOp: unknown enum code"

pOpAssoc :: [(POp, Word16)]
pOpAssoc
  = [ (ADDI, 0), (SUBI, 1), (MULI, 2), (DIVI, 3)
    , (SGNI, 4), (NEGI, 5), (MODI, 6)
    , (POWI, 7), (SHLI, 8), (SHRI, 9)
    , (INCI, 10), (DECI, 11), (LEQI, 12), (EQLI, 13)
    , (ADDN, 14), (SUBN, 15), (MULN, 16), (DIVN, 17)
    , (MODN, 18), (TZRO, 19), (LZRO, 20)
    , (POWN, 21), (SHLN, 22), (SHRN, 23)
    , (ANDN, 24), (IORN, 25), (XORN, 26), (COMN, 27)
    , (INCN, 28), (DECN, 29), (LEQN, 30), (EQLN, 31)
    , (ADDF, 32), (SUBF, 33), (MULF, 34), (DIVF, 35)
    , (MINF, 36), (MAXF, 37), (LEQF, 38), (EQLF, 39)
    , (POWF, 40), (EXPF, 41), (SQRT, 42), (LOGF, 43)
    , (LOGB, 44)
    , (ABSF, 45), (CEIL, 46), (FLOR, 47), (TRNF, 48)
    , (RNDF, 49)
    , (COSF, 50), (ACOS, 51), (COSH, 52), (ACSH, 53)
    , (SINF, 54), (ASIN, 55), (SINH, 56), (ASNH, 57)
    , (TANF, 58), (ATAN, 59), (TANH, 60), (ATNH, 61)
    , (ATN2, 62)
    , (CATT, 63), (TAKT, 64), (DRPT, 65), (SIZT, 66)
    , (UCNS, 67), (USNC, 68), (EQLT, 69), (LEQT, 70)
    , (PAKT, 71), (UPKT, 72)
    , (CATS, 73), (TAKS, 74), (DRPS, 75), (SIZS, 76)
    , (CONS, 77), (SNOC, 78), (IDXS, 79), (BLDS, 80)
    , (VWLS, 81), (VWRS, 82), (SPLL, 83), (SPLR, 84)
    , (PAKB, 85), (UPKB, 86), (TAKB, 87), (DRPB, 88)
    , (IDXB, 89), (SIZB, 90), (FLTB, 91), (CATB, 92)
    , (ITOF, 93), (NTOF, 94), (ITOT, 95), (NTOT, 96)
    , (TTOI, 97), (TTON, 98), (TTOF, 99), (FTOT, 100)
    , (FORK, 101)
    , (EQLU, 102), (CMPU, 103), (EROR, 104)
    , (PRNT, 105), (INFO, 106)
    ]

pop2word :: Map POp Word16
pop2word = fromList pOpAssoc

word2pop :: Map Word16 POp
word2pop = fromList $ swap <$> pOpAssoc
  where swap (x, y) = (y, x)

putLit :: MonadPut m => Lit -> m ()
putLit (I i) = putTag IT *> putInt i
putLit (N n) = putTag NT *> putNat n
putLit (F f) = putTag FT *> putFloat f
putLit (T t) = putTag TT *> putText t
putLit (C c) = putTag CT *> putChar c
putLit (LM r) = putTag LMT *> putReferent r
putLit (LY r) = putTag LYT *> putReference r

getLit :: MonadGet m => m Lit
getLit = getTag >>= \case
  IT -> I <$> getInt
  NT -> N <$> getNat
  FT -> F <$> getFloat
  TT -> T <$> getText
  CT -> C <$> getChar
  LMT -> LM <$> getReferent
  LYT -> LY <$> getReference

putBLit :: MonadPut m => BLit -> m ()
putBLit (Text t) = putTag TextT *> putText t
putBLit (List s) = putTag ListT *> putFoldable putValue s
putBLit (TmLink r) = putTag TmLinkT *> putReferent r
putBLit (TyLink r) = putTag TyLinkT *> putReference r
putBLit (Bytes b) = putTag BytesT *> putBytes b

getBLit :: MonadGet m => m BLit
getBLit = getTag >>= \case
  TextT -> Text <$> getText
  ListT -> List . Seq.fromList <$> getList getValue
  TmLinkT -> TmLink <$> getReferent
  TyLinkT -> TyLink <$> getReference
  BytesT -> Bytes <$> getBytes

putRefs :: MonadPut m => [Reference] -> m ()
putRefs rs = putFoldable putReference rs

getRefs :: MonadGet m => m [Reference]
getRefs = getList getReference

putEnumMap
  :: MonadPut m
  => EnumKey k
  => (k -> m ()) -> (v -> m ()) -> EnumMap k v -> m ()
putEnumMap pk pv m = putFoldable (putPair pk pv) (mapToList m)

getEnumMap :: MonadGet m => EnumKey k => m k -> m v -> m (EnumMap k v)
getEnumMap gk gv = mapFromList <$> getList (getPair gk gv)

putBranches :: MonadPut m => Var v => [v] -> Branched (ANormal v) -> m ()
putBranches ctx bs = case bs of
  MatchEmpty -> putTag MEmptyT
  MatchIntegral m df -> do
    putTag MIntT
    putEnumMap putWord64be (putNormal ctx) m
    putMaybe df $ putNormal ctx
  MatchText m df -> do
    putTag MTextT
    putMap putText (putNormal ctx) m
    putMaybe df $ putNormal ctx
  MatchRequest m (TAbs v df) -> do
    putTag MReqT
    putMap putReference (putEnumMap putCTag (putCase ctx)) m
    putNormal (v:ctx) df
    where 
  MatchData r m df -> do
    putTag MDataT
    putReference r
    putEnumMap putCTag (putCase ctx) m
    putMaybe df $ putNormal ctx
  MatchSum m -> do
    putTag MSumT
    putEnumMap putWord64be (putCase ctx) m
  _ -> exn "putBranches: malformed intermediate term"

getBranches
  :: MonadGet m => Var v => [v] -> Word64 -> m (Branched (ANormal v))
getBranches ctx frsh0 = getTag >>= \case
  MEmptyT -> pure MatchEmpty
  MIntT ->
    MatchIntegral
      <$> getEnumMap getWord64be (getNormal ctx frsh0)
      <*> getMaybe (getNormal ctx frsh0)
  MTextT ->
    MatchText
      <$> getMap getText (getNormal ctx frsh0)
      <*> getMaybe (getNormal ctx frsh0)
  MReqT ->
    MatchRequest
      <$> getMap getReference (getEnumMap getCTag (getCase ctx frsh0))
      <*> (TAbs v <$> getNormal (v:ctx) (frsh0+1))
    where
    v = getFresh frsh0
  MDataT ->
    MatchData
      <$> getReference
      <*> getEnumMap getCTag (getCase ctx frsh0)
      <*> getMaybe (getNormal ctx frsh0)
  MSumT -> MatchSum <$> getEnumMap getWord64be (getCase ctx frsh0)

putCase :: MonadPut m => Var v => [v] -> ([Mem], ANormal v) -> m ()
putCase ctx (ccs, (TAbss us e)) = putCCs ccs *> putNormal (us++ctx) e

getCase :: MonadGet m => Var v => [v] -> Word64 -> m ([Mem], ANormal v)
getCase ctx frsh0 = do
  ccs <- getCCs
  let l = length ccs
      frsh = frsh0 + fromIntegral l
      us = getFresh <$> take l [frsh0..]
  (,) ccs <$> getNormal (us++ctx) frsh

putCTag :: MonadPut m => CTag -> m ()
putCTag c = serialize (VarInt $ fromEnum c)

getCTag :: MonadGet m => m CTag
getCTag = toEnum . unVarInt <$> deserialize

putGroupRef :: MonadPut m => GroupRef -> m ()
putGroupRef (GR r i)
  = putReference r *> putWord64be i

getGroupRef :: MonadGet m => m GroupRef
getGroupRef = GR <$> getReference <*> getWord64be

putValue :: MonadPut m => Value -> m ()
putValue (Partial gr ws vs)
  = putTag PartialT
      *> putGroupRef gr
      *> putFoldable putWord64be ws
      *> putFoldable putValue vs
putValue (Data r t ws vs)
  = putTag DataT
      *> putReference r
      *> putWord64be t
      *> putFoldable putWord64be ws
      *> putFoldable putValue vs
putValue (Cont us bs k)
  = putTag ContT
      *> putFoldable putWord64be us
      *> putFoldable putValue bs
      *> putCont k
putValue (BLit l)
  = putTag BLitT *> putBLit l

getValue :: MonadGet m => m Value
getValue = getTag >>= \case
  PartialT ->
    Partial <$> getGroupRef <*> getList getWord64be <*> getList getValue
  DataT ->
    Data <$> getReference
         <*> getWord64be
         <*> getList getWord64be
         <*> getList getValue
  ContT -> Cont <$> getList getWord64be <*> getList getValue <*> getCont
  BLitT -> BLit <$> getBLit

putCont :: MonadPut m => Cont -> m ()
putCont KE = putTag KET
putCont (Mark rs ds k)
  = putTag MarkT
      *> putFoldable putReference rs
      *> putMap putReference putValue ds
      *> putCont k
putCont (Push i j m n gr k)
  = putTag PushT
      *> putWord64be i *> putWord64be j
      *> putWord64be m *> putWord64be n
      *> putGroupRef gr *> putCont k

getCont :: MonadGet m => m Cont
getCont = getTag >>= \case
  KET -> pure KE
  MarkT ->
    Mark <$> getList getReference
         <*> getMap getReference getValue
         <*> getCont
  PushT ->
    Push <$> getWord64be <*> getWord64be
         <*> getWord64be <*> getWord64be
         <*> getGroupRef <*> getCont

deserializeGroup :: Var v => ByteString -> Either String (SuperGroup v)
deserializeGroup bs = runGetS (getVersion *> getGroup) bs
  where
  getVersion = getWord32be >>= \case
    1 -> pure ()
    n -> fail $ "deserializeGroup: unknown version: " ++ show n

serializeGroup :: Var v => SuperGroup v -> ByteString
serializeGroup sg = runPutS (putVersion *> putGroup sg)
  where
  putVersion = putWord32be 1

deserializeValue :: ByteString -> Either String Value
deserializeValue bs = runGetS (getVersion *> getValue) bs
  where
  getVersion = getWord32be >>= \case
    1 -> pure ()
    n -> fail $ "deserializeValue: unknown version: " ++ show n

serializeValue :: Value -> ByteString
serializeValue v = runPutS (putVersion *> putValue v)
  where
  putVersion = putWord32be 1

serializeValueLazy :: Value -> L.ByteString
serializeValueLazy v = runPutLazy (putVersion *> putValue v)
  where putVersion = putWord32be 1

-- Some basics, moved over from V1 serialization
putChar :: MonadPut m => Char -> m ()
putChar = serialize . VarInt . fromEnum

getChar :: MonadGet m => m Char
getChar = toEnum . unVarInt <$> deserialize

putFloat :: MonadPut m => Double -> m ()
putFloat = serializeBE

getFloat :: MonadGet m => m Double
getFloat = deserializeBE

putNat :: MonadPut m => Word64 -> m ()
putNat = putWord64be

getNat :: MonadGet m => m Word64
getNat = getWord64be

putInt :: MonadPut m => Int64 -> m ()
putInt = serializeBE

getInt :: MonadGet m => m Int64
getInt = deserializeBE

putLength ::
  (MonadPut m, Integral n, Integral (Unsigned n),
   Bits n, Bits (Unsigned n))
  => n -> m ()
putLength = serialize . VarInt

getLength ::
  (MonadGet m, Integral n, Integral (Unsigned n),
   Bits n, Bits (Unsigned n))
  => m n
getLength = unVarInt <$> deserialize

putFoldable
  :: (Foldable f, MonadPut m) => (a -> m ()) -> f a -> m ()
putFoldable putA as = do
  putLength (length as)
  traverse_ putA as

putMap :: MonadPut m => (a -> m ()) -> (b -> m ()) -> Map a b -> m ()
putMap putA putB m = putFoldable (putPair putA putB) (Map.toList m)

getList :: MonadGet m => m a -> m [a]
getList a = getLength >>= (`replicateM` a)

getMap :: (MonadGet m, Ord a) => m a -> m b -> m (Map a b)
getMap getA getB = Map.fromList <$> getList (getPair getA getB)

putMaybe :: MonadPut m => Maybe a -> (a -> m ()) -> m ()
putMaybe Nothing _ = putWord8 0
putMaybe (Just a) putA = putWord8 1 *> putA a

getMaybe :: MonadGet m => m a -> m (Maybe a)
getMaybe getA = getWord8 >>= \tag -> case tag of
  0 -> pure Nothing
  1 -> Just <$> getA
  _ -> unknownTag "Maybe" tag

putPair :: MonadPut m => (a -> m ()) -> (b -> m ()) -> (a,b) -> m ()
putPair putA putB (a,b) = putA a *> putB b

getPair :: MonadGet m => m a -> m b -> m (a,b)
getPair = liftA2 (,)

getBytes :: MonadGet m => m Bytes.Bytes
getBytes = Bytes.fromChunks <$> getList getBlock

putBytes :: MonadPut m => Bytes.Bytes -> m ()
putBytes = putFoldable putBlock . Bytes.chunks

getBlock :: MonadGet m => m (Bytes.View (Block Word8))
getBlock = getLength >>= fmap (Bytes.view . BA.convert) . getByteString

putBlock :: MonadPut m => Bytes.View (Block Word8) -> m ()
putBlock b = putLength (BA.length b) *> putByteString (BA.convert b)

putHash :: MonadPut m => Hash -> m ()
putHash h = do
  let bs = Hash.toBytes h
  putLength (B.length bs)
  putByteString bs

getHash :: MonadGet m => m Hash
getHash = do
  len <- getLength
  bs <- B.copy <$> Ser.getBytes len
  pure $ Hash.fromBytes bs

putReferent :: MonadPut m => Referent -> m ()
putReferent = \case
  Ref r -> do
    putWord8 0
    putReference r
  Con r i ct -> do
    putWord8 1
    putReference r
    putLength i
    putConstructorType ct

getReferent :: MonadGet m => m Referent
getReferent = do
  tag <- getWord8
  case tag of
    0 -> Ref <$> getReference
    1 -> Con <$> getReference <*> getLength <*> getConstructorType
    _ -> unknownTag "getReferent" tag

getConstructorType :: MonadGet m => m CT.ConstructorType
getConstructorType = getWord8 >>= \case
  0 -> pure CT.Data
  1 -> pure CT.Effect
  t -> unknownTag "getConstructorType" t

putConstructorType :: MonadPut m => CT.ConstructorType -> m ()
putConstructorType = \case
  CT.Data -> putWord8 0
  CT.Effect -> putWord8 1

putText :: MonadPut m => Text -> m ()
putText text = do
  let bs = encodeUtf8 text
  putLength $ B.length bs
  putByteString bs

getText :: MonadGet m => m Text
getText = do
  len <- getLength
  bs <- B.copy <$> Ser.getBytes len
  pure $ decodeUtf8 bs

putReference :: MonadPut m => Reference -> m ()
putReference r = case r of
  Builtin name -> do
    putWord8 0
    putText name
  Derived hash i n -> do
    putWord8 1
    putHash hash
    putLength i
    putLength n

getReference :: MonadGet m => m Reference
getReference = do
  tag <- getWord8
  case tag of
    0 -> Builtin <$> getText
    1 -> DerivedId <$> (Id <$> getHash <*> getLength <*> getLength)
    _ -> unknownTag "Reference" tag

