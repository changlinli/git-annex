{- git-annex command-line actions
 -
 - Copyright 2010-2014 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module CmdLine.Action where

import Common.Annex
import qualified Annex
import Types.Command
import qualified Annex.Queue

type CommandActionRunner = CommandStart -> CommandCleanup

{- Runs a command, starting with the check stage, and then
 - the seek stage. Finishes by running the continutation, and 
 - then showing a count of any failures. -}
performCommandAction :: Command -> CmdParams -> Annex () -> Annex ()
performCommandAction Command { cmdseek = seek, cmdcheck = c, cmdname = name } params cont = do
	mapM_ runCheck c
	Annex.changeState $ \s -> s { Annex.errcounter = 0 }
	seek params
	cont
	showerrcount =<< Annex.getState Annex.errcounter
  where
	showerrcount 0 = noop
	showerrcount cnt = error $ name ++ ": " ++ show cnt ++ " failed"

{- Runs one of the actions needed to perform a command.
 - Individual actions can fail without stopping the whole command,
 - including by throwing IO errors (but other errors terminate the whole
 - command).
 - 
 - This should only be run in the seek stage. -}
commandAction :: CommandActionRunner
commandAction a = account =<< tryIO go
  where
	go = do
		Annex.Queue.flushWhenFull
		callCommandAction a
	account (Right True) = return True
	account (Right False) = incerr
	account (Left err) = do
		showErr err
		showEndFail
		incerr
	incerr = do
		Annex.incError
		return False

{- Runs a single command action through the start, perform and cleanup
 - stages, without catching errors. Useful if one command wants to run
 - part of another command. -}
callCommandAction :: CommandActionRunner
callCommandAction = start
  where
	start   = stage $ maybe skip perform
	perform = stage $ maybe failure cleanup
	cleanup = stage $ status
	stage = (=<<)
	skip = return True
	failure = showEndFail >> return False
	status r = showEndResult r >> return r
