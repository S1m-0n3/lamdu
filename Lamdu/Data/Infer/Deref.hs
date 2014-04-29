{-# LANGUAGE TemplateHaskell, DeriveDataTypeable #-}
module Lamdu.Data.Infer.Deref
  ( M, expr, entireExpr, deref
  , toInferError
  , DerefedTV(..), dValue, dType, dScope, dTV, dContext
  , Error(..)
  , RefData.Restriction(..), ExprRef
  ) where

import Control.Applicative (Applicative(..), (<$>))
import Control.Lens.Operators
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Trans.State (StateT)
import Control.MonadA (MonadA)
import Data.Binary (Binary(..))
import Data.Derive.Binary (makeBinary)
import Data.DeriveTH (derive)
import Data.Function.Decycle (decycle)
import Data.Map (Map)
import Data.Store.Guid (Guid)
import Data.Traversable (traverse)
import Data.Typeable (Typeable)
import Lamdu.Data.Infer.Context (Context)
import Lamdu.Data.Infer.GuidAliases (GuidAliases)
import Lamdu.Data.Infer.RefTags (ExprRef, ParamRef, TagParam)
import Lamdu.Data.Infer.TypedValue (TypedValue, tvVal, tvType)
import qualified Control.Lens as Lens
import qualified Control.Monad.Trans.State as State
import qualified Data.Map as Map
import qualified Data.OpaqueRef as OR
import qualified Data.UnionFind.WithData as UFData
import qualified Lamdu.Data.Expr as Expr
import qualified Lamdu.Data.Expr.Lens as ExprLens
import qualified Lamdu.Data.Infer.Context as Context
import qualified Lamdu.Data.Infer.GuidAliases as GuidAliases
import qualified Lamdu.Data.Infer.Monad as InferM
import qualified Lamdu.Data.Infer.RefData as RefData

data Error def = InfiniteExpr (ExprRef def)
  deriving (Show, Eq, Ord)

type Expr def = RefData.LoadedExpr def (ExprRef def)

-- TODO: Make this a newtype and maybe rename to Context
-- | The stored guid names we know for paremeter refs (different
-- mapping in different subexprs)
type StoredGuids def = [(ParamRef def, Guid)]

data DerefedTV def = DerefedTV
  { _dValue :: Expr def
  , _dType :: Expr def
  , _dScope :: Map Guid (Expr def) -- TODO: Make a separate derefScope action instead of this
  , _dTV :: TypedValue def
  , _dContext :: StoredGuids def
  } deriving (Typeable)
Lens.makeLenses ''DerefedTV
derive makeBinary ''DerefedTV

type M def = StateT (Context def) (Either (Error def))
mError :: Error def -> M def a
mError = lift . Left
mGuidAliases :: StateT (GuidAliases def) (Either (Error def)) a -> M def a
mGuidAliases = Lens.zoom Context.guidAliases

canonizeGuid ::
  MonadA m =>
  StoredGuids def -> ParamRef def -> StateT (GuidAliases def) m Guid
canonizeGuid storedGuidsOfRefs paramRef = do
  paramRep <- GuidAliases.find paramRef
  storedExistingGuids <- do
    aliases <- State.get
    return $ filter ((`GuidAliases.hasGuid` aliases) . snd) storedGuidsOfRefs
  storedGuidsOfReps <-
    storedExistingGuids
    & Lens.traverse . Lens._1 %%~ GuidAliases.find
  case lookup paramRep storedGuidsOfReps of
    Nothing -> State.gets (GuidAliases.guidOfRep paramRep)
    Just storedGuid -> return storedGuid

deref :: StoredGuids def -> ExprRef def -> M def (Expr def)
deref storedGuids =
  decycle go
  where
    go Nothing ref = mError $ InfiniteExpr ref
    go (Just recurse) ref = do
      refData <- Lens.zoom Context.ufExprs (UFData.read ref)
      refData ^. RefData.rdBody
        & Lens.traverse %%~ recurse
        >>= ExprLens.bodyPar %%~ mGuidAliases . canonizeGuid storedGuids
        <&> (`Expr.Expr` ref)

derefScope ::
  StoredGuids def ->
  OR.RefMap (TagParam def) (ExprRef def) ->
  M def (Map Guid (Expr def))
derefScope storedGuids =
  fmap Map.fromList . traverse each . (^@.. Lens.itraversed)
  where
    each (paramRef, ref) = do
      guid <- mGuidAliases $ canonizeGuid storedGuids paramRef
      typeExpr <- deref storedGuids ref
      return (guid, typeExpr)

expr ::
  Expr.Expr ldef Guid (TypedValue def, a) ->
  M def (Expr.Expr ldef Guid (M def (DerefedTV def), a))
expr =
  go []
  where
    go storedGuids (Expr.Expr storedBody (tv, pl)) = do
      newStoredGuids <-
        case storedBody ^? Expr._BodyLam . Expr.lamParamId of
        Nothing -> return storedGuids
        Just storedParamId -> do
          storedParamIdRep <- mGuidAliases $ GuidAliases.getRep storedParamId
          return $ (storedParamIdRep, storedParamId) : storedGuids
      let
        derefTV = do
          scope <- fmap (^. RefData.rdScope) . Lens.zoom Context.ufExprs . UFData.read $ tv ^. tvVal
          DerefedTV
            <$> deref newStoredGuids (tv ^. tvVal)
            <*> deref newStoredGuids (tv ^. tvType)
            <*> derefScope storedGuids (scope ^. RefData.scopeMap)
            <*> pure tv
            <*> pure storedGuids
      storedBody
        & Lens.traverse %%~ go newStoredGuids
        <&> (`Expr.Expr` (derefTV, pl))

entireExpr ::
  Expr.Expr ldef Guid (TypedValue def, a) ->
  M def (Expr.Expr ldef Guid (DerefedTV def, a))
entireExpr = (>>= Lens.sequenceOf (Lens.traverse . Lens._1)) . expr
------- Lifted errors:

toInferError :: Error def -> InferM.Error def
toInferError (InfiniteExpr ref) = InferM.InfiniteExpr ref
