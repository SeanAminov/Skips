--!strict
--[[
	BotPolicy — what a bot presses, and which cards it takes.

	PURE, AND DETERMINISTIC FROM A SEED. No Roblox, no time, no globals: a bot is another input
	trace over the same `RunSim` every human uses, so a bot's run is as reproducible as a player's
	and the server is not running a second, softer game for them.

	HOW A BOT IS MADE TO LOSE — and it matters that it is not by cheating.

	A bot that was simply given worse physics would be a lie: it would look like it was playing the
	same game and it would not be. Instead a bot plays the real game *badly in a specific way*:

	  1. Its timing is jittered, so it clears ropes but not perfectly, and occasionally whiffs.
	  2. It takes the SAFE cards FIRST. Reinforce Jump Rope, Luck, jump height — reaching for a
	     score multiplier only when the offer holds nothing else it likes.

	Point 2 is the one that decides matches, and it is the mechanism the user asked for without
	bolting on a handicap: a mostly-safe build scores slower than anyone building aggressively, and
	since 2026-09-11 the lowest runner is cut every minute. Measured then over ten seeds: a greedy
	build averaged 133 points by the first cut, the strongest bot band 30. It is the same trap a
	cautious human falls into.

	MEASURED, AND RETUNED ONCE. Excluding the multipliers outright was the first attempt and it was
	too strong a handicap: one rope at one point per clear tops out near 30 points in the opening
	minute, against a first checkpoint of 100, so every bot died at 60 seconds without exception.
	That is not an opponent, it is a formality. Ranking the multipliers LAST rather than banning
	them lets a bot grow enough to be worth beating and still fall behind.

	A bot can still win a match against someone who plays worse than it. That is correct: an
	opponent that cannot lose is not an opponent.
]]

local SimTuning = require(script.Parent.SimTuning)

local BotPolicy = {}

export type Skill = {
	-- How many ticks before a sweep the bot begins its jump. The honest window is roughly 11 ticks
	-- at the opening period; drifting either side of it is what makes a bot look human.
	leadTicks: number,
	-- How long it holds. A tap clears the rope; a longer hold is what a strong player uses to span
	-- several rotations, and a bot never learns to.
	holdTicks: number,
	-- Jitter applied to the lead, in ticks, each jump.
	jitterTicks: number,
	-- Chance in 100 that a jump is simply missed. Bots are eliminated by the checkpoint curve far
	-- more often than by this, but a run with no mistakes at all reads as scripted.
	whiffPercent: number,
	-- Chance in 100 of reaching for a SAFE card when the offer holds both a safe card and a score
	-- multiplier. This is the real difficulty dial: timing decides whether a bot clears the next
	-- rope, but card taste decides whether it is still alive in three minutes.
	safeBiasPercent: number,
}

--[[
	Three difficulty bands. Even the top band is deliberately beatable: it clears ropes reliably but
	still takes safe cards, so it dies to the curve rather than to the rope.

	WHIFF RATES RETUNED 2026-09-10, once whiffs actually worked. They were 7 / 4 / 2 per 100 jumps,
	chosen while a whiff was silently re-rolled every tick and so never happened. Made real, those
	rates killed bots on the rope at a median of 26 to 37 seconds -- some at three -- because a miss
	before the first Reinforce card is certain death. 3 / 2 / 1 keeps an occasional human-looking
	mistake without the rope, rather than the curve, deciding every bot's fate.
]]
BotPolicy.SKILLS = table.freeze({
	table.freeze({ leadTicks = 11, holdTicks = 2, jitterTicks = 4, whiffPercent = 3, safeBiasPercent = 70 }),
	table.freeze({ leadTicks = 11, holdTicks = 3, jitterTicks = 2, whiffPercent = 2, safeBiasPercent = 50 }),
	table.freeze({ leadTicks = 11, holdTicks = 4, jitterTicks = 1, whiffPercent = 1, safeBiasPercent = 30 }),
})

