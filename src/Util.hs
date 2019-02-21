{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ViewPatterns #-}
module Util where

import Protolude

import Bound
import Bound.Var
import Control.Monad.Trans.Control
import Data.Bifoldable
import Data.HashMap.Lazy(HashMap)
import qualified Data.HashMap.Lazy as HashMap
import Data.HashSet(HashSet)
import qualified Data.HashSet as HashSet
import Data.List.NonEmpty(NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Set(Set)
import qualified Data.Set as Set
import Data.String
import Data.Text(Text)
import qualified Data.Text as Text
import Data.Vector(Vector)
import qualified Data.Vector as Vector
import qualified Data.Vector.Generic as GVector
import qualified Data.Vector.Generic.Base as BVector
import qualified Data.Vector.Generic.Mutable as MVector
import System.IO

type Scope1 = Scope ()

unusedVar :: Traversable f => f (Var b a) -> Maybe (f a)
unusedVar = traverse $ unvar (const Nothing) pure

unusedScope :: (Monad f, Traversable f) => Scope b f a -> Maybe (f a)
unusedScope = unusedVar . fromScope

abstractNone :: Monad f => f a -> Scope b f a
abstractNone = Scope . return . F

instantiate1 :: Monad f => f a -> Scope1 f a -> f a
instantiate1 = Bound.instantiate1

rebind
  :: Monad f
  => (b -> Scope b' f a)
  -> Scope b f a
  -> Scope b' f a
rebind f (Scope s) = Scope $ s >>= unvar (unscope . f) (pure . F)

toSet ::  (Ord a, Foldable f) => f a -> Set a
toSet = foldMap Set.singleton

toVector :: Foldable f => f a -> Vector a
toVector = Vector.fromList . toList

toHashSet ::  (Eq a, Hashable a, Foldable f) => f a -> HashSet a
toHashSet = foldMap HashSet.singleton

toHashMap :: (Eq a, Hashable a, Foldable f) => f (a, b) -> HashMap a b
toHashMap = foldMap (uncurry HashMap.singleton)

bimapScope
  :: Bifunctor f
  => (x -> x')
  -> (y -> y')
  -> Scope b (f x) y
  -> Scope b (f x') y'
bimapScope f g (Scope s) = Scope $ bimap f (fmap (bimap f g)) s

bifoldMapScope
  :: (Bifoldable expr, Monoid m)
  => (x -> m)
  -> (y -> m)
  -> Scope b (expr x) y -> m
bifoldMapScope f g (Scope s) = bifoldMap f (unvar mempty $ bifoldMap f g) s

fromText :: IsString a => Text -> a
fromText = fromString . Text.unpack

-- TODO remove
shower :: (Show a, IsString b) => a -> b
shower = fromString . show

indexed :: Traversable f => f a -> f (Int, a)
indexed x = evalState (traverse go x) 0
  where
    go a = do
      i <- get
      put $! i + 1
      return (i, a)

itraverse :: (Applicative m, Traversable t) => (Int -> a -> m b) -> t a -> m (t b)
itraverse f = traverse (uncurry f) . indexed

iforM :: (Applicative m, Traversable t) => t a -> (Int -> a -> m b) -> m (t b)
iforM = flip itraverse

imap :: Traversable t => (Int -> a -> b) -> t a -> t b
imap f = fmap (uncurry f) . indexed

ifor :: Traversable t => t a -> (Int -> a -> b) -> t b
ifor = flip imap

fst3 :: (a, b, c) -> a
fst3 (a, _, _) = a

snd3 :: (a, b, c) -> b
snd3 (_, b, _) = b

thd3 :: (a, b, c) -> c
thd3 (_, _, c) = c

mapWithPrefix
  :: (v -> Vector v' -> v')
  -> Vector v
  -> Vector v'
mapWithPrefix f vs = result
  where
    result = Vector.imap (\i v -> f v $ Vector.take i result) vs

forWithPrefix
  :: Vector v
  -> (v -> Vector v' -> v')
  -> Vector v'
forWithPrefix = flip mapWithPrefix

mapWithPrefixM
  :: Monad m
  => (v -> Vector v' -> m v')
  -> Vector v
  -> m (Vector v')
mapWithPrefixM f vs
  = constructNM (Vector.length vs)
  $ \vs' -> f (vs Vector.! Vector.length vs') vs'

constructNM
  :: (BVector.Vector v a, Monad m)
  => Int
  -> (v a -> m a)
  -> m (v a)
{-# INLINE constructNM #-}
constructNM len f = fill 0 $ runST $ do
  v <- MVector.new len
  GVector.unsafeFreeze v
  where
    fill i !v | i < len = do
      x <- f $ GVector.unsafeTake i v
      BVector.elemseq v x $ fill (i + 1) $ runST $ do
        v' <- GVector.unsafeThaw v
        MVector.unsafeWrite v' i x
        GVector.unsafeFreeze v'
    fill _ v = return v

nonEmptySome :: Alternative f => f a -> f (NonEmpty a)
nonEmptySome p = (\(x:xs) -> x NonEmpty.:| xs) <$> some p

logBase2 :: FiniteBits b => b -> Int
logBase2 x = finiteBitSize x - 1 - countLeadingZeros x

hashedElemIndex
  :: (Eq a, Hashable a)
  => Vector a
  -> a
  -> Maybe Int
hashedElemIndex xs
  -- Just guessing the cutoff here
  | Vector.length xs <= 16 = flip Vector.elemIndex xs
  | otherwise = flip HashMap.lookup m
  where
    m = toHashMap $ Vector.imap (\i x -> (x, i)) xs

hashedLookup
  :: (Eq a, Hashable a)
  => Vector (a, b)
  -> a
  -> Maybe b
hashedLookup xs
  -- Just guessing the cutoff here
  | Vector.length xs <= 16 = \a -> snd <$> Vector.find ((== a) . fst) xs
  | otherwise = flip HashMap.lookup m
  where
    m = toHashMap xs

fixPoint
  :: Eq a
  => (a -> a)
  -> a
  -> a
fixPoint f a
  | a == a' = a
  | otherwise = fixPoint f a'
  where
    a' = f a

saturate
  :: (Eq a, Hashable a)
  => (a -> HashSet a)
  -> HashSet a
  -> HashSet a
saturate f = fixPoint $ \s -> HashSet.unions $ s : map f (HashSet.toList s)

filterMSet
  :: Applicative f
  => (a -> f Bool)
  -> HashSet a
  -> f (HashSet a)
filterMSet f s
  = HashSet.fromMap . void . HashMap.filter identity
  <$> HashMap.traverseWithKey (\a _ -> f a) (HashSet.toMap s)

withFile :: MonadBaseControl IO m => FilePath -> IOMode -> (Handle -> m r) -> m r
withFile name mode = liftBaseOp $ bracket (openFile name mode) hClose

distinct :: (Foldable t, Hashable a, Eq a) => t a -> Bool
distinct es = HashSet.size (toHashSet es) == length es

pattern Mempty :: (Eq m, Monoid m) => m
pattern Mempty <- ((==) mempty -> True) where Mempty = mempty

allM :: Monad m => (a -> m Bool) -> [a] -> m Bool
allM _ [] = return True
allM p (x:xs) = do
  b <- p x
  if b then
    allM p xs
  else
    return False
