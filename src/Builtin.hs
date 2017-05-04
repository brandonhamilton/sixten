{-# LANGUAGE OverloadedStrings, ViewPatterns, MonadComprehensions, PatternSynonyms #-}
module Builtin where

import Control.Applicative
import Data.HashMap.Lazy(HashMap)
import qualified Data.HashMap.Lazy as HashMap
import Data.List.NonEmpty
import Data.Maybe
import Data.Monoid
import Data.Vector(Vector)
import qualified Data.Vector as Vector
import Data.Void

import Backend.Target(Target)
import qualified Backend.Target as Target
import Syntax
import Syntax.Abstract as Abstract
import qualified Syntax.Sized.Closed as Closed
import qualified Syntax.Sized.Definition as Sized
import Util

pattern IntName <- ((==) "Int" -> True) where IntName = "Int"
pattern IntType = Global IntName

pattern ByteName <- ((==) "Byte" -> True) where ByteName = "Byte"
pattern ByteType = Global ByteName

pattern AddIntName <- ((==) "addInt" -> True) where AddIntName = "addInt"
pattern AddInt e1 e2 = App (App (Global AddIntName) Explicit e1) Explicit e2

pattern SubIntName <- ((==) "subInt" -> True) where SubIntName = "subInt"
pattern SubInt e1 e2 = App (App (Global SubIntName) Explicit e1) Explicit e2

pattern MaxIntName <- ((==) "maxInt" -> True) where MaxIntName = "maxInt"
pattern MaxInt e1 e2 = App (App (Global MaxIntName) Explicit e1) Explicit e2

pattern PrintIntName <- ((==) "printInt" -> True) where PrintIntName = "printInt"
pattern PrintInt e1 = App (Global PrintIntName) Explicit e1

pattern TypeName <- ((==) "Type" -> True) where TypeName = "Type"
pattern Type = Global TypeName

pattern SizeOfName <- ((==) "sizeOf" -> True) where SizeOfName = "sizeOf"

pattern RefName <- ((==) "Ref" -> True) where RefName = "Ref"
pattern PtrName <- ((==) "Ptr" -> True) where PtrName = "Ptr"

pattern UnitName <- ((==) "Unit" -> True) where UnitName = "Unit"
pattern UnitType = Global UnitName
pattern MkUnitConstrName <- ((==) "MkUnit" -> True) where MkUnitConstrName = "MkUnit"
pattern MkUnitConstr = QConstr UnitName MkUnitConstrName
pattern MkUnit = Con MkUnitConstr

pattern Closure <- ((== QConstr "Builtin" "CL") -> True) where Closure = QConstr "Builtin" "CL"

pattern Ref = QConstr PtrName RefName

pattern FailName <- ((==) "fail" -> True) where FailName = "fail"
pattern Fail t = App (Global FailName) Explicit t

pattern PiTypeName <- ((==) "Pi_" -> True) where PiTypeName = "Pi_"

pattern NatName <- ((==) "Nat" -> True) where NatName = "Nat"
pattern Nat = Global NatName

pattern ZeroName <- ((==) "Zero" -> True) where ZeroName = "Zero"
pattern ZeroConstr = QConstr NatName ZeroName
pattern Zero = Con ZeroConstr

pattern SuccName <- ((==) "Succ" -> True) where SuccName = "Succ"
pattern SuccConstr = QConstr NatName SuccName
pattern Succ x = App (Con SuccConstr) Explicit x

pattern StringName <- ((==) "String" -> True) where StringName = "String"
pattern MkStringName <- ((==) "MkString" -> True) where MkStringName = "MkString"
pattern MkStringConstr = QConstr StringName MkStringName

pattern ArrayName <- ((==) "Array" -> True) where ArrayName = "Array"
pattern MkArrayName <- ((==) "MkArray" -> True) where MkArrayName = "MkArray"
pattern MkArrayConstr = QConstr ArrayName MkArrayName

pattern PairName <- ((==) "Pair" -> True) where PairName = "Pair"
pattern Pair = Global PairName
pattern MkPairName <- ((==) "MkPair" -> True) where MkPairName = "MkPair"
pattern MkPairConstr = QConstr PairName MkPairName
pattern MkPair a b = App (App (Con MkPairConstr) Explicit a) Explicit b

applyName :: Int -> Name
applyName n = "apply_" <> shower n

papName :: Int -> Int -> Name
papName k m = "pap_" <> shower k <> "_" <> shower m

addInt :: Expr v -> Expr v -> Expr v
addInt (Lit (Integer 0)) e = e
addInt e (Lit (Integer 0)) = e
addInt (Lit (Integer m)) (Lit (Integer n)) = Lit $ Integer $ m + n
addInt e e' = AddInt e e'

maxInt :: Expr v -> Expr v -> Expr v
maxInt (Lit (Integer 0)) e = e
maxInt e (Lit (Integer 0)) = e
maxInt (Lit (Integer m)) (Lit (Integer n)) = Lit $ Integer $ max m n
maxInt e e' = MaxInt e e'

context :: Target -> HashMap Name (Definition Expr Void, Type Void)
context target = HashMap.fromList
  [ (TypeName, opaqueData typeRep Type)
  , (SizeOfName, opaque $ arrow Explicit Type IntType)
  , (PtrName, dataType (Lam mempty Explicit Type $ Scope ptrSize)
                       (arrow Explicit Type Type)
                       [ ConstrDef RefName $ toScope $ fmap B $ arrow Explicit (pure 0)
                                           $ app (Global PtrName) Explicit (pure 0)
                       ])
  , (ByteName, opaqueData byteRep Type)
  , (IntName, opaqueData intRep Type)
  , (NatName, dataType intRep Type
      [ ConstrDef ZeroName $ Scope Nat
      , ConstrDef SuccName $ Scope $ arrow Explicit Nat Nat
      ])
  , (PiTypeName, opaqueData ptrSize Type)
  ]
  where
    cl = fromMaybe (error "Builtin not closed") . closed
    opaqueData sz t = dataType sz t mempty
    opaque t = (Opaque, cl t)
    dataType sz t xs = (DataDefinition (DataDef xs) sz, cl t)
    byteRep = Lit $ Integer 1
    intRep = Lit $ Integer $ Target.intBytes target
    ptrSize = Lit $ Integer $ Target.ptrBytes target
    typeRep = intRep

convertedContext :: Target -> HashMap Name (Sized.Definition Closed.Expr Void)
convertedContext target = HashMap.fromList $ concat
  [[( TypeName
    , constDef $ Closed.Sized typeSize typeSize
    )
  , (SizeOfName
    , funDef (Telescope $ pure (mempty, (), Scope typeSize))
      $ Scope $ Closed.Sized intSize $ pure $ B 0
    )
  , ( PiTypeName
    , constDef $ Closed.Sized intSize ptrSize
    )
  , ( PtrName
    , funDef (Telescope $ pure (mempty, (), Scope typeSize))
      $ Scope $ Closed.Sized intSize ptrSize
    )
  , ( IntName
    , constDef $ Closed.Sized intSize intSize
    )
  , ( ByteName
    , constDef $ Closed.Sized intSize byteSize
    )
  ]
  , [(papName left given, pap target left given) | given <- [1..maxArity - 1], left <- [1..maxArity - given]]
  , [(applyName arity, apply target arity) | arity <- [1..maxArity]]
  ]
  where
    constDef = Sized.ConstantDef Public . Sized.Constant
    funDef tele = Sized.FunctionDef Public Sized.NonClosure . Sized.Function tele
    intSize = Closed.Lit $ Integer $ Target.intBytes target
    typeSize = intSize
    byteSize = Closed.Lit $ Integer 1
    ptrSize = Closed.Lit $ Integer $ Target.ptrBytes target

convertedSignatures :: Target -> HashMap Name Closed.FunSignature
convertedSignatures target
  = flip HashMap.mapMaybeWithKey (convertedContext target) $ \name def ->
    case def of
      Sized.FunctionDef _ _ (Sized.Function tele s) -> case fromScope s of
        Closed.Anno _ t -> Just (tele, toScope t)
        _ -> error $ "Builtin.convertedSignatures " <> show name
      Sized.ConstantDef _ _ -> Nothing

deref :: Target -> Closed.Expr v -> Closed.Expr v
deref target e
  = Closed.Case (Closed.Sized intSize e)
  $ ConBranches
  $ pure
    ( Ref
    , Telescope
      $ pure ("dereferenced", (), Scope unknownSize)
    , toScope
    $ Closed.Var $ B 0
    )
  where
    unknownSize = global "Builtin.deref.UnknownSize"
    intSize = Closed.Lit $ Integer $ Target.ptrBytes target

maxArity :: Num n => n
maxArity = 6

apply :: Target -> Int -> Sized.Definition Closed.Expr Void
apply target numArgs
  = Sized.FunctionDef Public Sized.NonClosure
  $ Sized.Function
    (Telescope
    $ Vector.cons ("this", (), Scope ptrSize)
    $ (\n -> (fromText $ "size" <> shower (unTele n), (), Scope intSize)) <$> Vector.enumFromN 0 numArgs
    <|> (\n -> (fromText $ "x" <> shower (unTele n), (), Scope $ pure $ B $ 1 + n)) <$> Vector.enumFromN 0 numArgs)
  $ toScope
  $ Closed.Sized (Closed.Global "Builtin.apply.unknownSize")
  $ Closed.Case (deref target $ Closed.Var $ B 0)
  $ ConBranches
  $ pure
    ( Closure
    , Telescope
      $ Vector.fromList [("f_unknown", (), Scope ptrSize), ("n", (), Scope intSize)]
    , toScope
      $ Closed.Case (Closed.Sized intSize $ Closed.Var $ B 1)
      $ LitBranches
        [(Integer $ fromIntegral arity, br arity) | arity <- 1 :| [2..maxArity]]
        $ Closed.Call (global FailName) $ pure $ Closed.Sized intSize (Closed.Lit $ Integer 1)
    )
  where
    intSize = Closed.Lit $ Integer $ Target.intBytes target
    ptrSize = Closed.Lit $ Integer $ Target.ptrBytes target

    directPtr = Direct $ Target.ptrBytes target
    directInt = Direct $ Target.intBytes target

    br :: Int -> Closed.Expr (Var Tele (Var Tele Void))
    br arity
      | numArgs < arity
        = Closed.Con Ref
        $ pure
        $ sizedCon target (Closed.Lit $ Integer 0) Closure
        $ Vector.cons (Closed.Sized ptrSize $ global $ papName (arity - numArgs) numArgs)
        $ Vector.cons (Closed.Sized intSize $ Closed.Lit $ Integer $ fromIntegral $ arity - numArgs)
        $ Vector.cons (Closed.Sized ptrSize $ Closed.Var $ F $ B 0)
        $ (\n -> Closed.Sized intSize $ Closed.Var $ F $ B $ 1 + n) <$> Vector.enumFromN 0 numArgs
        <|> (\n -> Closed.Sized (Closed.Var $ F $ B $ 1 + n) $ Closed.Var $ F $ B $ 1 + Tele numArgs + n) <$> Vector.enumFromN 0 numArgs
      | numArgs == arity
        = Closed.PrimCall (ReturnIndirect OutParam) (Closed.Var $ B 0)
        $ Vector.cons (Closed.Sized ptrSize $ Closed.Var $ F $ B 0, directPtr)
        $ (\n -> (Closed.Sized intSize $ Closed.Var $ F $ B $ 1 + n, directInt)) <$> Vector.enumFromN 0 numArgs
        <|> (\n -> (Closed.Sized (Closed.Var $ F $ B $ 1 + n) $ Closed.Var $ F $ B $ 1 + Tele numArgs + n, Indirect)) <$> Vector.enumFromN 0 numArgs
      | otherwise
        = Closed.Call (global $ applyName $ numArgs - arity)
        $ Vector.cons
          (Closed.Sized ptrSize
          $ Closed.PrimCall (ReturnIndirect OutParam) (Closed.Var $ B 0)
          $ Vector.cons (Closed.Sized ptrSize $ Closed.Var $ F $ B 0, directPtr)
          $ (\n -> (Closed.Sized intSize $ Closed.Var $ F $ B $ 1 + n, directInt)) <$> Vector.enumFromN 0 arity
          <|> (\n -> (Closed.Sized (Closed.Var $ F $ B $ 1 + n) $ Closed.Var $ F $ B $ 1 + fromIntegral numArgs + n, Indirect)) <$> Vector.enumFromN 0 arity)
        $ (\n -> Closed.Sized intSize $ Closed.Var $ F $ B $ 1 + n) <$> Vector.enumFromN (fromIntegral arity) (numArgs - arity)
        <|> (\n -> Closed.Sized (Closed.Var $ F $ B $ 1 + n) $ Closed.Var $ F $ B $ 1 + fromIntegral numArgs + n) <$> Vector.enumFromN (fromIntegral arity) (numArgs - arity)

pap :: Target -> Int -> Int -> Sized.Definition Closed.Expr Void
pap target k m
  = Sized.FunctionDef Public Sized.NonClosure
  $ Sized.Function
    (Telescope
    $ Vector.cons ("this", (), Scope intSize)
    $ (\n -> (fromText $ "size" <> shower (unTele n), (), Scope intSize)) <$> Vector.enumFromN 0 k
    <|> (\n -> (fromText $ "x" <> shower (unTele n), (), Scope $ pure $ B $ 1 + n)) <$> Vector.enumFromN 0 k)
  $ toScope
  $ Closed.Sized (Closed.Global "Builtin.pap.unknownSize")
  $ Closed.Case (deref target $ Closed.Var $ B 0)
  $ ConBranches
  $ pure
    ( Closure
    , Telescope
      $ Vector.cons ("_", (), Scope intSize)
      $ Vector.cons ("_", (), Scope intSize)
      $ Vector.cons ("that", (), Scope intSize)
      $ (\n -> (fromText $ "size" <> shower (unTele n), (), Scope intSize)) <$> Vector.enumFromN 0 m
      <|> (\n -> (fromText $ "y" <> shower (unTele n), (), Scope $ pure $ B $ 3 + n)) <$> Vector.enumFromN 0 m
    , toScope
      $ Closed.Call (global $ applyName $ m + k)
      $ Vector.cons (Closed.Sized ptrSize $ Closed.Var $ B 2)
      $ (\n -> Closed.Sized intSize $ Closed.Var $ B $ 3 + n) <$> Vector.enumFromN 0 m
      <|> (\n -> Closed.Sized intSize $ Closed.Var $ F $ B $ 1 + n) <$> Vector.enumFromN 0 k
      <|> (\n -> Closed.Sized (Closed.Var $ B $ 3 + n) $ Closed.Var $ B $ 3 + Tele m + n) <$> Vector.enumFromN 0 m
      <|> (\n -> Closed.Sized (Closed.Var $ F $ B $ 1 + n) $ Closed.Var $ F $ B $ 1 + Tele k + n) <$> Vector.enumFromN 0 k
    )
  where
    intSize = Closed.Lit $ Integer $ Target.intBytes target
    ptrSize = Closed.Lit $ Integer $ Target.ptrBytes target

addInts :: Target -> Vector (Closed.Expr v) -> Closed.Expr v
addInts target = Vector.foldr1 go
  where
    go x y
      = Closed.Call (global AddIntName)
      $ Vector.cons (Closed.Anno x intSize)
      $ pure $ Closed.Anno y intSize
    intSize = Closed.Lit $ Integer $ Target.intBytes target

sizedCon :: Target -> Closed.Expr v -> QConstr -> Vector (Closed.Expr v) -> Closed.Expr v
sizedCon target tagSize qc args
  = Closed.Sized (addInts target $ Vector.cons tagSize argSizes) (Closed.Con qc args)
  where
    argSizes = Closed.sizeOf <$> args
