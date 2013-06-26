{-# LANGUAGE TypeFamilies #-}
module Lamdu.CodeEdit.ExpressionEdit.InferredEdit(make) where

import Control.Applicative ((<$>))
import Control.Lens.Operators
import Control.MonadA (MonadA)
import Data.Monoid (mempty)
import Data.Store.Guid (Guid)
import Lamdu.CodeEdit.ExpressionEdit.ExpressionGui (ExpressionGui, ParentPrecedence(..))
import Lamdu.CodeEdit.ExpressionEdit.ExpressionGui.Monad (ExprGuiM)
import Lamdu.Config (Config)
import qualified Graphics.UI.Bottle.EventMap as E
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.FocusDelegator as FocusDelegator
import qualified Lamdu.GUI.BottleWidgets as BWidgets
import qualified Lamdu.CodeEdit.ExpressionEdit.ExpressionGui as ExpressionGui
import qualified Lamdu.CodeEdit.ExpressionEdit.ExpressionGui.Monad as ExprGuiM
import qualified Lamdu.CodeEdit.ExpressionEdit.HoleEdit as HoleEdit
import qualified Lamdu.CodeEdit.Sugar.Types as Sugar
import qualified Lamdu.Config as Config
import qualified Lamdu.WidgetEnvT as WE
import qualified Lamdu.WidgetIds as WidgetIds

fdConfig :: Config -> FocusDelegator.Config
fdConfig config = FocusDelegator.Config
  { FocusDelegator.startDelegatingKeys =
    Config.replaceInferredValueKeys config ++
    Config.delKeys config
  , FocusDelegator.startDelegatingDoc = E.Doc ["Edit", "Inferred value", "Replace"]
  , FocusDelegator.stopDelegatingKeys = Config.keepInferredValueKeys config
  , FocusDelegator.stopDelegatingDoc = E.Doc ["Edit", "Inferred value", "Back"]
  }

make ::
  MonadA m => ParentPrecedence ->
  Sugar.Payload Sugar.Name m a ->
  Sugar.Inferred Sugar.Name m (ExprGuiM.SugarExpr m) ->
  Guid -> Widget.Id ->
  ExprGuiM m (ExpressionGui m)
make parentPrecedence pl inferred guid myId = do
  config <- ExprGuiM.widgetEnv WE.readConfig
  let
    eventMap =
      maybe mempty
      (E.keyPresses
       (Config.acceptInferredValueKeys config)
       (E.Doc ["Edit", "Inferred value", "Accept"]) .
       fmap mkResult) $
      inferred ^. Sugar.iMAccept
  ExprGuiM.wrapDelegated (fdConfig config)
    FocusDelegator.NotDelegating (ExpressionGui.egWidget %~)
    (makeUnwrapped parentPrecedence pl inferred guid) myId
    <&> ExpressionGui.egWidget %~ Widget.weakerEvents eventMap
  where
    mkResult pr =
      Widget.EventResult
      { Widget._eCursor = WidgetIds.fromGuid <$> pr ^. Sugar.prMJumpTo
      , Widget._eAnimIdMapping =
          HoleEdit.pickedResultAnimIdTranslation (pr ^. Sugar.prIdTranslation)
      }

makeUnwrapped ::
  MonadA m => ParentPrecedence ->
  Sugar.Payload Sugar.Name m a ->
  Sugar.Inferred Sugar.Name m (ExprGuiM.SugarExpr m) ->
  Guid -> Widget.Id ->
  ExprGuiM m (ExpressionGui m)
makeUnwrapped (ParentPrecedence parentPrecedence) pl inferred guid myId = do
  config <- ExprGuiM.widgetEnv WE.readConfig
  mInnerCursor <- ExprGuiM.widgetEnv $ WE.subCursor myId
  inactive <-
    ExpressionGui.addInferredTypes pl =<<
    ExpressionGui.egWidget
    ( ExprGuiM.widgetEnv
    . BWidgets.makeFocusableView myId
    . Widget.tint (Config.inferredValueTint config)
    . Widget.scale (realToFrac <$> Config.inferredValueScaleFactor config)
    ) =<< ExprGuiM.makeSubexpression parentPrecedence (inferred ^. Sugar.iValue)
  case (mInnerCursor, inferred ^. Sugar.iHole . Sugar.holeMActions) of
    (Just _, Just actions) ->
      HoleEdit.makeUnwrappedActive pl actions
      (inactive ^. ExpressionGui.egWidget . Widget.wSize)
      Nothing -- TODO: next hole
      guid myId
    _ -> return inactive