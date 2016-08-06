{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE MultiWayIf         #-}
{-# LANGUAGE OverloadedStrings  #-}

{-|
Module      : Database.MySQL.BinLog
Description : Text and binary protocol
Copyright   : (c) Winterland, 2016
License     : BSD
Maintainer  : drkoster@qq.com
Stability   : experimental
Portability : PORTABLE

This module provide tools for binlog listening and row based binlog decoding.
-}

module Database.MySQL.BinLog where

import           Control.Exception                         (Exception, throwIO)
import           Control.Monad
import           Data.Binary.Put
import           Data.ByteString                           (ByteString)
import           Data.IORef                                (IORef, newIORef, readIORef, writeIORef)
import           Data.Typeable
import           Data.Word
import           Data.Text.Encoding                        (encodeUtf8)
import           Database.MySQL.Base
import           Database.MySQL.BinLogProtocol.BinLogEvent
import           Database.MySQL.Connection
import           Database.MySQL.Protocol
import           System.IO.Streams                         (InputStream, OutputStream)
import qualified System.IO.Streams                         as Stream


type SlaveID = Word32

-- | Register a pesudo slave to master, although MySQL document suggests you should call this
-- before calling 'dumpBinLog', but it seems it's not really necessary.
--
registerPesudoSlave :: MySQLConn -> SlaveID -> IO OK
registerPesudoSlave conn sid = command conn (COM_REGISTER_SLAVE sid "" "" "" 0 0 0)

-- | Setup binlog listening on given connection, during listening
-- the connection *can not* be used to do query, or an 'UnconsumedResultSet' will be thrown.
--
dumpBinLog :: MySQLConn               -- ^ connection to be listened
           -> SlaveID                 -- ^ a number for our pesudo slave.
           -> (ByteString, Word32)    -- ^ binlog position
           -> Bool                    -- ^ if master support semi-ack, do we want to enable it?
                                      -- if master doesn't support, this parameter will be ignored.
           -> IO (FormatDescription, IORef ByteString, InputStream BinLogPacket)
dumpBinLog conn@(MySQLConn is os _ consumed) sid (initfn, initpos) wantAck = do
    guardUnconsumed conn
    checksum <- isCheckSumEnabled conn
    when checksum $ void $ executeRaw conn "SET @master_binlog_checksum = @@global.binlog_checksum"
    semiAck  <- isSemiSyncEnabled conn
    let needAck = semiAck && wantAck
    when needAck . void $ executeRaw conn "SET @rpl_semi_sync_slave = 1"
    writeCommand (COM_BINLOG_DUMP initpos 0x00 sid initfn) os
    writeIORef consumed False

    rp <- skipToPacketT (readBinLogPacket checksum needAck is) BINLOG_ROTATE_EVENT
    re <- getFromBinLogPacket getRotateEvent rp
    fref <- newIORef (rFileName re)

    p <- skipToPacketT (readBinLogPacket checksum needAck is) BINLOG_FORMAT_DESCRIPTION_EVENT
    replyAck needAck p fref os
    fmt <- getFromBinLogPacket getFormatDescription p

    es <- Stream.makeInputStream $ do
        q <- readBinLogPacket checksum needAck is
        case q of
            Nothing   -> writeIORef consumed True >> return Nothing
            Just q' -> do when (blEventType q' == BINLOG_ROTATE_EVENT) $ do
                                e <- getFromBinLogPacket getRotateEvent q'
                                writeIORef' fref (rFileName e)
                          replyAck needAck q' fref os
                          return q
    return (fmt, fref, es)
  where
    skipToPacketT iop typ = do
        p <- iop
        case p of
            Just p' -> do
                if blEventType p' == typ then return p' else throwIO (UnexpectedBinLogEvent p')
            Nothing -> throwIO NetworkException

    replyAck needAck p fref os' = when (needAck && blSemiAck p) $ do
        fn <- readIORef fref
        Stream.write (Just (makeSemiAckPacket (blLogPos p) fn)) os'

    makeSemiAckPacket pos fn = putToPacket 0 $ do
        putWord8 0xEF      -- semi-ack
        putWord64le pos
        putByteString fn

    readBinLogPacket checksum needAck is' = do
        p <- readPacket is'
        if  | isOK p -> Just <$> getFromPacket (getBinLogPacket checksum needAck) p
            | isEOF p -> return Nothing
            | isERR p -> decodeFromPacket p >>= throwIO . ERRException

-- | Current binlog filename and next position if you resume listening.
--
data BinLogTracker = BinLogTracker
    { btFileName :: {-# UNPACK #-} !ByteString
    , btNextPos  :: {-# UNPACK #-} !Word64
    } deriving (Show, Eq)

-- | Row based biblog event type.
--
-- It's recommended to call 'enableRowQueryEvent' before 'dumpBinLog', so that you can get
-- query event in row based binlog(for exampleit's important for detect a table change).
--
-- a 'BinLogTracker' is included so that you can roll up your own HA solutions,
-- for example, writing 'BinLogPacket' to a zookeeper when you done with an event.
--
data RowBinLogEvent
    = RowQueryEvent   !BinLogTracker !QueryEvent
    | RowDeleteEvent  !BinLogTracker !TableMapEvent !DeleteRowsEvent
    | RowWriteEvent   !BinLogTracker !TableMapEvent !WriteRowsEvent
    | RowUpdateEvent  !BinLogTracker !TableMapEvent !UpdateRowsEvent
  deriving (Show, Eq)

-- | decode row based event from 'BinLogPacket' stream.
decodeRowBinLogEvent :: (FormatDescription, IORef ByteString, InputStream BinLogPacket)
                     -> IO (InputStream RowBinLogEvent)
decodeRowBinLogEvent (fd', fref', is') = Stream.makeInputStream (loop fd' fref' is')
  where
    loop fd fref is = do
        p <- Stream.read is
        case p of
            Nothing -> return Nothing
            Just p' -> do
                let t = blEventType p'
                if  | t == BINLOG_QUERY_EVENT -> do
                        tr <- track p' fref
                        e <- getFromBinLogPacket getQueryEvent p'
                        pure (Just (RowQueryEvent tr e))
                    | t == BINLOG_TABLE_MAP_EVENT -> do
                        tme <- getFromBinLogPacket (getTableMapEvent fd) p'
                        q <- Stream.read is
                        case q of
                            Nothing -> return Nothing
                            Just q' -> do
                                let u = blEventType q'
                                if  | u == BINLOG_WRITE_ROWS_EVENTv1 || u == BINLOG_WRITE_ROWS_EVENTv2 -> do
                                        tr <- track q' fref
                                        e <- getFromBinLogPacket' (getWriteRowEvent fd tme) q'
                                        pure (Just (RowWriteEvent tr tme e))
                                    | u == BINLOG_DELETE_ROWS_EVENTv1 || u == BINLOG_DELETE_ROWS_EVENTv2 -> do
                                        tr <- track q' fref
                                        e <- getFromBinLogPacket' (getDeleteRowEvent fd tme) q'
                                        pure (Just (RowDeleteEvent tr tme e))
                                    | u == BINLOG_UPDATE_ROWS_EVENTv1 || u == BINLOG_UPDATE_ROWS_EVENTv2 -> do
                                        tr <- track q' fref
                                        e <- getFromBinLogPacket' (getUpdateRowEvent fd tme) q'
                                        pure (Just (RowUpdateEvent tr tme e))
                                    | otherwise -> loop fd fref is
                    | otherwise -> loop fd fref is

    track p fref = BinLogTracker <$> readIORef fref <*> pure (blLogPos p)


-- | Get latest master's binlog filename and position.
--
getLastBinLogInfo :: MySQLConn -> IO (ByteString, Word64)
getLastBinLogInfo conn = do
    (_, is) <- queryRaw conn "SHOW MASTER STATUS;"
    row <- Stream.read is
    Stream.skipToEof is
    case row of
        Just (MySQLText fn : MySQLInt64U pos : _) -> return (encodeUtf8 fn, pos)
        row'                                       -> throwIO (GetLastBinLogInfoFail row')

data GetLastBinLogInfoFail = GetLastBinLogInfoFail (Maybe [MySQLValue]) deriving (Show, Typeable)
instance Exception GetLastBinLogInfoFail

-- | Return True if binlog_checksum = CRC32. Only for MySQL > 5.6
--
isCheckSumEnabled :: MySQLConn -> IO Bool
isCheckSumEnabled conn = do
    (_, is) <- queryRaw conn "SHOW GLOBAL VARIABLES LIKE 'binlog_checksum';"
    row <- Stream.read is
    Stream.skipToEof is
    case row of
        Just [_, MySQLText "CRC32"] -> return True
        _                           -> return False

-- | Return True if rpl_semi_sync_master_enabled = ON. Only for MySQL > 5.5
--
isSemiSyncEnabled :: MySQLConn -> IO Bool
isSemiSyncEnabled conn = do
    (_, is) <- queryRaw conn "SHOW VARIABLES LIKE 'rpl_semi_sync_master_enabled';"
    row <- Stream.read is
    Stream.skipToEof is
    case row of
        Just [_, MySQLText "ON"] -> return True
        _                        -> return False

-- | Set session varible @binlog_rows_query_log_events@ to @ON@, so that
-- we can get query event in row based binlog.
--
enableRowQueryEvent :: MySQLConn -> IO ()
enableRowQueryEvent conn = void $ executeRaw conn "SET @binlog_rows_query_log_events = ON;"

