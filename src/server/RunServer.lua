--!strict
--[[
	RunServer — authoritative owner of every live run.

	The client sends only boolean transitions stamped with simulation ticks. This module validates
	and buffers them, then steps the same RunSim the client predicts with. The authority delay is a
	latency buffer, not a second set of rules: local feel is immediate while a player's packets still
	arrive before the server judges their tick. It starts at 18 ticks and stretches with the player's
	measured ping, up to 45, so a slow connection is judged on the jump it made rather than on when
	its packet landed.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardCatalog = require(Shared:WaitForChild("CardCatalog"))
local MatchTuning = require(Shared:WaitForChild("MatchTuning"))
local MonetizationConfig = require(Shared:WaitForChild("MonetizationConfig"))
local RunProtocol = require(Shared:WaitForChild("RunProtocol"))
local RunSim = require(Shared:WaitForChild("RunSim"))
local SimTuning = require(Shared:WaitForChild("SimTuning"))
local RunView = require(Shared:WaitForChild("RunView"))
local AvatarNormalizer = require(script.Parent:WaitForChild("AvatarNormalizer"))

type InputTransition = { tick: number, down: boolean }
type CharacterState = {
	character: Model,
	root: BasePart,
	baseRoot: CFrame,
	groundPosition: Vector3,
}
--[[
	How a run was started, and what should happen when it ends.

	Solo passes nothing: a fresh seed, no checkpoint curve, and -- since 2026-09-10, at the user's
	request -- no automatic restart either; a lost solo run waits for PLAY_AGAIN. A match passes all
	four, and crucially `autoRestart = false` -- a
	dead competitor stays dead and keeps their score until the match resolves. Resurrecting them
	into a fresh solo run mid-match is the single easiest way to break the mode, and it was
	previously what SIX separate call sites did unconditionally.
]]
export type RunOptions = {
	seed: number?,
	checkpointSet: number?,
	matchId: string?,
	autoRestart: boolean?,
}

type Session = {
	runId: number,
	matchId: string?,
	autoRestart: boolean,
	finished: boolean,
	deathReason: string?,
	run: RunSim.Run,
	startAt: number,
	armed: boolean,
	clockStarted: boolean,
	accumulator: number,
	inputDown: boolean,
	lastInputTick: number,
	lastQueuedDown: boolean,
	pending: { InputTransition },
	recentTransitionTicks: { number },
	characterState: CharacterState,
	paused: boolean,
	offer: { CardCatalog.Card }?,
	offerRound: number,
	offerDeadline: number?,   -- server time the card choice is taken out of the player's hands
	resumeDeadline: number?,  -- server time a revived run starts whether or not the player taps
	stacks: { [string]: number },
	ended: boolean,
	reviveExpiresAt: number?,
	revivePurchasePending: boolean,
	shoppingRemaining: number?, -- in the shop from the revive offer: the seconds the counter paused on
	retired: boolean,         -- its match ended it (the cut, or the match decided); no revive can follow
	delayTicks: number,       -- how far authority trails this player's prediction, from their ping
	lastClientTick: number,   -- the last tick the CLIENT stamped, for ordering; lastInputTick is where it landed
	lateInputs: number,       -- presses that arrived after their tick and were applied on the next one
	pauseAtTick: number?,     -- solo pause requested: stop when the run reaches this tick
	userPaused: boolean,      -- stopped at the player's request, as opposed to behind a card offer
	unpauseRequested: boolean,
}

local RunServer = {}

--[[
	Tickets, through a seam: the run server charges for a revive but does not know where tickets are
	kept. The bootstrap wires these to PlayerDataService. The defaults refuse, so a missing wire can
	never hand out a free revive.
]]
function RunServer.spendTickets(_player: Player, _amount: number): (boolean, string)
	return false, "tickets are not available"
end
function RunServer.refundTickets(_player: Player, _amount: number): boolean
	return false
end

local sessions: { [Player]: Session } = {}
local characters: { [Player]: CharacterState } = {}
local ready: { [Player]: boolean } = {}
local runSerials: { [Player]: number } = {}
local laneIndices: { [Player]: number } = {}
local nextLaneIndex = 1
local seedSource = Random.new()
local netClock = 0

local remoteFolder = ReplicatedStorage:FindFirstChild(RunProtocol.REMOTE_FOLDER)
if not remoteFolder then
	remoteFolder = Instance.new("Folder")
	remoteFolder.Name = RunProtocol.REMOTE_FOLDER
	remoteFolder.Parent = ReplicatedStorage
end
assert(remoteFolder:IsA("Folder"), "RunServer: remote container must be a Folder")

local remote = remoteFolder:FindFirstChild(RunProtocol.REMOTE_NAME)
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = RunProtocol.REMOTE_NAME
	remote.Parent = remoteFolder
end
assert(remote:IsA("RemoteEvent"), "RunServer: Run remote must be a RemoteEvent")
local runRemote = remote :: RemoteEvent

local function pingOf(player: Player): number
	local ok, ping = pcall(function()
		return player:GetNetworkPing()
	end)
	return if ok and typeof(ping) == "number" then ping else 0
end

-- How many ticks authority should trail this player's prediction: long enough for their presses to
-- arrive before the tick they were stamped for is judged. One-way latency is half the round trip.
local function delayFor(player: Player): number
	local ticks = math.ceil((pingOf(player) * 0.5 + RunProtocol.PING_MARGIN_SECONDS) * SimTuning.TICK_RATE)
	return math.clamp(ticks, RunProtocol.AUTHORITY_DELAY_TICKS, RunProtocol.MAX_AUTHORITY_DELAY_TICKS)
end

-- How far ahead a shared resume moment must be for this player's copy of it to arrive in time. A
-- late arrival is still correct -- the client catches up against the timestamp -- just less smooth.
local function resumeLead(player: Player): number
	return math.clamp(pingOf(player) * 0.5 + 0.05, 0.05, RunProtocol.START_LEAD_SECONDS)
end

local function groundForLane(laneIndex: number): Vector3
	local spawn = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	if spawn then
		return Vector3.new(
			spawn.Position.X + (laneIndex - 1) * 12,
			spawn.Position.Y + spawn.Size.Y * 0.5,
			spawn.Position.Z
		)
	end
	return Vector3.new((laneIndex - 1) * 12, 0.5, 0)
end

local function putAtGround(state: CharacterState, rootToFeet: number)
	local rootPosition = state.groundPosition + Vector3.new(0, rootToFeet, 0)
	-- The camera watches from +Z, so the avatar's LookVector must point +Z to show its front.
	local targetRoot = CFrame.lookAt(rootPosition, rootPosition + Vector3.new(0, 0, 1))
	local rootToPivot = state.root.CFrame:ToObjectSpace(state.character:GetPivot())
	state.character:PivotTo(targetRoot * rootToPivot)
	state.baseRoot = state.root.CFrame
end

local function sendSnapshot(player: Player, session: Session, op: string)
	runRemote:FireClient(player, op, {
		runId = session.runId,
		state = RunSim.snapshot(session.run),
	})
end

--[[
	Two signals, because a dead player and a finished player are different things.

	`ENDED` fires the moment a rope catches them or a checkpoint eliminates them -- but they may
	still buy a revive, so their run is not over and the match must keep them in contention. Their
	score stands either way: the user's rule is that dying does not remove you from contention, and
	if the field cannot beat your score while they play on, you still win.

	`FINISHED` fires once the revive is definitively not coming. That is the signal a match resolves
	on. It fires at most once per session, so a decline racing a timeout cannot resolve twice.
]]
local endedListeners: { (Player, Session) -> () } = {}
local finishedListeners: { (Player, Session) -> () } = {}

function RunServer.onRunEnded(fn: (Player, Session) -> ())
	table.insert(endedListeners, fn)
end

function RunServer.onRunFinished(fn: (Player, Session) -> ())
	table.insert(finishedListeners, fn)
end

local function notifyEnded(player: Player, session: Session)
	for _, fn in endedListeners do
		task.spawn(fn, player, session)
	end
end

local function finishSession(player: Player, session: Session)
	if session.finished then
		return
	end
	session.finished = true
	for _, fn in finishedListeners do
		task.spawn(fn, player, session)
	end
end

local function startRun(player: Player, options: RunOptions?)
	local characterState = characters[player]
	if not characterState or not ready[player] or player.Parent ~= Players then
		return
	end

	local opts = options or {}
	runSerials[player] = (runSerials[player] or 0) + 1
	characterState.root.CFrame = characterState.baseRoot

	local session: Session = {
		runId = runSerials[player],
		matchId = opts.matchId,
		deathReason = nil,
		-- Nothing restarts on its own any more: a match run finishes, and a solo run waits for the
		-- player's PLAY_AGAIN (the user, 2026-09-10: a lost run should not start the next by itself).
		autoRestart = if opts.autoRestart == nil then false else opts.autoRestart,
		finished = false,
		run = RunSim.new(
			opts.seed or seedSource:NextInteger(1, 2147483647),
			nil,
			opts.checkpointSet
		),
		startAt = 0,
		armed = false,
		clockStarted = false,
		accumulator = 0,
		inputDown = false,
		lastInputTick = 0,
		lastQueuedDown = false,
		pending = {},
		recentTransitionTicks = {},
		characterState = characterState,
		paused = false,
		offer = nil,
		offerRound = 0,
		offerDeadline = nil,
		resumeDeadline = nil,
		stacks = {},
		ended = false,
		reviveExpiresAt = nil,
		revivePurchasePending = false,
		shoppingRemaining = nil,
		retired = false,
		delayTicks = delayFor(player),
		lastClientTick = 0,
		lateInputs = 0,
		pauseAtTick = nil,
		userPaused = false,
		unpauseRequested = false,
	}
	sessions[player] = session

	runRemote:FireClient(player, RunProtocol.SERVER.START, {
		runId = session.runId,
		seed = session.run.seed,
		-- Prediction must judge the same checkpoints authority does, so the set travels with the
		-- seed. Solo sends the empty set; a match will send the competitive one.
		checkpointSet = session.run.checkpointSet,
		baseRoot = characterState.baseRoot,
		groundPosition = characterState.groundPosition,
		-- Solo and match runs end differently (NEW RUN versus NO THANKS), and only solo may pause.
		inMatch = session.matchId ~= nil,
	})
end

-- The one place a finished run decides what happens next. A match run reports the player out and
-- stays out. A solo run used to restart itself; since 2026-09-10 it waits instead, and the client
-- shows the run-over panel until the player asks for another. Previously six call sites made this
-- decision by not making it, and every one of them restarted.
local function restartOrFinish(player: Player, session: Session)
	if sessions[player] ~= session or player.Parent ~= Players then
		return
	end
	if session.autoRestart then
		startRun(player)
	else
		finishSession(player, session)
		if session.matchId == nil then
			runRemote:FireClient(player, RunProtocol.SERVER.RUN_OVER, {
				runId = session.runId,
				score = session.run.score,
				loops = session.run.loops,
			})
		end
	end
end

local reject: (Player, string) -> ()

-- A hard authoritative snapshot puts client prediction and server authority on the same tick.
-- Normal play deliberately keeps authority behind by AUTHORITY_DELAY_TICKS so a next-tick input
-- has time to cross the network before it is judged. Re-arm that gap after every paused resume;
-- otherwise the first post-upgrade press is routinely rejected as already late.
local function rearmAuthorityClock(session: Session, startAt: number?)
	session.startAt = startAt or workspace:GetServerTimeNow()
	session.clockStarted = false
	session.accumulator = 0
end

local function canRevive(session: Session, now: number): boolean
	return session.ended
		and not session.retired
		and not session.run.alive
		and session.run.loops >= MonetizationConfig.MIN_REVIVE_SKIPS
		and session.reviveExpiresAt ~= nil
		and now < (session.reviveExpiresAt :: number)
end

local function declineRevive(player: Player, runIdValue: unknown)
	local session = sessions[player]
	if not session or typeof(runIdValue) ~= "number" or runIdValue ~= session.runId then
		return reject(player, "wrong run id in DECLINE_REVIVE")
	end
	-- Not while a ticket is being taken: that write decides the run, one way or the other.
	if session.ended and not session.revivePurchasePending then
		session.reviveExpiresAt = nil
		session.shoppingRemaining = nil
		restartOrFinish(player, session)
	end
end

--[[
	Moves the end of a dead run's revive window, and arranges for the run to finish if nobody acts
	before it. Each move supersedes the last: an old deadline finds the window moved and does nothing.
	A deadline that arrives while a ticket is being taken also does nothing -- that write finishes the
	decision either way, and sets a new window if it refuses.
]]
local function holdReviveWindow(player: Player, session: Session, seconds: number): number
	local expiresAt = workspace:GetServerTimeNow() + seconds
	session.reviveExpiresAt = expiresAt
	task.delay(seconds, function()
		if sessions[player] == session and session.ended and session.reviveExpiresAt == expiresAt
			and not session.revivePurchasePending and player.Parent == Players then
			restartOrFinish(player, session)
		end
	end)
	return expiresAt
end

local function grantRevive(player: Player, session: Session)
	RunSim.revive(session.run)
	local resumeAt = workspace:GetServerTimeNow()
		+ MonetizationConfig.REVIVE_RESUME_COUNTDOWN_SECONDS
	session.ended = false
	session.paused = false
	session.offer = nil
	session.reviveExpiresAt = nil
	session.revivePurchasePending = false
	session.shoppingRemaining = nil
	-- This is the same shared-clock handshake used by GO at the beginning of a run. Sending the
	-- exact server timestamp (rather than starting independent five-second timers) keeps client
	-- prediction and delayed server authority on the same simulation tick after checkout.
	session.delayTicks = delayFor(player)
	rearmAuthorityClock(session, resumeAt)
	session.resumeDeadline = resumeAt
	session.inputDown = false
	session.lastInputTick = session.run.tick
	session.lastClientTick = session.run.tick
	session.lastQueuedDown = false
	table.clear(session.pending)
	table.clear(session.recentTransitionTicks)
	session.characterState.root.CFrame = session.characterState.baseRoot
	runRemote:FireClient(player, RunProtocol.SERVER.REVIVED, {
		runId = session.runId,
		state = RunSim.snapshot(session.run),
		startAt = resumeAt,
	})
end

--[[
	A revive costs tickets -- two since 2026-09-11 (tickets replaced the Robux
	revive on 2026-09-10). They are taken FIRST, by the store, and the run comes back only once they
	are gone -- never the other way round. While the store is asked, the run is held, so the
	five-second window cannot close underneath the write. A run that disappears, or is cut from its
	match, while its tickets are being taken gets them back.
]]
local function beginTicketRevive(player: Player, runIdValue: unknown)
	local session = sessions[player]
	local now = workspace:GetServerTimeNow()
	if not session or typeof(runIdValue) ~= "number" or runIdValue ~= session.runId
		or not canRevive(session, now) or session.revivePurchasePending then
		return reject(player, "revive is not available")
	end
	session.revivePurchasePending = true
	session.shoppingRemaining = nil
	holdReviveWindow(player, session, MonetizationConfig.REVIVE_SPEND_HOLD_SECONDS)
	task.spawn(function()
		local called, spent, why = pcall(RunServer.spendTickets, player, MonetizationConfig.REVIVE_TICKET_COST)
		if not called then
			spent, why = false, "the ticket store did not answer"
		end
		-- Gone, or cut from its match while the tickets were being taken: give them back.
		if sessions[player] ~= session or player.Parent ~= Players or not session.ended or session.retired then
			if spent then
				RunServer.refundTickets(player, MonetizationConfig.REVIVE_TICKET_COST)
			end
			return
		end
		session.revivePurchasePending = false
		if spent then
			grantRevive(player, session)
			return
		end
		-- Refused: not enough tickets, or the store did not answer. The offer stays up for the ordinary
		-- decision window, so the player can go and get a ticket or let the run go.
		local expiresAt = holdReviveWindow(player, session, MonetizationConfig.REVIVE_OFFER_SECONDS)
		runRemote:FireClient(player, RunProtocol.SERVER.REVIVE_REFUSED, {
			runId = session.runId,
			reason = why,
			expiresAt = expiresAt,
		})
	end)
end

--[[
	The player went to the ticket shop from the revive offer. THE REVIVE COUNTER PAUSES there (the
	user, 2026-09-11): it stands still on the second it had reached, and carries on from that second
	if the shop is closed without buying. The run is still held for at most REVIVE_SHOPPING_SECONDS,
	so a player who walks away from an open shop cannot hold a match open for ever.
]]
local function holdForShopping(player: Player, runIdValue: unknown)
	local session = sessions[player]
	local now = workspace:GetServerTimeNow()
	if not session or typeof(runIdValue) ~= "number" or runIdValue ~= session.runId
		or not canRevive(session, now) or session.revivePurchasePending then
		return
	end
	if session.shoppingRemaining == nil then
		session.shoppingRemaining = math.max(1, (session.reviveExpiresAt :: number) - now)
	end
	local expiresAt = holdReviveWindow(player, session, MonetizationConfig.REVIVE_SHOPPING_SECONDS)
	runRemote:FireClient(player, RunProtocol.SERVER.REVIVE_WINDOW, {
		runId = session.runId,
		expiresAt = expiresAt,
		paused = true,
		remaining = session.shoppingRemaining,
	})
end

-- The shop was closed without a ticket: the counter carries on from the second it paused on.
local function resumeAfterShopping(player: Player, runIdValue: unknown)
	local session = sessions[player]
	local now = workspace:GetServerTimeNow()
	if not session or typeof(runIdValue) ~= "number" or runIdValue ~= session.runId
		or not canRevive(session, now) or session.revivePurchasePending then
		return
	end
	local remaining = session.shoppingRemaining
	if remaining == nil then
		return
	end
	session.shoppingRemaining = nil
	local expiresAt = holdReviveWindow(player, session, remaining)
	runRemote:FireClient(player, RunProtocol.SERVER.REVIVE_WINDOW, {
		runId = session.runId,
		expiresAt = expiresAt,
	})
end

--[[
	"I have my hands back, go now."

	The five seconds after a revive were a forced wait; they are now only a BACKSTOP. The player
	taps the moment they are ready and play resumes, and if they never tap -- window unfocused,
	phone put down, still reading the receipt -- the original deadline starts the run anyway so a
	revived run can never sit frozen. In a match, frozen is the same as lost.

	The tap does not resume anything by itself. It asks the server to move the shared resume moment,
	and the server answers with the new one. Both peers must begin stepping on the same tick, so the
	new moment is one START_LEAD_SECONDS out -- the same lead the opening GO uses -- rather than
	"now", which the packet could not reach the client before.
]]
local function resumeRevivedRunNow(player: Player, runIdValue: unknown)
	local session = sessions[player]
	if not session or typeof(runIdValue) ~= "number" or runIdValue ~= session.runId then
		return reject(player, "wrong run id in RESUME_NOW")
	end
	local deadline = session.resumeDeadline
	if not deadline or session.ended or not session.run.alive or session.paused then
		return
	end

	local resumeAt = workspace:GetServerTimeNow() + RunProtocol.START_LEAD_SECONDS
	if resumeAt >= deadline then
		-- The backstop is already closer than the tap could bring it. Leave the agreed moment alone
		-- rather than pushing it later.
		return
	end
	session.resumeDeadline = resumeAt
	rearmAuthorityClock(session, resumeAt)
	runRemote:FireClient(player, RunProtocol.SERVER.RESUME_AT, {
		runId = session.runId,
		startAt = resumeAt,
	})
end

local function armRun(player: Player, runId: unknown)
	local session = sessions[player]
	if not session or session.ended or session.armed then
		return
	end
	if typeof(runId) ~= "number" or runId ~= session.runId then
		return reject(player, "wrong run id in START_ACK")
	end

	session.delayTicks = delayFor(player)
	session.startAt = workspace:GetServerTimeNow() + RunProtocol.START_LEAD_SECONDS
	session.armed = true
	runRemote:FireClient(player, RunProtocol.SERVER.GO, {
		runId = session.runId,
		startAt = session.startAt,
	})
end

reject = function(player: Player, reason: string)
	warn(string.format("[Skips] rejected input from %s: %s", player.Name, reason))
end

local function acceptInput(player: Player, runId: unknown, tickValue: unknown, downValue: unknown)
	local session = sessions[player]
	if not session or session.ended then
		return reject(player, "no live run")
	end
	if typeof(runId) ~= "number" or runId ~= session.runId then
		return reject(player, "wrong run id")
	end
	if typeof(tickValue) ~= "number" or tickValue ~= math.floor(tickValue) then
		return reject(player, "tick is not an integer")
	end
	if typeof(downValue) ~= "boolean" then
		return reject(player, "input state is not boolean")
	end

	local inputTick = tickValue :: number
	local inputDown = downValue :: boolean
	if inputTick <= session.lastClientTick then
		return reject(player, "ticks are not strictly increasing")
	end
	if inputTick > session.run.tick + RunProtocol.MAX_FUTURE_TICKS then
		return reject(player, "input is implausibly far in the future")
	end
	if inputDown == session.lastQueuedDown then
		return reject(player, "input did not change state")
	end
	if #session.pending >= RunProtocol.MAX_PENDING_INPUTS then
		return reject(player, "pending input buffer is full")
	end

	local recent = session.recentTransitionTicks
	while #recent > 0 and inputTick - recent[1] >= SimTuning.TICK_RATE do
		table.remove(recent, 1)
	end
	if #recent >= RunProtocol.MAX_TRANSITIONS_PER_SECOND then
		return reject(player, "transition rate exceeds the human-input ceiling")
	end

	--[[
		LATE, NOT LOST. A press whose tick authority had already judged used to be rejected outright,
		so a press that crossed a slow connection simply never happened: the client saw its jump, the
		server saw a player standing still, and the next snapshot put them back on the floor. It is now
		applied on the first tick still to come -- later than meant, but pressed. The ping-stretched
		delay makes this rare; this makes the rare case survivable. It hands out nothing: a press can
		only ever land at or after the tick the player stamped, never before it.
	]]
	local effectiveTick = math.max(inputTick, session.run.tick + 1, session.lastInputTick + 1)
	if effectiveTick > inputTick then
		session.lateInputs += 1
	end

	session.lastClientTick = inputTick
	session.lastInputTick = effectiveTick
	session.lastQueuedDown = inputDown
	table.insert(recent, inputTick)
	table.insert(session.pending, { tick = effectiveTick, down = inputDown })
end

local applyCard: (Player, Session, CardCatalog.Card, number, boolean) -> ()

local function beginOffer(player: Player, session: Session, upgradeRound: number)
	if session.paused or session.offer then
		return
	end
	-- Finite cards may eventually cap, but Upgrade Rocket Fuel remains repeatable forever. The
	-- catalog preserves three unique choices while it can and repeats actionable late-run choices
	-- when fewer than three definitions remain rather than ending progression.
	if CardCatalog.eligibleCount(session.stacks, session.run.stats) == 0 then
		return
	end
	-- An offer outranks a pending solo pause; the client drops its pause when the offer arrives.
	session.pauseAtTick = nil
	session.unpauseRequested = false
	session.paused = true
	session.accumulator = 0
	session.offerRound = upgradeRound
	session.offer = CardCatalog.rollOffer(session.run.rng, session.run.stats.luck, session.stacks,
		session.run.stats)
	-- Solo is the player's own run: let them read for as long as they want. In any matchmaking mode
	-- everyone else is still scoring, so the server owns a five-second auto-pick deadline.
	session.offerDeadline = if session.matchId ~= nil
		then workspace:GetServerTimeNow() + MatchTuning.CARD_DECISION_SECONDS
		else nil

	local cardIds: { string } = {}
	local stackCounts: { number } = {}
	for index, card in session.offer do
		cardIds[index] = card.id
		stackCounts[index] = session.stacks[card.id] or 0
	end
	runRemote:FireClient(player, RunProtocol.SERVER.OFFER, {
		runId = session.runId,
		round = upgradeRound,
		cardIds = cardIds,
		stackCounts = stackCounts,
		luck = session.run.stats.luck,
		deadline = session.offerDeadline,
	})
end

-- Every card request gets a terminal reply. Previously the ordinary `reject` paths only warned on
-- the server, while the client had already latched `pickPending = true`; one rejected packet could
-- therefore leave the offer visible and make every later click a no-op for the rest of the run.
local function rejectCard(player: Player, session: Session?, reason: string)
	reject(player, reason)
	if not session then
		return
	end

	local cardIds: { string } = {}
	local stackCounts: { number } = {}
	if session.offer then
		for index, card in session.offer do
			cardIds[index] = card.id
			stackCounts[index] = session.stacks[card.id] or 0
		end
	end
	runRemote:FireClient(player, RunProtocol.SERVER.CARD_REJECTED, {
		runId = session.runId,
		round = session.offerRound,
		paused = session.paused and session.offer ~= nil,
		cardIds = cardIds,
		stackCounts = stackCounts,
		luck = session.run.stats.luck,
		reason = reason,
		state = RunSim.snapshot(session.run),
	})
end

-- Applying a card, from a player's click or from the deadline expiring. Both go through here so an
-- auto-pick cannot skip a step a real pick performs -- the offer being consumed first, the input
-- edge being retired, the authority clock being re-armed. A second copy of this would be a second
-- set of rules, which is exactly what the determinism rules exist to prevent.
applyCard = function(
	player: Player,
	session: Session,
	card: CardCatalog.Card,
	oldStacks: number,
	automatic: boolean
)
	-- Consume the offer before applying its reward. A duplicated packet now finds no offer and
	-- cannot stack the same choice twice, even if future effect code starts yielding.
	session.offer = nil
	session.offerDeadline = nil
	session.stacks[card.id] = oldStacks + 1
	RunSim.applyStatEffects(session.run, card.effects)
	-- The offer opened on a rope clear, so the player is mid-air. `resumeAfterUpgrade` keeps them
	-- there — same height, same velocity, same rope phases — and retires only the hold, because
	-- both peers force the button up across a pick and the shared module is the only place that
	-- transition can be agreed on rather than inferred.
	RunSim.resumeAfterUpgrade(session.run)
	session.inputDown = false
	session.lastQueuedDown = false
	session.lastInputTick = session.run.tick
	session.lastClientTick = session.run.tick
	table.clear(session.pending)
	table.clear(session.recentTransitionTicks)
	session.paused = false
	--[[
		Both peers resume on ONE shared moment, as GO and a revive always have. The client used to
		resume the instant CARD_APPLIED arrived while authority resumed on its own clock, so the
		safety gap shrank by a whole round trip after every card -- on a slow connection, enough for
		the first press after an upgrade to arrive late and be judged as never made.
	]]
	session.delayTicks = delayFor(player)
	local resumeAt = workspace:GetServerTimeNow() + resumeLead(player)
	rearmAuthorityClock(session, resumeAt)

	runRemote:FireClient(player, RunProtocol.SERVER.CARD_APPLIED, {
		runId = session.runId,
		round = session.offerRound,
		cardId = card.id,
		stacks = session.stacks[card.id],
		automatic = automatic,
		state = RunSim.snapshot(session.run),
		startAt = resumeAt,
	})
end

--[[
	The card choice has a deadline, and the deadline is the whole point.

	A paused run is a run that has stopped scoring while everyone else's keeps going, so an
	indecisive player in a match would lose it to a menu. Rather than rushing them with a shrinking
	bar and nothing behind it, the game picks for them when the clock runs out.

	The pick uses the run's own seeded RNG, so the card the deadline chooses is reproducible from
	the replay like every other decision in the game -- an auto-pick is not a coin flip the server
	made privately.
]]
local function autoPickExpiredOffer(player: Player, session: Session, now: number)
	local offer = session.offer
	local deadline = session.offerDeadline
	if not offer or not deadline or now < deadline or session.ended or not session.run.alive then
		return
	end

	-- Only cards the player could actually have taken are candidates. Handing someone a card that
	-- would have been rejected as capped is worse than the pause.
	local takeable: { CardCatalog.Card } = {}
	for _, card in offer do
		local owned = session.stacks[card.id] or 0
		if CardCatalog.isEligible(card, session.stacks, session.run.stats) then
			table.insert(takeable, card)
		end
	end
	if #takeable == 0 then
		-- Nothing in this offer can be taken. Resume rather than strand the run behind a dead modal.
		session.offer = nil
		session.offerDeadline = nil
		session.paused = false
		rearmAuthorityClock(session)
		return rejectCard(player, session, "offer expired with no takeable card")
	end

	local card = takeable[session.run.rng:nextInt(1, #takeable)]
	applyCard(player, session, card, session.stacks[card.id] or 0, true)
end

local function chooseCard(player: Player, runId: unknown, roundValue: unknown, cardIdValue: unknown)
	local session = sessions[player]
	if not session or session.ended or not session.paused or not session.offer then
		return rejectCard(player, session, "no card offer is awaiting a pick")
	end
	if typeof(runId) ~= "number" or runId ~= session.runId then
		return rejectCard(player, session, "wrong run id in PICK_CARD")
	end
	if typeof(roundValue) ~= "number" or roundValue ~= session.offerRound then
		return rejectCard(player, session, "wrong upgrade round in PICK_CARD")
	end
	if typeof(cardIdValue) ~= "string" then
		return rejectCard(player, session, "card id is not a string")
	end

	local cardId = cardIdValue :: string
	local card = CardCatalog.resolveOfferedCard(session.offer, cardId)
	if not card then
		return rejectCard(player, session, "card was not in the stored offer")
	end
	local oldStacks = session.stacks[card.id] or 0
	if not CardCatalog.isEligible(card, session.stacks, session.run.stats) then
		return rejectCard(player, session, "card has no eligible rope or is already capped")
	end

	return applyCard(player, session, card, oldStacks, false)
end

--[[
	PAUSING, solo only. The client stops on a tick and names it; authority -- which trails by the
	delay -- keeps stepping the presses already on their way until it reaches that same tick, and
	stops there. Coming back is the revive's handshake: one shared moment, a get-ready the player can
	tap through, and the same state on both sides.
]]
local function resumeFromPause(player: Player, session: Session)
	local resumeAt = workspace:GetServerTimeNow() + RunProtocol.PAUSE_RESUME_SECONDS
	session.paused = false
	session.userPaused = false
	session.unpauseRequested = false
	session.pauseAtTick = nil
	session.delayTicks = delayFor(player)
	rearmAuthorityClock(session, resumeAt)
	session.resumeDeadline = resumeAt
	runRemote:FireClient(player, RunProtocol.SERVER.UNPAUSED, {
		runId = session.runId,
		state = RunSim.snapshot(session.run),
		startAt = resumeAt,
	})
end

local function reachPause(player: Player, session: Session)
	session.pauseAtTick = nil
	session.paused = true
	session.userPaused = true
	session.accumulator = 0
	if session.unpauseRequested then
		-- The player asked to come back before authority had even caught up to the pause.
		resumeFromPause(player, session)
	end
end

local function stepSession(player: Player, session: Session, dt: number, now: number)
	if session.ended then
		return
	end
	if not session.armed then
		return
	end
	if session.paused then
		session.accumulator = 0
		return
	end

	if not session.clockStarted then
		if now < session.startAt then
			return
		end
		session.clockStarted = true
		session.resumeDeadline = nil
		session.accumulator = now - session.startAt
			- session.delayTicks / SimTuning.TICK_RATE
	else
		session.accumulator += dt
	end

	-- `not session.paused` is load-bearing, not defensive. `beginOffer` pauses the session from
	-- inside this loop; without the check the server kept stepping the frame's remaining ticks
	-- while the client sat frozen behind the modal, so a rope could sweep — and kill the player —
	-- during a card choice they were still reading. The client's loop has always had this guard.
	local steps = 0
	while session.accumulator >= SimTuning.DT
		and steps < RunProtocol.MAX_STEPS_PER_FRAME
		and not session.paused do
		-- A solo pause stops exactly on the tick the player paused at, so both peers stand on the
		-- same frame of the same jump.
		local pauseAt = session.pauseAtTick
		if pauseAt and session.run.tick >= pauseAt then
			reachPause(player, session)
			break
		end
		session.accumulator -= SimTuning.DT
		steps += 1

		local nextTick = session.run.tick + 1
		local transition = session.pending[1]
		if transition and transition.tick == nextTick then
			session.inputDown = transition.down
			table.remove(session.pending, 1)
		elseif transition and transition.tick < nextTick then
			warn("[Skips] discarded an impossible stale buffered input")
			table.remove(session.pending, 1)
		end

		local events = session.run:step(session.inputDown)
		-- The server no longer moves the character every tick (2026-09-10). Its owner draws it from
		-- prediction, and everyone else draws a ghost from ViewService, so sixty CFrame replications a
		-- second per player were bandwidth nobody was looking at.
		if events then
			for _, event in events do
				-- Recorded so placings can say WHY a run ended: caught by a rope, or fell off the
				-- checkpoint pace. They read very differently to a player.
				if event.kind == RunSim.EVENT.DEATH then
					session.deathReason = event.reason
				end
			end
			for _, event in events do
				if event.kind == RunSim.EVENT.UPGRADE_READY and event.upgradeRound then
					beginOffer(player, session, event.upgradeRound)
					break
				end
			end
		end

		if session.run.tick % RunProtocol.SNAPSHOT_INTERVAL_TICKS == 0 then
			sendSnapshot(player, session, RunProtocol.SERVER.STATE)
		end
		if not session.run.alive then
			session.ended = true
			-- Dead, but not necessarily out: a revive may still be bought. The match keeps them in
			-- contention on their standing score until FINISHED says otherwise.
			notifyEnded(player, session)
			if session.run.loops >= MonetizationConfig.MIN_REVIVE_SKIPS then
				local expiresAt = now + MonetizationConfig.REVIVE_OFFER_SECONDS
				session.reviveExpiresAt = expiresAt
				runRemote:FireClient(player, RunProtocol.SERVER.ENDED, {
					runId = session.runId,
					state = RunSim.snapshot(session.run),
					revive = {
						expiresAt = expiresAt,
						cost = MonetizationConfig.REVIVE_TICKET_COST,
					},
				})
				task.delay(MonetizationConfig.REVIVE_OFFER_SECONDS, function()
					if sessions[player] == session
						and session.ended
						and session.reviveExpiresAt == expiresAt
						and player.Parent == Players then
						restartOrFinish(player, session)
					end
				end)
			else
				sendSnapshot(player, session, RunProtocol.SERVER.ENDED)
				task.delay(RunProtocol.RESTART_DELAY_SECONDS, function()
					if sessions[player] == session and player.Parent == Players then
						restartOrFinish(player, session)
					end
				end)
			end
			break
		end
	end
end

local function requestPause(player: Player, runIdValue: unknown, tickValue: unknown)
	local session = sessions[player]
	if not session or typeof(runIdValue) ~= "number" or runIdValue ~= session.runId then
		return reject(player, "wrong run id in PAUSE")
	end
	-- Solo only: in a match a pause would freeze your score while everyone else's keeps going, and
	-- the checkpoint clock is the whole point there. Never behind a card, a revive or a get-ready.
	if session.matchId ~= nil or session.ended or not session.run.alive or not session.armed
		or session.paused or session.offer ~= nil or session.pauseAtTick ~= nil
		or session.resumeDeadline ~= nil then
		return
	end
	if typeof(tickValue) ~= "number" or tickValue ~= math.floor(tickValue) then
		return reject(player, "pause tick is not an integer")
	end
	local tick = tickValue :: number
	if tick > session.run.tick + RunProtocol.MAX_FUTURE_TICKS then
		return reject(player, "pause tick is implausibly far in the future")
	end
	-- A client somehow behind authority pauses where authority already is; UNPAUSED hands it that
	-- exact state, so the two still come back from one frame.
	session.pauseAtTick = math.max(tick, session.run.tick)
end

local function requestUnpause(player: Player, runIdValue: unknown)
	local session = sessions[player]
	if not session or typeof(runIdValue) ~= "number" or runIdValue ~= session.runId then
		return reject(player, "wrong run id in UNPAUSE")
	end
	if session.userPaused then
		resumeFromPause(player, session)
	elseif session.pauseAtTick then
		session.unpauseRequested = true
	end
end

--[[
	A finished solo run starts again only when the player asks. The user's call (2026-09-10): losing
	in solo should not throw you straight into the next run. Taking NEW RUN during the revive offer
	arrives here too, and declines it.
]]
local function playAgain(player: Player, runIdValue: unknown)
	local session = sessions[player]
	if session then
		if typeof(runIdValue) ~= "number" or runIdValue ~= session.runId then
			return reject(player, "wrong run id in PLAY_AGAIN")
		end
		-- Matches restart through MatchService, a live run cannot be thrown away from here, and a run
		-- with a purchase in flight is held until the receipt resolves.
		if session.matchId ~= nil or not session.ended or session.revivePurchasePending then
			return
		end
		session.reviveExpiresAt = nil
		session.shoppingRemaining = nil
		finishSession(player, session)
	end
	startRun(player)
end

local function prepareCharacter(player: Player, character: Model)
	if not player:HasAppearanceLoaded() then
		player.CharacterAppearanceLoaded:Wait()
	end
	if character ~= player.Character then
		return
	end

	local root, rootToFeet = AvatarNormalizer.prepare(character)
	local laneIndex = laneIndices[player]
	if not laneIndex then
		laneIndex = nextLaneIndex
		nextLaneIndex += 1
		laneIndices[player] = laneIndex
	end

	local state: CharacterState = {
		character = character,
		root = root,
		baseRoot = root.CFrame,
		groundPosition = groundForLane(laneIndex),
	}
	putAtGround(state, rootToFeet)
	characters[player] = state
	if ready[player] then
		startRun(player)
	end
end

local function attachPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		-- Respawning abandons the run. Tell the match before the session is dropped, or it waits
		-- forever for a competitor who is no longer there.
		local previous = sessions[player]
		if previous then
			finishSession(player, previous)
		end
		sessions[player] = nil
		characters[player] = nil
		task.spawn(prepareCharacter, player, character)
	end)
	if player.Character then
		task.spawn(prepareCharacter, player, player.Character)
	end
end

--[[
	What a match is allowed to know about a run.

	A summary rather than the Session itself: a match should be able to rank players and draw a
	scoreboard without reaching into input buffers or rope schedules. Keeping this seam narrow is
	what stops match code from quietly becoming a second set of run rules.
]]
export type RunSummary = {
	runId: number,
	matchId: string?,
	score: number,
	loops: number,
	tick: number,
	alive: boolean,
	ended: boolean,
	finished: boolean,
	paused: boolean,
	deathReason: string?,
}

function RunServer.summaryOf(player: Player): RunSummary?
	local session = sessions[player]
	if not session then
		return nil
	end
	return {
		runId = session.runId,
		matchId = session.matchId,
		score = session.run.score,
		loops = session.run.loops,
		tick = session.run.tick,
		alive = session.run.alive,
		ended = session.ended,
		finished = session.finished,
		paused = session.paused,
		deathReason = session.deathReason,
	}
end

--[[
	The one way a match ends a player's run: the per-minute cut, or the match being decided while they
	were still running (MatchService). The run stops where it stands (`RunSim.retire`), no revive can
	follow, and the player is told why. A run that was already dead -- sitting in its revive offer --
	keeps the rope as its reason and simply loses the offer. Returns whether there was a run to end.
]]
function RunServer.retireFromMatch(player: Player, cut: boolean): boolean
	local session = sessions[player]
	if not session or session.matchId == nil or session.finished then
		return false
	end
	local wasRunning = session.run.alive
	if wasRunning then
		RunSim.retire(session.run)
		session.deathReason = if cut then RunSim.DEATH_REASON.CUT else RunSim.DEATH_REASON.MATCH_OVER
	end
	session.retired = true
	session.ended = true
	session.paused = false
	session.offer = nil
	session.offerDeadline = nil
	session.pauseAtTick = nil
	session.resumeDeadline = nil
	session.reviveExpiresAt = nil
	session.shoppingRemaining = nil
	if player.Parent == Players then
		runRemote:FireClient(player, RunProtocol.SERVER.ENDED, {
			runId = session.runId,
			state = RunSim.snapshot(session.run),
			reason = session.deathReason,
			retired = true,
		})
	end
	if wasRunning then
		notifyEnded(player, session)
	end
	finishSession(player, session)
	return true
end

-- Start a run on a match's terms. Returns false when the player has no prepared character yet, so
-- a match can wait for them rather than assuming the run began.
function RunServer.startRunFor(player: Player, options: RunOptions): boolean
	startRun(player, options)
	local session = sessions[player]
	return session ~= nil and session.matchId == options.matchId
end

function RunServer.isPlayable(player: Player): boolean
	return characters[player] ~= nil and ready[player] == true
end

-- What an onlooker may see of this player's run (ViewService). Nil until the run is armed.
function RunServer.viewOf(player: Player): RunView.View?
	local session = sessions[player]
	if not session or not session.armed then
		return nil
	end
	return RunView.of(session.run)
end

function RunServer.start()
	StarterPlayer.AutoJumpEnabled = false

	for _, player in Players:GetPlayers() do
		attachPlayer(player)
	end
	Players.PlayerAdded:Connect(attachPlayer)
	Players.PlayerRemoving:Connect(function(player)
		local leaving = sessions[player]
		if leaving then
			finishSession(player, leaving)
		end
		sessions[player] = nil
		characters[player] = nil
		ready[player] = nil
		runSerials[player] = nil
		laneIndices[player] = nil
	end)

	runRemote.OnServerEvent:Connect(function(player, op, a, b, c)
		if op == RunProtocol.CLIENT.READY then
			ready[player] = true
			if characters[player] and not sessions[player] then
				startRun(player)
			end
		elseif op == RunProtocol.CLIENT.START_ACK then
			armRun(player, a)
		elseif op == RunProtocol.CLIENT.INPUT then
			acceptInput(player, a, b, c)
		elseif op == RunProtocol.CLIENT.PICK_CARD then
			chooseCard(player, a, b, c)
		elseif op == RunProtocol.CLIENT.REQUEST_REVIVE then
			beginTicketRevive(player, a)
		elseif op == RunProtocol.CLIENT.REVIVE_SHOPPING then
			holdForShopping(player, a)
		elseif op == RunProtocol.CLIENT.REVIVE_SHOP_CLOSED then
			resumeAfterShopping(player, a)
		elseif op == RunProtocol.CLIENT.DECLINE_REVIVE then
			declineRevive(player, a)
		elseif op == RunProtocol.CLIENT.RESUME_NOW then
			resumeRevivedRunNow(player, a)
		elseif op == RunProtocol.CLIENT.PLAY_AGAIN then
			playAgain(player, a)
		elseif op == RunProtocol.CLIENT.PAUSE then
			requestPause(player, a, b)
		elseif op == RunProtocol.CLIENT.UNPAUSE then
			requestUnpause(player, a)
		end
	end)

	-- Fast, repeatable playtest setup. This RemoteEvent never exists in a live server; it lets
	-- Studio exercise card clicks, the paid-revive presentation and the grant itself without
	-- playing ten perfect skips -- or spending Robux -- before every regression check.
	if RunService:IsStudio() then
		local studioTest = remoteFolder:FindFirstChild("StudioTest")
		if not studioTest then
			studioTest = Instance.new("RemoteEvent")
			studioTest.Name = "StudioTest"
			studioTest.Parent = remoteFolder
		end
		assert(studioTest:IsA("RemoteEvent"))
		studioTest.OnServerEvent:Connect(function(player, op)
			local session = sessions[player]
			if not session then return end
			if op == "FORCE_OFFER" and not session.ended and not session.paused then
				session.run.upgradeRound += 1
				beginOffer(player, session, session.run.upgradeRound)
			elseif op == "FORCE_GRANT" and session.ended and not session.run.alive then
				-- Exactly what a granted receipt does, minus the receipt. `ProcessReceipt` is the
				-- only path that may grant a paid revive, and it is also the only path that costs
				-- real Robux -- Roblox has no sandbox currency, so without this hook the revive
				-- logic could only ever be exercised by buying it. This calls the same function
				-- the receipt callback calls, so what it proves is the real grant, not a mock of
				-- one. Studio-only, like its neighbours: it cannot exist on a live server.
				grantRevive(player, session)
			elseif op == "FORCE_REVIVE" and not session.ended then
				session.run.loops = math.max(session.run.loops, MonetizationConfig.MIN_REVIVE_SKIPS)
				session.run.score = math.max(session.run.score, session.run.loops)
				session.run.alive = false
				session.ended = true
				local expiresAt = workspace:GetServerTimeNow() + MonetizationConfig.REVIVE_OFFER_SECONDS
				session.reviveExpiresAt = expiresAt
				runRemote:FireClient(player, RunProtocol.SERVER.ENDED, {
					runId = session.runId,
					state = RunSim.snapshot(session.run),
					revive = {
						expiresAt = expiresAt,
						cost = MonetizationConfig.REVIVE_TICKET_COST,
					},
				})
			end
		end)
	end

	RunService.Heartbeat:Connect(function(dt)
		local now = workspace:GetServerTimeNow()
		for player, session in sessions do
			-- Before stepping: a paused session is one `stepSession` returns straight out of, so the
			-- card deadline has to be judged here or an expired offer would never resolve.
			autoPickExpiredOffer(player, session, now)
			stepSession(player, session, dt, now)
		end

		-- Every few seconds each player hears how their connection looks, so a high ping is named on
		-- the HUD rather than felt as a game that eats jumps.
		netClock += dt
		if netClock >= RunProtocol.NET_REPORT_SECONDS then
			netClock = 0
			for player, session in sessions do
				if player.Parent == Players then
					runRemote:FireClient(player, RunProtocol.SERVER.NET, {
						pingMs = math.floor(pingOf(player) * 1000 + 0.5),
						delayTicks = session.delayTicks,
						lateInputs = session.lateInputs,
					})
				end
			end
		end
	end)
end

return RunServer
