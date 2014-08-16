-- ------------------------------------------------------ --
-- Copyright © 2014 AlephCloud Systems, Inc.
-- ------------------------------------------------------ --

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE GADTs #-}

-- |
-- Module: Main
-- Copyright: Copyright © 2014 AlephCloud Systems, Inc.
-- License: BSD3
-- Maintainer: Lars Kuhtz <lars@alephcloud.com>
-- Stability: experimental
--
-- Tests for Haskell SQS bindings
--

module Main
( main
) where

import Aws
import Aws.Core
import qualified Aws.Sqs as SQS

import Control.Arrow (second)
import Control.Error
import Control.Monad
import Control.Monad.IO.Class

import qualified Data.List as L
import Data.Monoid
import qualified Data.Text as T

import Test.Tasty
import Test.QuickCheck.Instances ()

import System.Environment
import System.Exit

import Utils

-- -------------------------------------------------------------------------- --
-- Main

main :: IO ()
main = do
    args <- getArgs
    runMain args $ map (second tail . span (/= '=')) args
  where
    runMain :: [String] -> [(String,String)] -> IO ()
    runMain args _argsMap
        | any (`elem` helpArgs) args = defaultMain (tests undefined)
        | "--run-with-aws-credentials" `elem` args =
            Aws.withEnvironment sqsConfiguration $ \env -> do
                withArgs (tastyArgs args) . defaultMain $ tests env
        | otherwise = putStrLn help >> exitFailure

    helpArgs = ["--help", "-h"]
    mainArgs =
        [ "--run-with-aws-credentials"
        ]
    tastyArgs args = flip filter args $ \x -> not
        $ any (`L.isPrefixOf` x) mainArgs


help :: String
help = L.intercalate "\n"
    [ ""
    , "NOTE"
    , ""
    , "This test suite accesses the AWS account that is associated with"
    , "the default credentials from the credential file ~/.aws-keys."
    , ""
    , "By running the tests in this test-suite costs for usage of AWS"
    , "services may incur."
    , ""
    , "In order to actually excute the tests in this test-suite you must"
    , "provide the command line options:"
    , ""
    , "    --run-with-aws-credentials"
    , ""
    , "When running this test-suite through cabal you may use the following"
    , "command:"
    , ""
    , "    cabal test sqs-tests --test-option=--run-with-aws-credentials"
    , ""
    ]

tests :: Environment (SQS.SqsConfiguration NormalQuery) -> TestTree
tests env = testGroup "SQS Tests"
    [ test_queue env
    , test_message env
    ]

-- -------------------------------------------------------------------------- --
-- Static Test parameters
--
-- TODO make these configurable

testProtocol :: Protocol
testProtocol = HTTP

testSqsEndpoint :: SQS.Endpoint
testSqsEndpoint = SQS.sqsEndpointEu

defaultQueueName :: T.Text
defaultQueueName = "test-queue"

-- -------------------------------------------------------------------------- --
-- SQS Utils

sqsQueueName :: T.Text -> SQS.QueueName
sqsQueueName url = SQS.QueueName (sqsQueueNameText url) (sqsAccountIdText url)

sqsQueueNameText :: T.Text -> T.Text
sqsQueueNameText url = T.split (== '/') url !! 4

sqsAccountIdText :: T.Text -> T.Text
sqsAccountIdText url = T.split (== '/') url !! 3

sqsConfiguration :: SQS.SqsConfiguration NormalQuery
sqsConfiguration = SQS.SqsConfiguration
    { SQS.sqsProtocol = testProtocol
    , SQS.sqsEndpoint = testSqsEndpoint
    , SQS.sqsPort = 80
    , SQS.sqsUseUri = False
    , SQS.sqsDefaultExpiry = 180
    }

simpleSqs
    :: (AsMemoryResponse a, Transaction r a, ServiceConfiguration r ~ SQS.SqsConfiguration, MonadIO m)
    => Environment (SQS.SqsConfiguration NormalQuery)
    -> r
    -> m (MemoryResponse a)
simpleSqs env command = liftIO $ simpleAws env command

