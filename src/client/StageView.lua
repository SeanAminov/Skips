--!strict
--[[
	StageView — the other runs, drawn in lanes beside yours; and, once you are out, spectating.

	The user (2026-09-10): see everyone -- "it doesn't have to show all the players… maybe just like
	2-4" -- with players taken away as they lose, so the final duel is face to face; and spectating as
	"an arrow to go back and forth on names of players… and see the game work in real time of their run".

	PRESENTATION ONLY (§6.4). Everything drawn here comes from `ViewService`'s views, which are read
	from runs. Nothing here can touch a run, and deleting this file leaves a playable game.

	GHOSTS, NOT THE REAL CHARACTERS. Another player's real character is hidden on this client and a
	copy of it is drawn in a lane of our choosing instead. The real one stands wherever the server put
	it, animated by its owner's client from a timeline a few hundred milliseconds ahead of anything the
	server has confirmed; a ghost is positioned AND animated from the same view, so its jump and its rope
	can never disagree with each other. In a match every look comes from the rig folder -- humans and bots
	alike, which is what keeps bots undisclosed.

	LANES ARE STABLE. A ghost keeps its lane for as long as it is shown; a lane only changes hands when
	its runner goes out, and then the best-placed runner not yet shown slides in. Re-sorting the lanes
	by score every frame would have ghosts swapping places all match.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RunProtocol = require(Shared:WaitForChild("RunProtocol"))
local SimTuning = require(Shared:WaitForChild("SimTuning"))
local ViewProtocol = require(Shared:WaitForChild("ViewProtocol"))
local RopeView = require(script.Parent:WaitForChild("RopeView"))

local StageView = {}
StageView.__index = StageView

local INK = Color3.fromRGB(40, 36, 61)
local PAPER = Color3.fromRGB(255, 253, 244)
local CREAM = Color3.fromRGB(255, 244, 211)
local PANEL = Color3.fromRGB(46, 42, 70)
local GOLD = Color3.fromRGB(247, 197, 84)
local MUTED = Color3.fromRGB(157, 147, 164)

local IDLE_ANIMATION_ID = "rbxassetid://507766666"
local JUMP_ANIMATION_ID = "rbxassetid://507765000"
-- Ghost ropes are drawn with fewer segments than your own: they are further away, and there are more.
local GHOST_SEGMENTS = 12
local LANE_SLIDE_SECONDS = 0.35
-- The lanes ghosts take, in order: right of you, left of you, further right.
local LANE_SLOTS = { 1, -1, 2 }
local MAX_SAMPLES = 12
local HIDE_SWEEP_SECONDS = 0.5
local REBUILD_SECONDS = 0.5
local DEAD_TRANSPARENCY = 0.55

local BODY_PARTS = {
	Head = true, UpperTorso = true, LowerTorso = true,
	LeftUpperArm = true, LeftLowerArm = true, LeftHand = true,
	RightUpperArm = true, RightLowerArm = true, RightHand = true,
	LeftUpperLeg = true, LeftLowerLeg = true, LeftFoot = true,
	RightUpperLeg = true, RightLowerLeg = true, RightFoot = true,
}

type Sample = {
	at: number,
	tick: number,
	y: number,
	grounded: boolean,
	rising: boolean,
	alive: boolean,
	score: number,
	burning: number,
	guarded: { boolean },
	period: number,
	ropes: { number },
}

type Ghost = {
	key: string,
	name: string,
	rig: string?,
	player: number?,
	out: boolean,
	samples: { Sample },
	lastSeen: number,
	model: Model?,
	root: BasePart?,
	humanoid: Humanoid?,
	jumpTrack: AnimationTrack?,
	airborne: boolean,
	dimmed: boolean,
	rootToFeet: number,
	ropes: RopeView.RopeView?,
	nameLabel: TextLabel?,
	scoreLabel: TextLabel?,
	slot: number?,
	lane: number,
	nextBuildAt: number,
}

export type Framing = {
	minLane: number,
	maxLane: number,
	focusLane: number?,
	focusY: number?,
}

-- A match opponent still running. The list controls SPLAT visibility; the server owns the paid roster.
export type Opponent = { key: string, name: string, score: number }

export type StageView = typeof(setmetatable(
	{} :: {
		folder: Folder,
		ghosts: { [string]: Ghost },
		inMatch: boolean,
		youOut: boolean,
		spectating: string?,
		bar: Frame,
		barName: TextLabel,
		barScore: TextLabel,
		prevButton: TextButton,
		nextButton: TextButton,
		hideClock: number,
		hideOthers: boolean,
	},
	{} :: { __index: typeof(StageView) }
))

local player = Players.LocalPlayer

local function corner(object: GuiObject, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = object
end

local function stroke(object: GuiObject, colour: Color3, thickness: number)
	local s = Instance.new("UIStroke")
	s.Color = colour
	s.Thickness = thickness
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = object
end

local function label(parent: Instance, name: string, size: UDim2, position: UDim2): TextLabel
	local text = Instance.new("TextLabel")
	text.Name = name
	text.AnchorPoint = Vector2.new(0.5, 0.5)
	text.Size = size
	text.Position = position
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.TextColor3 = PAPER
	text.TextStrokeColor3 = INK
	text.TextStrokeTransparency = 0.1
	text.TextScaled = true
	text.Parent = parent
	return text
end

local function arrow(parent: Instance, name: string, text: string, x: number): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.Size = UDim2.fromOffset(52, 46)
	b.Position = UDim2.new(x, 0, 0.5, 0)
	b.BackgroundColor3 = GOLD
	b.BorderSizePixel = 0
	b.Font = Enum.Font.FredokaOne
	b.Text = text
	b.TextScaled = true
	b.TextColor3 = PAPER
	b.TextStrokeColor3 = INK
	b.TextStrokeTransparency = 0.2
	b.Parent = parent
	corner(b, 14)
	stroke(b, INK, 3)
	return b
end

local function newGhost(key: string): Ghost
	return {
		key = key,
		name = "",
		rig = nil,
		player = nil,
		out = false,
		samples = {},
		lastSeen = 0,
		model = nil,
		root = nil,
		humanoid = nil,
		jumpTrack = nil,
		airborne = false,
		dimmed = false,
		rootToFeet = SimTuning.NOMINAL_HEIGHT * 0.5,
		ropes = nil,
		nameLabel = nil,
		scoreLabel = nil,
		slot = nil,
		lane = 0,
		nextBuildAt = 0,
	}
end

local function latest(ghost: Ghost): Sample?
	return ghost.samples[#ghost.samples]
end

-- Alive first, then by score, then by key: who deserves a lane when there are more runs than lanes.
local function standing(a: Ghost, b: Ghost): boolean
	local la, lb = latest(a), latest(b)
	if not la or not lb then
		return la ~= nil
	end
	if la.alive ~= lb.alive then
		return la.alive
	end
	if la.score ~= lb.score then
		return la.score > lb.score
	end
	return a.key < b.key
end

local function setDimmed(ghost: Ghost, dimmed: boolean)
	if ghost.dimmed == dimmed or not ghost.model then
		return
	end
	ghost.dimmed = dimmed
	for _, descendant in (ghost.model :: Model):GetDescendants() do
		if descendant:IsA("BasePart") or descendant:IsA("Decal") then
			(descendant :: any).LocalTransparencyModifier = if dimmed then DEAD_TRANSPARENCY else 0
		end
	end
end

-- Copies the ghost's look from the rig folder (a match) or from the player's own character (solo).
local function buildModel(self: StageView, ghost: Ghost): boolean
	local source: Instance? = nil
	if ghost.rig then
		local folder = ReplicatedStorage:FindFirstChild(ViewProtocol.RIG_FOLDER)
		source = folder and folder:FindFirstChild(ghost.rig :: string)
	elseif ghost.player then
		local other = Players:GetPlayerByUserId(ghost.player :: number)
		source = other and other.Character
	end
	if not source or not source:IsA("Model") then
		return false
	end
	local original = source :: Model
	local was = original.Archivable
	original.Archivable = true
	local ok, copy = pcall(function()
		return original:Clone()
	end)
	original.Archivable = was
	if not ok or not copy then
		return false
	end
	local model = copy :: Model
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("LuaSourceContainer") or descendant:IsA("Sound") or descendant:IsA("BillboardGui") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.LocalTransparencyModifier = 0
		elseif descendant:IsA("Decal") then
			descendant.LocalTransparencyModifier = 0
		end
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		model:Destroy()
		return false
	end
	root.Anchored = true
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.BreakJointsOnDeath = false
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)

	local low = math.huge
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") and BODY_PARTS[child.Name] then
			low = math.min(low, child.Position.Y - child.Size.Y * 0.5)
		end
	end
	ghost.rootToFeet = if low < math.huge then root.Position.Y - low else SimTuning.NOMINAL_HEIGHT * 0.5
	model.Name = "Ghost_" .. ghost.key
	model.Parent = self.folder

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		local created = Instance.new("Animator")
		created.Parent = humanoid
		animator = created
	end
	for _, spec in { { id = IDLE_ANIMATION_ID, jump = false }, { id = JUMP_ANIMATION_ID, jump = true } } do
		local animation = Instance.new("Animation")
		animation.AnimationId = spec.id
		local loaded, track = pcall(function()
			return (animator :: Animator):LoadAnimation(animation)
		end)
		animation:Destroy()
		if loaded and track then
			if spec.jump then
				track.Priority = Enum.AnimationPriority.Action4
				track.Looped = false
				ghost.jumpTrack = track
			else
				track.Priority = Enum.AnimationPriority.Idle
				track.Looped = true
				track:Play(0)
			end
		end
	end

	-- A cartoon name tag, so a ghost is somebody: the name and the live score.
	local tag = Instance.new("BillboardGui")
	tag.Name = "Tag"
	tag.Size = UDim2.fromOffset(170, 46)
	tag.StudsOffsetWorldSpace = Vector3.new(0, ghost.rootToFeet + 0.9, 0)
	tag.LightInfluence = 0
	tag.MaxDistance = 160
	tag.Adornee = root
	tag.Parent = model
	local nameLabel = label(tag, "Name", UDim2.fromScale(1, 0.55), UDim2.fromScale(0.5, 0.3))
	nameLabel.Text = ghost.name
	local scoreLabel = label(tag, "Score", UDim2.fromScale(1, 0.45), UDim2.fromScale(0.5, 0.78))
	scoreLabel.TextColor3 = GOLD

	ghost.model = model
	ghost.root = root
	ghost.humanoid = humanoid
	ghost.nameLabel = nameLabel
	ghost.scoreLabel = scoreLabel
	ghost.dimmed = false
	return true
end

local function removeGhost(self: StageView, key: string)
	local ghost = self.ghosts[key]
	if not ghost then
		return
	end
	if ghost.model then
		(ghost.model :: Model):Destroy()
	end
	if ghost.ropes then
		(ghost.ropes :: RopeView.RopeView):destroy()
	end
	self.ghosts[key] = nil
	if self.spectating == key then
		self.spectating = nil
	end
end

local function hideShown(ghost: Ghost)
	if ghost.model and (ghost.model :: Model).Parent ~= nil then
		(ghost.model :: Model).Parent = nil
	end
	if ghost.ropes then
		(ghost.ropes :: RopeView.RopeView):setCount(0)
	end
end

-- Where a ghost is at `renderAt`: the discrete state of the nearer sample, and the rope clock and
-- height blended between the two samples either side.
local function sampleAt(ghost: Ghost, renderAt: number): (Sample?, number, number)
	local samples = ghost.samples
	local count = #samples
	if count == 0 then
		return nil, 0, 0
	end
	for index = count, 1, -1 do
		local a = samples[index]
		if a.at <= renderAt then
			local b = samples[index + 1]
			if b then
				local t = math.clamp((renderAt - a.at) / math.max(1e-3, b.at - a.at), 0, 1)
				return (if t < 0.5 then a else b), a.tick + (b.tick - a.tick) * t, a.y + (b.y - a.y) * t
			end
			-- Past the newest sample: keep the rope turning a little so a late packet is not a stall.
			local ahead = if a.alive then math.min(renderAt - a.at, 0.3) * SimTuning.TICK_RATE else 0
			return a, a.tick + ahead, a.y
		end
	end
	local first = samples[1]
	return first, first.tick, first.y
end

local function drawGhost(self: StageView, ghost: Ghost, renderAt: number, ground: Vector3, rotation: CFrame,
	right: Vector3, lowGraphics: boolean): number?
	local now = os.clock()
	if not ghost.model then
		if now < ghost.nextBuildAt then
			return nil
		end
		ghost.nextBuildAt = now + REBUILD_SECONDS
		if not buildModel(self, ghost) then
			return nil
		end
	end
	local model = ghost.model :: Model
	if model.Parent ~= self.folder then
		model.Parent = self.folder
	end
	local sample, tickFloat, y = sampleAt(ghost, renderAt)
	if not sample then
		return nil
	end

	local laneGround = ground + right * (ghost.lane * ViewProtocol.LANE_SPACING)
	local root = ghost.root :: BasePart
	root.CFrame = CFrame.new(laneGround + Vector3.new(0, ghost.rootToFeet + y, 0)) * rotation

	local humanoid = ghost.humanoid :: Humanoid
	local desired = if sample.grounded then Enum.HumanoidStateType.Running
		elseif sample.rising then Enum.HumanoidStateType.Jumping
		else Enum.HumanoidStateType.Freefall
	if humanoid:GetState() ~= desired then
		humanoid:ChangeState(desired)
	end
	local airborne = not sample.grounded
	local track = ghost.jumpTrack
	if track then
		if airborne and not ghost.airborne then
			track:Play(0.05)
		elseif not airborne and ghost.airborne then
			track:Stop(0.08)
		end
	end
	ghost.airborne = airborne
	setDimmed(ghost, not sample.alive)

	if ghost.nameLabel then
		(ghost.nameLabel :: TextLabel).Text = ghost.name
	end
	if ghost.scoreLabel then
		(ghost.scoreLabel :: TextLabel).Text = tostring(sample.score)
	end

	if not ghost.ropes then
		ghost.ropes = RopeView.new(self.folder, "Ghost_" .. ghost.key, GHOST_SEGMENTS)
	end
	local ropes = ghost.ropes :: RopeView.RopeView
	ropes:setCount(#sample.ropes)
	for index, nextSweepTick in sample.ropes do
		local period = math.max(1, sample.period)
		local remaining = (nextSweepTick - tickFloat) % period
		local angle = math.pi - (remaining / period) * math.pi * 2
		ropes:draw(index, laneGround, angle, index <= (sample.burning or 0),
			sample.guarded[index] == true, y,
			lowGraphics)
	end
	return y
end

-- Every other player's real character is hidden on this client; their ghost is drawn instead.
local function hideRealCharacters()
	for _, other in Players:GetPlayers() do
		local character = other ~= player and other.Character
		if character then
			for _, descendant in character:GetDescendants() do
				if descendant:IsA("BasePart") or descendant:IsA("Decal") then
					(descendant :: any).LocalTransparencyModifier = 1
				end
			end
		end
	end
end

local function candidates(self: StageView): { Ghost }
	local list = {}
	for _, ghost in self.ghosts do
		if not ghost.out and latest(ghost) ~= nil then
			table.insert(list, ghost)
		end
	end
	table.sort(list, standing)
	return list
end

local function cycle(self: StageView, step: number)
	local list = candidates(self)
	if #list == 0 then
		return
	end
	local at = 1
	for index, ghost in list do
		if ghost.key == self.spectating then
			at = index
			break
		end
	end
	self.spectating = list[((at - 1 + step) % #list) + 1].key
end

function StageView.new(): StageView
	local folder = workspace:FindFirstChild("SkipsStage")
	if folder then
		folder:Destroy()
	end
	local stageFolder = Instance.new("Folder")
	stageFolder.Name = "SkipsStage"
	stageFolder.Parent = workspace

	-- The spectate bar: who you are watching, with an arrow either side.
	local gui = Instance.new("ScreenGui")
	gui.Name = "SkipsSpectate"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 15
	gui.Parent = player:WaitForChild("PlayerGui")
	local bar = Instance.new("Frame")
	bar.Name = "Spectate"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -24)
	bar.Size = UDim2.fromOffset(430, 70)
	bar.BackgroundColor3 = PANEL
	bar.BackgroundTransparency = 0.06
	bar.BorderSizePixel = 0
	bar.Visible = false
	bar.Parent = gui
	corner(bar, 22)
	stroke(bar, INK, 4)
	local caption = label(bar, "Caption", UDim2.new(0.6, 0, 0, 18), UDim2.new(0.5, 0, 0, -14))
	caption.Text = "YOU'RE OUT  •  WATCHING"
	caption.TextColor3 = CREAM
	local barName = label(bar, "Name", UDim2.fromScale(0.6, 0.5), UDim2.fromScale(0.5, 0.36))
	local barScore = label(bar, "Score", UDim2.fromScale(0.6, 0.36), UDim2.fromScale(0.5, 0.76))
	barScore.TextColor3 = GOLD
	local prevButton = arrow(bar, "Previous", "<", 0.09)
	local nextButton = arrow(bar, "Next", ">", 0.91)

	local self = setmetatable({
		folder = stageFolder,
		ghosts = {},
		inMatch = false,
		youOut = false,
		spectating = nil,
		bar = bar,
		barName = barName,
		barScore = barScore,
		prevButton = prevButton,
		nextButton = nextButton,
		hideClock = 0,
		hideOthers = false,
	}, StageView) :: any

	prevButton.Activated:Connect(function()
		cycle(self, -1)
	end)
	nextButton.Activated:Connect(function()
		cycle(self, 1)
	end)

	local remoteFolder = ReplicatedStorage:WaitForChild(RunProtocol.REMOTE_FOLDER)
	local viewRemote = remoteFolder:WaitForChild(ViewProtocol.REMOTE_NAME) :: RemoteEvent
	viewRemote.OnClientEvent:Connect(function(op, payload)
		if op == ViewProtocol.SERVER.VIEW and typeof(payload) == "table" then
			self:receive(payload)
		end
	end)
	return self
end

function StageView.receive(self: StageView, payload: any)
	local at = if typeof(payload.at) == "number" then payload.at else workspace:GetServerTimeNow()
	self.inMatch = payload.match == true
	self.youOut = payload.out == true
	local seen: { [string]: boolean } = {}
	if typeof(payload.entries) == "table" then
		for _, raw in payload.entries do
			if typeof(raw) == "table" and typeof(raw.key) == "string" then
				local key = raw.key :: string
				seen[key] = true
				local ghost = self.ghosts[key]
				if not ghost then
					ghost = newGhost(key)
					self.ghosts[key] = ghost
				end
				local g = ghost :: Ghost
				g.name = tostring(raw.name or "")
				g.rig = if typeof(raw.rig) == "string" then raw.rig else nil
				g.player = if typeof(raw.player) == "number" then raw.player else nil
				g.out = raw.out == true
				g.lastSeen = at
				if typeof(raw.tick) == "number" and typeof(raw.ropes) == "table" then
					table.insert(g.samples, {
						at = at,
						tick = raw.tick,
						y = tonumber(raw.y) or 0,
						grounded = raw.grounded == true,
						rising = raw.rising == true,
						alive = raw.alive == true,
						score = tonumber(raw.score) or 0,
						burning = math.max(0, math.floor(tonumber(raw.burning) or 0)),
						guarded = if typeof(raw.guarded) == "table" then raw.guarded else {},
						period = tonumber(raw.period) or 120,
						ropes = raw.ropes,
					})
					while #g.samples > MAX_SAMPLES do
						table.remove(g.samples, 1)
					end
				end
			end
		end
	end
	-- Anyone the server stopped naming is gone: they left, or the lineup changed with the mode.
	for key in self.ghosts do
		if not seen[key] then
			removeGhost(self, key)
		end
	end
end

function StageView.isSpectating(self: StageView): boolean
	return self.inMatch and self.youOut and self.spectating ~= nil
end

function StageView.isInMatch(self: StageView): boolean
	return self.inMatch
end

--[[
	"Hide other players" (the user, 2026-09-11: "an option for the player to just center the camera on
	him during any point"). Nobody else is drawn and the camera frames only your lane -- solo, casual,
	ranked or duel alike. Once you are out of a match the run you are watching is still drawn, since
	there is nobody else left to centre on. Presentation only: every run plays on exactly the same.
]]
function StageView.setHideOthers(self: StageView, hide: boolean)
	self.hideOthers = hide
end

-- The match opponents still running, best first. SPLAT uses only whether this is empty; the paid
-- group roster is rebuilt authoritatively on the server. Empty outside a match.
function StageView.opponents(self: StageView): { Opponent }
	local list: { Opponent } = {}
	if not self.inMatch then
		return list
	end
	for _, ghost in self.ghosts do
		local sample = latest(ghost)
		if not ghost.out and sample and sample.alive then
			table.insert(list, { key = ghost.key, name = ghost.name, score = sample.score })
		end
	end
	table.sort(list, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.key < b.key
	end)
	return list
end

--[[
	Called once a frame, before the camera is placed. Draws every shown ghost in its lane and returns
	how the camera should frame them: the span of lanes on screen, and -- while spectating -- whose lane
	and height to follow instead of your own.
]]
function StageView.update(self: StageView, dt: number, ground: Vector3, baseRoot: CFrame, right: Vector3,
	lowGraphics: boolean): Framing
	self.hideClock += dt
	if self.hideClock >= HIDE_SWEEP_SECONDS then
		self.hideClock = 0
		hideRealCharacters()
	end

	-- Free the lanes of anyone who went out: "when a player loses, they're removed".
	local used: { [number]: boolean } = {}
	for _, ghost in self.ghosts do
		if ghost.slot and (ghost.out or latest(ghost) == nil) then
			ghost.slot = nil
		end
		if ghost.slot then
			used[ghost.slot :: number] = true
		end
	end
	-- Fill free lanes with the best-placed runners not yet shown.
	local waiting: { Ghost } = {}
	for _, ghost in self.ghosts do
		if not ghost.slot and not ghost.out and latest(ghost) ~= nil then
			table.insert(waiting, ghost)
		end
	end
	table.sort(waiting, standing)
	for slot = 1, math.min(#LANE_SLOTS, ViewProtocol.MAX_SHOWN) do
		if not used[slot] then
			local ghost = table.remove(waiting, 1)
			if not ghost then
				break
			end
			ghost.slot = slot
			ghost.lane = LANE_SLOTS[slot]
			used[slot] = true
		end
	end

	-- Spectating: once you are out of a match, watch the runs still going, arrows to change.
	local spectate = self.inMatch and self.youOut
	if spectate then
		local target = self.spectating and self.ghosts[self.spectating :: string]
		if not target or target.out then
			local list = candidates(self)
			self.spectating = if #list > 0 then list[1].key else nil
		end
		-- The watched run always has a lane: if it has none, it takes the first one.
		local watched = self.spectating and self.ghosts[self.spectating :: string]
		if watched and not watched.slot then
			for _, ghost in self.ghosts do
				if ghost.slot == 1 then
					ghost.slot = nil
				end
			end
			watched.slot = 1
			watched.lane = LANE_SLOTS[1]
		end
	else
		self.spectating = nil
	end

	local renderAt = workspace:GetServerTimeNow() - ViewProtocol.RENDER_DELAY_SECONDS
	local rotation = baseRoot.Rotation
	local minLane, maxLane = 0, 0
	local focusLane: number? = nil
	local focusY: number? = nil
	for _, ghost in self.ghosts do
		-- Hiding others leaves only the run you are watching once you are out.
		if ghost.slot and (not self.hideOthers or ghost.key == self.spectating) then
			local target = LANE_SLOTS[ghost.slot :: number]
			ghost.lane += (target - ghost.lane) * math.min(1, dt / LANE_SLIDE_SECONDS)
			local y = drawGhost(self, ghost, renderAt, ground, rotation, right, lowGraphics)
			minLane = math.min(minLane, target)
			maxLane = math.max(maxLane, target)
			if ghost.key == self.spectating and y then
				focusLane = ghost.lane
				focusY = y
			end
		else
			hideShown(ghost)
		end
	end

	local watched = self.spectating and self.ghosts[self.spectating :: string]
	self.bar.Visible = watched ~= nil
	if watched then
		local sample = latest(watched)
		self.barName.Text = watched.name
		self.barScore.Text = if sample then tostring(sample.score) else ""
		self.prevButton.Visible = #candidates(self) > 1
		self.nextButton.Visible = self.prevButton.Visible
	end

	return { minLane = minLane, maxLane = maxLane, focusLane = focusLane, focusY = focusY }
end

return StageView
