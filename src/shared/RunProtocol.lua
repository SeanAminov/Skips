--!strict
--[[
	RunProtocol — the small, shared vocabulary around RunSim.

	This module contains transport limits and message names, never gameplay. Both peers still step
	RunSim itself; putting network timing here prevents a client/server constant from drifting while
	keeping real time outside the deterministic model.
]]

local RunProtocol = {}

RunProtocol.REMOTE_FOLDER = "SkipsRemotes"
RunProtocol.REMOTE_NAME = "Run"

RunProtocol.CLIENT = table.freeze({
	READY = "READY",
	START_ACK = "START_ACK",
	INPUT = "INPUT",
	PICK_CARD = "PICK_CARD",
	REQUEST_REVIVE = "REQUEST_REVIVE",
	DECLINE_REVIVE = "DECLINE_REVIVE",
	-- From the revive offer to the ticket shop: the revive counter pauses while the player buys.
	REVIVE_SHOPPING = "REVIVE_SHOPPING",
	-- That shop was closed without buying: the counter carries on from the second it paused on.
	REVIVE_SHOP_CLOSED = "REVIVE_SHOP_CLOSED",
	-- "I have my hands back, go now" after a revive. The server owns the resume tick either way;
	-- this only asks it to bring the deadline forward.
	RESUME_NOW = "RESUME_NOW",
	-- Solo only. A finished solo run waits for this rather than restarting on its own.
	PLAY_AGAIN = "PLAY_AGAIN",
	-- Solo only: stop on a tick, and ask to come back from it.
	PAUSE = "PAUSE",
	UNPAUSE = "UNPAUSE",
})

RunProtocol.SERVER = table.freeze({
	START = "START",
	GO = "GO",
	STATE = "STATE",
	OFFER = "OFFER",
	CARD_APPLIED = "CARD_APPLIED",
	CARD_REJECTED = "CARD_REJECTED",
	ENDED = "ENDED",
	-- The dead run's revive window moved (the player went shopping, or a ticket was being taken).
	-- While they shop it carries `paused` and the `remaining` seconds the counter stands still on.
	REVIVE_WINDOW = "REVIVE_WINDOW",
	-- A ticket revive did not go through: not enough tickets, or the store did not answer.
	REVIVE_REFUSED = "REVIVE_REFUSED",
	REVIVED = "REVIVED",
	-- The authoritative resume moment, re-sent when a tap pulls it in. Both peers must start
	-- stepping on the same tick or prediction diverges from its first frame.
	RESUME_AT = "RESUME_AT",
	-- A solo run is over, and nothing more happens until the player asks to play again.
	RUN_OVER = "RUN_OVER",
	-- The state a paused solo run resumes from, and the shared moment it resumes on.
	UNPAUSED = "UNPAUSED",
	-- How this player's connection looks from the server, so the HUD can say so.
	NET = "NET",
})

-- The server intentionally trails prediction so a normal input packet arrives before its tick is
-- judged. This changes authority latency, never local input feel.
RunProtocol.START_LEAD_SECONDS = 0.35
RunProtocol.AUTHORITY_DELAY_TICKS = 18 -- 300 ms at 60 Hz
RunProtocol.RESTART_DELAY_SECONDS = 0.15
RunProtocol.SNAPSHOT_INTERVAL_TICKS = 6
RunProtocol.MAX_STEPS_PER_FRAME = 12
RunProtocol.MAX_FUTURE_TICKS = 120
RunProtocol.MAX_PENDING_INPUTS = 128
RunProtocol.MAX_TRANSITIONS_PER_SECOND = 30

--[[
	PING. Authority trails prediction by at least AUTHORITY_DELAY_TICKS, and by more for a slower
	connection: every run start and every resume measures the player's ping and waits long enough for
	their presses to arrive before the tick they are stamped for is judged, up to
	MAX_AUTHORITY_DELAY_TICKS. So a laggy player is judged on the jump they made, not on when their
	packet happened to land -- and because every run is judged in its own ticks, waiting longer for
	one player gives them nothing over anyone else.
]]
RunProtocol.MAX_AUTHORITY_DELAY_TICKS = 45 -- 750 ms
RunProtocol.PING_MARGIN_SECONDS = 0.08
-- The two pings the HUD names. Past the first the delay is stretching to cover it; past the second
-- even the longest delay cannot, and a press can start landing a few ticks late.
RunProtocol.PING_WARN_SECONDS = 0.6
RunProtocol.PING_LIMIT_SECONDS = 1.3
RunProtocol.NET_REPORT_SECONDS = 5
-- A paused solo run comes back on a three-second get-ready, which a tap skips.
RunProtocol.PAUSE_RESUME_SECONDS = 3

function RunProtocol.validate(): true
	assert(RunProtocol.START_LEAD_SECONDS > 0, "START_LEAD_SECONDS must be positive")
	assert(RunProtocol.AUTHORITY_DELAY_TICKS > 0, "AUTHORITY_DELAY_TICKS must be positive")
	assert(RunProtocol.SNAPSHOT_INTERVAL_TICKS > 0, "SNAPSHOT_INTERVAL_TICKS must be positive")
	assert(RunProtocol.MAX_STEPS_PER_FRAME > 0, "MAX_STEPS_PER_FRAME must be positive")
	assert(RunProtocol.MAX_FUTURE_TICKS > RunProtocol.AUTHORITY_DELAY_TICKS,
		"MAX_FUTURE_TICKS must exceed the authority delay")
	assert(RunProtocol.MAX_PENDING_INPUTS >= RunProtocol.MAX_TRANSITIONS_PER_SECOND,
		"pending input bound must hold at least one legal second")
	assert(RunProtocol.MAX_AUTHORITY_DELAY_TICKS >= RunProtocol.AUTHORITY_DELAY_TICKS,
		"the ping-stretched delay can never be shorter than the base delay")
	assert(RunProtocol.MAX_FUTURE_TICKS > RunProtocol.MAX_AUTHORITY_DELAY_TICKS,
		"an input stamped a whole maximum delay ahead must still be accepted")
	assert(RunProtocol.PING_LIMIT_SECONDS > RunProtocol.PING_WARN_SECONDS, "the ping warnings must escalate")
	assert(RunProtocol.PAUSE_RESUME_SECONDS > 0, "a paused run needs a get-ready before it resumes")
	return true
end

RunProtocol.validate()

return table.freeze(RunProtocol)
