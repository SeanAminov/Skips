--!strict
--[[
	Leaderboards — which boards exist, what period each covers, and how a number is written down.

	PURE. No DataStores, no Roblox services, no clock of its own: every function takes the timestamp
	it should work from. That is what makes the awkward parts — period rollover and formatting a
	seven-digit score into a narrow row — testable without a published place, which matters because
	`DataStoreService` is unreachable until this experience is linked.

	THE BOARDS, AS THE USER ASKED FOR THEM (2026-09-10): solo, duo, group and ranked, each filterable
	by today, this week or all time — except ranked, which has no periods. A rating is a standing,
	not a tally: "your rating this week" would be a second number for the same thing, and the moment
	it disagreed with the rating on the ranked screen one of them would be lying.

	  SOLO    best score in a solo run    a personal best: keeps the larger value
	  DUO     duel wins                   a tally
	  GROUP   lobby wins                  a tally
	  RANKED  current Elo rating          a standing: the latest value, all time only

	PERIODS ARE PART OF THE STORE NAME, NOT A FIELD IN IT.
	A daily board is a different OrderedDataStore from yesterday's. This is why there is no reset
	job anywhere: the moment the UTC day rolls over, `keyFor` returns a new name, that store is
	empty, and yesterday's is still sitting there intact if it is ever wanted. The alternative —
	one store plus a scheduled wipe — needs a job that must never fail, and loses history when it
	does.

	UTC, ALWAYS. "Daily" has to mean the same window for every player or the board is a lie, and a
	server does not know where its players are. A day boundary that moves with the viewer would let
	the same score appear on two different days.

	RENAMED STORES, NOTHING LOST. The first version kept "wins" and "points" under LB_W_* and LB_P_*.
	Those names are retired. No value was ever written to them: DataStores have been unreachable for
	the whole life of the feature, because the place has never stayed linked.

	PUBLISHING MUST NEVER RENAME A STORE. These names are part of the save-data format, not an internal
	implementation detail. Publishing new scripts to the same Roblox experience keeps them. Changing
	a prefix would make an existing board look empty, so `validate` and suite section 15 pin the exact
	all-time names. A deliberate migration must read/merge old stores; it may never silently rename.
]]

local Leaderboards = {}

Leaderboards.PERIOD = table.freeze({
	DAILY = "DAILY",
	WEEKLY = "WEEKLY",
	ALL_TIME = "ALL_TIME",
})

Leaderboards.BOARD = table.freeze({
	SOLO = "SOLO",
	DUO = "DUO",
	GROUP = "GROUP",
	RANKED = "RANKED",
})

-- Order matters: this is the order the filters appear in.
Leaderboards.PERIODS = table.freeze({ "DAILY", "WEEKLY", "ALL_TIME" })
Leaderboards.BOARDS = table.freeze({ "SOLO", "DUO", "GROUP", "RANKED" })

local ALL_TIME_ONLY = table.freeze({ "ALL_TIME" })

type Definition = { prefix: string, label: string, valueLabel: string, periodic: boolean }
local DEFINITIONS: { [string]: Definition } = table.freeze({
	SOLO = table.freeze({ prefix = "S", label = "SOLO", valueLabel = "BEST SCORE", periodic = true }),
	DUO = table.freeze({ prefix = "D", label = "DUO", valueLabel = "WINS", periodic = true }),
	GROUP = table.freeze({ prefix = "G", label = "GROUP", valueLabel = "WINS", periodic = true }),
	RANKED = table.freeze({ prefix = "R", label = "RANKED", valueLabel = "RATING", periodic = false }),
})

Leaderboards.TOP_COUNT = 25

-- Its own remote. A board is neither a run nor a match, and putting it on either of those remotes
-- would mean a leaderboard refresh shared a path with packets that decide whether someone lives.
Leaderboards.REMOTE_NAME = "Leaderboard"
Leaderboards.CLIENT = table.freeze({ REQUEST = "REQUEST" })
Leaderboards.SERVER = table.freeze({ BOARD = "BOARD", UNAVAILABLE = "UNAVAILABLE" })

-- A board read hits a DataStore, so a client cannot be allowed to ask on every frame.
Leaderboards.REQUEST_COOLDOWN_SECONDS = 3
-- How long a fetched board is reused before it is worth asking again.
Leaderboards.CACHE_SECONDS = 30

--[[
	How far down your own rank is counted exactly.

	Each hundred places is one sorted-page request, and those come out of a per-server budget that
	every player on the server shares. Past this depth the row honestly says "500+" rather than
	spending the requests someone else's board needs. Your own value is always shown exactly.
]]
Leaderboards.RANK_PAGE_SIZE = 100
Leaderboards.RANK_SCAN_PAGES = 5
Leaderboards.ME_CACHE_SECONDS = 60

