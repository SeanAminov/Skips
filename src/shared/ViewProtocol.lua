--!strict
--[[
	ViewProtocol — the lane view: the runs beside yours, drawn as ghosts, and spectating.

	The user (2026-09-10): "make sure I can see everyone in the server… it doesn't have to show all the
	players or all 8 people, maybe just like 2-4… when a player loses they're removed… in the final
	1v1 duel, can see them… spectate should be an arrow to go back and forth on names of players".

	PRESENTATION ONLY. A view is READ from a run -- tick, height, rope schedule, score -- and drawn;
	nothing here, on either side, changes a run. The server sends each player the views of the runs
	that belong beside theirs ten times a second, and the client draws them a fraction of a second in
	the past so the motion between samples is smooth.

	BOTS STAY UNDISCLOSED. In a match every participant is addressed by an opaque slot key and a rig
	name, humans and bots alike, and no field says "bot": the lane view must not become the thing that
	gives them away.
]]

local ViewProtocol = {}

ViewProtocol.REMOTE_NAME = "View"
-- ReplicatedStorage folder holding one appearance per match participant, humans and bots alike.
ViewProtocol.RIG_FOLDER = "SkipsRigs"

ViewProtocol.SERVER = table.freeze({
	VIEW = "VIEW",
})

-- Ten views a second, drawn this far behind the newest one so there is always a sample either side.
ViewProtocol.INTERVAL_SECONDS = 0.1
ViewProtocol.RENDER_DELAY_SECONDS = 0.18

-- How many other runs are drawn beside yours at once (so two to four lanes on screen), and how many
-- other solo players a solo run sees.
ViewProtocol.MAX_SHOWN = 3
ViewProtocol.SOLO_NEIGHBOURS = 3

-- The local runner draws every gameplay rope. Distant lanes are presentation only and show the
-- first four well-spaced phases; transmitting/rendering all eight for three neighbours would update
-- hundreds of extra segment and guard parts every frame without changing what anyone can play.
ViewProtocol.MAX_GHOST_ROPES = 4

-- Studs between lanes: a rope is about 7 studs wide, so neighbours never overlap.
ViewProtocol.LANE_SPACING = 9

-- A ghost the server has stopped sending for this long is gone.
ViewProtocol.STALE_SECONDS = 2

export type Entry = {
	key: string,      -- opaque and stable for this ghost; in a match it is a slot, never an account id
	rig: string?,     -- the appearance under ReplicatedStorage.SkipsRigs, when the server made one
	player: number?,  -- solo only: whose character to borrow the look of
	name: string,
	out: boolean,     -- finished in the match: taken out of the lineup
	tick: number,
	y: number,
	grounded: boolean,
	rising: boolean,
	alive: boolean,
	score: number,
	burning: number, -- first N transmitted ropes are on fire
	guarded: { boolean }, -- per rope: a Reinforce guard is on it
	period: number,
	ropes: { number }, -- up to MAX_GHOST_ROPES representative next-sweep ticks
}

function ViewProtocol.validate(): true
	assert(ViewProtocol.INTERVAL_SECONDS > 0, "views must be sent at some rate")
	assert(ViewProtocol.RENDER_DELAY_SECONDS > ViewProtocol.INTERVAL_SECONDS,
		"ghosts must be drawn far enough behind to have a sample on either side")
	assert(ViewProtocol.MAX_SHOWN >= 1 and ViewProtocol.MAX_SHOWN <= 3,
		"the user asked for two to four lanes on screen, counting your own")
	assert(ViewProtocol.MAX_GHOST_ROPES >= 1 and ViewProtocol.MAX_GHOST_ROPES <= 4,
		"distant rope rendering must remain bounded")
	assert(ViewProtocol.LANE_SPACING >= 8, "lanes closer than a rope's width would overlap")
	return true
end

ViewProtocol.validate()

return table.freeze(ViewProtocol)
