{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ViewPatterns #-}

module Unison.Term where

import qualified Control.Monad.Writer.Strict as Writer
import           Data.Foldable (toList)
import           Data.Int (Int64)
import           Data.List (foldl')
import           Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Monoid as Monoid
import           Data.Set (Set, union)
import qualified Data.Set as Set
import           Data.Text (Text)
import           Data.Vector (Vector)
import qualified Data.Vector as Vector
import           Data.Word (Word64)
import           GHC.Generics
import           Prelude.Extras (Eq1(..), Show1(..))
import           Text.Show
import qualified Unison.ABT as ABT
import           Unison.Hash (Hash)
import qualified Unison.Hash as Hash
import           Unison.Hashable (Hashable1, accumulateToken)
import qualified Unison.Hashable as Hashable
import           Unison.Pattern (Pattern)
import           Unison.Reference (Reference(..))
import qualified Unison.Reference as Reference
import           Unison.Type (Type)
import qualified Unison.Type as Type
import           Unison.Var (Var)
import           Unsafe.Coerce
import qualified Unison.Pattern as Pattern
import Data.Foldable (traverse_)

-- todo: add loc to MatchCase
data MatchCase a = MatchCase Pattern (Maybe a) a
  deriving (Show,Eq,Foldable,Functor,Generic,Generic1,Traversable)

-- | Base functor for terms in the Unison language
-- We need `typeVar` because the term and type variables may differ.
data F typeVar typeAnn a
  = Int64 Int64
  | UInt64 Word64
  | Float Double
  | Boolean Bool
  | Text Text
  | Blank -- An expression that has not been filled in, has type `forall a . a`
  | Ref Reference
  | Constructor Reference Int -- First argument identifies the data type, second argument identifies the constructor
  | Request Reference Int
  | Handle a a
  | EffectPure a
  | EffectBind Reference Int [a] a
  | App a a
  | Ann a (Type.AnnotatedType typeVar typeAnn)
  | Vector (Vector a)
  | If a a a
  | And a a
  | Or a a
  | Lam a
  -- Note: let rec blocks have an outer ABT.Cycle which introduces as many
  -- variables as there are bindings
  | LetRec [a] a
  -- Note: first parameter is the binding, second is the expression which may refer
  -- to this let bound variable. Constructed as `Let b (abs v e)`
  | Let a a
  -- Pattern matching / eliminating data types, example:
  --  case x of
  --    Just n -> rhs1
  --    Nothing -> rhs2
  --
  -- translates to
  --
  --   Match x
  --     [ (Constructor 0 [Var], ABT.abs n rhs1)
  --     , (Constructor 1 [], rhs2) ]
  | Match a [MatchCase a]
  deriving (Eq,Foldable,Functor,Generic,Generic1,Traversable)

-- | Like `Term v`, but with an annotation of type `a` at every level in the tree
type AnnotatedTerm v a = AnnotatedTerm2 v a v a
-- | Allow type variables and term variables to differ
type AnnotatedTerm' vt v a = AnnotatedTerm2 vt a v a
-- | Allow type variables, term variables, type annotations and term annotations
-- to all differ
type AnnotatedTerm2 vt at v a = ABT.Term (F vt at) v a

-- | Terms are represented as ABTs over the base functor F, with variables in `v`
type Term v = AnnotatedTerm v ()
-- | Terms with type variables in `vt`, and term variables in `v`
type Term' vt v = AnnotatedTerm' vt v ()

bindBuiltins :: Var v => [(v, Term v)] -> [(v, Type v)] -> Term v -> Term v
bindBuiltins termBuiltins typeBuiltins =
   typeMap (ABT.substs typeBuiltins) . ABT.substs termBuiltins

vmap :: Ord v2 => (v -> v2) -> AnnotatedTerm v a -> AnnotatedTerm v2 a
vmap f = ABT.vmap f . typeMap (ABT.vmap f)

vtmap :: Ord vt2 => (vt -> vt2) -> AnnotatedTerm' vt v a -> AnnotatedTerm' vt2 v a
vtmap f = typeMap (ABT.vmap f)

typeMap :: Ord vt2 => (Type.AnnotatedType vt a -> Type.AnnotatedType vt2 a2)
                   -> AnnotatedTerm' vt v a -> ABT.Term (F vt2 a2) v a
typeMap f t = go t where
  go (ABT.Term fvs a t) = ABT.Term fvs a $ case t of
    ABT.Abs v t -> ABT.Abs v (go t)
    ABT.Var v -> ABT.Var v
    ABT.Cycle t -> ABT.Cycle (go t)
    ABT.Tm (Ann e t) -> ABT.Tm (Ann (go e) (f t))
    -- Safe since `Ann` is only ctor that has embedded `Type v` arg
    -- otherwise we'd have to manually match on every non-`Ann` ctor
    ABT.Tm ts -> unsafeCoerce $ ABT.Tm (fmap go ts)

wrapV :: Ord v => AnnotatedTerm v a -> AnnotatedTerm (ABT.V v) a
wrapV = vmap ABT.Bound

freeVars :: AnnotatedTerm' vt v a -> Set v
freeVars = ABT.freeVars

freeTypeVars :: Ord vt => AnnotatedTerm' vt v a -> Set vt
freeTypeVars t = go t where
  go :: Ord vt => AnnotatedTerm' vt v a -> Set vt
  go (ABT.Term _ _ t) = case t of
    ABT.Abs _ t -> go t
    ABT.Var _ -> Set.empty
    ABT.Cycle t -> go t
    ABT.Tm (Ann e t) -> Type.freeVars t `union` go e
    ABT.Tm ts -> foldMap go ts

-- nicer pattern syntax

pattern Var' v <- ABT.Var' v
pattern Int64' n <- (ABT.out -> ABT.Tm (Int64 n))
pattern UInt64' n <- (ABT.out -> ABT.Tm (UInt64 n))
pattern Float' n <- (ABT.out -> ABT.Tm (Float n))
pattern Boolean' b <- (ABT.out -> ABT.Tm (Boolean b))
pattern Text' s <- (ABT.out -> ABT.Tm (Text s))
pattern Blank' <- (ABT.out -> ABT.Tm Blank)
pattern Ref' r <- (ABT.out -> ABT.Tm (Ref r))
pattern Builtin' r <- (ABT.out -> ABT.Tm (Ref (Builtin r)))
pattern App' f x <- (ABT.out -> ABT.Tm (App f x))
pattern Match' scrutinee branches <- (ABT.out -> ABT.Tm (Match scrutinee branches))
pattern Constructor' ref n <- (ABT.out -> ABT.Tm (Constructor ref n))
pattern Request' ref n <- (ABT.out -> ABT.Tm (Request ref n))
pattern EffectBind' id cid args k <- (ABT.out -> ABT.Tm (EffectBind id cid args k))
pattern EffectPure' a <- (ABT.out -> ABT.Tm (EffectPure a))
pattern If' cond t f <- (ABT.out -> ABT.Tm (If cond t f))
pattern And' x y <- (ABT.out -> ABT.Tm (And x y))
pattern Or' x y <- (ABT.out -> ABT.Tm (Or x y))
pattern Handle' h body <- (ABT.out -> ABT.Tm (Handle h body))
pattern Apps' f args <- (unApps -> Just (f, args))
pattern Ann' x t <- (ABT.out -> ABT.Tm (Ann x t))
pattern Vector' xs <- (ABT.out -> ABT.Tm (Vector xs))
pattern Lam' subst <- ABT.Tm' (Lam (ABT.Abs' subst))
pattern LamNamed' v body <- (ABT.out -> ABT.Tm (Lam (ABT.Term _ _ (ABT.Abs v body))))
pattern Let1' b subst <- (unLet1 -> Just (b, subst))
pattern Let1Named' v b e <- (ABT.Tm' (Let b (ABT.out -> ABT.Abs v e)))
pattern Lets' bs e <- (unLet -> Just (bs, e))
pattern LetRecNamed' bs e <- (unLetRecNamed -> Just (bs,e))
pattern LetRec' subst <- (unLetRec -> Just subst)

fresh :: Var v => Term v -> v -> v
fresh = ABT.fresh

-- some smart constructors

var :: a -> v -> AnnotatedTerm2 vt at v a
var = ABT.annotatedVar

var' :: Var v => Text -> Term' vt v
var' = var() . ABT.v'

derived :: Ord v => a -> Hash -> AnnotatedTerm2 vt at v a
derived a = ref a . Reference.Derived

derived' :: Ord v => Text -> Maybe (Term' vt v)
derived' base58 = derived () <$> Hash.fromBase58 base58

ref :: Ord v => a -> Reference -> AnnotatedTerm2 vt at v a
ref a r = ABT.tm' a (Ref r)

builtin :: Ord v => a -> Text -> AnnotatedTerm2 vt at v a
builtin a n = ref a (Reference.Builtin n)

float :: Ord v => a -> Double -> AnnotatedTerm2 vt at v a
float a d = ABT.tm' a (Float d)

boolean :: Ord v => a -> Bool -> AnnotatedTerm2 vt at v a
boolean a b = ABT.tm' a (Boolean b)

int64 :: Ord v => a -> Int64 -> AnnotatedTerm2 vt at v a
int64 a d = ABT.tm' a (Int64 d)

uint64 :: Ord v => a -> Word64 -> AnnotatedTerm2 vt at v a
uint64 a d = ABT.tm' a (UInt64 d)

text :: Ord v => a -> Text -> AnnotatedTerm2 vt at v a
text a = ABT.tm' a . Text

blank :: Ord v => a -> AnnotatedTerm2 vt at v a
blank a = ABT.tm' a Blank

constructor :: Ord v => a -> Reference -> Int -> AnnotatedTerm2 vt at v a
constructor a ref n = ABT.tm' a (Constructor ref n)

-- todo: delete and rename app' to app
app :: Ord v => Term' vt v -> Term' vt v -> Term' vt v
app f arg = ABT.tm (App f arg)

app' :: Ord v => a -> AnnotatedTerm2 vt at v a -> AnnotatedTerm2 vt at v a -> AnnotatedTerm2 vt at v a
app' a f arg = ABT.tm' a (App f arg)

match :: Ord v => a -> AnnotatedTerm2 vt at v a -> [MatchCase (AnnotatedTerm2 vt at v a)] -> AnnotatedTerm2 vt at v a
match a scrutinee branches = ABT.tm' a (Match scrutinee branches)

handle :: Ord v => a -> AnnotatedTerm2 vt at v a -> AnnotatedTerm2 vt at v a -> AnnotatedTerm2 vt at v a
handle a h block = ABT.tm' a (Handle h block)

and :: Ord v => a -> AnnotatedTerm2 vt at v a -> AnnotatedTerm2 vt at v a -> AnnotatedTerm2 vt at v a
and a x y = ABT.tm' a (And x y)

or :: Ord v => a -> AnnotatedTerm2 vt at v a -> AnnotatedTerm2 vt at v a -> AnnotatedTerm2 vt at v a
or a x y = ABT.tm' a (Or x y)

vector :: Ord v => a -> [AnnotatedTerm2 vt at v a] -> AnnotatedTerm2 vt at v a
vector a es = vector' a (Vector.fromList es)

vector' :: Ord v => a -> Vector (AnnotatedTerm2 vt at v a) -> AnnotatedTerm2 vt at v a
vector' a es = ABT.tm' a (Vector es)

apps :: Ord v => AnnotatedTerm2 vt at v a -> [(a, AnnotatedTerm2 vt at v a)] -> AnnotatedTerm2 vt at v a
apps f = foldl' (\f (a,t) -> app' a t f) f

iff :: Ord v => a -> AnnotatedTerm2 vt at v a -> AnnotatedTerm2 vt at v a -> AnnotatedTerm2 vt at v a -> AnnotatedTerm2 vt at v a
iff a cond t f = ABT.tm' a (If cond t f)

ann :: Ord v => Term' vt v -> Type vt -> Term' vt v
ann e t = ABT.tm (Ann e t)

ann' :: Ord v => a -> AnnotatedTerm2 vt at v a -> Type.AnnotatedType vt at -> AnnotatedTerm2 vt at v a
ann' a e t = ABT.tm' a (Ann e t)

-- arya: are we sure we want the two annotations to be the same?
lam :: Ord v => a -> v -> AnnotatedTerm2 vt at v a -> AnnotatedTerm2 vt at v a
lam a v body = ABT.tm' a (Lam (ABT.abs' a v body))