--[[
	Cards a bot is willing to take, best-first within its own limited taste.

	The ordering is the handicap. A bot works down this list and takes the first card the offer
	happens to contain, so it hoards safety and only picks up a multiplier when nothing safer was
	on the table. It falls behind gradually rather than being unable to play, which is the whole
	design — see the retuning note in the module header.
]]
BotPolicy.PREFERRED_CARDS = table.freeze({
	-- Safe first: none of these move score per clear or clears per second by much.
	"REINFORCE_JUMP_ROPE",
	"INCREASE_LUCK",
	"INCREASE_JUMP_HEIGHT",
	"ROCKET_SHOES",
	-- The multipliers, last, and only reached when the offer held nothing safer.
	"IGNITE_JUMPROPE",
	"ADD_JUMPROPE",
})

--[[
	ADD_JUMPROPE IS LAST, AND IT TOOK TWO MEASUREMENTS TO EARN ITS PLACE.

	Banning it produced bots that died at exactly 60 seconds every time, because one rope at a
	two-second period allows at most 30 clears in the opening minute and the first checkpoint asks
	for 100 points. No amount of card taste closes that gap: more ropes is the only way through.

	Taking it eagerly was worse — a reference build that grabbed every multiplier killed itself at
	43 seconds, because the planner committed to one jump at a time and never looked at the second
	rope. That was a planner bug, not a reason to avoid the card, and `shouldReplan` now re-targets
	whenever the soonest sweep changes.

	So it sits last: a bot builds toward more ropes slowly, gets through the early checkpoints, and
	still falls behind someone taking them every time.
]]

-- The cards that actually keep pace with the checkpoint curve. Named here so the validator can
-- prove they sit below every safe card rather than trusting the order above to stay correct.
BotPolicy.MULTIPLIER_CARDS = table.freeze({ ADD_JUMPROPE = true, IGNITE_JUMPROPE = true })

export type Plan = {
	pressAtTick: number,
	releaseAtTick: number,
	sweepTick: number,
}

-- The soonest sweep any rope is due to make. A bot only ever plans against the next hazard; it does
-- not reason about the one after, which is another reason a multi-rope build outclasses it.
function BotPolicy.nextSweep(run: any): number?
	local soonest: number? = nil
	for _, rope in run.ropes do
		if not soonest or rope.nextSweepTick < (soonest :: number) then
			soonest = rope.nextSweepTick
		end
	end
	return soonest
end

--[[
	Decides the jump for the sweep that is coming. Returns nil only when there is no sweep at all;
	a whiff returns a plan that never presses.

	Consumes exactly two RNG draws when it plans, and one when it whiffs, so a bot's stream advances
	predictably and two servers replaying the same bot seed produce the same run.
]]
function BotPolicy.plan(run: any, skill: Skill, rng: any): Plan?
	local sweep = BotPolicy.nextSweep(run)
	if not sweep then
		return nil
	end
	-- A whiff is a decision about THIS sweep, so it has to hold. It used to return nil, and
	-- shouldReplan treats no plan as plan again -- so the whiff was re-rolled on the very next tick
	-- and, with around a hundred ticks before the jump was due, effectively never stood. Bots were
	-- missing almost none of their jumps whatever their whiff rate said; the splat test exposed it.
	-- A skip plan aims at the sweep and never presses, so the miss stands until the sweep passes.
	if rng:nextInt(1, 100) <= skill.whiffPercent then
		return { pressAtTick = math.huge, releaseAtTick = math.huge, sweepTick = sweep }
	end

	local jitter = if skill.jitterTicks > 0
		then rng:nextInt(-skill.jitterTicks, skill.jitterTicks)
		else 0
	local lead = math.max(1, skill.leadTicks + jitter)
	local press = sweep - lead
	return {
		pressAtTick = press,
		releaseAtTick = press + math.max(1, skill.holdTicks),
		sweepTick = sweep,
	}
end

--[[
	Is the current plan still aimed at the right rope?

	True when there is no plan, when the planned sweep has passed, or when some other rope now
	sweeps sooner than the one being aimed at. That last case is the one that matters: it is what
	lets a bot survive its own Add Jumprope picks instead of walking into the rope it was not
	watching.
]]
function BotPolicy.shouldReplan(run: any, plan: Plan?): boolean
	if not plan then
		return true
	end
	if run.tick >= plan.sweepTick then
		return true
	end
	local soonest = BotPolicy.nextSweep(run)
	return soonest ~= nil and soonest < plan.sweepTick
end

