--!strict
--[[
	DistractionClient — what a splatted player sees and hears.

	PRESENTATION ONLY. It draws over the screen and plays a sound; it never touches the simulation,
	never reads or consumes input, and never decides anything. The victim's run carries on underneath
	exactly as before — they just cannot see it. Every rule about who may be splatted lives on the
	server (`DistractionService`).

	PROCEDURAL, SO IT NEEDS NO UPLOAD. The splat is built from rounded frames rather than an image, so
	it works the moment it ships: no asset to upload, no moderation queue to wait on, and nothing in it
	that could ever push the game's age rating up. `Distraction.IMAGE_ID` can layer uploaded art on
	top later.

	SHAKES, NEVER FLASHES. The splat is shown once and hidden once. In between it moves — a sum of
	sines, so it wobbles hard without jumping randomly — and it fades out at the end. Nothing toggles
	on and off, because rapid flashing is the photosensitivity risk, and motion is not.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Distraction = require(Shared:WaitForChild("Distraction"))
local RunProtocol = require(Shared:WaitForChild("RunProtocol"))

local DistractionClient = {}

local remoteFolder = ReplicatedStorage:WaitForChild(RunProtocol.REMOTE_FOLDER)
local remote = remoteFolder:WaitForChild(Distraction.REMOTE_NAME) :: RemoteEvent

local INK = Color3.fromRGB(40, 36, 61)
local GOO = Color3.fromRGB(128, 222, 92)
local SHINE = Color3.fromRGB(206, 250, 176)
local PAPER = Color3.fromRGB(255, 253, 244)

-- Sized against screen HEIGHT, so the splat stays round on every aspect ratio and always buries the
-- middle of the screen, which is exactly where the rope is.
local BLOB_SCALE = 1.35

-- x, y, diameter — fractions of the blob.
local LOBES = {
	{ 0.50, 0.48, 0.62 }, { 0.30, 0.40, 0.38 }, { 0.70, 0.38, 0.40 }, { 0.34, 0.66, 0.34 },
	{ 0.68, 0.64, 0.36 }, { 0.50, 0.24, 0.30 }, { 0.18, 0.58, 0.20 }, { 0.82, 0.55, 0.22 },
}
local FLECKS = {
	{ 0.06, 0.18, 0.07 }, { 0.93, 0.22, 0.06 }, { 0.10, 0.86, 0.08 }, { 0.90, 0.84, 0.06 },
	{ 0.24, 0.10, 0.05 }, { 0.78, 0.08, 0.05 }, { 0.50, 0.95, 0.05 },
}
-- x, top, width, reach — a drip grows from `top` by up to `reach` over the splat's life.
local DRIPS = {
	{ 0.30, 0.70, 0.075, 0.30 }, { 0.45, 0.76, 0.060, 0.42 },
	{ 0.58, 0.74, 0.070, 0.24 }, { 0.71, 0.68, 0.060, 0.36 },
}
local OUTLINE = 1.07

local player = Players.LocalPlayer
local gui = Instance.new("ScreenGui")
gui.Name = "SkipsDistraction"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
-- Above everything, card offers and match screens included: the whole point is that you cannot see.
gui.DisplayOrder = 100
gui.Parent = player:WaitForChild("PlayerGui")

local canvas = Instance.new("CanvasGroup")
canvas.Name = "Splat"
canvas.AnchorPoint = Vector2.new(0.5, 0.5)
canvas.Position = UDim2.fromScale(0.5, 0.5)
canvas.Size = UDim2.fromScale(1, 1)
canvas.BackgroundTransparency = 1
canvas.Visible = false
canvas.Parent = gui

local blob = Instance.new("Frame")
blob.Name = "Blob"
blob.AnchorPoint = Vector2.new(0.5, 0.5)
blob.Position = UDim2.fromScale(0.5, 0.5)
blob.Size = UDim2.fromScale(BLOB_SCALE, BLOB_SCALE)
blob.SizeConstraint = Enum.SizeConstraint.RelativeYY
blob.BackgroundTransparency = 1
blob.Parent = canvas

local function round(frame: Frame)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = frame
end

local function disc(x: number, y: number, d: number, color: Color3, z: number): Frame
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(x, y)
	frame.Size = UDim2.fromScale(d, d)
	frame.BackgroundColor3 = color
	frame.BorderSizePixel = 0
	frame.ZIndex = z
	frame.Parent = blob
	round(frame)
	return frame
end

-- Outline pass first, every shape slightly larger in ink, then the goo on top. The overlapping
-- shapes merge into one silhouette with a single outer outline — the same dilation trick the icon
-- and thumbnails use, just built from frames.
for _, shape in LOBES do
	disc(shape[1], shape[2], shape[3] * OUTLINE, INK, 1)
end
for _, shape in FLECKS do
	disc(shape[1], shape[2], shape[3] * 1.25, INK, 1)
end
for _, shape in LOBES do
	disc(shape[1], shape[2], shape[3], GOO, 2)
end
for _, shape in FLECKS do
	disc(shape[1], shape[2], shape[3], GOO, 2)
end
disc(0.40, 0.34, 0.12, SHINE, 3)
disc(0.33, 0.30, 0.05, SHINE, 3)

type Drip = { ink: Frame, goo: Frame, width: number, reach: number }
local drips: { Drip } = {}
for _, spec in DRIPS do
	local function pill(color: Color3, width: number, z: number): Frame
		local frame = Instance.new("Frame")
		frame.AnchorPoint = Vector2.new(0.5, 0)
		frame.Position = UDim2.fromScale(spec[1], spec[2])
		frame.Size = UDim2.fromScale(width, 0.04)
		frame.BackgroundColor3 = color
		frame.BorderSizePixel = 0
		frame.ZIndex = z
		frame.Parent = blob
		round(frame)
		return frame
	end
	table.insert(drips, {
		ink = pill(INK, spec[3] * 1.35, 1),
		goo = pill(GOO, spec[3], 2),
		width = spec[3],
		reach = spec[4],
	})
end

local word = Instance.new("TextLabel")
word.Name = "Word"
word.AnchorPoint = Vector2.new(0.5, 0.5)
word.Position = UDim2.fromScale(0.5, 0.50)
word.Size = UDim2.fromScale(0.68, 0.18)
word.Rotation = -8
word.BackgroundTransparency = 1
word.Font = Enum.Font.FredokaOne
word.Text = "SPLAT!"
word.TextScaled = true
word.TextColor3 = PAPER
word.TextStrokeColor3 = INK
word.TextStrokeTransparency = 0
word.ZIndex = 5
word.Parent = blob

local byline = Instance.new("TextLabel")
byline.Name = "Byline"
byline.AnchorPoint = Vector2.new(0.5, 0.5)
byline.Position = UDim2.fromScale(0.5, 0.62)
byline.Size = UDim2.fromScale(0.5, 0.06)
byline.Rotation = -8
byline.BackgroundTransparency = 1
byline.Font = Enum.Font.FredokaOne
byline.Text = ""
byline.TextScaled = true
byline.TextColor3 = PAPER
byline.TextStrokeColor3 = INK
byline.TextStrokeTransparency = 0
byline.ZIndex = 5
byline.Parent = blob

if Distraction.IMAGE_ID ~= "" then
	local art = Instance.new("ImageLabel")
	art.Name = "Art"
	art.AnchorPoint = Vector2.new(0.5, 0.5)
	art.Position = UDim2.fromScale(0.5, 0.5)
	art.Size = UDim2.fromScale(0.9, 0.9)
	art.BackgroundTransparency = 1
	art.Image = Distraction.IMAGE_ID
	art.ScaleType = Enum.ScaleType.Fit
	art.ZIndex = 4
	art.Parent = blob
end

local startedAt = 0
local duration = Distraction.DURATION_SECONDS
local stepConnection: RBXScriptConnection? = nil

local function stop()
	canvas.Visible = false
	canvas.GroupTransparency = 0
	local connection = stepConnection
	if connection then
		connection:Disconnect()
		stepConnection = nil
	end
end

local function frame()
	local t = os.clock() - startedAt
	if t >= duration then
		stop()
		return
	end

	-- Pop in over the first quarter second, overshooting slightly, then settle.
	local pop = if t < 0.12
		then 0.55 + (t / 0.12) * 0.55
		elseif t < 0.25 then 1.10 - ((t - 0.12) / 0.13) * 0.10
		else 1.0
	-- Wobble hardest at the start and ease off across the final second.
	local settle = math.clamp((duration - t) / 1.0, 0, 1)
	local amplitude = Distraction.SHAKE_PIXELS * (0.35 + 0.65 * settle)
	local dx = math.sin(t * 23) * amplitude + math.sin(t * 41) * amplitude * 0.45
	local dy = math.cos(t * 19) * amplitude * 0.8 + math.sin(t * 37) * amplitude * 0.35
	blob.Position = UDim2.new(0.5, dx, 0.5, dy)
	blob.Rotation = math.sin(t * 13) * Distraction.SHAKE_DEGREES * settle
	blob.Size = UDim2.fromScale(BLOB_SCALE * pop, BLOB_SCALE * pop)

	-- The drips run for the whole life of the splat.
	local grow = math.clamp(t / duration, 0, 1)
	for _, drip in drips do
		local height = 0.04 + drip.reach * grow
		drip.ink.Size = UDim2.fromScale(drip.width * 1.35, height + 0.012)
		drip.goo.Size = UDim2.fromScale(drip.width, height)
	end

	local fadeFrom = duration - Distraction.FADE_SECONDS
	canvas.GroupTransparency = if t > fadeFrom
		then math.clamp((t - fadeFrom) / Distraction.FADE_SECONDS, 0, 1)
		else 0
end

local function play(seconds: number, fromName: string?)
	-- Clamped here as well as on the server: presentation must never be the thing that holds a
	-- player blind for longer than the rule allows.
	duration = math.clamp(seconds, Distraction.MIN_SECONDS, Distraction.MAX_SECONDS)
	startedAt = os.clock()
	byline.Text = if fromName and fromName ~= "" then "from " .. fromName else ""
	canvas.GroupTransparency = 0
	canvas.Visible = true

	local sound = Instance.new("Sound")
	sound.Name = "Splat"
	sound.SoundId = Distraction.SOUND_ID
	sound.Volume = Distraction.SOUND_VOLUME
	local group = SoundService:FindFirstChild("SkipsSFX")
	if group and group:IsA("SoundGroup") then
		sound.SoundGroup = group
	end
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, 6)

	if not stepConnection then
		stepConnection = RunService.RenderStepped:Connect(frame)
	end
end

remote.OnClientEvent:Connect(function(op, payload)
	if op ~= Distraction.SERVER.SPLAT then
		return
	end
	local data = if typeof(payload) == "table" then payload :: any else {}
	local seconds = if typeof(data.duration) == "number" then data.duration else Distraction.DURATION_SECONDS
	play(seconds, if typeof(data.fromName) == "string" then data.fromName else nil)
end)

return DistractionClient
