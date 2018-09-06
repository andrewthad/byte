{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE BinaryLiterals #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeInType #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UnboxedSums #-}
{-# LANGUAGE UnboxedTuples #-}

module Packed.Bytes.Parser
  ( Parser(..)
  , Result(..)
  , run
  , bigEndianWord16
  , bigEndianWord32
  , decimalWord32
  ) where

import Packed.Bytes (Bytes(..))

import Data.Word (Word32)
import Data.Primitive (ByteArray(..))
import GHC.Word (Word32(W32#),Word16(W16#))
import GHC.Int (Int(I#))
import GHC.Types (TYPE,RuntimeRep(..),IO(..),Type)
import GHC.Exts (State#,Int#,ByteArray#,Word#,(+#),(-#),(>#),
  (<#),(==#),(>=#),(*#),(<=#),
  MutableArray#,MutableByteArray#,writeArray#,unsafeFreezeArray#,newArray#,
  unsafeFreezeByteArray#,newByteArray#,and#,
  plusWord#,timesWord#,indexWord8Array#,eqWord#,andI#,
  clz8#, or#, neWord#, uncheckedShiftL#,int2Word#,word2Int#,quotInt#,
  shrinkMutableByteArray#,copyMutableByteArray#,chr#,gtWord#,
  writeWord32Array#,readFloatArray#,runRW#,ltWord#,minusWord#,
  RealWorld)

type Maybe# (a :: TYPE r) = (# (# #) | a #)
type Either# a (b :: TYPE r) = (# a | b #)

type Result# e (r :: RuntimeRep) (a :: TYPE r) =
  (# Int# , Either# e a #)

data Result e a = Result
  { resultIndex :: !Int
  , resultValue :: !(Either e a)
  } deriving (Eq,Show)

run :: Bytes -> Parser e a -> Result e a
run (Bytes (ByteArray arr) (I# off) (I# len)) (Parser (ParserLevity f)) = case f arr off (off +# len) of
  (# ix, r #) -> case r of
    (# e | #) -> Result (I# (ix -# off)) (Left e)
    (# | a #) -> Result (I# (ix -# off)) (Right a)

newtype Parser e a = Parser { getParser :: ParserLevity e 'LiftedRep a }

newtype ParserLevity e (r :: RuntimeRep) (a :: TYPE r) = ParserLevity
  { getParserLevity ::
       ByteArray# -- input
    -> Int# -- offset
    -> Int# -- end (not length)
    -> Result# e r a
  }

instance Functor (Parser e) where
  {-# INLINE fmap #-}
  -- This is written this way to improve the likelihood that the applicative
  -- rewrite rules fire.
  fmap f p = apParser (pureParser f) p

fmapParser :: (a -> b) -> Parser e a -> Parser e b
fmapParser f (Parser (ParserLevity g)) = Parser $ ParserLevity $ \arr off0 end -> case g arr off0 end of
  (# off1, r #) -> case r of
    (# e | #) -> (# off1, (# e | #) #)
    (# | a #) -> (# off1, (# | f a #) #)

instance Applicative (Parser e) where
  pure = pureParser
  {-# INLINE pure #-}
  (<*>) = apParser
  {-# INLINE (<*>) #-}

-- Require a specified number of bytes to be remaining in the
-- input. If there are not this many bytes present, fail at
-- the current offset. The parsers that use this always consume
-- exactly the same number of bytes.
{-# NOINLINE[2] require #-}
require ::
     Int# -- how many bytes do we need
  -> ( Int# -> e ) -- convert the actual number of bytes into an error
  -> ( Int# -> Int# )
     -- convert the actual number of bytes into the number of
     -- bytes actually consumed (should be less than the argument given it)
  -> (    ByteArray# -- input
       -> Int# -- offset
       -> a
     )
  -> Parser e a
require n toError toConsumed f = Parser $ ParserLevity $ \arr off end ->
  let len = end -# off 
   in case len >=# n of
        1# -> (# off +# n, (# | f arr off #) #)
        _ -> (# off +# toConsumed len, (# toError len | #) #)

atMost ::
     Int# -- the maximal number of bytes that could be consumed
  -> ( ByteArray# -> Int# -> Result# e 'LiftedRep a ) -- parser without bounds checking
  -> Parser e a -- parser with bounds checking
  -> Parser e a
atMost n f (Parser (ParserLevity g)) = Parser $ ParserLevity $ \arr off end ->
  let len = end -# off 
   in case len >=# n of
        1# -> f arr off
        _ -> g arr off end

{-# INLINE bigEndianWord32 #-}
bigEndianWord32 :: e -> Parser e Word32
bigEndianWord32 e = require 4# (\_ -> e) (\_ -> 0#) (\arr off -> W32# (unsafeBigEndianWord32Unboxed arr off))

unsafeBigEndianWord32Unboxed :: ByteArray# -> Int# -> Word#
unsafeBigEndianWord32Unboxed arr off =
  let !byteA = indexWord8Array# arr off
      !byteB = indexWord8Array# arr (off +# 1#)
      !byteC = indexWord8Array# arr (off +# 2#)
      !byteD = indexWord8Array# arr (off +# 3#)
      !theWord = uncheckedShiftL# byteA 24#
           `or#` uncheckedShiftL# byteB 16#
           `or#` uncheckedShiftL# byteC 8#
           `or#` byteD
   in theWord

{-# INLINE bigEndianWord16 #-}
bigEndianWord16 :: e -> Parser e Word16
bigEndianWord16 e = require 2# (\_ -> e) (\_ -> 0#) (\arr off -> W16# (unsafeBigEndianWord16Unboxed arr off))

unsafeBigEndianWord16Unboxed :: ByteArray# -> Int# -> Word#
unsafeBigEndianWord16Unboxed arr off =
  let !byteA = indexWord8Array# arr off
      !byteB = indexWord8Array# arr (off +# 1#)
      !theWord = uncheckedShiftL# byteA 8#
           `or#` byteB
   in theWord

-- | This parser does not allow leading zeroes. Consequently,
-- we can establish an upper bound on the number of bytes this
-- parser will consume. This means that it can typically omit
-- most bounds-checking as it runs.
decimalWord32 :: e -> Parser e Word32
decimalWord32 e = Parser (boxWord32Parser (decimalWord32Unboxed e))
  -- atMost 10#
  -- unsafeDecimalWord32Unboxed
  -- (\x -> case decimalWord32Unboxed)

decimalWord32Unboxed :: forall e. e -> ParserLevity e 'WordRep Word#
decimalWord32Unboxed e = ParserLevity $ \arr off end -> let len = end -# off in case len ># 0# of
  1# -> case unsafeDecimalDigitUnboxedMaybe arr off of
    (# (# #) | #) -> (# off, (# e | #) #)
    (# | initialDigit #) -> case initialDigit of
      0## -> -- zero is special because we do not allow leading zeroes
        case len ># 1# of
          1# -> case unsafeDecimalDigitUnboxedMaybe arr (off +# 1#) of
            (# (# #) | #) -> (# off +# 1#, (# | 0## #) #)
            (# | _ #) -> (# (off +# 2#) , (# e | #) #)
          _ -> (# off +# 1#, (# | 0## #) #)
      _ ->
        let maximumDigits = case gtWord# initialDigit 4## of
              1# -> 8#
              _ -> 9#
            go :: Int# -> Int# -> Word# -> Result# e 'WordRep Word#
            go !ix !counter !acc = case counter ># 0# of
              1# -> case ix <# end of
                1# -> case unsafeDecimalDigitUnboxedMaybe arr ix of
                  (# (# #) | #) -> (# ix, (# | acc #) #)
                  (# | w #) -> go (ix +# 1#) (counter -# 1#) (plusWord# w (timesWord# acc 10##))
                _ -> (# ix, (# | acc #) #)
              _ -> let accTrimmed = acc `and#` 0xFFFFFFFF## in case ix <# end of
                1# -> case unsafeDecimalDigitUnboxedMaybe arr ix of
                  (# (# #) | #) -> case (ltWord# accTrimmed 1000000000##) `andI#` (eqWord# initialDigit 4##) of
                    1# -> (# ix, (# e | #) #)
                    _ -> (# ix, (# | accTrimmed #) #)
                  (# | _ #) -> (# ix, (# e | #) #)
                _ -> case (ltWord# accTrimmed 1000000000##) `andI#` (eqWord# initialDigit 4##) of
                  1# -> (# ix, (# e | #) #)
                  _ -> (# ix, (# | accTrimmed #) #)
         in go ( off +# 1# ) maximumDigits initialDigit
  _ -> (# off, (# e | #) #)

unsafeDecimalDigitUnboxedMaybe :: ByteArray# -> Int# -> Maybe# Word#
unsafeDecimalDigitUnboxedMaybe arr off =
  let !w = minusWord# (indexWord8Array# arr (off +# 0#)) 48##
   in case ltWord# w 10## of
        1# -> (# | w #)
        _ -> (# (# #) | #)

unsafeDecimalDigitUnboxed :: e -> ByteArray# -> Int# -> Either# e Word#
unsafeDecimalDigitUnboxed e arr off =
  let !w = minusWord# (indexWord8Array# arr (off +# 0#)) 48##
   in case ltWord# w 10## of
        1# -> (# | w #)
        _ -> (# e | #)


{-# RULES "parserApplyPure" [~2] forall f n1 toError1 toConsumed1 p1. apParser (pureParser f) (require n1 toError1 toConsumed1 p1) =
      (require n1 toError1 toConsumed1 (\arr off0 -> f (p1 arr off0)))
#-}
{-# RULES "parserApply" [~2] forall n1 toError1 toConsumed1 p1 n2 toError2 toConsumed2 p2. apParser (require n1 toError1 toConsumed1 p1) (require n2 toError2 toConsumed2 p2) =
      (require (n1 +# n2)
        (\i -> case i <# n1 of
          1# -> toError1 i
          _ -> toError2 (n1 -# i)
        )
        (\i -> case i <# n1 of
          1# -> toConsumed1 i
          _ -> n1 +# toConsumed2 (i -# n1)
        )
        (\arr off0 -> p1 arr off0 (p2 arr (off0 +# n1)))
      )
#-}
{-# RULES "parserApplyReassociate" [~2] forall f n1 toError1 toConsumed1 p1 n2 toError2 toConsumed2 p2. apParser (apParser f (require n1 toError1 toConsumed1 p1)) (require n2 toError2 toConsumed2 p2) =
      apParser
        (fmapParser (\g -> \(w1,w2) -> g w1 w2) f)
        (require (n1 +# n2)
          (\i -> case i <# n1 of
            1# -> toError1 i
            _ -> toError2 (n1 -# i)
          )
          (\i -> case i <# n1 of
            1# -> toConsumed1 i
            _ -> n1 +# toConsumed2 (i -# n1)
          )
          (\arr off0 -> (p1 arr off0, p2 arr (off0 +# n1)))
        )
#-}

pureParser :: a -> Parser e a
pureParser a = Parser (ParserLevity (\_ off _ -> (# off, (# | a #) #)))

{-# NOINLINE[2] apParser #-}
apParser :: Parser e (a -> b) -> Parser e a -> Parser e b
apParser (Parser f) (Parser g) = Parser (applyLifted f g)

{-# NOINLINE[2] boxWord32Parser #-}
boxWord32Parser ::
     ParserLevity e 'WordRep Word#
  -> ParserLevity e 'LiftedRep Word32
boxWord32Parser (ParserLevity f) = ParserLevity $ \arr off0 end -> case f arr off0 end of
  (# off1, r #) -> case r of
    (# e | #) -> (# off1, (# e | #) #)
    (# | w #) -> (# off1, (# | W32# w #) #)

boxWord32Word32Parser ::
     ParserLevity e ('TupleRep '[ 'WordRep, 'WordRep ]) (# Word#, Word# #)
  -> ParserLevity e 'LiftedRep (Word32,Word32)
boxWord32Word32Parser = error "Uhoetuhaotn"

applyLifted :: 
     ParserLevity e 'LiftedRep (a -> b)
  -> ParserLevity e 'LiftedRep a
  -> ParserLevity e 'LiftedRep b
applyLifted (ParserLevity f) (ParserLevity g) = ParserLevity $ \arr off0 end -> case f arr off0 end of
  (# off1, r #) -> case r of
    (# e | #) -> (# off1, (# e | #) #)
    (# | a #) -> case g arr off1 end of
      (# off2, r2 #) -> case r2 of
        (# e | #) -> (# off2, (# e | #) #)
        (# | b #) -> (# off2, (# | a b #) #)
-- 
-- data SingRuntimeRep :: RuntimeRep -> Type where
--   SingLifted :: SingRuntimeRep 'LiftedRep
--   SingWord :: SingRuntimeRep 'WordRep
-- 
-- data Ap e a where
--   Pure :: a -> Ap e a
--   Ap :: forall e (r :: RuntimeRep) (a :: TYPE r) (b :: Type). SingRuntimeRep r -> ParserLevity e r a -> Ap e (a -> b) -> Ap e b
-- 
-- newtype Apply :: [ArgType] -> Type -> Type where
--   Apply :: SingRuntimeRep r -> ParserLevity e r a -> Reversed xs -> Function t xs -> Apply ((ArgTypeConstructor r) a ': xs)
-- 
-- consApply :: SingRuntimeRep r -> Apply xs (a -> b) -> a -> ParserLevity e r a -> Apply (x ': xs) b
-- consApply r _ _ = Apply r 
-- 
-- type family ArgTypeConstructor (r :: RuntimeRep) :: TYPE r -> ArgType where
--   ArgTypeConstructor 'WordRep = 'ArgTypeWord
-- 
-- data ArgType :: Type where
--   ArgTypeWord :: TYPE 'WordRep -> ArgType
-- 
-- type family Function (t :: Type) (xs :: [ArgType]) where
--   Function t '[] = t
--   Function t (x ': xs) = FunctionCons t x xs
-- 
-- type family FunctionCons (t :: Type) (x :: ArgType) (xs :: [ArgType]) where
--   FunctionCons t ('ArgTypeWord a) ys = a -> Function t ys
-- 
-- runAp :: Ap e a -> Parser e a
-- runAp (Pure a) = pureParser a
-- runAp (Ap s p f) = Parser (applyLevity s (getParser (runAp f)) p)
-- 
-- applyLevity :: forall (r :: RuntimeRep) e (a :: TYPE r) b.
--      SingRuntimeRep r
--   -> ParserLevity e 'LiftedRep (a -> b)
--   -> ParserLevity e r a
--   -> ParserLevity e 'LiftedRep b
-- applyLevity s f g = case s of
--   SingLifted -> applyLifted f g
-- 
-- 
-- {-# RULES "apply{a,word32}" [~2] forall p1 p2. apParser (pureParser p1) (Parser (boxWord32Parser p2)) = runAp (Ap SingWord p2 (Pure (\w -> p1 (W32# w)))) #-}
-- -- {-# RULES "apply{b,word32}" [~2] forall p1 p2. apParser (runAp p1) (Parser (boxWord32Parser p2)) = runAp (Ap SingWord p2 (Pure (\w -> p1 (W32# w)))) #-}