-- Whether the button is held on this tick, given a plan. Grounded-only presses are the run's own
-- rule; this simply stops holding once the plan is done.
function BotPolicy.isDown(plan: Plan?, tick: number): boolean
	if not plan then
		return false
	end
	return tick >= plan.pressAtTick and tick < plan.releaseAtTick
end

--[[
	Which of the three offered cards a bot takes.

	WEIGHTED, NOT ORDERED, AND THE SECOND RETUNE. A strict preference order was measured and failed
	twice: a bot gets about five upgrades in the opening minute, Reinforce Jump Rope alone absorbs
	eight picks, and so every bot arrived at the first checkpoint with 30 points against the 100 it
	needed. Both attempts produced a bot that could not reach 60 seconds, which is not an opponent.

	So a bot rolls: `safeBiasPercent` of the time it hoards safety, otherwise it takes the
	multiplier like a competent player would. It therefore builds a real score and still lags
	someone who takes the multiplier every single time — falling behind gradually, which is what
	"does not really win" has to mean if the bot is to be worth beating at all.
]]
local function firstMatching(offer: { any }, wantMultiplier: boolean): any
	for _, wanted in BotPolicy.PREFERRED_CARDS do
		if BotPolicy.MULTIPLIER_CARDS[wanted] == wantMultiplier or
			(not wantMultiplier and not BotPolicy.MULTIPLIER_CARDS[wanted]) then
			for _, card in offer do
				if (card :: any).id == wanted then
					return card
				end
			end
		end
	end
	return nil
end

function BotPolicy.chooseCard(offer: { any }, skill: Skill?, rng: any?): any
	local safe = firstMatching(offer, false)
	local multiplier = firstMatching(offer, true)

	if safe and multiplier and skill and rng then
		if rng:nextInt(1, 100) <= skill.safeBiasPercent then
			return safe
		end
		return multiplier
	end
	-- Nothing to weigh: either only one kind was offered, or no skill was supplied. Safe first,
	-- because the conservative choice is the one a bot should make when it has no reason to gamble.
	return safe or multiplier or offer[1]
end

--[[
	The same skill, playing blind — what a splatted bot uses for the length of the splat.

	A person who cannot see the rope still knows its rhythm and guesses: some jumps land, more are
	early or late, and plenty are never attempted. That is modelled rather than scripted to fail --
	the jitter widens and the whiff rate climbs -- so a blinded bot can still get lucky, exactly as a
	blinded person can. Never more accurate than the sighted skill, by construction.
]]
function BotPolicy.blinded(skill: Skill, jitterMultiplier: number, whiffPercent: number): Skill
	return {
		leadTicks = skill.leadTicks,
		holdTicks = skill.holdTicks,
		jitterTicks = math.max(skill.jitterTicks * jitterMultiplier, 6),
		whiffPercent = math.max(skill.whiffPercent, whiffPercent),
		safeBiasPercent = skill.safeBiasPercent,
	}
end

