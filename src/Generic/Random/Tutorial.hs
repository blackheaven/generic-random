-- | Generic implementations of
-- [QuickCheck](https://hackage.haskell.org/package/QuickCheck)'s
-- @arbitrary@.
--
-- == Example
--
-- Define your type.
--
-- @
-- data Tree a = Leaf a | Node (Tree a) (Tree a)
--   deriving 'Generic'
-- @
--
-- Pick an 'arbitrary' implementation, specifying the required distribution of
-- data constructors.
--
-- @
-- instance Arbitrary a => Arbitrary (Tree a) where
--   arbitrary = 'genericArbitrary' (8 '%' 9 '%' ())
-- @
--
-- @arbitrary :: 'Gen' (Tree a)@ picks a @Leaf@ with probability 9\/17, or a
-- @Node@ with probability 8\/17, and recursively fills their fields with
-- @arbitrary@.
--
-- For @Tree@, 'genericArbitrary' produces code equivalent to the following:
--
-- @
-- 'genericArbitrary' :: Arbitrary a => 'Weights' (Tree a) -> Gen (Tree a)
-- 'genericArbitrary' (x '%' y '%' ()) =
--   frequency
--     [ (x, Leaf \<$\> arbitrary)
--     , (y, Node \<$\> arbitrary \<*\> arbitrary)
--     ]
-- @
--
-- == Distribution of constructors
--
-- The distribution of constructors can be specified as
-- a special list of /weights/ in the same order as the data type definition.
-- This assigns to each constructor a probability proportional to its weight;
-- in other words, @p_C = weight_C / sumOfWeights@.
--
-- The list of weights is built up with the @('%')@ operator as a cons, and using
-- the unit @()@ as the empty list, in the order corresponding to the data type
-- definition. The uniform distribution can be obtained with 'uniform'.
--
-- === Uniform distribution
--
-- You can specify the uniform distribution (all weights equal) with 'uniform'.
-- ('genericArbitraryU' is available as a shorthand for
-- @'genericArbitrary' 'uniform'@.)
--
-- Note that for many recursive types, a uniform distribution tends to produce
-- big or even infinite values.
--
-- === Typed weights
--
-- /GHC 8.0.1 and above only (base ≥ 4.9)./
--
-- The weights actually have type @'W' \"ConstructorName\"@ (just a newtype
-- around 'Int'), so that you can annotate a weight with its corresponding
-- constructor, and it will be checked that you got the order right.
--
-- This will type-check.
--
-- @
-- ((x :: 'W' \"Leaf\") '%' (y :: 'W' \"Node\") '%' ()) :: 'Weights' (Tree a)
-- (x '%' (y :: 'W' \"Node\") '%' ()) :: 'Weights' (Tree a)
-- @
--
-- This will not: the first requires an order of constructors different from
-- the definition of the @Tree@ type; the second doesn't have the right number
-- of weights.
--
-- @
-- ((x :: 'W' \"Node\") '%' y '%' ()) :: 'Weights' (Tree a)
-- (x '%' y '%' z '%' ()) :: 'Weights' (Tree a)
-- @
--
-- == Ensuring termination
--
-- As mentioned earlier, one must be careful with recursive types
-- to avoid producing extremely large values.
--
-- The alternative generator 'genericArbitrary'' implements a simple strategy to keep
-- values at reasonable sizes: the size parameter of 'Gen' is divided among the
-- fields of the chosen constructor. When it reaches zero, the generator
-- selects a small term of the given type. This generally ensures that the
-- number of constructors remains close to the initial size parameter passed to
-- 'Gen'.
--
-- @
-- 'genericArbitrary'' (x1 '%' ... '%' xn '%' ())
-- @
--
-- Here is an example with nullary constructors:
--
-- @
-- data Bush = Leaf1 | Leaf2 | Node3 Bush Bush Bush
--   deriving Generic
--
-- instance Arbitrary Bush where
--   arbitrary = 'genericArbitrary'' (1 '%' 2 '%' 3 '%' ())
-- @
--
-- Here, 'genericArbitrary'' is equivalent to:
--
-- @
-- 'genericArbitrary'' :: 'Weights' Bush -> Gen Bush
-- 'genericArbitrary'' (x '%' y '%' z '%' ()) =
--   sized $ \\n ->
--     if n == 0 then
--       -- If the size parameter is zero, only nullary alternatives are kept.
--       elements [Leaf1, Leaf2]
--     else
--       frequency
--         [ (x, return Leaf1)
--         , (y, return Leaf2)
--         , (z, resize (n \`div\` 3) node)  -- 3 because Node3 is 3-ary
--         ]
--   where
--     node = Node3 \<$\> arbitrary \<*\> arbitrary \<*\> arbitrary
-- @
--
-- If we want to generate a value of type @Tree ()@, there is a
-- value of depth 1 that we can use to end recursion: @Leaf ()@.
--
-- @
-- 'genericArbitrary'' :: 'Weights' (Tree ()) -> Gen (Tree ())
-- 'genericArbitrary'' (x '%' y '%' ()) =
--   sized $ \\n ->
--     if n == 0 then
--       return (Leaf ())
--     else
--       frequency
--         [ (x, Leaf \<$\> arbitrary)
--         , (y, resize (n \`div\` 2) $ Node \<$\> arbitrary \<*\> arbitrary)
--         ]
-- @
--
-- Because the argument of @Tree@ must be inspected in order to discover
-- values of type @Tree ()@, we incur some extra constraints if we want
-- polymorphism.
--
-- @
-- {-\# LANGUAGE FlexibleContexts, UndecidableInstances \#-}
--
-- instance (Arbitrary a, BaseCase (Tree a))
--   => Arbitrary (Tree a) where
--   arbitrary = 'genericArbitrary'' (1 '%' 2 '%' ())
-- @
--
-- By default, the 'BaseCase' type class looks for all values of minimal depth
-- (constructors have depth @1 + max(0, depths of fields)@).
--
-- This can easily be overriden by declaring a specialized 'BaseCase' instance,
-- such as this one:
--
-- @
-- instance Arbitrary a => 'BaseCase' (Tree a) where
--   'baseCase' = oneof [leaf, simpleNode]
--     where
--       leaf = Leaf \<$\> arbitrary
--       simpleNode = Node \<$\> leaf \<*\> leaf
-- @
--
-- An alternative base case can also be specified directly in the `arbitrary`
-- definition with the 'withBaseCase' combinator.
--
-- 'genericArbitraryRec' is a variant of 'genericArbitrary'' with no base case.
--
-- @
-- instance Arbitrary Bush where
--   arbitrary =
--     'genericArbitraryRec' (1 '%' 2 '%' 3 '%' ())
--       \`withBaseCase\` return Leaf1
-- @
--
-- == Custom generators for some fields
--
-- It is possible to use custom generators instead of 'arbitrary' to generate
-- field values. For example, imagine that 'String' is meant to represent
-- alphanumerical strings only.
--
-- @
-- data User = User {
--   userName :: 'String',
--   userId :: 'Int'
--   } deriving 'Generic'
-- @
--
-- Situation: the 'Arbitrary' instance for 'String' may generate strings with
-- any unicode characters, alphanumerical or not; using @newtype@ wrappers or
-- passing generators explicitly to properties may be impractical.
--
-- The alternative is to declare a (heterogeneous) list of generators to be
-- used when generating fields of the appropriate type...
--
-- @
-- customGens :: GenList '[String, Int]
-- customGens =
--      (listOf (elements (filter isAlphaNum [minBound .. maxBound])))
--   :@ (getNonNegative <$> arbitrary :: Gen Int)
--   :@ Nil
-- @
--
-- And to use the @genericArbitrary@ variants that accept explicit generators.
--
-- @
-- instance Arbitrary User where
--   arbitrary = 'genericArbitrarySingleG' customGens
-- @

module Generic.Random.Tutorial () where

import GHC.Generics
import Generic.Random
