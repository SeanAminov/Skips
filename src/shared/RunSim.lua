--!strict
--[[
	RunSim — the rules of a run. THE one module that decides what happens.

	THIS MODULE MUST STAY DETERMINISTIC. READ ALL OF THIS BEFORE CHANGING ANYTHING HERE.

	This module is stepped by the client for responsiveness and by the server for authority, and
	there is deliberately no second implementation of any rule in it. That is not a style
	preference: it is the only reason a client can predict a jump without the server having to
	trust it. The client runs ahead, the server runs the same code over the same inputs, and any
	divergence is a bug or a cheat rather than something to be reconciled away.

	FOUR THINGS THIS MODULE MUST NEVER DO, each of which would break that guarantee:

	  1. Read time. No `dt`, no `os.clock`, no `tick()`, no `DateTime`. One `step()` is one tick.
	  2. Touch Roblox. No Instances, no `Touched`, no `Humanoid`, no `workspace.Gravity`. The rope,
	     the arc and the collision between them are arithmetic. Roblox physics is frame-rate
	     sensitive and network-owned, and either property alone makes a score untrustworthy.
	  3. Measure a character. The body is `SimTuning.NOMINAL_HEIGHT`, identical for everyone,
	     because avatars are not (§5.1).
	  4. Know that it is the only run. No `LocalPlayer`, no singletons, no module-level state. A
	     run is a value; a server holds many and steps them all (§6.5). Two players handed the same
	     seed are playing the same course, which is how versus arrives later for almost nothing.

	THE MODEL, in one paragraph. A rope turns; every `ropePeriodTicks` it sweeps the ground. Press
	launches a jump, holding holds back gravity while still rising, releasing lets it take over. At
	the instant of a sweep the feet are either clear of the rope — a loop, worth score — or
	they are not, and the run ends. Everything else is bookkeeping.

	WHY SWEEPS ARE SCHEDULED RATHER THAN COMPUTED FROM A MODULO. Each rope carries its own
	`nextSweepTick` and adds the current period when it fires. A modulo of the tick would have been
	shorter, but a rope-speed card can shrink the period, and a modulo would move sweeps that were
	already pending — occasionally firing one instantly the moment the card was taken.
]]

local SimTuning = require(script.Parent.SimTuning)
local MatchTuning = require(script.Parent.MatchTuning)
local Rng = require(script.Parent.Rng)

type Stats = SimTuning.Stats
type Rng = Rng.Rng

local RunSim = {}
RunSim.__index = RunSim

-- ─── Events ──────────────────────────────────────────────────────────────────────────────────
-- The vocabulary the presentation layer listens to. Deleting every listener must leave the run
-- mechanically identical (§6.4), so nothing here may carry a decision — only a report of one.
RunSim.EVENT = table.freeze({
	JUMP = "JUMP",
	LAND = "LAND",
	LOOP = "LOOP",
	UPGRADE_READY = "UPGRADE_READY",
	ROPE_REINFORCED = "ROPE_REINFORCED",
	CHECKPOINT_PASSED = "CHECKPOINT_PASSED",
	DEATH = "DEATH",
})

-- Why a run ended. The presentation says different things for each, and a match needs to
-- distinguish "caught by the rope" from "did not keep pace" when it reports placings.
RunSim.DEATH_REASON = table.freeze({
	ROPE = "ROPE",
	CHECKPOINT = "CHECKPOINT",
	-- Ended from outside by `retire`: the lowest runner still in at a minute mark, or a match that was
	-- decided while this runner was still going.
	CUT = "CUT",
	MATCH_OVER = "MATCH_OVER",
})

export type Event = {
	kind: string,
	tick: number,
	-- LOOP
	ropeIndex: number?,
	score: number?,
	points: number?,
	lucky: boolean?,
	-- UPGRADE_READY
	upgradeRound: number?,
	-- DEATH
	reason: string?,
	-- CHECKPOINT_PASSED / DEATH by checkpoint
	checkpointIndex: number?,
	requiredScore: number?,
	-- JUMP / LAND
	height: number?,
}

type Rope = {
	nextSweepTick: number,
	-- Reinforce guard on THIS rope. Zero or one; it absorbs one otherwise lethal strike by this rope.
	guards: number,
}

