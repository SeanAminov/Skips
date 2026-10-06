--!strict
--[[
	MatchProtocol — the vocabulary for duels and lobbies.

	Deliberately a SEPARATE remote from `RunProtocol`. A run is one player's simulation and knows
	nothing about anyone else; a match is a grouping over runs. Folding match traffic into the run
	remote would put "who is winning" packets on the same path as the tick-accurate input packets
	that decide whether someone lives, and the run has no business growing an opinion about that.

	Nothing here is gameplay. A match chooses the seed, and every participant plays exactly the same
	simulation they would play alone; the only thing a match adds is the cut, once a minute, of the
	lowest runner still in (`MatchRules.cutCandidate`). That is the whole reason
	the social layer is cheap: the design rules required the run to be a value with the seed
	as an input, four stages before anyone needed a second player.
]]

local MatchProtocol = {}

MatchProtocol.REMOTE_NAME = "Match"

MatchProtocol.CLIENT = table.freeze({
	QUEUE = "QUEUE",               -- join a matchmaking queue (payload: mode, kind)
	LEAVE_QUEUE = "LEAVE_QUEUE",
	CHALLENGE = "CHALLENGE",       -- invite one named player to a duel
	ACCEPT = "ACCEPT",             -- accept a pending challenge
	DECLINE = "DECLINE",
	LEAVE_MATCH = "LEAVE_MATCH",   -- forfeit; the score already earned still stands
	-- After a match resolves the player's run is over and nothing restarts it, because a match run
	-- deliberately does not auto-restart. This is how they ask for a fresh solo run back.
	PLAY_SOLO = "PLAY_SOLO",
})

MatchProtocol.SERVER = table.freeze({
	QUEUED = "QUEUED",             -- you are in a queue, and how many are waiting
	QUEUE_LEFT = "QUEUE_LEFT",
	CHALLENGED = "CHALLENGED",     -- someone has invited you
	CHALLENGE_SENT = "CHALLENGE_SENT",
	CHALLENGE_DECLINED = "CHALLENGE_DECLINED",
	MATCH_FOUND = "MATCH_FOUND",   -- roster is set; the loading beat before play
	MATCH_STARTED = "MATCH_STARTED",
	SCORES = "SCORES",             -- the live table, sent on a timer while playing, with the next cut
	CUT = "CUT",                   -- the lowest runner still in was cut: who, and at which minute
	FINAL_MINUTE = "FINAL_MINUTE", -- a duel reached 4:00: one minute left, most points at the buzzer wins
	RESOLVED = "RESOLVED",         -- final placings
})

MatchProtocol.MODE = table.freeze({
	DUEL = "DUEL",
	LOBBY = "LOBBY",
})

MatchProtocol.STATE = table.freeze({
	FORMING = "FORMING",
	RUNNING = "RUNNING",
	RESOLVED = "RESOLVED",
})

MatchProtocol.DUEL_SIZE = 2

--[[
	Lobbies fill to eight, but never wait forever for them.

	The user asked for "8+", and on a busy server that is what a lobby is. On a quiet one, holding
	four people hostage until four more appear is how a mode dies before anyone plays it. So: start
	immediately at the target, and otherwise start with whoever is queued once the fill window
	closes, provided there are at least two.
]]
MatchProtocol.LOBBY_TARGET = 8
MatchProtocol.LOBBY_MIN = 2

-- After this long in a queue, the remaining slots are filled with bots and the match starts.
-- Ten seconds is short on purpose: a player who queued and got nothing is a player who does not
-- queue again, and an imperfect opponent now beats a perfect one that never arrives.
MatchProtocol.BOT_FILL_SECONDS = 10

--[[
	CASUAL OR RANKED. Casual is everything above: quick, unrated, filled out after ten seconds.
	Ranked is rated with chess Elo (`Elo`) and is humans only -- nothing may ever fill a ranked
	queue -- so the user accepted that it can take a while.

	Pairing: the rating window starts at +/-100, widens by 10 a second, and opens completely at
	sixty seconds, so a quiet server still produces a ranked match rather than none. A ranked lobby
	starts at eight, or with whoever compatible is queued once the longest wait reaches thirty
	seconds.
]]
MatchProtocol.KIND = table.freeze({
	CASUAL = "CASUAL",
	RANKED = "RANKED",
})
MatchProtocol.RANKED_WINDOW_START = 100
MatchProtocol.RANKED_WINDOW_GROWTH_PER_SECOND = 10
MatchProtocol.RANKED_WINDOW_OPEN_SECONDS = 60
MatchProtocol.RANKED_LOBBY_WAIT_SECONDS = 30

-- The loading beat between "you have opponents" and "go". Long enough to read the roster, short
-- enough that nobody alt-tabs. The run's own GO handshake still owns the exact start tick.
MatchProtocol.COUNTDOWN_SECONDS = 4

-- The live table is presentation, not authority, so it is sent on a wall clock rather than per
-- tick. Four times a second reads as live without putting a packet on every simulation step.
MatchProtocol.SCORE_INTERVAL_SECONDS = 0.25

-- A challenge that nobody answers must not sit in the invited player's UI forever.
MatchProtocol.CHALLENGE_TIMEOUT_SECONDS = 30
-- Bounds remote spam and repeated invite popups from one sender without making a normal retry slow.
MatchProtocol.CHALLENGE_COOLDOWN_SECONDS = 3

function MatchProtocol.validate(): true
	assert(MatchProtocol.DUEL_SIZE == 2, "a duel is two players")
	assert(MatchProtocol.LOBBY_MIN >= 2, "a lobby needs someone to race")
	assert(MatchProtocol.LOBBY_TARGET >= MatchProtocol.LOBBY_MIN,
		"the lobby target cannot be below its minimum")
	assert(MatchProtocol.BOT_FILL_SECONDS > 0, "BOT_FILL_SECONDS must be positive")
	assert(MatchProtocol.COUNTDOWN_SECONDS > 0, "COUNTDOWN_SECONDS must be positive")
	assert(MatchProtocol.SCORE_INTERVAL_SECONDS > 0, "SCORE_INTERVAL_SECONDS must be positive")
	assert(MatchProtocol.CHALLENGE_TIMEOUT_SECONDS > MatchProtocol.COUNTDOWN_SECONDS,
		"a challenge must outlive the countdown it leads into")
	assert(MatchProtocol.CHALLENGE_COOLDOWN_SECONDS > 0,
		"outgoing challenge requests must be throttled")
	assert(MatchProtocol.BOT_FILL_SECONDS < MatchProtocol.CHALLENGE_TIMEOUT_SECONDS,
		"bots must fill a queue before a pending challenge would even expire")
	assert(MatchProtocol.RANKED_WINDOW_START > 0 and MatchProtocol.RANKED_WINDOW_GROWTH_PER_SECOND > 0,
		"the ranked window must start open and keep widening")
	assert(MatchProtocol.RANKED_WINDOW_OPEN_SECONDS > 0, "a ranked search must open up eventually")
	assert(MatchProtocol.RANKED_LOBBY_WAIT_SECONDS > 0, "a ranked lobby must eventually start")
	return true
end

MatchProtocol.validate()

return table.freeze(MatchProtocol)
