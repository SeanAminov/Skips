--!strict
--[[
	ViewService — tells each player what the runs beside theirs look like, ten times a second.

	PRESENTATION ONLY. A view is read from a run (`RunView`) and changes nothing; each client draws a
	ghost from it (`StageView`). In a match a player hears about every other participant -- bots
	included and indistinguishable: keyed by slot, with a rig name, never an account id and never a
	bot flag. In solo a player hears about up to three other players doing their own runs, so the park
	is never empty.

	Why the server says who is beside you rather than each client working it out: the lineup is a
	match's business (who is in it, who is out), and a client that could ask for any run's view would
	be a way to watch a stranger's run uninvited.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RunProtocol = require(Shared:WaitForChild("RunProtocol"))
local ViewProtocol = require(Shared:WaitForChild("ViewProtocol"))
local BotRunner = require(script.Parent:WaitForChild("BotRunner"))
local MatchService = require(script.Parent:WaitForChild("MatchService"))
local RunServer = require(script.Parent:WaitForChild("RunServer"))

local ViewService = {}

local function entryFrom(key: string, name: string, view: any?, out: boolean, rig: string?,
	playerId: number?): { [string]: any }
	local entry: { [string]: any } = { key = key, name = name, out = out, rig = rig, player = playerId }
	if view then
		entry.tick = view.tick
		entry.y = view.y
		entry.grounded = view.grounded
		entry.rising = view.rising
		entry.alive = view.alive
		entry.score = view.score
		entry.period = view.period
		entry.burning = math.min(view.burning, ViewProtocol.MAX_GHOST_ROPES)
		entry.guarded = {}
		entry.ropes = {}
		for index = 1, math.min(#view.ropes, ViewProtocol.MAX_GHOST_ROPES) do
			entry.guarded[index] = view.guarded[index]
			entry.ropes[index] = view.ropes[index]
		end
	end
	return entry
end

-- Solo: other players not in a match, taken in UserId order starting just after yours, so everyone's
-- neighbours stay the same from one tenth of a second to the next.
local function soloEntries(player: Player): { { [string]: any } }
	local others = {}
	for _, other in Players:GetPlayers() do
		if other ~= player and MatchService.matchFor(other) == nil then
			local view = RunServer.viewOf(other)
			if view then
				table.insert(others, { player = other, view = view })
			end
		end
	end
	table.sort(others, function(a, b)
		return a.player.UserId < b.player.UserId
	end)
	local start = 1
	for index, other in others do
		if other.player.UserId > player.UserId then
			start = index
			break
		end
	end
	local entries = {}
	for step = 0, math.min(#others, ViewProtocol.SOLO_NEIGHBOURS) - 1 do
		local other = others[((start - 1 + step) % #others) + 1]
		table.insert(entries, entryFrom("p" .. other.player.UserId, other.player.Name, other.view, false,
			nil, other.player.UserId))
	end
	return entries
end

function ViewService.start()
	local remoteFolder = ReplicatedStorage:FindFirstChild(RunProtocol.REMOTE_FOLDER)
	if not remoteFolder then
		remoteFolder = Instance.new("Folder")
		remoteFolder.Name = RunProtocol.REMOTE_FOLDER
		remoteFolder.Parent = ReplicatedStorage
	end
	local existing = (remoteFolder :: Folder):FindFirstChild(ViewProtocol.REMOTE_NAME)
	if not existing then
		existing = Instance.new("RemoteEvent")
		existing.Name = ViewProtocol.REMOTE_NAME
		existing.Parent = remoteFolder
	end
	assert(existing:IsA("RemoteEvent"), "ViewService: View remote must be a RemoteEvent")
	local remote = existing :: RemoteEvent

	local clock = 0
	RunService.Heartbeat:Connect(function(dt)
		clock += dt
		if clock < ViewProtocol.INTERVAL_SECONDS then
			return
		end
		clock = 0
		local now = workspace:GetServerTimeNow()
		for _, player in Players:GetPlayers() do
			local mates, youOut = MatchService.lineupFor(player)
			local entries: { { [string]: any } }
			if mates then
				entries = {}
				for _, mate in mates do
					local view = if mate.bot then BotRunner.viewOf(mate.bot)
						elseif mate.player then RunServer.viewOf(mate.player)
						else nil
					table.insert(entries, entryFrom(mate.key, mate.name, view, mate.finished, mate.rig, nil))
				end
			else
				entries = soloEntries(player)
			end
			remote:FireClient(player, ViewProtocol.SERVER.VIEW, {
				at = now,
				match = mates ~= nil,
				out = youOut == true,
				entries = entries,
			})
		end
	end)
end

return ViewService