simpleSqsT
    :: (AsMemoryResponse a, Transaction r a, ServiceConfiguration r ~ SQS.SqsConfiguration, MonadIO m)
    => Environment (SQS.SqsConfiguration NormalQuery)
    -> r
    -> EitherT T.Text m (MemoryResponse a)
simpleSqsT env = tryT . simpleSqs env

withQueueTest
    :: Environment (SQS.SqsConfiguration NormalQuery)
    -> T.Text -- ^ Queue name
    -> (IO (T.Text, SQS.QueueName) -> TestTree) -- ^ test tree
    -> TestTree
withQueueTest env queueName f = withResource createQueue deleteQueue $ \getQueueUrl ->
    f $ do
        url <- getQueueUrl
        return (url, sqsQueueName url)
  where
    createQueue = do
        SQS.CreateQueueResponse url <- simpleSqs env $ SQS.CreateQueue Nothing queueName
        return url
    deleteQueue url = void $ simpleSqs env (SQS.DeleteQueue (sqsQueueName url))

-- -------------------------------------------------------------------------- --
-- Queue Tests

test_queue :: Environment (SQS.SqsConfiguration NormalQuery) -> TestTree
test_queue env = testGroup "Queue Tests"
    [ eitherTOnceTest1 "CreateListDeleteQueue" (prop_createListDeleteQueue env)
    ]

-- |
--
prop_createListDeleteQueue
    :: Environment (SQS.SqsConfiguration NormalQuery)
    -> T.Text -- ^ queue name
    -> EitherT T.Text IO ()
prop_createListDeleteQueue env queueName = do
    SQS.CreateQueueResponse queueUrl <- simpleSqsT env $ SQS.CreateQueue Nothing tQueueName
    let queue = sqsQueueName queueUrl
    handleT (\e -> deleteQueue queue >> left e) $ do
        retryT 6 $ do
            SQS.ListQueuesResponse allQueueUrls <- simpleSqsT env (SQS.ListQueues Nothing)
            unless (queueUrl `elem` allQueueUrls)
                . left $ "queue " <> sshow queueUrl <> " not listed"
        deleteQueue queue
  where
    tQueueName = testData queueName
    deleteQueue queueUrl = void $ simpleSqsT env (SQS.DeleteQueue queueUrl)

-- -------------------------------------------------------------------------- --
-- Message Tests

test_message :: Environment (SQS.SqsConfiguration NormalQuery) -> TestTree
test_message env =
    withQueueTest env defaultQueueName $ \getQueueParams -> testGroup "Queue Tests"
        [ eitherTOnceTest0 "SendReceiveDeleteMessage" $ do
            (_, queue) <- liftIO getQueueParams
            prop_sendReceiveDeleteMessage env queue
        , eitherTOnceTest0 "SendReceiveDeleteMessageLongPolling" $ do
            (_, queue) <- liftIO getQueueParams
            prop_sendReceiveDeleteMessageLongPolling env queue
        , eitherTOnceTest0 "SendReceiveDeleteMessageLongPolling1" $ do
            (_, queue) <- liftIO getQueueParams
            prop_sendReceiveDeleteMessageLongPolling1 env queue
        ]

-- | Simple send and short-polling receive. First sends all messages
-- and receives messages thereafter one by one.
--
prop_sendReceiveDeleteMessage
    :: Environment (SQS.SqsConfiguration NormalQuery)
    -> SQS.QueueName
    -> EitherT T.Text IO ()
prop_sendReceiveDeleteMessage env queue = do

    -- a visibility timeout should be used only if either @receiveBatch == 1@
    -- or no retry is used so that all received messages are handled.
    let visTimeout = Just 60
    let delay = Just 0
    let poll = Nothing -- no consistent receive (any number of messages up to the requested number can be returned)
    let receiveBatch = 1
    let msgNum = 10

    let messages = map (\i -> "message" <> sshow i) [1 .. msgNum]

    -- send messages
    forM_ messages $ \msg -> void . simpleSqsT env $ SQS.SendMessage msg queue [] delay

    recMsgs <- fmap concat . replicateM msgNum $ do
        msgs <- retryT 5 $ do
            r <- simpleSqsT env $ SQS.ReceiveMessage visTimeout [] (Just receiveBatch) [] queue poll
            case r of
                SQS.ReceiveMessageResponse [] -> left "no message received"
                SQS.ReceiveMessageResponse t
                    | length t <= receiveBatch -> right t
                    | otherwise -> left $ "unexpected number of messages received: " <> sshow (length t)
        forM_ msgs $ \msg -> retryT 5 $
            simpleSqsT env $ SQS.DeleteMessage (SQS.mReceiptHandle msg) queue
        return (map SQS.mBody msgs)

    let recv = L.sort recMsgs
    let sent = L.sort messages
    unless (sent == recv)
        $ left $ "received messages don't match send messages; sent: "
            <> sshow sent <> "; got: " <> sshow recv

