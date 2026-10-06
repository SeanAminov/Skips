--!strict
--[[
	RatingService — every player's Elo rating: loaded when they join, changed when a ranked match
	resolves, saved, and mirrored onto the ranked leaderboard.

	THE RATING OF RECORD LIVES IN A PLAIN DATASTORE, one key per player: { rating, games, last }. The
	ranked leaderboard is only a sorted mirror of it (`LeaderboardService.setRating`), because an
	ordered store holds a single integer and a rating needs its games-played count beside it — that
	count is what decides the K-factor.

	IT MUST WORK WHEN DATASTORES DO NOT. With the place unlinked, everyone plays ranked from the
	starting rating and nothing is saved. That is said to the player ("OFFLINE, NOT SAVED"), never
	hidden: a rating that silently resets would be worse than one that openly is not being kept.

	CHANGES ARE SAVED AS DELTAS, NOT OVERWRITES. A match rates everyone from the ratings it captured
	when it formed, and `+delta` is applied inside `UpdateAsync`, so it stays right even if the stored
	value moved in the meantime — where writing the absolute number would quietly undo whatever
	happened in between. Each save carries a key for its match, and a key already applied is skipped,
	so retrying a save that did in fact land can never count one match twice.

	MATCHES DO NOT KNOW THIS MODULE EXISTS. The bootstrap hands `MatchService` three hooks (read a
	rating, are ratings being saved, apply a result) — the same seam `onWin` uses for leaderboards.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Elo = require(Shared:WaitForChild("Elo"))
local LeaderboardService = require(script.Parent:WaitForChild("LeaderboardService"))
local StoreAccess = require(script.Parent:WaitForChild("StoreAccess"))

local RatingService = {}

local FEATURE = "ratings"

-- Versioned, so a future change to what a record holds can move to a new store instead of having to
-- guess what shape every old key is in.
local STORE_NAME = "Ratings_v1"

export type Record = { rating: number, games: number }

local records: { [number]: Record } = {}
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

-- Whatever is stored, a record comes out whole and within the rules: integers, never below the floor.
local function sanitise(value: any): Record
	if typeof(value) == "table" and typeof(value.rating) == "number" and typeof(value.games) == "number" then
		return {
			rating = math.max(Elo.FLOOR, math.floor(value.rating)),
			games = math.max(0, math.floor(value.games)),
		}
	end
	return { rating = Elo.START, games = 0 }
end

function RatingService.recordOf(userId: number): Record
	return records[userId] or { rating = Elo.START, games = 0 }
end

-- Whether ratings are being saved. False for the whole session once DataStores are known to be out.
function RatingService.isAvailable(): boolean
	return not StoreAccess.offline()
end

local function load(player: Player)
	local userId = player.UserId
	records[userId] = records[userId] or { rating = Elo.START, games = 0 }
	local ratings = getStore()
	if not ratings then
		return
	end
	local ok, value = StoreAccess.try(FEATURE, function()
		return ratings:GetAsync(tostring(userId))
	end)
	if ok and player.Parent == Players then
		records[userId] = sanitise(value)
	end
end

--[[
	Applies one resolved ranked match. Memory changes at once, so the next queue already pairs on the
	new rating; then each change is saved as a delta and the leaderboard mirror refreshed. A player
	who left before the match resolved is still saved — everything here keys on userId.
]]
function RatingService.apply(changes: { Elo.Change })
	-- One key for the whole match, shared by every retry of every save below.
	local matchKey = HttpService:GenerateGUID(false)
	for _, change in changes do
		local userId = change.userId
		if userId > 0 then
			if Players:GetPlayerByUserId(userId) then
				local current = RatingService.recordOf(userId)
				records[userId] = { rating = change.after, games = current.games + 1 }
			end
			local delta = change.delta
			task.spawn(function()
				local ratings = getStore()
				if not ratings then
					return
				end
				local saved: number? = nil
				local ok = StoreAccess.write(FEATURE, function()
					ratings:UpdateAsync(tostring(userId), function(stored)
						local record = sanitise(stored)
						if typeof(stored) == "table" and stored.last == matchKey then
							-- Already in: a retry after a save that landed must not count it twice.
							saved = record.rating
							return nil
						end
						local nextRating = math.max(Elo.FLOOR, record.rating + delta)
						saved = nextRating
						return { rating = nextRating, games = record.games + 1, last = matchKey }
					end)
				end)
				if ok and saved then
					LeaderboardService.setRating(userId, saved)
				end
			end)
		end
	end
end

function RatingService.start()
	for _, player in Players:GetPlayers() do
		task.spawn(load, player)
	end
	Players.PlayerAdded:Connect(function(player)
		task.spawn(load, player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		records[player.UserId] = nil
	end)
end

return RatingService
