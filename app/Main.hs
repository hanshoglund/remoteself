{-# LANGUAGE KindSignatures, GADTs, DeriveFunctor, ConstraintKinds #-}

module Main where

import Lib
import System.Process
import Control.Exception
import System.IO
import Control.Concurrent.Async
import Control.Applicative
import Data.Void
import System.Posix.Process (getProcessID)
import System.Exit
import Data.Aeson
import Control.Monad

getCurrentProcessPath :: IO FilePath
getCurrentProcessPath = do
  pid <- getProcessID
  -- TODO read /proc/$PID/exe
  pure "/Users/Hoglund/Code/hs/hsremote/.stack-work/dist/x86_64-osx/Cabal-1.18.1.5/build/hsremote-exe/hsremote-ex"

main :: IO ()
main = listenSelf echo



echo inp out = forever $ do
  msg <- inp
  out msg

listenSelf :: (IO Value -> (Value -> IO ()) -> IO ()) -> IO ()
listenSelf = undefined
-- FIXME proper incremental JSON parsing

type Username  = String
type Hostname  = String
type Port      = String
type Arguments = [String]

-- | Transfer the current process to a remote server via SSH and invoke it there.
--   The main of the current process must dispatch the arguments given to withSelfRemote to invoke listenSelf for this to work.
withSelfRemote
  :: (Username, Hostname, Port, Arguments)
    -- ^ Where to run + argument strings (so we can dispatch to selfListen)
  -> (IO Value -> (Value -> IO ()) -> Async ExitCode -> IO r)
  -> IO r
withSelfRemote (_,_,_,args) k = do
  exePath <- getCurrentProcessPath
  -- TODO actually transfer + run remotely via SSH
  --  scp exePath root@localhost:tmpPath
  --  ssh root@localhost -p 32768 "tmpPath args..."
  -- Test locally:
  withProcessJSON (proc exePath args) k


-- |
-- Run an action alongside an external process
--
-- Provide a (blocking) action to read JSON objects emitted on stdout, and a send action to send JSON objects
-- to its stdin.
withProcessJSON
  :: CreateProcess
  -> (IO Value -> (Value -> IO ()) -> Async ExitCode -> IO r)
  -> IO r
withProcessJSON = undefined
-- TODO use a (bracket ...MVar) lock here to make read/writes thread-safe
-- FIXME proper incremental JSON parsing

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
data Prim :: * -> * -> * -> * -> * where
  Ls    :: Prim FilePath Void Void [FilePath]
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
