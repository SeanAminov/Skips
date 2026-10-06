--!strict
--[[
	MatchService — queues, rosters, and turning a set of finished runs into placings.

	WHAT A MATCH ACTUALLY IS. One seed and one checkpoint set, handed to every participant. After
	that each player runs the ordinary simulation with their own inputs and their own build, and
	this module never touches a run again except to read its score. That is the entire multiplayer
	implementation, and it is small only because the design rules forbid singletons in the
	simulation four stages before anyone needed a second player.

	WHAT THIS MODULE MUST NEVER DO:
	  1. Decide anything a run decides. It reads `RunServer.summaryOf`; it does not step or score
	     anyone. It ends a run in exactly ONE way -- the per-minute cut, or the match being decided
	     while someone still runs -- and only through `retire`, which asks the run's owner. Any other
	     way for a match to end a run would be a second set of rules (§6).
	  2. Give two participants different courses. One seed, one checkpoint set, handed out together.
	  3. Wait forever. Every casual queue, challenge and match has a bound, because the thing a
	     player cannot recover from is a screen that never changes. Ranked is the one deliberate
	     exception -- it waits for a human, at the user's direction -- and its search screen counts
	     the wait up, so it is never a screen that does not change.

	WHY DEATH DOES NOT ELIMINATE. The user's rule: your score stands after you die, and if nobody
	still playing beats it you win from the grave. So this tracks two different states — `ended`
	(dead, may still revive) and `finished` (definitively out) — and only the second one resolves
	anything.

	THE CUT (the user, 2026-09-11: "every minute it should eliminate one player... the player with the
	least amount of points"). Once a minute `runCut` takes the lowest runner still in
	(`MatchRules.cutCandidate`). It replaced the x2.5 checkpoint curve: match runs now carry no curve
	at all, and a match of N is decided within N cuts.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MatchProtocol = require(Shared:WaitForChild("MatchProtocol"))
local MatchRules = require(Shared:WaitForChild("MatchRules"))
local MatchTuning = require(Shared:WaitForChild("MatchTuning"))
local Elo = require(Shared:WaitForChild("Elo"))
local SimTuning = require(Shared:WaitForChild("SimTuning"))
local ViewProtocol = require(Shared:WaitForChild("ViewProtocol"))
local RunProtocol = require(Shared:WaitForChild("RunProtocol"))
local BotRunner = require(script.Parent:WaitForChild("BotRunner"))
local RunServer = require(script.Parent:WaitForChild("RunServer"))
local BotOutfits = require(script.Parent:WaitForChild("BotOutfits"))

type Participant = {
	-- nil for a bot. Everything downstream keys on `userId`, which bots have (negative) and
	-- players have (positive), so the rest of this file rarely has to care which it is holding.
	player: Player?,
	bot: BotRunner.Bot?,
	isBot: boolean,
	userId: number,
	name: string,
	-- Last known summary. Kept rather than re-read at resolve time because a player who leaves
	-- takes their session with them, and their score must survive them.
	score: number,
	loops: number,
	tick: number,
	alive: boolean,
	deathReason: string?,
	finished: boolean,
}

type Match = {
	id: string,
	mode: string,
	seed: number,
	state: string,
	participants: { Participant },
	byUserId: { [number]: Participant },
	startAt: number,
	--[[
		Whether first place here is worth a recorded win.

		The user's rule: a duel against a bot does not count, matchmaking does. This closes the
		obvious farm -- queue a duel, wait ten seconds, beat a bot, repeat -- while leaving a
		bot-filled lobby rewarding, so a quiet server still feels worth playing on.

		Note the remaining hole, left deliberately at the user's direction: an all-bot LOBBY does
		award a win. Flipping this to "at least one other human" is a one-line change here.
	]]
	awardsWin: boolean,
	-- Ranked: humans only, with each human's rating and games played captured the moment the match
	-- formed. The result is rated from these, never from whatever a store happens to hold at the end.
	ranked: boolean,
	ratingsBefore: { [number]: { rating: number, games: number } },
	-- The cut: the server time of the next one, and how many have already happened.
	nextCutAt: number,
	cuts: number,
	-- A duel instead: a one-minute warning at 4:00, and the buzzer at 5:00 (MatchTuning).
	finalMinute: boolean,
	finalMinuteAt: number,
	cutoffAt: number,
}

local MatchService = {}

-- Replaced by the leaderboard service once it exists. A no-op default keeps matches working
-- whether or not persistence is available, which matters because DataStores are unreachable until
-- the place is published and linked.
function MatchService.onWin(_player: Player, _mode: string, _score: number) end

--[[
	Ratings, through the same kind of seam as `onWin`. A match must KNOW ratings -- to pair ranked
	players and to rate a result -- but must not know where they are kept. The bootstrap replaces
	these with the rating service; the defaults keep ranked playable, unrated, with nothing saved.
]]
function MatchService.ratingOf(_userId: number): (number, number)
	return Elo.START, 0
end
function MatchService.ratingsOnline(): boolean
	return false
end
function MatchService.onRated(_changes: { Elo.Change }) end

-- Every resolved match, summarised for tuning (MatchAnalytics, wired by the bootstrap). The summary
-- carries Player handles only so analytics can address its events; the log it writes names no one.
function MatchService.onResolved(_summary: any) end

local matches: { [string]: Match } = {}
local matchOf: { [Player]: Match } = {}
-- One queue per kind and mode: CASUAL:DUEL, CASUAL:LOBBY, RANKED:DUEL, RANKED:LOBBY.
local function queueKey(kind: string, mode: string): string
	return kind .. ":" .. mode
end
local queues: { [string]: { Player } } = {}
for _, kind in { MatchProtocol.KIND.CASUAL, MatchProtocol.KIND.RANKED } do
	for _, mode in { MatchProtocol.MODE.DUEL, MatchProtocol.MODE.LOBBY } do
		queues[queueKey(kind, mode)] = {}
	end
end
local queuedAt: { [Player]: number } = {}
local challenges: { [Player]: { from: Player, expiresAt: number } } = {}
local lastChallengeAt: { [Player]: number } = {}
local nextMatchSerial = 0
local seedSource = Random.new()
local scoreClock = 0

local remoteFolder = ReplicatedStorage:FindFirstChild(RunProtocol.REMOTE_FOLDER)
if not remoteFolder then
	remoteFolder = Instance.new("Folder")
	remoteFolder.Name = RunProtocol.REMOTE_FOLDER
	remoteFolder.Parent = ReplicatedStorage
end
assert(remoteFolder:IsA("Folder"), "MatchService: remote container must be a Folder")

local remote = remoteFolder:FindFirstChild(MatchProtocol.REMOTE_NAME)
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = MatchProtocol.REMOTE_NAME
	remote.Parent = remoteFolder
end
assert(remote:IsA("RemoteEvent"), "MatchService: Match remote must be a RemoteEvent")
local matchRemote = remote :: RemoteEvent

-- ─── small helpers ───────────────────────────────────────────────────────────────────────────

local function entriesOf(match: Match): { MatchRules.Entry }
	local entries: { MatchRules.Entry } = {}
	for index, p in match.participants do
		entries[index] = {
			userId = p.userId,
			name = p.name,
			score = p.score,
			loops = p.loops,
			tick = p.tick,
			alive = p.alive,
			deathReason = p.deathReason,
			isBot = p.isBot,
		}
	end
	return entries
end

local function broadcast(match: Match, op: string, payload: { [string]: any })
	for _, p in match.participants do
		local player = p.player
		if player and player.Parent == Players then
			matchRemote:FireClient(player, op, payload)
		end
	end
end

--[[
	Placings as a client sees them: identical, minus `isBot`.

	Bots are not disclosed in matches (the user's decision, 2026-09-10). The server still needs the
	flag -- it is what keeps a bot's win off the leaderboard -- but no client uses it, and sending it
	would disclose bots to anyone reading remote traffic.
]]
local function forClient(rows: { any }): { any }
	local out = {}
	for index, row in rows do
		local copy = table.clone(row)
		copy.isBot = nil
		out[index] = copy
	end
	return out
end

local function finishedOf(match: Match): { [number]: boolean }
	local finished: { [number]: boolean } = {}
	for _, p in match.participants do
		finished[p.userId] = p.finished
	end
	return finished
end

-- Pulls each participant's live numbers across from their run. A player whose session has gone
-- (left, respawned, dropped to solo) keeps the last figures we saw, so their score survives them.
local function refresh(match: Match)
	for _, p in match.participants do
		if p.bot then
			local summary = BotRunner.summary(p.bot)
			p.score = summary.score
			p.loops = summary.loops
			p.tick = summary.tick
			p.alive = summary.alive
			p.deathReason = summary.deathReason
		elseif p.player then
			local summary = RunServer.summaryOf(p.player)
			if summary and summary.matchId == match.id then
				p.score = summary.score
				p.loops = summary.loops
				p.tick = summary.tick
				p.alive = summary.alive
				p.deathReason = summary.deathReason
			end
		end
	end
end

local function removeFromQueues(player: Player)
	for _, queue in queues do
		local index = table.find(queue, player)
		if index then
			table.remove(queue, index)
		end
	end
	queuedAt[player] = nil
end

-- ─── resolution ──────────────────────────────────────────────────────────────────────────────

-- ─── rigs: every participant's look, for the lane view ────────────────────────────────────────

--[[
	One appearance per participant in `ReplicatedStorage.SkipsRigs`, named by match and slot, so every
	client can draw each runner in a lane beside its own (StageView). Humans get a copy of their
	character; bots get a random outfit from Roblox's own free catalog (BotOutfits) -- hair, clothes,
	now and then a cap or shades -- which is how a great many real players look. That is the point: a
	bot must not stand out in the lane beside you, and a folder that held only bots would itself give
	them away.
]]
local RIG_BODY_PARTS = {
	Head = true, UpperTorso = true, LowerTorso = true, LeftUpperArm = true, LeftLowerArm = true,
	LeftHand = true, RightUpperArm = true, RightLowerArm = true, RightHand = true, LeftUpperLeg = true,
	LeftLowerLeg = true, LeftFoot = true, RightUpperLeg = true, RightLowerLeg = true, RightFoot = true,
}

local function rigFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(ViewProtocol.RIG_FOLDER)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = ViewProtocol.RIG_FOLDER
	folder.Parent = ReplicatedStorage
	return folder
end

local function modelFrom(description: HumanoidDescription): Model?
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	end)
	description:Destroy()
	return if ok then model else nil
end

local function botRig(bot: BotRunner.Bot): Model?
	-- Seeded by the bot, so its look is one look for the whole match. A plain body if an item will
	-- not load -- a bot is never left without one.
	local model = modelFrom(BotOutfits.describe(Random.new(-bot.userId)))
		or modelFrom(BotOutfits.plain(Random.new(-bot.userId)))
	if not model then
		return nil
	end
	-- The same 5.5-stud body every player is normalised to, so a bot is not the odd one out by height.
	local low, high = math.huge, -math.huge
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") and RIG_BODY_PARTS[child.Name] then
			low = math.min(low, child.Position.Y - child.Size.Y * 0.5)
			high = math.max(high, child.Position.Y + child.Size.Y * 0.5)
		end
	end
	if high > low then
		pcall(function()
			model:ScaleTo(model:GetScale() * SimTuning.NOMINAL_HEIGHT / (high - low))
		end)
	end
	return model
end

local function buildRigs(match: Match)
	local folder = rigFolder()
	for slot, p in match.participants do
		local rig: Model? = nil
		local player = p.player
		if player and player.Character then
			local character = player.Character :: Model
			local was = character.Archivable
			character.Archivable = true
			local ok, copy = pcall(function()
				return character:Clone()
			end)
			character.Archivable = was
			rig = if ok then copy else nil
		elseif p.bot then
			rig = botRig(p.bot :: BotRunner.Bot)
		end
		if rig then
			if matches[match.id] ~= match then
				rig:Destroy()
				return
			end
			for _, descendant in rig:GetDescendants() do
				if descendant:IsA("LuaSourceContainer") then
					descendant:Destroy()
				end
			end
			rig.Name = match.id .. "_" .. slot
			rig.Parent = folder
		end
	end
end

local function clearRigs(match: Match)
	local folder = ReplicatedStorage:FindFirstChild(ViewProtocol.RIG_FOLDER)
	if not folder then
		return
	end
	local prefix = match.id .. "_"
	for _, child in folder:GetChildren() do
		if child.Name:sub(1, #prefix) == prefix then
			child:Destroy()
		end
	end
end

--[[
	THE ONE WAY A MATCH ENDS A RUN: the cut, or the match being decided while the runner still runs.
	It asks the run's owner -- RunServer for a player, BotRunner for a bot -- and never touches a
	simulation from here.
]]
local function retire(p: Participant, cut: boolean)
	if p.bot then
		BotRunner.retire(p.bot, cut)
	elseif p.player then
		RunServer.retireFromMatch(p.player, cut)
	end
end

local function resolve(match: Match)
	if match.state == MatchProtocol.STATE.RESOLVED then
		return
	end
	match.state = MatchProtocol.STATE.RESOLVED
	-- Decided with someone still running -- a lone runner who leads outright, or the last cut -- ends
	-- their run here too. The match is over; a run left going would only score into nothing.
	for _, p in match.participants do
		if not p.finished then
			retire(p, false)
			p.finished = true
		end
	end
	refresh(match)

	local placings = MatchRules.rank(entriesOf(match))
	--[[
		A win is recorded only when the match was worth winning, and only for a human.

		`awardsWin` is false for a duel that had to be padded with a bot, which is the farm the
		user asked to close: queue, wait ten seconds, beat a bot, repeat. The winner being a bot is
		checked separately -- a bot topping a lobby is a perfectly good outcome, it just is not
		anybody's win.
	]]
	local winner = placings[1]
	local awarded = match.awardsWin and winner ~= nil and winner.isBot ~= true
	if awarded and winner then
		local participant = match.byUserId[winner.userId]
		local player = participant and participant.player
		if player and player.Parent == Players then
			MatchService.onWin(player, match.mode, winner.score)
		end
	end

	-- Ranked: rate the result, pairwise chess Elo from the ratings captured when the match formed.
	local ratingChanges: { Elo.Change } = {}
	if match.ranked then
		local rated: { Elo.Rated } = {}
		for _, p in match.participants do
			local before = match.ratingsBefore[p.userId]
			if before and not p.isBot then
				table.insert(rated, {
					userId = p.userId,
					rating = before.rating,
					games = before.games,
					score = p.score,
					tick = p.tick,
				})
			end
		end
		if #rated >= 2 then
			ratingChanges = Elo.rate(rated)
			MatchService.onRated(ratingChanges)
		end
	end

	-- When and why every run in the match ended, for the curve to be tuned on real players.
	local runs = {}
	for _, placing in placings do
		local participant = match.byUserId[placing.userId]
		table.insert(runs, {
			bot = placing.isBot == true,
			player = if participant then participant.player else nil,
			score = placing.score,
			seconds = placing.tick / SimTuning.TICK_RATE,
			reason = if placing.alive then "LEFT" else (placing.deathReason or "UNKNOWN"),
			place = placing.place,
		})
	end
	task.spawn(MatchService.onResolved, { mode = match.mode, ranked = match.ranked, runs = runs })

	broadcast(match, MatchProtocol.SERVER.RESOLVED, {
		matchId = match.id,
		mode = match.mode,
		-- `awardsWin` stays on the server. No client reads it, and a false value on a duel would tell
		-- anyone reading remote traffic that their opponent was a bot.
		placings = forClient(placings),
		ranked = match.ranked,
		ratings = ratingChanges,
	})

	for _, p in match.participants do
		if matchOf[p.player] == match then
			matchOf[p.player] = nil
		end
	end
	clearRigs(match)
	matches[match.id] = nil
end

local function markFinished(match: Match, participant: Participant)
	if participant.finished then
		return
	end
	participant.finished = true
	if MatchRules.isDecided(entriesOf(match), finishedOf(match)) then
		resolve(match)
	end
end

--[[
	The cut, once a minute: the lowest runner still in is out. Everyone hears who, the table stops
	counting them as a runner, and their score stands like anyone else's who is out. Nobody is cut
	when nobody should be -- a lone runner leading outright has already won (`isDecided`).
]]
local function runCut(match: Match)
	match.cuts += 1
	match.nextCutAt += MatchTuning.CUT_INTERVAL_SECONDS
	refresh(match)
	local victim = MatchRules.cutCandidate(entriesOf(match), finishedOf(match))
	local participant = if victim then match.byUserId[victim.userId] else nil
	if not participant then
		return
	end
	retire(participant, true)
	refresh(match)
	broadcast(match, MatchProtocol.SERVER.CUT, {
		matchId = match.id,
		name = participant.name,
		minute = match.cuts,
		score = participant.score,
	})
	markFinished(match, participant)
end

-- A duel reaches 4:00: a warning only -- one minute left, and the most points at the buzzer wins.
local function warnFinalMinute(match: Match)
	match.finalMinute = true
	broadcast(match, MatchProtocol.SERVER.FINAL_MINUTE, {
		matchId = match.id,
		cutoffAt = match.cutoffAt,
	})
end

-- A duel's buzzer (5:00): whoever is still going stops, and the most points wins.
local function reachCutoff(match: Match)
	resolve(match)
end

-- ─── forming and starting ────────────────────────────────────────────────────────────────────

local function formMatch(mode: string, players: { Player }, botCount: number, ranked: boolean?): Match?
	-- A bot in a rated match would put a number on the board that no person earned against a person.
	assert(not ranked or botCount == 0, "a ranked match can never contain a bot")
	local roster: { Player } = {}
	for _, player in players do
		-- A queued player whose character is not ready cannot be handed a run, and holding the
		-- match for them would strand everyone else.
		if player.Parent == Players and RunServer.isPlayable(player) and not matchOf[player] then
			table.insert(roster, player)
		end
	end
	-- Bots make up the difference, so one human is enough to start. The alternative -- refusing to
	-- form a match until enough people happen to be queued -- is how the mode dies on a quiet
	-- server, and the user asked for exactly this fill.
	if #roster == 0 or (#roster + botCount) < MatchProtocol.LOBBY_MIN then
		return nil
	end

	nextMatchSerial += 1
	local match: Match = {
		id = string.format("M%d", nextMatchSerial),
		mode = mode,
		-- ONE seed for everyone. This is the whole fairness guarantee: the rope timings, the card
		-- rolls and the Luck procs are identical for every participant.
		seed = seedSource:NextInteger(1, 2147483647),
		state = MatchProtocol.STATE.FORMING,
		participants = {},
		byUserId = {},
		startAt = workspace:GetServerTimeNow() + MatchProtocol.COUNTDOWN_SECONDS,
		-- A duel padded out with a bot is practice, not a result. Matchmaking counts either way.
		awardsWin = not (mode == MatchProtocol.MODE.DUEL and botCount > 0),
		ranked = ranked == true,
		ratingsBefore = {},
		nextCutAt = math.huge,
		cuts = 0,
		finalMinute = false,
		finalMinuteAt = math.huge,
		cutoffAt = math.huge,
	}

	for _, player in roster do
		local participant: Participant = {
			player = player,
			bot = nil,
			isBot = false,
			userId = player.UserId,
			name = player.Name,
			score = 0,
			loops = 0,
			tick = 0,
			alive = true,
			deathReason = nil,
			finished = false,
		}
		table.insert(match.participants, participant)
		match.byUserId[participant.userId] = participant
		matchOf[player] = match
		removeFromQueues(player)
		if match.ranked then
			local rating, games = MatchService.ratingOf(player.UserId)
			match.ratingsBefore[player.UserId] = { rating = rating, games = games }
		end
	end

	-- Bots are spawned on the match's own seed, so they face exactly the rope the humans face. They
	-- are not a scoreboard curve: they play, and the same cut takes them, which is what makes their
	-- score meaningful next to a real one.
	for _ = 1, botCount do
		local bot = BotRunner.spawn(match.seed, MatchTuning.SET_NONE)
		local participant: Participant = {
			player = nil,
			bot = bot,
			isBot = true,
			userId = bot.userId,
			name = bot.name,
			score = 0,
			loops = 0,
			tick = 0,
			alive = true,
			deathReason = nil,
			finished = false,
		}
		table.insert(match.participants, participant)
		match.byUserId[participant.userId] = participant
	end

	matches[match.id] = match
	task.spawn(buildRigs, match)

	local roster_payload: { { [string]: any } } = {}
	for index, p in match.participants do
		roster_payload[index] = { userId = p.userId, name = p.name }
	end
	broadcast(match, MatchProtocol.SERVER.MATCH_FOUND, {
		matchId = match.id,
		mode = match.mode,
		ranked = match.ranked,
		roster = roster_payload,
		startAt = match.startAt,
	})

	-- The countdown is the loading beat. The run's own GO handshake still owns the exact tick play
	-- begins on, so this only decides when the runs are created.
	task.delay(MatchProtocol.COUNTDOWN_SECONDS, function()
		if matches[match.id] ~= match or match.state ~= MatchProtocol.STATE.FORMING then
			return
		end
		match.state = MatchProtocol.STATE.RUNNING
		local runsStartAt = workspace:GetServerTimeNow() + RunProtocol.START_LEAD_SECONDS
		if match.mode == MatchProtocol.MODE.DUEL then
			-- Duels are never cut: a one-minute warning at 4:00, the buzzer at 5:00 (MatchTuning).
			match.finalMinuteAt = runsStartAt + MatchTuning.DUEL_FINAL_MINUTE_SECONDS
			match.cutoffAt = runsStartAt + MatchTuning.DUEL_CUTOFF_SECONDS
		else
			-- The first cut comes a minute after the runs start, on the same clock as their GO.
			match.nextCutAt = runsStartAt + MatchTuning.CUT_INTERVAL_SECONDS
		end
		for _, p in match.participants do
			local player = p.player
			if p.isBot then
				-- Bots need no start handshake: they are already stepping on the match seed.
			elseif player and player.Parent == Players then
				local started = RunServer.startRunFor(player, {
					seed = match.seed,
					-- No curve: the cut is what ends a match now (2026-09-11).
					checkpointSet = MatchTuning.SET_NONE,
					matchId = match.id,
					-- The load-bearing flag. A dead competitor stays dead and keeps their score;
					-- restarting them into a fresh solo run would silently break the whole mode.
					autoRestart = false,
				})
				if not started then
					markFinished(match, p)
				end
			else
				markFinished(match, p)
			end
		end
		broadcast(match, MatchProtocol.SERVER.MATCH_STARTED, {
			matchId = match.id,
			mode = match.mode,
			seed = match.seed,
		})
	end)

	return match
end

-- ─── queue servicing ─────────────────────────────────────────────────────────────────────────

--[[
	Who in a queue can be handed a run right now, in the order they queued.

	A queued player whose character is still loading is passed over, never removed: they keep their
	place and are matched the moment they can be. Nothing below takes a player out of a queue itself
	-- `formMatch` removes exactly the players it places -- so a match that fails to form leaves
	everyone where they were. The old code removed a pair first, and if the match then refused to
	form, neither player was ever put back while their screen still said SEARCHING.
]]
local function readyIn(queue: { Player }): { Player }
	local ready: { Player } = {}
	for _, player in queue do
		if player.Parent == Players and RunServer.isPlayable(player) and not matchOf[player] then
			table.insert(ready, player)
		end
	end
	return ready
end

local function waitedFor(player: Player, now: number): number
	local since = queuedAt[player]
	return if since then now - since else 0
end

--[[
	Casual: real opponents first, bots when they do not turn up.

	Both casual queues prefer humans and only fall back after `BOT_FILL_SECONDS`. That ordering
	matters: filling early would mean two people queueing at the same moment get separate bot
	matches instead of each other.
]]
local function serviceCasual(now: number)
	local duel = readyIn(queues[queueKey(MatchProtocol.KIND.CASUAL, MatchProtocol.MODE.DUEL)])
	local index = 1
	while index + 1 <= #duel do
		formMatch(MatchProtocol.MODE.DUEL, { duel[index], duel[index + 1] }, 0, false)
		index += 2
	end
	local leftover = duel[index]
	if leftover and waitedFor(leftover, now) >= MatchProtocol.BOT_FILL_SECONDS then
		formMatch(MatchProtocol.MODE.DUEL, { leftover }, MatchProtocol.DUEL_SIZE - 1, false)
	end

	local lobby = readyIn(queues[queueKey(MatchProtocol.KIND.CASUAL, MatchProtocol.MODE.LOBBY)])
	local head = lobby[1]
	if head and (#lobby >= MatchProtocol.LOBBY_TARGET
		or waitedFor(head, now) >= MatchProtocol.BOT_FILL_SECONDS) then
		local group: { Player } = table.move(lobby, 1, math.min(#lobby, MatchProtocol.LOBBY_TARGET), 1, {})
		-- Always fill to the full eight. A lobby of two humans and six bots is a better lobby than
		-- a lobby of two, and the bots are eliminated by the checkpoint curve like everyone else.
		formMatch(MatchProtocol.MODE.LOBBY, group, MatchProtocol.LOBBY_TARGET - #group, false)
	end
end

--[[
	How far apart two ranked ratings may be and still be paired, for someone who has waited this long.
	Tight at first so a result means something, wider every second, and fully open after
	`RANKED_WINDOW_OPEN_SECONDS`: the user accepted waiting for ranked, not waiting forever.
]]
local function ratingWindow(waited: number): number
	if waited >= MatchProtocol.RANKED_WINDOW_OPEN_SECONDS then
		return math.huge
	end
	return MatchProtocol.RANKED_WINDOW_START + MatchProtocol.RANKED_WINDOW_GROWTH_PER_SECOND * waited
end

-- The more patient of the two sets the window, so a long wait is what eventually finds a match.
local function compatible(a: Player, b: Player, now: number): boolean
	local ratingA = MatchService.ratingOf(a.UserId)
	local ratingB = MatchService.ratingOf(b.UserId)
	local window = math.max(ratingWindow(waitedFor(a, now)), ratingWindow(waitedFor(b, now)))
	return math.abs(ratingA - ratingB) <= window
end

-- Ranked: humans only, always. Nothing on this path can add a bot, and `formMatch` asserts it.
local function serviceRanked(now: number)
	local duel = readyIn(queues[queueKey(MatchProtocol.KIND.RANKED, MatchProtocol.MODE.DUEL)])
	local paired: { [Player]: boolean } = {}
	for i, a in duel do
		if not paired[a] then
			for j = i + 1, #duel do
				local b = duel[j]
				if not paired[b] and compatible(a, b, now) then
					paired[a] = true
					paired[b] = true
					formMatch(MatchProtocol.MODE.DUEL, { a, b }, 0, true)
					break
				end
			end
		end
	end

	local lobby = readyIn(queues[queueKey(MatchProtocol.KIND.RANKED, MatchProtocol.MODE.LOBBY)])
	local head = lobby[1]
	if not head then
		return
	end
	-- Everyone in a ranked lobby is within the window of whoever has waited longest.
	local group: { Player } = { head }
	for other = 2, #lobby do
		if #group >= MatchProtocol.LOBBY_TARGET then
			break
		end
		if compatible(head, lobby[other], now) then
			table.insert(group, lobby[other])
		end
	end
	if #group >= MatchProtocol.LOBBY_TARGET
		or (#group >= MatchProtocol.LOBBY_MIN
			and waitedFor(head, now) >= MatchProtocol.RANKED_LOBBY_WAIT_SECONDS) then
		formMatch(MatchProtocol.MODE.LOBBY, group, 0, true)
	end
end

local function serviceQueues(now: number)
	serviceCasual(now)
	serviceRanked(now)
end

-- ─── client requests ─────────────────────────────────────────────────────────────────────────

local function joinQueue(player: Player, modeValue: unknown, kindValue: unknown)
	if matchOf[player] then
		return
	end
	local mode = if typeof(modeValue) == "string" then modeValue else nil
	if mode ~= MatchProtocol.MODE.DUEL and mode ~= MatchProtocol.MODE.LOBBY then
		return
	end
	-- Anything but an explicit RANKED is casual: nobody is ever put on a rating by omission.
	local kind = if kindValue == MatchProtocol.KIND.RANKED then MatchProtocol.KIND.RANKED else MatchProtocol.KIND.CASUAL
	local key = queueKey(kind, mode :: string)
	removeFromQueues(player)
	table.insert(queues[key], player)
	local now = workspace:GetServerTimeNow()
	queuedAt[player] = now
	local ranked = kind == MatchProtocol.KIND.RANKED
	matchRemote:FireClient(player, MatchProtocol.SERVER.QUEUED, {
		mode = mode,
		kind = kind,
		waiting = #queues[key],
		target = if mode == MatchProtocol.MODE.DUEL
			then MatchProtocol.DUEL_SIZE
			else MatchProtocol.LOBBY_TARGET,
		-- The server's own moment the search began, so the client's clock counts from the truth.
		since = now,
		rating = if ranked then (MatchService.ratingOf(player.UserId)) else nil,
		ratingsOnline = MatchService.ratingsOnline(),
	})
end

local function leaveQueue(player: Player)
	removeFromQueues(player)
	matchRemote:FireClient(player, MatchProtocol.SERVER.QUEUE_LEFT, {})
end

local function challenge(player: Player, targetUserId: unknown)
	if matchOf[player] or typeof(targetUserId) ~= "number" then
		return
	end
	local now = workspace:GetServerTimeNow()
	local last = lastChallengeAt[player]
	if last and now - last < MatchProtocol.CHALLENGE_COOLDOWN_SECONDS then
		return
	end
	lastChallengeAt[player] = now
	local target = Players:GetPlayerByUserId(targetUserId)
	if not target or target == player or matchOf[target] then
		return
	end
	local pending = challenges[target]
	if pending and pending.from.Parent == Players and now < pending.expiresAt then
		return
	end
	challenges[target] = {
		from = player,
		expiresAt = now + MatchProtocol.CHALLENGE_TIMEOUT_SECONDS,
	}
	matchRemote:FireClient(target, MatchProtocol.SERVER.CHALLENGED, {
		fromUserId = player.UserId,
		fromName = player.Name,
		expiresAt = challenges[target].expiresAt,
	})
	matchRemote:FireClient(player, MatchProtocol.SERVER.CHALLENGE_SENT, {
		toUserId = target.UserId,
		toName = target.Name,
	})
end

local function acceptChallenge(player: Player)
	local pending = challenges[player]
	challenges[player] = nil
	if not pending or workspace:GetServerTimeNow() >= pending.expiresAt then
		return
	end
	local challenger = pending.from
	if challenger.Parent ~= Players or matchOf[challenger] or matchOf[player] then
		return
	end
	-- A challenge is two real people by definition, so it always counts.
	formMatch(MatchProtocol.MODE.DUEL, { challenger, player }, 0, false)
end

local function declineChallenge(player: Player)
	local pending = challenges[player]
	challenges[player] = nil
	if pending and pending.from.Parent == Players then
		matchRemote:FireClient(pending.from, MatchProtocol.SERVER.CHALLENGE_DECLINED, {
			byUserId = player.UserId,
			byName = player.Name,
		})
	end
end

-- Forfeiting keeps the score already earned. Leaving is not a way to erase a bad run, and it is
-- not a way to strand the people still playing either.
local function leaveMatch(player: Player)
	local match = matchOf[player]
	if not match then
		return
	end
	local participant = match.byUserId[player.UserId]
	if participant then
		refresh(match)
		markFinished(match, participant)
	end
	matchOf[player] = nil
end

-- A match run never auto-restarts, so when the match is over the player has an ended run and
-- nothing to play. This is the way back to solo. Guarded on not being in a match so it cannot be
-- used to abandon one without forfeiting through `leaveMatch`.
local function playSolo(player: Player)
	if matchOf[player] or not RunServer.isPlayable(player) then
		return
	end
	RunServer.startRunFor(player, {})
end

-- ─── lifecycle ───────────────────────────────────────────────────────────────────────────────

function MatchService.start()
	RunServer.onRunFinished(function(player, _session)
		local match = matchOf[player]
		if not match then
			return
		end
		local participant = match.byUserId[player.UserId]
		if participant then
			refresh(match)
			markFinished(match, participant)
		end
	end)

	matchRemote.OnServerEvent:Connect(function(player, op, a, b)
		if op == MatchProtocol.CLIENT.QUEUE then
			joinQueue(player, a, b)
		elseif op == MatchProtocol.CLIENT.LEAVE_QUEUE then
			leaveQueue(player)
		elseif op == MatchProtocol.CLIENT.CHALLENGE then
			challenge(player, a)
		elseif op == MatchProtocol.CLIENT.ACCEPT then
			acceptChallenge(player)
		elseif op == MatchProtocol.CLIENT.DECLINE then
			declineChallenge(player)
		elseif op == MatchProtocol.CLIENT.LEAVE_MATCH then
			leaveMatch(player)
		elseif op == MatchProtocol.CLIENT.PLAY_SOLO then
			playSolo(player)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		removeFromQueues(player)
		challenges[player] = nil
		lastChallengeAt[player] = nil
		for target, pending in challenges do
			if pending.from == player then
				challenges[target] = nil
			end
		end
		local match = matchOf[player]
		if match then
			local participant = match.byUserId[player.UserId]
			if participant then
				markFinished(match, participant)
			end
			matchOf[player] = nil
		end
	end)

	RunService.Heartbeat:Connect(function(dt)
		local now = workspace:GetServerTimeNow()
		serviceQueues(now)

		for player, pending in challenges do
			if now >= pending.expiresAt then
				challenges[player] = nil
			end
		end

		-- Bots advance every frame on the fixed timestep, not on the scoreboard's slower clock:
		-- they are playing the same course at the same rate as the humans beside them.
		for _, match in matches do
			if match.state == MatchProtocol.STATE.RUNNING then
				for _, p in match.participants do
					local bot = p.bot
					if bot then
						BotRunner.advance(bot, dt, RunProtocol.MAX_STEPS_PER_FRAME)
						if bot.finished and not p.finished then
							refresh(match)
							markFinished(match, p)
						end
					end
				end
				if match.state == MatchProtocol.STATE.RUNNING and now >= match.nextCutAt then
					runCut(match)
				end
				if match.state == MatchProtocol.STATE.RUNNING and not match.finalMinute
					and now >= match.finalMinuteAt then
					warnFinalMinute(match)
				end
				if match.state == MatchProtocol.STATE.RUNNING and now >= match.cutoffAt then
					reachCutoff(match)
				end
			end
		end

		scoreClock += dt
		if scoreClock < MatchProtocol.SCORE_INTERVAL_SECONDS then
			return
		end
		scoreClock = 0
		for _, match in matches do
			if match.state == MatchProtocol.STATE.RUNNING then
				refresh(match)
				local entries = entriesOf(match)
				local finished = finishedOf(match)
				-- A lone runner who has just passed the fallen leader has won; no need to wait for a cut.
				if MatchRules.isDecided(entries, finished) then
					resolve(match)
				else
					local duel = match.mode == MatchProtocol.MODE.DUEL
					-- A lobby marks the row the next cut would take, so everyone can see who is in
					-- danger, and when. A duel is never cut.
					local danger = if duel then nil else MatchRules.cutCandidate(entries, finished)
					local rows = forClient(MatchRules.liveTable(entries))
					for _, row in rows do
						row.danger = if danger and row.userId == danger.userId then true else nil
					end
					broadcast(match, MatchProtocol.SERVER.SCORES, {
						matchId = match.id,
						table = rows,
						cutAt = if duel then nil else match.nextCutAt,
						cut = match.cuts + 1,
						-- A duel's buzzer, for the timer on every client.
						cutoffAt = if duel then match.cutoffAt else nil,
					})
				end
			end
		end
	end)
end

-- Read-only, for tests and for the Studio hooks.
function MatchService.matchFor(player: Player): string?
	local match = matchOf[player]
	return match and match.id or nil
end

--[[
	Who is beside `player` in their match, for the lane view (ViewService): every other participant,
	keyed by SLOT and rig name -- never by account id, and with nothing that says bot -- and whether
	`player` themself is out. Nil when they are not in a live match.
]]
export type Mate = {
	key: string,
	rig: string,
	name: string,
	player: Player?,
	bot: BotRunner.Bot?,
	finished: boolean,
}

function MatchService.lineupFor(player: Player): ({ Mate }?, boolean)
	local match = matchOf[player]
	if not match or match.state == MatchProtocol.STATE.RESOLVED then
		return nil, false
	end
	local mates: { Mate } = {}
	local youOut = false
	for slot, p in match.participants do
		if p.player == player then
			youOut = p.finished
		else
			table.insert(mates, {
				key = "s" .. slot,
				rig = match.id .. "_" .. slot,
				name = p.name,
				player = if p.player and p.player.Parent == Players then p.player else nil,
				bot = p.bot,
				finished = p.finished,
			})
		end
	end
	return mates, youOut
end

--[[
	What another server system may know about one of `fromPlayer`'s opponents.

	Only inside the same RUNNING match, never the caller themself, and as a narrow view rather than
	the Participant -- for the same reason `RunServer.summaryOf` exists: a feature layered on top of
	matches must be able to read one, never edit one.
]]
export type OpponentView = {
	matchId: string,
	userId: number,
	player: Player?,
	bot: BotRunner.Bot?,
	alive: boolean,
	busy: boolean, -- behind a card choice right now
}

function MatchService.opponentView(fromPlayer: Player, targetUserId: number): OpponentView?
	local match = matchOf[fromPlayer]
	if not match or match.state ~= MatchProtocol.STATE.RUNNING then
		return nil
	end
	local p = match.byUserId[targetUserId]
	if not p or p.player == fromPlayer or p.finished then
		return nil
	end
	local bot = p.bot
	if bot then
		return {
			matchId = match.id,
			userId = p.userId,
			player = nil,
			bot = bot,
			alive = bot.run.alive,
			busy = BotRunner.isThinking(bot),
		}
	end
	local victim = p.player
	local summary = victim and RunServer.summaryOf(victim)
	if not summary or summary.matchId ~= match.id then
		return nil
	end
	return {
		matchId = match.id,
		userId = p.userId,
		player = victim,
		bot = nil,
		alive = summary.alive and not summary.ended,
		busy = summary.paused,
	}
end

-- Every opponent still belonging to `fromPlayer`'s active match. This is deliberately a server-only
-- view: group effects can address a matchup without trusting a client-supplied roster or exposing
-- the account ids that distinguish people from undisclosed bots.
function MatchService.opponents(fromPlayer: Player): { OpponentView }
	local match = matchOf[fromPlayer]
	local result: { OpponentView } = {}
	if not match or match.state ~= MatchProtocol.STATE.RUNNING then
		return result
	end
	for _, participant in match.participants do
		if participant.player ~= fromPlayer and not participant.finished then
			local view = MatchService.opponentView(fromPlayer, participant.userId)
			if view then
				table.insert(result, view)
			end
		end
	end
	return result
end

return MatchService
