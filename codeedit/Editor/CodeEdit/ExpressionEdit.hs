{-# LANGUAGE OverloadedStrings #-}
module Editor.CodeEdit.ExpressionEdit(make) where

import Control.Arrow (first)
import Control.Monad (liftM)
import Data.Monoid (Monoid(..))
import Editor.Anchors (ViewTag)
import Editor.CodeEdit.ExpressionEdit.ExpressionGui (ExpressionGui)
import Editor.ITransaction (ITransaction)
import Editor.MonadF (MonadF)
import Editor.OTransaction (OTransaction)
import Graphics.UI.Bottle.Widget (EventHandlers)
import qualified Editor.BottleWidgets as BWidgets
import qualified Editor.CodeEdit.ExpressionEdit.ApplyEdit as ApplyEdit
import qualified Editor.CodeEdit.ExpressionEdit.BuiltinEdit as BuiltinEdit
import qualified Editor.CodeEdit.ExpressionEdit.ExpressionGui as ExpressionGui
import qualified Editor.CodeEdit.ExpressionEdit.FuncEdit as FuncEdit
import qualified Editor.CodeEdit.ExpressionEdit.HoleEdit as HoleEdit
import qualified Editor.CodeEdit.ExpressionEdit.LiteralEdit as LiteralEdit
import qualified Editor.CodeEdit.ExpressionEdit.PiEdit as PiEdit
import qualified Editor.CodeEdit.ExpressionEdit.SectionEdit as SectionEdit
import qualified Editor.CodeEdit.ExpressionEdit.VarEdit as VarEdit
import qualified Editor.CodeEdit.ExpressionEdit.WhereEdit as WhereEdit
import qualified Editor.CodeEdit.Parens as Parens
import qualified Editor.CodeEdit.Sugar as Sugar
import qualified Editor.Config as Config
import qualified Editor.ITransaction as IT
import qualified Editor.WidgetIds as WidgetIds
import qualified Graphics.UI.Bottle.EventMap as E
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.FocusDelegator as FocusDelegator

data HoleResultPicker m = NotAHole | IsAHole (Maybe (HoleEdit.ResultPicker m))
foldHolePicker
  :: r -> (Maybe (HoleEdit.ResultPicker m) -> r)
  -> HoleResultPicker m -> r
foldHolePicker notHole _isHole NotAHole = notHole
foldHolePicker _notHole isHole (IsAHole x) = isHole x

exprFocusDelegatorConfig :: FocusDelegator.Config
exprFocusDelegatorConfig = FocusDelegator.Config
  { FocusDelegator.startDelegatingKey = E.ModKey E.shift E.KeyRight
  , FocusDelegator.startDelegatingDoc = "Enter subexpression"
  , FocusDelegator.stopDelegatingKey = E.ModKey E.shift E.KeyLeft
  , FocusDelegator.stopDelegatingDoc = "Leave subexpression"
  }

make :: MonadF m => ExpressionGui.Maker m
make sExpr = do
  (holePicker, widget) <- makeEditor sExpr exprId
  typeEdits <- mapM make $ Sugar.rInferredTypes sExpr
  let onReadOnly = Widget.doesntTakeFocus
  return .
    ExpressionGui.atEgWidget
    ( maybe onReadOnly
      (Widget.weakerEvents . expressionEventMap holePicker)
      (Sugar.eActions (Sugar.rEntity sExpr))
    ) .
    -- TODO: Hack hack hack: Probably need to move the addType to the
    -- various expression edit makers, and not here?
    (case map ExpressionGui.egWidget typeEdits of
       [] -> id
       typeEditWidgets ->
         ExpressionGui.addType exprId typeEditWidgets
    ) $ widget
  where
    exprId = WidgetIds.fromGuid . Sugar.guid . Sugar.rEntity $ sExpr

makeEditor
  :: MonadF m
  => Sugar.ExpressionRef m
  -> Widget.Id
  -> OTransaction ViewTag m (HoleResultPicker m, ExpressionGui m)
makeEditor sExpr =
  case Sugar.rExpression sExpr of
  Sugar.ExpressionWhere hasParens w ->
    wrapNonHoleExpr . squareParenify hasParens $
      WhereEdit.makeWithBody make w
  Sugar.ExpressionFunc hasParens f ->
    wrapNonHoleExpr . textParenify hasParens $ FuncEdit.make make f
  Sugar.ExpressionHole hole ->
    isAHole . HoleEdit.make hole . Sugar.guid $ Sugar.rEntity sExpr
  Sugar.ExpressionGetVariable varRef ->
    notAHole {- TODO: May need parenification -} $ VarEdit.make varRef
  Sugar.ExpressionApply hasParens apply ->
    wrapNonHoleExpr . textParenify hasParens $ ApplyEdit.make make apply
  Sugar.ExpressionPi hasParens funcType ->
    wrapNonHoleExpr . textParenify hasParens $ PiEdit.make make funcType
  Sugar.ExpressionSection hasParens section ->
    wrapNonHoleExpr . textParenify hasParens $ SectionEdit.make make section
  Sugar.ExpressionLiteralInteger integer ->
    notAHole $ LiteralEdit.makeInt integer
  Sugar.ExpressionBuiltin builtin ->
    wrapNonHoleExpr $ BuiltinEdit.make builtin
  where
    parenify mkParens hasParens mkWidget myId =
      mkWidget myId >>=
      case hasParens of
      Sugar.HaveParens -> mkParens myId
      Sugar.DontHaveParens -> return
    isAHole = (fmap . liftM . first) IsAHole
    notAHole = (fmap . liftM) ((,) NotAHole)
    wrapNonHoleExpr =
      notAHole .
      BWidgets.wrapDelegated exprFocusDelegatorConfig
      FocusDelegator.Delegating ExpressionGui.atEgWidget
    textParenify = parenify Parens.addHighlightedTextParens
    squareParenify = parenify (Parens.addSquareParens . Widget.toAnimId)

expressionEventMap
  :: MonadF m
  => HoleResultPicker m
  -> Sugar.Actions m
  -> EventHandlers (ITransaction ViewTag m)
expressionEventMap holePicker actions =
  mconcat
    [ giveAsArg
    , callWithArg
    , addArg
    , delete
    , replace
    , lambdaWrap
    , addWhereItem
    , cut
    ]
  where
    itrans = liftM WidgetIds.fromGuid . IT.transaction
    giveAsArg =
      moveUnlessOnHole .
      Widget.keysEventMapMovesCursor
      Config.giveAsArgumentKeys "Give as argument" . itrans $
      Sugar.giveAsArg actions
    callWithArg =
      moveUnlessOnHole .
      Widget.keysEventMapMovesCursor
      Config.callWithArgumentKeys "Call with argument" . itrans $
      Sugar.callWithArg actions
    addArg =
      maybeMempty (Sugar.mNextArg actions) moveToIfHole
      -- Move to next arg overrides add arg's keys.
      `mappend`
      (withPickResultFirst Config.addNextArgumentKeys "Add arg" . itrans $
       Sugar.addNextArg actions)
    delete =
      -- Replace has the keys of Delete if delete is not available:
      maybeMempty (Sugar.mDelete actions) $
      mkEventMap Config.delKeys "Delete" WidgetIds.fromGuid
    cut =
      if isHole then mempty else
      mkEventMap Config.cutKeys "Cut" WidgetIds.fromGuid $
      Sugar.cut actions
    replace =
      if isHole then mempty else
      mkEventMap (Config.replaceKeys ++ Config.delKeys) "Replace" diveGuid $
      Sugar.replace actions
    lambdaWrap =
      mkEventMap Config.lambdaWrapKeys "Lambda wrap" diveParam $
      Sugar.lambdaWrap actions
    addWhereItem =
      mkEventMap Config.addWhereItemKeys "Add where item" diveParam $
      Sugar.addWhereItem actions

    diveGuid = FocusDelegator.delegatingId . WidgetIds.fromGuid
    diveParam = FocusDelegator.delegatingId . WidgetIds.paramId
    mkEventMap keys doc f =
      Widget.keysEventMapMovesCursor keys doc .
      liftM f . IT.transaction

    withPickResultFirst keys doc action =
      case holePicker of
        IsAHole (Just pickResult) ->
          E.keyPresses keys ("Pick result and " ++ doc) $
          combineActions pickResult action
        _ ->
          Widget.keysEventMapMovesCursor keys doc action
    combineActions pickResult action = do
      eventResult <- pickResult
      cursorId <- action
      return $
        (Widget.atECursor . const . Just) cursorId
        eventResult

    moveUnlessOnHole = ifHole $ (const . fmap . liftM . Widget.atECursor . const) Nothing
    isHole = foldHolePicker False (const True) holePicker
    ifHole whenHole = foldHolePicker id whenHole holePicker
    maybeMempty x f = maybe mempty f x
    moveToIfHole nextArg =
      case Sugar.rExpression nextArg of
      Sugar.ExpressionHole{} ->
        withPickResultFirst Config.addNextArgumentKeys "Move to next arg" .
        return . WidgetIds.fromGuid . Sugar.guid . Sugar.rEntity $ nextArg
      _ -> mempty
