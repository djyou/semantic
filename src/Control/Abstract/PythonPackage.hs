{-# LANGUAGE UndecidableInstances #-}
module Control.Abstract.PythonPackage
( runPythonPackaging, Strategy(..) ) where

import           Control.Abstract.Evaluator (LoopControl, Return)
import           Control.Abstract.Heap (Allocator, Deref, deref)
import           Control.Abstract.Value
import           Control.Effect.Carrier
import           Control.Effect.Sum
import           Data.Abstract.Evaluatable
import           Data.Abstract.Name (name)
import           Data.Abstract.Path (stripQuotes)
import           Data.Abstract.Value.Concrete (Value (..), ValueError (..))
import qualified Data.Map as Map
import           Prologue

data Strategy = Unknown | Packages [Text] | FindPackages [Text]
  deriving (Show, Eq)

runPythonPackaging :: ( Carrier sig m
                      , Ord address
                      , Show address
                      , Show term
                      , Member Trace sig
                      , Member (Boolean (Value term address)) sig
                      , Member (State (Heap address (Value term address))) sig
                      , Member (Resumable (BaseError (AddressError address (Value term address)))) sig
                      , Member (Resumable (BaseError (ValueError term address))) sig
                      , Member Fresh sig
                      , Member (State Strategy) sig
                      , Member (Allocator address) sig
                      , Member (Deref (Value term address)) sig
                      , Member (Env address) sig
                      , Member (Error (LoopControl address)) sig
                      , Member (Error (Return address)) sig
                      , Member (Reader ModuleInfo) sig
                      , Member (Reader PackageInfo) sig
                      , Member (Reader Span) sig
                      , Member (Function term address (Value term address)) sig
                      )
                   => Evaluator term address (Value term address) (PythonPackagingC term address (Eff m)) a
                   -> Evaluator term address (Value term address) m a
runPythonPackaging = raiseHandler (runPythonPackagingC . interpret)

newtype PythonPackagingC term address m a = PythonPackagingC { runPythonPackagingC :: m a }

wrap :: Evaluator term address (Value term address) m a -> PythonPackagingC term address (Eff m) a
wrap = PythonPackagingC . runEvaluator

instance ( Carrier sig m
         , Member (Allocator address) sig
         , Member (Boolean (Value term address)) sig
         , Member (Deref (Value term address)) sig
         , Member (Env address) sig
         , Member (Error (LoopControl address)) sig
         , Member (Error (Return address)) sig
         , Member Fresh sig
         , Member (Function term address (Value term address)) sig
         , Member (Reader ModuleInfo) sig
         , Member (Reader PackageInfo) sig
         , Member (Reader Span) sig
         , Member (Resumable (BaseError (AddressError address (Value term address)))) sig
         , Member (Resumable (BaseError (ValueError term address))) sig
         , Member (State (Heap address (Value term address))) sig
         , Member (State Strategy) sig
         , Member Trace sig
         , Ord address
         , Show address
         , Show term
         )
      => Carrier sig (PythonPackagingC term address (Eff m)) where
  ret = PythonPackagingC . ret
  eff op
    | Just e <- prj op = wrap $ case handleCoercible e of
      Call callName super params k -> Evaluator . k =<< do
        case callName of
          Closure _ _ name' paramNames _ _ -> do
            let bindings = foldr (uncurry Map.insert) lowerBound (zip paramNames params)
            let asStrings = deref >=> asArray >=> traverse (deref >=> asString)

            case name' of
              Just n
                | name "find_packages" == n -> do
                  as <- maybe (pure mempty) (fmap (fmap stripQuotes) . asStrings) (Map.lookup (name "exclude") bindings)
                  put (FindPackages as)
                | name "setup" == n -> do
                  packageState <- get
                  if packageState == Unknown then do
                    as <- maybe (pure mempty) (fmap (fmap stripQuotes) . asStrings) (Map.lookup (name "packages") bindings)
                    put (Packages as)
                    else
                      pure ()
              _ -> pure ()
          _ -> pure ()
        call callName super params
      Function name params body k -> function name params body >>= Evaluator . k
      BuiltIn b k -> builtIn b >>= Evaluator . k
    | otherwise        = PythonPackagingC (eff (handleCoercible op))