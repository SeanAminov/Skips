--!strict
--[[
	PlayerDataService — each player's saved record: tickets, redeemed codes, settings, social
	rewards, and whether they have been shown the first-time hint.

	ONE KEY PER PLAYER in `PlayerData_v1`:
	{ v, tickets, tutorialDone, redeemed, settings, socialRewards, ops }. Every change goes through
	`UpdateAsync` by way of `StoreAccess`, so two servers touching one record cannot lose a write,
	and one bad moment on a live server is retried rather than lost.

	TICKETS ARE MONEY, SO EVERY TICKET CHANGE IS IDEMPOTENT. A grant carries the Roblox purchase id, a
	spend carries a fresh key, a code carries its own name, a social claim carries a fixed key; the
	key is written into `ops` by the same write that changes the balance, and a key already there is
	skipped. So a retry after a write that did in fact land -- the one failure StoreAccess cannot see
	-- can never grant twice or charge twice. `ops` keeps the most recent OPS_KEPT keys; redeemed
	codes and socialRewards claims are kept separately and forever.

	A SPEND IS DECIDED BY THE STORE, NOT BY MEMORY. The in-memory balance is only a mirror for the HUD.
	`spendTickets` checks the stored balance inside the write, so one ticket can never be spent on two
	servers at once.

	SETTINGS ARE PRESENTATION ONLY: stored here so they follow the player, read
	by nothing that decides a run.

	IT MUST WORK WHEN DATASTORES DO NOT. With no store (Studio, unlinked) the record lives in memory for
	the session and says so (`SkipsDataSaved = false`), and nothing can be bought, because products
	only resolve in a linked place.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerProtocol = require(Shared:WaitForChild("PlayerProtocol"))
local RunProtocol = require(Shared:WaitForChild("RunProtocol"))
local SocialConfig = require(Shared:WaitForChild("SocialConfig"))
local CodeConfig = require(script.Parent:WaitForChild("CodeConfig"))
local StoreAccess = require(script.Parent:WaitForChild("StoreAccess"))

local PlayerDataService = {}

local FEATURE = "player data"
-- Versioned, so a future change to what a record holds can move to a new store rather than guess
-- at the shape of every old key.
local STORE_NAME = "PlayerData_v1"
local OPS_KEPT = 40
local LOAD_ATTEMPTS = 3
-- Settings changes are coalesced: dragging the sound slider writes once after it is released.
local SETTINGS_SAVE_DELAY = 3
local GROUP_CLAIM_OP = "social:groupJoin"

export type Settings = { sound: number, lowGraphics: boolean, hideOthers: boolean }

export type SocialRewards = {
	-- Verified community membership reward (Like is asked in UI; only Join is proven).
	groupJoin: boolean,
}

export type Record = {
	v: number,
	tickets: number,
	tutorialDone: boolean,
	redeemed: { [string]: number },
	settings: Settings,
	socialRewards: SocialRewards,
	ops: { [string]: number },
}

type State = {
	record: Record,
	loaded: boolean,
	-- A spend in flight. A second one is refused rather than raced against it.
	spending: boolean,
	settingsSaving: boolean,
	settingsDirty: boolean,
	codeAttempts: { number },
	groupClaimAttempts: { number },
}

local states: { [Player]: State } = {}
local store: DataStore? = nil
local remote: RemoteEvent? = nil

local function getStore(): DataStore?
	if store then
		return store
	end
	local ok, result = StoreAccess.try(FEATURE, function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok and result then
		store = result
		return result
	end
	return nil
end

local function defaultSettings(): Settings
	return { sound = PlayerProtocol.DEFAULT_SOUND, lowGraphics = false, hideOthers = false }
end

local function defaultSocialRewards(): SocialRewards
	return { groupJoin = false }
end

local function blank(): Record
	return {
		v = 2,
		tickets = 0,
		tutorialDone = false,
		redeemed = {},
		settings = defaultSettings(),
		socialRewards = defaultSocialRewards(),
		ops = {},
	}
end

local function validSound(value: any): boolean
	return typeof(value) == "number"
		and value >= PlayerProtocol.SOUND_MIN and value <= PlayerProtocol.SOUND_MAX
end

-- Version 1 stored one of four indices. Version 2 stores the actual 0–1 slider position. In
-- particular, legacy 1 meant OFF while current 1 means full volume, so the record version must
-- decide the interpretation rather than guessing from the number.
local LEGACY_SOUND_LEVELS = table.freeze({ 0, 0.35, 0.7, 1 })

-- Whatever is stored comes out whole: a whole, non-negative balance, well-formed logs, valid settings.
local function sanitise(value: any): Record
	local record = blank()
	if typeof(value) == "table" then
		if typeof(value.tickets) == "number" then
			record.tickets = math.max(0, math.floor(value.tickets))
		end
		record.tutorialDone = value.tutorialDone == true
		for _, field in { "ops", "redeemed" } do
			local stored = value[field]
			if typeof(stored) == "table" then
				for key, at in stored do
					if typeof(key) == "string" and typeof(at) == "number" then
						(record :: any)[field][key] = at
					end
				end
			end
		end
		if typeof(value.settings) == "table" then
			local storedSound = value.settings.sound
			if (value.v == nil or value.v == 1) and typeof(storedSound) == "number"
				and storedSound == math.floor(storedSound) and LEGACY_SOUND_LEVELS[storedSound] ~= nil then
				record.settings.sound = LEGACY_SOUND_LEVELS[storedSound]
			elseif validSound(storedSound) then
				record.settings.sound = PlayerProtocol.normaliseSound(storedSound)
			end
			record.settings.lowGraphics = value.settings.lowGraphics == true
			record.settings.hideOthers = value.settings.hideOthers == true
		end
		if typeof(value.socialRewards) == "table" then
			record.socialRewards.groupJoin = value.socialRewards.groupJoin == true
		end
	end
	return record
end

local function trimOps(record: Record)
	local entries = {}
	for key, at in record.ops do
		table.insert(entries, { key = key, at = at })
	end
	if #entries <= OPS_KEPT then
		return
	end
	table.sort(entries, function(a, b)
		return a.at > b.at
	end)
	for index = OPS_KEPT + 1, #entries do
		record.ops[entries[index].key] = nil
	end
end

local function publish(player: Player)
	local state = states[player]
	if not state or player.Parent ~= Players then
		return
	end
	player:SetAttribute(PlayerProtocol.ATTRIBUTE.TICKETS, state.record.tickets)
	player:SetAttribute(PlayerProtocol.ATTRIBUTE.TUTORIAL_DONE, state.record.tutorialDone)
	player:SetAttribute(PlayerProtocol.ATTRIBUTE.SOUND, state.record.settings.sound)
	player:SetAttribute(PlayerProtocol.ATTRIBUTE.LOW_GRAPHICS, state.record.settings.lowGraphics)
	player:SetAttribute(PlayerProtocol.ATTRIBUTE.HIDE_OTHERS, state.record.settings.hideOthers)
	player:SetAttribute(PlayerProtocol.ATTRIBUTE.GROUP_CLAIMED, state.record.socialRewards.groupJoin)
	player:SetAttribute(PlayerProtocol.ATTRIBUTE.LOADED, state.loaded)
	player:SetAttribute(PlayerProtocol.ATTRIBUTE.SAVED, not StoreAccess.offline())
end

--[[
	One change to one record, applied inside UpdateAsync under its idempotency key. `transform` edits
	the record and returns true to write it, or false to leave it as it is (not enough tickets, say).

	Returns whether the change is in -- applied now, or already applied under the same key -- and the
	record as the store holds it. A failed write returns nil for the record, so a caller never mistakes
	"the store did not answer" for "you cannot afford it".
]]
local function change(userId: number, key: string, transform: (Record) -> boolean): (boolean, Record?)
	local records = getStore()
	if not records then
		return false, nil
	end
	local applied = false
	local result: Record? = nil
	local ok = StoreAccess.write(FEATURE, function()
		records:UpdateAsync(tostring(userId), function(stored)
			local record = sanitise(stored)
			result = record
			if record.ops[key] then
				applied = true -- already in: a retry after a write that landed
				return nil
			end
			if not transform(record) then
				applied = false
				return nil
			end
			record.ops[key] = os.time()
			trimOps(record)
			applied = true
			return record
		end)
	end)
	if not ok then
		return false, nil
	end
	return applied, result
end

local function load(player: Player)
	local state: State = {
		record = blank(),
		loaded = false,
		spending = false,
		settingsSaving = false,
		settingsDirty = false,
		codeAttempts = {},
		groupClaimAttempts = {},
	}
	states[player] = state
	publish(player)
	-- Offline Studio deliberately uses a session-only blank record. A live server must never do so:
	-- loading blank after a transient failure could later overwrite real tickets and paid receipts.
	local loadedSafely = StoreAccess.offline()
	local records = getStore()
	if records then
		for attempt = 1, LOAD_ATTEMPTS do
			local ok, value = StoreAccess.try(FEATURE, function()
				return records:GetAsync(tostring(player.UserId))
			end)
			if states[player] ~= state then
				return
			end
			if ok then
				state.record = sanitise(value)
				loadedSafely = true
				break
			end
			if StoreAccess.offline() or attempt == LOAD_ATTEMPTS then
				break
			end
			task.wait(2 ^ (attempt - 1))
		end
	end
	if not loadedSafely and not StoreAccess.offline() then
		if states[player] == state then
			states[player] = nil
		end
		if player.Parent == Players then
			player:Kick("Your saved data could not be loaded safely. Please rejoin in a moment.")
		end
		return
	end
	if states[player] == state then
		state.loaded = true
		publish(player)
		-- Membership that was invisible right after PromptJoinAsync can resolve on a later join.
		task.spawn(function()
			PlayerDataService.tryClaimGroupReward(player, true)
		end)
	end
end

local function mirrorTickets(userId: number, record: Record)
	local player = Players:GetPlayerByUserId(userId)
	local state = player and states[player]
	if player and state then
		state.record.tickets = record.tickets
		state.record.redeemed = record.redeemed
		state.record.socialRewards = record.socialRewards
		publish(player)
	end
end

function PlayerDataService.ticketsOf(player: Player): number
	local state = states[player]
	return if state then state.record.tickets else 0
end

--[[
	Whether `amount` could be spent right now, read from memory: the record is loaded, no other spend
	is in flight, and the mirrored balance covers it. Never yields. A gate only -- the spend itself is
	still decided by the store. The splat asks this before it lands (DistractionService).
]]
function PlayerDataService.canAfford(player: Player, amount: number): (boolean, string)
	local state = states[player]
	if not state or not state.loaded then
		return false, "tickets are still loading"
	end
	if state.spending then
		return false, "already spending"
	end
	if state.record.tickets < amount then
		return false, "not enough tickets"
	end
	return true, "ok"
end

--[[
	Spends tickets. The only place a ticket is ever taken, and only if the STORED balance covers it.
	Yields. Returns whether it was spent, and why not when it was not.
]]
function PlayerDataService.spendTickets(player: Player, amount: number): (boolean, string)
	local affordable, why = PlayerDataService.canAfford(player, amount)
	if not affordable then
		return false, why
	end
	local state = states[player] :: State
	if StoreAccess.offline() then
		state.record.tickets -= amount
		publish(player)
		return true, "spent (not saved this session)"
	end
	state.spending = true
	local ok, record = change(player.UserId, "spend:" .. HttpService:GenerateGUID(false), function(r)
		if r.tickets < amount then
			return false
		end
		r.tickets -= amount
		return true
	end)
	state.spending = false
	if record and states[player] == state then
		mirrorTickets(player.UserId, record)
	end
	if ok then
		return true, "spent"
	end
	return false, if record then "not enough tickets" else "the ticket store did not answer"
end

--[[
	Adds tickets. From a purchase the key is the Roblox purchase id, so a receipt Roblox retries can
	never grant twice. Works whether or not the player is in this server. Yields. Returns whether the
	tickets are saved -- a purchase must never be reported granted before that.
]]
function PlayerDataService.grantTickets(userId: number, amount: number, key: string): boolean
	if StoreAccess.offline() then
		return false
	end
	local ok, record = change(userId, key, function(r)
		r.tickets += amount
		return true
	end)
	if ok and record then
		mirrorTickets(userId, record)
	end
	return ok
end

-- Gives back tickets taken for something that then could not happen. This waits for the guarded,
-- keyed write so the caller does not report a refusal while the player's balance still looks lower.
function PlayerDataService.refundTickets(player: Player, amount: number): boolean
	local state = states[player]
	if StoreAccess.offline() then
		if state then
			state.record.tickets += amount
			publish(player)
			return true
		end
		return false
	end
	return PlayerDataService.grantTickets(player.UserId, amount,
		"refund:" .. HttpService:GenerateGUID(false))
end

local function markTutorialDone(player: Player)
	local state = states[player]
	if not state or state.record.tutorialDone then
		return
	end
	state.record.tutorialDone = true
	publish(player)
	if StoreAccess.offline() then
		return
	end
	task.spawn(change, player.UserId, "tutorial", function(r)
		if r.tutorialDone then
			return false
		end
		r.tutorialDone = true
		return true
	end)
end

local function reply(player: Player, op: string, ok: boolean, message: string)
	local r = remote
	if r and player.Parent == Players then
		r:FireClient(player, op, { ok = ok, message = message })
	end
end

local function replyCode(player: Player, ok: boolean, message: string)
	reply(player, PlayerProtocol.SERVER.CODE_RESULT, ok, message)
end

local function replyGroup(player: Player, ok: boolean, message: string)
	reply(player, PlayerProtocol.SERVER.GROUP_RESULT, ok, message)
end

local function inGroup(player: Player): (boolean, boolean)
	if SocialConfig.GROUP_ID <= 0 then
		return false, false
	end
	local ok, result = pcall(function()
		return player:IsInGroupAsync(SocialConfig.GROUP_ID)
	end)
	if not ok then
		return false, false
	end
	return true, result == true
end

--[[
	Pays the once-per-account community reward after verifying membership on the server.
	`silent` is true for the post-load auto-claim (no toast spam when already claimed / not a member).
]]
function PlayerDataService.tryClaimGroupReward(player: Player, silent: boolean?)
	local state = states[player]
	if not state then
		return
	end
	local quiet = silent == true
	if SocialConfig.GROUP_ID <= 0 then
		if not quiet then
			replyGroup(player, false, "COMMUNITY REWARD ISN'T READY YET")
		end
		return
	end
	if not state.loaded then
		if not quiet then
			replyGroup(player, false, "STILL LOADING  •  TRY AGAIN IN A MOMENT")
		end
		return
	end
	if state.record.socialRewards.groupJoin then
		if not quiet then
			replyGroup(player, false, "CLAIMED ✓")
		end
		return
	end

	local checked, member = inGroup(player)
	if not checked then
		if not quiet then
			replyGroup(player, false, "CAN'T CHECK RIGHT NOW — TRY AGAIN SOON")
		end
		return
	end
	if not member then
		if not quiet then
			replyGroup(player, false, "JOIN THE COMMUNITY FIRST")
		end
		return
	end

	local reward = SocialConfig.GROUP_REWARD_TICKETS
	if StoreAccess.offline() then
		state.record.socialRewards.groupJoin = true
		state.record.tickets += reward
		publish(player)
		if not quiet then
			replyGroup(player, true,
				string.format("COMMUNITY BONUS CLAIMED! +%d 🎟  •  NOT SAVED THIS SESSION", reward))
		end
		return
	end

	local ok, record = change(player.UserId, GROUP_CLAIM_OP, function(r)
		if r.socialRewards.groupJoin then
			return false
		end
		r.socialRewards.groupJoin = true
		r.tickets += reward
		return true
	end)
	if record then
		mirrorTickets(player.UserId, record)
	end
	if ok then
		replyGroup(player, true, string.format("COMMUNITY BONUS CLAIMED! +%d 🎟", reward))
	elseif record and record.socialRewards.groupJoin then
		if not quiet then
			replyGroup(player, false, "CLAIMED ✓")
		end
	elseif not quiet then
		replyGroup(player, false, "COULDN'T REACH THE SAVE  •  TRY AGAIN")
	end
end

local function claimGroupFromClient(player: Player)
	local state = states[player]
	if not state then
		return
	end
	local now = os.clock()
	local attempts = state.groupClaimAttempts
	while #attempts > 0 and now - attempts[1] > 60 do
		table.remove(attempts, 1)
	end
	if #attempts >= SocialConfig.CLAIM_ATTEMPTS_PER_MINUTE then
		return replyGroup(player, false, "TOO MANY TRIES  •  WAIT A MINUTE")
	end
	table.insert(attempts, now)

	-- Membership can lag after PromptJoinAsync; tell the player to rejoin rather than pay on trust.
	local checked, member = inGroup(player)
	if checked and not member then
		return replyGroup(player, false,
			string.format("YOU JOINED! REJOIN ONCE TO CLAIM YOUR %d 🎟", SocialConfig.GROUP_REWARD_TICKETS))
	end
	PlayerDataService.tryClaimGroupReward(player, false)
end

--[[
	Redeems a code typed in Settings. Every rule is the server's: whether the code exists, whether it
	has expired, whether this account has used it. Guessing is throttled per player, and a code is
	recorded on the account in the same write that pays it out, so it can never pay twice.
]]
local function redeemCode(player: Player, typed: unknown)
	local state = states[player]
	if not state or typeof(typed) ~= "string" then
		return
	end
	local now = os.clock()
	local attempts = state.codeAttempts
	while #attempts > 0 and now - attempts[1] > 60 do
		table.remove(attempts, 1)
	end
	if #attempts >= PlayerProtocol.CODE_ATTEMPTS_PER_MINUTE then
		return replyCode(player, false, "TOO MANY TRIES  •  WAIT A MINUTE")
	end
	table.insert(attempts, now)

	local code = string.upper((typed :: string):gsub("%s+", ""))
	if #code == 0 or #code > PlayerProtocol.CODE_MAX_LENGTH or code:match("^[%u%d]+$") == nil then
		return replyCode(player, false, "THAT CODE ISN'T REAL")
	end
	local entry = CodeConfig[code]
	if not entry or (entry.studioOnly and not RunService:IsStudio()) then
		return replyCode(player, false, "THAT CODE ISN'T REAL")
	end
	if entry.expiresUtc and os.time() > entry.expiresUtc then
		return replyCode(player, false, "THAT CODE HAS EXPIRED")
	end
	if not state.loaded then
		return replyCode(player, false, "STILL LOADING  •  TRY AGAIN IN A MOMENT")
	end
	if state.record.redeemed[code] then
		return replyCode(player, false, "YOU ALREADY USED THAT CODE")
	end
	local reward = entry.tickets
	if StoreAccess.offline() then
		state.record.redeemed[code] = os.time()
		state.record.tickets += reward
		publish(player)
		return replyCode(player, true, string.format("+%d TICKETS  •  NOT SAVED THIS SESSION", reward))
	end
	local ok, record = change(player.UserId, "code:" .. code, function(r)
		if r.redeemed[code] then
			return false
		end
		r.redeemed[code] = os.time()
		r.tickets += reward
		return true
	end)
	if record then
		mirrorTickets(player.UserId, record)
	end
	if ok then
		replyCode(player, true, string.format("+%d TICKET%s!", reward, if reward == 1 then "" else "S"))
	elseif record then
		replyCode(player, false, "YOU ALREADY USED THAT CODE")
	else
		replyCode(player, false, "COULDN'T REACH THE SAVE  •  TRY AGAIN")
	end
end

local function saveSettings(player: Player)
	local state = states[player]
	if not state then
		return
	end
	if state.settingsSaving then
		state.settingsDirty = true
		return
	end
	if StoreAccess.offline() then
		return
	end
	state.settingsSaving = true
	task.spawn(function()
		task.wait(SETTINGS_SAVE_DELAY)
		state.settingsDirty = false
		local settings = table.clone(state.record.settings)
		local records = getStore()
		if records then
			StoreAccess.write(FEATURE, function()
				records:UpdateAsync(tostring(player.UserId), function(stored)
					local record = sanitise(stored)
					record.settings = settings
					return record
				end)
			end)
		end
		state.settingsSaving = false
		if state.settingsDirty and states[player] == state then
			saveSettings(player)
		end
	end)
end

local function setSettings(player: Player, value: unknown)
	local state = states[player]
	if not state or typeof(value) ~= "table" then
		return
	end
	local wanted = value :: any
	if validSound(wanted.sound) then
		state.record.settings.sound = PlayerProtocol.normaliseSound(wanted.sound)
	end
	if typeof(wanted.lowGraphics) == "boolean" then
		state.record.settings.lowGraphics = wanted.lowGraphics
	end
	if typeof(wanted.hideOthers) == "boolean" then
		state.record.settings.hideOthers = wanted.hideOthers
	end
	publish(player)
	saveSettings(player)
end

-- Studio only. With DataStores reachable this writes the developer's own real record, like any other
-- Studio session does; that is the price of testing the real grant path rather than a mock of it.
local function studioGrant(player: Player)
	local state = states[player]
	if not state then
		return
	end
	local amount = PlayerProtocol.STUDIO_GRANT_TICKETS
	if StoreAccess.offline() then
		state.record.tickets += amount
		publish(player)
		return
	end
	task.spawn(PlayerDataService.grantTickets, player.UserId, amount, "studio:" .. HttpService:GenerateGUID(false))
end

function PlayerDataService.start()
	local remoteFolder = ReplicatedStorage:FindFirstChild(RunProtocol.REMOTE_FOLDER)
	if not remoteFolder then
		remoteFolder = Instance.new("Folder")
		remoteFolder.Name = RunProtocol.REMOTE_FOLDER
		remoteFolder.Parent = ReplicatedStorage
	end
	local existing = (remoteFolder :: Folder):FindFirstChild(PlayerProtocol.REMOTE_NAME)
	if not existing then
		existing = Instance.new("RemoteEvent")
		existing.Name = PlayerProtocol.REMOTE_NAME
		existing.Parent = remoteFolder
	end
	assert(existing:IsA("RemoteEvent"), "PlayerDataService: PlayerData remote must be a RemoteEvent")
	local playerRemote = existing :: RemoteEvent
	remote = playerRemote

	playerRemote.OnServerEvent:Connect(function(player, op, value)
		if op == PlayerProtocol.CLIENT.TUTORIAL_DONE then
			markTutorialDone(player)
		elseif op == PlayerProtocol.CLIENT.REDEEM_CODE then
			task.spawn(redeemCode, player, value)
		elseif op == PlayerProtocol.CLIENT.CLAIM_GROUP then
			task.spawn(claimGroupFromClient, player)
		elseif op == PlayerProtocol.CLIENT.SET_SETTINGS then
			setSettings(player, value)
		elseif op == PlayerProtocol.CLIENT.STUDIO_GRANT and RunService:IsStudio() then
			studioGrant(player)
		end
	end)

	for _, player in Players:GetPlayers() do
		task.spawn(load, player)
	end
	Players.PlayerAdded:Connect(function(player)
		task.spawn(load, player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
end

return PlayerDataService