lam' :: Ord v => a -> [v] -> AnnotatedTerm2 vt at v a -> AnnotatedTerm2 vt at v a
lam' a vs body = foldr (lam a) body vs

lam'' :: Ord v => [(a,v)] -> AnnotatedTerm2 vt at v a -> AnnotatedTerm2 vt at v a
lam'' vs body = foldr (uncurry lam) body vs

pattern LetRecNamedAnnotated' ann bs e <- (unLetRecNamedAnnotated -> Just (ann, bs,e))

unLetRecNamedAnnotated :: AnnotatedTerm' vt v a -> Maybe (a, [((a, v), AnnotatedTerm' vt v a)], AnnotatedTerm' vt v a)
unLetRecNamedAnnotated (ABT.CycleA' ann avs (ABT.Tm' (LetRec bs e))) =
  Just (ann, avs `zip` bs, e)
unLetRecNamedAnnotated _ = Nothing

annotatedLetRec :: Ord v => a -> [((a,v), AnnotatedTerm' vt v a)] -> AnnotatedTerm' vt v a -> AnnotatedTerm' vt v a
annotatedLetRec _ [] e = e
annotatedLetRec a bindings e = ABT.cycle' a (foldr (uncurry ABT.abs') z (map fst bindings))
  where
    z = ABT.tm' a (LetRec (map snd bindings) e)

