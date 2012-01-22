{-# LANGUAGE DeriveDataTypeable, RecordWildCards #-}
module Network.IRC.Bot.Core
    ( simpleBot
    , simpleBot'
    , BotConf(..)
    , nullBotConf
    , User(..)
    , nullUser
    ) where

import Control.Concurrent       (ThreadId, forkIO, threadDelay)
import Control.Concurrent.Chan  (Chan, dupChan, newChan, readChan, writeChan)
import Control.Concurrent.MVar  (MVar, modifyMVar_, newMVar, readMVar)
import Control.Concurrent.QSem  (QSem, newQSem, waitQSem, signalQSem)
import Control.Exception        (IOException, catch)
import Control.Monad            (mplus, forever, when)
import Control.Monad.Trans      (liftIO)
import Data.Data                (Data, Typeable)
import Data.Set                 (Set, empty)
import Data.Time                (UTCTime, addUTCTime, getCurrentTime)
import Network                  (HostName, PortID(PortNumber), connectTo)
import Network.IRC              (Message, decode, encode, joinChan, nick, user)
import Network.IRC              as I
import Network.IRC.Bot.Types    (User(..), nullUser)
import Network.IRC.Bot.Log      (Logger, LogLevel(Normal, Debug), stdoutLogger)
import Network.IRC.Bot.BotMonad (BotMonad(logM, sendMessage), BotPartT, BotEnv(..), runBotPartT)
import Network.IRC.Bot.Part.NickUser (changeNickUser)
import Prelude                  hiding (catch)
import System.IO                (BufferMode(LineBuffering), Handle, hClose, hGetLine, hPutStrLn, hSetBuffering)

-- |Bot configuration
data BotConf = 
    BotConf
    { channelLogger :: (Maybe (Chan Message -> IO ()))  -- ^ optional channel logging function
    , logger        :: Logger           -- ^ app logging
    , host          :: HostName         -- ^ irc server to connect 
    , port          :: PortID           -- ^ irc port to connect to (usually, 'PortNumber 6667')
    , nick          :: String           -- ^ irc nick
    , commandPrefix :: String           -- ^ command prefix
    , user          :: User             -- ^ irc user info
    , channels      :: Set String       -- ^ channel to join
    }

nullBotConf :: BotConf
nullBotConf =
    BotConf { channelLogger  = Nothing
            , logger         = stdoutLogger Normal
            , host           = ""
            , port           = PortNumber 6667
            , nick           = ""
            , commandPrefix  = "#"
            , user           = nullUser
            , channels       = empty
            }

-- | connect to irc server and send NICK and USER commands
ircConnect :: HostName -> PortID -> String -> User -> IO Handle
ircConnect host port n u =
    do h <- connectTo host port
       hSetBuffering h LineBuffering
       return h

partLoop :: Logger -> String -> String -> Chan Message -> Chan Message -> (BotPartT IO ()) -> IO ()
partLoop logger botName prefix incomingChan outgoingChan botPart =
  forever $ do msg <- readChan incomingChan
               runBotPartT botPart (BotEnv msg outgoingChan logger botName prefix)

ircLoop :: Logger -> String -> String -> Chan Message -> Chan Message -> [BotPartT IO ()] -> IO [ThreadId]
ircLoop logger botName prefix incomingChan outgoingChan parts = 
    mapM forkPart parts
  where
    forkPart botPart =
      do inChan <- dupChan incomingChan
         forkIO $ partLoop logger botName prefix inChan outgoingChan (botPart `mplus` return ())

-- reconnect loop is still a bit buggy     
-- if you try to write multiple lines, and the all fail, reconnect will be called multiple times..
-- something should be done so that this does not happen
connectionLoop :: Logger -> MVar UTCTime -> HostName -> PortID -> String -> User -> Chan Message -> Chan Message -> Maybe (Chan Message) -> QSem -> IO (ThreadId, ThreadId, IO ())
connectionLoop logger mv host port nick user outgoingChan incomingChan logChan connQSem =
  do hMVar <- newMVar (undefined :: Handle)
     doConnect logger host port nick user hMVar connQSem
     outgoingTid  <- forkIO $ forever $
                      do msg <- readChan outgoingChan
                         writeMaybeChan logChan msg
                         h <- readMVar hMVar
                         hPutStrLn h (encode msg) `catch` (reconnect logger host port nick user hMVar connQSem)
                         modifyMVar_ mv (const getCurrentTime) 
     incomingTid  <- forkIO $ forever $
                       do h <- readMVar hMVar
                          msgStr <- (hGetLine h) `catch` (\e -> reconnect logger host port nick user hMVar connQSem e >> return "")
                          modifyMVar_ mv (const getCurrentTime)
                          case decode (msgStr ++ "\n") of
                            Nothing -> logger Normal ("decode failed: " ++ msgStr)
                            (Just msg) -> 
                              do logger Debug (show msg)
                                 writeMaybeChan logChan msg
                                 writeChan incomingChan msg
     let forceReconnect = 
             do h <- readMVar hMVar
                hClose h
     return (outgoingTid, incomingTid, forceReconnect)

ircConnectLoop logger host port nick user =
        (ircConnect host port nick user) `catch` 
        (\e ->
          do logger Normal $ "irc connect failed ... retry in 60 seconds: " ++ show (e :: IOException)
             threadDelay (60 * 10^6)
             ircConnectLoop logger host port nick user)

doConnect :: (LogLevel -> String -> IO a) -> String -> PortID -> String -> User -> MVar Handle -> QSem -> IO ()
doConnect logger host port nick user hMVar connQSem =
    do logger Normal $ showString "Connecting to " . showString host . showString " as " $ nick
       h <- ircConnectLoop logger host port nick user
       modifyMVar_ hMVar (const $ return h)
       logger Normal $ "Connected."
       signalQSem connQSem
       return ()

reconnect :: Logger -> String -> PortID -> String -> User -> MVar Handle -> QSem -> IOException -> IO ()
reconnect logger host port nick user hMVar connQSem e = 
    do logger Normal $ "IRC Connection died: " ++ show e
       doConnect logger host port nick user hMVar connQSem

onConnectLoop :: Logger -> String -> String -> Chan Message -> QSem -> BotPartT IO () -> IO ThreadId
onConnectLoop logger botName prefix outgoingChan connQSem action =
    forkIO $ forever $ 
      do waitQSem connQSem
         runBotPartT action (BotEnv undefined outgoingChan logger botName prefix)

-- |simpleBot connects to the server and handles messages using the supplied BotPartTs
-- 
-- the 'Chan Message' for the optional logging function will include
-- all received and sent messages. This means that the bots output
-- will be included in the logs.
simpleBot :: BotConf          -- ^ Bot configuration
          -> [BotPartT IO ()] -- ^ bot parts (must include 'pingPart', or equivalent)
          -> IO [ThreadId]    -- ^ 'ThreadId' for all forked handler threads
simpleBot BotConf{..} parts =
    simpleBot' channelLogger logger host port nick commandPrefix user parts

-- |simpleBot' connects to the server and handles messages using the supplied BotPartTs
--
-- the 'Chan Message' for the optional logging function will include
-- all received and sent messages. This means that the bots output
-- will be included in the logs.
simpleBot' :: (Maybe (Chan Message -> IO ())) -- ^ optional logging function
          -> Logger           -- ^ application logging
          -> HostName         -- ^ irc server to connect 
          -> PortID           -- ^ irc port to connect to (usually, 'PortNumber 6667')
          -> String           -- ^ irc nick
          -> String           -- ^ command prefix 
          -> User             -- ^ irc user info
          -> [BotPartT IO ()] -- ^ bot parts (must include 'pingPart', 'channelsPart', and 'nickUserPart')
          -> IO [ThreadId]    -- ^ 'ThreadId' for all forked handler threads
simpleBot' mChanLogger logger host port nick prefix user parts =  
  do (mLogTid, mLogChan) <- 
         case mChanLogger of
           Nothing  -> return (Nothing, Nothing)
           (Just chanLogger) ->
               do logChan <- newChan :: IO (Chan Message)
                  logTid  <- forkIO $ chanLogger logChan
                  return (Just logTid, Just logChan)
     -- message channels
     outgoingChan <- newChan :: IO (Chan Message)
     incomingChan <- newChan :: IO (Chan Message)
     mv <- newMVar =<< getCurrentTime
     connQSem <- newQSem 0
     (outgoingTid, incomingTid, forceReconnect) <- connectionLoop logger mv host port nick user outgoingChan incomingChan mLogChan connQSem
     watchDogTid <- forkIO $ forever $ 
                    do let timeout = 5*60
                       now          <- getCurrentTime
                       lastActivity <- readMVar mv
                       when (now > addUTCTime (fromIntegral timeout) lastActivity) forceReconnect
                       threadDelay (30*10^6) -- check every 30 seconds
     ircTids     <- ircLoop logger nick prefix incomingChan outgoingChan parts
     onConnectId <- onConnectLoop logger nick prefix outgoingChan connQSem onConnect
     return $ maybe id (:) mLogTid $ (incomingTid : outgoingTid : watchDogTid : ircTids)
    where
      onConnect :: BotPartT IO ()
      onConnect = 
          changeNickUser nick (Just user)

-- | call 'writeChan' if 'Just'. Do nothing for Nothing.
writeMaybeChan :: Maybe (Chan a) -> a -> IO ()
writeMaybeChan Nothing     _ = return () 
writeMaybeChan (Just chan) a = writeChan chan a
