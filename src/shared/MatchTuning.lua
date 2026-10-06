--!strict
--[[
	MatchTuning — the per-minute cut, the deadline on a card choice, and the retired checkpoint curve.

	THE CUT REPLACED THE CURVE IN MATCHES on 2026-09-11. The user: "it shouldn't be 2.5x limit.
	Instead it's like a catch up. Every minute it should eliminate one player. So the player with the
	least amount of points gets eliminated. So the max length time will be 8 minutes. Players can still
	drop during gameplay." `MatchRules.cutCandidate` decides who goes; MatchService cuts every
	`CUT_INTERVAL_SECONDS`. A cut only ever removes someone, so a match of N runners is decided within
	N cuts -- eight minutes for a full lobby -- whatever anyone builds: the job the curve used to do.
	Duels are not cut: the most points at a five-minute buzzer wins (below).

	The checkpoint sets below are still in RunSim, but every match run now asks for SET_NONE. They are
	kept, proof and all, as the floor to bring back if playtests find a cut alone too gentle -- a
	rocket build no longer matters to termination, because the cut does not care how anyone scores.

	WHY CHECKPOINTS AND NOT A TIMER (the reasoning behind the retired curve).
	A solo run ends when a rope catches you. A competitive run cannot rely on that: a strong rocket
	build can stay airborne for a long time, so two good players would race until one of them got
	bored. A buzzer would end the match but would not change how it is played.

	Checkpoints end it *and* shape it. Each one demands a cumulative score by a tick, and the
	requirement escalates every thirty seconds. Playing safe — stacking Reinforce Jump Rope and
	clearing one rope at a time — cannot keep up with a curve like that, so the pressure is toward
	more ropes, higher point multipliers, faster rope: the aggressive half of the deck. The curve is the difficulty,
	and the rope is only the hazard.

	THE TEN-MINUTE GUARANTEE IS PROVED, NOT TUNED.
	`maxAttainableScore` uses the real rope cap plus a proof-only score ceiling. The final checkpoint demands more
	than that arithmetic ceiling. So the last checkpoint is not a balance opinion that might be wrong;
	it is arithmetic, and `validate` refuses to load if a future tuning change ever breaks it.

	ADDING OR RETUNING A SET IS A ROW IN A TABLE. Nothing here is read by
	anything except the checkpoint comparison in `RunSim`.
]]

local SimTuning = require(script.Parent.SimTuning)

local MatchTuning = {}

export type Checkpoint = {
	atTicks: number,      -- integer; the tick the requirement is judged on
	requiredScore: number, -- integer; cumulative score the run must have reached by then
}

