--!strict
--[[
	SimTuning — every number the run simulation reads, in one place.

	WHY THIS EXISTS SEPARATELY FROM RunSim:
	The upgrade cards all work by changing numbers. If those numbers lived
	inside the simulation, every card would be an edit to the simulation, and the design rules
	requires the opposite: adding a card must be a row in a table, never a change to the engine.
	So the sim reads a `Stats` block and never contains a literal of its own.

	THE TICK IS AN INTEGER AND TIME IS NEVER READ.
	Determinism rule: no `dt`, no `os.clock`, no `tick()`, no `DateTime` anywhere in the run
	path. The simulation advances exactly one TICK per step and derives everything from the tick
	count. `DT` below is a constant used to convert per-second tuning into per-tick motion — it is
	not a measured frame time and must never be replaced by one.

	ROPE TIMING IS COUNTED IN TICKS, NOT SECONDS.
	`ropePeriodTicks` is an integer, so a rope sweep lands exactly on a tick boundary on every
	machine. Storing the period as 2 seconds and multiplying would reintroduce float rounding
	into the one comparison that decides whether the player lives, which is precisely where
	determinism is worth the most.
]]

local SimTuning = {}

-- ─── Fixed timestep ──────────────────────────────────────────────────────────────────────────
-- 60 Hz: fine enough that a 16.7 ms input granularity is below human timing resolution, coarse
-- enough that the server can step every live run and replay whole runs cheaply. A ten-minute run
-- is 36,000 ticks.
SimTuning.TICK_RATE = 60
SimTuning.DT = 1 / 60

-- ─── The body ────────────────────────────────────────────────────────────────────────────────
-- Measured on a real spawned character on 2026-09-07. Every player's
-- avatar is normalised to this absolute height by the place's Avatar settings.
--
-- THE SIMULATION USES THIS NUMBER AND NEVER MEASURES A CHARACTER (§5.1). A shorter avatar must
-- never mean a smaller hitbox, or the leaderboard is unfair and avatar purchases become pay-to-win.
SimTuning.NOMINAL_HEIGHT = 5.5

-- ─── Start of run ────────────────────────────────────────────────────────────────────────────
-- The rope turns from tick 1, but sweeps neither score nor kill during the wind-up. Without this
-- the very first sweep would kill a player who had not yet looked at the screen.
-- 89 makes the 120-tick rope begin one quarter-turn behind the avatar and makes its FIRST visible
-- ground sweep score at tick 90. The old 209 value added a whole unjudged rotation: players made
-- the first jump correctly, saw the rope pass their feet, and reasonably read the missing point as
-- a bug. The 1.5-second approach is still a generous visual countdown without a fake sweep.
SimTuning.GRACE_TICKS = 89 -- 1.48 s; first visible/judged sweep is tick 90

-- ─── Base stats ──────────────────────────────────────────────────────────────────────────────
-- Cards mutate a copy of this. Nothing here is read directly by the sim; it reads the run's own
-- Stats block, so two runs on one server can hold different values without touching each other
-- (§6.5).
--
-- The jump arc these produce, for reference — verified by the Stage 0 test suite, not asserted
-- here by hand:
--   tap (no hold):   apex ~1.2 studs, airtime ~0.40 s
--   full hold:       apex ~4.0 studs, airtime ~0.87 s
-- Against a 120-tick (2.00 s) opening rope, a tap is the controlled one-loop answer. Height and
-- rocket upgrades are what eventually let a single jump span several rotations.
export type Stats = {
	gravity: number,            -- studs/s². Cartoon gravity, deliberately not Roblox's 196.2 —
	                            -- at 196.2 a readable airtime forces a 30-stud apex.
	jumpImpulse: number,        -- studs/s applied on press
	holdGravityScale: number,   -- gravity multiplier while rising and still held
	fallGravityScale: number,   -- gravity multiplier while falling; changes hang time, not apex
	maxHoldTicks: number,       -- integer; how long the hold can hold back gravity
	rocketFuelCapacity: number, -- integer simulation ticks of powered flight; zero means locked
	rocketThrust: number,       -- studs/s² added while fuel is burning
	ropePeriodTicks: number,    -- integer; ticks between sweeps of one rope
	ropeCount: number,          -- integer; ropes turn evenly out of phase with each other
	footClearance: number,      -- studs the feet must be above at the sweep instant to survive
	scorePerLoop: number,        -- x1 base, then +1 for each distinct burning rope
	ropeReinforcements: number, -- integer; Reinforce guards in total, each on one rope (RunSim.syncGuards)
	luck: number,               -- integer used by offer weights and deterministic clear procs
}