local SECONDS_PER_DAY = 86400

--[[
	The UTC day number, counting from the Unix epoch.

	Integer division rather than `os.date`, because `os.date` is locale- and platform-sensitive and
	this number ends up in a store name that must be identical on every server in the universe.
]]
function Leaderboards.dayNumber(unixTime: number): number
	return math.floor(unixTime / SECONDS_PER_DAY)
end

--[[
	The UTC week number, counting from the Unix epoch, with weeks starting on MONDAY.

	Day 0 is Thursday 1 January 1970, so the first Monday is day 4. The shift has to make day 4 the
	first day of a new week, which means `4 + shift` must be a multiple of 7 — so the shift is 3.

	Written out because the obvious answer is 4 and it is wrong: shifting by 4 puts the boundary on
	Sunday, and the weekly board would reset a day early forever. Caught by the suite, which checks
	that day 4 and day 3 land in different weeks rather than trusting the arithmetic.
]]
function Leaderboards.weekNumber(unixTime: number): number
	return math.floor((Leaderboards.dayNumber(unixTime) + 3) / 7)
end

-- The periods a board can be filtered by. Ranked has one: now.
function Leaderboards.periodsFor(board: string): { string }
	local definition = DEFINITIONS[board]
	assert(definition ~= nil, "unknown board " .. tostring(board))
	return if definition.periodic then Leaderboards.PERIODS else ALL_TIME_ONLY
end

-- Whether a board/period pair is one that exists. Everything a client sends is checked with this.
function Leaderboards.isValid(board: unknown, period: unknown): boolean
	if typeof(board) ~= "string" or typeof(period) ~= "string" then
		return false
	end
	local definition = DEFINITIONS[board]
	if not definition or Leaderboards.PERIOD[period] == nil then
		return false
	end
	return definition.periodic or period == Leaderboards.PERIOD.ALL_TIME
end

--[[
	The store name for one board in one period.

	Kept short deliberately: Roblox caps DataStore names at 50 characters, and a name that overflows
	fails at runtime on a live server rather than here.
]]
function Leaderboards.keyFor(board: string, period: string, unixTime: number): string
	assert(Leaderboards.isValid(board, period),
		string.format("board %s has no %s period", tostring(board), tostring(period)))
	local prefix = DEFINITIONS[board].prefix
	if period == Leaderboards.PERIOD.DAILY then
		return string.format("LB_%s_D%d", prefix, Leaderboards.dayNumber(unixTime))
	elseif period == Leaderboards.PERIOD.WEEKLY then
		return string.format("LB_%s_W%d", prefix, Leaderboards.weekNumber(unixTime))
	end
	return string.format("LB_%s_ALL", prefix)
end

--[[
	Which wins board a finished match counts toward. A duel is DUO and a lobby is GROUP, ranked or
	not: a ranked duel won is still a duel won. Ranked play is shown separately, on the rating board.
]]
function Leaderboards.boardForMatchMode(mode: string): string
	return if mode == "DUEL" then Leaderboards.BOARD.DUO else Leaderboards.BOARD.GROUP
end

-- ─── writing numbers down ────────────────────────────────────────────────────────────────────

--[[
	The exact number, with thousands separators. `1234567` becomes `1,234,567`.

	THIS IS THE DEFAULT on a leaderboard row, and deliberately so. The user's requirement was that
	you can tell what number it is; an abbreviation cannot do that, and a leaderboard row is wide
	enough to carry seven digits. `formatShort` exists for places that genuinely cannot.
]]
function Leaderboards.formatExact(value: number): string
	local negative = value < 0
	local digits = tostring(math.floor(math.abs(value)))
	local grouped = ""
	local count = 0
	for index = #digits, 1, -1 do
		grouped = digits:sub(index, index) .. grouped
		count += 1
		if count % 3 == 0 and index > 1 then
			grouped = "," .. grouped
		end
	end
	return if negative then "-" .. grouped else grouped
end

local SUFFIXES = table.freeze({
	{ 1e15, "Qa" },
	{ 1e12, "T" },
	{ 1e9, "B" },
	{ 1e6, "M" },
	{ 1e3, "K" },
})

