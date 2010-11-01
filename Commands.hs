{- git-annex command line
 -
 - Copyright 2010 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Commands (parseCmd) where

import System.Console.GetOpt
import Control.Monad.State (liftIO)
import System.Posix.Files
import System.Directory
import Data.String.Utils
import Control.Monad (filterM)
import Monad (when, unless)

import qualified GitRepo as Git
import qualified Annex
import Utility
import Locations
import qualified Backend
import UUID
import LocationLog
import Types
import Core
import qualified Remotes
import qualified TypeInternals

{- A subcommand runs in four stages. Each stage can return the next stage
 - to run.
 -
 - 0. The parse stage takes the parameters passed to the subcommand,
 -    looks through the repo to find the ones that are relevant
 -    to that subcommand (ie, new files to add), and returns a list of
 -    start stage actions to run. -}
type SubCmdParse = [String] -> Git.Repo -> IO [SubCmdStart]
{- 1. The start stage is run before anything is printed about the
  -   subcommand, is passed some input, and can early abort it
  -   if the input does not make sense. It should run quickly and
  -   should not modify Annex state. -}
type SubCmdStart = Annex (Maybe SubCmdPerform)
{- 2. The perform stage is run after a message is printed about the subcommand
 -    being run, and it should be where the bulk of the work happens. -}
type SubCmdPerform = Annex (Maybe SubCmdCleanup)
{- 3. The cleanup stage is run only if the perform stage succeeds, and it
 -    returns the overall success/fail of the subcommand. -}
type SubCmdCleanup = Annex Bool

data SubCommand = SubCommand {
	subcmdname :: String,
	subcmdparams :: String,
	subcmdparse :: SubCmdParse,
	subcmddesc :: String
}
subCmds :: [SubCommand]
subCmds =  [
	  (SubCommand "add" path	(withFilesNotInGit addStart)
		"add files to annex")
	, (SubCommand "get" path	(withFilesInGit getStart)
		"make content of annexed files available")
	, (SubCommand "drop" path	(withFilesInGit dropStart)
		"indicate content of files not currently wanted")
	, (SubCommand "move" path	(withFilesInGit moveStart)
		"transfer content of files to/from another repository")
	, (SubCommand "init" desc	(withDescription initStart)
		"initialize git-annex with repository description")
	, (SubCommand "unannex" path	(withFilesInGit unannexStart)
		"undo accidential add command")
	, (SubCommand "fix" path	(withFilesInGit fixStart)
		"fix up symlinks to point to annexed content")
	, (SubCommand "pre-commit" path (withFilesToBeCommitted fixStart)
		"fix up symlinks before they are committed")
	, (SubCommand "fromkey" key	(withFilesMissing fromKeyStart)
		"adds a file using a specific key")
	, (SubCommand "dropkey"	key	(withKeys dropKeyStart)
		"drops annexed content for specified keys")
	, (SubCommand "setkey" key	(withTempFile setKeyStart)
		"sets annexed content for a key using a temp file")
	]
	where
		path = "PATH ..."
		key = "KEY ..."
		desc = "DESCRIPTION"

-- Each dashed command-line option results in generation of an action
-- in the Annex monad that performs the necessary setting.
options :: [OptDescr (Annex ())]
options = [
	    Option ['f'] ["force"] (NoArg (storebool "force" True))
		"allow actions that may lose annexed data"
	  , Option ['q'] ["quiet"] (NoArg (storebool "quiet" True))
		"avoid verbose output"
	  , Option ['v'] ["verbose"] (NoArg (storebool "quiet" False))
		"allow verbose output"
	  , Option ['b'] ["backend"] (ReqArg (storestring "backend") "NAME")
		"specify default key-value backend to use"
	  , Option ['k'] ["key"] (ReqArg (storestring "key") "KEY")
		"specify a key to use"
	  , Option ['t'] ["to"] (ReqArg (storestring "torepository") "REPOSITORY")
		"specify to where to transfer content"
	  , Option ['f'] ["from"] (ReqArg (storestring "fromrepository") "REPOSITORY")
		"specify from where to transfer content"
	  ]
	where
		storebool n b = Annex.flagChange n $ FlagBool b
		storestring n s = Annex.flagChange n $ FlagString s

header :: String
header = "Usage: git-annex " ++ (join "|" $ map subcmdname subCmds)

{- Usage message with lists of options and subcommands. -}
usage :: String
usage = usageInfo header options ++ "\nSubcommands:\n" ++ cmddescs
	where
		cmddescs = unlines $ map (\c -> indent $ showcmd c) subCmds
		showcmd c =
			(subcmdname c) ++
			(pad 11 (subcmdname c)) ++
			(subcmdparams c) ++
			(pad 13 (subcmdparams c)) ++
			(subcmddesc c)
		indent l = "  " ++ l
		pad n s = take (n - (length s)) $ repeat ' '

{- Prepares a set of actions to run to perform a subcommand, based on
 - the parameters passed to it. -}
prepSubCmd :: SubCommand -> Git.Repo -> [String] -> IO [Annex Bool]
prepSubCmd SubCommand { subcmdparse = parse } repo params = do
	list <- parse params repo :: IO [SubCmdStart]
	return $ map (\a -> doSubCmd a) list

{- Runs a subcommand through the start, perform and cleanup stages -}
doSubCmd :: SubCmdStart -> SubCmdCleanup
doSubCmd start = do
	s <- start
	case (s) of
		Nothing -> return True
		Just perform -> do
			p <- perform
			case (p) of
				Nothing -> do
					showEndFail
					return False
				Just cleanup -> do
					c <- cleanup
					if (c)
						then do
							showEndOk
							return True
						else do
							showEndFail
							return False

{- These functions parse a user's parameters into a list of SubCmdStart
   actions to perform. -}
type ParseStrings = (String -> SubCmdStart) -> SubCmdParse
withFilesNotInGit :: ParseStrings
withFilesNotInGit a params repo = do
	files <- mapM (Git.notInRepo repo) params
	return $ map a $ notState $ foldl (++) [] files
withFilesInGit :: ParseStrings
withFilesInGit a params repo = do
	files <- mapM (Git.inRepo repo) params
	return $ map a $ notState $ foldl (++) [] files
withFilesMissing :: ParseStrings
withFilesMissing a params _ = do
	files <- liftIO $ filterM missing params
	return $ map a $ notState files
	where
		missing f = do
			e <- doesFileExist f
			return $ not e
withDescription :: ParseStrings
withDescription a params _ = do
	return $ [a $ unwords params]
withFilesToBeCommitted :: ParseStrings
withFilesToBeCommitted a params repo = do
	files <- mapM (Git.stagedFiles repo) params
	return $ map a $ notState $ foldl (++) [] files
withKeys :: ParseStrings
withKeys a params _ = return $ map a params
withTempFile :: ParseStrings
withTempFile a params _ = return $ map a params

{- filter out files from the state directory -}
notState :: [FilePath] -> [FilePath]
notState fs = filter (\f -> stateLoc /= take (length stateLoc) f) fs

{- Parses command line and returns two lists of actions to be 
 - run in the Annex monad. The first actions configure it
 - according to command line options, while the second actions
 - handle subcommands. -}
parseCmd :: [String] -> AnnexState -> IO ([Annex Bool], [Annex Bool])
parseCmd argv state = do
	(flags, params) <- getopt
	when (null params) $ error usage
	case lookupCmd (params !! 0) of
		[] -> error usage
		[subcommand] -> do
			let repo = TypeInternals.repo state
			actions <- prepSubCmd subcommand repo (drop 1 params)
			let configactions = map (\flag -> do
				flag
				return True) flags
			return (configactions, actions)
		_ -> error "internal error: multiple matching subcommands"
	where
		getopt = case getOpt Permute options argv of
			(flags, params, []) -> return (flags, params)
			(_, _, errs) -> ioError (userError (concat errs ++ usage))
		lookupCmd cmd = filter (\c -> cmd  == subcmdname c) subCmds

{- The add subcommand annexes a file, storing it in a backend, and then
 - moving it into the annex directory and setting up the symlink pointing
 - to its content. -}
addStart :: FilePath -> SubCmdStart
addStart file = notAnnexed file $ do
	s <- liftIO $ getSymbolicLinkStatus file
	if ((isSymbolicLink s) || (not $ isRegularFile s))
		then return Nothing
		else do
			showStart "add" file
			return $ Just $ addPerform file
addPerform :: FilePath -> SubCmdPerform
addPerform file = do
	stored <- Backend.storeFileKey file
	case (stored) of
		Nothing -> return Nothing
		Just (key, _) -> return $ Just $ addCleanup file key
addCleanup :: FilePath -> Key -> SubCmdCleanup
addCleanup file key = do
	logStatus key ValuePresent
	g <- Annex.gitRepo
	let dest = annexLocation g key
	liftIO $ createDirectoryIfMissing True (parentDir dest)
	liftIO $ renameFile file dest
	link <- calcGitLink file key
	liftIO $ createSymbolicLink link file
	Annex.queue "add" [] file
	return True

{- The unannex subcommand undoes an add. -}
unannexStart :: FilePath -> SubCmdStart
unannexStart file = isAnnexed file $ \(key, backend) -> do
	showStart "unannex" file
	return $ Just $ unannexPerform file key backend
unannexPerform :: FilePath -> Key -> Backend -> SubCmdPerform
unannexPerform file key backend = do
	-- force backend to always remove
	Annex.flagChange "force" $ FlagBool True
	ok <- Backend.removeKey backend key
	if (ok)
		then return $ Just $ unannexCleanup file key
		else return Nothing
unannexCleanup :: FilePath -> Key -> SubCmdCleanup
unannexCleanup file key = do
	logStatus key ValueMissing
	g <- Annex.gitRepo
	let src = annexLocation g key
	liftIO $ removeFile file
	liftIO $ Git.run g ["rm", "--quiet", file]
	-- git rm deletes empty directories; put them back
	liftIO $ createDirectoryIfMissing True (parentDir file)
	liftIO $ renameFile src file
	return True

{- Gets an annexed file from one of the backends. -}
getStart :: FilePath -> SubCmdStart
getStart file = isAnnexed file $ \(key, backend) -> do
	inannex <- inAnnex key
	if (inannex)
		then return Nothing
		else do
			showStart "get" file
			return $ Just $ getPerform key backend
getPerform :: Key -> Backend -> SubCmdPerform
getPerform key backend = do
	ok <- getViaTmp key (Backend.retrieveKeyFile backend key)
	if (ok)
		then return $ Just $ return True -- no cleanup needed
		else return Nothing

{- Indicates a file's content is not wanted anymore, and should be removed
 - if it's safe to do so. -}
dropStart :: FilePath -> SubCmdStart
dropStart file = isAnnexed file $ \(key, backend) -> do
	inbackend <- Backend.hasKey key
	if (not inbackend)
		then return Nothing
		else do
			showStart "drop" file
			return $ Just $ dropPerform key backend
dropPerform :: Key -> Backend -> SubCmdPerform
dropPerform key backend = do
	success <- Backend.removeKey backend key
	if (success)
		then return $ Just $ dropCleanup key
		else return Nothing
dropCleanup :: Key -> SubCmdCleanup
dropCleanup key = do
	logStatus key ValueMissing
	inannex <- inAnnex key
	if (inannex)
		then do
			g <- Annex.gitRepo
			let loc = annexLocation g key
			liftIO $ removeFile loc
			return True
		else return True

{- Drops cached content for a key. -}
dropKeyStart :: String -> SubCmdStart
dropKeyStart keyname = do
	backends <- Backend.list
	let key = genKey (backends !! 0) keyname
	present <- inAnnex key
	force <- Annex.flagIsSet "force"
	if (not present)
		then return Nothing
		else if (not force)
			then error "dropkey is can cause data loss; use --force if you're sure you want to do this"
			else do
				showStart "dropkey" keyname
				return $ Just $ dropKeyPerform key
dropKeyPerform :: Key -> SubCmdPerform
dropKeyPerform key = do
	g <- Annex.gitRepo
	let loc = annexLocation g key
	liftIO $ removeFile loc
	return $ Just $ dropKeyCleanup key
dropKeyCleanup :: Key -> SubCmdCleanup
dropKeyCleanup key = do
	logStatus key ValueMissing
	return True

{- Sets cached content for a key. -}
setKeyStart :: FilePath -> SubCmdStart
setKeyStart tmpfile = do
	keyname <- Annex.flagGet "key"
	when (null keyname) $ error "please specify the key with --key"
	backends <- Backend.list
	let key = genKey (backends !! 0) keyname
	showStart "setkey" tmpfile
	return $ Just $ setKeyPerform tmpfile key
setKeyPerform :: FilePath -> Key -> SubCmdPerform
setKeyPerform tmpfile key = do
	g <- Annex.gitRepo
	let loc = annexLocation g key
	ok <- liftIO $ boolSystem "mv" [tmpfile, loc]
	if (not ok)
		then error "mv failed!"
		else return $ Just $ setKeyCleanup key
setKeyCleanup :: Key -> SubCmdCleanup
setKeyCleanup key = do
	logStatus key ValuePresent
	return True

{- Fixes the symlink to an annexed file. -}
fixStart :: FilePath -> SubCmdStart
fixStart file = isAnnexed file $ \(key, _) -> do
	link <- calcGitLink file key
	l <- liftIO $ readSymbolicLink file
	if (link == l)
		then return Nothing
		else do
			showStart "fix" file
			return $ Just $ fixPerform file link
fixPerform :: FilePath -> FilePath -> SubCmdPerform
fixPerform file link = do
	liftIO $ createDirectoryIfMissing True (parentDir file)
	liftIO $ removeFile file
	liftIO $ createSymbolicLink link file
	return $ Just $ fixCleanup file
fixCleanup :: FilePath -> SubCmdCleanup
fixCleanup file = do
	Annex.queue "add" [] file
	return True

{- Stores description for the repository etc. -}
initStart :: String -> SubCmdStart
initStart description = do
	when (null description) $ error $
		"please specify a description of this repository\n" ++ usage
	showStart "init" description
	return $ Just $ initPerform description
initPerform :: String -> SubCmdPerform
initPerform description = do
	g <- Annex.gitRepo
	u <- getUUID g
	describeUUID u description
	liftIO $ gitAttributes g
	liftIO $ gitPreCommitHook g
	return $ Just $ initCleanup
initCleanup :: SubCmdCleanup
initCleanup = do
	g <- Annex.gitRepo
	logfile <- uuidLog
	liftIO $ Git.run g ["add", logfile]
	liftIO $ Git.run g ["commit", "-m", "git annex init", logfile]
	return True

{- Adds a file pointing at a manually-specified key -}
fromKeyStart :: FilePath -> SubCmdStart
fromKeyStart file = do
	keyname <- Annex.flagGet "key"
	when (null keyname) $ error "please specify the key with --key"
	backends <- Backend.list
	let key = genKey (backends !! 0) keyname

	inbackend <- Backend.hasKey key
	unless (inbackend) $ error $
		"key ("++keyname++") is not present in backend"
	showStart "fromkey" file
	return $ Just $ fromKeyPerform file key
fromKeyPerform :: FilePath -> Key -> SubCmdPerform
fromKeyPerform file key = do
	link <- calcGitLink file key
	liftIO $ createDirectoryIfMissing True (parentDir file)
	liftIO $ createSymbolicLink link file
	return $ Just $ fromKeyCleanup file
fromKeyCleanup :: FilePath -> SubCmdCleanup
fromKeyCleanup file = do
	Annex.queue "add" [] file
	return True

{- Move a file either --to or --from a repository.
 -
 - This only operates on the cached file content; it does not involve
 - moving data in the key-value backend. -}
moveStart :: FilePath -> SubCmdStart
moveStart file = do
	fromName <- Annex.flagGet "fromrepository"
	toName <- Annex.flagGet "torepository"
	case (fromName, toName) of
		("", "") -> error "specify either --from or --to"
		("",  _) -> moveToStart file
		(_ , "") -> moveFromStart file
		(_ ,  _) -> error "only one of --from or --to can be specified"

{- Moves the content of an annexed file to another repository,
 - removing it from the current repository, and updates locationlog
 - information on both.
 -
 - If the destination already has the content, it is still removed
 - from the current repository.
 -
 - Note that unlike drop, this does not honor annex.numcopies.
 - A file's content can be moved even if there are insufficient copies to
 - allow it to be dropped.
 -}
moveToStart :: FilePath -> SubCmdStart
moveToStart file = isAnnexed file $ \(key, _) -> do
	ishere <- inAnnex key
	if (not ishere)
		then return Nothing -- not here, so nothing to do
		else do
			showStart "move" file
			return $ Just $ moveToPerform key
moveToPerform :: Key -> SubCmdPerform
moveToPerform key = do
	-- checking the remote is expensive, so not done in the start step
	remote <- Remotes.commandLineRemote
	isthere <- Remotes.inAnnex remote key
	case isthere of
		Left err -> do
			showNote $ show err
			return Nothing
		Right False -> do
			Core.showNote $ "moving to " ++ (Git.repoDescribe remote) ++ "..."
			let tmpfile = (annexTmpLocation remote) ++ (keyFile key)
			ok <- Remotes.copyToRemote remote key tmpfile
			if (ok)
				then return $ Just $ moveToCleanup remote key tmpfile
				else return Nothing -- failed
		Right True -> return $ Just $ dropCleanup key
moveToCleanup :: Git.Repo -> Key -> FilePath -> SubCmdCleanup
moveToCleanup remote key tmpfile = do
	-- Tell remote to use the transferred content.
	ok <- Remotes.runCmd remote "git-annex" ["setkey", "--quiet",
		"--backend=" ++ (backendName key),
		"--key=" ++ keyName key,
		tmpfile]
	if ok
		then do
			-- Record that the key is present on the remote.
			g <- Annex.gitRepo
			remoteuuid <- getUUID remote
			logfile <- liftIO $ logChange g key remoteuuid ValuePresent
			Annex.queue "add" [] logfile
			-- Cleanup on the local side is the same as done for the
			-- drop subcommand.
			dropCleanup key
		else return False

{- Moves the content of an annexed file from another repository to the current
 - repository and updates locationlog information on both.
 -
 - If the current repository already has the content, it is still removed
 - from the other repository.
 -}
moveFromStart :: FilePath -> SubCmdStart
moveFromStart file = isAnnexed file $ \(key, _) -> do
	remote <- Remotes.commandLineRemote
	l <- Remotes.keyPossibilities key
	if (null $ filter (\r -> Remotes.same r remote) l)
		then return Nothing
		else do
			showStart "move" file
			return $ Just $ moveFromPerform key
moveFromPerform :: Key -> SubCmdPerform
moveFromPerform key = do
	remote <- Remotes.commandLineRemote
	ishere <- inAnnex key
	if (ishere)
		then return $ Just $ moveFromCleanup remote key
		else do
			Core.showNote $ "moving from " ++ (Git.repoDescribe remote) ++ "..."
			ok <- getViaTmp key (Remotes.copyFromRemote remote key)
			if (ok)
				then return $ Just $ moveFromCleanup remote key
				else return Nothing -- fail
moveFromCleanup :: Git.Repo -> Key -> SubCmdCleanup
moveFromCleanup remote key = do
	ok <- Remotes.runCmd remote "git-annex" ["dropkey", "--quiet", "--force",
		"--backend=" ++ (backendName key),
		keyName key]
	when ok $ do
		-- Record locally that the key is not on the remote.
		remoteuuid <- getUUID remote
		g <- Annex.gitRepo
		logfile <- liftIO $ logChange g key remoteuuid ValueMissing
		Annex.queue "add" [] logfile
	return ok

-- helpers
notAnnexed :: FilePath -> Annex (Maybe a) -> Annex (Maybe a)
notAnnexed file a = do
	r <- Backend.lookupFile file
	case (r) of
		Just _ -> return Nothing
		Nothing -> a
isAnnexed :: FilePath -> ((Key, Backend) -> Annex (Maybe a)) -> Annex (Maybe a)
isAnnexed file a = do
	r <- Backend.lookupFile file
	case (r) of
		Just v -> a v
		Nothing -> return Nothing
