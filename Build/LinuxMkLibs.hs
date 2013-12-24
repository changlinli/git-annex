{- Linux library copier and binary shimmer
 -
 - Copyright 2013 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Main where

import Control.Applicative
import System.Environment
import Data.Maybe
import System.FilePath
import System.Directory
import Control.Monad
import Data.List
import Data.List.Utils
import System.Posix.Files
import Data.Char

import Utility.PartialPrelude
import Utility.Directory
import Utility.Process
import Utility.Monad
import Utility.Path
import Utility.FileMode
import Utility.CopyFile

main :: IO ()
main = getArgs >>= go
  where
	go [] = error "specify LINUXSTANDALONE_DIST"
	go (top:_) = mklibs top

mklibs :: FilePath -> IO ()
mklibs top = do
	fs <- dirContentsRecursive top
	exes <- filterM checkExe fs
	libs <- parseLdd <$> readProcess "ldd" exes
	glibclibs <- glibcLibs
	let libs' = nub $ libs ++ glibclibs
	libdirs <- nub . catMaybes <$> mapM (installLib top) libs'
	writeFile (top </> "libdirs") (unlines libdirs)
	writeFile (top </> "linker")
		(Prelude.head $ filter ("ld-linux" `isInfixOf`) libs')
	writeFile (top </> "gconvdir")
		(Prelude.head $ filter ("/gconv/" `isInfixOf`) glibclibs)
	
	mapM_ (installLinkerShim top) exes

installLib :: FilePath -> FilePath -> IO (Maybe FilePath)
installLib top lib = ifM (doesFileExist lib)
	( do
		installFile top lib
		s <- getSymbolicLinkStatus lib
		when (isSymbolicLink s) $ do
			l <- readSymbolicLink (inTop top lib)
			let absl = absPathFrom (parentDir lib) l
			let target = relPathDirToFile (parentDir lib) absl
			installFile top absl
			nukeFile (top ++ lib)
			createSymbolicLink target (inTop top lib)
		return $ Just $ parentDir lib
	, return Nothing
	)

{- Installs a linker shim script around a binary.
 -
 - Note that each binary is put into its own separate directory,
 - to avoid eg git looking for binaries in its directory rather
 - than in PATH.-}
installLinkerShim :: FilePath -> FilePath -> IO ()
installLinkerShim top exe = do
	createDirectoryIfMissing True shimdir
	renameFile exe exedest
	writeFile exe $ unlines
		[ "#!/bin/sh"
		, "exec \"$GIT_ANNEX_LINKER\" --library-path \"$GIT_ANNEX_LD_LIBRARY_PATH\" \"$GIT_ANNEX_SHIMMED/" ++ base ++ "/" ++ base ++ "\" \"$@\""
		]
	modifyFileMode exe $ addModes executeModes
  where
	base = takeFileName exe
	shimdir = top </> "shimmed" </> base
	exedest = shimdir </> base

installFile :: FilePath -> FilePath -> IO ()
installFile top f = do
	createDirectoryIfMissing True destdir
	void $ copyFileExternal f destdir
  where
  	-- Note: This is an absolute, not a relative, directory.
	dir = parentDir f
	destdir = inTop top dir

-- Note that f is not relative, so cannot use </>
inTop :: FilePath -> FilePath -> FilePath
inTop top f = top ++ f -- 

checkExe :: FilePath -> IO Bool
checkExe f
	| ".so" `isSuffixOf` f = return False
	| otherwise = ifM (isExecutable . fileMode <$> getFileStatus f)
		( checkFileExe <$> readProcess "file" [f]
		, return False
		)

{- Check that file(1) thinks it's a Linux ELF executable, or possibly
 - a shared library (a few executables like ssh appear as shared libraries). -}
checkFileExe :: String -> Bool
checkFileExe s = and
	[ "ELF" `isInfixOf` s
	, "executable" `isInfixOf` s || "shared object" `isInfixOf` s
	]

{- Parse ldd output, getting all the libraries that the input files
 - link to. Note that some of the libraries may not exist 
 - (eg, linux-vdso.so) -}
parseLdd :: String -> [FilePath]
parseLdd = catMaybes . map (getlib . dropWhile isSpace) . lines
  where
	getlib l = headMaybe . words =<< lastMaybe (split " => " l)

{- Get all glibc libs and other support files, including gconv files
 -
 - XXX Debian specific. -}
glibcLibs :: IO [FilePath]
glibcLibs = lines <$> readProcess "sh"
	["-c", "dpkg -L libc6 | egrep '\\.so|gconv'"]