--[[
	A Roblox-shaped handle: letters and digits, at most one underscore and never at either end,
	three to twenty characters. Bots are not disclosed (the user's decision, 2026-09-10).

	SEMI-HUMAN (the user, 2026-09-11: "names should be semi humanish too"). Built around a first name,
	the way most real handles are -- emma2931, Liam_48, LilyPlays, noahh7, ItsAva, ruby_m, xXZoeXx --
	rather than two game words glued together ("SkyHopper4411"), which read as generated. Made up, and
	not checked against real accounts, so a coincidence with a real username stays possible.

	The lists are checked so no combination spells "bot" (suite §16 reads 500 of them).
]]
local FIRST_NAMES = table.freeze({
	"emma", "liam", "olivia", "noah", "ava", "ethan", "mia", "lucas", "sophia", "mason",
	"bella", "logan", "chloe", "jack", "lily", "owen", "grace", "leo", "zoe", "caleb",
	"ella", "ryan", "ruby", "dylan", "nora", "tyler", "maya", "aiden", "ivy", "jake",
	"hazel", "max", "luna", "sam", "aria", "eli", "stella", "finn", "piper", "nate",
	"willow", "cole", "daisy", "luke", "sadie", "evan", "quinn", "jayden", "layla", "gavin",
	"amelia", "kai", "harper", "miles", "violet", "theo", "jade", "wyatt", "ellie", "levi",
})
local NAME_SUFFIXES = table.freeze({
	"plays", "xd", "gamer", "rblx", "pro", "bunny", "cat", "fox", "star", "vibes",
	"gaming", "kid", "lol", "art", "hops", "skates",
})
local NAME_PREFIXES = table.freeze({ "its", "im", "real", "just", "lil", "the" })
local NAME_INITIALS = "acdefghjklmnprstw"

local function capitalise(word: string): string
	return word:sub(1, 1):upper() .. word:sub(2)
end

local function pick(rng: any, list: { string }): string
	return list[rng:nextInt(1, #list)]
end

function BotPolicy.nameFor(rng: any): string
	local first = pick(rng, FIRST_NAMES)
	local style = rng:nextInt(1, 8)
	local name
	if style == 1 then -- emma2931
		name = first .. tostring(rng:nextInt(1, 9999))
	elseif style == 2 then -- Liam_48
		name = capitalise(first) .. "_" .. tostring(rng:nextInt(1, 99))
	elseif style == 3 then -- LilyPlays, jakexd
		local suffix = pick(rng, NAME_SUFFIXES)
		name = if rng:nextInt(1, 2) == 1 then capitalise(first) .. capitalise(suffix) else first .. suffix
	elseif style == 4 then -- noahh7
		name = first .. first:sub(-1) .. tostring(rng:nextInt(1, 99))
	elseif style == 5 then -- ItsAva, imjake
		local prefix = pick(rng, NAME_PREFIXES)
		name = if rng:nextInt(1, 2) == 1 then capitalise(prefix) .. capitalise(first) else prefix .. first
	elseif style == 6 then -- ruby_m, EmmaK09
		local at = rng:nextInt(1, #NAME_INITIALS)
		local initial = NAME_INITIALS:sub(at, at)
		name = if rng:nextInt(1, 2) == 1
			then first .. "_" .. initial
			else capitalise(first) .. initial:upper() .. string.format("%02d", rng:nextInt(0, 99))
	elseif style == 7 then -- MasonGamer12
		name = capitalise(first) .. capitalise(pick(rng, NAME_SUFFIXES)) .. tostring(rng:nextInt(1, 99))
	else -- xXZoeXx
		name = "xX" .. capitalise(first) .. "Xx"
	end
	return name:sub(1, 20)
end

function BotPolicy.validate(): true
	assert(#BotPolicy.SKILLS >= 1, "there must be at least one skill band")
	for index, skill in BotPolicy.SKILLS do
		assert(skill.leadTicks > 0, string.format("skill %d: leadTicks must be positive", index))
		assert(skill.holdTicks > 0, string.format("skill %d: holdTicks must be positive", index))
		assert(skill.jitterTicks >= 0, string.format("skill %d: jitterTicks must be non-negative", index))
		assert(skill.whiffPercent >= 0 and skill.whiffPercent < 100,
			string.format("skill %d: whiffPercent must be in [0, 100)", index))
		-- Never 0 and never 100: at 0 a bot builds optimally and stops being beatable by taste, at
		-- 100 it cannot pass the first checkpoint and stops being an opponent. Both were measured.
		assert(skill.safeBiasPercent > 0 and skill.safeBiasPercent < 100,
			string.format("skill %d: safeBiasPercent must be strictly inside (0, 100)", index))
		-- A bot that never misses and holds forever would be a wall, not an opponent.
		assert(skill.holdTicks < SimTuning.baseStats().maxHoldTicks,
			string.format("skill %d: a bot must not use the full hold window", index))
	end

	-- The multipliers must rank below every safe card. If one ever drifts up the list, bots keep
	-- pace with the curve and the mechanism that makes them lose inverts silently.
	local seenMultiplier = false
	for _, id in BotPolicy.PREFERRED_CARDS do
		if BotPolicy.MULTIPLIER_CARDS[id] then
			seenMultiplier = true
		else
			assert(not seenMultiplier,
				"a bot must prefer every safe card over a multiplier; " .. id .. " ranks too low")
		end
	end
	return true
end

BotPolicy.validate()

return table.freeze(BotPolicy)
