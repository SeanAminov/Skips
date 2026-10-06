--!strict
--[[
	MatchClient — the match remote, and the screens it drives.

	Kept out of `Main.client.lua` because that file owns the run: prediction, reconciliation, input.
	Match traffic is a different conversation on a different remote, and folding it in would put
	"who is winning" packets next to the tick-accurate input handling that decides whether the
	local player lives.

	NOTHING HERE IS AUTHORITY. Every placing arrives already ranked by `MatchRules` on the server.
	This file re-sorts nothing and decides nothing; the one thing it owns is which panel is on
	screen. Deleting the whole module must leave a playable solo game.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MatchProtocol = require(Shared:WaitForChild("MatchProtocol"))
local RunProtocol = require(Shared:WaitForChild("RunProtocol"))
local MatchPresenter = require(script.Parent:WaitForChild("MatchPresenter"))

local MatchClient = {}

local remoteFolder = ReplicatedStorage:WaitForChild(RunProtocol.REMOTE_FOLDER)
local matchRemote = remoteFolder:WaitForChild(MatchProtocol.REMOTE_NAME) :: RemoteEvent

local presenter = MatchPresenter.new()

-- The only local state: which match we believe we are in, and the server timestamps we render
-- countdowns and the search clock against. All of them are the server's numbers, never a local clock.
local currentMatchId: string? = nil
local rosterStartAt: number? = nil
local challengeExpiresAt: number? = nil
local queuedSince: number? = nil
-- When the next cut comes (a lobby), or the buzzer (a duel), as the server last said.
local cutAt: number? = nil
local cutoffAt: number? = nil

local function send(op: string, payload: any?)
	matchRemote:FireServer(op, payload)
end

presenter:setCallbacks(
	function(mode: string, kind: string)
		matchRemote:FireServer(MatchProtocol.CLIENT.QUEUE, mode, kind)
	end,
	function()
		send(MatchProtocol.CLIENT.LEAVE_QUEUE)
	end,
	function()
		presenter:hideChallenge()
		challengeExpiresAt = nil
		send(MatchProtocol.CLIENT.ACCEPT)
	end,
	function()
		presenter:hideChallenge()
		challengeExpiresAt = nil
		send(MatchProtocol.CLIENT.DECLINE)
	end,
	function()
		send(MatchProtocol.CLIENT.PLAY_SOLO)
	end
)

matchRemote.OnClientEvent:Connect(function(op, payload)
	local data = if typeof(payload) == "table" then payload :: any else {}

	if op == MatchProtocol.SERVER.QUEUED then
		if typeof(data.waiting) == "number" and typeof(data.target) == "number" then
			queuedSince = if typeof(data.since) == "number" then data.since else workspace:GetServerTimeNow()
			presenter:setQueued(tostring(data.mode), data.waiting, data.target,
				data.kind, data.rating, data.ratingsOnline)
		end

	elseif op == MatchProtocol.SERVER.QUEUE_LEFT then
		queuedSince = nil
		presenter:showQueue()

	elseif op == MatchProtocol.SERVER.CHALLENGED then
		if typeof(data.fromName) == "string" and typeof(data.expiresAt) == "number" then
			challengeExpiresAt = data.expiresAt
			presenter:showChallenge(data.fromName)
		end

	elseif op == MatchProtocol.SERVER.CHALLENGE_DECLINED then
		queuedSince = nil
		presenter:showQueue()
		presenter.queueStatus.Visible = true
		presenter.queueStatus.Text = string.format("%s DECLINED", tostring(data.byName))

	elseif op == MatchProtocol.SERVER.MATCH_FOUND then
		if typeof(data.matchId) ~= "string" or typeof(data.roster) ~= "table" then
			return
		end
		currentMatchId = data.matchId
		rosterStartAt = if typeof(data.startAt) == "number" then data.startAt else nil
		queuedSince = nil
		presenter:hideChallenge()
		presenter:hideResult()
		presenter:showRoster(tostring(data.mode), data.roster, data.ranked == true)

	elseif op == MatchProtocol.SERVER.MATCH_STARTED then
		if data.matchId ~= currentMatchId then
			return
		end
		rosterStartAt = nil
		presenter:hideRoster()

	elseif op == MatchProtocol.SERVER.SCORES then
		-- Accepted even when `matchId` has drifted: a stale table is a cosmetic wrong number for a
		-- quarter of a second, whereas dropping the live board mid-match is the feature missing.
		if typeof(data.table) == "table" then
			presenter:setScores(data.table)
		end
		cutAt = if typeof(data.cutAt) == "number" then data.cutAt else nil
		cutoffAt = if typeof(data.cutoffAt) == "number" then data.cutoffAt else nil

	elseif op == MatchProtocol.SERVER.CUT then
		if typeof(data.name) == "string" and typeof(data.minute) == "number" then
			presenter:showCut(data.name, data.minute, data.name == Players.LocalPlayer.Name)
		end

	elseif op == MatchProtocol.SERVER.FINAL_MINUTE then
		presenter:showFinalMinute()

	elseif op == MatchProtocol.SERVER.RESOLVED then
		if typeof(data.placings) ~= "table" then
			return
		end
		currentMatchId = nil
		rosterStartAt = nil
		cutAt = nil
		cutoffAt = nil
		presenter:hideRoster()
		presenter:hideScores()
		presenter:showResult(data.placings, data.ratings)
	end
end)

-- Countdowns are rendered against the server's timestamps every frame rather than counted down
-- locally, for the same reason the card deadline is: a local timer drifts from the number the
-- server actually acts on, and the moment they disagree the panel lies.
RunService.Heartbeat:Connect(function()
	local now = workspace:GetServerTimeNow()
	if rosterStartAt then
		presenter:setRosterCountdown(rosterStartAt - now, MatchProtocol.COUNTDOWN_SECONDS)
	end
	if queuedSince then
		presenter:setQueueElapsed(now - queuedSince)
	end
	if cutoffAt then
		presenter:setDuelTimer(cutoffAt - now)
	elseif cutAt then
		presenter:setCutCountdown(cutAt - now)
	end
	if challengeExpiresAt and now >= challengeExpiresAt then
		challengeExpiresAt = nil
		presenter:hideChallenge()
	end
end)

function MatchClient.presenter(): MatchPresenter.MatchPresenter
	return presenter
end

-- Solo players need a way in. Shown once at startup and again whenever a match ends; a player who
-- only ever wants to play alone can ignore it, and it never covers the rope during a run.
function MatchClient.showEntry()
	presenter:showQueue()
end

return MatchClient