-- | Smart constructor for let rec blocks. Each binding in the block may
-- reference any other binding in the block in its body (including itself),
-- and the output expression may also reference any binding in the block.
letRec :: Ord v => [(v, Term' vt v)] -> Term' vt v -> Term' vt v
letRec [] e = e
letRec bindings e = ABT.cycle (foldr ABT.abs z (map fst bindings))
  where
    z = ABT.tm (LetRec (map snd bindings) e)

-- | Smart constructor for let blocks. Each binding in the block may
-- reference only previous bindings in the block, not including itself.
-- The output expression may reference any binding in the block.
-- todo: delete me
let1_ :: Ord v => [(v,Term' vt v)] -> Term' vt v -> Term' vt v
let1_ bindings e = foldr f e bindings
  where
    f (v,b) body = ABT.tm (Let b (ABT.abs v body))

let1 :: Ord v => [((a, v), AnnotatedTerm2 vt at v a)] -> AnnotatedTerm2 vt at v a -> AnnotatedTerm2 vt at v a
let1 bindings e = foldr f e bindings
  where
    f ((ann,v),b) body = ABT.tm' ann (Let b (ABT.abs' ann v body))

-- let1' :: Var v => [(Text, Term' vt v)] -> Term' vt v -> Term' vt v
-- let1' bs e = let1 [(ABT.v' name, b) | (name,b) <- bs ] e