function SimTuning.baseStats(): Stats
	return {
		gravity = 60,
		jumpImpulse = 12,
		holdGravityScale = 0.28,
		fallGravityScale = 1,
		maxHoldTicks = 30, -- 0.5 s
		rocketFuelCapacity = 0,
		-- Raised from 66 on 2026-09-10 ("increase the jump height of boost"): a full tank held from
		-- the top of a jump now climbs to about 30 studs instead of 17. A short burn still arrests a fall.
		rocketThrust = 74,
		ropePeriodTicks = 120, -- 2.00 s; intentionally gentle before speed becomes an upgrade choice
		ropeCount = 1,
		footClearance = 0.35,
		scorePerLoop = 1,
		ropeReinforcements = 0,
		luck = 0,
	}
end

-- ─── Stat limits ─────────────────────────────────────────────────────────────────────────────
-- ONE ceiling and one floor per stat, for every card that will ever touch it.
--
-- These used to live on the individual card effects, and two cards that moved the same stat were
-- free to disagree. They did: Rocket Shoes capped `maxHoldTicks` at 90 while Super Rocket Shoes
-- capped it at 120, so a player who reached 120 on Supers and then took a Rocket Shoes had the
-- clamp pull them back down to 90 — a card that cost a choice and paid negative. The design rules
-- require every card to move an outcome the player can measure, and a per-effect bound cannot
-- be checked against a bound written in a different row.
--
-- Clamping against the stat instead of against the effect makes that class of bug unrepresentable:
-- there is only ever one number to disagree with. Fuel, jump and Luck remain unbounded. Fire and
-- reinforcement are bounded relationally to one per owned rope. Rope count and speed are finite
-- because they consume rendered parts/network entries and eventually cease to create distinct beats.
SimTuning.MAX_ROPES = 8
SimTuning.PERIOD_TICKS_MIN = 24 -- 0.40 s per turn; faster ceases to be a readable jump-rope beat

SimTuning.STAT_LIMITS = table.freeze({
	gravity = table.freeze({ minimum = 1 }),
	jumpImpulse = table.freeze({ minimum = 1 }),
	holdGravityScale = table.freeze({ minimum = 0.1, maximum = 0.99 }),
	fallGravityScale = table.freeze({ minimum = 0.1, maximum = 1 }),
	maxHoldTicks = table.freeze({ minimum = 1 }),
	rocketFuelCapacity = table.freeze({ minimum = 0 }),
	rocketThrust = table.freeze({ minimum = 1 }),
	ropePeriodTicks = table.freeze({ minimum = SimTuning.PERIOD_TICKS_MIN }),
	ropeCount = table.freeze({ minimum = 1, maximum = SimTuning.MAX_ROPES }),
	footClearance = table.freeze({ minimum = 0.05, maximum = 2 }),
	scorePerLoop = table.freeze({ minimum = 1 }),
	ropeReinforcements = table.freeze({ minimum = 0 }),
	luck = table.freeze({ minimum = 0 }),
})

-- ─── Difficulty ──────────────────────────────────────────────────────────────────────────────
-- The opening rhythm never accelerates on its own. Faster rope timing is a visible,
-- player-chosen upgrade in the reference, so only Jump Rope Speed may move this number.

-- Upgrade progress is earned only by clearing ropes; owning any burning rope raises a clear from
-- one step to two, and Lucky adds two more. Additional burning ropes increase the score multiplier
-- (x2, x3, ...) but do not compound progress. The target grows exponentially so each offer costs
-- more clears than the last,
-- the same curve for every player (no measured points-per-second; the formula just keeps late-run
-- cadence honest as if calibrated to a shared baseline rate):
--   required(round) = floor(BASE * GROWTH^round)
-- With BASE 5 and GROWTH 1.1: 5, 5, 6, 6, 7, 8, 8, 9, 10, 11, 12, ...
SimTuning.UPGRADE_PROGRESS_BASE = 5
SimTuning.UPGRADE_PROGRESS_GROWTH = 1.1

