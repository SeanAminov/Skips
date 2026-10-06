--!strict
--[[
	Stage 2 client: predict RunSim at a fixed 60 Hz, render its state, and pause when an upgrade is ready for the
	server's three-card offer. Mouse/touch chooses the card actually clicked; keyboard/gamepad takes
	the currently selected first card. Frame delta only fills clocks outside the simulation.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")

local player = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardCatalog = require(Shared:WaitForChild("CardCatalog"))
local MonetizationConfig = require(Shared:WaitForChild("MonetizationConfig"))
local RunProtocol = require(Shared:WaitForChild("RunProtocol"))
local RunSim = require(Shared:WaitForChild("RunSim"))
local SimTuning = require(Shared:WaitForChild("SimTuning"))
local PlayerProtocol = require(Shared:WaitForChild("PlayerProtocol"))
local InputController = require(script.Parent:WaitForChild("InputController"))
local AudioPresenter = require(script.Parent:WaitForChild("AudioPresenter"))
local RunPresenter = require(script.Parent:WaitForChild("RunPresenter"))
-- Required for its side effects: it owns the match remote and its own ScreenGui. Deleting this
-- line must leave a playable solo game behind.
require(script.Parent:WaitForChild("MatchClient"))
require(script.Parent:WaitForChild("LeaderboardClient"))
require(script.Parent:WaitForChild("DistractionClient"))
local TicketClient = require(script.Parent:WaitForChild("TicketClient"))
local SettingsClient = require(script.Parent:WaitForChild("SettingsClient"))
local StageView = require(script.Parent:WaitForChild("StageView"))
local SplatClient = require(script.Parent:WaitForChild("SplatClient"))
require(script.Parent:WaitForChild("CosmeticsClient"))
require(script.Parent:WaitForChild("CommunityClient"))

type InputTransition = { tick: number, down: boolean }
type Session = {
	runId: number,
	run: RunSim.Run,
	startAt: number,
	started: boolean,
	resumeCountdown: boolean,
	resumeRequested: boolean,
	accumulator: number,
	inputDown: boolean,
	lastInputTick: number,
	nextInputIndex: number,
	inputs: { InputTransition },
	digests: { [number]: number },
	previousY: number,
	paused: boolean,
	offerCards: { CardCatalog.Card }?,
	offerRound: number,
	offerDeadline: number?,
	pickPending: boolean,
	suppressUntilRelease: boolean,
	reviveExpiresAt: number?,
	purchasePending: boolean,
	inMatch: boolean,
	-- The upgrade round this client paused for on its own prediction; nil once the offer arrives.
	awaitingRound: number?,
	userPaused: boolean,
	unpauseRequested: boolean,
	lastSentDown: boolean,
	runOver: boolean,
	runOverAt: number,
	playAgainRequested: boolean,
	-- Sent to the ticket shop by the revive offer; a ticket arriving revives at once.
	wantsRevive: boolean,
	-- In that shop the revive counter stands still on this many seconds (RunServer.holdForShopping).
	revivePausedRemaining: number?,
	-- Prediction and authority can both discover the same death; the cue plays exactly once.
	deathSoundPlayed: boolean,
}

StarterPlayer.AutoJumpEnabled = false
task.spawn(function()
	local playerScripts = player:WaitForChild("PlayerScripts")
	local playerModule = playerScripts:WaitForChild("PlayerModule", 2)
	if not playerModule then
		-- Some Studio/player configurations omit the default movement stack entirely. In that case
		-- there is nothing to disable, and waiting forever only produces a misleading warning.
		return
	end
	local ok, moduleValue = pcall(require, playerModule)
	if ok then
		local controls = (moduleValue :: any):GetControls()
		controls:Disable()
	else
		warn("[Skips] could not disable PlayerModule controls: " .. tostring(moduleValue))
	end
end)

local remoteFolder = ReplicatedStorage:WaitForChild(RunProtocol.REMOTE_FOLDER)
local runRemote = remoteFolder:WaitForChild(RunProtocol.REMOTE_NAME) :: RemoteEvent
local presenter = RunPresenter.new()
local audio = AudioPresenter.new()
local stage = StageView.new()
local session: Session? = nil
local inputController: InputController.InputController
local bestScore = 0
-- What the server last said about this connection (its NET report). Used only to rebuild the
-- prediction lead after an unusual resync, never to judge anything.
local netDelayTicks = RunProtocol.AUTHORITY_DELAY_TICKS
local netPingSeconds = 0.1
-- The press that loses a run must not also skip straight past its result.
local RUN_OVER_LOCKOUT_SECONDS = 0.9
local reviveCost = MonetizationConfig.REVIVE_TICKET_COST
local playerRemote = remoteFolder:WaitForChild(PlayerProtocol.REMOTE_NAME) :: RemoteEvent
-- The PRESS • HOLD • RELEASE hint is for first-time players only: gone for good after their first ten
-- seconds of actual jumping, and remembered on the account (PlayerDataService).
local tutorialDone = player:GetAttribute(PlayerProtocol.ATTRIBUTE.TUTORIAL_DONE) == true
local tutorialTicks = 0

local function playDeathCue(active: Session)
	if active.deathSoundPlayed then
		return
	end
	active.deathSoundPlayed = true
	audio:play("SWEEP")
	audio:play("MISS")
end

local function sendRunInput(active: Session, down: boolean)
	local inputTick = math.max(active.run.tick + 1, active.lastInputTick + 1)
	active.lastInputTick = inputTick
	active.lastSentDown = down
	table.insert(active.inputs, { tick = inputTick, down = down })
	runRemote:FireServer(RunProtocol.CLIENT.INPUT, active.runId, inputTick, down)
end

local function chooseOfferIndex(index: number)
	local active = session
	if not active or not active.run.alive or not active.paused or not active.offerCards
		or active.pickPending then
		return
	end
	local card = active.offerCards[index]
	if not card then
		return
	end
	active.pickPending = true
	active.suppressUntilRelease = true
	runRemote:FireServer(
		RunProtocol.CLIENT.PICK_CARD,
		active.runId,
		active.offerRound,
		card.id
	)
end

local function isPointerInput(source: InputObject?): boolean
	return source ~= nil and (source.UserInputType == Enum.UserInputType.MouseButton1
		or source.UserInputType == Enum.UserInputType.Touch)
end

-- The run-over panel and the revive offer's NEW RUN both come here. Asked once: the server owns
-- when the next run starts, and a mashed button must not queue three of them.
local function requestPlayAgain(active: Session)
	if active.playAgainRequested then
		return
	end
	active.playAgainRequested = true
	presenter:hideRunOver()
	runRemote:FireServer(RunProtocol.CLIENT.PLAY_AGAIN, active.runId)
end

local function handleLogicalInput(down: boolean, source: InputObject?)
	local active = session
	if not active then
		return
	end
	if not active.run.alive then
		-- A finished solo run starts again on a key or pad press after a short beat. A pointer has to
		-- use the PLAY AGAIN button: tapping VS or TOP on the result must not also start a run.
		if down and active.runOver and not isPointerInput(source)
			and os.clock() - active.runOverAt >= RUN_OVER_LOCKOUT_SECONDS then
			requestPlayAgain(active)
		end
		return
	end
	if active.userPaused then
		-- Paused: only the RESUME button brings the run back, so a stray press cannot.
		return
	end
	if active.resumeCountdown then
		-- Do not turn the checkout-closing click (or an impatient held key) into an automatic jump
		-- on the first resumed tick. A held input must be released before play accepts it again.
		if down then
			active.suppressUntilRelease = true
			-- The same press is also the "I'm ready" tap. Asked once: the server owns the resume
			-- moment, and spamming the button must not spam the remote.
			if not active.resumeRequested then
				active.resumeRequested = true
				runRemote:FireServer(RunProtocol.CLIENT.RESUME_NOW, active.runId)
			end
		elseif active.suppressUntilRelease then
			active.suppressUntilRelease = false
		end
		return
	end
	if active.paused then
		if down and isPointerInput(source) then
			-- An ImageButton owns pointer selection. Consuming the global pointer press here prevents
			-- InputBegan from choosing the old keyboard highlight before Activated identifies the card.
			active.suppressUntilRelease = true
		elseif down then
			chooseOfferIndex(presenter:getOfferIndex())
		elseif not down then
			active.suppressUntilRelease = false
		end
		return
	end
	if active.suppressUntilRelease then
		if not down then
			active.suppressUntilRelease = false
			if active.inputDown then
				sendRunInput(active, false)
			end
		end
		return
	end
	sendRunInput(active, down)
end

-- Solo only, and only while actually running: never behind a card, a revive or a get-ready.
local function canPause(active: Session): boolean
	return not active.inMatch and active.started and active.run.alive and not active.paused
		and not active.resumeCountdown and not active.runOver
end

local function requestPause()
	local active = session
	if not active or not canPause(active) then
		return
	end
	active.userPaused = true
	active.paused = true
	active.accumulator = 0
	local pauseTick = active.run.tick
	-- Pausing mid-hold ends the hold, exactly as picking a card does. The release is stamped for the
	-- first tick after the pause, so both peers apply it on the same frame once play resumes.
	if active.lastSentDown then
		sendRunInput(active, false)
	end
	runRemote:FireServer(RunProtocol.CLIENT.PAUSE, active.runId, pauseTick)
	presenter:showPaused()
end

local function requestResume()
	local active = session
	if not active or not active.userPaused or active.unpauseRequested then
		return
	end
	active.unpauseRequested = true
	presenter:setPausedStatus("GET READY…")
	runRemote:FireServer(RunProtocol.CLIENT.UNPAUSE, active.runId)
end

inputController = InputController.new(handleLogicalInput)
presenter:setOfferChosenCallback(chooseOfferIndex)
presenter:setPauseCallbacks(requestPause, requestResume)
presenter:setPlayAgainCallback(function()
	local active = session
	if active and active.runOver then
		requestPlayAgain(active)
	end
end)

-- A revive costs tickets (two), taken by the server before the run comes back (RunServer).
local function requestTicketRevive(active: Session)
	if active.purchasePending then
		return
	end
	active.purchasePending = true
	active.wantsRevive = false
	presenter:setReviveStatus("REVIVING…")
	runRemote:FireServer(RunProtocol.CLIENT.REQUEST_REVIVE, active.runId)
end

presenter:setReviveCallbacks(function()
	local active = session
	if not active or active.run.alive or not active.reviveExpiresAt
		or workspace:GetServerTimeNow() >= active.reviveExpiresAt or active.purchasePending then
		return
	end
	if TicketClient.balance() >= reviveCost then
		requestTicketRevive(active)
		return
	end
	-- No ticket: straight to the shop (the user: revive "takes us to buy credits page and then use"),
	-- with the run held while they buy. The ticket arriving revives at once; closing the shop lets the
	-- run go.
	active.wantsRevive = true
	runRemote:FireServer(RunProtocol.CLIENT.REVIVE_SHOPPING, active.runId)
	presenter:setReviveStatus(string.format("COUNTDOWN PAUSED  •  GET %d MORE 🎟",
		math.max(1, reviveCost - TicketClient.balance())))
	TicketClient.openShop("REVIVE")
end, function()
	-- NEW RUN in solo skips the offer and starts the next run in one press; a match has no next run
	-- to start, so there the same button declines and the player watches the rest.
	local active = session
	if not active or active.run.alive or active.purchasePending then return end
	presenter:hideRevive()
	audio:resetCountdown()
	if active.inMatch then
		runRemote:FireServer(RunProtocol.CLIENT.DECLINE_REVIVE, active.runId)
	else
		requestPlayAgain(active)
	end
end, function()
	-- The corner X: no revive, and no new run yet either. Solo lands on the run-over panel.
	local active = session
	if not active or active.run.alive or active.purchasePending then return end
	presenter:hideRevive()
	audio:resetCountdown()
	runRemote:FireServer(RunProtocol.CLIENT.DECLINE_REVIVE, active.runId)
end)

-- A ticket landing while a revive waits on it: close the shop and revive, in that order.
player:GetAttributeChangedSignal(PlayerProtocol.ATTRIBUTE.TICKETS):Connect(function()
	local active = session
	if not active then
		return
	end
	if active.reviveExpiresAt and not active.purchasePending then
		presenter:setReviveBalance(TicketClient.balance())
	end
	if active.wantsRevive and not active.run.alive and TicketClient.balance() >= reviveCost then
		TicketClient.closeShop()
		requestTicketRevive(active)
	end
end)

-- Closing the shop without the tickets carries the paused revive countdown on from where it stopped
-- (the user, 2026-09-11). The offer is still there; NEW RUN or the X is how to say no.
TicketClient.onShopClosed(function()
	local active = session
	if not active or not active.wantsRevive or active.run.alive or active.purchasePending then
		return
	end
	active.wantsRevive = false
	runRemote:FireServer(RunProtocol.CLIENT.REVIVE_SHOP_CLOSED, active.runId)
	presenter:setReviveBalance(TicketClient.balance())
end)

-- Settings are presentation only: they set how loud, how pretty and who else is drawn, never how the
-- run plays.
local appliedLowGraphics: boolean? = nil
local appliedHideOthers: boolean? = nil
SettingsClient.onChanged(function(level: number, lowGraphics: boolean, hideOthers: boolean)
	audio:setVolume(level)
	-- A sound-slider drag can report many volume previews. Do not reparent the entire far-scenery
	-- set or reapply the lane filter for every percentage point when those two settings did not move.
	if lowGraphics ~= appliedLowGraphics then
		appliedLowGraphics = lowGraphics
		presenter:setLowGraphics(lowGraphics)
	end
	if hideOthers ~= appliedHideOthers then
		appliedHideOthers = hideOthers
		stage:setHideOthers(hideOthers)
	end
end)

presenter:setHintEnabled(not tutorialDone)
player:GetAttributeChangedSignal(PlayerProtocol.ATTRIBUTE.TUTORIAL_DONE):Connect(function()
	if player:GetAttribute(PlayerProtocol.ATTRIBUTE.TUTORIAL_DONE) == true and not tutorialDone then
		tutorialDone = true
		presenter:setHintEnabled(false)
	end
end)

local function stepPredicted(active: Session)
	if not tutorialDone then
		tutorialTicks += 1
		if tutorialTicks >= PlayerProtocol.TUTORIAL_TICKS then
			tutorialDone = true
			presenter:setHintEnabled(false)
			playerRemote:FireServer(PlayerProtocol.CLIENT.TUTORIAL_DONE)
		end
	end
	local nextTick = active.run.tick + 1
	while active.nextInputIndex <= #active.inputs do
		local transition = active.inputs[active.nextInputIndex]
		if transition.tick > nextTick then
			break
		end
		if transition.tick == nextTick then
			active.inputDown = transition.down
		end
		active.nextInputIndex += 1
	end

	active.previousY = active.run.y
	local events = active.run:step(active.inputDown)
	active.digests[active.run.tick] = active.run.digest
	if RunService:IsStudio() then
		presenter.gui:SetAttribute("PredictedTick", active.run.tick)
		presenter.gui:SetAttribute("PredictedDigest", active.run.digest)
	end
	if events then
		for _, event in events do
			if event.kind == RunSim.EVENT.JUMP then
				if RunService:IsStudio() then
					presenter.gui:SetAttribute("LastJumpTick", event.tick)
				end
				audio:play("JUMP")
			elseif event.kind == RunSim.EVENT.LOOP then
				audio:play("SWEEP")
				audio:play("CLEAR", ((event.ropeIndex or 1) - 1) * 0.04)
				if event.lucky then
					audio:play("CARD", 0.2)
					presenter:showLucky(event.points or 0)
				end
			elseif event.kind == RunSim.EVENT.ROPE_REINFORCED then
				audio:play("SWEEP")
				audio:play("CARD", -0.18)
			elseif event.kind == RunSim.EVENT.DEATH then
				playDeathCue(active)
			elseif event.kind == RunSim.EVENT.UPGRADE_READY then
				audio:play("UPGRADE")
			end
		end
	end
	if not active.run.alive then
		presenter.setEnded(presenter, active.run.loops)
	elseif events then
		for _, event in events do
			if event.kind == RunSim.EVENT.UPGRADE_READY then
				active.paused = true
				active.awaitingRound = event.upgradeRound
				active.accumulator = 0
				presenter:waitingForOffer()
				break
			end
		end
	end
end

local function replaceWithAuthority(active: Session, snapshot: RunSim.Snapshot)
	active.run = RunSim.fromSnapshot(snapshot)
	active.inputDown = active.run.wasDown
	active.previousY = active.run.y
	table.clear(active.digests)
	local inputIndex = 1
	while inputIndex <= #active.inputs and active.inputs[inputIndex].tick <= snapshot.tick do
		inputIndex += 1
	end
	active.nextInputIndex = inputIndex
end

local function rebuildFrom(active: Session, snapshot: RunSim.Snapshot)
	local targetTick = active.run.tick
	local rebuilt = RunSim.fromSnapshot(snapshot)
	local down = rebuilt.wasDown
	local inputIndex = 1
	while inputIndex <= #active.inputs and active.inputs[inputIndex].tick <= snapshot.tick do
		inputIndex += 1
	end

	table.clear(active.digests)
	for tick = snapshot.tick + 1, targetTick do
		while inputIndex <= #active.inputs and active.inputs[inputIndex].tick == tick do
			down = active.inputs[inputIndex].down
			inputIndex += 1
		end
		rebuilt:step(down)
		active.digests[rebuilt.tick] = rebuilt.digest
		if not rebuilt.alive then
			break
		end
	end

	active.run = rebuilt
	active.inputDown = rebuilt.wasDown
	active.nextInputIndex = inputIndex
	active.previousY = rebuilt.y
end

--[[
	Restores prediction's lead over authority after this client sat still.

	The client normally runs a whole authority delay ahead of the server. While it waits behind a
	pause its clock stops, so when it lets go it would otherwise run level with authority -- and every
	press after that would arrive already late.
]]
local function restoreLead(active: Session, authorityTick: number)
	local lead = netDelayTicks + netPingSeconds * 0.5 * SimTuning.TICK_RATE
	active.accumulator = math.max(0, (authorityTick + lead - active.run.tick) / SimTuning.TICK_RATE)
end

--[[
	THE "STUCK IN THE FLOOR" BUG.

	The client pauses the moment it predicts an upgrade and waits for the server's offer. If
	authority's run had parted from the prediction just before -- almost always a press that reached
	the server too late to count -- the server never reaches that upgrade, no offer ever comes, and
	the client sat paused for good: every press swallowed, the avatar standing on the floor while
	authority's snapshots swung the rope through it. Now, the moment authority shows it will not offer
	that upgrade, the client lets go and carries on from authority's run.
]]
local function releaseStaleUpgradePause(active: Session, authorityTick: number)
	local round = active.awaitingRound
	if not active.paused or active.offerCards ~= nil or round == nil or active.userPaused then
		return
	end
	if active.run.upgradeRound >= round then
		return
	end
	active.paused = false
	active.awaitingRound = nil
	presenter:hideOffer()
	restoreLead(active, authorityTick)
end

local function reconcile(active: Session, snapshot: RunSim.Snapshot)
	if snapshot.tick > active.run.tick then
		warn(string.format(
			"[Skips] authority reached tick %d before prediction tick %d",
			snapshot.tick,
			active.run.tick
		))
		active.run = RunSim.fromSnapshot(snapshot)
		active.inputDown = active.run.wasDown
		active.previousY = active.run.y
		releaseStaleUpgradePause(active, snapshot.tick)
		return
	end

	local predictedDigest = if snapshot.tick == active.run.tick
		then active.run.digest
		else active.digests[snapshot.tick]
	if predictedDigest and predictedDigest ~= snapshot.digest then
		warn(string.format(
			"[Skips] prediction diverged at tick %d (client %d, server %d); replaying authority",
			snapshot.tick,
			predictedDigest,
			snapshot.digest
		))
		rebuildFrom(active, snapshot)
		releaseStaleUpgradePause(active, snapshot.tick)
	end

	for tick in active.digests do
		if tick <= snapshot.tick then
			active.digests[tick] = nil
		end
	end
end

runRemote.OnClientEvent:Connect(function(op, payload)
	if typeof(payload) ~= "table" then
		return
	end
	local data = payload :: any
	if op == RunProtocol.SERVER.START then
		if typeof(data.runId) ~= "number"
			or typeof(data.seed) ~= "number"
			or typeof(data.baseRoot) ~= "CFrame"
			or typeof(data.groundPosition) ~= "Vector3" then
			warn("[Skips] ignored malformed START packet")
			return
		end

		session = {
			runId = data.runId,
			run = RunSim.new(data.seed, nil, data.checkpointSet),
			startAt = math.huge,
			started = false,
			resumeCountdown = false,
			resumeRequested = false,
			accumulator = 0,
			inputDown = false,
			lastInputTick = 0,
			nextInputIndex = 1,
			inputs = {},
			digests = {},
			previousY = 0,
			paused = false,
			offerCards = nil,
			offerRound = 0,
			offerDeadline = nil,
			pickPending = false,
			suppressUntilRelease = false,
			reviveExpiresAt = nil,
			purchasePending = false,
			inMatch = data.inMatch == true,
			awaitingRound = nil,
			userPaused = false,
			unpauseRequested = false,
			lastSentDown = false,
			runOver = false,
			runOverAt = 0,
			playAgainRequested = false,
			wantsRevive = false,
			revivePausedRemaining = nil,
			deathSoundPlayed = false,
		}
		audio:resetCountdown()
		presenter.beginRun(presenter, data.baseRoot, data.groundPosition)
		presenter:setReviveMode(data.inMatch == true)
		presenter:hidePaused()
		if inputController:isDown() then
			handleLogicalInput(true)
		end
		runRemote:FireServer(RunProtocol.CLIENT.START_ACK, data.runId)
	elseif op == RunProtocol.SERVER.GO then
		local active = session
		if not active or data.runId ~= active.runId or typeof(data.startAt) ~= "number" then
			return
		end
		active.startAt = data.startAt
	elseif op == RunProtocol.SERVER.OFFER then
		local active = session
		if not active
			or data.runId ~= active.runId
			or typeof(data.round) ~= "number"
			or typeof(data.cardIds) ~= "table"
			or typeof(data.stackCounts) ~= "table"
			or typeof(data.luck) ~= "number" then
			return
		end
		local cards: { CardCatalog.Card } = {}
		for index = 1, 3 do
			local cardId = data.cardIds[index]
			local card = if typeof(cardId) == "string" then CardCatalog.get(cardId) else nil
			if not card then
				warn("[Skips] ignored malformed card offer")
				return
			end
			cards[index] = card
		end
		active.paused = true
		active.accumulator = 0
		active.offerCards = cards
		-- An offer outranks a pause: the server dropped its pending pause when it offered.
		active.userPaused = false
		active.unpauseRequested = false
		active.awaitingRound = nil
		presenter:hidePaused()
		active.offerRound = data.round
			active.offerDeadline = if typeof(data.deadline) == "number" then data.deadline else nil
		active.pickPending = false
		presenter:showOffer(cards, data.stackCounts, data.luck)
		presenter:setOfferDeadline(if active.offerDeadline
			then active.offerDeadline - workspace:GetServerTimeNow()
			else nil)
	elseif op == RunProtocol.SERVER.CARD_APPLIED then
		local active = session
		if not active or data.runId ~= active.runId or typeof(data.state) ~= "table" then
			return
		end
		-- Clear the click latch before decoding the snapshot. Even a malformed reply must leave the
		-- visible offer clickable instead of turning one protocol error into a permanent soft-lock.
		active.pickPending = false
		local ok, message = pcall(replaceWithAuthority, active, data.state)
		if not ok then
			warn("[Skips] ignored malformed applied-card snapshot: " .. tostring(message))
			return
		end
		active.paused = false
		active.accumulator = 0
		active.offerCards = nil
		active.awaitingRound = nil
		-- The server deliberately discarded every pre-offer transition. Mirror that reset instead of
		-- replaying a queued mouse-up or scheduling the next press behind a stale future tick.
		active.inputs = {}
		active.nextInputIndex = 1
		active.lastInputTick = active.run.tick
		active.offerDeadline = nil
		presenter:hideOffer()
		audio:play("CARD")
		presenter.gui:SetAttribute("LastCardPick", "APPLIED")
		inputController:reset()
		active.inputDown = false
		active.suppressUntilRelease = false
		if typeof(data.startAt) == "number" then
			-- Resume on the server's shared moment, not on arrival: see RunServer's applyCard.
			active.started = false
			active.startAt = data.startAt
		end
	elseif op == RunProtocol.SERVER.CARD_REJECTED then
		local active = session
		if not active or data.runId ~= active.runId then
			return
		end
		active.pickPending = false
		active.suppressUntilRelease = inputController:isDown()
		presenter.gui:SetAttribute("LastCardPick", "REJECTED")
		presenter.gui:SetAttribute("LastCardRejectReason", tostring(data.reason or "unknown"))

		-- A rejection is also a tiny authoritative resync. Normally the same offer is still pending,
		-- so the player can immediately click again. If the server has already resumed, remove a
		-- stale client overlay and restore its snapshot instead of trapping the player behind it.
		if data.paused == false and typeof(data.state) == "table" then
			local ok, message = pcall(replaceWithAuthority, active, data.state)
			if not ok then
				warn("[Skips] ignored malformed rejected-card snapshot: " .. tostring(message))
				return
			end
			active.paused = false
			active.offerCards = nil
			active.accumulator = 0
			active.offerDeadline = nil
			presenter:hideOffer()
		else
			active.paused = true
			active.accumulator = 0
		end
	elseif op == RunProtocol.SERVER.REVIVE_WINDOW then
		local active = session
		if active and data.runId == active.runId and typeof(data.expiresAt) == "number" then
			active.reviveExpiresAt = data.expiresAt
			-- In the ticket shop the counter stands still; closing it lets the counter carry on.
			active.revivePausedRemaining = if data.paused == true and typeof(data.remaining) == "number"
				then data.remaining
				else nil
		end
	elseif op == RunProtocol.SERVER.REVIVE_REFUSED then
		local active = session
		if not active or data.runId ~= active.runId then
			return
		end
		active.purchasePending = false
		active.revivePausedRemaining = nil
		if typeof(data.expiresAt) == "number" then
			active.reviveExpiresAt = data.expiresAt
		end
		presenter:setReviveStatus(if data.reason == "not enough tickets"
			then "NOT ENOUGH 🎟  •  TAP REVIVE TO GET MORE"
			else "COULDN'T REVIVE  •  TRY AGAIN")
	elseif op == RunProtocol.SERVER.STATE or op == RunProtocol.SERVER.ENDED then
		local active = session
		if not active or data.runId ~= active.runId or typeof(data.state) ~= "table" then
			return
		end
		local reconcileFunction = if op == RunProtocol.SERVER.ENDED then replaceWithAuthority else reconcile
		local ok, message = pcall(reconcileFunction, active, data.state)
		if not ok then
			warn("[Skips] ignored malformed authoritative snapshot: " .. tostring(message))
			return
		end
		if op == RunProtocol.SERVER.ENDED then
			-- A late input can let authority discover the loss before local prediction. That path used
			-- to show the run-over UI silently because only the predicted DEATH event played audio.
			-- MATCH_OVER also retires the winning runner; that is not a loss. A rope/checkpoint death
			-- has no packet reason here, while a competitive cut is an explicit loss and keeps the cue.
			if data.reason ~= RunSim.DEATH_REASON.MATCH_OVER then
				playDeathCue(active)
			end
			presenter.setEnded(presenter, data.state.loops)
			if typeof(data.state.score) == "number" then
				bestScore = math.max(bestScore, data.state.score)
			end
			if typeof(data.revive) == "table"
				and typeof(data.revive.expiresAt) == "number"
				and typeof(data.revive.cost) == "number" then
				active.paused = true
				active.accumulator = 0
				active.reviveExpiresAt = data.revive.expiresAt
				active.purchasePending = false
				active.wantsRevive = false
				active.revivePausedRemaining = nil
				reviveCost = data.revive.cost
				presenter:showRevive(data.revive.cost, TicketClient.balance())
			end
			if data.retired == true then
				-- The match ended this run: cut for the lowest score, or decided. No revive can follow,
				-- so whatever offer or shop the old death had opened goes away.
				active.reviveExpiresAt = nil
				active.revivePausedRemaining = nil
				active.purchasePending = false
				if active.wantsRevive then
					active.wantsRevive = false
					TicketClient.closeShop()
				end
				presenter:hideRevive()
				audio:resetCountdown()
				presenter:setRetired(tostring(data.reason))
			end
		end
	elseif op == RunProtocol.SERVER.RUN_OVER then
		local active = session
		if not active or data.runId ~= active.runId then
			return
		end
		active.runOver = true
		active.runOverAt = os.clock()
		active.wantsRevive = false
		active.reviveExpiresAt = nil
		active.revivePausedRemaining = nil
		if TicketClient.isOpen() then
			TicketClient.closeShop()
		end
		presenter:hideRevive()
		audio:resetCountdown()
		bestScore = math.max(bestScore, active.run.score)
		presenter:showRunOver(active.run.score, active.run.loops, bestScore)
	elseif op == RunProtocol.SERVER.UNPAUSED then
		local active = session
		if not active or data.runId ~= active.runId or typeof(data.state) ~= "table"
			or typeof(data.startAt) ~= "number" then
			return
		end
		-- Inputs are kept: the release stamped as the pause began is still to be applied, by both
		-- peers, on the first tick after it.
		local ok, message = pcall(replaceWithAuthority, active, data.state)
		if not ok then
			warn("[Skips] ignored malformed unpause snapshot: " .. tostring(message))
			return
		end
		active.userPaused = false
		active.unpauseRequested = false
		active.paused = false
		active.started = false
		active.startAt = data.startAt
		active.resumeCountdown = true
		active.resumeRequested = false
		active.accumulator = 0
		presenter:hidePaused()
		presenter:setGetReadyCountdown(data.startAt - workspace:GetServerTimeNow())
		audio:resetCountdown()
	elseif op == RunProtocol.SERVER.NET then
		if typeof(data.pingMs) == "number" then
			netPingSeconds = data.pingMs / 1000
			presenter:setPing(data.pingMs)
		end
		if typeof(data.delayTicks) == "number" then
			netDelayTicks = data.delayTicks
		end
	elseif op == RunProtocol.SERVER.RESUME_AT then
		local active = session
		if not active or data.runId ~= active.runId or typeof(data.startAt) ~= "number"
			or not active.resumeCountdown then
			return
		end
		-- The tap moved the agreed moment earlier. Adopt the server's number rather than resuming
		-- locally: the whole reason this is a round trip is that both peers must step the same tick.
		active.startAt = data.startAt
		presenter:setGetReadyCountdown(data.startAt - workspace:GetServerTimeNow())
	elseif op == RunProtocol.SERVER.REVIVED then
		local active = session
		if not active or data.runId ~= active.runId or typeof(data.state) ~= "table"
			or typeof(data.startAt) ~= "number" then
			return
		end
		local ok, message = pcall(replaceWithAuthority, active, data.state)
		if not ok then
			warn("[Skips] ignored malformed revive snapshot: " .. tostring(message))
			return
		end
		active.paused = false
		active.started = false
		active.startAt = data.startAt
		active.resumeCountdown = true
		active.resumeRequested = false
		active.reviveExpiresAt = nil
		active.revivePausedRemaining = nil
		active.deathSoundPlayed = false
		active.purchasePending = false
		active.accumulator = 0
		active.inputs = {}
		active.nextInputIndex = 1
		active.lastInputTick = active.run.tick
		presenter:hideRevive()
		presenter:setGetReadyCountdown(data.startAt - workspace:GetServerTimeNow())
		audio:resetCountdown()
		audio:play("REVIVE")
		inputController:reset()
		active.inputDown = false
		active.suppressUntilRelease = false
	end
end)

RunService.Heartbeat:Connect(function(dt)
	local active = session
	if not active then
		return
	end
	presenter:setPauseVisible(canPause(active))
	-- The other runs beside yours, and whose run you are watching once you are out (StageView).
	presenter:setFraming(stage:update(dt, presenter.groundPosition, presenter.baseRoot, presenter:laneRight(),
		presenter.lowGraphics))
	presenter:setSpectating(stage:isSpectating())
	-- The SPLAT button, in a match, covers every eligible opponent still running (SplatClient).
	SplatClient.update(stage:opponents(), stage:isInMatch())
	if active.reviveExpiresAt then
		local remaining = active.reviveExpiresAt - workspace:GetServerTimeNow()
		-- Paused while the player is in the ticket shop: the number stands still and nothing ticks.
		-- The server still lets the run go once its longest hold is up, so that is still watched.
		local paused = active.revivePausedRemaining
		presenter:updateRevive(if paused then paused else remaining)
		if not paused then
			audio:playCountdown(remaining)
		end
		if remaining <= 0 then
			active.reviveExpiresAt = nil
			active.revivePausedRemaining = nil
			presenter:hideRevive()
			audio:resetCountdown()
		end
	end

	if not active.started then
		local now = workspace:GetServerTimeNow()
		if active.resumeCountdown then
			local remaining = active.startAt - now
			presenter:setGetReadyCountdown(remaining)
			audio:playCountdown(remaining)
		end
		if now < active.startAt then
			presenter.render(presenter, active.run, active.previousY, 0)
			return
		end
		active.started = true
		local finishedResumeCountdown = active.resumeCountdown
		active.resumeCountdown = false
		active.accumulator = now - active.startAt
		active.suppressUntilRelease = inputController:isDown()
		presenter.setStarted(presenter)
		if finishedResumeCountdown then
			audio:resetCountdown()
		end
	else
		active.accumulator += dt
	end
	if active.paused then
		-- The deadline the server will actually act on, re-read every frame. A local countdown
		-- would drift from it and could still read 2 as the modal closed.
		if active.offerDeadline and active.offerCards then
			presenter:setOfferDeadline(active.offerDeadline - workspace:GetServerTimeNow())
		end
		-- Hold the exact simulated state, not the tick before it. A card offer now opens in
		-- mid-air, so this is the frame the player looks at while they choose; rendering
		-- `previousY` would freeze them a tick short of the height the sim actually reached.
		active.accumulator = 0
		presenter.render(presenter, active.run, active.run.y, 1)
		return
	end

	local steps = 0
	while active.accumulator >= SimTuning.DT
		and steps < RunProtocol.MAX_STEPS_PER_FRAME
		and not active.paused do
		active.accumulator -= SimTuning.DT
		steps += 1
		stepPredicted(active)
	end

	presenter.render(presenter, active.run, active.previousY, active.accumulator / SimTuning.DT)
	if RunService:IsStudio() then
		presenter.gui:SetAttribute("RenderedTick", active.run.tick)
	end
end)

runRemote:FireServer(RunProtocol.CLIENT.READY)
