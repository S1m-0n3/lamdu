module Lamdu.Data.Infer.MakeTypes (makeTV) where

import Control.Applicative (Applicative(..), (<$>))
import Control.Lens.Operators
import Control.Monad (void, when)
import Lamdu.Data.Infer.Monad (Infer, Error(..))
import Lamdu.Data.Infer.RefData (Scope, LoadedBody, scopeNormalizeParamRefs)
import Lamdu.Data.Infer.RefTags (ExprRef, ParamRef)
import Lamdu.Data.Infer.Rule (verifyTagId)
import Lamdu.Data.Infer.TypedValue (TypedValue(..), tvVal, tvType)
import Lamdu.Data.Infer.Unify (unify, forceLam, unifyBody)
import qualified Control.Lens as Lens
import qualified Data.Monoid as Monoid
import qualified Data.UnionFind.WithData as UFData
import qualified Lamdu.Data.Expr as Expr
import qualified Lamdu.Data.Expr.Lens as ExprLens
import qualified Lamdu.Data.Infer.Context as Context
import qualified Lamdu.Data.Infer.GuidAliases as GuidAliases
import qualified Lamdu.Data.Infer.Load as Load
import qualified Lamdu.Data.Infer.Monad as InferM
import qualified Lamdu.Data.Infer.RefData as RefData
import qualified Lamdu.Data.Infer.Rule.Apply as RuleApply
import qualified Lamdu.Data.Infer.Rule.GetField as RuleGetField
import qualified Lamdu.Data.Infer.Rule.Uncircumsize as RuleUncircumsize
import qualified Lamdu.Data.Infer.Trigger as Trigger

scopeLookup :: Scope def -> ParamRef def -> Infer def (ExprRef def)
scopeLookup scope param = do
  scopeNorm <- InferM.liftGuidAliases $ scopeNormalizeParamRefs scope
  guidRep <- InferM.liftGuidAliases $ GuidAliases.find param
  case scopeNorm ^. RefData.scopeMap . Lens.at guidRep of
    Nothing -> InferM.error VarNotInScope
    Just ref -> pure ref

makePiTypeOfLam ::
  par -> TypedValue def -> TypedValue def ->
  Expr.Body (Load.LoadedDef def) par (ExprRef def)
makePiTypeOfLam paramGuid paramType body =
  Expr.BodyLam $
  Expr.Lam Expr.KType paramGuid
  (paramType ^. tvVal)
  -- We rely on the scope of the Lam KVal body being equal to the
  -- scope of the Lam KType body, because we use the same
  -- paramGuid. This means param guids cannot be unique.
  (body ^. tvType)

maybeCircumsize ::
  Ord def =>
  Scope def ->
  TypedValue def ->
  LoadedBody def (TypedValue def) ->
  Infer def (ExprRef def)
