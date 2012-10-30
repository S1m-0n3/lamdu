{-# LANGUAGE OverloadedStrings, TemplateHaskell #-}
module Editor.CodeEdit.ExpressionEdit.HoleEdit
  ( make, makeUnwrapped
  , searchTermWidgetId
  ) where

import Control.Applicative ((<*>))
import Control.Arrow (first, second, (&&&))
import Control.Monad ((<=<), filterM, liftM, mplus, msum, void)
import Control.Monad.ListT (ListT)
import Data.Function (on)
import Data.Hashable (Hashable, hash)
import Data.List (isInfixOf, isPrefixOf)
import Data.List.Class (List)
import Data.List.Utils (sortOn, nonEmptyAll)
import Data.Maybe (isJust, listToMaybe, maybeToList, mapMaybe, fromMaybe)
import Data.Monoid (Monoid(..))
import Data.Store.Guid (Guid)
import Data.Store.Property (Property(..))
import Data.Store.Transaction (Transaction)
import Editor.Anchors (ViewTag)
import Editor.CodeEdit.ExpressionEdit.ExpressionGui (ExpressionGui(..))
import Editor.CodeEdit.ExpressionEdit.ExpressionGui.Monad (ExprGuiM, WidgetT)
import Editor.ITransaction (ITransaction)
import Editor.MonadF (MonadF)
import Graphics.UI.Bottle.Animation(AnimId)
import Graphics.UI.Bottle.Widget (Widget)
import qualified Data.AtFieldTH as AtFieldTH
import qualified Data.Char as Char
import qualified Data.List.Class as List
import qualified Data.Store.Guid as Guid
import qualified Data.Store.IRef as IRef
import qualified Data.Store.Property as Property
import qualified Editor.Anchors as Anchors
import qualified Editor.BottleWidgets as BWidgets
import qualified Editor.CodeEdit.ExpressionEdit.ExpressionGui as ExpressionGui
import qualified Editor.CodeEdit.ExpressionEdit.ExpressionGui.Monad as ExprGuiM
import qualified Editor.CodeEdit.Sugar as Sugar
import qualified Editor.Config as Config
import qualified Editor.Data as Data
import qualified Editor.ITransaction as IT
import qualified Editor.Layers as Layers
import qualified Editor.WidgetEnvT as WE
import qualified Editor.WidgetIds as WidgetIds
import qualified Graphics.DrawingCombinators as Draw
import qualified Graphics.UI.Bottle.Animation as Anim
import qualified Graphics.UI.Bottle.EventMap as E
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.Box as Box
import qualified Graphics.UI.Bottle.Widgets.FocusDelegator as FocusDelegator
import qualified System.Random as Random

moreSymbol :: String
moreSymbol = "▷"

moreSymbolSizeFactor :: Fractional a => a
moreSymbolSizeFactor = 0.5

data Group = Group
  { groupNames :: [String]
  , groupBaseExpr :: Data.PureExpression
  , groupHashBase :: String
  }
AtFieldTH.make ''Group

type T = Transaction ViewTag

data HoleInfo m = HoleInfo
  { hiHoleId :: Widget.Id
  , hiSearchTerm :: Property (ITransaction ViewTag m) String
  , hiHole :: Sugar.Hole m
  , hiHoleActions :: Sugar.HoleActions m
  , hiGuid :: Guid
  , hiMNextHole :: Maybe (Sugar.Expression m)
  }

pickExpr ::
  Monad m => HoleInfo m -> Sugar.HoleResult -> ITransaction ViewTag m Widget.EventResult
pickExpr holeInfo expr = do
  (guid, _) <- IT.transaction $ Sugar.holePickResult (hiHoleActions holeInfo) expr
  return Widget.EventResult
    { Widget.eCursor = Just $ WidgetIds.fromGuid guid
    , Widget.eAnimIdMapping = id -- TODO: Need to fix the parens id
    }

resultPickEventMap
  :: Monad m
  => HoleInfo m -> Sugar.HoleResult -> Widget.EventHandlers (ITransaction ViewTag m)
resultPickEventMap holeInfo holeResult =
  case hiMNextHole holeInfo of
  Just nextHole
    | not (Sugar.holeResultHasHoles holeResult) ->
      mappend (simplePickRes Config.pickResultKeys) .
      E.keyPresses Config.addNextArgumentKeys
      "Pick result and move to next arg" .
      liftM Widget.eventResultFromCursor $ do
        _ <- IT.transaction $ Sugar.holePickResult (hiHoleActions holeInfo) holeResult
        return . WidgetIds.fromGuid $ Sugar.rGuid nextHole
  _ -> simplePickRes $ Config.pickResultKeys ++ Config.addNextArgumentKeys
  where
    simplePickRes keys =
      E.keyPresses keys "Pick this search result" $
      pickExpr holeInfo holeResult


data ResultsList = ResultsList
  { rlFirstId :: Widget.Id
  , rlMoreResultsPrefixId :: Widget.Id
  , rlFirst :: Sugar.HoleResult
  , rlMore :: Maybe [Sugar.HoleResult]
  }

randomizeResultExpr ::
  Hashable h => HoleInfo m -> h -> Data.Expression a -> Data.Expression a
randomizeResultExpr holeInfo hashBase expr =
  flip Data.randomizeGuids expr . Random.mkStdGen $
  hash (hashBase, Guid.bs (hiGuid holeInfo))

exprHash :: Data.Expression a -> String
exprHash = show . void

resultsToWidgets
  :: MonadF m
  => HoleInfo m -> ResultsList
  -> ExprGuiM m
     ( WidgetT m
     , Maybe (Sugar.HoleResult, Maybe (WidgetT m))
     )
resultsToWidgets holeInfo results = do
  cursorOnMain <- ExprGuiM.otransaction $ WE.isSubCursor myId
  extra <-
    if cursorOnMain
    then liftM (Just . (,) canonizedExpr . fmap fst) makeExtra
    else do
      cursorOnExtra <- ExprGuiM.otransaction $ WE.isSubCursor moreResultsPrefixId
      if cursorOnExtra
        then do
          extra <- makeExtra
          return $ do
            (widget, mResult) <- extra
            result <- mResult
            return (result, Just widget)
        else return Nothing
  liftM (flip (,) extra) .
    maybe return (const addMoreSymbol) (rlMore results) =<<
    toWidget myId canonizedExpr
  where
    makeExtra = maybe (return Nothing) (liftM Just . makeMoreResults) $ rlMore results
    makeMoreResults moreResults = do
      pairs <- mapM moreResult moreResults
      return
        ( Box.vboxAlign 0 $ map fst pairs
        , msum $ map snd pairs
        )
    moreResult expr = do
      mResult <- (liftM . fmap . const) cExpr . ExprGuiM.otransaction $ WE.subCursor resultId
      widget <- toWidget resultId cExpr
      return (widget, mResult)
      where
        resultId = mappend moreResultsPrefixId $ pureGuidId cExpr
        cExpr = randomizeResultExpr holeInfo (exprHash expr) expr
    toWidget resultId expr =
      ExprGuiM.otransaction . BWidgets.makeFocusableView resultId .
      Widget.strongerEvents (resultPickEventMap holeInfo expr) .
      ExpressionGui.egWidget =<<
      ExprGuiM.makeSubexpresion . Sugar.removeTypes =<<
      (ExprGuiM.transaction . Sugar.holeConvertResult (hiHoleActions holeInfo)) expr
    moreResultsPrefixId = rlMoreResultsPrefixId results
    addMoreSymbol w = do
      moreSymbolLabel <-
        liftM (Widget.scale moreSymbolSizeFactor) .
        ExprGuiM.otransaction .
        BWidgets.makeLabel moreSymbol $ Widget.toAnimId myId
      return $ BWidgets.hboxCenteredSpaced [w, moreSymbolLabel]
    canonizedExpr = rlFirst results
    myId = rlFirstId results
    pureGuidId = WidgetIds.fromGuid . Data.eGuid

makeNoResults :: MonadF m => AnimId -> ExprGuiM m (WidgetT m)
makeNoResults myId =
  ExprGuiM.otransaction .
  BWidgets.makeTextView "(No results)" $ mappend myId ["no results"]

mkGroup :: [String] -> Data.ExpressionBody Data.PureExpression -> Group
mkGroup names expr = Group
  { groupNames = names
  , groupBaseExpr = pExpr
  , groupHashBase = exprHash pExpr
  }
  where
    pExpr = toPureExpr expr

makeVariableGroup ::
  MonadF m => (Sugar.GetVariable, Data.VariableRef) -> ExprGuiM m Group
makeVariableGroup (getVar, varRef) =
  ExprGuiM.withNameFromVarRef getVar $ \(_, varName) ->
  return . mkGroup [varName] . Data.ExpressionLeaf $ Data.GetVariable varRef

toPureExpr
  :: Data.ExpressionBody Data.PureExpression -> Data.PureExpression
toPureExpr = Data.pureExpression $ Guid.fromString "ZeroGuid"

renamePrefix :: AnimId -> AnimId -> AnimId -> AnimId
renamePrefix srcPrefix destPrefix animId =
  maybe animId (Anim.joinId destPrefix) $
  Anim.subId srcPrefix animId

holeResultAnimMappingNoParens :: HoleInfo m -> Widget.Id -> AnimId -> AnimId
holeResultAnimMappingNoParens holeInfo resultId =
  renamePrefix ("old hole" : Widget.toAnimId resultId) myId .
  renamePrefix myId ("old hole" : myId)
  where
    myId = Widget.toAnimId $ hiHoleId holeInfo

groupOrdering :: String -> Group -> [Bool]
groupOrdering searchTerm result =
  map not
  [ match (==)
  , match isPrefixOf
  , match insensitivePrefixOf
  , match isInfixOf
  ]
  where
    insensitivePrefixOf = isPrefixOf `on` map Char.toLower
    match f = any (f searchTerm) names
    names = groupNames result

makeLiteralGroup :: String -> [Group]
makeLiteralGroup searchTerm =
  [ makeLiteralIntResult (read searchTerm)
  | nonEmptyAll Char.isDigit searchTerm
  ]
  where
    makeLiteralIntResult integer =
      Group
      { groupNames = [show integer]
      , groupBaseExpr = toPureExpr . Data.ExpressionLeaf $ Data.LiteralInteger integer
      , groupHashBase = "Literal"
      }

resultsPrefixId :: HoleInfo m -> Widget.Id
resultsPrefixId holeInfo = mconcat [hiHoleId holeInfo, Widget.Id ["results"]]

toResultsList ::
  (Monad m, Hashable h) =>
  HoleInfo m -> h -> Data.PureExpression ->
  T m (Maybe ResultsList)
toResultsList holeInfo hashBase baseExpr = do
  results <- Sugar.holeInferResults (hiHole holeInfo) baseExpr
  return $
    case results of
    [] -> Nothing
    (x:xs) ->
      let
        canonizedExpr = randomizeResultExpr holeInfo hashBase x
        canonizedExprId = WidgetIds.fromGuid $ Data.eGuid canonizedExpr
      in Just ResultsList
        { rlFirstId = mconcat [resultsPrefixId holeInfo, canonizedExprId]
        , rlMoreResultsPrefixId = mconcat [resultsPrefixId holeInfo, Widget.Id ["more results"], canonizedExprId]
        , rlFirst = canonizedExpr
        , rlMore =
          case xs of
          [] -> Nothing
          _ -> Just xs
        }

data ResultType = GoodResult | BadResult

makeResultsList ::
  Monad m => HoleInfo m -> Group ->
  T m (Maybe (ResultType, ResultsList))
makeResultsList holeInfo group = do
  -- We always want the first, and we want to know if there's more, so
  -- take 2:
  mRes <- toResultsList holeInfo hashBase baseExpr
  case mRes of
    Just res -> return . Just $ (GoodResult, res)
    Nothing ->
      (liftM . fmap) ((,) BadResult) . toResultsList holeInfo hashBase $ holeApply baseExpr
  where
    hashBase = groupHashBase group
    baseExpr = groupBaseExpr group
    holeApply =
      toPureExpr .
      (Data.makeApply . toPureExpr . Data.ExpressionLeaf) Data.Hole

makeAllResults
  :: MonadF m
  => HoleInfo m
  -> ExprGuiM m (ListT (T m) (ResultType, ResultsList))
makeAllResults holeInfo = do
  paramResults <-
    mapM (makeVariableGroup . first Sugar.GetParameter) $
    Sugar.holeScope hole
  globalResults <-
    mapM (makeVariableGroup . (Sugar.GetDefinition &&& Data.DefinitionRef)) =<<
    ExprGuiM.getP Anchors.globals
  let
    searchTerm = Property.value $ hiSearchTerm holeInfo
    literalResults = makeLiteralGroup searchTerm
    nameMatch = any (insensitiveInfixOf searchTerm) . groupNames
  return .
    List.catMaybes .
    List.mapL (makeResultsList holeInfo) .
    List.fromList .
    sortOn (groupOrdering searchTerm) .
    filter nameMatch $
    literalResults ++
    paramResults ++
    primitiveResults ++
    globalResults
  where
    insensitiveInfixOf = isInfixOf `on` map Char.toLower
    hole = hiHole holeInfo
    primitiveResults =
      [ mkGroup ["Set", "Type"] $ Data.ExpressionLeaf Data.Set
      , mkGroup ["Integer", "ℤ", "Z"] $ Data.ExpressionLeaf Data.IntegerType
      , mkGroup ["->", "Pi", "→", "→", "Π", "π"] $ Data.makePi (Guid.augment "NewPi" (hiGuid holeInfo)) holeExpr holeExpr
      , mkGroup ["\\", "Lambda", "Λ", "λ"] $ Data.makeLambda (Guid.augment "NewLambda" (hiGuid holeInfo)) holeExpr holeExpr
      ]
    holeExpr = toPureExpr $ Data.ExpressionLeaf Data.Hole

addNewDefinitionEventMap ::
  Monad m =>
  HoleInfo m ->
  Widget.EventHandlers (ITransaction ViewTag m)
addNewDefinitionEventMap holeInfo =
  E.keyPresses Config.newDefinitionKeys
  "Add as new Definition" . makeNewDefinition $
  pickExpr holeInfo
  where
    makeNewDefinition holePickResult = do
      newDefI <- IT.transaction $ do
        newDefI <- Anchors.makeDefinition -- TODO: From Sugar
        let
          searchTerm = Property.value $ hiSearchTerm holeInfo
          newName = concat . words $ searchTerm
        Anchors.setP (Anchors.assocNameRef (IRef.guid newDefI)) newName
        Anchors.newPane newDefI
        return newDefI
      defRef <-
        liftM (fromMaybe (error "GetDef should always type-check") . listToMaybe) .
        IT.transaction .
        Sugar.holeInferResults (hiHole holeInfo) .
        toPureExpr . Data.ExpressionLeaf . Data.GetVariable $
        Data.DefinitionRef newDefI
      -- TODO: Can we use pickResult's animIdMapping?
      eventResult <- holePickResult defRef
      maybe (return ()) (IT.transaction . Anchors.savePreJumpPosition) $
        Widget.eCursor eventResult
      return Widget.EventResult {
        Widget.eCursor = Just $ WidgetIds.fromIRef newDefI,
        Widget.eAnimIdMapping =
          holeResultAnimMappingNoParens holeInfo searchTermId
        }
    searchTermId = WidgetIds.searchTermId $ hiHoleId holeInfo

makeSearchTermWidget
  :: MonadF m
  => HoleInfo m -> Widget.Id
  -> Maybe Sugar.HoleResult
  -> ExprGuiM m (ExpressionGui m)
makeSearchTermWidget holeInfo searchTermId mResultToPick =
  ExprGuiM.otransaction .
  liftM
  (flip ExpressionGui (0.5/Config.holeSearchTermScaleFactor) .
   Widget.scale Config.holeSearchTermScaleFactor .
   Widget.strongerEvents pickResultEventMap .
   (Widget.atWEventMap . E.filterChars) (`notElem` "`[]\\")) $
  BWidgets.makeWordEdit (hiSearchTerm holeInfo) searchTermId
  where
    pickResultEventMap =
      maybe mempty (resultPickEventMap holeInfo) mResultToPick

vboxMBiasedAlign ::
  Maybe Box.Cursor -> Box.Alignment -> [Widget f] -> Widget f
vboxMBiasedAlign mChildIndex align =
  maybe Box.toWidget Box.toWidgetBiased mChildIndex .
  Box.makeAlign align Box.vertical

makeResultsWidget
  :: MonadF m
  => HoleInfo m
  -> [ResultsList] -> Bool
  -> ExprGuiM m (Maybe Sugar.HoleResult, WidgetT m)
makeResultsWidget holeInfo firstResults moreResults = do
  firstResultsAndWidgets <-
    mapM (resultsToWidgets holeInfo) firstResults
  (mResult, firstResultsWidget) <-
    case firstResultsAndWidgets of
    [] -> liftM ((,) Nothing) . makeNoResults $ Widget.toAnimId myId
    xs -> do
      let
        mResult =
          listToMaybe . mapMaybe snd $
          zipWith (second . fmap . (,)) [0..] xs
      return
        ( mResult
        , blockDownEvents . vboxMBiasedAlign (fmap fst mResult) 0 $
          map fst xs
        )
  let extraWidgets = maybeToList $ snd . snd =<< mResult
  moreResultsWidgets <-
    ExprGuiM.otransaction $
    if moreResults
    then liftM (: []) . BWidgets.makeLabel "..." $ Widget.toAnimId myId
    else return []
  return
    ( fmap (fst . snd) mResult
    , Widget.scale Config.holeResultScaleFactor .
      BWidgets.hboxCenteredSpaced $
      Box.vboxCentered (firstResultsWidget : moreResultsWidgets) :
      extraWidgets
    )
  where
    myId = hiHoleId holeInfo
    blockDownEvents =
      Widget.weakerEvents $
      Widget.keysEventMap
      [E.ModKey E.noMods E.KeyDown]
      "Nothing (at bottom)" (return ())

adHocTextEditEventMap :: Monad m => Property m String -> Widget.EventHandlers m
adHocTextEditEventMap textProp =
  mconcat . concat $
  [ [ E.filterChars (`notElem` " \n") .
      E.simpleChars "Character" "Append search term character" $
      changeText . flip (++) . (: [])
    ]
  , [ E.keyPresses (map (E.ModKey E.noMods) [E.KeyBackspace, E.KeyDel]) "Delete backwards" $
      changeText init
    | (not . null . Property.value) textProp
    ]
  ]
  where
    changeText f = do
      Property.pureModify textProp f
      return Widget.emptyEventResult

collectResults :: List l => l (ResultType, a) -> List.ItemM l ([a], Bool)
collectResults =
  conclude <=<
  List.splitWhenM (return . (>= Config.holeResultCount) . length . fst) .
  List.scanl step ([], [])
  where
    conclude (notEnoughResults, enoughResultsM) =
      liftM
      ( second (not . null) . splitAt Config.holeResultCount
      . uncurry (on (++) reverse) . last . mappend notEnoughResults
      ) .
      List.toList $
      List.take 2 enoughResultsM
    step results (tag, x) =
      ( case tag of
        GoodResult -> first
        BadResult -> second
      ) (x :) results

makeBackground :: Widget.Id -> Int -> Draw.Color -> Widget f -> Widget f
makeBackground myId level =
  Widget.backgroundColor level $
  mappend (Widget.toAnimId myId) ["hole background"]

operatorHandler ::
  Functor f => E.Doc -> (Char -> f Widget.Id) -> Widget.EventHandlers f
operatorHandler doc handler =
  (fmap . fmap) Widget.eventResultFromCursor .
  E.charGroup "Operator" doc
  Config.operatorChars . flip $ const handler

alphaNumericHandler ::
  Functor f => E.Doc -> (Char -> f Widget.Id) -> Widget.EventHandlers f
alphaNumericHandler doc handler =
  (fmap . fmap) Widget.eventResultFromCursor .
  E.charGroup "Letter/digit" doc
  Config.alphaNumericChars . flip $ const handler

pickEventMap ::
  MonadF m => HoleInfo m -> String -> Maybe Sugar.HoleResult ->
  Widget.EventHandlers (ITransaction ViewTag m)
pickEventMap holeInfo searchTerm (Just result)
  | nonEmptyAll (`notElem` Config.operatorChars) searchTerm =
    operatorHandler "Pick this result and apply operator" $ \x ->
    IT.transaction $ do
      (_, actions) <- Sugar.holePickResult (hiHoleActions holeInfo) result
      liftM (searchTermWidgetId . WidgetIds.fromGuid) $
        Sugar.giveAsArgToOperator actions [x]
  | nonEmptyAll (`elem` Config.operatorChars) searchTerm =
    alphaNumericHandler "Pick this result and resume" $ \x ->
    IT.transaction $ do
      (g, _) <- Sugar.holePickResult (hiHoleActions holeInfo) result
      let
        mTarget
          | g /= hiGuid holeInfo = Just g
          | otherwise = fmap Sugar.rGuid $ hiMNextHole holeInfo
      liftM WidgetIds.fromGuid $ case mTarget of
        Just target -> do
          (`Property.set` [x]) =<< Anchors.assocSearchTermRef target
          return target
        Nothing -> return g
pickEventMap _ _ _ = mempty

markTypeMatchesAsUsed :: Monad m => HoleInfo m -> ExprGuiM m ()
markTypeMatchesAsUsed holeInfo =
  ExprGuiM.markVariablesAsUsed . map fst =<<
  (filterM
   (checkInfer . toPureExpr .
    Data.ExpressionLeaf . Data.GetVariable . snd) .
   Sugar.holeScope . hiHole)
    holeInfo
  where
    checkInfer =
      liftM (isJust . listToMaybe) . ExprGuiM.transaction .
      Sugar.holeInferResults (hiHole holeInfo)

makeActiveHoleEdit :: MonadF m => HoleInfo m -> ExprGuiM m (ExpressionGui m)
makeActiveHoleEdit holeInfo = do
  markTypeMatchesAsUsed holeInfo
  allResults <- makeAllResults holeInfo

  (firstResults, hasMoreResults) <- ExprGuiM.transaction $ collectResults allResults

  cursor <- ExprGuiM.otransaction WE.readCursor
  let
    sub = isJust . flip Widget.subId cursor
    shouldBeOnResult = sub $ resultsPrefixId holeInfo
    isOnResult = any sub $ [rlFirstId, rlMoreResultsPrefixId] <*> firstResults
    assignSource
      | shouldBeOnResult && not isOnResult = cursor
      | otherwise = hiHoleId holeInfo
    destId = head (map rlFirstId firstResults ++ [searchTermId])
  ExprGuiM.assignCursor assignSource destId $ do
    (mSelectedResult, resultsWidget) <-
      makeResultsWidget holeInfo firstResults hasMoreResults
    let
      mResult =
        mplus mSelectedResult .
        fmap rlFirst $ listToMaybe firstResults
      adHocEditor = adHocTextEditEventMap $ hiSearchTerm holeInfo
      eventMap = mconcat
        [ addNewDefinitionEventMap holeInfo
        , pickEventMap holeInfo searchTerm mResult
        ]
    searchTermWidget <- makeSearchTermWidget holeInfo searchTermId mResult
    return .
      ExpressionGui.atEgWidget
      (Widget.strongerEvents eventMap .
       makeBackground (hiHoleId holeInfo)
       Layers.activeHoleBG Config.holeBackgroundColor) $
      ExpressionGui.addBelow
      [ (0.5, Widget.strongerEvents adHocEditor resultsWidget)
      ]
      searchTermWidget
  where
    searchTermId = WidgetIds.searchTermId $ hiHoleId holeInfo
    searchTerm = Property.value $ hiSearchTerm holeInfo

holeFDConfig :: FocusDelegator.Config
holeFDConfig = FocusDelegator.Config
  { FocusDelegator.startDelegatingKey = E.ModKey E.noMods E.KeyEnter
  , FocusDelegator.startDelegatingDoc = "Enter hole"
  , FocusDelegator.stopDelegatingKey = E.ModKey E.noMods E.KeyEsc
  , FocusDelegator.stopDelegatingDoc = "Leave hole"
  }

make ::
  MonadF m => Sugar.Hole m -> Maybe (Sugar.Expression m) -> Guid ->
  Widget.Id -> ExprGuiM m (ExpressionGui m)
make hole mNextHole guid =
  ExpressionGui.wrapDelegated holeFDConfig FocusDelegator.Delegating
  ExpressionGui.atEgWidget $ makeUnwrapped hole mNextHole guid

makeInactiveHoleEdit ::
  MonadF m => Sugar.Hole m -> Widget.Id -> ExprGuiM m (ExpressionGui m)
makeInactiveHoleEdit hole myId =
  liftM
  (ExpressionGui.fromValueWidget .
   makeBackground myId Layers.inactiveHole unfocusedColor) .
  ExprGuiM.otransaction $ BWidgets.makeFocusableTextView "  " myId
  where
    unfocusedColor
      | canPickResult = Config.holeBackgroundColor
      | otherwise = Config.unfocusedReadOnlyHoleBackgroundColor
    canPickResult = isJust $ Sugar.holeMActions hole

makeUnwrapped ::
  MonadF m => Sugar.Hole m -> Maybe (Sugar.Expression m) -> Guid ->
  Widget.Id -> ExprGuiM m (ExpressionGui m)
makeUnwrapped hole mNextHole guid myId = do
  cursor <- ExprGuiM.otransaction WE.readCursor
  searchTermProp <-
    (liftM . Property.atSet . fmap) IT.transaction .
    ExprGuiM.transaction $ Anchors.assocSearchTermRef guid
  case (Sugar.holeMActions hole, Widget.subId myId cursor) of
    (Just holeActions, Just _) ->
      let
        holeInfo = HoleInfo
          { hiHoleId = myId
          , hiSearchTerm = searchTermProp
          , hiHole = hole
          , hiHoleActions = holeActions
          , hiGuid = guid
          , hiMNextHole = mNextHole
          }
      in makeActiveHoleEdit holeInfo
    _ -> makeInactiveHoleEdit hole myId

searchTermWidgetId :: Widget.Id -> Widget.Id
searchTermWidgetId = WidgetIds.searchTermId . FocusDelegator.delegatingId
