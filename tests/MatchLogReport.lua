--[[
	MatchLogReport — read a day of matchmaking runs back and summarise when and why they ended.

	Paste into the command bar (or an Edit-mode execute_luau) in a Studio session LINKED to the
	published place with Studio API access on; DataStores do not exist anywhere else. Set DAY to the
	UTC date to read (YYYYMMDD). Studio test matches are counted separately and left out of the table.

	Reads at most MAX_MATCHES keys, one GetAsync each, so a busy day does not spend the whole budget.
]]

local DAY = os.date("!%Y%m%d")
local MAX_MATCHES = 300

local store = game:GetService("DataStoreService"):GetDataStore("MatchLog_v1")
local pages = store:ListKeysAsync(DAY .. "/", 100)

-- counts[group][bucket] = runs; group is e.g. "human ROPE" or "bot CHECKPOINT"
local counts: { [string]: { [number]: number } } = {}
local studioMatches, liveMatches = 0, 0
local seen = 0

local function add(group: string, seconds: number)
	local bucket = math.floor(seconds / 30)
	counts[group] = counts[group] or {}
	counts[group][bucket] = (counts[group][bucket] or 0) + 1
end

while seen < MAX_MATCHES do
	for _, keyInfo in pages:GetCurrentPage() do
		if seen >= MAX_MATCHES then
			break
		end
		seen += 1
		local ok, entry = pcall(function()
			return store:GetAsync(keyInfo.KeyName)
		end)
		if ok and typeof(entry) == "table" then
			if entry.studio then
				studioMatches += 1
			else
				liveMatches += 1
				for _, run in entry.runs or {} do
					add(string.format("%s %s", if run.bot then "bot" else "human", tostring(run.reason)),
						tonumber(run.seconds) or 0)
				end
			end
		end
	end
	if pages.IsFinished then
		break
	end
	pages:AdvanceToNextPageAsync()
end

local lines = { string.format("%s: %d live matches (%d Studio test matches ignored)", DAY, liveMatches, studioMatches) }
for group, buckets in counts do
	local parts = {}
	for bucket = 0, 20 do
		local n = buckets[bucket]
		if n then
			table.insert(parts, string.format("%d:%02d=%d", (bucket * 30) // 60, (bucket * 30) % 60, n))
		end
	end
	table.insert(lines, string.format("  %-18s %s", group, table.concat(parts, "  ")))
end
local report = table.concat(lines, "\n")
print(report)
return report
