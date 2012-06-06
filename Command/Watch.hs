{- git-annex command
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE BangPatterns #-}

module Command.Watch where

import Common.Annex
import Command
import Utility.Inotify
import Utility.ThreadLock
import qualified Annex
import qualified Command.Add
import qualified Git
import qualified Git.Command
import qualified Git.UpdateIndex
import Git.HashObject
import Git.Types
import Git.FilePath
import qualified Backend
import Annex.Content

import Control.Exception as E
import System.INotify
import Control.Concurrent.MVar

def :: [Command]
def = [command "watch" paramPaths seek "watch for changes"]

seek :: [CommandSeek]
seek = [withNothing start]

start :: CommandStart
start = notBareRepo $ do
	showStart "watch" "."
	showAction "scanning"
	inRepo $ Git.Command.run "add" [Param "--update"]
	state <- Annex.getState id
	mvar <- liftIO $ newMVar state
	next $ next $ liftIO $ withINotify $ \i -> do
		let hook a = Just $ runAnnex mvar a
		watchDir i "." (ignored . takeFileName)
			(hook onAdd) (hook onAddSymlink)
			(hook onDel) (hook onDelDir)
		putStrLn "(started)"
		waitForTermination
		return True
	where
		ignored ".git" = True
		ignored ".gitignore" = True
		ignored ".gitattributes" = True
		ignored _ = False

{- Runs a handler, inside the Annex monad.
 -
 - Exceptions by the handlers are ignored, otherwise a whole watcher
 - thread could be crashed.
 -}
runAnnex :: MVar Annex.AnnexState -> (FilePath -> Annex a) -> FilePath -> IO ()
runAnnex mvar a f = do
	startstate <- takeMVar mvar
	r <- E.try (go startstate) :: IO (Either E.SomeException Annex.AnnexState)
	case r of
		Left e -> do
			putStrLn (show e)
			putMVar mvar startstate
		Right !newstate ->
			putMVar mvar newstate
	where
		go state = Annex.exec state $ a f

{- Adding a file is tricky; the file has to be replaced with a symlink
 - but this is race prone, as the symlink could be changed immediately
 - after creation. To avoid that race, git add is not used to stage the
 - symlink. -}
onAdd :: FilePath -> Annex ()
onAdd file = do
	showStart "add" file
	Command.Add.ingest file >>= go
	where
		go Nothing = showEndFail
		go (Just key) = do
			link <- Command.Add.link file key True
			inRepo $ stageSymlink file link
			showEndOk

{- A symlink might be an arbitrary symlink, which is just added.
 - Or, if it is a git-annex symlink, ensure it points to the content
 - before adding it.
 -}
onAddSymlink :: FilePath -> Annex ()
onAddSymlink file = go =<< Backend.lookupFile file
	where
		go Nothing = addlink =<< liftIO (readSymbolicLink file)
		go (Just (key, _)) = do
			link <- calcGitLink file key
			ifM ((==) link <$> liftIO (readSymbolicLink file))
				( addlink link
				, do
					liftIO $ removeFile file
					liftIO $ createSymbolicLink link file
					addlink link
				)
		addlink link = inRepo $ stageSymlink file link

{- The file could reappear at any time, so --cached is used, to only delete
 - it from the index. -}
onDel :: FilePath -> Annex ()
onDel file = inRepo $ Git.Command.run "rm"
	[Params "--quiet --cached --ignore-unmatch --", File file] 

{- A directory has been deleted, or moved, so tell git to remove anything
 - that was inside it from its cache. -}
onDelDir :: FilePath -> Annex ()
onDelDir dir = inRepo $ Git.Command.run "rm"
	[Params "--quiet -r --cached --ignore-unmatch --", File dir]

{- Adds a symlink to the index, without ever accessing the actual symlink
 - on disk. -}
stageSymlink :: FilePath -> String -> Git.Repo -> IO ()
stageSymlink file linktext repo = Git.UpdateIndex.stream_update_index repo [stage]
	where
		stage streamer = do
			line <- Git.UpdateIndex.update_index_line
				<$> (hashObject repo BlobObject linktext)
				<*> pure SymlinkBlob
				<*> toTopFilePath file repo
			streamer line
