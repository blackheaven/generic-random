{-# LANGUAGE FlexibleContexts, FlexibleInstances, MultiParamTypeClasses #-}
{-# LANGUAGE TypeApplications, TypeOperators #-}
{-# LANGUAGE DeriveFunctor, GeneralizedNewtypeDeriving #-}
{-# LANGUAGE AllowAmbiguousTypes, ScopedTypeVariables #-}
{-# LANGUAGE DataKinds, KindSignatures #-}
module Generic.Random.Internal.Generic where

import Control.Applicative
import Data.Coerce
import GHC.Generics hiding ( S )
import Test.QuickCheck

-- * Random generators

-- | Pick a constructor with uniform probability, and fill its fields
-- recursively.
--
-- An equivalent definition for @Tree@ is:
--
-- > genericArbitrary :: Arbitrary a => Gen (Tree a)
-- > genericArbitrary =
-- >   oneof
-- >     [ Leaf <$> arbitrary                -- Uses Arbitrary a
-- >     , Node <$> arbitrary <*> arbitrary  -- Uses Arbitrary (Tree a)
-- >     ]
--
-- Note that for many types, 'genericArbitrary' tends to produce big values.
-- For instance for @Tree a@ values are finite but the average number of
-- @Leaf@ and @Node@ constructors is infinite.

genericArbitrary :: (Generic a, GA Unsized (Rep a)) => Gen a
genericArbitrary = ($ repeat 1) . unFreq . fmap to $ ga @Unsized


-- | This allows to specify the probability distribution of constructors
-- as a list of weights, in the same order as the data type definition.
--
-- An equivalent definition for @Tree@ is:
--
-- > genericArbitraryFrequency :: Arbitrary a => [Int] -> Gen (Tree a)
-- > genericArbitraryFrequency [x, y] =
-- >   frequency
-- >     [ (x, Leaf <$> arbitrary)
-- >     , (y, Node <$> arbitrary <*> arbitrary)
-- >     ]

genericArbitraryFrequency
  :: (Generic a, GA Unsized (Rep a))
  => [Int]  -- ^ List of weights for every constructor
  -> Gen a
genericArbitraryFrequency = unFreq . fmap to $ ga @Unsized


-- | The size parameter of 'Gen' is divided among the fields of the chosen
-- constructor.  When it reaches zero, the generator selects a finite term
-- whenever it can find any of the given type.
--
-- The type of 'genericArbitraryFrequency'' has an ambiguous @n@ parameter; it
-- is a type-level natural number of type 'Nat' and it can be specified using
-- the @TypeApplications@ extension. That number determines the maximum /depth/
-- of terms that can be used to end recursion.
--
-- > genericArbitraryFrequency' @n weights
--
-- With @n ~ ''Z'@, the generator looks for a simple nullary constructor.  If none
-- exist at the current type, as is the case for our @Tree@ type, it carries on
-- as in 'genericArbitraryFrequency'.
--
-- > genericArbitraryFrequency' @'Z :: Arbitrary a => [Int] -> Gen (Tree a)
-- > genericArbitraryFrequency' @'Z [x, y] =
-- >   frequency
-- >     [ (x, Leaf <$> arbitrary)
-- >     , (y, scale (`div` 2) $ Node <$> arbitrary <*> arbitrary)
-- >     ]
-- >     -- 2 because Node is 2-ary.
--
-- Here is another example:
--
-- > data Tree' = Leaf1 | Leaf2 | Node3 Tree' Tree' Tree'
-- >   deriving Generic
-- >
-- > instance Arbitrary Tree' where
-- >   arbitrary = genericArbitraryFrequency' [1, 2, 3]
--
-- 'genericArbitraryFrequency'' is equivalent to:
--
-- > genericArbitraryFrequency' @'Z :: [Int] -> Gen Tree'
-- > genericArbitraryFrequency' @'Z [x, y, z] =
-- >   sized $ \n ->
-- >     if n == 0 then
-- >       -- If the size parameter is zero, the non-nullary alternative is discarded.
-- >       frequency $
-- >         [ (x, return Leaf1)
-- >         , (y, return Leaf2)
-- >         ]
-- >     else
-- >       frequency $
-- >         [ (x, return Leaf1)
-- >         , (y, return Leaf2)
-- >         , (z, resize (n `div` 3) node)
-- >         ]
-- >         -- 3 because Node3 is 3-ary
-- >   where
-- >     node = Node3 <$> arbitrary <*> arbitrary <*> arbitrary
--
-- To increase the chances of termination when no nullary constructor is directly
-- available, such as in @Tree@, we can pass a larger depth @n@. The effectiveness
-- of this parameter depends on the concrete type the generator is used for.
--
-- For instance, if we want to generate a value of @Tree ()@, there is a term
-- of depth 1 (represented by @''S' ''Z'@) that we can use to end recursion:
-- @Leaf ()@.
--
-- > genericArbitraryFrequency' @('S 'Z) :: [Int] -> Gen (Tree ())
-- > genericArbitraryFrequency' @('S 'Z) [x, y] =
-- >   sized $ \n ->
-- >     if n == 0 then
-- >       return (Leaf ())
-- >     else
-- >       frequency
-- >         [ (x, Leaf <$> arbitrary)
-- >         , (y, scale (`div` 2) $ Node <$> arbitrary <*> arbitrary)
-- >         ]

genericArbitraryFrequency'
  :: forall (n :: Nat) a
  . (Generic a, GA (Sized n) (Rep a))
  => [Int]  -- ^ List of weights for every constructor
  -> Gen a
genericArbitraryFrequency' = unFreq . fmap to $ ga @(Sized n)


-- | Like 'genericArbitraryFrequency'', but with uniformly distributed
-- constructors.

genericArbitrary'
  :: forall (n :: Nat) a. (Generic a, GA (Sized n) (Rep a)) => Gen a
genericArbitrary' = ($ repeat 1) . unFreq . fmap to $ ga @(Sized n)


-- * Internal

newtype Freq sized a = Freq { unFreq :: [Int] -> Gen a }
  deriving Functor

instance Applicative (Freq sized) where
  pure = Freq . pure . pure
  Freq f <*> Freq x = Freq (liftA2 (<*>) f x)

newtype Gen' sized a = Gen' { unGen' :: Gen a }
  deriving (Functor, Applicative)

data Sized :: Nat -> *
data Unsized

liftGen :: Gen a -> Freq sized a
liftGen = Freq . const

-- | Generic Arbitrary
class GA sized f where
  ga :: Freq sized (f p)

instance GA sized U1 where
  ga = pure U1

instance Arbitrary c => GA sized (K1 i c) where
  ga = liftGen . fmap K1 $ arbitrary

instance GA sized f => GA sized (M1 i c f) where
  ga = fmap M1 ga

instance (GASum (Sized n) f, GASum (Sized n) g, BaseCases n f, BaseCases n g)
  => GA (Sized n) (f :+: g) where
  ga = frequency' gaSum baseCases
    where
      frequency' :: [Gen' sized a] -> Tagged n [[a]] -> Freq sized a
      frequency' as (Tagged a0s) = Freq $ \ws ->
        let
          units = [(w, elements a0) | (w, a0) <- zip ws a0s]
        in
          sized $ \sz -> frequency $
            if sz == 0 && not (null units) then
              units
            else
              [(w, a) | (w, Gen' a) <- zip ws as]

instance (GASum Unsized f, GASum Unsized g) => GA Unsized (f :+: g) where
  ga = frequency' gaSum
    where
      frequency' :: [Gen' sized a] -> Freq sized a
      frequency' as = Freq $ \ws -> frequency
        [(w, a) | (w, Gen' a) <- zip ws as]

instance (GA Unsized f, GA Unsized g) => GA Unsized (f :*: g) where
  ga = liftA2 (:*:) ga ga

instance (GAProduct f, GAProduct g) => GA (Sized n) (f :*: g) where
  ga = constScale' a
    where
      constScale' :: Gen' Unsized a -> Freq (Sized n) a
      constScale' = Freq . const . scale (`div` arity) . unGen'
      (arity, a) = gaProduct


gArbitrarySingle :: forall sized f p . GA sized f => Gen' sized (f p)
gArbitrarySingle = Gen' (unFreq (ga :: Freq sized (f p)) [1])


class GASum sized f where
  gaSum :: [Gen' sized (f p)]

instance (GASum sized f, GASum sized g) => GASum sized (f :+: g) where
  gaSum = (fmap . fmap) L1 gaSum ++ (fmap . fmap) R1 gaSum

instance GA sized f => GASum sized (M1 i c f) where
  gaSum = [gArbitrarySingle]


class GAProduct f where
  gaProduct :: (Int, Gen' Unsized (f p))

instance GA Unsized f => GAProduct (M1 i c f) where
  gaProduct = (1, gArbitrarySingle)

instance (GAProduct f, GAProduct g) => GAProduct (f :*: g) where
  gaProduct = (m + n, liftA2 (:*:) a b)
    where
      (m, a) = gaProduct
      (n, b) = gaProduct


newtype Tagged (a :: Nat) b = Tagged { unTagged :: b }

data Nat = Z | S Nat

class BaseCases (n :: Nat) f where
  baseCases :: Tagged n [[f p]]

baseCases' :: forall n f p. BaseCases n f => Tagged n [f p]
baseCases' = (Tagged . concat . unTagged) (baseCases @n)

instance BaseCases n U1 where
  baseCases = Tagged [[U1]]

instance BaseCases n f => BaseCases n (M1 i c f) where
  baseCases = (coerce :: Tagged n [[f p]] -> Tagged n [[M1 i c f p]]) baseCases

instance BaseCases 'Z (K1 i c) where
  baseCases = Tagged [[]]

instance (Generic c, BaseCases n (Rep c)) => BaseCases ('S n) (K1 i c) where
  baseCases = (Tagged . (fmap . fmap) (K1 . to) . unTagged) (baseCases @n)

instance (BaseCases n f, BaseCases n g) => BaseCases n (f :+: g) where
  baseCases = Tagged $
    (fmap . fmap) L1 (unTagged (baseCases @n)) ++
    (fmap . fmap) R1 (unTagged (baseCases @n))

instance (BaseCases n f, BaseCases n g) => BaseCases n (f :*: g) where
  baseCases = Tagged
    [ liftA2 (:*:)
        (unTagged (baseCases' @n))
        (unTagged (baseCases' @n)) ]