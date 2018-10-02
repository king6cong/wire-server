{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs               #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE ViewPatterns               #-}

module Spar.App where

import Bilge
import Cassandra
import Control.Exception (SomeException, assert)
import Control.Monad.Except
import Control.Monad.Reader
import Data.Aeson as Aeson (encode, object, (.=))
import Data.EitherR (fmapL)
import Data.Id
import Data.String.Conversions
import GHC.Stack
import Lens.Micro
import SAML2.Util (renderURI)
import SAML2.WebSSO hiding (UserRef(..))
import Servant
import Spar.API.Instances ()
import Spar.API.Swagger ()
import Spar.Error
import Spar.Options as Options
import Spar.Types
import URI.ByteString as URI
import Web.Cookie (SetCookie, renderSetCookie)

import qualified Cassandra as Cas
import qualified Control.Monad.Catch as Catch
import qualified Data.Text as ST
import qualified Data.ByteString.Builder as Builder
import qualified Data.UUID.V4 as UUID
import qualified SAML2.WebSSO as SAML
import qualified Spar.Data as Data
import qualified Spar.Intra.Brig as Intra
import qualified System.Logger as Log


newtype Spar a = Spar { fromSpar :: ReaderT Env (ExceptT SparError IO) a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadReader Env, MonadError SparError)

data Env = Env
  { sparCtxOpts         :: Opts
  , sparCtxLogger       :: Log.Logger
  , sparCtxCas          :: Cas.ClientState
  , sparCtxHttpManager  :: Bilge.Manager
  , sparCtxHttpBrig     :: Bilge.Request
  , sparCtxRequestId    :: RequestId
  }

instance HasConfig Spar where
  type ConfigExtra Spar = TeamId
  getConfig = asks (saml . sparCtxOpts)

instance SP Spar where
  -- FUTUREWORK: optionally use 'field' to index user or idp ids for easier logfile processing.
  logger (toLevel -> lv) mg = do
    lg <- asks sparCtxLogger
    reqid <- asks sparCtxRequestId
    let fields, mg' :: Log.Msg -> Log.Msg
        fields = Log.field "request" (unRequestId reqid)
        mg'    = Log.msg . condenseLogMsg . cs $ mg
    Spar . Log.log lg lv $ fields Log.~~ mg'

condenseLogMsg :: ST -> ST
condenseLogMsg = ST.intercalate " "
               . filter (/= "")
               . map ST.strip
               . ST.split (`elem` (" \n\r\t\v\f" :: [Char]))

toLevel :: SAML.Level -> Log.Level
toLevel = \case
  SAML.Fatal -> Log.Fatal
  SAML.Error -> Log.Error
  SAML.Warn  -> Log.Warn
  SAML.Info  -> Log.Info
  SAML.Debug -> Log.Debug
  SAML.Trace -> Log.Trace

fromLevel :: Log.Level -> SAML.Level
fromLevel = \case
  Log.Fatal -> SAML.Fatal
  Log.Error -> SAML.Error
  Log.Warn  -> SAML.Warn
  Log.Info  -> SAML.Info
  Log.Debug -> SAML.Debug
  Log.Trace -> SAML.Trace

instance SPStore Spar where
  storeRequest i r      = wrapMonadClientWithEnv $ Data.storeRequest i r
  checkAgainstRequest r = wrapMonadClient        $ Data.checkAgainstRequest r
  storeAssertion i r    = wrapMonadClientWithEnv $ Data.storeAssertion i r

instance SPStoreIdP SparError Spar where
  storeIdPConfig :: IdPConfig TeamId -> Spar ()
  storeIdPConfig idp = wrapMonadClient $ Data.storeIdPConfig idp

  getIdPConfig :: IdPId -> Spar (IdPConfig TeamId)
  getIdPConfig = (>>= maybe (throwSpar SparNotFound) pure) . wrapMonadClientWithEnv . Data.getIdPConfig

  getIdPConfigByIssuer :: Issuer -> Spar (IdPConfig TeamId)
  getIdPConfigByIssuer = (>>= maybe (throwSpar SparNotFound) pure) . wrapMonadClientWithEnv . Data.getIdPConfigByIssuer

-- | 'wrapMonadClient' with an 'Env' in a 'ReaderT', and exceptions.
wrapMonadClientWithEnv :: forall a. ReaderT Data.Env (ExceptT TTLError Cas.Client) a -> Spar a
wrapMonadClientWithEnv action = do
  denv <- Data.mkEnv <$> (sparCtxOpts <$> ask) <*> (fromTime <$> getNow)
  either (throwSpar . SparCassandraTTLError) pure =<< wrapMonadClient (runExceptT $ action `runReaderT` denv)

-- | Call a cassandra command in the 'Spar' monad.  Catch all exceptions and re-throw them as 500 in
-- Handler.
wrapMonadClient :: Cas.Client a -> Spar a
wrapMonadClient action = do
  Spar $ do
    ctx <- asks sparCtxCas
    runClient ctx action `Catch.catch`
      (throwSpar . SparCassandraError . cs . show @SomeException)

insertUser :: SAML.UserRef -> UserId -> Spar ()
insertUser uref uid = wrapMonadClient $ Data.insertUser uref uid

-- | Look up user locally, then in brig, then return the 'UserId'.  If either lookup fails, return
-- 'Nothing'.  See also: 'Spar.App.createUser'.
--
-- ASSUMPTIONS: User creation on brig/galley is idempotent.  Any incomplete creation (because of
-- brig or galley crashing) will cause the lookup here to yield invalid user.
getUser :: SAML.UserRef -> Spar (Maybe UserId)
getUser uref = do
  muid <- wrapMonadClient $ Data.getUser uref
  case muid of
    Nothing -> pure Nothing
    Just uid -> Intra.confirmUserId uid

-- | Create a fresh 'Data.Id.UserId', store it on C* locally together with 'SAML.UserRef', then
-- create user on brig with that 'UserId'.  See also: 'Spar.App.getUser'.
--
-- The manual for the team admin should say this: when deleting a user, delete it on the IdP first,
-- then delete it on the team admin page in wire.  If a user is deleted in wire but not in the IdP,
-- it will be recreated on the next successful login attempt.
--
-- When an sso login succeeds for a user that is marked as deleted in brig, it is recreated by spar.
-- This is necessary because brig does not talk to spar when deleting users, and we may have
-- 'UserId' records on spar that are deleted on brig.  Without this lenient behavior, there would be
-- no way for admins to reuse a 'SAML.UserRef' if it has ever been associated with a deleted user in
-- the past.
--
-- FUTUREWORK: once we support <https://github.com/wireapp/hscim scim>, brig will refuse to delete
-- users that have an sso id, unless the request comes from spar.  then we can make users
-- undeletable in the team admin page, and ask admins to go talk to their IdP system.
createUser :: SAML.UserRef -> Spar UserId
createUser suid = do
  buid <- Id <$> liftIO UUID.nextRandom
  teamid <- (^. idpExtraInfo) <$> getIdPConfigByIssuer (suid ^. uidTenant)
  insertUser suid buid
  buid' <- Intra.createUser suid buid teamid
  assert (buid == buid') $ pure buid


instance SPHandler SparError Spar where
  type NTCTX Spar = Env
  nt ctx (Spar action) = Handler . ExceptT . fmap (fmapL sparToServantErr) . runExceptT $ runReaderT action ctx

instance MonadHttp Spar where
  getManager = asks sparCtxHttpManager

instance Intra.MonadSparToBrig Spar where
  call modreq = do
    req <- asks sparCtxHttpBrig
    httpLbs req modreq


-- | The from of the response on the finalize-login request depends on the verdict (denied or
-- granted), plus the choice that the client has made during the initiate-login request.  Here we
-- call either 'verdictHandlerWeb' or 'verdictHandlerMobile', resp., on the 'SAML.AccessVerdict'.
--
-- NB: there are at least two places in the 'SAML.AuthnResponse' that can contain the request id:
-- the response header and every assertion.  Since saml2-web-sso validation guarantees that the
-- signed in-response-to info in the assertions matches the unsigned in-response-to field in the
-- 'SAML.Response', and fills in the response id in the header if missing, we can just go for the
-- latter.
verdictHandler :: HasCallStack => Maybe BindCookie -> SAML.AuthnResponse -> SAML.AccessVerdict -> Spar SAML.ResponseVerdict
verdictHandler cky aresp verdict = do
  -- [3/4.1.4.2]
  -- <SubjectConfirmation> [...] If the containing message is in response to an <AuthnRequest>, then
  -- the InResponseTo attribute MUST match the request's ID.
  reqid <- either (throwSpar . SparNoRequestRefInResponse . cs) pure $ SAML.rspInResponseTo aresp
  format :: Maybe VerdictFormat <- wrapMonadClient $ Data.getVerdictFormat reqid
  case format of
    Just (VerdictFormatWeb)
      -> verdictHandlerResult cky verdict >>= verdictHandlerWeb
    Just (VerdictFormatMobile granted denied)
      -> verdictHandlerResult cky verdict >>= verdictHandlerMobile granted denied
    Nothing -> throwError $ SAML.BadSamlResponse "AuthRequest seems to have disappeared (could not find verdict format)."
               -- (this shouldn't happen too often, see 'storeVerdictFormat')

data VerdictHandlerResult
  = VerifyHandlerDenied [ST]
  | VerifyHandlerGranted SetCookie UserId

verdictHandlerResult :: HasCallStack => Maybe BindCookie -> SAML.AccessVerdict -> Spar VerdictHandlerResult
verdictHandlerResult bindCky = \case
  denied@(SAML.AccessDenied reasons) -> do
    SAML.logger SAML.Debug (show denied)
    pure $ VerifyHandlerDenied reasons

  SAML.AccessGranted userref -> do
    uid :: UserId <- do
      fromBindCookie <- maybe (pure Nothing) (wrapMonadClient . Data.lookupBindCookie) bindCky
      fromBrig       <- getUser userref
      case (fromBindCookie, fromBrig) of
        (Nothing,  Nothing)  -> createUser userref
        (_,        Just uid) -> pure uid
        (Just uid, Nothing)  -> Intra.bindUser uid userref >> pure uid
        -- (if both bind cookie and sso user lookup are 'Just', it just means that the user
        -- attempted an SSO login when already logged in.  point-, but also harmless.)

    cky :: SetCookie <- Intra.ssoLogin uid  -- TODO: can this be a race condition?  (user is not
                                            -- quite created yet when we ask for a cookie?  do we do
                                            -- quorum reads / writes here?  writes: probably yes,
                                            -- reads: probably no.)
    pure $ VerifyHandlerGranted cky uid

-- | If the client is web, it will be served with an HTML page that it can process to decide whether
-- to log the user in or show an error.
--
-- The HTML page is empty and has two ways to communicate the verdict to the js app:
-- - A title element with contents @wire:sso:<outcome>@.  This is chosen to be easily parseable and
--   not be the title of any page sent by the IdP while it negotiates with the user.
-- - The page broadcasts a message to '*', to be picked up by the app.
verdictHandlerWeb :: HasCallStack => VerdictHandlerResult -> Spar SAML.ResponseVerdict
verdictHandlerWeb = pure . \case
    VerifyHandlerDenied reasons -> forbiddenPage reasons
    VerifyHandlerGranted cky _uid -> successPage cky
  where
    forbiddenPage :: [ST] -> SAML.ResponseVerdict
    forbiddenPage reasons = ServantErr
      { errHTTPCode     = 200
      , errReasonPhrase = "forbidden"  -- (not sure what this is used for)
      , errBody         = easyHtml $
                          "<head>" <>
                          "  <title>wire:sso:error:forbidden</title>" <>
                          "   <script type=\"text/javascript\">" <>
                          "       const receiverOrigin = '*';" <>
                          "       window.opener.postMessage(" <> Aeson.encode errval <> ", receiverOrigin);" <>
                          "   </script>" <>
                          "</head>"
      , errHeaders      = []
      }
      where
        errval = object [ "type" .= ("AUTH_ERROR" :: ST)
                        , "payload" .= object [ "label" .= ("forbidden" :: ST)
                                              , "errors" .= reasons
                                              ]
                        ]

    successPage :: SetCookie -> SAML.ResponseVerdict
    successPage cky = ServantErr
      { errHTTPCode     = 200
      , errReasonPhrase = "success"
      , errBody         = easyHtml $
                          "<head>" <>
                          "  <title>wire:sso:success</title>" <>
                          "   <script type=\"text/javascript\">" <>
                          "       const receiverOrigin = '*';" <>
                          "       window.opener.postMessage({type: 'AUTH_SUCCESS'}, receiverOrigin);" <>
                          "   </script>" <>
                          "</head>"
      , errHeaders      = [("Set-Cookie", cs . Builder.toLazyByteString . renderSetCookie $ cky)]
      }

easyHtml :: LBS -> LBS
easyHtml doc =
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" <>
  "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">" <>
  "<html xml:lang=\"en\" xmlns=\"http://www.w3.org/1999/xhtml\">" <> doc <> "</html>"

-- | If the client is mobile, it has picked error and success redirect urls (see
-- 'mkVerdictGrantedFormatMobile', 'mkVerdictDeniedFormatMobile'); variables in these URLs are here
-- substituted and the client is redirected accordingly.
verdictHandlerMobile :: HasCallStack => URI.URI -> URI.URI -> VerdictHandlerResult -> Spar SAML.ResponseVerdict
verdictHandlerMobile granted denied = \case
    VerifyHandlerDenied reasons
      -> mkVerdictDeniedFormatMobile denied "forbidden" &
         either (throwSpar . SparCouldNotSubstituteFailureURI . cs) (pure . forbiddenPage reasons)
    VerifyHandlerGranted cky uid
      -> mkVerdictGrantedFormatMobile granted cky uid &
         either (throwSpar . SparCouldNotSubstituteSuccessURI . cs) (pure . successPage cky)
  where
    forbiddenPage :: [ST] -> URI.URI -> SAML.ResponseVerdict
    forbiddenPage errs uri = err303
      { errReasonPhrase = "forbidden"
      , errHeaders = [ ("Location", cs $ renderURI uri)
                     , ("Content-Type", "application/json")
                     ]
      , errBody = Aeson.encode errs
      }

    successPage :: SetCookie -> URI.URI -> SAML.ResponseVerdict
    successPage cky uri = err303
      { errReasonPhrase = "success"
      , errHeaders = [ ("Location", cs $ renderURI uri)
                     , ("Set-Cookie", cs . Builder.toLazyByteString . renderSetCookie $ cky)
                     ]
      }
