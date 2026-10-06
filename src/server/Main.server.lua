--!strict
--[[
	Server bootstrap.

	Order matters: `RunServer` owns runs and must exist before anything registers a listener on it,
	or a match formed in the first frame could miss the signal it resolves on.

	The wiring below is deliberately here rather than inside the services. `MatchService` should not
	have to know that leaderboards exist -- it exposes `onWin` and something else decides what a win
	is worth. That is what lets the leaderboard be absent, broken, or switched off without matches
	caring, which is not hypothetical: DataStores are unreachable until this place is linked.
]]

local RunServer = require(script.Parent:WaitForChild("RunServer"))
local MatchService = require(script.Parent:WaitForChild("MatchService"))
local LeaderboardService = require(script.Parent:WaitForChild("LeaderboardService"))
local DistractionService = require(script.Parent:WaitForChild("DistractionService"))
local RatingService = require(script.Parent:WaitForChild("RatingService"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))
local PurchaseService = require(script.Parent:WaitForChild("PurchaseService"))
local MatchAnalytics = require(script.Parent:WaitForChild("MatchAnalytics"))
local ViewService = require(script.Parent:WaitForChild("ViewService"))
local Leaderboards = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Leaderboards"))

RunServer.start()
MatchService.start()
LeaderboardService.start()
DistractionService.start()
RatingService.start()
PlayerDataService.start()
PurchaseService.start()
ViewService.start()

-- A win lands on the board for the mode it was won in -- a duel on DUO, a lobby on GROUP -- across
-- all its periods at once. `MatchService` has already decided whether this match was worth a win at
-- all (a duel padded with a bot is not) and has already excluded bots.
MatchService.onWin = function(player, mode, _score)
	LeaderboardService.addWin(player.UserId, Leaderboards.boardForMatchMode(mode))
end

--[[
	Ratings: MatchService must know them to pair ranked players and rate a result, but not where they
	live. Same seam as `onWin`, so ranked keeps working -- unrated, and saying so -- when the rating
	store is unreachable.
]]
MatchService.ratingOf = function(userId)
	local record = RatingService.recordOf(userId)
	return record.rating, record.games
end
MatchService.ratingsOnline = RatingService.isAvailable
MatchService.onRated = function(changes)
	RatingService.apply(changes)
end

--[[
	The SOLO board is best score in a solo run, so match runs are left out: a match score is part of a
	result that already has its own boards, earned on a different curve against a clock, and letting
	it in would put it on a board that says solo.

	From ENDED rather than FINISHED because a solo run auto-restarts and never reports finished.
	`submitScore` keeps the larger value, so submitting at every death -- including after a revive
	extends the same run -- is harmless by construction rather than by careful call-site ordering.
]]
RunServer.onRunEnded(function(player, _session)
	local summary = RunServer.summaryOf(player)
	if summary and summary.matchId == nil then
		LeaderboardService.submitScore(player.UserId, summary.score)
	end
end)

-- Tickets pay for revives through a seam, as ratings and wins do: the run server charges, and
-- PlayerDataService is where the tickets are.
RunServer.spendTickets = PlayerDataService.spendTickets
RunServer.refundTickets = PlayerDataService.refundTickets
-- A group splat is charged once before it appears; if nobody remains eligible, it is refunded.
DistractionService.spendTickets = PlayerDataService.spendTickets
DistractionService.refundTickets = PlayerDataService.refundTickets

-- When and why every matchmaking run ended, anonymously, for tuning the checkpoint curve.
MatchService.onResolved = function(summary)
	MatchAnalytics.record(summary)
end