--[[
	A short form for narrow space — the in-run HUD, a scoreboard row on a phone.

	THREE SIGNIFICANT FIGURES, ALWAYS. `1.23M`, `12.3M`, `123M`. That bounds the error at half a
	percent, so the reader knows the magnitude and very nearly the value. Plain `1M` for anything
	between one and two million would be the thing the user explicitly asked to avoid.

	Below a thousand it returns the exact number: abbreviating small values buys no space and only
	loses information.
]]
function Leaderboards.formatShort(value: number): string
	local negative = value < 0
	local magnitude = math.abs(value)
	if magnitude < 1000 then
		return tostring(math.floor(value))
	end

	for _, entry in SUFFIXES do
		local scale = entry[1] :: number
		local suffix = entry[2] :: string
		if magnitude >= scale then
			local scaled = magnitude / scale
			-- Three significant figures: 1.23 / 12.3 / 123.
			local text
			if scaled < 10 then
				text = string.format("%.2f", scaled)
			elseif scaled < 100 then
				text = string.format("%.1f", scaled)
			else
				text = string.format("%.0f", scaled)
			end
			-- Trailing zeros after a decimal point read as false precision.
			if text:find("%.") then
				text = text:gsub("0+$", ""):gsub("%.$", "")
			end
			return (if negative then "-" else "") .. text .. suffix
		end
	end
	return tostring(math.floor(value))
end

-- A place on a board: "#12", "#1,234", "500+" when the count stopped early, "—" when unknown.
function Leaderboards.formatRank(rank: number?, capped: boolean?): string
	if rank == nil then
		return "—"
	end
	if capped then
		return Leaderboards.formatExact(rank) .. "+"
	end
	return "#" .. Leaderboards.formatExact(rank)
end

-- The label a period shows on its filter.
function Leaderboards.periodLabel(period: string): string
	if period == Leaderboards.PERIOD.DAILY then
		return "TODAY"
	elseif period == Leaderboards.PERIOD.WEEKLY then
		return "THIS WEEK"
	end
	return "ALL TIME"
end

function Leaderboards.boardLabel(board: string): string
	return DEFINITIONS[board].label
end

-- What the number column means on this board.
function Leaderboards.valueLabel(board: string): string
	return DEFINITIONS[board].valueLabel
end

function Leaderboards.validate(): true
	assert(Leaderboards.TOP_COUNT > 0 and Leaderboards.TOP_COUNT <= 100,
		"TOP_COUNT must be a sane page size")

	for _, board in Leaderboards.BOARDS do
		assert(DEFINITIONS[board] ~= nil, "board " .. board .. " has no definition")
		assert(Leaderboards.BOARD[board] == board, "board " .. board .. " is not in BOARD")
	end
	assert(not DEFINITIONS.RANKED.periodic, "a rating is a standing, not a tally: no periods")

	-- Permanent persistence contract. Do not edit these strings to "version" a release: Roblox keeps
	-- the old OrderedDataStore under the old name, so the visible leaderboard would appear reset.
	assert(Leaderboards.keyFor("SOLO", "ALL_TIME", 0) == "LB_S_ALL", "SOLO store name changed")
	assert(Leaderboards.keyFor("DUO", "ALL_TIME", 0) == "LB_D_ALL", "DUO store name changed")
	assert(Leaderboards.keyFor("GROUP", "ALL_TIME", 0) == "LB_G_ALL", "GROUP store name changed")
	assert(Leaderboards.keyFor("RANKED", "ALL_TIME", 0) == "LB_R_ALL", "RANKED store name changed")

	-- Every store name must fit Roblox's 50-character cap, at a plausible far-future timestamp, and
	-- no two boards or periods may ever share one, or they would silently overwrite each other.
	local seen: { [string]: boolean } = {}
	for _, stamp in { 1789000000, 4102444800 } do
		for _, board in Leaderboards.BOARDS do
			for _, period in Leaderboards.periodsFor(board) do
				local key = Leaderboards.keyFor(board, period, stamp)
				assert(#key <= 50, string.format("store name %q is too long", key))
				local tag = key .. "@" .. stamp
				assert(not seen[tag], "two boards share the store name " .. key)
				seen[tag] = true
			end
		end
	end

	assert(Leaderboards.REQUEST_COOLDOWN_SECONDS > 0, "board requests must be rate limited")
	assert(Leaderboards.CACHE_SECONDS >= Leaderboards.REQUEST_COOLDOWN_SECONDS,
		"caching for less time than the cooldown would make the cooldown the real refresh rate")
	assert(Leaderboards.RANK_SCAN_PAGES >= 1 and Leaderboards.RANK_PAGE_SIZE >= 1,
		"a rank scan needs at least one page")

	assert(Leaderboards.formatExact(1234567) == "1,234,567", "exact formatting is wrong")
	assert(Leaderboards.formatShort(1234567) == "1.23M", "short formatting must keep three figures")
	assert(Leaderboards.formatRank(500, true) == "500+", "a capped rank must say it was capped")
	return true
end

Leaderboards.validate()

return table.freeze(Leaderboards)
