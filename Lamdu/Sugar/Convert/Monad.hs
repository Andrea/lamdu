{-# LANGUAGE GeneralizedNewtypeDeriving, TemplateHaskell, PolymorphicComponents, ConstraintKinds #-}
module Lamdu.Sugar.Convert.Monad
  ( Context(..), TagParamInfo(..), RecordParamsInfo(..)
  , scHoleInferStateKey, scHoleInferState, scStructureInferState
  , scCodeAnchors, scSpecialFunctions, scTagParamInfos, scRecordParamsInfos
  , SugarM(..), run
  , readContext, liftCTransaction, liftTransaction, local
  , codeAnchor
  , getP
  , convertSubexpression
  , memoLoadInferInHoleContext
  ) where

import Control.Applicative (Applicative, (<$>))
import Control.Lens ((^.))
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Trans.Reader (ReaderT, runReaderT)
import Control.MonadA (MonadA)
import Data.Binary (Binary)
import Data.Map (Map)
import Data.Monoid (Monoid)
import Data.Store.Guid (Guid)
import Data.Store.IRef (Tag)
import Data.Typeable (Typeable1)
import Lamdu.Data.Expression.IRef (DefM)
import Lamdu.Sugar.Convert.Infer (ExprMM)
import Lamdu.Sugar.Internal
import Lamdu.Sugar.Types.Internal
import qualified Control.Lens as Lens
import qualified Control.Monad.Trans.Reader as Reader
import qualified Data.Cache as Cache
import qualified Data.Store.Transaction as Transaction
import qualified Lamdu.Data.Anchors as Anchors
import qualified Lamdu.Data.Expression.IRef as ExprIRef
import qualified Lamdu.Data.Expression.Infer as Infer
import qualified Lamdu.Sugar.Convert.Infer as SugarInfer

data TagParamInfo = TagParamInfo
  { tpiFromParameters :: Guid
  , tpiJumpTo :: Guid
  }

data RecordParamsInfo m = RecordParamsInfo
  { rpiFromDefinition :: Guid
  , rpiJumpTo :: T m Guid
  }

data Context m = Context
  { _scHoleInferStateKey :: Cache.KeyBS
  , _scHoleInferState :: Infer.Context (DefM m)
  , _scStructureInferState :: Infer.Context (DefM m)
  , _scCodeAnchors :: Anchors.CodeProps m
  , _scSpecialFunctions :: Anchors.SpecialFunctions (Tag m)
  , _scTagParamInfos :: Map Guid TagParamInfo -- tag guids
  , _scRecordParamsInfos :: Map Guid (RecordParamsInfo m) -- param guids
  , scConvertSubexpression :: forall a. Monoid a => ExprMM m a -> SugarM m (ExpressionU m a)
  }

newtype SugarM m a = SugarM (ReaderT (Context m) (CT m) a)
  deriving (Functor, Applicative, Monad)

Lens.makeLenses ''Context

run :: MonadA m => Context m -> SugarM m a -> CT m a
run ctx (SugarM action) = runReaderT action ctx

readContext :: MonadA m => SugarM m (Context m)
readContext = SugarM Reader.ask

local :: Monad m => (Context m -> Context m) -> SugarM m a -> SugarM m a
local f (SugarM act) = SugarM $ Reader.local f act

liftCTransaction :: MonadA m => CT m a -> SugarM m a
liftCTransaction = SugarM . lift

liftTransaction :: MonadA m => T m a -> SugarM m a
liftTransaction = liftCTransaction . lift

codeAnchor :: MonadA m => (Anchors.CodeProps m -> a) -> SugarM m a
codeAnchor f = f . (^. scCodeAnchors) <$> readContext

getP :: MonadA m => Transaction.MkProperty m a -> SugarM m a
getP = liftTransaction . Transaction.getP

convertSubexpression :: (MonadA m, Monoid a) => ExprMM m a -> SugarM m (ExpressionU m a)
convertSubexpression exprI = do
  convertSub <- scConvertSubexpression <$> readContext
  convertSub exprI

memoLoadInferInHoleContext ::
  (MonadA m, Typeable1 m, Cache.Key a, Binary a) =>
  Context m ->
  ExprIRef.ExpressionM m a ->
  Infer.InferNode (DefM m) ->
  CT m
  ( Maybe
    ( ExprIRef.ExpressionM m (Infer.Inferred (DefM m), a)
    , Infer.Context (DefM m)
    )
  )
memoLoadInferInHoleContext ctx expr point =
  SugarInfer.memoLoadInfer Nothing expr
    (ctx ^. scHoleInferStateKey)
    (ctx ^. scHoleInferState, point)
