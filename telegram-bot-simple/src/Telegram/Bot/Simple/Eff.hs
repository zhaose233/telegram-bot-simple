{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE FlexibleInstances          #-}
module Telegram.Bot.Simple.Eff where

import           Control.Monad.Reader
import           Control.Monad.Writer
import           Data.Bifunctor
import           Servant.Client

import qualified Telegram.Bot.API     as Telegram

-- | Bot handler context.
--
-- The context may include an 'Update' the bot is handling at the moment.
newtype BotM a = BotM { _runBotM :: ReaderT BotContext ClientM a }
  deriving (Functor, Applicative, Monad, MonadReader BotContext, MonadIO)

data BotContext = BotContext
  { botContextUser   :: Telegram.User
  , botContextUpdate :: Maybe Telegram.Update
  }

-- | To retain control over errors coming from Telegram API in `BotM`,
-- consider using `liftIO . flip runClientM clientEnv` instead.
-- Issues generated by servant-client will be logged, response failure errors will be ignored.
liftClientM :: ClientM a -> BotM a
liftClientM = BotM . lift

runBotM :: BotContext -> BotM a -> ClientM a
runBotM update = flip runReaderT update . _runBotM

newtype Eff action model = Eff { _runEff :: Writer [BotM (Maybe action)] model }
  deriving (Functor, Applicative, Monad)

-- | The idea behind following type class is
--   to allow you defining the type 'ret' you want to return from 'BotM' action.
--   You can create your own return-types via new instances.
--   Here 'action' is a 'botAction'
--   type, that will be used further in 'botHandler' function.
--   If you don't want to return action use 'Nothing' instead.
--
--   See "Telegram.Bot.Simple.Instances" for more commonly useful instances.
--   - @GetAction a a@ - for simple making finite automata of
--   BotM actions. (For example you can log every update
--   and then return new 'action' to answer at message/send sticker/etc)
--   - @GetAction () a@ - to use @pure ()@ instead of dealing with @Nothing@.
--   - @GetAction Text a@ - to add some sugar over the 'replyText' function.
--   'OverloadedStrings' breaks type inference,
--   so we advise to use @replyText \"message\"@
--   instead of @pure \@_ \@Text \"message\"@.
class GetAction return action where
  getNextAction :: BotM return -> BotM (Maybe action)

instance Bifunctor Eff where
  bimap f g = Eff . mapWriter (bimap g (map . fmap . fmap $ f)) . _runEff

runEff :: Eff action model -> (model, [BotM (Maybe action)])
runEff = runWriter . _runEff

eff :: GetAction a b => BotM a -> Eff b ()
eff e = Eff (tell [getNextAction e])

withEffect :: GetAction a action => BotM a -> model -> Eff action model
withEffect effect model = eff effect >> pure model

(<#) :: GetAction a action => model -> BotM a -> Eff action model
(<#) = flip withEffect

-- | Set a specific 'Telegram.Update' in a 'BotM' context.
setBotMUpdate :: Maybe Telegram.Update -> BotM a -> BotM a
setBotMUpdate update (BotM m) =  BotM (local f m)
  where
    f botContext = botContext { botContextUpdate = update }

-- | Set a specific 'Telegram.Update' in every effect of 'Eff' context.
setEffUpdate :: Maybe Telegram.Update -> Eff action model -> Eff action model
setEffUpdate update (Eff m) = Eff (censor (map (setBotMUpdate update)) m)