function SimTuning.upgradeProgressRequired(upgradeRound: number): number
	assert(upgradeRound >= 0 and upgradeRound == math.floor(upgradeRound),
		"upgradeRound must be a non-negative integer")
	return math.max(1, math.floor(
		SimTuning.UPGRADE_PROGRESS_BASE
			* (SimTuning.UPGRADE_PROGRESS_GROWTH ^ upgradeRound)
			+ 1e-9
	))
end

-- Each Luck stack adds a visible chance for a successful clear to become LUCKY. A lucky clear
-- doubles the whole award (including the points multiplier) and grants two extra steps of upgrade
-- progress. Keeping both effects in RunSim makes points, progression and the banner deterministic
-- on the predicting client and authoritative server.
SimTuning.LUCK_PROC_PERCENT_PER_STACK = 5
SimTuning.LUCKY_SCORE_MULTIPLIER = 2
SimTuning.LUCKY_UPGRADE_PROGRESS_BONUS = 2

-- A card choice or a reinforcement breaking grants the same short safety/readability window.
-- Three quarters of a second is long enough for the opacity pulse to read without removing a full
-- opening rope rotation from the game.
SimTuning.INVULNERABILITY_TICKS = math.floor(SimTuning.TICK_RATE * 0.75)

-- ─── Validation ──────────────────────────────────────────────────────────────────────────────
-- Runs at load. A malformed tuning table refuses to run rather than shipping a game whose numbers
-- quietly do not work.

local function isPositiveInteger(v: number): boolean
	return v == math.floor(v) and v > 0
end

function SimTuning.validateStats(s: Stats): true
	local function nonNegativeInteger(v: number): boolean
		return v == math.floor(v) and v >= 0
	end

	assert(s.gravity > 0, "gravity must be positive")
	assert(s.jumpImpulse > 0, "jumpImpulse must be positive")
	assert(s.holdGravityScale > 0 and s.holdGravityScale < 1,
		"holdGravityScale must be in (0,1) — at 1 the hold does nothing, at 0 the player never falls")
	assert(s.fallGravityScale > 0 and s.fallGravityScale <= 1,
		"fallGravityScale must be in (0,1]")
	assert(isPositiveInteger(s.maxHoldTicks), "maxHoldTicks must be a positive integer")
	assert(s.rocketFuelCapacity >= 0 and s.rocketFuelCapacity == math.floor(s.rocketFuelCapacity),
		"rocketFuelCapacity must be a non-negative integer")
	assert(s.rocketThrust > 0, "rocketThrust must be positive")
	assert(isPositiveInteger(s.ropePeriodTicks), "ropePeriodTicks must be a positive integer")
	assert(isPositiveInteger(s.ropeCount), "ropeCount must be a positive integer")
	assert(s.footClearance > 0, "footClearance must be positive")
	assert(s.footClearance < SimTuning.NOMINAL_HEIGHT,
		"footClearance above the body height would make every sweep lethal")
	assert(isPositiveInteger(s.scorePerLoop), "scorePerLoop must be a positive integer")
	assert(nonNegativeInteger(s.ropeReinforcements), "ropeReinforcements must be a non-negative integer")
	assert(s.scorePerLoop - 1 <= s.ropeCount,
		"each score multiplier step must belong to a distinct burning rope")
	assert(s.ropeReinforcements <= s.ropeCount,
		"each rope may carry at most one reinforcement")
	assert(nonNegativeInteger(s.luck), "luck must be a non-negative integer")

	-- The limits are the same table `RunSim.applyStatEffects` clamps against, so a stat can only
	-- arrive here out of range if something bypassed the card path entirely.
	local values = s :: any
	for stat, limit in SimTuning.STAT_LIMITS do
		local value = values[stat]
		assert(typeof(value) == "number",
			string.format("STAT_LIMITS names %q, which is not a stat", stat))
		assert(value >= limit.minimum,
			string.format("%s is %.4f, below its floor %.4f", stat, value, limit.minimum))
		assert(limit.maximum == nil or value <= limit.maximum,
			string.format("%s is %.4f, above its ceiling %.4f", stat, value, limit.maximum or 0))
	end
	return true
end

