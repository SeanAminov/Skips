--!strict
--[[
	StoreAccess — the one answer to "can DataStores be used here?", and the one way they are called.

	TWO KINDS OF FAILURE, needing opposite handling:
	  * NOT AVAILABLE AT ALL. The local file is unpublished (PlaceId 0), or Studio has not been given
	    API access. Nothing will succeed for the rest of the session, so the right move is to stop
	    asking: one warning, and every feature built on DataStores steps aside and says so.
	  * ONE BAD MOMENT on a live server: a throttled request, a brief Roblox outage. The next call
	    will very likely work. Switching a feature off for the rest of that server's life -- hours, on
	    a busy one -- over a single throttled request would silently lose every win and rating after
	    it. That is what the leaderboards did before this module existed.

	The first cannot happen on a live server and the second barely matters in Studio, so the rule goes
	by environment rather than by parsing error strings Roblox does not promise to keep stable: in
	Studio, or with PlaceId 0, the first failure means unavailable for the session; on a live server a
	failure is only ever the failure of that one call.
]]

local RunService = game:GetService("RunService")

local StoreAccess = {}

-- Attempts per write, waiting one second and then two between them.
StoreAccess.WRITE_ATTEMPTS = 3
-- A live outage must not flood the server log: each feature warns at most once a minute.
StoreAccess.WARN_INTERVAL_SECONDS = 60

local offline = game.PlaceId == 0
local warnedOffline = false
local lastWarnAt: { [string]: number } = {}

local function sessionOnly(): boolean
	return RunService:IsStudio() or game.PlaceId == 0
end

local function warnOffline(feature: string, reason: string)
	if warnedOffline then
		return
	end
	warnedOffline = true
	warn(string.format("[Skips] %s: DataStores are unavailable in this session: %s "
		.. "(expected while the place is unpublished, unlinked, or Studio lacks API access)",
		feature, reason))
end

-- True once DataStores are known to be unusable for the rest of this session.
function StoreAccess.offline(): boolean
	return offline
end

--[[
	One DataStore call, guarded. Returns whether it succeeded, then its result or the error text.
	Never throws, so nothing built on it can take a match down with it.
]]
function StoreAccess.try(feature: string, call: () -> any): (boolean, any)
	if offline then
		warnOffline(feature, "the place is not linked")
		return false, "DataStores are unavailable in this session"
	end
	local ok, result = pcall(call)
	if ok then
		return true, result
	end
	if sessionOnly() then
		offline = true
		warnOffline(feature, tostring(result))
	else
		local now = os.clock()
		local last = lastWarnAt[feature]
		if last == nil or now - last >= StoreAccess.WARN_INTERVAL_SECONDS then
			lastWarnAt[feature] = now
			warn(string.format("[Skips] %s: a DataStore call failed (%s); later calls will still try",
				feature, tostring(result)))
		end
	end
	return false, result
end

--[[
	A write that must survive one bad moment: tried up to WRITE_ATTEMPTS times, a second and then two
	apart. Yields, so call it from a spawned thread.

	Only for UpdateAsync transforms that are safe to run again. Keep-the-larger and store-the-latest
	are safe by nature. An increment is not quite: a call that fails AFTER committing -- rare, since
	most failures are refusals before anything is written -- would count twice when retried. Ratings
	carry a match key so a repeat is recognised and skipped; win tallies accept that small risk,
	because the alternative is losing a win to every throttled request.
]]
function StoreAccess.write(feature: string, call: () -> any): boolean
	for attempt = 1, StoreAccess.WRITE_ATTEMPTS do
		local ok = StoreAccess.try(feature, call)
		if ok then
			return true
		end
		if offline or attempt == StoreAccess.WRITE_ATTEMPTS then
			break
		end
		task.wait(2 ^ (attempt - 1))
	end
	return false
end

return StoreAccess
