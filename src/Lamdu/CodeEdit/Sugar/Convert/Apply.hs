module Lamdu.CodeEdit.Sugar.Convert.Apply
  ( convert
  ) where

import Control.Applicative (Applicative(..), (<$>))
import Control.Lens.Operators
import Control.Monad (MonadPlus(..), guard, (<=<))
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Either (EitherT(..))
import Control.Monad.Trans.Maybe (MaybeT(..))
import Control.MonadA (MonadA)
import Data.Store.Guid (Guid)
import Data.Store.IRef (Tag)
import Data.Traversable (traverse)
import Data.Typeable (Typeable1)
import Lamdu.CodeEdit.Sugar.Infer (ExprMM)
import Lamdu.CodeEdit.Sugar.Monad (SugarM)
import Lamdu.CodeEdit.Sugar.Types
import Lamdu.Data.Anchors (PresentationMode(..))
import qualified Control.Lens as Lens
import qualified Control.Monad.Trans.Either as Either
import qualified Data.Set as Set
import qualified Data.Store.Guid as Guid
import qualified Lamdu.CodeEdit.Sugar.Expression as SugarExpr
import qualified Lamdu.CodeEdit.Sugar.Infer as SugarInfer
import qualified Lamdu.CodeEdit.Sugar.Monad as SugarM
import qualified Lamdu.Data.Anchors as Anchors
import qualified Lamdu.Data.Expression as Expr
import qualified Lamdu.Data.Expression.IRef as ExprIRef
import qualified Lamdu.Data.Expression.Lens as ExprLens
import qualified Lamdu.Data.Expression.Utils as ExprUtil
import qualified Lamdu.Data.Ops as DataOps

uneither :: Either a a -> a
uneither = either id id

justToLeft :: Monad m => MaybeT m a -> EitherT a m ()
justToLeft = maybe (pure ()) Either.left <=< lift . runMaybeT

convert ::
  (Typeable1 m, MonadA m) =>
  Expr.Apply (ExprMM m) ->
  ExprMM m -> SugarM m (ExpressionU m)
convert app@(Expr.Apply funcI argI) exprI =
  fmap uneither . runEitherT $ do
    justToLeft $ convertEmptyList app exprI
    argS <- lift $ SugarM.convertSubexpression argI
    justToLeft $ convertList app argS exprI
    funcS <- lift $ SugarM.convertSubexpression funcI
    justToLeft $ convertLabeled funcS argS exprI
    lift $ convertPrefix funcS funcI argS exprI

maybeToMPlus :: MonadPlus m => Maybe a -> m a
maybeToMPlus Nothing = mzero
maybeToMPlus (Just x) = return x

indirectDefinitionGuid :: ExpressionP name m pl -> Maybe Guid
indirectDefinitionGuid funcS =
  case funcS ^. rBody of
  BodyGetVar gv -> Just $ gv ^. gvIdentifier
  BodyCollapsed c -> Just $ c ^. pCompact . gvIdentifier
  BodyInferred i -> indirectDefinitionGuid $ i ^. iValue
  BodyGetField _ -> Nothing -- TODO: <-- do we want to make something up here?
  _ -> Nothing

indirectDefinitionPresentationMode :: MonadA m => ExpressionP name m pl -> SugarM m (Maybe PresentationMode)
indirectDefinitionPresentationMode =
  traverse (SugarM.getP . Anchors.assocPresentationMode) .
  indirectDefinitionGuid

noRepetitions :: Ord a => [a] -> Bool
noRepetitions x = length x == Set.size (Set.fromList x)

convertLabeled ::
  (MonadA m, Typeable1 m) =>
  ExpressionU m -> ExpressionU m -> ExprMM m ->
  MaybeT (SugarM m) (ExpressionU m)
convertLabeled funcS argS exprI = do
  Record Val fields <- maybeToMPlus $ argS ^? rBody . _BodyRecord
  let
    getArg field = do
      tagG <- maybeToMPlus $ field ^? rfTag . rBody . _BodyTag
      pure (tagG, field ^. rfExpr)
  args@((_, arg0) : args1toN@((_, arg1) : args2toN)) <-
    traverse getArg $ fields ^. flItems
  let tagGuids = args ^.. Lens.traversed . Lens._1 . tagGuid
  guard $ noRepetitions tagGuids
  presentationMode <- MaybeT $ indirectDefinitionPresentationMode funcS
  let
    (specialArgs, annotatedArgs) =
      case presentationMode of
      Verbose -> (NoSpecialArgs, args)
      OO -> (ObjectArg arg0, args1toN)
      Infix -> (InfixArgs arg0 arg1, args2toN)
  lift . SugarExpr.make exprI $ BodyApply Apply
    { _aFunc = SugarExpr.removeSuccessfulType funcS
    , _aSpecialArgs = specialArgs
    , _aAnnotatedArgs = annotatedArgs
    }

makeCollapsed ::
  (MonadA m, Typeable1 m) =>
  ExprMM m ->
  Guid -> GetVar MStoredName m -> ExpressionU m -> SugarM m (ExpressionU m)
makeCollapsed exprI g compact fullExpression =
  SugarExpr.make exprI $ BodyCollapsed Collapsed
    { _pFuncGuid = g
    , _pCompact = compact
    , _pFullExpression =
      Lens.set rGuid expandedGuid $ SugarExpr.removeInferredTypes fullExpression
    }
  where
    expandedGuid = Guid.combine (SugarInfer.resultGuid exprI) $ Guid.fromString "polyExpanded"

convertPrefix ::
  (MonadA m, Typeable1 m) =>
  ExpressionU m -> ExprMM m -> ExpressionU m ->
  ExprMM m -> SugarM m (ExpressionU m)
