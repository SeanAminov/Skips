--!strict
--[[
	Distraction — the credit-bought splat that blinds an opponent for a few seconds.

	WHY A SPLAT AND NOT A JUMP SCARE. The user asked for a jump scare with a scream and, separately,
	for the game to stay open to every age. On Roblox those cannot both hold. The all-ages label,
	Minimal, has no fear category at all, and Roblox's own definition of Mild names "jump scares" and
	"shrieking or screaming" — so any jump scare, however cartoonish, closes the game to players aged
	5 to 8 (checked against the content-maturity documentation on 2026-09-10). What the user actually
	wants is mechanical: cover an opponent's screen long enough that they mistime a jump. A giant
	cartoon splat does that exactly as well and frightens nobody. The look and the sound are data
	below, so a later change of theme is an edit here rather than new code.

	THE VICTIM'S RUN IS NOT TOUCHED. A splatted player's simulation is unchanged: they simply cannot
	see it for a moment, and every input is judged exactly as before. That is what keeps a purchasable
	effect inside the simulation — nothing sold here edits anyone's run.

	A BOT MUST FEEL IT TOO. Bots are not disclosed in matches, so a player can spend credits splatting
	one without knowing. Taking money for an effect that silently does nothing when the target turns
	out to be a bot would be selling under false pretences. So a splatted bot plays the same window
	blind: its timing widens and its whiff rate climbs, the way a person guessing the rhythm by ear
	fares. It can still get lucky, exactly as a person can.

	BOUNDED, BECAUSE IT IS BOUGHT. One player may be splatted at most once per `IMMUNITY_SECONDS`.
	Without that, anyone with enough credits could keep an opponent blind for a whole match, which is
	not a distraction any more but a way to delete someone from it.
]]

local SimTuning = require(script.Parent.SimTuning)

local Distraction = {}

Distraction.REMOTE_NAME = "Distraction"
-- SPLAT goes to the victim. RESULT tells a buyer whether their splat landed, and why not if it did not.
Distraction.SERVER = table.freeze({ SPLAT = "SPLAT", RESULT = "RESULT" })
--[[
	BUY is the one operation a live server honours: one ticket splats every eligible opponent in the
	buyer's current match. The server owns the roster -- the client sends no target and cannot tell a
	bot from a person -- and charges before any effect appears (DistractionService). PREVIEW and
	TEST_APPLY are free test splats and are honoured ONLY in Studio: a free splat on a live server
	would be a button for griefing strangers.
]]
Distraction.CLIENT = table.freeze({ PREVIEW = "PREVIEW", TEST_APPLY = "TEST_APPLY", BUY = "BUY" })

-- Why a splat did not land, as the buyer's screen is told. Nothing is charged for any of them.
Distraction.REFUSED = table.freeze({
	NO_TARGET = "NO_TARGET",     -- not an opponent still in your running match
	OUT = "OUT",                 -- already out of the running
	CHOOSING = "CHOOSING",       -- behind a card choice right now
	IMMUNE = "IMMUNE",           -- splatted less than IMMUNITY_SECONDS ago
	NO_TICKETS = "NO_TICKETS",
	BUSY = "BUSY",               -- buyer cooldown or another ticket spend is still in flight
	UNAVAILABLE = "UNAVAILABLE",
})

-- The user asked for three to five seconds.
Distraction.MIN_SECONDS = 3
Distraction.MAX_SECONDS = 5
Distraction.DURATION_SECONDS = 4
Distraction.DURATION_TICKS = Distraction.DURATION_SECONDS * SimTuning.TICK_RATE
Distraction.FADE_SECONDS = 0.6

-- A remote-event flood must never become a datastore-write flood. Target immunity is a separate,
-- victim-facing rule; this bounds how often one buyer can ask the server to start a paid attempt.
Distraction.BUY_COOLDOWN_SECONDS = 1

-- At most one splat per player per fifteen seconds: blind no more than about a quarter of the time,
-- even against someone with unlimited credits.
Distraction.IMMUNITY_SECONDS = 15

-- Pro Sound Effects "Slide Whistle 4 (SFX)", 1.4 s, from Roblox's licensed library — the same licensed
-- source as the rope whoosh. Loud, comedic, and deliberately not a scream: screaming is Mild content.
Distraction.SOUND_ID = "rbxassetid://9119198140"
Distraction.SOUND_VOLUME = 1.5

-- Empty draws the built-in procedural splat, which needs no upload and no moderation wait. An
-- uploaded image id here is drawn on top instead, and must itself be all-ages art.
Distraction.IMAGE_ID = ""

-- The shake moves the splat; it never flashes it. Flashing is the photosensitivity risk, not motion.
Distraction.SHAKE_PIXELS = 18
Distraction.SHAKE_DEGREES = 5

-- How a blinded bot plays: timing jitter multiplied, and at least this many jumps in 100 missed.
Distraction.BOT_JITTER_MULTIPLIER = 4
Distraction.BOT_WHIFF_PERCENT = 55

function Distraction.validate(): true
	assert(Distraction.DURATION_SECONDS >= Distraction.MIN_SECONDS
		and Distraction.DURATION_SECONDS <= Distraction.MAX_SECONDS,
		"a splat lasts three to five seconds")
	assert(Distraction.DURATION_TICKS == math.floor(Distraction.DURATION_TICKS),
		"the bot's blind window must be a whole number of ticks")
	assert(Distraction.FADE_SECONDS > 0 and Distraction.FADE_SECONDS < Distraction.MIN_SECONDS,
		"the fade must fit inside the shortest splat")
	assert(Distraction.BUY_COOLDOWN_SECONDS > 0, "paid splat requests must be throttled")
	assert(Distraction.IMMUNITY_SECONDS >= Distraction.MAX_SECONDS * 3,
		"immunity must keep anyone from being held blind for most of a match")
	assert(Distraction.SOUND_ID ~= "", "a splat needs its sound")
	assert(Distraction.SOUND_VOLUME > 0 and Distraction.SOUND_VOLUME <= 10,
		"Sound.Volume only goes from 0 to 10")
	assert(Distraction.BOT_JITTER_MULTIPLIER >= 1, "blindness cannot make a bot more accurate")
	assert(Distraction.BOT_WHIFF_PERCENT > 0 and Distraction.BOT_WHIFF_PERCENT < 100,
		"a blinded bot must be able both to miss and to get lucky")
	return true
end

Distraction.validate()

return table.freeze(Distraction)
