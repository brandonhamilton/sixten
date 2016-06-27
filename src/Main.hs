{-# LANGUAGE OverloadedStrings #-}
module Main where

import Control.Monad.Except
import Data.Bifunctor
import Data.Bitraversable
import Data.Foldable
import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as HS
import Data.List
import Data.Monoid
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import qualified Data.Vector as V
import Data.Void
import System.Environment

import Builtin
import ClosureConvert
import Erase
import qualified Generate
import Infer
import Lift
import qualified LLVM
import Meta
import TCM
import Syntax
import qualified Syntax.Abstract as Abstract
import qualified Syntax.Concrete as Concrete
import qualified Syntax.Lifted as Lifted
import qualified Syntax.Parse as Parse
import qualified Syntax.Resolve as Resolve
import qualified Syntax.Restricted as Restricted
import qualified Syntax.SLambda as SLambda
import Restrict
import Util

processGroup
  :: [(Name, Definition Concrete.Expr Name, Concrete.Expr Name)]
  -> TCM s [(Name, LLVM.B)]
processGroup
  = exposeGroup
  >=> typeCheckGroup
  >=> addGroupToContext
  >=> eraseGroup
  >=> liftGroup
  >=> addLiftedGroupToContext
  >=> closureConvertGroup
  >=> restrictGroup
  >=> liftRestrictedGroup "-lifted"
  >=> addGroupDirectionsToContext
  >=> generateGroup

exposeGroup
  :: [(Name, Definition Concrete.Expr Name, Concrete.Expr Name)]
  -> TCM s [(Name, Definition Concrete.Expr (Var Int v), Scope Int Concrete.Expr v)]
exposeGroup defs = return
  [ ( n
    , s >>>= unvar (pure . B) Concrete.Global
    , t >>>= Concrete.Global
    )
  | ((s, t), (n, _, _)) <- zip (zip abstractedScopes abstractedTypes) defs]
  where
    abstractedScopes = recursiveAbstractDefs [(n, d) | (n, d, _) <- defs]
    abstractedTypes = recursiveAbstract [(n, t) | (n, _, t) <- defs]

typeCheckGroup
  :: [(Name, Definition Concrete.Expr (Var Int (MetaVar Abstract.Expr s)), ScopeM Int Concrete.Expr s)]
  -> TCM s [(Name, Definition Abstract.Expr Void, Abstract.Expr Void)]
typeCheckGroup defs = do
  checkedDefs <- checkRecursiveDefs $ V.fromList defs

  let vf :: a -> TCM s b
      vf _ = throwError "typeCheckGroup"
  checkedDefs' <- traverse (bitraverse (traverse $ traverse vf) (traverse vf)) checkedDefs
  let names = V.fromList [n | (n, _, _) <- defs]
      instDefs =
        [ ( names V.! i
          , instantiateDef (Abstract.Global . (names V.!)) d
          , instantiate (Abstract.Global . (names V.!)) t
          )
        | (i, (d, t)) <- zip [0..] $ V.toList checkedDefs'
        ]
  return instDefs

addGroupToContext
  :: [(Name, Definition Abstract.Expr Void, Abstract.Expr Void)]
  -> TCM s [(Name, Definition Abstract.Expr Void, Abstract.Expr Void)]
addGroupToContext defs = do
  addContext $ HM.fromList $ (\(n, d, t) -> (n, (d, t))) <$> defs
  return defs

eraseGroup
  :: [(Name, Definition Abstract.Expr Void, Abstract.Expr Void)] 
  -> TCM s [(Name, Definition SLambda.SExpr Void)]
eraseGroup defs = forM defs $ \(x, e, _) -> (,) x <$> eraseDef e

liftGroup
  :: [(Name, Definition SLambda.SExpr Void)]
  -> TCM s [(Name, Lifted.SExpr Void)]
liftGroup defs = sequence
  [ do
      e' <- liftSExpr $ vacuous e
      e'' <- traverse (throwError . ("liftGroup " ++) . show) e'
      return (x, e'')
  | (x, Definition e) <- defs
  ]

closureConvertGroup
  :: [(Name, Lifted.SExpr Void)]
  -> TCM s [(Name, Lifted.SExpr Void)]
closureConvertGroup defs = forM defs $ \(x, e) -> do
  e' <- convertSBody $ vacuous e
  e'' <- traverse (throwError . ("closureConvertGroup " ++) . show) e'
  return (x, e'')

addLiftedGroupToContext
  :: [(Name, Lifted.SExpr Void)]
  -> TCM s [(Name, Lifted.SExpr Void)]
addLiftedGroupToContext defs = do
  addLiftedContext $ HM.fromList defs
  return defs

restrictGroup
  :: [(Name, Lifted.SExpr Void)]
  -> TCM s [(Name, Restricted.LBody Void)]
restrictGroup defs = forM defs $ \(x, e) -> do
  e' <- Restrict.restrictBody $ vacuous e
  e'' <- traverse (throwError . ("restrictGroup " ++) . show) e'
  return (x, e'')

liftRestrictedGroup
  :: Name
  -> [(Name, Restricted.LBody Void)]
  -> TCM s [(Name, Restricted.Body Void)]
liftRestrictedGroup name defs = do
  let defs' = Restrict.liftProgram name $ fmap vacuous <$> defs
  traverse (traverse (traverse (throwError . ("liftGroup " ++) . show))) defs'

addGroupDirectionsToContext
  :: [(Name, Restricted.Body Void)]
  -> TCM s [(Name, Restricted.Body Void)]
addGroupDirectionsToContext defs = do
  forM_ defs $ \(x, b) -> case b of
    Restricted.FunctionBody (Restricted.Function retDir xs _) -> addDirections x (retDir, snd <$> xs)
    Restricted.ConstantBody _ -> return ()
  return defs

generateGroup
  :: [(Name, Restricted.Body Void)]
  -> TCM s [(LLVM.B, LLVM.B)]
generateGroup defs = do
  qcindex <- qconstructorIndex
  let defMap = HM.fromList defs
      env = Generate.GenEnv qcindex (`HM.lookup` defMap)
  return $ flip map defs $ \(x, e) ->
    second (fold . intersperse "\n")
      $ Generate.runGen env
      $ Generate.generateBody x $ vacuous e

processFile :: FilePath -> IO ()
processFile file = do
  parseResult <- Parse.parseFromFile Parse.program file
  let resolveResult = Resolve.program <$> parseResult
  case resolveResult of
    Nothing -> return ()
    Just (Left err) -> Text.putStrLn err
    Just (Right resolved) -> do
      let constrs = HS.fromList
                  $ programConstrNames Builtin.context
                  <> programConstrNames resolved
          instCon v
            | v `HS.member` constrs = Concrete.Con $ Left v
            | otherwise = pure v
          resolved' = bimap (>>>= instCon) (>>= instCon) <$> resolved
          groups = dependencyOrder resolved'
      case runTCM (process groups) mempty of
        (Left err, t) -> do
          mapM_ (putDoc . (<> "\n")) t
          putStrLn err
        (Right res, _) -> do
          forM_ (concat res) $ \(_, b) -> do
            Text.putStrLn ""
            Text.putStrLn b
          Text.putStrLn "\ninit:"
          forM_ (concat res) $ \(i, _) ->
            unless (Text.null i) $ Text.putStrLn i
  where
    process groups = do
      addContext Builtin.context
      addLiftedContext Builtin.liftedContext
      mapM (processGroup . fmap (\(n, (d, t)) -> (n, d, t))) groups

main :: IO ()
main = do
  x:_ <- getArgs
  processFile x
