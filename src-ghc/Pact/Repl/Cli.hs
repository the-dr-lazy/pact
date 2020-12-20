{-# LANGUAGE TupleSections #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      :  Pact.Repl.Cli
-- Copyright   :  (C) 2020 Stuart Popejoy
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Stuart Popejoy <stuart@kadena.io>
--
-- Client library
--

module Pact.Repl.Cli
  ( loadCli
  ) where


import Control.Lens
import Control.Monad.Catch
import Control.Monad.Reader
import Control.Monad.State.Strict
import Data.Aeson hiding (Object)
import Data.Default
import Data.Function
import qualified Data.Map.Strict as M
import qualified Data.HashMap.Strict as HM
import Data.List (sortBy,elemIndex)
import Data.Text (Text,unpack,intercalate)
import Data.Thyme.Time.Core
import Data.Thyme.Clock
import qualified Data.Vector as V
import Network.Connection
import Network.HTTP.Client hiding (responseBody)
import Network.HTTP.Client.TLS
import Servant.Client.Core
import Servant.Client
import Servant.Server
import System.IO
-- import System.FilePath
import Text.Trifecta as TF hiding (line,err,try,newline)

import Pact.ApiReq
import Pact.Compile
import Pact.Eval
import Pact.Native
-- intentionally hidden unused functions to prevent lib functions from consuming gas
import Pact.Native.Internal hiding (defRNative,defGasRNative,defNative)
import Pact.Parse
import Pact.Repl
import Pact.Repl.Lib
import Pact.Repl.Types
import Pact.Types.API
import Pact.Types.Command
import Pact.Types.Runtime
import Pact.Types.PactValue
import Pact.Types.Pretty
import Pact.Server.API



cliDefs :: NativeModule
cliDefs = ("Cli",
     [
      defZNative "local" local'
      (funType a [("exec",a)])
      [LitExample "(local (+ 1 2))"]
      "Evaluate EXEC on server."
      ,
      defZNative "add-cap" addCap
      (funType tTyString [("cap",TyFun $ funType' tTyBool []),("signers",TyList (tTyString))])
      [LitExample "(add-cap (coin.TRANSFER \"alice\" \"bob\" 10.0) [\"alice\"])"]
      "Add signer capability CAP for SIGNERS"
      ,
      defZRNative "import" import'
      (funType tTyString [("modules", TyList (tTyString))])
      [LitExample "(import ['fungible-v2,'coin])"]
      "Import and load code for MODULES from remote."
     ])
  where
       a = mkTyVar "a" []

import' :: RNativeFun LibState
import' i as = do
  ms <- forM as $ \a -> case a of
    TLitString m -> return $ "(describe-module \"" <> m <> "\")"
    _ -> evalError' a "Expected string"
  mds <- localExec i $ "[" <> (intercalate " " ms) <> "]"
  rs <- case mds of
    PList vs -> forM vs $ \md ->
      case preview (_PObject . to _objectMap . ix "code" . _PLiteral . _LString) md of
        Just code -> evalPact' code
        Nothing -> evalError' i "Expected code"
    _ -> evalError' i "Expected list"
  return $ toTList TyAny def (concat rs)


termToCode :: Term Ref -> Text
termToCode (TLiteral l _) = renderCompactText l
termToCode (TList vs _ _) = "[" <> intercalate " " (V.toList $ termToCode <$> vs) <> "]"
termToCode (TObject (Object (ObjectMap om) _ ko _) _) =
  "{" <> intercalate ", " (map go (psort ko $ M.toList $ (termToCode <$> om))) <> "}"
  where psort Nothing = id
        psort (Just o) = sortBy (compare `on` ((`elemIndex` o) . fst))
        go (k,v) = renderCompactText k <> ": " <> v
termToCode (TApp (App f as _) _) =
  "(" <> termToCode f <> " " <> intercalate " " (map termToCode as) <> ")"
termToCode (TConst (Arg n _ _) mn _ _ _) = case mn of
  Nothing -> n
  Just m -> renderCompactText m <> "." <> n
termToCode (TVar v _) = case v of
  Direct d -> termToCode $ fmap (\_ -> error "Direct with var unsupported") d
  Ref r -> termToCode r
termToCode TNative {..} = renderCompactText _tNativeName
termToCode (TDef Def {..} _) = renderCompactText _dModule <> "." <> renderCompactText _dDefName
termToCode t = renderCompactText t

local' :: ZNativeFun LibState
local' i as = do
  let code = intercalate " " $ map termToCode as
  fromPactValue <$> localExec i code

localExec :: HasInfo i => i -> Text -> Eval LibState PactValue
localExec i code = do
  cmd <- buildCmd i code
  env <- buildEndpoint i
  r <- sendLocal i env cmd
  case _pactResult (_crResult r) of
    Left e -> throwM e
    Right v -> return v


infoCode :: HasInfo i => i -> Term n
infoCode = tStr . tShow . getInfo

addCap :: ZNativeFun LibState
addCap _i [TApp (App n as _) _,signers] = do
  let name = infoCode n
  as' <- mapM reduce as
  signers' <- reduce signers
  eval (TApp (App (TVar (QName (QualifiedName "cli" "add-cap1" def)) def)
               [ name
               , TList (V.fromList as') TyAny def
               , signers' ]
               def) def)

addCap i as = argsError' i as

cliState :: HasInfo i => i -> FieldKey -> Fold PactValue a -> Eval LibState a
cliState i k p = evalExpect i (asString k) (_head . _PObject . to _objectMap . ix k . p) "(cli.cli-state)"

buildEndpoint :: HasInfo i => i -> Eval LibState ClientEnv
buildEndpoint i = do
  cid <- cliState i "chain-id" (_PLiteral . _LInteger)
  pactCid <- evalExpect1 i "integer" (_PLiteral . _LInteger) "PACT_CHAIN_ID"
  let isPact = cid == pactCid
  host <- cliState i "host" (_PLiteral . _LString)
  nw <- cliState i "network-id" (_PLiteral . _LString)
  let url | isPact = "http://" <> host <> "/"
          | otherwise = "https://" <> host <> "/chainweb/0.0/" <> nw <> "/chain/" <> tShow cid <> "/pact"
  burl <- parseBaseUrl (unpack url)
  -- mgr <- liftIO $ newManager defaultManagerSettings
  liftIO $ getClientEnv burl

buildCmd :: HasInfo i => i -> Text -> Eval LibState (Command Text)
buildCmd i cmd = do
  ttl <- cliState i "ttl" (_PLiteral . _LInteger)
  nw <- NetworkId <$> cliState i "network-id" (_PLiteral . _LString)
  ctime <- cliState i "creation-time" (_PLiteral . _LTime)
  nonce <- cliState i "nonce" (_PLiteral . _LString)
  cid <- cliState i "chain-id" (_PLiteral . _LInteger)
  sender <- cliState i "sender" (_PLiteral . _LString)
  gasLimit <- view (eeGasEnv . geGasLimit)
  gasPrice <- view (eeGasEnv . geGasPrice)
  md <- view eeMsgBody
  let toCT = TxCreationTime . fromIntegral . (`div` 1000000) . toMicroseconds . utcTimeToPOSIXSeconds
  liftIO $ mkExec cmd md
    (PublicMeta (ChainId (tShow cid))
     sender gasLimit gasPrice (fromIntegral ttl)
     (toCT ctime))
    []
    (Just nw)
    (Just nonce)

getClientEnv :: BaseUrl -> IO ClientEnv
getClientEnv url = flip mkClientEnv url <$> newTlsManagerWith mgrSettings
    where
      mgrSettings = mkManagerSettings
       (TLSSettingsSimple True False False)
       Nothing

evalExpect1 :: HasInfo i => i -> Text -> Fold PactValue a -> Text -> Eval LibState a
evalExpect1 i msg f = evalExpect i msg (_head . f)

evalExpect :: HasInfo i => i -> Text -> Fold [PactValue] a -> Text -> Eval LibState a
evalExpect i msg f cmd = do
  r <- evalPactValue cmd
  case preview f r of
    Nothing -> evalError' i $ "Expected " <> pretty msg <> " for command " <> pretty cmd
    Just v -> return v

evalPactValue :: Text -> Eval e [PactValue]
evalPactValue e = evalPact' e >>= traverse toPV
  where
    toPV t = eitherDie t $ toPactValue t

evalPact' :: Text -> Eval e [Term Name]
evalPact' cmd = compilePact cmd >>= mapM eval

compilePact :: Text -> Eval e [Term Name]
compilePact cmd = case TF.parseString exprsOnly mempty (unpack cmd) of
  TF.Success es -> mapM go es
  TF.Failure f -> evalError def $ unAnnotate $ _errDoc f
  where
    go e = case compile (mkTextInfo cmd) e of
      Right t -> return t
      Left l -> evalError (peInfo l) (peDoc l)


loadCli :: Maybe FilePath -> Repl ()
loadCli _confm = do
  rEnv . eeRefStore . rsNatives %= HM.union (moduleToMap cliDefs)
  void $ loadFile def "cli/cli.repl"


_cli :: IO ()
_cli = do
  s <- initReplState Interactive Nothing
  void $ (`evalStateT` s) $ do
    useReplLib
    loadCli Nothing
    forever $ pipeLoop True stdin Nothing

_eval :: Eval LibState a -> IO a
_eval e = do
  s <- initReplState Interactive Nothing
  (r,_) <- (`evalStateT` s) $ do
    useReplLib
    loadCli Nothing
    evalEval def e
  either (error . show) return r

_testCode :: Text -> IO [Text]
_testCode code = _eval (fmap termToCode <$> (compilePact code >>= mapM enscope))


send :: HasInfo i => i -> ClientEnv -> SubmitBatch -> Eval e RequestKeys
send i env sb =
  liftIO (runClientM (sendClient sb) env) >>= eitherDie i

sendLocal :: HasInfo i => i -> ClientEnv -> Command Text -> Eval e (CommandResult Hash)
sendLocal i env cmd =
  liftIO (runClientM (localClient cmd) env) >>= eitherDie i

eitherDie :: HasInfo i => Pretty a => i -> Either a b -> Eval e b
eitherDie i = either (evalError' i . pretty) return
