--!strict
--[[
	MatchAnalytics — when, and why, every matchmaking run ended.

	The user, 2026-09-10: "I want a way for us to collect other players' data when they play
	matchmaking, to see what times they end up dying at, either through the limiter or running into
	the jump rope." This is that, so the per-minute cut (which replaced the limiter on 2026-09-11) gets
	tuned on real players rather than bots.

	TWO SINKS, because they answer different questions:
	  * Roblox Analytics custom events, one per human run ("MatchRunEnded", value = seconds survived,
	    broken down by death reason, one-minute bucket and mode). Read straight off the Creator
	    Dashboard, no code needed.
	  * One `MatchLog_v1` DataStore key per match, prefixed by UTC date: every run in it, bots too and
	    flagged, for anything the dashboard cannot slice. `tests/MatchLogReport.lua` reads a day back
	    from a linked Studio session.

	NO ONE IS IDENTIFIED. The log holds no userIds and no names -- a run is its mode, whether it was a
	bot, its score, when and why it ended, and where it placed. That is everything tuning needs, and it
	keeps personal records out of a store nobody will ever be asked to erase them from. Studio test
	matches are marked, so they can be left out.
]]

local AnalyticsService = game:GetService("AnalyticsService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local StoreAccess = require(script.Parent:WaitForChild("StoreAccess"))

local MatchAnalytics = {}

local FEATURE = "match log"
local STORE_NAME = "MatchLog_v1"
local EVENT_NAME = "MatchRunEnded"

export type RunRecord = {
	bot: boolean,
	player: Player?,       -- only to address the analytics event; never written to the log
	score: number,
	seconds: number,       -- how long the run lasted, in its own simulated time
	reason: string,        -- ROPE, CUT, MATCH_OVER (still running when it was decided), or LEFT
	place: number,
}

export type MatchRecord = {
	mode: string,
	ranked: boolean,
	runs: { RunRecord },
}

local store: DataStore? = nil

local function getStore(): DataStore?
	if store then
		return store
	end
	local ok, result = StoreAccess.try(FEATURE, function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok and result then
		store = result
		return result
	end
	return nil
end

-- "2:00-3:00": the minute a run ended in, since the cut comes once a minute (2026-09-11).
function MatchAnalytics.bucketOf(seconds: number): string
	local start = math.max(0, math.floor(seconds / 60) * 60)
	local finish = start + 60
	return string.format("%d:%02d-%d:%02d", start // 60, start % 60, finish // 60, finish % 60)
end

function MatchAnalytics.record(match: MatchRecord)
	local modeLabel = match.mode .. (if match.ranked then " RANKED" else "")
	local humans, bots = 0, 0
	local runs = {}
	for _, run in match.runs do
		if run.bot then
			bots += 1
		else
			humans += 1
			local player = run.player
			if player and player.Parent == Players then
				pcall(function()
					AnalyticsService:LogCustomEvent(player, EVENT_NAME, run.seconds, {
						[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = run.reason,
						[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = MatchAnalytics.bucketOf(run.seconds),
						[Enum.AnalyticsCustomFieldKeys.CustomField03.Name] = modeLabel,
					})
				end)
			end
		end
		table.insert(runs, {
			bot = run.bot,
			score = run.score,
			seconds = math.floor(run.seconds * 10 + 0.5) / 10,
			reason = run.reason,
			place = run.place,
		})
	end

	task.spawn(function()
		local log = getStore()
		if not log then
			return
		end
		local key = os.date("!%Y%m%d") .. "/" .. HttpService:GenerateGUID(false)
		local entry = {
			v = 1,
			at = os.time(),
			studio = RunService:IsStudio(),
			mode = match.mode,
			ranked = match.ranked,
			humans = humans,
			bots = bots,
			runs = runs,
		}
		StoreAccess.write(FEATURE, function()
			log:SetAsync(key, entry)
		end)
	end)
end

return MatchAnalytics
