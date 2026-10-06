--!strict
--[[
	PlayerProtocol — the small vocabulary around a player's saved record: tickets, codes, settings,
	and first-time help.

	The server owns the record and publishes the parts a client may show as PLAYER ATTRIBUTES, which
	Roblox replicates to clients on its own. Nothing here is private -- a ticket count is no secret --
	and a client only ever READS them. What a client may SAY: that it finished the first-time hint, what
	it wants its settings to be, and a code it would like to redeem. The server decides what each of
	those is worth.
]]

local SimTuning = require(script.Parent.SimTuning)

local PlayerProtocol = {}

PlayerProtocol.REMOTE_NAME = "PlayerData"

PlayerProtocol.CLIENT = table.freeze({
	TUTORIAL_DONE = "TUTORIAL_DONE",
	REDEEM_CODE = "REDEEM_CODE",
	SET_SETTINGS = "SET_SETTINGS",
	-- Ask the server to verify community membership and pay the once-per-account social reward.
	CLAIM_GROUP = "CLAIM_GROUP",
	-- Studio only: hand yourself tickets, to test the shop and a ticket revive without buying.
	STUDIO_GRANT = "STUDIO_GRANT",
})

PlayerProtocol.SERVER = table.freeze({
	CODE_RESULT = "CODE_RESULT",
	GROUP_RESULT = "GROUP_RESULT",
})

PlayerProtocol.ATTRIBUTE = table.freeze({
	TICKETS = "SkipsTickets",
	TUTORIAL_DONE = "SkipsTutorialDone",
	-- True once the record has been read (or given up on), so a zero balance is not shown as final
	-- while it is still on its way.
	LOADED = "SkipsDataLoaded",
	-- False when nothing can be saved this session (Studio without DataStores), so the UI can say so.
	SAVED = "SkipsDataSaved",
	SOUND = "SkipsSound",
	LOW_GRAPHICS = "SkipsLowGraphics",
	-- "Hide other players" (the user, 2026-09-11): the camera frames only your own lane.
	HIDE_OTHERS = "SkipsHideOthers",
	-- True once the verified community reward has been claimed on this account.
	GROUP_CLAIMED = "SkipsGroupClaimed",
})

-- The PRESS • HOLD • RELEASE hint stays up for a new player's first ten seconds of actual jumping
-- (the user, 2026-09-10), then never again on that account.
PlayerProtocol.TUTORIAL_TICKS = 10 * SimTuning.TICK_RATE

PlayerProtocol.STUDIO_GRANT_TICKETS = 5

-- Sound is a direct 0–1 volume, shown as a slider. Values are stored to one-percent precision so a
-- drag cannot fill saved records with meaningless floating-point noise. Like every setting, it is
-- presentation only: gameplay must never branch on it.
PlayerProtocol.SOUND_MIN = 0
PlayerProtocol.SOUND_MAX = 1
PlayerProtocol.SOUND_STEPS = 100
PlayerProtocol.DEFAULT_SOUND = 1

function PlayerProtocol.normaliseSound(value: number): number
	return math.floor(math.clamp(value, PlayerProtocol.SOUND_MIN, PlayerProtocol.SOUND_MAX)
		* PlayerProtocol.SOUND_STEPS + 0.5) / PlayerProtocol.SOUND_STEPS
end

-- Codes are short, and guessing them is throttled per player.
PlayerProtocol.CODE_MAX_LENGTH = 24
PlayerProtocol.CODE_ATTEMPTS_PER_MINUTE = 6

function PlayerProtocol.validate(): true
	assert(PlayerProtocol.TUTORIAL_TICKS > 0 and PlayerProtocol.TUTORIAL_TICKS == math.floor(PlayerProtocol.TUTORIAL_TICKS),
		"the hint window must be a whole number of ticks")
	assert(PlayerProtocol.STUDIO_GRANT_TICKETS >= 1, "a Studio grant must grant something")
	assert(PlayerProtocol.SOUND_MIN == 0 and PlayerProtocol.SOUND_MAX == 1,
		"sound volume must use the standard zero-to-one range")
	assert(PlayerProtocol.SOUND_STEPS >= 20 and PlayerProtocol.SOUND_STEPS == math.floor(PlayerProtocol.SOUND_STEPS),
		"the sound slider needs enough whole steps to feel continuous")
	assert(PlayerProtocol.DEFAULT_SOUND >= PlayerProtocol.SOUND_MIN
		and PlayerProtocol.DEFAULT_SOUND <= PlayerProtocol.SOUND_MAX,
		"the default sound volume must be in range")
	assert(math.abs(PlayerProtocol.normaliseSound(0.376) - 0.38) < 1e-9,
		"sound volume must be saved to one-percent precision")
	assert(PlayerProtocol.CODE_ATTEMPTS_PER_MINUTE >= 1, "a player must be able to try at least one code")
	return true
end

PlayerProtocol.validate()

return table.freeze(PlayerProtocol)
