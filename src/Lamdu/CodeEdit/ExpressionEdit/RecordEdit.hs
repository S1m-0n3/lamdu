{-# LANGUAGE OverloadedStrings #-}
module Lamdu.CodeEdit.ExpressionEdit.RecordEdit(make) where

import Control.Applicative ((<$>), (<*>), (*>))
import Control.Lens.Operators
import Control.MonadA (MonadA)
import Data.Monoid (Monoid(..))
import Data.Store.Transaction (Transaction)
import Data.Vector.Vector2 (Vector2(..))
import Lamdu.CodeEdit.ExpressionEdit.ExpressionGui (ExpressionGui)
import Lamdu.CodeEdit.ExpressionEdit.ExpressionGui.Monad (ExprGuiM)
import qualified Control.Lens as Lens
import qualified Graphics.UI.Bottle.EventMap as E
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.Box as Box
import qualified Graphics.UI.Bottle.Widgets.Grid as Grid
import qualified Lamdu.BottleWidgets as BWidgets
import qualified Lamdu.CodeEdit.ExpressionEdit.ExpressionGui as ExpressionGui
import qualified Lamdu.CodeEdit.ExpressionEdit.ExpressionGui.Monad as ExprGuiM
import qualified Lamdu.CodeEdit.ExpressionEdit.FieldEdit as FieldEdit
import qualified Lamdu.CodeEdit.Sugar as Sugar
import qualified Lamdu.Config as Config
import qualified Lamdu.WidgetIds as WidgetIds

type T = Transaction

make ::
  MonadA m =>
  Sugar.Record m (Sugar.Expression m) -> Widget.Id -> ExprGuiM m (ExpressionGui m)
make = ExpressionGui.wrapExpression . makeUnwrapped

makeUnwrapped ::
  MonadA m =>
  Sugar.Record m (Sugar.Expression m) -> Widget.Id -> ExprGuiM m (ExpressionGui m)
makeUnwrapped (Sugar.Record k fields mAddField) myId =
  ExprGuiM.assignCursor myId bracketId $ do
    fieldRows <- mapM makeFieldRow fields
    let fieldsWidget = Grid.toWidget $ Grid.make fieldRows
    bracketWidget <-
      ( ExprGuiM.withFgColor (parensColor k)
      . ExprGuiM.widgetEnv . BWidgets.makeFocusableTextView "{" )
      bracketId
    let
      height = Widget.wSize . Lens._2
      bracketHeight = bracketWidget ^. height
      fieldsHeight = fieldsWidget ^. height
      resizedBracketWidget
        | fieldsHeight > 0 =
          Widget.scale (Vector2 1 (fieldsHeight / bracketHeight)) bracketWidget
        | otherwise = bracketWidget
    return . ExpressionGui.fromValueWidget . Widget.weakerEvents eventMap $
      Box.hboxCentered [resizedBracketWidget, fieldsWidget]
  where
    parensColor Sugar.Type = Config.recordTypeParensColor
    parensColor Sugar.Val = Config.recordValParensColor
    bracketId = Widget.joinId myId ["{"]
    makeFieldRow (Sugar.RecordField mItemActions tag fieldExpr) = do
      ((fieldRefGui, fieldExprGui), resultPickers) <-
        ExprGuiM.listenResultPickers $
        (,)
        <$> FieldEdit.make tag
        <*> ExprGuiM.makeSubexpresion fieldExpr
      let
        itemEventMap = maybe mempty (recordItemEventMap resultPickers) mItemActions
        space = ExpressionGui.fromValueWidget $ Widget.scale Config.fieldScale BWidgets.stdSpaceWidget
      return . ExpressionGui.makeRow $
        [(1, fieldRefGui), (0.5, space), (0, fieldExprGui)]
        & Lens.mapped . Lens._2 . ExpressionGui.egWidget %~
          Widget.weakerEvents itemEventMap
    mkEventMap f mAction keys doc =
      maybe mempty (Widget.keysEventMapMovesCursor keys doc . f) mAction
    eventMap =
      mkEventMap (fmap WidgetIds.fromGuid)
      mAddField Config.recordAddFieldKeys $ E.Doc ["Edit", "Record", "Add First Field"]

recordItemEventMap :: MonadA m => [T m ()] -> Sugar.ListItemActions m -> Widget.EventHandlers (T m)
recordItemEventMap resultPickers (Sugar.ListItemActions addNext delete) =
  mconcat
  [ Widget.keysEventMapMovesCursor Config.recordAddFieldKeys
    (E.Doc ["Edit", "Record", "Add Next Field"]) $ WidgetIds.fromGuid <$> (sequence_ resultPickers *> addNext)
  , Widget.keysEventMapMovesCursor (Config.delForwardKeys ++ Config.delBackwordKeys)
    (E.Doc ["Edit", "Record", "Delete Field"]) $ WidgetIds.fromGuid <$> delete
  ]