maybeCircumsize scope applicant uncircumsizedValBody = do
  -- We only maybeCircumsize non-tags:
  valRef <-
    RefData.defaultRefData scope (ExprLens.bodyHole # ())
    & RefData.rdWasNotDirectlyTag .~ Monoid.Any True
    & Context.freshData
    & InferM.liftContext
  RuleUncircumsize.make valRef
    (applicant ^. tvVal)
    (uncircumsizedValBody <&> (^. tvVal))
  return valRef

makeApplyTV ::
  Ord def =>
  Scope def -> Expr.Apply (TypedValue def) -> TypedValue def ->
  Infer def ()
makeApplyTV applyScope apply@(Expr.Apply func arg) dest = do
  funcScope <-
    UFData.read (func ^. tvType)
    & InferM.liftUFExprs
    <&> (^. RefData.rdScope)
  (piParam, piParamType, piResultRef) <- forceLam Expr.KType funcScope $ func ^. tvType
  void $ unify (arg ^. tvType) piParamType
  RuleApply.make piParam (arg ^. tvVal) piResultRef (dest ^. tvType)
  void . unify (dest ^. tvVal) =<< maybeCircumsize applyScope func (Expr.BodyApply apply)

addTagVerification :: ExprRef def -> Infer def ()
addTagVerification = Trigger.add [RefData.MustBeTag] Trigger.OnDirectlyTag verifyTagId

makeGetFieldTV ::
  Ord def =>
  Scope def -> Expr.GetField (TypedValue def) -> TypedValue def ->
  Infer def ()
makeGetFieldTV scope getField@(Expr.GetField record tag) dest = do
  unifyBody (tag ^. tvType) scope (ExprLens.bodyTagType # ())
  addTagVerification $ tag ^. tvVal
  RuleGetField.make (tag ^. tvVal) (dest ^. tvType) (record ^. tvType)
  void . unify (dest ^. tvVal) =<< maybeCircumsize scope record (Expr.BodyGetField getField)

makeLambdaType ::
  Ord def =>
  Scope def -> ParamRef def -> TypedValue def -> TypedValue def ->
  Infer def (LoadedBody def (ExprRef def))
makeLambdaType scope paramRef paramType result = do
  unifyBody (paramType ^. tvType) scope (ExprLens.bodyType # ())
  return $ makePiTypeOfLam paramRef paramType result

makeRecordType ::
  Ord def =>
  Expr.Kind -> Scope def ->
  [(TypedValue def, TypedValue def)] ->
  Infer def (LoadedBody def (ExprRef def))
makeRecordType k scope fields = do
  fields & Lens.traverseOf_ (Lens.traverse . Lens._1 . tvType) (mkBody (ExprLens.bodyTagType # ()))
  fields & Lens.traverseOf_ (Lens.traverse . Lens._1 . tvVal) addTagVerification
  when (k == Expr.KType) $
    fields & Lens.traverseOf_ (Lens.traverse . Lens._2 . tvType) (mkBody (ExprLens.bodyType # ()))
  return $
    case k of
    Expr.KVal -> Expr.BodyRecord . Expr.Record Expr.KType $ onRecVField <$> fields
    Expr.KType -> ExprLens.bodyType # ()
  where
    mkBody body ref = unifyBody ref scope body
    onRecVField (tag, val) = (tag ^. tvVal, val ^. tvType)

makeTV ::
  Ord def =>
  Scope def ->
  LoadedBody def (TypedValue def) ->
  TypedValue def ->
  Infer def ()
makeTV scope body dest =
  case body of
  Expr.BodyLeaf Expr.Hole -> return ()
  -- Simple types
  Expr.BodyLeaf Expr.Type -> typeIsType
  Expr.BodyLeaf Expr.IntegerType -> typeIsType
  Expr.BodyLeaf Expr.TagType -> typeIsType
  Expr.BodyLeaf Expr.LiteralInteger {} -> do
    loadGivenVal
    setType (ExprLens.bodyIntegerType # ())
  Expr.BodyLeaf Expr.Tag {} -> do
    loadGivenVal
    setType (ExprLens.bodyTagType # ())
  -- GetPars
  Expr.BodyLeaf (Expr.GetVariable (Expr.DefinitionRef (Load.LoadedDef _ ref))) -> do
    loadGivenVal
    void $ unify (dest ^. tvType) ref
  Expr.BodyLeaf (Expr.GetVariable (Expr.ParameterRef param)) -> do
    loadGivenVal
    void $ unify (dest ^. tvType) =<< scopeLookup scope param
  -- Complex:
  Expr.BodyGetField getField -> makeGetFieldTV scope getField dest
  Expr.BodyApply apply -> makeApplyTV scope apply dest
  Expr.BodyLam (Expr.Lam Expr.KType _ paramType result) -> do
    typeIsType
    unifyBody (paramType ^. tvType) scope bodyType
    unifyBody (result ^. tvType) scope bodyType
  Expr.BodyLam (Expr.Lam Expr.KVal paramGuid paramType result) -> do
    loadGivenVal
    setType =<< makeLambdaType scope paramGuid paramType result
  Expr.BodyRecord (Expr.Record k fields) -> do
    loadGivenVal
    setType =<< makeRecordType k scope fields
  where
    loadGivenVal = unifyBody (dest ^. tvVal) scope (body <&> (^. tvVal))
    setType = unifyBody (dest ^. tvType) scope
    bodyType = ExprLens.bodyType # ()
    typeIsType = do
      loadGivenVal
      setType bodyType