--[[
	The curve: a removal every THIRTY seconds. Ten points by the first, twenty-five by the second,
	and steeper and steeper after that. Redesigned 2026-09-10 at the user's direction, replacing a
	removal a minute from 100 points.

	HOW IT ESCALATES. Each removal multiplies the last requirement by a ratio. The ratio starts at the
	user's own first step -- 10 to 25 is x2.5 -- and eases toward `LATE_GROWTH` across the first
	`SETTLE_REMOVALS` removals.

	On 2026-09-10 the user played the curve and asked for the same x2.5 all the way -- "10 by 30
	seconds, 25 by 60, then like 60 by 90 ... use that type of scaling so 2.5 and see how that goes" --
	so `LATE_GROWTH` now equals the opening ratio and the easing does nothing: 10, 25, 63, 156, 391,
	977, 2441, 6104 ... A gentler late game is a one-number change here if the playtests want it.

	At x2.5 the ten-minute proof is not close. The removal at 5:30 already asks for more than any run
	could have scored by then, so in practice no match outlives five and a half minutes.

	THE FIVE KNOBS ARE THE WHOLE CURVE. Change them and `validate` re-proves at load that the last
	removal still outruns the ten-minute ceiling -- set the late growth too gently and the game
	refuses to start rather than shipping matches that can run forever.
]]
MatchTuning.CHECKPOINT_INTERVAL_TICKS = 30 * SimTuning.TICK_RATE
MatchTuning.CHECKPOINT_COUNT = 20 -- twenty removals, thirty seconds apart: ten minutes
MatchTuning.CHECKPOINT_FIRST_SCORE = 10 -- by 0:30 (the user's number)
MatchTuning.CHECKPOINT_SECOND_SCORE = 25 -- by 0:60 (the user's number)
MatchTuning.CHECKPOINT_LATE_GROWTH = 2.5 -- the ratio per removal once it has settled (the user's x2.5)
MatchTuning.CHECKPOINT_SETTLE_REMOVALS = 6 -- removals the ratio takes to ease down to it

-- The ratio from removal `step` to removal `step + 1`.
function MatchTuning.checkpointRatio(step: number): number
	local early = MatchTuning.CHECKPOINT_SECOND_SCORE / MatchTuning.CHECKPOINT_FIRST_SCORE
	local eased = math.clamp((step - 1) / MatchTuning.CHECKPOINT_SETTLE_REMOVALS, 0, 1)
	return early + (MatchTuning.CHECKPOINT_LATE_GROWTH - early) * eased
end

local function buildStandardSet(): { Checkpoint }
	local set: { Checkpoint } = {}
	-- Carried at full precision and rounded per removal, so rounding never compounds down the curve.
	local exact = MatchTuning.CHECKPOINT_FIRST_SCORE
	for index = 1, MatchTuning.CHECKPOINT_COUNT do
		if index > 1 then
			exact *= MatchTuning.checkpointRatio(index - 1)
		end
		set[index] = table.freeze({
			atTicks = index * MatchTuning.CHECKPOINT_INTERVAL_TICKS,
			-- Rounded to an integer because score is an integer: comparing against a fractional
			-- requirement would make the boundary depend on float formatting.
			requiredScore = math.floor(exact + 0.5),
		})
	end
	return table.freeze(set)
end

--[[
	Sets are addressed by INDEX, not by name, because the index travels in every authoritative
	snapshot and feeds the digest. A string would need its own hashing rule and would cost bytes ten
	times a second; an integer is one `hashStep` and one field.

	Index 1 is always the empty set. A solo run is not on a clock, and a run reconstructed from a
	snapshot that has never heard of checkpoints must default to "none" rather than to a curve.
]]
MatchTuning.SETS = table.freeze({
	table.freeze({}),      -- 1: NONE — solo play, no checkpoint pressure
	buildStandardSet(),    -- 2: STANDARD — the competitive curve
})

MatchTuning.SET_NONE = 1
MatchTuning.SET_STANDARD = 2

function MatchTuning.setFor(index: number): { Checkpoint }
	local set = MatchTuning.SETS[index]
	assert(set ~= nil, string.format("MatchTuning: unknown checkpoint set %s", tostring(index)))
	return set
end

--[[
	The largest score any run could hold at `ticks`, using proof-only ceilings.

	The rope bound is the real presentation/gameplay cap. Score multipliers remain open-ended, so the
	retired curve's score ceiling is proof-only and is not a play limit.
]]
MatchTuning.PROOF_MAX_ROPES = SimTuning.MAX_ROPES
MatchTuning.PROOF_MAX_SCORE_PER_LOOP = 64

function MatchTuning.maxAttainableScore(ticks: number): number
	local clearsPerTick = MatchTuning.PROOF_MAX_ROPES / SimTuning.PERIOD_TICKS_MIN
	local pointsPerClear = MatchTuning.PROOF_MAX_SCORE_PER_LOOP * SimTuning.LUCKY_SCORE_MULTIPLIER
	return ticks * clearsPerTick * pointsPerClear
end

--[[
	How long a player has to choose a card before the game chooses for them.

	Measured in real seconds rather than ticks, and deliberately so: the simulation is frozen while
	the modal is open, so there are no ticks to count. This is the one number in the run that is
	honestly wall-clock, and it exists because a competitor's match clock keeps running while you
	read three cards. Taking the decision away after five seconds is kinder than letting an
	indecisive player quietly lose the match.

	The auto-pick uses the run's own seeded RNG, so which card it lands on is reproducible from the
	replay like every other decision.
]]
MatchTuning.CARD_DECISION_SECONDS = 5

--[[
	The cut: every minute of match time, the lowest runner still in is out (the user's number). Wall
	clock, from the moment the runs start, the same clock the card deadline runs on -- a player behind a
	card or a revive is still in the minute everyone else is in.
]]
MatchTuning.CUT_INTERVAL_SECONDS = 60

--[[
	DUELS ARE NOT CUT (the user, 2026-09-11: "For duels just make it go for 5 minutes max as cut off").
	A per-minute cut would end every duel at 1:00. A duel runs to a five-minute buzzer instead, and the
	most points at the buzzer wins -- the same points that decide everything else. At four minutes
	both players are warned that one minute is left (the user: "it'll just be like a countdown or
	warning... player with most points in 1 minute wins"). The warning changes no rule.
]]
MatchTuning.DUEL_FINAL_MINUTE_SECONDS = 4 * 60
MatchTuning.DUEL_CUTOFF_SECONDS = 5 * 60

function MatchTuning.validate(): true
	assert(MatchTuning.DUEL_FINAL_MINUTE_SECONDS > 0
		and MatchTuning.DUEL_CUTOFF_SECONDS > MatchTuning.DUEL_FINAL_MINUTE_SECONDS,
		"a duel's final-minute warning must come before its buzzer")
	assert(MatchTuning.CUT_INTERVAL_SECONDS == math.floor(MatchTuning.CUT_INTERVAL_SECONDS)
		and MatchTuning.CUT_INTERVAL_SECONDS > MatchTuning.CARD_DECISION_SECONDS * 2,
		"a cut must leave far more time to play than a card choice takes")
	assert(MatchTuning.CHECKPOINT_INTERVAL_TICKS > 0
		and MatchTuning.CHECKPOINT_INTERVAL_TICKS == math.floor(MatchTuning.CHECKPOINT_INTERVAL_TICKS),
		"CHECKPOINT_INTERVAL_TICKS must be a positive integer")
	assert(MatchTuning.CHECKPOINT_SECOND_SCORE > MatchTuning.CHECKPOINT_FIRST_SCORE,
		"the second removal must ask for more than the first")
	assert(MatchTuning.CHECKPOINT_LATE_GROWTH > 1, "the checkpoint curve must keep escalating")
	assert(MatchTuning.CHECKPOINT_SETTLE_REMOVALS >= 1, "the growth needs at least one removal to settle")
	assert(MatchTuning.CARD_DECISION_SECONDS > 0, "CARD_DECISION_SECONDS must be positive")

	assert(#MatchTuning.SETS[MatchTuning.SET_NONE] == 0, "set 1 must be the empty set")

	for setIndex, set in MatchTuning.SETS do
		local previousTick, previousScore = 0, 0
		for index, checkpoint in set do
			assert(checkpoint.atTicks == math.floor(checkpoint.atTicks) and checkpoint.atTicks > 0,
				string.format("set %d checkpoint %d: atTicks must be a positive integer", setIndex, index))
			assert(checkpoint.requiredScore == math.floor(checkpoint.requiredScore)
				and checkpoint.requiredScore > 0,
				string.format("set %d checkpoint %d: requiredScore must be a positive integer",
					setIndex, index))
			-- Both must strictly increase. A flat or falling requirement would let a player who
			-- failed one checkpoint pass the next, and the ordered scan in RunSim assumes ordering.
			assert(checkpoint.atTicks > previousTick,
				string.format("set %d checkpoint %d: ticks must strictly increase", setIndex, index))
			assert(checkpoint.requiredScore > previousScore,
				string.format("set %d checkpoint %d: requirement must strictly increase", setIndex, index))
			previousTick, previousScore = checkpoint.atTicks, checkpoint.requiredScore
		end
	end

	-- THE TERMINATION PROOF. The last checkpoint of every non-empty set must demand more than any
	-- run could possibly have scored by then, so no run survives past it. If a future change to the
	-- stat limits raises the ceiling above the curve, this refuses to load rather than silently
	-- shipping a game whose matches can run forever.
	for setIndex, set in MatchTuning.SETS do
		if #set > 0 then
			local final = set[#set]
			local ceiling = MatchTuning.maxAttainableScore(final.atTicks)
			assert(final.requiredScore > ceiling, string.format(
				"set %d cannot terminate: final checkpoint asks %d by tick %d, but %d is attainable",
				setIndex, final.requiredScore, final.atTicks, math.floor(ceiling)))
		end
	end

	return true
end

MatchTuning.validate()

return table.freeze(MatchTuning)