export type Run = typeof(setmetatable(
	{} :: {
		seed: number,
		stats: Stats,
		rng: Rng,
		ropes: { Rope },

		tick: number,
		alive: boolean,

		y: number,        -- feet height above the ground, in studs
		vy: number,       -- studs per second
		grounded: boolean,
		holding: boolean,
		holdTicksLeft: number,
		wasDown: boolean,
		rocketFuel: number,
		rocketActive: boolean,
		invulnerableTicks: number,

		loops: number,
		score: number,
		upgradeRound: number,
		upgradeProgress: number,
		checkpointSet: number,
		checkpointIndex: number,

		digest: number,
	},
	{} :: { __index: typeof(RunSim) }
))

export type Snapshot = {
	seed: number,
	stats: Stats,
	rngState: number,
	ropes: { Rope },
	tick: number,
	alive: boolean,
	y: number,
	vy: number,
	grounded: boolean,
	holding: boolean,
	holdTicksLeft: number,
	wasDown: boolean,
	rocketFuel: number,
	rocketActive: boolean,
	invulnerableTicks: number,
	loops: number,
	score: number,
	upgradeRound: number,
	upgradeProgress: number,
	checkpointSet: number,
	checkpointIndex: number,
	digest: number,
}

export type StatEffect = {
	stat: string,
	operation: string,
	value: number,
}

local UINT32 = 4294967296

local function copyStats(source: Stats): Stats
	return {
		gravity = source.gravity,
		jumpImpulse = source.jumpImpulse,
		holdGravityScale = source.holdGravityScale,
		fallGravityScale = source.fallGravityScale,
		maxHoldTicks = source.maxHoldTicks,
		rocketFuelCapacity = source.rocketFuelCapacity,
		rocketThrust = source.rocketThrust,
		ropePeriodTicks = source.ropePeriodTicks,
		ropeCount = source.ropeCount,
		footClearance = source.footClearance,
		scorePerLoop = source.scorePerLoop,
		ropeReinforcements = source.ropeReinforcements,
		luck = source.luck,
	}
end

--[[
	A rolling hash of every tick's state.

	This is what "same seed plus same inputs reproduces the run" is actually tested against — the
	alternative is storing 36,000 states per run and comparing them, which is the same assertion
	at a thousand times the cost. Positions are quantised to 1/4096 of a stud before hashing:
	floats are bit-identical across peers today, and quantising means a future change that
	introduces a rounding difference below a quarter-millimetre does not spuriously fail a replay.
]]
local function hashStep(h: number, value: number): number
	local v = math.floor(value) % UINT32
	return (h * 33 + v) % UINT32
end

local function quantise(v: number): number
	return math.floor(v * 4096)
end

