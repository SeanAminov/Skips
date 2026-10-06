--!strict
--[[
	DistractionService — the server's authority over who may be splatted, when, and what it costs.

	Every check lives here and nowhere else, because the effect is bought: a check made only on a
	client is a check an exploiter skips.

	A SPLAT COSTS ONE TICKET AND HITS EVERY ELIGIBLE OPPONENT IN THE BUYER'S CURRENT MATCH. The server
	builds that roster; the client never names people, bots, or lane slots. Obvious refusals are checked
	first, then the datastore confirms the ticket charge, and only then may any effect land. The same
	match and opponents are checked again after the yielding charge. If nobody can still be hit, the
	ticket is refunded. A paid effect can therefore never appear before its charge has succeeded.

	See `Distraction` for why this is a splat rather than a jump scare, and why a bot must feel it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Distraction = require(Shared:WaitForChild("Distraction"))
local MonetizationConfig = require(Shared:WaitForChild("MonetizationConfig"))
local RunProtocol = require(Shared:WaitForChild("RunProtocol"))
local BotRunner = require(script.Parent:WaitForChild("BotRunner"))
local MatchService = require(script.Parent:WaitForChild("MatchService"))

local DistractionService = {}

--[[
	Tickets, through the same kind of seam the revive uses: this service charges for a splat but does
	not know where tickets are kept. The bootstrap wires both to PlayerDataService. The defaults refuse,
	so a missing wire can never hand out a free splat.
]]
function DistractionService.spendTickets(_player: Player, _amount: number): (boolean, string)
	return false, "tickets are not available"
end
function DistractionService.refundTickets(_player: Player, _amount: number): boolean
	return false
end

-- userId -> server time of the last splat that landed. Keyed by userId so bots (negative ids) and
-- humans are held to one immunity rule.
local lastSplatAt: { [number]: number } = {}
local lastBuyAt: { [Player]: number } = {}
local splatRemote: RemoteEvent? = nil

local function targetStatus(target: MatchService.OpponentView?): (boolean, string, number?)
	if not target then
		return false, Distraction.REFUSED.NO_TARGET
	end
	if not target.alive then
		return false, Distraction.REFUSED.OUT
	end
	if target.busy then
		return false, Distraction.REFUSED.CHOOSING
	end
	local now = workspace:GetServerTimeNow()
	local last = lastSplatAt[target.userId]
	if last and (now - last) < Distraction.IMMUNITY_SECONDS then
		return false, Distraction.REFUSED.IMMUNE, Distraction.IMMUNITY_SECONDS - (now - last)
	end
	return true, "READY"
end

--[[
	Splat `target`, one of `fromPlayer`'s opponents as MatchService describes it. Returns whether it
	landed; when it did not, why (a `Distraction.REFUSED` code) and, for an immune target, the seconds
	left.

	Refused when the target is not an opponent in the caller's running match, is already out, is
	behind a card choice, or was splatted within IMMUNITY_SECONDS. The card-choice refusal matters: a
	splat over the modal would simply burn the victim's pick to the auto-pick deadline, which is not
	the effect anyone paid for.
]]
function DistractionService.apply(fromPlayer: Player, target: MatchService.OpponentView?): (boolean, string, number?)
	local eligible, refusal, retryIn = targetStatus(target)
	if not eligible then
		return false, refusal, retryIn
	end
	target = target :: MatchService.OpponentView
	local now = workspace:GetServerTimeNow()

	local bot = target.bot
	if bot then
		BotRunner.blind(bot, Distraction.DURATION_TICKS,
			Distraction.BOT_JITTER_MULTIPLIER, Distraction.BOT_WHIFF_PERCENT)
		lastSplatAt[target.userId] = now
		return true, "LANDED"
	end

	local victim = target.player
	local remote = splatRemote
	if victim and victim.Parent == Players and remote then
		remote:FireClient(victim, Distraction.SERVER.SPLAT, {
			duration = Distraction.DURATION_SECONDS,
			fromName = fromPlayer.DisplayName,
		})
		lastSplatAt[target.userId] = now
		return true, "LANDED"
	end
	return false, Distraction.REFUSED.UNAVAILABLE
end

local function reply(player: Player, landed: boolean, reason: string, retryIn: number?, count: number?)
	local remote = splatRemote
	if remote and player.Parent == Players then
		remote:FireClient(player, Distraction.SERVER.RESULT, {
			landed = landed,
			count = count or 0,
			reason = reason,
			retryIn = if retryIn then math.ceil(retryIn) else nil,
			cost = MonetizationConfig.SPLAT_TICKET_COST,
		})
	end
end

-- Returns every opponent that can be hit now. When there are none, preserve the most useful refusal
-- for the UI (immunity with its shortest remaining wait, then card choice, out, or no target).
local function eligibleOpponents(player: Player): ({ MatchService.OpponentView }, string, number?)
	local eligible: { MatchService.OpponentView } = {}
	local fallback = Distraction.REFUSED.NO_TARGET
	local shortestImmunity: number? = nil
	for _, target in MatchService.opponents(player) do
		local ready, reason, retryIn = targetStatus(target)
		if ready then
			table.insert(eligible, target)
		elseif reason == Distraction.REFUSED.IMMUNE then
			fallback = reason
			if retryIn and (not shortestImmunity or retryIn < shortestImmunity) then
				shortestImmunity = retryIn
			end
		elseif fallback ~= Distraction.REFUSED.IMMUNE and reason == Distraction.REFUSED.CHOOSING then
			fallback = reason
		elseif fallback == Distraction.REFUSED.NO_TARGET then
			fallback = reason
		end
	end
	return eligible, fallback, shortestImmunity
end

-- PlayerDataService's reasons, as the buyer's screen is told them.
local function refusalFor(why: string): string
	if why == "not enough tickets" then
		return Distraction.REFUSED.NO_TICKETS
	elseif why == "already spending" then
		return Distraction.REFUSED.BUSY
	end
	return Distraction.REFUSED.UNAVAILABLE
end

local function refundFailedSplat(player: Player, cost: number)
	local called, refunded = pcall(DistractionService.refundTickets, player, cost)
	if not (called and refunded) then
		warn(string.format("[Skips] could not refund a failed splat for %s: %s",
			player.Name, tostring(refunded)))
	end
end

--[[
	A splat bought with a ticket: snapshot every eligible opponent, take one ticket, revalidate the
	same matchup and only then land on everyone still eligible. New opponents can never join a paid
	attempt across the datastore yield. If all snapshotted opponents disappear or become protected,
	the ticket is refunded.
]]
local function buy(player: Player)
	local now = workspace:GetServerTimeNow()
	local lastBuy = lastBuyAt[player]
	if lastBuy and now - lastBuy < Distraction.BUY_COOLDOWN_SECONDS then
		return reply(player, false, Distraction.REFUSED.BUSY,
			Distraction.BUY_COOLDOWN_SECONDS - (now - lastBuy))
	end
	lastBuyAt[player] = now

	local cost = MonetizationConfig.SPLAT_TICKET_COST
	local originalTargets, reason, retryIn = eligibleOpponents(player)
	if #originalTargets == 0 then
		return reply(player, false, reason, retryIn)
	end
	local originalMatchByUserId: { [number]: string } = {}
	for _, target in originalTargets do
		originalMatchByUserId[target.userId] = target.matchId
	end
	local called, spent, spendWhy = pcall(DistractionService.spendTickets, player, cost)
	if not (called and spent) then
		return reply(player, false,
			refusalFor(tostring(if called then spendWhy else spent)))
	end

	local landedCount = 0
	local currentTargets, currentReason, currentRetryIn = eligibleOpponents(player)
	for _, target in currentTargets do
		if originalMatchByUserId[target.userId] == target.matchId then
			local applyCalled, landed = pcall(DistractionService.apply, player, target)
			if applyCalled and landed then
				landedCount += 1
			elseif not applyCalled then
				warn(string.format("[Skips] paid group splat application failed for %s: %s",
					player.Name, tostring(landed)))
			end
		end
	end
	if landedCount == 0 then
		refundFailedSplat(player, cost)
		return reply(player, false, currentReason, currentRetryIn)
	end
	reply(player, true, "LANDED", nil, landedCount)
end

function DistractionService.start()
	local remoteFolder = ReplicatedStorage:FindFirstChild(RunProtocol.REMOTE_FOLDER)
	if not remoteFolder then
		remoteFolder = Instance.new("Folder")
		remoteFolder.Name = RunProtocol.REMOTE_FOLDER
		remoteFolder.Parent = ReplicatedStorage
	end
	local existing = (remoteFolder :: Folder):FindFirstChild(Distraction.REMOTE_NAME)
	if not existing then
		existing = Instance.new("RemoteEvent")
		existing.Name = Distraction.REMOTE_NAME
		existing.Parent = remoteFolder
	end
	assert(existing:IsA("RemoteEvent"), "DistractionService: remote must be a RemoteEvent")
	local remote = existing :: RemoteEvent
	splatRemote = remote

	remote.OnServerEvent:Connect(function(player, op, value)
		if op == Distraction.CLIENT.BUY then
			buy(player)
			return
		end
		--[[
			Everything else is a free test splat, and exists only in Studio. PREVIEW splats yourself, so
			the effect can be looked at with no match and no second player. TEST_APPLY runs the full
			authoritative path against an opponent named by userId, which is how a bot's blindness, or a
			second client in Server & Clients mode, gets checked.
		]]
		if not RunService:IsStudio() then
			return
		end
		if op == Distraction.CLIENT.PREVIEW then
			remote:FireClient(player, Distraction.SERVER.SPLAT, {
				duration = Distraction.DURATION_SECONDS,
				fromName = "Studio preview",
			})
		elseif op == Distraction.CLIENT.TEST_APPLY then
			local target = if typeof(value) == "number" then MatchService.opponentView(player, value) else nil
			local _, why = DistractionService.apply(player, target)
			print(string.format("[Skips] test splat on %s: %s", tostring(value), why))
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastSplatAt[player.UserId] = nil
		lastBuyAt[player] = nil
	end)
end

return DistractionService
