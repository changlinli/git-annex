{- git-annex test data types.
 -
 - Copyright 2011-2015 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE CPP #-}

module Types.Test where

#ifdef WITH_TESTSUITE
import Test.Tasty.Options
import Data.Monoid
import Prelude
#endif

#ifdef WITH_TESTSUITE
data TestOptions = TestOptions
	{ tastyOptionSet :: OptionSet
	, keepFailuresOption :: Bool
	}

instance Monoid TestOptions where
	mempty = TestOptions mempty False
	mappend a b = TestOptions
		(tastyOptionSet a <> tastyOptionSet b)
		(keepFailuresOption a || keepFailuresOption b)

#else
type TestOptions = ()
#endif

type TestRunner = TestOptions -> IO ()
