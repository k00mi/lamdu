{-# LANGUAGE DeriveFunctor, DeriveDataTypeable, TemplateHaskell #-}
module Lamdu.Data.Infer.ImplicitVariables
  ( add, Payload(..)
  ) where

import Control.Applicative (Applicative(..), (<$>))
import Control.Lens.Operators
import Control.Monad (void, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State (StateT, execStateT, state)
import Data.Binary (Binary(..), getWord8, putWord8)
import Data.Derive.Binary (makeBinary)
import Data.DeriveTH (derive)
import Data.Foldable (traverse_)
import Data.Store.Guid (Guid)
import Data.Typeable (Typeable)
import Lamdu.Data.Expr (Expr)
import Lamdu.Data.Infer.Context (Context)
import Lamdu.Data.Infer.RefData (RefData)
import Lamdu.Data.Infer.TypedValue (TypedValue(..))
import System.Random (RandomGen, random)
import qualified Control.Lens as Lens
import qualified Control.Monad.Trans.State as State
import qualified Data.Store.Guid as Guid
import qualified Data.UnionFind.WithData as UFData
import qualified Lamdu.Data.Expr as Expr
import qualified Lamdu.Data.Expr.Lens as ExprLens
import qualified Lamdu.Data.Infer as Infer
import qualified Lamdu.Data.Infer.Context as Context
import qualified Lamdu.Data.Infer.GuidAliases as GuidAliases
import qualified Lamdu.Data.Infer.LamWrap as LamWrap
import qualified Lamdu.Data.Infer.Load as Load
import qualified Lamdu.Data.Infer.Monad as InferM
import qualified Lamdu.Data.Infer.RefData as RefData
import qualified Lamdu.Data.Infer.TypedValue as TypedValue

data Payload a = Stored a | AutoGen Guid
  deriving (Eq, Ord, Show, Functor, Typeable)
derive makeBinary ''Payload

outerLambdas :: Lens.Traversal' (Expr def par a) (Expr def par a)
outerLambdas f =
  pure
  & Lens.outside (ExprLens.bodyKindedLam Expr.KVal) .~ fmap (ExprLens.bodyKindedLam Expr.KVal # ) . onLambda
  & Expr.eBody
  where
    onLambda (paramId, paramType, body) =
      (,,) paramId <$> f paramType <*> outerLambdas f body

add ::
  (Show def, Ord def, RandomGen gen) =>
  gen -> def ->
  Load.LoadedExpr def (TypedValue def, a) ->
  StateT (Context def) (Either (InferM.Error def))
  (Load.LoadedExpr def (TypedValue def, Payload a))
add gen def expr =
  expr ^.. outerLambdas . Lens.traverse . Lens._1
  & traverse_ (onEachParamTypeSubexpr def)
  & (`execStateT` gen)
  & (`execStateT` (expr <&> Lens._2 %~ Stored))

isUnrestrictedHole :: RefData def -> Bool
isUnrestrictedHole refData =
  null (refData ^. RefData.rdRestrictions)
  && Lens.has (RefData.rdBody . ExprLens.bodyHole) refData

-- We try to fill each hole *value* of each subexpression of each
-- param *type* with type-vars. Since those are part of the "stored"
-- expr, they have a TV/inferred-type we can use to unify both val and
-- type.
onEachParamTypeSubexpr ::
  (Ord def, RandomGen gen) =>
  def -> TypedValue def ->
  -- TODO: Remove the StateT gen
  StateT gen
  (StateT (Load.LoadedExpr def (TypedValue def, Payload a))
   (StateT (Context def)
    (Either (InferM.Error def)))) ()
onEachParamTypeSubexpr def tv = do
  -- TODO: can use a cached deref here
  iValData <-
    liftContext . Lens.zoom Context.ufExprs . UFData.read $
    tv ^. TypedValue.tvVal
  when (isUnrestrictedHole iValData) $ do
    -- TODO: Use fresh
    paramGuid <- state random
    paramId <-
      liftContext . Lens.zoom Context.guidAliases $ GuidAliases.getRep paramGuid
    -- Make a new type ref for the implicit (we can't just re-use the
    -- given tv type ref because we need to intersect/restrict its
    -- scope)
    -- TODO: If this uses a scope-with-def, it will get itself in
    -- scope. If it doesn't, it won't get next variables in scope...
    implicitTypeRef <-
      liftContext $ Context.freshHole (RefData.emptyScope def)
    -- Wrap with (paramId:implicitTypeRef) lambda
    let
      -- TODO: AutoGen should not have Guid? Just make up guids in GUI?
      newPayload Nothing = AutoGen $ Guid.augment "implicitLam" paramGuid
      newPayload (Just x) = Stored x
    lift State.get
      >>= liftContext . LamWrap.lambdaWrap paramId implicitTypeRef
      -- TODO: Is it OK that we use same AutoGen/guid for new Lam and
      -- new ParamType in here?
      <&> Lens.mapped . Lens._2 %~ joinPayload . newPayload
      >>= lift . State.put
    varScope <-
      liftContext . Lens.zoom Context.ufExprs .
      fmap (^. RefData.rdScope) . UFData.read $ tv ^. TypedValue.tvVal
    -- implicitValRef <= getVar paramId
    implicitValRef <-
      liftContext . Load.exprIntoContext varScope $
      ExprLens.pureExpr . ExprLens.bodyParameterRef # paramId
    -- tv <- TV implicitValRef implicitTypeRef
    let implicit = TypedValue implicitValRef implicitTypeRef
    void . liftContext $ Infer.unify tv implicit
  where
    liftContext = lift . lift

joinPayload :: Payload (Payload a) -> Payload a
joinPayload (AutoGen guid) = AutoGen guid
joinPayload (Stored x) = x
