{-# LANGUAGE RecordWildCards #-}

-- | Functions operation on 'SlogContext' and its subtypes.

module Pos.DB.Block.Slog.Context
       ( mkSlogGState
       , mkSlogContext
       , cloneSlogGState
       , slogGetLastBlkSlots
       , slogPutLastSlots
       , slogRollbackLastSlots
       ) where

import           Universum

import           Formatting (int, sformat, (%))
import qualified System.Metrics as Ekg

import           Pos.Chain.Block (HasBlockConfiguration, HasSlogGState (..),
                     LastBlkSlots, SlogContext (..), SlogGState (..),
                     fixedTimeCQSec, sgsLastBlkSlots)
import           Pos.Chain.Genesis as Genesis (Config (..), configBlkSecurityParam)
import           Pos.Core (BlockCount (..))
import           Pos.Core.Metrics.Constants (withCardanoNamespace)
import           Pos.Core.Reporting (MetricMonitorState, mkMetricMonitorState)
import           Pos.DB.Block.GState.BlockExtra (getLastSlots, putLastSlots,
                     rollbackLastSlots)
import           Pos.DB.Class (MonadDB, MonadDBRead)

import           Pos.Util.Wlog (CanLog)


-- | Make new 'SlogGState' using data from DB.
mkSlogGState :: (MonadIO m, MonadDBRead m) => BlockCount -> m SlogGState
mkSlogGState (BlockCount k) = do
    lbs <- getLastSlots $ fromIntegral k
    SlogGState <$> newIORef lbs

-- | Make new 'SlogContext' using data from DB.
mkSlogContext
    :: forall m
     . (MonadIO m, MonadDBRead m, HasBlockConfiguration)
    => BlockCount
    -> Ekg.Store
    -> m SlogContext
mkSlogContext k store = do
    _scGState <- mkSlogGState k

    let mkMMonitorState :: Text -> m (MetricMonitorState a)
        mkMMonitorState = flip mkMetricMonitorState store
    -- Chain quality metrics stuff.
    let metricNameK = sformat ("chain_quality_last_k_("%int%")_blocks_%") k
    let metricNameOverall = "chain_quality_overall_%"
    let metricNameFixed =
            sformat ("chain_quality_last_"%int%"_sec_%")
                fixedTimeCQSec
    _scCQkMonitorState <- mkMMonitorState metricNameK
    _scCQOverallMonitorState <- mkMMonitorState metricNameOverall
    _scCQFixedMonitorState <- mkMMonitorState metricNameFixed

    -- Other metrics stuff.
    _scDifficultyMonitorState <- mkMMonitorState "total_main_blocks"
    _scEpochMonitorState <- mkMMonitorState "current_epoch"
    _scLocalSlotMonitorState <- mkMMonitorState "current_local_slot"
    _scGlobalSlotMonitorState <- mkMMonitorState "current_global_slot"
    let crucialValuesName = withCardanoNamespace "crucial_values"
    _scCrucialValuesLabel <-
        liftIO $ Ekg.createLabel crucialValuesName store
    return SlogContext {..}

-- | Make a copy of existing 'SlogGState'.
cloneSlogGState :: (MonadIO m) => SlogGState -> m SlogGState
cloneSlogGState SlogGState {..} =
    SlogGState <$> (readIORef _sgsLastBlkSlots >>= newIORef)

-- | Read 'LastBlkSlots' from in-memory state.
slogGetLastBlkSlots ::
       (MonadReader ctx m, HasSlogGState ctx, MonadIO m) => m LastBlkSlots
slogGetLastBlkSlots =
    -- 'LastBlkSlots' is stored in two places, the DB and an 'IORef' so just
    -- grab the copy in the 'IORef'.
    readIORef =<< view (slogGState . sgsLastBlkSlots)

-- | Update 'LastBlkSlots' in 'SlogContext'.
slogPutLastSlots ::
       (MonadReader ctx m, MonadDB m, HasSlogGState ctx, MonadIO m)
    => LastBlkSlots
    -> m ()
slogPutLastSlots slots = do
    -- When we set 'LastBlkSlots' we set it in both the DB and the 'IORef'.
    view (slogGState . sgsLastBlkSlots) >>= flip writeIORef slots
    putLastSlots slots

-- | Roll back the specified count of 'LastBlkSlots'.
slogRollbackLastSlots
    :: (CanLog m, MonadReader ctx m, MonadDB m, HasSlogGState ctx, MonadIO m)
    => Genesis.Config -> m ()
slogRollbackLastSlots genesisConfig = do
    -- Roll back in the DB, then read the DB and set the 'IORef'.
    rollbackLastSlots genesisConfig
    slots <- getLastSlots (configBlkSecurityParam genesisConfig)
    view (slogGState . sgsLastBlkSlots) >>= flip writeIORef slots