--[[
	Picks the sweep tick for one new rope: the middle of the widest gap in the schedule that is
	already turning.

	With one rope in the air every gap is the whole turn, so the newcomer lands exactly half a
	period from it — the opposite side of the arc, which is the only reading of "a second rope"
	that gives the player a new beat instead of a thicker version of the beat they already have.
	Beyond two it keeps subdividing whichever gap is largest, so each addition still lands as far
	from its neighbours as the schedule allows.

	MEASURED FROM `self.tick`, NOT FROM THE EARLIEST PENDING SWEEP. Phase is what matters, and a
	rope that has only just swept has a pending tick a full period away; anchoring to that would
	put the newcomer a period and a half out and the card would look like it did nothing for three
	seconds. Anchoring to now places it in the gap the player is actually standing in.

	The floor is half a period. Nothing else in the run can conjure a sweep out of nothing — a
	speed card shortens future intervals but never moves a pending tick — so this is the one place
	a rope can appear with less warning than the player has been trained to expect. Advancing by
	whole periods until it clears the floor keeps the phase, so the rope stays opposite.
]]
local function scheduleNewRope(self: Run): number
	local period = self.stats.ropePeriodTicks
	if #self.ropes == 0 then
		return self.tick + period
	end

	local phases: { number } = {}
	for _, rope in self.ropes do
		table.insert(phases, (rope.nextSweepTick - self.tick) % period)
	end
	table.sort(phases)

	-- The wrap-around gap, from the last sweep of this turn to the first of the next.
	local bestGap = phases[1] + period - phases[#phases]
	local bestStart = phases[#phases]
	for i = 1, #phases - 1 do
		local gap = phases[i + 1] - phases[i]
		if gap > bestGap then
			bestGap = gap
			bestStart = phases[i]
		end
	end

	local sweep = self.tick + bestStart + math.floor(bestGap / 2)
	local earliest = self.tick + math.floor(period / 2)
	while sweep < earliest do
		sweep += period
	end
	return sweep
end

--[[
	Rebuilds the rope schedule to match `stats.ropeCount`.

	Existing ropes keep their pending sweep. A pending sweep is a promise the player is already
	steering around, and rescheduling one to make the spacing prettier would kill someone mid-jump;
	only genuinely new ropes are scheduled, one at a time so each sees the ones before it.
]]
--[[
	Places every Reinforce guard on a rope. REINFORCE JUMP ROPE GUARDS ONE ROPE PER CARD (the user,
	2026-09-11: "it's only for one of the jumpropes"). `stats.ropeReinforcements` is the total; a new
	guard goes to the first unguarded rope, so no rope can ever hold two at once. A strike by a guarded
	rope spends that rope's guard; a strike by an unguarded rope still kills. Deterministic, so both
	peers agree.
]]
local function syncGuards(self: Run)
	local total = 0
	for _, rope in self.ropes do
		total += rope.guards
	end
	local want = self.stats.ropeReinforcements
	while total < want and #self.ropes > 0 do
		local pick: Rope? = nil
		for _, rope in self.ropes do
			if rope.guards == 0 then
				pick = rope
				break
			end
		end
		assert(pick ~= nil, "ropeReinforcements exceeds the number of unguarded ropes")
		local selected = pick :: Rope
		selected.guards = 1
		total += 1
	end
	while total > want do
		local pick = self.ropes[1]
		for _, rope in self.ropes do
			if rope.guards >= pick.guards then
				pick = rope
			end
		end
		pick.guards -= 1
		total -= 1
	end
end

local function syncRopes(self: Run)
	local want = self.stats.ropeCount
	local have = #self.ropes
	if want < have then
		for i = have, want + 1, -1 do
			self.ropes[i] = nil
		end
	else
		for _ = have + 1, want do
			self.ropes[#self.ropes + 1] = { nextSweepTick = scheduleNewRope(self), guards = 0 }
		end
	end
	syncGuards(self)
end

-- A dead run coming back to life starts over from the floor: feet down, motion zero, every rope a
-- full period away. This is only reachable from `revive`, where the player has already been struck
-- and there is no arc left to preserve — charging for a revive and then dropping the player into
-- the sweep that just killed them would be indefensible.
local function resetForSafeResume(self: Run)
	self.y = 0
	self.vy = 0
	self.grounded = true
	self.holding = false
	self.holdTicksLeft = 0
	self.wasDown = false
	self.rocketFuel = self.stats.rocketFuelCapacity
	self.rocketActive = false
	-- Checkout must not return the player into a lethal frame. The full-period rope reset is the
	-- warning; this short visible grace also covers input/display latency as control comes back.
	self.invulnerableTicks = SimTuning.INVULNERABILITY_TICKS
	for index, rope in self.ropes do
		rope.nextSweepTick = self.tick + self.stats.ropePeriodTicks
			+ math.floor((index - 1) * self.stats.ropePeriodTicks / #self.ropes)
	end
end

--[[
	`seed` is supplied by the server (§6.3). It is an argument rather than something this module
	generates, because a shared seed is what turns two solo runs into the same course.

	`statsOverride` exists for tests and for cards. It is shallow-copied over the base block so a
	caller can never hand the run a table it also holds a reference to — a run that shares its
	stats with anything else is a run whose numbers can change under it mid-flight.
]]
function RunSim.new(
	seed: number,
	statsOverride: { [string]: number }?,
	checkpointSet: number?
): Run
	local stats = SimTuning.baseStats()
	if statsOverride then
		local writable = stats :: any
		for k, v in statsOverride do
			-- A typo'd stat name would otherwise be accepted and silently do nothing, which is the
			-- worst possible outcome for a card: it would look installed and change no number.
			assert(writable[k] ~= nil, string.format("RunSim.new: unknown stat %q", k))
			writable[k] = v
		end
	end
	SimTuning.validateStats(stats)

	local self = setmetatable({
		seed = seed,
		stats = stats,
		rng = Rng.new(seed),
		ropes = {},

		tick = 0,
		alive = true,

		y = 0,
		vy = 0,
		grounded = true,
		holding = false,
		holdTicksLeft = 0,
		wasDown = false,
		rocketFuel = stats.rocketFuelCapacity,
		rocketActive = false,
		invulnerableTicks = 0,

		loops = 0,
		score = 0,
		upgradeRound = 0,
		upgradeProgress = 0,
		-- Defaults to the empty set: a solo run is not on a clock. A match hands in the competitive
		-- set explicitly, so checkpoint pressure can never appear in a run that did not ask for it.
		checkpointSet = checkpointSet or MatchTuning.SET_NONE,
		checkpointIndex = 0,

		digest = 5381,
	}, RunSim) :: any

	-- First sweeps land after the wind-up, spread across the period.
	local period = stats.ropePeriodTicks
	for i = 1, stats.ropeCount do
		self.ropes[i] = {
			nextSweepTick = SimTuning.GRACE_TICKS + 1 + math.floor((i - 1) * period / stats.ropeCount),
			guards = 0,
		}
	end
	syncGuards(self)

	return self
end

--[[
	Authoritative reconciliation state. The server sends this value; the client may rebuild the
	same Run and replay only its still-unacknowledged input ticks on top. Copying every nested table
	is deliberate: a network snapshot must be a value, never another reference to the live run.
]]
function RunSim.snapshot(self: Run): Snapshot
	local ropes: { Rope } = {}
	for i, rope in self.ropes do
		ropes[i] = { nextSweepTick = rope.nextSweepTick, guards = rope.guards }
	end

	return {
		seed = self.seed,
		stats = copyStats(self.stats),
		rngState = self.rng.state,
		ropes = ropes,
		tick = self.tick,
		alive = self.alive,
		y = self.y,
		vy = self.vy,
		grounded = self.grounded,
		holding = self.holding,
		holdTicksLeft = self.holdTicksLeft,
		wasDown = self.wasDown,
		rocketFuel = self.rocketFuel,
		rocketActive = self.rocketActive,
		invulnerableTicks = self.invulnerableTicks,
		loops = self.loops,
		score = self.score,
		upgradeRound = self.upgradeRound,
		upgradeProgress = self.upgradeProgress,
		checkpointSet = self.checkpointSet,
		checkpointIndex = self.checkpointIndex,
		digest = self.digest,
	}
end

function RunSim.fromSnapshot(snapshot: Snapshot): Run
	SimTuning.validateStats(snapshot.stats)
	assert(snapshot.tick >= 0 and snapshot.tick == math.floor(snapshot.tick),
		"RunSim.fromSnapshot: tick must be a non-negative integer")
	assert(snapshot.holdTicksLeft >= 0 and snapshot.holdTicksLeft == math.floor(snapshot.holdTicksLeft),
		"RunSim.fromSnapshot: holdTicksLeft must be a non-negative integer")
	assert(snapshot.upgradeRound >= 0 and snapshot.upgradeRound == math.floor(snapshot.upgradeRound),
		"RunSim.fromSnapshot: upgradeRound must be a non-negative integer")
	assert(snapshot.upgradeProgress >= 0 and snapshot.upgradeProgress == math.floor(snapshot.upgradeProgress),
		"RunSim.fromSnapshot: upgradeProgress must be a non-negative integer")
	assert(snapshot.rocketFuel >= 0 and snapshot.rocketFuel <= snapshot.stats.rocketFuelCapacity,
		"RunSim.fromSnapshot: rocket fuel must be within capacity")
	assert(snapshot.invulnerableTicks >= 0
		and snapshot.invulnerableTicks == math.floor(snapshot.invulnerableTicks),
		"RunSim.fromSnapshot: invulnerability must be a non-negative integer")
	assert(#snapshot.ropes == snapshot.stats.ropeCount,
		"RunSim.fromSnapshot: rope schedule does not match ropeCount")
	-- Resolving the set here rather than trusting the number means a malformed snapshot fails at the
	-- boundary instead of at the tick the first checkpoint would have been judged.
	local checkpointSet = MatchTuning.setFor(snapshot.checkpointSet)
	assert(snapshot.checkpointIndex >= 0
		and snapshot.checkpointIndex == math.floor(snapshot.checkpointIndex)
		and snapshot.checkpointIndex <= #checkpointSet,
		"RunSim.fromSnapshot: checkpointIndex is outside its set")

	local ropes: { Rope } = {}
	for i, rope in snapshot.ropes do
		assert(rope.nextSweepTick == math.floor(rope.nextSweepTick),
			"RunSim.fromSnapshot: rope ticks must be integers")
		local guards = rope.guards or 0
		assert(guards == 0 or guards == 1,
			"RunSim.fromSnapshot: each rope may carry at most one guard")
		ropes[i] = { nextSweepTick = rope.nextSweepTick, guards = guards }
	end

	return setmetatable({
		seed = snapshot.seed,
		stats = copyStats(snapshot.stats),
		rng = Rng.new(snapshot.rngState),
		ropes = ropes,
		tick = snapshot.tick,
		alive = snapshot.alive,
		y = snapshot.y,
		vy = snapshot.vy,
		grounded = snapshot.grounded,
		holding = snapshot.holding,
		holdTicksLeft = snapshot.holdTicksLeft,
		wasDown = snapshot.wasDown,
		rocketFuel = snapshot.rocketFuel,
		rocketActive = snapshot.rocketActive,
		invulnerableTicks = snapshot.invulnerableTicks,
		loops = snapshot.loops,
		score = snapshot.score,
		upgradeRound = snapshot.upgradeRound,
		upgradeProgress = snapshot.upgradeProgress,
		checkpointSet = snapshot.checkpointSet,
		checkpointIndex = snapshot.checkpointIndex,
		digest = snapshot.digest,
	}, RunSim) :: any
end

-- CardCatalog supplies rows of generic stat effects. The simulation owns the mutation so cards
-- cannot bypass validation or forget to rebuild derived rope state, but adding an ordinary card
-- never requires another branch here.
function RunSim.applyStatEffects(self: Run, effects: { StatEffect })
	local candidate = copyStats(self.stats)
	local writable = candidate :: any
	for index, effect in effects do
		local current = writable[effect.stat]
		assert(typeof(current) == "number",
			string.format("effect %d: unknown numeric stat %q", index, effect.stat))
		if effect.operation == "ADD" then
			current += effect.value
		elseif effect.operation == "MULTIPLY" then
			current *= effect.value
		else
			error(string.format("effect %d: unknown operation %q", index, effect.operation))
		end
		-- Clamped against the STAT, not against the card. Two cards that move one stat used to carry
		-- their own ceilings and disagree, so the later card's lower cap could pull a stat the
		-- earlier card had already raised back down (SimTuning.STAT_LIMITS explains the case).
		local limit = SimTuning.STAT_LIMITS[effect.stat]
		assert(limit ~= nil, string.format("effect %d moves %s, which has no limit", index, effect.stat))
		current = math.max(current, limit.minimum)
		if limit.maximum then
			current = math.min(current, limit.maximum)
		end
		writable[effect.stat] = current
	end
	SimTuning.validateStats(candidate)
	local previousCapacity = self.stats.rocketFuelCapacity
	self.stats = candidate
	-- Later rocket upgrades never top up the tank. The first Rocket Shoes unlock is the one exception:
	-- it starts full even when chosen mid-air, so the newly unlocked card can be used immediately.
	self.rocketFuel = math.min(self.rocketFuel, candidate.rocketFuelCapacity)
	if previousCapacity == 0 and candidate.rocketFuelCapacity > 0 then
		self.rocketFuel = candidate.rocketFuelCapacity
	end
	self.rocketActive = false
	syncRopes(self)
end

--[[
	Resume from a card choice WITHOUT interrupting the run.

	The offer opens on the tick a rope is cleared, so the player is in the air when they pick. They
	come back to the same height, the same velocity, and the same ropes at the same phase: taking a
	card is a beat inside the jump, not a jump that was ended and restarted. This used to slam the
	player back to the floor and push every rope a full period away, which read as the game
	stopping dead every ten seconds.

	The one thing that does not survive is the hold. Choosing a card is a click on the same button
	that jumps, so both peers force the button up across the pause; retiring the hold here, in the
	shared module, means the client predicts the same transition the server applies instead of
	inferring it from a forced release and drifting. Cutting a hold short only ever lowers an apex,
	and a lower apex lands the player earlier — sooner back on the ground, with more time before
	the next sweep, never less.

	This must live in RunSim rather than in either caller so prediction and authority receive
	exactly the same transition.
]]
function RunSim.resumeAfterUpgrade(self: Run)
	assert(self.alive, "RunSim.resumeAfterUpgrade: run is not alive")
	self.holding = false
	self.holdTicksLeft = 0
	self.wasDown = false
	-- Picking a card does not refill rockets. The tank only fills completely when the player lands.
	self.rocketActive = false
	self.invulnerableTicks = SimTuning.INVULNERABILITY_TICKS
end

-- Re-enter a finished run without changing its score, upgrade cadence, cards or RNG. The next rope is
-- deliberately a full period away: charging for a revive and immediately striking the player
-- again would be technically consistent but plainly unfair. This is deterministic state surgery;
-- both peers resume from the authoritative snapshot produced immediately afterward.
function RunSim.revive(self: Run)
	assert(not self.alive, "RunSim.revive: run is already alive")
	self.alive = true
	resetForSafeResume(self)
end

--[[
	Ends a live run from outside: its match cut it, or the match was decided while it was running.
	The other piece of deterministic state surgery beside `revive`: the run stops where it stands with
	its score unchanged, and both peers take the authoritative snapshot sent straight afterward. No
	rule inside the run decides this -- the match does (`MatchRules`) -- which is why it is an explicit
	call that `step` can never reach.
]]
function RunSim.retire(self: Run)
	if not self.alive then
		return
	end
	self.alive = false
	self.rocketActive = false
end

--[[
	Advances exactly one tick.

	`inputDown` is the button state for THIS tick — the whole input surface of the game (§5). The
	caller reconstructs it from press/release tick indices; the simulation never sees a timestamp.

	Returns nil on a tick where nothing happened, which is most of them. Returning a fresh empty
	table 60 times a second per player, for a server holding many runs, is pure garbage — and the
	callers all have to handle "no events" anyway.
]]
function RunSim.step(self: Run, inputDown: boolean): { Event }?
	if not self.alive then
		return nil
	end

	self.tick += 1
	local invulnerableAtTickStart = self.invulnerableTicks > 0
	local stats = self.stats
	local events: { Event }? = nil
	local function emit(e: Event)
		if not events then
			events = {}
		end
		table.insert(events :: { Event }, e)
	end

	-- ── input ────────────────────────────────────────────────────────────────────────────────
	-- A press only matters on its rising edge and only on the ground. Holding the button across a
	-- landing must not re-launch: that would make "hold the button forever" a strictly better
	-- strategy than playing, and the one-button contract (§5) means we cannot answer it with a
	-- second input.
	local pressed = inputDown and not self.wasDown
	self.wasDown = inputDown

	if pressed and self.grounded then
		self.vy = stats.jumpImpulse
		self.grounded = false
		self.holding = true
		self.holdTicksLeft = stats.maxHoldTicks
		emit({ kind = RunSim.EVENT.JUMP, tick = self.tick })
	elseif not inputDown then
		-- Releasing ends the hold permanently for this jump. Re-pressing mid-air must not buy more
		-- hold, or a rapid tap would out-perform a clean hold and the "hold" half of press-hold-
		-- release would stop meaning anything.
		self.holding = false
	end

	-- ── motion ───────────────────────────────────────────────────────────────────────────────
	if not self.grounded then
		local gravity = stats.gravity
		local normalHoldActive = self.holding and self.holdTicksLeft > 0 and self.vy > 0
		if normalHoldActive then
			gravity *= stats.holdGravityScale
			self.holdTicksLeft -= 1
		elseif self.vy < 0 then
			gravity *= stats.fallGravityScale
		end

		-- Rocket Shoes deliberately share the one action button. The initial held press still shapes
		-- the normal jump; once that boost is finished, or after a release and a fresh mid-air press,
		-- holding burns fuel. A short burn arrests a fall, while a long burn turns into a climb.
		local fuelCapacity = stats.rocketFuelCapacity
		if fuelCapacity > 0 then
			local availableBurn = math.min(1, self.rocketFuel)
			self.rocketActive = inputDown and not normalHoldActive and availableBurn > 0
			if self.rocketActive then
				self.rocketFuel -= availableBurn
				self.vy += stats.rocketThrust * availableBurn * SimTuning.DT
			end
		else
			-- This is the overwhelmingly common opening-run path. Avoid fuel arithmetic entirely
			-- until the player actually owns Rocket Shoes.
			self.rocketActive = false
		end

		-- Semi-implicit Euler: velocity first, then position. Fixed step, so this is exactly
		-- reproducible; it is not an approximation of a "real" continuous arc, it IS the arc.
		self.vy -= gravity * SimTuning.DT
		self.y += self.vy * SimTuning.DT

		if self.y <= 0 then
			self.y = 0
			self.vy = 0
			self.grounded = true
			self.holding = false
			self.holdTicksLeft = 0
			self.rocketActive = false
			-- Landing is the only full refill. Upgrade picks no longer top the tank mid-air.
			if stats.rocketFuelCapacity > 0 then
				self.rocketFuel = stats.rocketFuelCapacity
			end
			emit({ kind = RunSim.EVENT.LAND, tick = self.tick })
		end
	else
		self.rocketActive = false
	end

	-- ── the rope ─────────────────────────────────────────────────────────────────────────────
	-- Checked AFTER motion, so the height compared against the rope is the height at the end of
	-- this tick. Checking first would judge the player on where they were a tick ago, which is a
	-- 16 ms injustice they would feel and never be able to name.
	local inGrace = self.tick <= SimTuning.GRACE_TICKS
	local clearedThisTick = false
	for index, rope in self.ropes do
		if self.tick >= rope.nextSweepTick then
			rope.nextSweepTick += stats.ropePeriodTicks

			if not inGrace then
				if self.y > stats.footClearance then
					local lucky = stats.luck > 0
						and self.rng:nextInt(1, 100)
							<= math.min(100, stats.luck * SimTuning.LUCK_PROC_PERCENT_PER_STACK)
					local points = stats.scorePerLoop
					-- Once any rope burns, every clear is worth two progress steps. More burning
					-- ropes raise score from x2 to x3 and onward, not the upgrade cadence.
					local progress = if stats.scorePerLoop > 1 then 2 else 1
					if lucky then
						points *= SimTuning.LUCKY_SCORE_MULTIPLIER
						progress += SimTuning.LUCKY_UPGRADE_PROGRESS_BONUS
					end
					self.loops += 1
					self.score += points
					self.upgradeProgress += progress
					clearedThisTick = true
					emit({
						kind = RunSim.EVENT.LOOP,
						tick = self.tick,
						ropeIndex = index,
						score = self.score,
						points = points,
						lucky = lucky,
						height = self.y,
					})
				elseif self.invulnerableTicks > 0 then
					-- Protected contacts neither score nor consume another reinforcement. The rope keeps
					-- its schedule; this is a brief safety window, not a hidden phase reset.
				elseif rope.guards > 0 then
					-- Only this rope's own guard can take its strike.
					rope.guards -= 1
					stats.ropeReinforcements -= 1
					self.invulnerableTicks = SimTuning.INVULNERABILITY_TICKS
					emit({ kind = RunSim.EVENT.ROPE_REINFORCED, tick = self.tick, ropeIndex = index })
				else
					self.alive = false
					self.rocketActive = false
					emit({
						kind = RunSim.EVENT.DEATH,
						tick = self.tick,
						ropeIndex = index,
						reason = RunSim.DEATH_REASON.ROPE,
					})
					break
				end
			end
		end
	end

	-- ── upgrade progress ─────────────────────────────────────────────────────────────────────
	-- Only successful rope clears move the bar. Each clear is one step, or two once a rope is on fire;
	-- Lucky adds two more. The target grows exponentially with upgradeRound so deep runs keep a
	-- readable gap between offers. Overflow is retained for multi-step clears.
	if self.alive then
		local required = SimTuning.upgradeProgressRequired(self.upgradeRound)
		if clearedThisTick and self.upgradeProgress >= required then
			self.upgradeRound += 1
			self.upgradeProgress -= required
			emit({
				kind = RunSim.EVENT.UPGRADE_READY,
				tick = self.tick,
				upgradeRound = self.upgradeRound,
			})
		end
		syncRopes(self)
	end

	-- ── checkpoints ──────────────────────────────────────────────────────────────────────────
	-- Judged AFTER this tick's clears, so a clear that lands exactly on the deadline counts. The
	-- alternative loses runs on a technicality nobody could see coming.
	--
	-- Scanned one at a time in order: `checkpointIndex` only ever advances, so a run cannot be
	-- judged twice against the same requirement, and a run rebuilt from a snapshot resumes at the
	-- checkpoint it had already reached rather than re-testing history.
	if self.alive then
		local checkpoints = MatchTuning.setFor(self.checkpointSet)
		local pending = checkpoints[self.checkpointIndex + 1]
		if pending and self.tick >= pending.atTicks then
			self.checkpointIndex += 1
			if self.score < pending.requiredScore then
				self.alive = false
				self.rocketActive = false
				emit({
					kind = RunSim.EVENT.DEATH,
					tick = self.tick,
					reason = RunSim.DEATH_REASON.CHECKPOINT,
					checkpointIndex = self.checkpointIndex,
					requiredScore = pending.requiredScore,
					score = self.score,
				})
			else
				emit({
					kind = RunSim.EVENT.CHECKPOINT_PASSED,
					tick = self.tick,
					checkpointIndex = self.checkpointIndex,
					requiredScore = pending.requiredScore,
					score = self.score,
				})
			end
		end
	end

	-- Do not spend the first tick of a newly broken reinforcement on the strike that created it.
	if invulnerableAtTickStart then
		self.invulnerableTicks -= 1
	end

	-- ── digest ───────────────────────────────────────────────────────────────────────────────
	local h = self.digest
	h = hashStep(h, self.tick)
	h = hashStep(h, quantise(self.y))
	h = hashStep(h, quantise(self.vy))
	h = hashStep(h, self.grounded and 1 or 0)
	h = hashStep(h, self.score)
	h = hashStep(h, self.upgradeRound)
	h = hashStep(h, self.upgradeProgress)
	h = hashStep(h, self.checkpointSet)
	h = hashStep(h, self.checkpointIndex)
	h = hashStep(h, self.alive and 1 or 0)
	h = hashStep(h, self.rng.state)
	h = hashStep(h, quantise(stats.gravity))
	h = hashStep(h, quantise(stats.jumpImpulse))
	h = hashStep(h, quantise(stats.holdGravityScale))
	h = hashStep(h, quantise(stats.fallGravityScale))
	h = hashStep(h, stats.maxHoldTicks)
	h = hashStep(h, quantise(self.rocketFuel))
	h = hashStep(h, self.rocketActive and 1 or 0)
	h = hashStep(h, self.invulnerableTicks)
	h = hashStep(h, stats.rocketFuelCapacity)
	h = hashStep(h, quantise(stats.rocketThrust))
	h = hashStep(h, stats.ropePeriodTicks)
	h = hashStep(h, stats.ropeCount)
	h = hashStep(h, quantise(stats.footClearance))
	h = hashStep(h, stats.scorePerLoop)
	h = hashStep(h, stats.ropeReinforcements)
	h = hashStep(h, stats.luck)
	for _, rope in self.ropes do
		h = hashStep(h, rope.guards)
	end
	self.digest = h

	return events
end

--[[
	Steps a whole run from an input trace. This is what the server uses to validate a submitted
	run and what the tests use to assert on one.

	`inputEvents` is a list of `{ tick, down }` in ascending tick order — the wire format a client
	sends (§6.2). Ticks are validated here rather than trusted: a trace that goes backwards, or
	that reaches past the run, is malformed input and is rejected loudly instead of producing a
	plausible-looking score.
]]
export type InputEvent = { tick: number, down: boolean }

function RunSim.replay(
	seed: number,
	inputEvents: { InputEvent },
	maxTicks: number,
	statsOverride: { [string]: number }?,
	checkpointSet: number?
): (Run, { Event })
	local run = RunSim.new(seed, statsOverride, checkpointSet)
	local log: { Event } = {}

	local previousTick = 0
	for i, e in inputEvents do
		assert(e.tick == math.floor(e.tick) and e.tick >= 1,
			string.format("input %d: tick must be a positive integer", i))
		assert(e.tick > previousTick,
			string.format("input %d: ticks must strictly increase (got %d after %d)", i, e.tick, previousTick))
		previousTick = e.tick
	end

	local nextInput = 1
	local down = false
	for t = 1, maxTicks do
		while nextInput <= #inputEvents and inputEvents[nextInput].tick == t do
			down = inputEvents[nextInput].down
			nextInput += 1
		end

		local events = run:step(down)
		if events then
			for _, e in events do
				table.insert(log, e)
			end
		end
		if not run.alive then
			break
		end
	end

	return run, log
end

return RunSim
