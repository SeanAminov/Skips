--!strict
--[[
	BotRunner — headless runs for the bots that fill a match.

	A bot is a `RunSim` and an input trace, stepped by the server on the same fixed timestep a
	player's run uses, against the same seed, and cut by the same once-a-minute rule. It is not a
	scripted scoreboard entry: it plays the actual game and it dies to the actual rules, which is why
	its score can be trusted next to a human's on the same table.

	NO CHARACTER, NO REMOTE, NO CLIENT. A bot exists to give a lobby opponents and a duel a
	sparring partner; nothing here draws anything. If bots later need visible avatars, that is a
	presentation layer over this, not a change to it.

	WHY THE SERVER STEPS THEM AT ALL rather than faking a score curve: a faked number cannot be
	eliminated by a checkpoint, cannot be overtaken in the last ten seconds, and cannot be beaten by
	a player having a good run. Every one of those is a thing the mode needs to be able to happen.

	UNDISCLOSED, BY DECISION (2026-09-10). The user wants bots to pass as players. What that took,
	and what it deliberately did not:

	  * Roblox-shaped handles from `BotPolicy.nameFor`, instead of names that were obviously not
	    usernames. They are made up and cannot be checked against real accounts offline, so a rare
	    coincidence with a real username is possible. `isBot` never leaves the server.
	  * A bot now THINKS about its card for 1.2 to 4.5 seconds of wall time, as a person does. It
	    used to take the card in zero ticks, so its score never stalled on the live table while a
	    human's always did -- which gave bots away to anyone watching the board.
	  * NOT done: anything that makes a bot better. It still loses by taking safe cards, and still
	    plays the same rope by the same rules. Passing as a player is about looking like one, never
	    about being handed the ability to beat people it otherwise would not.

	Bots have a visible body since the lane view arrived (2026-09-10): MatchService puts a blocky
	default avatar for each one in the rig folder, beside the copies of the humans' characters, and
	every client draws it in a lane from `viewOf` exactly as it draws a person.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BotPolicy = require(Shared:WaitForChild("BotPolicy"))
local CardCatalog = require(Shared:WaitForChild("CardCatalog"))
local Rng = require(Shared:WaitForChild("Rng"))
local RunSim = require(Shared:WaitForChild("RunSim"))
local SimTuning = require(Shared:WaitForChild("SimTuning"))
local RunView = require(Shared:WaitForChild("RunView"))

local BotRunner = {}

export type Bot = {
	userId: number,        -- negative and far below zero; see BOT_ID_BASE
	name: string,
	run: RunSim.Run,
	rng: Rng.Rng,
	skill: BotPolicy.Skill,
	plan: BotPolicy.Plan?,
	stacks: { [string]: number },
	accumulator: number,
	finished: boolean,
	-- Seconds left reading an offer. While positive the bot's run is frozen exactly as a human's is
	-- behind the card modal, and the match clock keeps running past it.
	thinking: number,
	-- A splat landed: until this run tick the bot plans with a blinded skill.
	blindUntilTick: number,
	blindJitterMultiplier: number,
	blindWhiffPercent: number,
	-- Why the run ended: the rope, or its match retiring it (a cut, or the match being decided).
	deathReason: string?,
}

-- A person weighing three cards. The top of the range sits below the five-second auto-pick a human
-- faces, so a bot never needs the deadline a person sometimes does.
local THINK_MIN_SECONDS = 1.2
local THINK_MAX_SECONDS = 4.5

local nextBotSerial = 0

--[[
	Bot ids are NEGATIVE, unique per bot, and start at minus one million.

	Everything downstream — ranking, the live table, win attribution, `byUserId` — keys on userId,
	and a bot needs to sit in those structures without a Roblox account. Negative keeps them out of
	the leaderboard, whose `userId <= 0` guard refuses them outright.

	Why not simply -1, -2, -3: that is exactly the range Roblox Studio assigns its simulated players
	in *Server & Clients* testing (Player1 is -1, Player2 is -2). Starting bots at -1 made the first
	bot and the first test player share an id, so `byUserId` silently overwrote one with the other,
	and a test player would see a bot's row highlighted as "(you)". It only ever showed up in the
	one mode anyone would use to test matchmaking. Studio caps local test clients at eight, so a
	million is margin, not arithmetic.
]]
local BOT_ID_BASE = -1000000

function BotRunner.spawn(seed: number, checkpointSet: number, skillIndex: number?): Bot
	nextBotSerial += 1
	local band = skillIndex or ((nextBotSerial - 1) % #BotPolicy.SKILLS) + 1
	return {
		userId = BOT_ID_BASE - nextBotSerial,
		-- A separate stream seeded only by the serial, so naming never consumes the bot's play RNG.
		name = BotPolicy.nameFor(Rng.new(nextBotSerial * 104729 + 17)),
		-- The match seed, so a bot faces exactly the rope the humans face. Its own RNG is seeded
		-- separately so its timing jitter does not consume the run's stream and desync anything.
		run = RunSim.new(seed, nil, checkpointSet),
		rng = Rng.new(seed + nextBotSerial * 7919),
		skill = BotPolicy.SKILLS[band],
		plan = nil,
		stacks = {},
		accumulator = 0,
		finished = false,
		thinking = 0,
		blindUntilTick = 0,
		blindJitterMultiplier = 1,
		blindWhiffPercent = 0,
		deathReason = nil,
	}
end

-- Takes the card once the bot has finished thinking. It still loses because of *which* card it
-- takes, never because of how long it took.
local function takeCard(bot: Bot)
	if CardCatalog.eligibleCount(bot.stacks, bot.run.stats) == 0 then
		return
	end
	local offer = CardCatalog.rollOffer(bot.run.rng, bot.run.stats.luck, bot.stacks, bot.run.stats)
	local card = BotPolicy.chooseCard(offer, bot.skill, bot.rng)
	if not card then
		return
	end
	local owned = bot.stacks[card.id] or 0
	if not CardCatalog.isEligible(card, bot.stacks, bot.run.stats) then
		return
	end
	bot.stacks[card.id] = owned + 1
	RunSim.applyStatEffects(bot.run, card.effects)
	RunSim.resumeAfterUpgrade(bot.run)
end

local function currentSkill(bot: Bot): BotPolicy.Skill
	if bot.run.tick < bot.blindUntilTick then
		return BotPolicy.blinded(bot.skill, bot.blindJitterMultiplier, bot.blindWhiffPercent)
	end
	return bot.skill
end

--[[
	One simulation tick. Returns true when the bot has just been offered a card and must stop
	stepping until it has finished thinking, the way a human's run pauses behind the modal.
]]
function BotRunner.step(bot: Bot): boolean
	if not bot.run.alive then
		bot.finished = true
		return false
	end

	-- Re-target whenever the soonest sweep changes, not just when the planned one has passed. With
	-- several ropes out of phase, clearing one makes another the next hazard immediately.
	local plan = bot.plan
	if BotPolicy.shouldReplan(bot.run, plan) then
		bot.plan = BotPolicy.plan(bot.run, currentSkill(bot), bot.rng)
		plan = bot.plan
	end

	local offered = false
	local events = bot.run:step(BotPolicy.isDown(plan, bot.run.tick + 1))
	if events then
		for _, event in events do
			if event.kind == RunSim.EVENT.UPGRADE_READY
				and CardCatalog.eligibleCount(bot.stacks, bot.run.stats) > 0 then
				offered = true
			elseif event.kind == RunSim.EVENT.DEATH then
				bot.deathReason = event.reason
			end
		end
	end
	if not bot.run.alive then
		bot.finished = true
	end
	return offered
end

-- Advances a bot by real elapsed time on the same fixed timestep the run server uses, so a bot and
-- a human in one match progress through the same course at the same rate.
function BotRunner.advance(bot: Bot, dt: number, maxSteps: number)
	if bot.finished then
		return
	end

	-- Reading a card: the run is frozen, as a human's is behind the modal; the match clock is not.
	if bot.thinking > 0 then
		bot.thinking -= dt
		if bot.thinking > 0 then
			return
		end
		bot.thinking = 0
		takeCard(bot)
		bot.accumulator = 0
		return
	end

	bot.accumulator += dt
	local steps = 0
	while bot.accumulator >= SimTuning.DT and steps < maxSteps and not bot.finished do
		bot.accumulator -= SimTuning.DT
		steps += 1
		if BotRunner.step(bot) then
			bot.thinking = THINK_MIN_SECONDS
				+ (THINK_MAX_SECONDS - THINK_MIN_SECONDS) * bot.rng:nextInt(0, 1000) / 1000
			bot.accumulator = 0
			break
		end
	end
end

function BotRunner.isThinking(bot: Bot): boolean
	return bot.thinking > 0
end

--[[
	A splat landed on this bot. For `ticks` of its own run it plays blind.

	The current plan is dropped: it was made while the bot could see, and keeping it would let the
	bot finish a perfectly timed jump it had no way to time.
]]
function BotRunner.blind(bot: Bot, ticks: number, jitterMultiplier: number, whiffPercent: number)
	bot.blindUntilTick = math.max(bot.blindUntilTick, bot.run.tick + ticks)
	bot.blindJitterMultiplier = jitterMultiplier
	bot.blindWhiffPercent = whiffPercent
	bot.plan = nil
end

--[[
	Its match cut this bot, or was decided while it was still running (MatchService). The run stops
	where it stands, through the same `RunSim.retire` a player's run gets.
]]
function BotRunner.retire(bot: Bot, cut: boolean)
	if bot.run.alive then
		RunSim.retire(bot.run)
		bot.deathReason = if cut then RunSim.DEATH_REASON.CUT else RunSim.DEATH_REASON.MATCH_OVER
	end
	bot.finished = true
	bot.thinking = 0
end

-- What an onlooker may see of a bot's run: the same shape a player's run gives (RunView).
function BotRunner.viewOf(bot: Bot): RunView.View
	return RunView.of(bot.run)
end

function BotRunner.summary(bot: Bot)
	return {
		userId = bot.userId,
		name = bot.name,
		score = bot.run.score,
		loops = bot.run.loops,
		tick = bot.run.tick,
		alive = bot.run.alive,
		finished = bot.finished,
		deathReason = bot.deathReason,
	}
end

return BotRunner