-- | Checks for consistent receive: There is no message delay, so all messages
-- are available when the first receive is requested. By enabling long-polling
-- (with value 0) we force SQS to do a consistent receive.
--
prop_sendReceiveDeleteMessageLongPolling
    :: Environment (SQS.SqsConfiguration NormalQuery)
    -> SQS.QueueName
    -> EitherT T.Text IO ()
prop_sendReceiveDeleteMessageLongPolling env queue = do

    let delay = Nothing
    let visTimeout = Just 60
    let poll = Just 1 -- consistent receive (maximum available number of requested messages is returned)
    let receiveBatch = 10
    let msgNum = 40 -- this must be a multiple of 'receiveBatch'

    let messages = map (\i -> "message" <> sshow i) [1 .. msgNum]

    -- send messages
    forM_ messages $ \msg -> void . simpleSqsT env $ SQS.SendMessage msg queue [] delay

    recMsgs <- fmap concat . replicateM (msgNum `div` receiveBatch) $ do
        msgs <- do
            r <- simpleSqsT env $ SQS.ReceiveMessage visTimeout [] (Just receiveBatch) [] queue poll
            case r of
                SQS.ReceiveMessageResponse [] -> left "no messages received"
                SQS.ReceiveMessageResponse t
                    | length t == receiveBatch -> right t
                    | otherwise -> left $ "unexpected number of messages received: " <> sshow (length t)
        forM_ msgs $ \msg -> retryT 5 $
            simpleSqsT env $ SQS.DeleteMessage (SQS.mReceiptHandle msg) queue
        return (map SQS.mBody msgs)

    let recv = L.sort recMsgs
    let sent = L.sort messages
    unless (sent == recv)
        $ left $ "received messages don't match send messages; sent: "
            <> sshow sent <> "; got: " <> sshow recv

-- | Checks that long polling is actually enabled. We add a delay to the messages
-- and immediately make a receive request with a polling wait time that is larger
-- than the delay. Note that even though polling forces consistent reads, messages
-- will become available with some (small) offset. Therefor we request only a single
-- message at a time.
--
prop_sendReceiveDeleteMessageLongPolling1
    :: Environment (SQS.SqsConfiguration NormalQuery)
    -> SQS.QueueName
    -> EitherT T.Text IO ()
prop_sendReceiveDeleteMessageLongPolling1 env queue = do

    let delay = Just 2
    let visTimeout = Just 60
    let poll = Just 5 -- consistent receive (maximum available number of requested messages is returned)
    let receiveBatch = 1
    let msgNum = 10 -- this must be a multiple of 'receiveBatch'

    let messages = map (\i -> "message" <> sshow i) [1 :: Int .. msgNum]

    recMsgs <- fmap concat . forM messages $ \msg -> do
        void . simpleSqsT env $ SQS.SendMessage msg queue [] delay
        msgs <- do
            r <- simpleSqsT env $ SQS.ReceiveMessage visTimeout [] (Just receiveBatch) [] queue poll
            case r of
                SQS.ReceiveMessageResponse [] -> left "no messages received"
                SQS.ReceiveMessageResponse t
                    | length t == receiveBatch -> right t
                    | otherwise -> left $ "unexpected number of messages received: " <> sshow (length t)
        forM_ msgs $ \m -> retryT 5 $
            simpleSqsT env $ SQS.DeleteMessage (SQS.mReceiptHandle m) queue
        return (map SQS.mBody msgs)

    let recv = L.sort recMsgs
    let sent = L.sort messages
    unless (sent == recv)
        $ left $ "received messages don't match send messages; sent: "
            <> sshow sent <> "; got: " <> sshow recv