function SimTuning.validate(): true
	local s = SimTuning.baseStats()

	assert(isPositiveInteger(SimTuning.TICK_RATE), "TICK_RATE must be a positive integer")
	assert(SimTuning.DT == 1 / SimTuning.TICK_RATE, "DT must be exactly 1/TICK_RATE")
	assert(SimTuning.NOMINAL_HEIGHT > 0, "NOMINAL_HEIGHT must be positive")
	assert(SimTuning.GRACE_TICKS >= 0 and SimTuning.GRACE_TICKS == math.floor(SimTuning.GRACE_TICKS),
		"GRACE_TICKS must be a non-negative integer")

	SimTuning.validateStats(s)

	assert(isPositiveInteger(SimTuning.PERIOD_TICKS_MIN), "PERIOD_TICKS_MIN must be a positive integer")
	assert(SimTuning.PERIOD_TICKS_MIN < s.ropePeriodTicks,
		"PERIOD_TICKS_MIN must leave the difficulty ramp somewhere to go")
	assert(isPositiveInteger(SimTuning.MAX_ROPES) and SimTuning.MAX_ROPES <= SimTuning.PERIOD_TICKS_MIN,
		"every rope needs at least one distinct sweep phase at maximum speed")

	-- Every stat the base block declares must have a limit, or a card could move it with nothing
	-- to clamp against. Checked in this direction as well as the other so neither table can grow a
	-- row the other has never heard of.
	for stat in s :: any do
		assert(SimTuning.STAT_LIMITS[stat] ~= nil,
			string.format("stat %q has no entry in STAT_LIMITS", stat))
	end

	-- Even the shortest press must rise above the judged rope. Period length is irrelevant to this
	-- check: a timing game asks the player to place the arc around the sweep, not stay airborne for
	-- a whole revolution.
	local tapApex = s.jumpImpulse * s.jumpImpulse / (2 * s.gravity)
	assert(tapApex > s.footClearance,
		string.format("tap apex %.2f is below rope clearance %.2f", tapApex, s.footClearance))

	assert(isPositiveInteger(SimTuning.UPGRADE_PROGRESS_BASE),
		"UPGRADE_PROGRESS_BASE must be a positive integer")
	assert(SimTuning.UPGRADE_PROGRESS_GROWTH > 1,
		"UPGRADE_PROGRESS_GROWTH must be greater than one so later offers cost more clears")
	assert(SimTuning.upgradeProgressRequired(0) == SimTuning.UPGRADE_PROGRESS_BASE,
		"the opening upgrade target must equal UPGRADE_PROGRESS_BASE")
	-- A gentle exponential followed by floor() can intentionally repeat an early integer target
	-- (the 1.1 curve begins 5, 5, 6). It must never get cheaper, and the deeper check below proves
	-- that the curve still rises over time.
	assert(SimTuning.upgradeProgressRequired(1) >= SimTuning.upgradeProgressRequired(0),
		"the second upgrade target must not cost fewer clears than the first")
	assert(SimTuning.upgradeProgressRequired(10) > SimTuning.upgradeProgressRequired(5),
		"deep-run upgrade targets must keep rising")
	assert(isPositiveInteger(SimTuning.LUCK_PROC_PERCENT_PER_STACK),
		"LUCK_PROC_PERCENT_PER_STACK must be a positive integer")
	assert(SimTuning.LUCK_PROC_PERCENT_PER_STACK <= 100,
		"LUCK_PROC_PERCENT_PER_STACK cannot exceed 100 percent per stack")
	assert(isPositiveInteger(SimTuning.LUCKY_SCORE_MULTIPLIER)
		and SimTuning.LUCKY_SCORE_MULTIPLIER > 1,
		"LUCKY_SCORE_MULTIPLIER must be an integer greater than one")
	assert(isPositiveInteger(SimTuning.LUCKY_UPGRADE_PROGRESS_BONUS),
		"LUCKY_UPGRADE_PROGRESS_BONUS must be a positive integer")
	assert(SimTuning.LUCKY_UPGRADE_PROGRESS_BONUS < SimTuning.UPGRADE_PROGRESS_BASE,
		"one Lucky proc cannot fill an entire upgrade bar")
	assert(isPositiveInteger(SimTuning.INVULNERABILITY_TICKS),
		"INVULNERABILITY_TICKS must be a positive integer")
	assert(SimTuning.INVULNERABILITY_TICKS < s.ropePeriodTicks,
		"invulnerability must be shorter than the opening rope period")

	return true
end

SimTuning.validate()

return SimTuning