effectPure :: Ord v => a -> AnnotatedTerm2 vt at v a -> AnnotatedTerm2 vt at v a
effectPure a t = ABT.tm' a (EffectPure t)

effectBind :: Ord v => a -> Reference -> Int -> [AnnotatedTerm2 vt at v a] -> AnnotatedTerm2 vt at v a -> AnnotatedTerm2 vt at v a
effectBind a r cid args k = ABT.tm' a (EffectBind r cid args k)

unLet1 :: Var v => AnnotatedTerm' vt v a -> Maybe (AnnotatedTerm' vt v a, ABT.Subst (F vt a) v a)
unLet1 (ABT.Tm' (Let b (ABT.Abs' subst))) = Just (b, subst)
unLet1 _ = Nothing

-- | Satisfies `unLet (let' bs e) == Just (bs, e)`
unLet :: AnnotatedTerm' vt v a -> Maybe ([(v, AnnotatedTerm' vt v a)], AnnotatedTerm' vt v a)
unLet t = fixup (go t) where
  go (ABT.Tm' (Let b (ABT.out -> ABT.Abs v t))) =
    case go t of (env,t) -> ((v,b):env, t)
  go t = ([], t)
  fixup ([], _) = Nothing
  fixup bst = Just bst

-- | Satisfies `unLetRec (letRec bs e) == Just (bs, e)`
unLetRecNamed :: AnnotatedTerm' vt v a -> Maybe ([(v, AnnotatedTerm' vt v a)], AnnotatedTerm' vt v a)
unLetRecNamed (ABT.Cycle' vs (ABT.Tm' (LetRec bs e)))
  | length vs == length vs = Just (zip vs bs, e)
unLetRecNamed _ = Nothing

