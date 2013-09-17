{-# LANGUAGE RecordWildCards #-}
module Main where

import System.IO
import Network
import Text.Printf
import Data.Map (Map)
import qualified Data.Map as Map
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Exception.Base
import Control.Monad

-- <<main
main :: IO ()
main = withSocketsDo $ do
  server <- newServer
  sock   <- listenOn (PortNumber (fromIntegral port))
  printf "Listening on port %d\n" port
  forever $ do
    (handle, host, port) <- accept sock
    printf "Accepted connection from %s:%s\n" host (show port)
    forkFinally (talk handle server) (\_ -> hClose handle)


port :: Integer
port = 44444
-- >>


-- <<Client
type ClientName = String

data Client = Client
  { clientName          :: ClientName
  , clientHandle        :: Handle
  , clientKicked        :: TVar (Maybe String)
  , clientSendChan      :: TChan Message
  , clientBroadcastChan :: TChan Message
  }

newClient :: Server -> ClientName -> Handle -> STM Client
newClient Server{..} name handle = do
  c <- newTChan
  b <- dupTChan serverBroadcastChan
  k <- newTVar Nothing
  return Client { clientName          = name
                , clientHandle        = handle
                , clientKicked        = k
                , clientSendChan      = c
                , clientBroadcastChan = b
                }
-- >>

-- <<Server
data Server = Server
  { clients             :: TVar (Map ClientName Client)
  , serverBroadcastChan :: TChan Message
  }

newServer :: IO Server
newServer = do
  c <- newTVarIO Map.empty
  b <- newTChanIO
  return Server { clients             = c
                , serverBroadcastChan = b
                }
-- >>

-- <<Message
data Message = Notice String
             | Tell ClientName String
             | Broadcast ClientName String
             | Command String
-- >>

-------------------------------------------------------------------------------
-- Basic ops

tell :: Server -> Client -> ClientName -> String -> IO ()
tell server@Server{..} Client{..} who msg = do
  ok <- atomically $ sendToName server who (Tell clientName msg)
  if ok
     then return ()
     else hPutStrLn clientHandle (who ++ " is not connected.")

kick :: Server -> ClientName -> ClientName -> STM ()
kick server@Server{..} who by = do
  clientmap <- readTVar clients
  case Map.lookup who clientmap of
       Nothing ->
         void $ sendToName server by (Notice $ who ++ " is not connected")
       Just victim -> do
         writeTVar (clientKicked victim) $ Just ("by " ++ by)
         void $ sendToName server by (Notice $ "you kicked " ++ who)

broadcast :: Server -> Message -> STM ()
broadcast Server{..} msg =
  writeTChan serverBroadcastChan msg

sendMessage :: Client -> Message -> STM ()
sendMessage Client{..} msg =
  writeTChan clientSendChan msg

sendToName :: Server -> ClientName -> Message -> STM Bool
sendToName server@Server{..} name msg = do
  clientmap <- readTVar clients
  case Map.lookup name clientmap of
       Nothing -> return False
       Just client -> sendMessage client msg >> return True


--------------------------------------------------------------------------------
-- Main server ops

checkAddClient :: Server -> ClientName -> Handle -> IO (Maybe Client)
checkAddClient server@Server{..} name handle = atomically $ do
  clientmap <- readTVar clients
  if Map.member name clientmap
     then return Nothing
     else do
       client <- newClient server name handle
       writeTVar clients $ Map.insert name client clientmap
       broadcast server $ Notice (name ++ " has connected")
       return (Just client)

removeClient :: Server -> ClientName -> IO ()
removeClient server@Server{..} name = atomically $ do
  modifyTVar' clients $ Map.delete name
  broadcast server $ Notice (name ++ " has disconnected")

runClient :: Server -> Client -> IO ()
runClient serv@Server{..} client@Client{..} = do
  race server receive
  return ()
  where
    receive = forever $ do
      msg <- hGetLine clientHandle
      atomically $ sendMessage client (Command msg)

    server = join $ atomically $ do
      k <- readTVar clientKicked
      case k of
           Just reason -> return $
             hPutStrLn clientHandle $ "You have been kicked: " ++ reason
           Nothing -> do
             msg <- readTChan clientSendChan `orElse` readTChan clientBroadcastChan
             return $ do
               continue <- handleMessage serv client msg
               when continue $ server

handleMessage :: Server -> Client -> Message -> IO Bool
handleMessage server client@Client{..} message =
  case message of
       Notice msg         -> output $ "*** " ++ msg
       Tell name msg      -> output $ "*" ++ name ++ "*: " ++ msg
       Broadcast name msg -> output $ "<" ++ name ++ ">: " ++ msg
       Command msg ->
         case words msg of
              ["/kick", who] -> do
                atomically $ kick server who clientName
                return True
              "/tell" : who : what -> do
                tell server client who (unwords what)
                return True
              ["/quit"] ->
                return False
              ('/':_):_ -> do
                hPutStrLn clientHandle $ "Unrecognized command: " ++ msg
                return True
              _ -> do
                atomically $ broadcast server $ Broadcast clientName msg
                return True
  where
    output s = do hPutStrLn clientHandle s; return True


talk :: Handle -> Server -> IO ()
talk handle server@Server{..} = do
  hSetNewlineMode handle universalNewlineMode
  hSetBuffering handle LineBuffering
  readName
  where
    readName = do
      hPutStrLn handle "What is your name?"
      name <- hGetLine handle
      if null name
         then readName
         else mask $ \restore -> do
               ok <- checkAddClient server name handle
               case ok of
                    Nothing -> restore $ do
                      hPrintf handle "The name %s is in use. Please choose another\n" name
                      readName
                    Just client -> restore (runClient server client)
                                     `finally` removeClient server name
