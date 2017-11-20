{-# LANGUAGE KindSignatures, GADTs, DeriveFunctor, DeriveGeneric, ConstraintKinds, OverloadedStrings, RankNTypes, ScopedTypeVariables, TupleSections #-}

-- | Run arbitrary operations on a remote machine by starting a copy of the current executable.
--   The copy communicates with the original via a type-safe transport (using SSH pipes), a la Ansible.
--   Separate types can be provided for parameters, result and bidirectional streams.
-- Util.RemoteCommand
module Main where

import Prelude hiding (putStrLn)
import System.Process
import Control.Exception
import System.IO hiding (hGetLine, putStrLn, hPutStrLn)
import Control.Concurrent.Async
import Control.Applicative
import Data.Void
import System.Posix.Process (getProcessID)
import System.Exit
import Data.Aeson
import Control.Monad
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (hGetLine, putStrLn, hPutStrLn)
import qualified Data.ByteString.Lazy as LBS
import Control.Concurrent.STM
import Control.Concurrent.STM.TChan
import Control.Concurrent
import Data.HashMap.Lazy (fromList)
import GHC.Generics
import Data.Text (Text)
import qualified System.Directory as Directory
import Data.Traversable

getCurrentProcessPath :: IO FilePath
getCurrentProcessPath = do
  pid <- getProcessID
  -- TODO read /proc/$PID/exe
  pure "/Users/Hoglund/Code/hs/hsremote/.stack-work/dist/x86_64-osx/Cabal-1.18.1.5/build/hsremote-exe/hsremote-exe"

main :: IO ()
main = listenSelfTyped

contramap f g = g . f

data Cmd
  :: * -- Parameters
  -> * -- Input stream
  -> * -- Output stream
  -> * -- Result
  -> *
  where
    Id    :: Cmd Int () () Int
    Ls    :: Cmd FilePath () () [FilePath]
    Accum :: Cmd Int String String ()
    -- Id   :: {-JSON a =>-} Cmd a () () a
    -- Echo :: {-JSON a =>-} Cmd () a a ()

-- class IsCommand cmd where
--   impl_ :: cmd a i o b -> a -> IO i -> (o -> IO ()) -> IO b
--   unrefCmd_ :: cmd x y z o -> Text
--   refCmd_ :: Text -> (forall x y z o . (JSON x, JSON y, JSON z, JSON o) => cmd x y z o -> r) -> r
-- instance IsCommand Cmd where
--   impl_ = impl
--   unrefCmd_ = unrefCmd
--   refCmd_ = refCmd

impl :: Cmd a i o b -> a -> IO i -> (o -> IO ()) -> IO b
impl Id x _ _ = pure x
impl Ls path _ _ =
  Directory.getDirectoryContents path
impl Accum n re se = do
  replicateM n $ do
    m <- re
    se (m ++ "foo")
  pure ()

unrefCmd :: Cmd x y z o -> Text
unrefCmd Id   = "id"
unrefCmd Ls   = "ls"
unrefCmd Accum = "accum"
-- unrefCmd Echo = "echo"

refCmd :: Text -> (forall x y z o . (JSON x, JSON y, JSON z, JSON o) => Cmd x y z o -> r) -> r
refCmd "id" k = k Id
refCmd "ls" k = k Ls
refCmd "accum" k = k Accum
refCmd _ k = error "bad cmd"

refInit :: JSON a => cmd a i o b -> Value -> a
refInit _ = unsafeFromRes . fromJSON

unrefInit :: JSON a => cmd a i o b -> a -> Value
unrefInit _ = toJSON

refIn :: JSON i => cmd a i o b -> Value -> i
refIn _ = unsafeFromRes . fromJSON

unrefIn :: JSON i => cmd a i o b -> i -> Value
unrefIn _ = toJSON

refOut :: JSON o => cmd a i o b -> Value -> o
refOut _ = unsafeFromRes . fromJSON

unrefOut :: JSON o => cmd a i o b -> o -> Value
unrefOut _ = toJSON

refRes :: JSON b => cmd a i o b -> Value -> b
refRes _ = unsafeFromRes . fromJSON

unrefRes :: JSON b => cmd a i o b -> b -> Value
unrefRes _ = toJSON

-- instance ToJSON (Cmd a i o b) where
--   toJSON x = go x
--     where
--       go Id = String "Id"
--       go Echo = String "Echo"
-- instance FromJSON (Cmd a i o b) where
--   parseJSON (String x) = go x
--     where
--       go "Id" = Id
--       go "Echo" = Echo
--       go _ = bad
--       bad = error "bad FromJSON Cmd"
--   parseJSON _ = bad
--     where
--       bad = error "bad FromJSON Cmd"
-- Protocol:
--    Client sends {id:String, cmd:String, init:a}, then a sequence of {id:String,val:i}
--    Server/probe responds with {id:String,val:o} and finally with {id:String,done:b} or {id:String,fatal:String}


data Msg where
  Init  :: Text -> Text -> Value -> Msg -- Client/initiator sends {id:String, cmd:String, init:a}
  In    :: Text -> Value -> Msg           -- Client/initiator sends a sequence of {id:String,val:i}
  Out   :: Text -> Value -> Msg           -- Server/probe responds with {id:String,val:o}
  Done  :: Text -> Value -> Msg           -- Server completed  {id:String,done:b}
  Fatal :: Text -> String -> Msg          -- Server crashed  {id:String,done:b}
  deriving (Generic)
instance ToJSON Msg
instance FromJSON Msg
msgToObject :: Msg -> Object
msgToObject m = case toJSON m of
  Object o -> o
  _ -> error "bad obj"

listenSelfTyped :: IO ()
listenSelfTyped = listenSelf $ \recv send -> do
  -- TODO thanks to the reqId field we could allow several requests in parallel: for now run all in sequence
  Init reqId cmdId initVal <- unsafeFromRes . fromJSON . Object <$> recv
  let recvIn = do { In reqId val <- unsafeFromRes . fromJSON . Object <$> recv ; pure val }
  let sendOut = (send . msgToObject . Out reqId)
  let sendDone = (send . msgToObject . Done reqId)
  let sendFatal = (send . msgToObject . Fatal reqId)
  -- TODO break out impl functions so that it's not breakable...
  -- e.g. pass refInit/refIn/unrefOut/unrefRes
  -- FIXME also catch errors in refCmd
  refCmd cmdId $ \cmd -> do
      let initVal_  = refInit cmd initVal
      let recvIn_   = refIn cmd <$> recvIn
      let sendOut_  = contramap (unrefOut cmd) sendOut
      let sendDone_ = contramap (unrefRes cmd) sendDone
      res <- try $ impl cmd initVal_ recvIn_ sendOut_
      case res of
        Left (e :: SomeException) -> sendFatal (show e)
        Right res -> sendDone_ res

unsafeFromRes :: Result a -> a
unsafeFromRes (Success x) = x
unsafeFromRes _ = error "bad res"

unsafeFromObj (Object x) = x
unsafeFromObj _ = error "bad obj"


test2 = do
  withSelfRemoteTyped ("hans", "localhost", "22", ["selfremote"]) Ls "/Users/Hoglund/Desktop" $ \recv send res -> threadDelay 2000000 >> wait res

test = withSelfRemote ("hans", "localhost", "22", ["selfremote"]) $ \recv send done -> withAsync (forever $ do { v <- recv ; print v }) $ \_ -> do
  -- threadDelay 2000000
  send $ v "first"
  forever $ do
    send $ v "foo"
    threadDelay 20000
  where
    v x = fromList [("value", String x)]



echo :: Monad m => m t -> (t -> m a) -> m b
echo inp out = forever $ do
  msg <- inp
  out msg

listenSelf :: (IO Object -> (Object -> IO ()) -> IO ()) -> IO ()
listenSelf k =
  k (recvObject stdin) (sendObject stdout)

type Username  = String
type Hostname  = String
type Port      = String
type Arguments = [String]
type TypeRepStr = String

-- | Transfer the current executable to a remote server via SSH and invoke the given command.
--   NOTE: The main function of the current executable *must* handle the specific argument string given to this function by to invoking 'listenSelfTyped'.
withSelfRemoteTyped
  :: (JSON a, JSON i, JSON o, JSON b)
  => (Username, Hostname, Port, Arguments)
  -> Cmd a i o b
  -> a
  -> (IO o -> (i -> IO ()) -> Async (Either (Maybe (TypeRepStr, String), ExitCode) b) -> IO r)
  -> IO r
withSelfRemoteTyped conn cmd init k = withSelfRemote conn $ \recv send done -> do
  let reqId = "dummy"
  send $ msgToObject $ Init reqId (unrefCmd cmd) (unrefInit cmd init)
  withAsync (forever $ recv >>= print) $ \_ ->
    k
      -- FIXME parse Out/Done/Fatal
      (refOut cmd <$> do { Out reqId val <- unsafeFromRes . fromJSON . Object <$> recv ; pure val })

      (contramap (msgToObject . In reqId . unrefIn cmd) send)

      -- FIXME also objserver return value etc.. (maybe change return type too...), see above
      (Left . (Nothing, ) <$> done)


-- | Transfer the current executable to a remote server via SSH and invoke it there.
--   The main of the current process must dispatch the arguments given to withSelfRemote to invoke listenSelf for this to work.
withSelfRemote
  :: (Username, Hostname, Port, Arguments)
    -- ^ Where to run + argument strings (so we can dispatch to selfListen)
  -> (IO Object -> (Object -> IO ()) -> Async ExitCode -> IO r)
  -> IO r
withSelfRemote (_,_,_,args) k = do
  exePath <- getCurrentProcessPath
  print ("FIXME", exePath)
  -- TODO actually transfer + run remotely via SSH
  --  scp exePath root@localhost:tmpPath
  --  ssh root@localhost -p 32768 "tmpPath args..."
  -- Test locally:
  withProcessJSON (proc exePath args) k

-- FIXME proper incremental JSON parsing instead of hGetLine, hPutStrLn
sendObject :: Handle -> Object -> IO ()
sendObject handle v = do
  (hPutStrLn handle . LBS.toStrict . encode) v
  hFlush handle

recvObject :: Handle -> IO Object
recvObject handle = (maybe (error "bad bs") id . decode . LBS.fromStrict <$> hGetLine handle)

-- |
-- Run an action alongside an external process
--
-- Provide a (blocking) action to read JSON objects emitted on stdout, and a send action to send JSON objects
-- to its stdin.
withProcessJSON
  :: CreateProcess
  -> (IO Object -> (Object -> IO ()) -> Async ExitCode -> IO r)
  -> IO r
withProcessJSON pd k = do
  inChan <- newTChanIO
  outChan <- newTChanIO
  let getInput = atomically $ readTChan inChan
  let putInput x = atomically $ writeTChan inChan x
  let getOutput = atomically $ readTChan outChan
  let putOutput x = atomically $ writeTChan outChan x
  withProcessPipes pd
            (\inh -> forever $ do { v <- getOutput ; sendObject inh v })
            (\outh -> forever $ do { v <- recvObject outh; putInput v } )
            (const blockForever)
            (k getInput putOutput)
  where
    blockForever = forever $ threadDelay 1000 -- maxBound

withProcessPipes
  :: CreateProcess
     -> (Handle -> IO Void)
     -> (Handle -> IO Void)
     -> (Handle -> IO Void)
     -> (Async ExitCode -> IO c)
     -> IO c
withProcessPipes pd ih oh eh k = withProcess' (usePipes pd) $ \(in', out, err, pid) ->
  withAsync (ih $ pipeIsThere in') $ \iDone ->
    withAsync (oh $ pipeIsThere out) $ \oDone ->
      withAsync (eh $ pipeIsThere err) $ \eDone ->
        withAsync (waitForProcess pid) $ \pDone ->
          withAsync (fmap snd $ waitAny $ pDone : fmap vacuous [iDone, oDone, eDone]) k
  where
    usePipes pd = pd { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }
    pipeIsThere = maybe (error "withProcess: Assuming t pipe is there") id

withProcess'
  :: CreateProcess
     -> ((Maybe Handle,
          Maybe Handle,
          Maybe Handle,
          ProcessHandle)
         -> IO c)
     -> IO c
withProcess' pd = bracket (createProcess pd) (\(in', out, err, pid) -> do { m hClose in' ; m hClose out ; m hClose err; terminateProcess pid })
  where
    m f = maybe (pure ()) f
--
--
type JSON a = (ToJSON a, FromJSON a)
-- -- Some serialization
-- -- What we really want is (a `Isomorphic` ByteString)
--
type Future a = Concurrently a -- such that   do { a <- fut ; b <- fut ; a === b}
data Stream r a = Stream (Future (Either r (a, Stream r a)))
  deriving (Functor)

-- terminalStream :: (Stream Void ()) `Iso` ()
-- natStream :: (Stream () ()) `Iso` Natural
-- initialStream :: (Stream Void Void) `Iso` Void
--
-- data FailedToConnect = FailedToConnect
-- data Died
--   = ConnectionDied -- ^ The connection died
--   | RemoteException String String -- ^ Uncaught remote exception. The fields are (show $ typeRep exn) (show exn)
--a
-- type CommandInterp f a i o b = a -> Stream Void i -> f (Stream b o)
--
-- -- In place of static pointers, we can just provide a fixed set (including some combinators) and an interpreter function
-- data Prim :: * -> * -> * -> * -> * where
  -- Ls    :: Prim FilePath Void Void [FilePath]
--   Mkdir :: PrimCommand FilePath Void Void Bool
-- -- Combinators, interpreted sender side (we could possibly do some of them client-side in theory, but not necessary here)
-- data Command prim where
--   Prim  :: (JSON a, JSON b, JSON i, JSON o) => prim a i o b -> Command a i o b
--   (||)  :: Command a  i1 o1 b  -> Command b  i2 o2 c -> Command a _ _ c
--   (>>)  :: Command a  i  o1 b  -> Command b  i  o2 c -> Command a i (o1 :| o2) c
--   Xargs :: Command a  _ o1  _  -> Command o1 _  o2 c -> Command a _ (o1 :| (o1,o2) :| (o1,c)) ()
--   -- NOTE restricting (i ~ (), o ~ Void), we get
--   --   from (CommandInterp f a () Void b ~ a -> f b ~ Star f a b)
--   -- Basically, ic Command runs client-side, we get Monad etc, if server-side: not even Applicative (nor Category, because id)
--
-- interp :: Monad f => Command Prim a i o b -> CommandInterp f a i o b
--
-- -- | Make command enterable (e.g. handle transport over stdin and catch top-level exceptions).
-- makeRemotable
--   :: (JSON a, JSON b, JSON i, JSON o, JSON prim)
--   => (prim a i o b -> CommandInterp IO a i o b)
--   -> IO ()
--
-- -- Run itself on the remote host
-- selfRemote
--   :: (User, Hostname, Token)
--     -- ^ Where to run
--     --   The token is just a passed to the CLI, which should trigger the main function to run selfEnter
--   -> Command prim a i o b
--   -> CommandInterp IO a i o b
-- -- or with no RT exceptions, replace CommandInterp with:
-- --  -> a -> Stream Void i -> IO
-- --    (Either FailedToConnect
-- --      (Stream (Either Died b) o))
--
--
-- -- Run as e.g. $ ssh root@localhost -p 32768 "for i in {1..5}; do echo \$i; read; done"
-- -- Note stdin/out works as expected