unLetRec :: (Monad m, Var v)
         => AnnotatedTerm' vt v a
         -> Maybe ((v -> m v) ->
                   m ([(v, AnnotatedTerm' vt v a)], AnnotatedTerm' vt v a))
unLetRec (unLetRecNamed -> Just (bs, e)) = Just $ \freshen -> do
  vs <- sequence [ freshen v | (v,_) <- bs ]
  let sub = ABT.substsInheritAnnotation (map fst bs `zip` map ABT.var vs)
  pure (vs `zip` [ sub b | (_,b) <- bs ], sub e)
unLetRec _ = Nothing

unApps :: AnnotatedTerm' vt v a -> Maybe (AnnotatedTerm' vt v a, [AnnotatedTerm' vt v a])
unApps t = case go t [] of [] -> Nothing; f:args -> Just (f,args)
  where
  go (App' i o) acc = go i (o:acc)
  go _ [] = []
  go fn args = fn:args

pattern LamsNamed' vs body <- (unLams' -> Just (vs, body))

unLams' :: AnnotatedTerm' vt v a -> Maybe ([v], AnnotatedTerm' vt v a)
unLams' (LamNamed' v body) = case unLams' body of
  Nothing -> Just ([v], body)
  Just (vs, body) -> Just (v:vs, body)
unLams' _ = Nothing

dependencies' :: Ord v => AnnotatedTerm' vt v a -> Set Reference
dependencies' t = Set.fromList . Writer.execWriter $ ABT.visit' f t
  where f t@(Ref r) = Writer.tell [r] *> pure t
        f t = pure t

dependencies :: Ord v => AnnotatedTerm' vt v a -> Set Hash
dependencies e = Set.fromList [ h | Reference.Derived h <- Set.toList (dependencies' e) ]

referencedDataDeclarations :: Ord v => AnnotatedTerm' vt v a -> Set Reference
referencedDataDeclarations t = Set.fromList . Writer.execWriter $ ABT.visit' f t
  where f t@(Constructor r _) = Writer.tell [r] *> pure t
        f t@(Match _ cases) = traverse_ g cases *> pure t where
          g (MatchCase pat _ _) = Writer.tell (Set.toList (referencedDataDeclarationsP pat))
        f t = pure t

referencedDataDeclarationsP :: Pattern -> Set Reference
referencedDataDeclarationsP p = Set.fromList . Writer.execWriter $ go p where
  go (Pattern.As p) = go p
  go (Pattern.Constructor id _ args) = Writer.tell [id] *> traverse_ go args
  go (Pattern.EffectPure p) = go p
  go (Pattern.EffectBind id _ args k) = Writer.tell [id] *> traverse_ go args *> go k
  go _ = pure ()

updateDependencies :: Ord v => Map Reference Reference -> Term v -> Term v
updateDependencies u tm = ABT.rebuildUp go tm where
  go (Ref r) = Ref (Map.findWithDefault r r u)
  go f = f

countBlanks :: Ord v => Term v -> Int
countBlanks t = Monoid.getSum . Writer.execWriter $ ABT.visit' f t
  where f Blank = Writer.tell (Monoid.Sum (1 :: Int)) *> pure Blank
        f t = pure t

-- | If the outermost term is a function application,
-- perform substitution of the argument into the body
betaReduce :: Var v => Term v -> Term v
betaReduce (App' (Lam' f) arg) = ABT.bind f arg
betaReduce e = e

instance Var v => Hashable1 (F v a) where
  hash1 hashCycle hash e =
    let
      (tag, hashed, varint) = (Hashable.Tag, Hashable.Hashed, Hashable.UInt64 . fromIntegral)
    in case e of
      -- So long as `Reference.Derived` ctors are created using the same hashing
      -- function as is used here, this case ensures that references are 'transparent'
      -- wrt hash and hashing is unaffected by whether expressions are linked.
      -- So for example `x = 1 + 1` and `y = x` hash the same.
      Ref (Reference.Derived h) -> Hashable.fromBytes (Hash.toBytes h)
      -- Note: start each layer with leading `1` byte, to avoid collisions with
      -- types, which start each layer with leading `0`. See `Hashable1 Type.F`
      _ -> Hashable.accumulate $ tag 1 : case e of
        UInt64 i -> [tag 64, accumulateToken i]
        Int64 i -> [tag 65, accumulateToken i]
        Float n -> [tag 66, Hashable.Double n]
        Boolean b -> [tag 67, accumulateToken b]
        Text t -> [tag 68, accumulateToken t]
        Blank -> [tag 1]
        Ref (Reference.Builtin name) -> [tag 2, accumulateToken name]
        Ref (Reference.Derived _) -> error "handled above, but GHC can't figure this out"
        App a a2 -> [tag 3, hashed (hash a), hashed (hash a2)]
        Ann a t -> [tag 4, hashed (hash a), hashed (ABT.hash t)]
        Vector as -> tag 5 : varint (Vector.length as) : map (hashed . hash) (Vector.toList as)
        Lam a -> [tag 6, hashed (hash a) ]
        -- note: we use `hashCycle` to ensure result is independent of let binding order
        LetRec as a -> case hashCycle as of
          (hs, hash) -> tag 7 : hashed (hash a) : map hashed hs
        -- here, order is significant, so don't use hashCycle
        Let b a -> [tag 8, hashed $ hash b, hashed $ hash a]
        If b t f -> [tag 9, hashed $ hash b, hashed $ hash t, hashed $ hash f]
        Request r n -> [tag 10, accumulateToken r, varint n]
        EffectPure r -> [tag 11, hashed $ hash r]
        EffectBind r i rs k ->
          [tag 14, accumulateToken r, varint i, varint (length rs)] ++
          (hashed . hash <$> rs ++ [k])
        Constructor r n -> [tag 12, accumulateToken r, varint n]
        Match e branches -> tag 13 : hashed (hash e) : concatMap h branches
          where
            h (MatchCase pat guard branch) =
              concat [[accumulateToken pat],
                      toList (hashed . hash <$> guard),
                      [hashed (hash branch)]]
        Handle h b -> [tag 15, hashed $ hash h, hashed $ hash b]
        And x y -> [tag 16, hashed $ hash x, hashed $ hash y]
        Or x y -> [tag 17, hashed $ hash x, hashed $ hash y]

-- mostly boring serialization code below ...

instance (Eq a, Var v) => Eq1 (F v a) where (==#) = (==)
instance (Show a, Var v) => Show1 (F v a) where showsPrec1 = showsPrec

instance (Var v, Show a0, Show a) => Show (F v a0 a) where
  showsPrec p fa = go p fa where
    showConstructor r n = showsPrec 0 r <> s"#" <> showsPrec 0 n
    go _ (Int64 n) = (if n >= 0 then s "+" else s "") <> showsPrec 0 n
    go _ (UInt64 n) = showsPrec 0 n
    go _ (Float n) = showsPrec 0 n
    go _ (Boolean b) = showsPrec 0 b
    go p (Ann t k) = showParen (p > 1) $ showsPrec 0 t <> s":" <> showsPrec 0 k
    go p (App f x) =
      showParen (p > 9) $ showsPrec 9 f <> s" " <> showsPrec 10 x
    go _ (Lam body) = showParen True (s"λ " <> showsPrec 0 body)
    go _ (Vector vs) = showListWith (showsPrec 0) (Vector.toList vs)
    go _ Blank = s"_"
    go _ (Ref r) = showsPrec 0 r
    go _ (Let b body) = showParen True (s"let " <> showsPrec 0 b <> s" in " <> showsPrec 0 body)
    go _ (LetRec bs body) = showParen True (s"let rec" <> showsPrec 0 bs <> s" in " <> showsPrec 0 body)
    go _ (Handle b body) = showParen True (s"handle " <> showsPrec 0 b <> s " in " <> showsPrec 0 body)
    go _ (Constructor r n) = showConstructor r n
    go _ (Match scrutinee cases) =
      showParen True (s"case " <> showsPrec 0 scrutinee <> s" of " <> showsPrec 0 cases)
    go _ (Text s) = showsPrec 0 s
    go _ (Request r n) = showConstructor r n
    go _ (EffectPure r) = s"{ " <> showsPrec 0 r <> s" }"
    go _ (EffectBind ref i args k) =
      s"{ " <> showConstructor ref i <> showListWith (showsPrec 0) args <>
      s" -> " <> showsPrec 0 k <> s" }"
    go p (If c t f) = showParen (p > 0) $
      s"if " <> showsPrec 0 c <> s" then " <> showsPrec 0 t <>
      s" else " <> showsPrec 0 f
    go p (And x y) = showParen (p > 0) $
      s"and " <> showsPrec 0 x <> s" " <> showsPrec 0 y
    go p (Or x y) = showParen (p > 0) $
      s"or " <> showsPrec 0 x <> s" " <> showsPrec 0 y
    (<>) = (.)
    s = showString