convertPrefix funcRef funcI argRef applyI = do
  sugarContext <- SugarM.readContext
  let
    newArgRef = addCallWithNextArg argRef
    fromMaybeStored = traverse (SugarInfer.ntraversePayload pure id)
    onStored expr f = maybe id f $ fromMaybeStored expr
    addCallWithNextArg =
      onStored applyI $ \applyS ->
        rPayload . plActions . Lens.mapped . callWithNextArg .~
        SugarExpr.mkCallWithArg sugarContext applyS
    newFuncRef =
      SugarExpr.setNextHole newArgRef .
      SugarExpr.removeSuccessfulType $
      funcRef
    makeFullApply = makeApply newFuncRef
    makeApply f =
      SugarExpr.make applyI $ BodyApply Apply
      { _aFunc = f
      , _aSpecialArgs = ObjectArg newArgRef
      , _aAnnotatedArgs = []
      }
  if SugarInfer.isPolymorphicFunc funcI
    then
      case funcRef ^. rBody of
      BodyCollapsed (Collapsed g compact full) ->
        makeCollapsed applyI g compact =<< makeApply full
      BodyGetVar var ->
        makeCollapsed applyI (SugarInfer.resultGuid funcI) var =<< makeFullApply
      _ -> makeFullApply
    else
      makeFullApply

setListGuid :: Guid -> ExpressionU m -> ExpressionU m
setListGuid consistentGuid e = e
  & rGuid .~ consistentGuid
  & rHiddenGuids %~ (e ^. rGuid :)

subExpressionGuids ::
  Lens.Fold
  (Expr.Expression def (SugarInfer.Payload t i (Maybe (SugarInfer.Stored m)))) Guid
subExpressionGuids = Lens.folding ExprUtil.subExpressions . SugarInfer.exprStoredGuid

mkListAddFirstItem ::
  MonadA m => Anchors.SpecialFunctions (Tag m) -> SugarInfer.Stored m -> T m Guid
mkListAddFirstItem specialFunctions =
  fmap (ExprIRef.exprGuid . snd) . DataOps.addListItem specialFunctions

convertEmptyList ::
  (Typeable1 m, MonadA m) =>
  Expr.Apply (ExprMM m) ->
  ExprMM m ->
  MaybeT (SugarM m) (ExpressionU m)
convertEmptyList app@(Expr.Apply funcI _) exprI = do
  specialFunctions <-
    lift $ (^. SugarM.scSpecialFunctions) <$> SugarM.readContext
  let
    mkListActions exprS =
      ListActions
      { addFirstItem = mkListAddFirstItem specialFunctions exprS
      , replaceNil = ExprIRef.exprGuid <$> DataOps.setToHole exprS
      }
  guard $
    Lens.anyOf ExprLens.exprDefinitionRef
    (== Anchors.sfNil specialFunctions) funcI
  let guids = app ^.. Lens.traversed . subExpressionGuids
  (rHiddenGuids <>~ guids) .
    setListGuid consistentGuid <$>
    (lift . SugarExpr.make exprI . BodyList)
    (List [] (mkListActions <$> SugarInfer.resultStored exprI))
  where
    consistentGuid = Guid.augment "list" (SugarInfer.resultGuid exprI)

isCons ::
  Anchors.SpecialFunctions t ->
  ExprIRef.Expression t a -> Bool
isCons specialFunctions =
  Lens.anyOf
  (ExprLens.exprApply . Expr.applyFunc . ExprLens.exprDefinitionRef)
  (== Anchors.sfCons specialFunctions)

convertList ::
  (Typeable1 m, MonadA m) =>
  Expr.Apply (ExprMM m) ->
  ExpressionU m ->
  ExprMM m ->
  MaybeT (SugarM m) (ExpressionU m)
convertList (Expr.Apply funcI argI) argS exprI = do
  specialFunctions <- lift $ (^. SugarM.scSpecialFunctions) <$> SugarM.readContext
  Expr.Apply funcFuncI funcArgI <-
    maybeToMPlus $ funcI ^? ExprLens.exprApply
  List innerValues innerListMActions <-
    maybeToMPlus $ argS ^? rBody . _BodyList
  guard $ isCons specialFunctions funcFuncI
  listItemExpr <- lift $ SugarM.convertSubexpression funcArgI
  let
    hiddenGuids = (funcFuncI ^.. subExpressionGuids) ++ (funcI ^.. SugarInfer.exprStoredGuid)
    listItem =
      mkListItem listItemExpr argS hiddenGuids exprI argI $
      addFirstItem <$> innerListMActions
    mListActions = do
      exprS <- SugarInfer.resultStored exprI
      innerListActions <- innerListMActions
      pure ListActions
        { addFirstItem = mkListAddFirstItem specialFunctions exprS
        , replaceNil = replaceNil innerListActions
        }
  setListGuid (argS ^. rGuid) <$>
    (lift . SugarExpr.make exprI . BodyList)
    (List (listItem : innerValues) mListActions)

mkListItem ::
  MonadA m =>
  ExpressionU m -> ExpressionU m -> [Guid] ->
  ExprMM m -> ExprMM m -> Maybe (T m Guid) ->
  ListItem m (ExpressionU m)
mkListItem listItemExpr argS hiddenGuids exprI argI mAddNextItem =
  ListItem
  { liExpr =
    listItemExpr
    & SugarExpr.setNextHole argS
    & rHiddenGuids <>~ hiddenGuids ++ (argS ^. rHiddenGuids)
  , liMActions = do
      addNext <- mAddNextItem
      exprProp <- SugarInfer.resultStored exprI
      argProp <- SugarInfer.resultStored argI
      return ListItemActions
        { _itemAddNext = addNext
        , _itemDelete = SugarInfer.replaceWith exprProp argProp
        }
  }