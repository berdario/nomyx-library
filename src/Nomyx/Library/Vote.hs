{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

-- | Voting system
module Nomyx.Library.Vote where

import           Control.Applicative
import           Control.Arrow
import           Control.Monad.State       hiding (forM_)
import           Control.Shortcut
import           Data.List
import qualified Data.Map                  as M
import           Data.Maybe
import           Data.Time                 hiding (getCurrentTime)
import           Data.Typeable
import           Nomyx.Language
import           Prelude                   hiding (foldr)

-- | a vote assessing function (such as unanimity, majority...)
type AssessFunction = VoteStats -> Maybe Bool

-- | the vote statistics, including the number of votes per choice,
-- the number of persons called to vote, and if the vote is finished (timeout or everybody voted)
data VoteStats = VoteStats { voteCounts     :: M.Map Bool Int,
                             nbParticipants :: Int,
                             voteFinished   :: Bool}
                             deriving (Show, Typeable)

-- | information broadcasted when a vote begins
data VoteBegin = VoteBegin { vbRule        :: RuleInfo,
                             vbEndAt       :: UTCTime,
                             vbEventNumber :: EventNumber,
                             vbPlayers     :: [PlayerNumber]}
                             deriving (Show, Eq, Ord, Typeable)

-- | information broadcasted when a vote ends
data VoteEnd = VoteEnd { veRule       :: RuleInfo,
                         veVotes      :: [(PlayerNumber, Maybe Bool)],
                         vePassed     :: Bool,
                         veFinishedAt :: UTCTime}
                         deriving (Show, Eq, Ord, Typeable)

voteBegin :: Msg VoteBegin
voteBegin = Signal "VoteBegin"

voteEnd :: Msg VoteEnd
voteEnd = Signal "VoteEnd"

-- | vote at unanimity every incoming rule
unanimityVote :: Nomex ()
unanimityVote = do
   onRuleProposed $ callVoteRule unanimity oneDay
   displayVotes

-- | call a vote on a rule for every players, with an assessing function and a delay
callVoteRule :: AssessFunction -> NominalDiffTime -> RuleInfo -> Nomex ()
callVoteRule assess delay ri = do
   endTime <- addUTCTime delay <$> getCurrentTime
   callVoteRule' assess endTime ri

callVoteRule' :: AssessFunction -> UTCTime -> RuleInfo -> Nomex ()
callVoteRule' assess endTime ri = do
   en <- callVote assess endTime (_rName $ _rRuleTemplate ri) (_rNumber ri) (finishVote assess ri)
   pns <- getAllPlayerNumbers
   sendMessage voteBegin (VoteBegin ri endTime en pns)

-- | actions to do when the vote is finished
finishVote :: AssessFunction -> RuleInfo -> [(PlayerNumber, Maybe Bool)] -> Nomex ()
finishVote assess ri vs = do
   let passed = fromJust $ assess $ getVoteStats (map snd vs) True
   activateOrRejectRule ri passed
   end <- getCurrentTime
   sendMessage voteEnd (VoteEnd ri vs passed end)

-- | call a vote for every players, with an assessing function, a delay and a function to run on the result
callVote :: AssessFunction -> UTCTime -> String -> RuleNumber -> ([(PlayerNumber, Maybe Bool)] -> Nomex ()) -> Nomex EventNumber
callVote assess endTime name rn payload = do
   onEventOnce (voteWith endTime assess name rn) payload

-- | vote with a function able to assess the ongoing votes.
-- | the vote can be concluded as soon as the result is known.
voteWith :: UTCTime -> AssessFunction -> String -> RuleNumber-> Event [(PlayerNumber, Maybe Bool)]
voteWith timeLimit assess name rn = do
   pns <- liftEvent getAllPlayerNumbers
   let voteEvents = map (singleVote name rn) pns
   let timerEvent = timeEvent timeLimit
   let isFinished votes timer = isJust $ assess $ getVoteStats votes timer
   (vs, _)<- shortcut2b voteEvents timerEvent isFinished
   return $ zip pns vs

-- | display the votes (ongoing and finished)
displayVotes :: Nomex ()
displayVotes = do
   void $ onMessage voteEnd displayFinishedVote
   void $ onMessage voteBegin displayOnGoingVote

-- trigger the display of a radio button choice on the player screen, yelding either True or False.
-- after the time limit, the value sent back is Nothing.
singleVote ::  String -> RuleNumber -> PlayerNumber -> Event Bool
singleVote name rn pn = inputRadio pn title [(True, "For"), (False, "Against")] where
   title = "Vote for rule: \"" ++ name ++ "\" (#" ++ (show rn) ++ "):"

-- | assess the vote results according to a unanimity
unanimity :: AssessFunction
unanimity voteStats = voteQuota (nbVoters voteStats) voteStats

-- | assess the vote results according to an absolute majority (half voters plus one)
majority :: AssessFunction
majority voteStats = voteQuota ((nbVoters voteStats) `div` 2 + 1) voteStats

-- | assess the vote results according to a majority of x (in %)
majorityWith :: Int -> AssessFunction
majorityWith x voteStats = voteQuota ((nbVoters voteStats) * x `div` 100 + 1) voteStats

-- | assess the vote results according to a fixed number of positive votes
numberVotes :: Int -> AssessFunction
numberVotes x voteStats = voteQuota x voteStats

-- | adds a quorum to an assessing function
withQuorum :: AssessFunction -> Int -> AssessFunction
withQuorum f minNbVotes = \voteStats -> if (voted voteStats) >= minNbVotes
                                        then f voteStats
                                        else if voteFinished voteStats then Just False else Nothing

getVoteStats :: [Maybe Bool] -> Bool -> VoteStats
getVoteStats votes finished = VoteStats
   {voteCounts   = M.fromList $ counts (catMaybes votes),
    nbParticipants = length votes,
    voteFinished = finished}

counts :: (Eq a, Ord a) => [a] -> [(a, Int)]
counts as = map (head &&& length) (group $ sort as)

-- | Compute a result based on a quota of positive votes.
-- the result can be positive if the quota if reached, negative if the quota cannot be reached anymore at that point, or still pending.
voteQuota :: Int -> VoteStats -> Maybe Bool
voteQuota q voteStats
   | M.findWithDefault 0 True  vs >= q                       = Just True
   | M.findWithDefault 0 False vs > (nbVoters voteStats) - q = Just False
   | otherwise = Nothing
   where vs = voteCounts voteStats


-- | number of people that voted if the voting is finished,
-- total number of people that should vote otherwise
nbVoters :: VoteStats -> Int
nbVoters vs
   | voteFinished vs = voted vs
   | otherwise = nbParticipants vs

voted, notVoted :: VoteStats -> Int
notVoted    vs = (nbParticipants vs) - (voted vs)
voted       vs = M.findWithDefault 0 True (voteCounts vs) + M.findWithDefault 0 False (voteCounts vs)

-- | display an on going vote
displayOnGoingVote :: VoteBegin -> Nomex ()
displayOnGoingVote (VoteBegin (RuleInfo rn _ _ _ _ _ (RuleTemplate name _ _ _ _ _ _)) endTime en pns) = void $ outputAll $ do
   isa <- isEventActive en
   if isa
     then do
        ers <- mapM (\pn -> getEventResult en (singleVote name rn pn)) pns
        showOnGoingVote (zip pns ers) rn endTime
     else return ""

showOnGoingVote :: [(PlayerNumber, Maybe Bool)] -> RuleNumber -> UTCTime -> Nomex String
showOnGoingVote [] rn _ = return $ "Nobody voted yet for rule #" ++ (show rn) ++ "."
showOnGoingVote listVotes rn endTime = do
   list <- mapM showVote listVotes
   let timeString = formatTime defaultTimeLocale "on %d/%m at %H:%M UTC" endTime
   return $ "Votes for rule #" ++ (show rn) ++ ", finishing " ++ timeString ++ "\n" ++
            concatMap (\(name, vote) -> name ++ "\t" ++ vote ++ "\n") list

-- | display a finished vote
displayFinishedVote :: VoteEnd -> Nomex ()
displayFinishedVote (VoteEnd ri vs passed end) = void $ outputAll $ showFinishedVote (_rNumber ri) passed vs end

showFinishedVote :: RuleNumber -> Bool -> [(PlayerNumber, Maybe Bool)] -> UTCTime -> Nomex String
showFinishedVote rn passed l _ = do
   let title = "Vote finished for rule #" ++ (show rn) ++ ", passed: " ++ (show passed)
   let voted = filter (\(_, r) -> isJust r) l
   votes <- mapM showVote voted
   return $ title ++ " (" ++ (intercalate ", " $ map (\(name, vote) -> name ++ ": " ++ vote) votes) ++ ")"

showVote :: (PlayerNumber, Maybe Bool) -> Nomex (String, String)
showVote (pn, v) = do
   name <- showPlayer pn
   return (name, showChoice v)

showChoice :: Maybe Bool -> String
showChoice (Just a) = show a
showChoice Nothing  = "Not voted"
