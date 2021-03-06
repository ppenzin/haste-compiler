{-# LANGUAGE EmptyDataDecls #-}
-- | Wraps Haste.Concurrent to work with Haste.App.
--   Task switching happens whenever a thread is blocked in an MVar, so things
--   like polling an IORef in a loop will starve all other threads.
--
--   This will likely be the state of Haste concurrency until Javascript gains
--   decent native concurrency support.
module Haste.App.Concurrent (
    C.MVar, MBox, Send, Recv, Inbox, Outbox,
    fork, forkMany, newMVar, newEmptyMVar, takeMVar, putMVar, peekMVar,
    spawn, receive, statefully, (!), (<!),
    forever
  ) where
import qualified Haste.Concurrent.Monad as C
import Haste.App.Client
import Control.Monad

-- | Spawn off a concurrent computation.
fork :: Client () -> Client ()
fork m = do
  cs <- get id
  liftCIO . C.forkIO $ runClientCIO cs m

-- | Spawn several concurrent computations.
forkMany :: [Client ()] -> Client ()
forkMany = mapM_ fork

-- | Create a new MVar with the specified contents.
newMVar :: a -> Client (C.MVar a)
newMVar = liftCIO . C.newMVar

-- | Create a new empty MVar.
newEmptyMVar :: Client (C.MVar a)
newEmptyMVar = liftCIO C.newEmptyMVar

-- | Read the value of an MVar. If the MVar is empty, @takeMVar@ blocks until
--   a value arrives. @takeMVar@ empties the MVar.
takeMVar :: C.MVar a -> Client a
takeMVar = liftCIO . C.takeMVar

-- | Put a value into an MVar. If the MVar is full, @putMVar@ will block until
--   the MVar is empty.
putMVar :: C.MVar a -> a -> Client ()
putMVar v x = liftCIO $ C.putMVar v x

-- | Read an MVar without affecting its contents.
--   If the MVar is empty, @peekMVar@ immediately returns @Nothing@.
peekMVar :: C.MVar a -> Client (Maybe a)
peekMVar = liftCIO . C.peekMVar

-- | An MBox is a read/write-only MVar, depending on its first type parameter.
--   Used to communicate with server processes.
newtype MBox t a = MBox (C.MVar a)

data Recv
data Send

type Inbox = MBox Recv
type Outbox = MBox Send

-- | Block until a message arrives in a mailbox, then return it.
receive :: Inbox a -> Client a
receive (MBox mv) = takeMVar mv

-- | Creates a generic process and returns a MBox which may be used to pass
--   messages to it.
--   While it is possible for a process created using spawn to transmit its
--   inbox to someone else, this is a very bad idea; don't do it.
spawn :: (Inbox a -> Client ()) -> Client (Outbox a)
spawn f = do
  p <- newEmptyMVar
  fork $ f (MBox p)
  return (MBox p)

-- | Creates a generic stateful process. This process is a function taking a
--   state and an event argument, returning an updated state or Nothing.
--   @statefully@ creates a @MBox@ that is used to pass events to the process.
--   Whenever a value is written to this MBox, that value is passed to the
--   process function together with the function's current state.
--   If the process function returns Nothing, the process terminates.
--   If it returns a new state, the process again blocks on the event MBox,
--   and will use the new state to any future calls to the server function.
statefully :: st -> (st -> evt -> Client (Maybe st)) -> Client (Outbox evt)
statefully initialState handler = do
    spawn $ loop initialState
  where
    loop st p = do
      mresult <- receive p >>= handler st
      case mresult of
        Just st' -> loop st' p
        _        -> return ()

-- | Write a value to a MBox. Named after the Erlang message sending operator,
--   as both are intended for passing messages to processes.
--   This operation does not block until the message is delivered, but returns
--   immediately.
(!) :: Outbox a -> a -> Client ()
MBox m ! x = fork $ putMVar m x

-- | Perform a Client computation, then write its return value to the given
--   pipe. Mnemonic: the operator is a combination of <- and !.
--   Just like @(!)@, this operation is non-blocking.
(<!) :: Outbox a -> Client a -> Client ()
p <! m = do x <- m ; p ! x
