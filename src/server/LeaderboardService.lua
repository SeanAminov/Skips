--!strict
--[[
	LeaderboardService — writes to the boards, reads the top back, and finds where you stand.

	IT MUST WORK WHEN DATASTORES DO NOT. `PlaceId` is 0 whenever the local file is unlinked, and in
	that state `DataStoreService` errors on the first call. Every call here goes through
	`StoreAccess`, which tells the two kinds of failure apart: in an unlinked or API-less Studio
	session the boards step aside for good and say so; on a live server one failed call is only that
	call, and the next request tries again. A leaderboard that takes the match down with it would be a
	worse feature than no leaderboard.

	WHY ORDERED STORES. `GetSortedAsync` is the only way to ask "who are the top 25" without reading
	every player's key, and it is the entire reason boards are cheap. The cost is that values must be
	integers, which wins, scores and ratings already are.

	THREE KINDS OF WRITE, and getting them the wrong way round would quietly corrupt a board:
	  * wins ADD (`increment`)            — a tally only ever goes up by one
	  * solo scores KEEP THE LARGER VALUE — a personal best must never be lowered
	  * ratings STORE THE LATEST VALUE    — a rating can fall, so it is neither a sum nor a best
	All three go through `UpdateAsync`, never a blind overwrite: two servers can finish matches for
	the same player at the same moment, and read-then-write would lose one of them.

	PERIOD ROLLOVER IS FREE. `Leaderboards.keyFor` puts the day or week in the STORE NAME, so a new
	day is a new, empty store and yesterday's is untouched. Nothing here resets anything, and there
	is no scheduled job that has to never fail.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserService = game:GetService("UserService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Leaderboards = require(Shared:WaitForChild("Leaderboards"))
local RunProtocol = require(Shared:WaitForChild("RunProtocol"))
local StoreAccess = require(script.Parent:WaitForChild("StoreAccess"))

local LeaderboardService = {}

local FEATURE = "leaderboards"
local SHUTDOWN_DRAIN_SECONDS = 10
local pendingWrites = 0

-- Track background writes so an ordinary server shutdown gives them a bounded chance to finish.
-- The DataStore operation itself remains inside StoreAccess and keeps its retry/idempotency rules.
local function spawnWrite(work: () -> ())
	pendingWrites += 1
	task.spawn(function()
		local ok, why = pcall(work)
		if not ok then
			warn(string.format("[Skips] leaderboard background write failed: %s", tostring(why)))
		end
		pendingWrites -= 1
	end)
end

local function storeNamed(key: string): OrderedDataStore?
	local ok, store = StoreAccess.try(FEATURE, function()
		return DataStoreService:GetOrderedDataStore(key)
	end)
	if ok and store then
		return store
	end
	return nil
end

local function storeFor(board: string, period: string): OrderedDataStore?
	return storeNamed(Leaderboards.keyFor(board, period, os.time()))
end

-- Adds to a tally. This is the one place in the feature where a cross-server race is likely.
local function increment(board: string, period: string, userId: number, amount: number)
	local store = storeFor(board, period)
	if not store then
		return
	end
	StoreAccess.write(FEATURE, function()
		store:UpdateAsync(tostring(userId), function(current)
			return (current or 0) + amount
		end)
	end)
end

-- The best each player is known to hold on each store this session, so a solo run that is not a new
-- best costs no request at all. Kept per player and dropped when they leave.
local bestKnown: { [number]: { [string]: number } } = {}

--[[
	Keeps a personal best: never lowers a stored value, even if an out-of-order write arrives late.

	ONLY A NEW BEST IS WRITTEN (checked 2026-09-11 against what a live server can afford). A solo run
	ends every minute or so, and each end used to write all three periods whether or not it beat
	anything -- requests out of a budget the whole server shares. Now a score at or below the best this
	server already knows is not sent, and inside the write a stored value at least as high returns nil,
	which Roblox treats as "leave the key alone".
]]
local function recordBest(board: string, period: string, userId: number, value: number)
	local storeName = Leaderboards.keyFor(board, period, os.time())
	local mine = bestKnown[userId]
	if not mine then
		mine = {}
		bestKnown[userId] = mine
	end
	local known = mine[storeName]
	if known and value <= known then
		return
	end
	-- Use the exact same rollover key for the cache and the write. A server crossing midnight between
	-- two os.time() calls must not cache today's result under yesterday's store name (or vice versa).
	local store = storeNamed(storeName)
	if not store then
		return
	end
	local stored = value
	local ok = StoreAccess.write(FEATURE, function()
		store:UpdateAsync(tostring(userId), function(current)
			if typeof(current) == "number" and current >= value then
				stored = current
				return nil
			end
			stored = value
			return value
		end)
	end)
	if ok then
		mine[storeName] = stored
	end
end

--[[
	A win, on the board for the mode it was won in, across all its periods at once.

	Bots are rejected here rather than at the call site. Their ids are negative, and a negative id
	reaching a leaderboard is a bug worth catching close to the store instead of discovering as a
	nameless entry sitting at the top of the all-time board.
]]
function LeaderboardService.addWin(userId: number, board: string)
	if userId <= 0 then
		warn(string.format("[Skips] refused a leaderboard win for non-player id %d", userId))
		return
	end
	if board ~= Leaderboards.BOARD.DUO and board ~= Leaderboards.BOARD.GROUP then
		warn("[Skips] a win can only land on the duo or group board, not " .. tostring(board))
		return
	end
	spawnWrite(function()
		for _, period in Leaderboards.periodsFor(board) do
			increment(board, period, userId, 1)
		end
	end)
end

-- A solo score. Only solo runs are sent here; the bootstrap filters out match runs.
function LeaderboardService.submitScore(userId: number, score: number)
	if userId <= 0 or score <= 0 then
		return
	end
	spawnWrite(function()
		for _, period in Leaderboards.periodsFor(Leaderboards.BOARD.SOLO) do
			recordBest(Leaderboards.BOARD.SOLO, period, userId, math.floor(score))
		end
	end)
end

--[[
	A player's rating, as a standing: the latest value, which may be lower than the last one.

	The authoritative rating lives with the rating service; this is only the sorted mirror that makes
	a top 25 cheap. A player is in at most one match at a time, so the latest write is the right one.
]]
function LeaderboardService.setRating(userId: number, rating: number)
	if userId <= 0 then
		return
	end
	spawnWrite(function()
		local store = storeFor(Leaderboards.BOARD.RANKED, Leaderboards.PERIOD.ALL_TIME)
		if not store then
			return
		end
		local latest = math.max(0, math.floor(rating))
		StoreAccess.write(FEATURE, function()
			store:UpdateAsync(tostring(userId), function()
				return latest
			end)
		end)
	end)
end

export type Row = { rank: number, userId: number, name: string, value: number }

--[[
	Names are resolved from userIds through `GetNameFromUserIdAsync`, cached: the board holds ids,
	not names, so a player who changes their username is still themselves. An unresolvable id shows
	as its number rather than dropping the row — a gap in a leaderboard reads as a bug.
]]
local nameCache: { [number]: string } = {}

local function nameFor(userId: number): string
	local cached = nameCache[userId]
	if cached then
		return cached
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	local resolved = if ok and typeof(name) == "string" then name else tostring(userId)
	nameCache[userId] = resolved
	return resolved
end

-- Every name a board needs, in one request where possible: `GetUserInfosByUserIdsAsync` takes up to a
-- hundred ids at once, where `GetNameFromUserIdAsync` is one web call per row -- 25 in a row, the first
-- time a board is opened. Anything the batch misses falls back to `nameFor`.
local function resolveNames(userIds: { number })
	local missing: { number } = {}
	for _, userId in userIds do
		if not nameCache[userId] then
			table.insert(missing, userId)
		end
	end
	if #missing == 0 then
		return
	end
	local ok, infos = pcall(function()
		return UserService:GetUserInfosByUserIdsAsync(missing)
	end)
	if ok and typeof(infos) == "table" then
		for _, info in infos :: any do
			if typeof(info) == "table" and typeof(info.Id) == "number" and typeof(info.Username) == "string" then
				nameCache[info.Id] = info.Username
			end
		end
	end
end

-- The first page of a board, or nil when it could not be read just now. Nil and empty are kept
-- apart on purpose: empty means "nobody has played", nil means "ask again".
function LeaderboardService.top(board: string, period: string): { Row }?
	local store = storeFor(board, period)
	if not store then
		return nil
	end
	local ok, pages = StoreAccess.try(FEATURE, function()
		return store:GetSortedAsync(false, Leaderboards.TOP_COUNT)
	end)
	if not ok or not pages then
		return nil
	end

	local rows: { Row } = {}
	local okPage, page = pcall(function()
		return (pages :: DataStorePages):GetCurrentPage()
	end)
	if not okPage or typeof(page) ~= "table" then
		return nil
	end
	local ids: { number } = {}
	for _, entry in page :: any do
		local userId = tonumber((entry :: any).key) or 0
		if userId > 0 then
			table.insert(ids, userId)
		end
	end
	resolveNames(ids)
	for index, entry in page :: any do
		local userId = tonumber((entry :: any).key) or 0
		if userId > 0 then
			table.insert(rows, {
				rank = index,
				userId = userId,
				name = nameFor(userId),
				value = (entry :: any).value or 0,
			})
		end
	end
	return rows
end

export type Standing = { value: number?, rank: number?, capped: boolean }

--[[
	Where one player stands on one board, for the "your place" row pinned under the list.

	Finding a rank must never mean reading the whole board. So this reads the player's own value,
	then counts only the entries strictly ABOVE it — the sorted store can filter to values of at least
	`value + 1` — a page of a hundred at a time, stopping after `RANK_SCAN_PAGES`. Past that the rank
	is reported as capped ("500+"). Before each further page it checks the server's request budget and
	gives up rather than spending requests other players' boards need. Ties share a rank.

	Returns nil when the player's own value could not be read, so a failed read is never mistaken
	for "not on this board yet" and cached as if it were true.
]]
function LeaderboardService.rankOf(board: string, period: string, userId: number): Standing?
	local store = storeFor(board, period)
	if not store then
		return nil
	end
	local okValue, stored = StoreAccess.try(FEATURE, function()
		return store:GetAsync(tostring(userId))
	end)
	if not okValue then
		return nil
	end
	if typeof(stored) ~= "number" then
		return { value = nil, rank = nil, capped = false }
	end
	local value = stored :: number

	local ok, found = StoreAccess.try(FEATURE, function()
		return store:GetSortedAsync(false, Leaderboards.RANK_PAGE_SIZE, value + 1, nil)
	end)
	if not ok or not found then
		return { value = value, rank = nil, capped = false }
	end
	local pages = found :: DataStorePages
	local above = 0
	for pageIndex = 1, Leaderboards.RANK_SCAN_PAGES do
		local okPage, page = pcall(function()
			return pages:GetCurrentPage()
		end)
		if not okPage or typeof(page) ~= "table" then
			return { value = value, rank = nil, capped = false }
		end
		above += #(page :: any)
		if pages.IsFinished then
			return { value = value, rank = above + 1, capped = false }
		end
		if pageIndex == Leaderboards.RANK_SCAN_PAGES then
			break
		end
		if DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.GetSortedAsync) < 2 then
			return { value = value, rank = nil, capped = false }
		end
		local advanced = StoreAccess.try(FEATURE, function()
			pages:AdvanceToNextPageAsync()
		end)
		if not advanced then
			return { value = value, rank = nil, capped = false }
		end
	end
	return {
		value = value,
		rank = Leaderboards.RANK_PAGE_SIZE * Leaderboards.RANK_SCAN_PAGES,
		capped = true,
	}
end

function LeaderboardService.isAvailable(): boolean
	return not StoreAccess.offline()
end

--[[
	Serving boards to clients.

	Cached per board and period, a player's own standing cached per player, and every player rate
	limited. A board read is a DataStore call with a request budget attached, and without all three a
	client holding down a refresh button would burn the whole universe's quota.
]]
local cache: { [string]: { at: number, rows: { Row } } } = {}
local standingCache: { [string]: { at: number, standing: Standing } } = {}
local lastRequestAt: { [Player]: number } = {}

function LeaderboardService.start()
	local remoteFolder = ReplicatedStorage:FindFirstChild(RunProtocol.REMOTE_FOLDER)
	if not remoteFolder then
		remoteFolder = Instance.new("Folder")
		remoteFolder.Name = RunProtocol.REMOTE_FOLDER
		remoteFolder.Parent = ReplicatedStorage
	end
	local remote = (remoteFolder :: Folder):FindFirstChild(Leaderboards.REMOTE_NAME)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = Leaderboards.REMOTE_NAME
		remote.Parent = remoteFolder
	end
	assert(remote:IsA("RemoteEvent"), "LeaderboardService: Leaderboard remote must be a RemoteEvent")
	local boardRemote = remote :: RemoteEvent

	boardRemote.OnServerEvent:Connect(function(player, op, board, period)
		if op ~= Leaderboards.CLIENT.REQUEST then
			return
		end
		if not Leaderboards.isValid(board, period) then
			return
		end
		local boardName, periodName = board :: string, period :: string
		local now = os.clock()
		local last = lastRequestAt[player]
		if last and (now - last) < Leaderboards.REQUEST_COOLDOWN_SECONDS then
			return
		end
		lastRequestAt[player] = now

		if StoreAccess.offline() then
			boardRemote:FireClient(player, Leaderboards.SERVER.UNAVAILABLE, {})
			return
		end

		task.spawn(function()
			local cacheKey = boardName .. ":" .. periodName
			local hit = cache[cacheKey]
			local rows: { Row }
			if hit and (os.clock() - hit.at) < Leaderboards.CACHE_SECONDS then
				rows = hit.rows
			else
				local fresh = LeaderboardService.top(boardName, periodName)
				if not fresh then
					-- Could not be read just now. Said plainly rather than shown as an empty board,
					-- which would read as "nobody has played"; the next request tries again.
					if player.Parent == Players then
						boardRemote:FireClient(player, Leaderboards.SERVER.UNAVAILABLE, {})
					end
					return
				end
				rows = fresh
				cache[cacheKey] = { at = os.clock(), rows = rows }
			end

			-- Already on the first page? Then the rank is right there and costs nothing to find.
			local standing: Standing? = nil
			for _, row in rows do
				if row.userId == player.UserId then
					standing = { value = row.value, rank = row.rank, capped = false }
					break
				end
			end
			if not standing then
				local mineKey = cacheKey .. ":" .. player.UserId
				local mine = standingCache[mineKey]
				if mine and (os.clock() - mine.at) < Leaderboards.ME_CACHE_SECONDS then
					standing = mine.standing
				else
					standing = LeaderboardService.rankOf(boardName, periodName, player.UserId)
					-- A failed read is not cached: it would pin "not on this board" for a minute.
					if standing then
						standingCache[mineKey] = { at = os.clock(), standing = standing }
					end
				end
			end

			if player.Parent == Players then
				boardRemote:FireClient(player, Leaderboards.SERVER.BOARD, {
					board = boardName,
					period = periodName,
					rows = rows,
					me = standing,
				})
			end
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastRequestAt[player] = nil
		bestKnown[player.UserId] = nil
	end)

	game:BindToClose(function()
		local deadline = os.clock() + SHUTDOWN_DRAIN_SECONDS
		while pendingWrites > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return LeaderboardService
