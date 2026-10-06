--!strict
--[[
	SettingsClient — the gear in the corner: sound, graphics, other players, and codes; and the quick
	HIDE OTHERS button in the bottom-right corner.

	CLIENT SETTINGS ARE PRESENTATION ONLY. The server stores them so they follow
	the player between sessions; nothing that decides a run ever reads one. A code is the one thing on
	this panel with value, and the client only sends what was typed -- the SERVER decides what, if
	anything, it is worth.

	HIDE OTHER PLAYERS (the user, 2026-09-11: "add an option for the player to just center the camera on
	him during any point, ranked, solo, matchmaking, duo... like a 'Hide other players'"). One setting,
	two switches: a row on this panel, and a button on the HUD so it can be flipped mid-run without
	opening anything. Remembered like the others.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerProtocol = require(Shared:WaitForChild("PlayerProtocol"))
local RunProtocol = require(Shared:WaitForChild("RunProtocol"))

local SettingsClient = {}

local INK = Color3.fromRGB(40, 36, 61)
local PAPER = Color3.fromRGB(255, 253, 244)
local CREAM = Color3.fromRGB(255, 244, 211)
local PANEL = Color3.fromRGB(46, 42, 70)
local MUTED = Color3.fromRGB(157, 147, 164)
local GREEN = Color3.fromRGB(76, 181, 128)
local CORAL = Color3.fromRGB(240, 84, 74)
local BLUE = Color3.fromRGB(93, 151, 213)
local PURPLE = Color3.fromRGB(145, 111, 207)

local PANEL_W, PANEL_H = 440, 540

local player = Players.LocalPlayer
local remoteFolder = ReplicatedStorage:WaitForChild(RunProtocol.REMOTE_FOLDER)
local playerRemote = remoteFolder:WaitForChild(PlayerProtocol.REMOTE_NAME) :: RemoteEvent

local gui = Instance.new("ScreenGui")
gui.Name = "SkipsSettings"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 30
gui.Parent = player:WaitForChild("PlayerGui")

local function corner(object: GuiObject, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = object
end

local function stroke(object: GuiObject, colour: Color3, thickness: number): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = colour
	s.Thickness = thickness
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = object
	return s
end

local function words(parent: Instance, name: string, text: string, size: number,
	box: Vector2, centre: Vector2): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Size = UDim2.fromOffset(box.X, box.Y)
	label.Position = UDim2.fromOffset(centre.X, centre.Y)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.Text = text
	label.TextSize = size
	label.TextColor3 = PAPER
	label.TextStrokeColor3 = INK
	label.TextStrokeTransparency = 0.1
	label.Parent = parent
	return label
end

local function chip(parent: Instance, name: string, text: string, box: Vector2, centre: Vector2): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.Size = UDim2.fromOffset(box.X, box.Y)
	b.Position = UDim2.fromOffset(centre.X, centre.Y)
	b.BackgroundColor3 = MUTED
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Font = Enum.Font.FredokaOne
	b.Text = text
	b.TextSize = 18
	b.TextColor3 = PAPER
	b.TextStrokeColor3 = INK
	b.TextStrokeTransparency = 0.25
	b.Parent = parent
	corner(b, 14)
	stroke(b, INK, 3)
	return b
end

-- ── the corner gear ──────────────────────────────────────────────────────────────────────────
-- In the left-edge column: VS, TOP, tickets, settings, style.
local openButton = chip(gui, "Open", "⚙", Vector2.new(76, 48), Vector2.new(52, 284))
openButton.BackgroundColor3 = BLUE
openButton.TextSize = 28

-- ── the quick switch ─────────────────────────────────────────────────────────────────────────
-- Bottom right, clear of the spectate bar, the fuel gauge and the upgrade bar: one tap, mid-run.
local hideButton = chip(gui, "HideOthers", "HIDE OTHERS", Vector2.new(150, 44), Vector2.new(0, 0))
hideButton.AnchorPoint = Vector2.new(1, 1)
hideButton.Position = UDim2.new(1, -14, 1, -14)
hideButton.TextSize = 17
hideButton.BackgroundColor3 = PURPLE

-- ── the panel ────────────────────────────────────────────────────────────────────────────────
local popout = Instance.new("Frame")
popout.Name = "Settings"
popout.AnchorPoint = Vector2.new(0.5, 0.5)
popout.Position = UDim2.fromScale(0.5, 0.5)
popout.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
popout.BackgroundTransparency = 1
popout.Visible = false
popout.Parent = gui
local fitScale = Instance.new("UIScale")
fitScale.Parent = popout

local shadow = Instance.new("Frame")
shadow.Name = "Shadow"
shadow.Size = UDim2.fromScale(1, 1)
shadow.Position = UDim2.fromOffset(7, 8)
shadow.BackgroundColor3 = INK
shadow.BorderSizePixel = 0
shadow.Parent = popout
corner(shadow, 26)

local panel = Instance.new("Frame")
panel.Name = "Panel"
-- A tap on an open panel belongs to it, never a jump (InputController).
panel.Active = true
panel.Size = UDim2.fromScale(1, 1)
panel.BackgroundColor3 = PANEL
panel.BorderSizePixel = 0
panel.Parent = popout
corner(panel, 26)
stroke(panel, INK, 4)

words(panel, "Title", "SETTINGS", 34, Vector2.new(PANEL_W - 130, 40), Vector2.new(PANEL_W / 2, 36))
local closeButton = chip(panel, "Close", "X", Vector2.new(38, 38), Vector2.new(PANEL_W - 30, 30))
closeButton.BackgroundColor3 = CORAL

-- Sound: a continuous, pointer-draggable bar. Minus and plus remain as accessible five-percent
-- nudges for gamepad, keyboard selection and anyone who finds a small drag awkward on mobile.
words(panel, "SoundHeading", "SOUND", 20, Vector2.new(PANEL_W - 60, 24), Vector2.new(PANEL_W / 2, 90))
local soundValue = words(panel, "SoundValue", "100%", 17, Vector2.new(72, 24), Vector2.new(354, 90))
soundValue.TextXAlignment = Enum.TextXAlignment.Right

local soundTrack = Instance.new("Frame")
soundTrack.Name = "SoundSlider"
soundTrack.AnchorPoint = Vector2.new(0.5, 0.5)
soundTrack.Size = UDim2.fromOffset(280, 18)
soundTrack.Position = UDim2.fromOffset(PANEL_W / 2, 128)
soundTrack.BackgroundColor3 = Color3.fromRGB(25, 23, 42)
soundTrack.BorderSizePixel = 0
soundTrack.Parent = panel
corner(soundTrack, 9)
stroke(soundTrack, INK, 3)

local soundFill = Instance.new("Frame")
soundFill.Name = "Fill"
soundFill.Size = UDim2.fromScale(1, 1)
soundFill.BackgroundColor3 = GREEN
soundFill.BorderSizePixel = 0
soundFill.ZIndex = 2
soundFill.Parent = soundTrack
corner(soundFill, 9)

local soundKnob = Instance.new("Frame")
soundKnob.Name = "Knob"
soundKnob.AnchorPoint = Vector2.new(0.5, 0.5)
soundKnob.Size = UDim2.fromOffset(28, 28)
soundKnob.Position = UDim2.fromScale(1, 0.5)
soundKnob.BackgroundColor3 = PAPER
soundKnob.BorderSizePixel = 0
soundKnob.ZIndex = 3
soundKnob.Parent = soundTrack
corner(soundKnob, 14)
stroke(soundKnob, INK, 3)

local soundHit = Instance.new("TextButton")
soundHit.Name = "SoundSliderInput"
soundHit.AnchorPoint = Vector2.new(0.5, 0.5)
soundHit.Size = UDim2.fromOffset(310, 48)
soundHit.Position = UDim2.fromOffset(PANEL_W / 2, 128)
soundHit.BackgroundTransparency = 1
soundHit.Text = ""
soundHit.AutoButtonColor = false
soundHit.ZIndex = 4
soundHit.Parent = panel

local soundMinus = chip(panel, "SoundDown", "−", Vector2.new(38, 38), Vector2.new(47, 128))
local soundPlus = chip(panel, "SoundUp", "+", Vector2.new(38, 38), Vector2.new(PANEL_W - 47, 128))
soundMinus.TextSize = 24
soundPlus.TextSize = 24

-- Graphics: normal or low.
words(panel, "GraphicsHeading", "GRAPHICS", 20, Vector2.new(PANEL_W - 60, 24), Vector2.new(PANEL_W / 2, 178))
local normalChip = chip(panel, "GraphicsNormal", "NORMAL", Vector2.new(170, 38), Vector2.new(PANEL_W / 2 - 92, 214))
local lowChip = chip(panel, "GraphicsLow", "LOW", Vector2.new(170, 38), Vector2.new(PANEL_W / 2 + 92, 214))
local graphicsNote = words(panel, "GraphicsNote", "LOW TURNS OFF SHADOWS, GLOW AND FAR SCENERY", 13,
	Vector2.new(PANEL_W - 60, 18), Vector2.new(PANEL_W / 2, 246))
graphicsNote.TextColor3 = MUTED

-- Other players: shown in lanes beside you, or hidden with the camera on you alone.
words(panel, "PlayersHeading", "OTHER PLAYERS", 20, Vector2.new(PANEL_W - 60, 24), Vector2.new(PANEL_W / 2, 290))
local showChip = chip(panel, "PlayersShow", "SHOW", Vector2.new(170, 38), Vector2.new(PANEL_W / 2 - 92, 326))
local hideChip = chip(panel, "PlayersHide", "HIDE", Vector2.new(170, 38), Vector2.new(PANEL_W / 2 + 92, 326))
local playersNote = words(panel, "PlayersNote", "HIDE PUTS THE CAMERA ON YOU ALONE, IN EVERY MODE", 13,
	Vector2.new(PANEL_W - 60, 18), Vector2.new(PANEL_W / 2, 358))
playersNote.TextColor3 = MUTED

-- Codes.
words(panel, "CodeHeading", "REDEEM A CODE", 20, Vector2.new(PANEL_W - 60, 24), Vector2.new(PANEL_W / 2, 402))
local codeBox = Instance.new("TextBox")
codeBox.Name = "Code"
codeBox.AnchorPoint = Vector2.new(0.5, 0.5)
codeBox.Size = UDim2.fromOffset(250, 40)
codeBox.Position = UDim2.fromOffset(28 + 125, 442)
codeBox.BackgroundColor3 = Color3.fromRGB(25, 23, 42)
codeBox.BorderSizePixel = 0
codeBox.ClearTextOnFocus = false
codeBox.Font = Enum.Font.FredokaOne
codeBox.PlaceholderText = "TYPE A CODE"
codeBox.PlaceholderColor3 = MUTED
codeBox.Text = ""
codeBox.TextColor3 = PAPER
codeBox.TextSize = 20
codeBox.Parent = panel
corner(codeBox, 12)
stroke(codeBox, INK, 3)
local redeemButton = chip(panel, "Redeem", "REDEEM", Vector2.new(120, 40), Vector2.new(PANEL_W - 28 - 60, 442))
redeemButton.BackgroundColor3 = GREEN
local codeStatus = words(panel, "CodeStatus", "", 16, Vector2.new(PANEL_W - 60, 22), Vector2.new(PANEL_W / 2, 484))
codeStatus.TextColor3 = CREAM
local savedNote = words(panel, "Unsaved", "SETTINGS CAN'T BE SAVED IN THIS SESSION", 13,
	Vector2.new(PANEL_W - 60, 18), Vector2.new(PANEL_W / 2, PANEL_H - 22))
savedNote.TextColor3 = MUTED
savedNote.Visible = false

-- ── state ────────────────────────────────────────────────────────────────────────────────────
local current = { sound = PlayerProtocol.DEFAULT_SOUND, lowGraphics = false, hideOthers = false }
local listeners: { (number, boolean, boolean) -> () } = {}

local function paint()
	soundFill.Size = UDim2.fromScale(current.sound, 1)
	soundKnob.Position = UDim2.fromScale(current.sound, 0.5)
	soundValue.Text = string.format("%d%%", math.floor(current.sound * 100 + 0.5))
	normalChip.BackgroundColor3 = if current.lowGraphics then MUTED else GREEN
	lowChip.BackgroundColor3 = if current.lowGraphics then GREEN else MUTED
	showChip.BackgroundColor3 = if current.hideOthers then MUTED else GREEN
	hideChip.BackgroundColor3 = if current.hideOthers then GREEN else MUTED
	hideButton.Text = if current.hideOthers then "SHOW OTHERS" else "HIDE OTHERS"
	hideButton.BackgroundColor3 = if current.hideOthers then GREEN else PURPLE
	savedNote.Visible = player:GetAttribute(PlayerProtocol.ATTRIBUTE.SAVED) == false
end

local function notify()
	for _, callback in listeners do
		task.spawn(callback, current.sound, current.lowGraphics, current.hideOthers)
	end
end

local function readAttributes()
	local sound = player:GetAttribute(PlayerProtocol.ATTRIBUTE.SOUND)
	current.sound = if typeof(sound) == "number"
		and sound >= PlayerProtocol.SOUND_MIN and sound <= PlayerProtocol.SOUND_MAX
		then PlayerProtocol.normaliseSound(sound)
		else PlayerProtocol.DEFAULT_SOUND
	current.lowGraphics = player:GetAttribute(PlayerProtocol.ATTRIBUTE.LOW_GRAPHICS) == true
	current.hideOthers = player:GetAttribute(PlayerProtocol.ATTRIBUTE.HIDE_OTHERS) == true
	paint()
	notify()
end

-- Applied at once, then sent for saving: a setting must never wait on the network to take effect.
local function choose(sound: number, lowGraphics: boolean, hideOthers: boolean)
	current.sound = PlayerProtocol.normaliseSound(sound)
	current.lowGraphics = lowGraphics
	current.hideOthers = hideOthers
	paint()
	notify()
	playerRemote:FireServer(PlayerProtocol.CLIENT.SET_SETTINGS,
		{ sound = current.sound, lowGraphics = lowGraphics, hideOthers = hideOthers })
end

local soundDragging = false
local soundTouch: InputObject? = nil
local soundChangedDuringDrag = false

local function previewSoundAt(screenX: number)
	local width = soundTrack.AbsoluteSize.X
	if width <= 0 then
		return
	end
	local level = (screenX - soundTrack.AbsolutePosition.X) / width
	local normalised = PlayerProtocol.normaliseSound(level)
	if normalised == current.sound then
		return
	end
	current.sound = normalised
	soundChangedDuringDrag = true
	paint()
	notify()
end

local function finishSoundDrag()
	if not soundDragging then
		return
	end
	soundDragging = false
	soundTouch = nil
	if soundChangedDuringDrag then
		soundChangedDuringDrag = false
		choose(current.sound, current.lowGraphics, current.hideOthers)
	end
end

soundHit.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		soundDragging = true
		soundTouch = if input.UserInputType == Enum.UserInputType.Touch then input else nil
		previewSoundAt(input.Position.X)
	end
end)
UserInputService.InputChanged:Connect(function(input)
	if soundDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input == soundTouch) then
		previewSoundAt(input.Position.X)
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if soundDragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input == soundTouch) then
		finishSoundDrag()
	end
end)
soundMinus.Activated:Connect(function()
	choose(current.sound - 0.05, current.lowGraphics, current.hideOthers)
end)
soundPlus.Activated:Connect(function()
	choose(current.sound + 0.05, current.lowGraphics, current.hideOthers)
end)
normalChip.Activated:Connect(function()
	choose(current.sound, false, current.hideOthers)
end)
lowChip.Activated:Connect(function()
	choose(current.sound, true, current.hideOthers)
end)
showChip.Activated:Connect(function()
	choose(current.sound, current.lowGraphics, false)
end)
hideChip.Activated:Connect(function()
	choose(current.sound, current.lowGraphics, true)
end)
hideButton.Activated:Connect(function()
	choose(current.sound, current.lowGraphics, not current.hideOthers)
end)

local function redeem()
	local typed = codeBox.Text
	if typed:gsub("%s+", "") == "" then
		codeStatus.Text = "TYPE A CODE FIRST"
		codeStatus.TextColor3 = CREAM
		return
	end
	codeStatus.Text = "CHECKING…"
	codeStatus.TextColor3 = CREAM
	playerRemote:FireServer(PlayerProtocol.CLIENT.REDEEM_CODE, typed)
end
redeemButton.Activated:Connect(redeem)
codeBox.FocusLost:Connect(function(enterPressed)
	if enterPressed then
		redeem()
	end
end)

playerRemote.OnClientEvent:Connect(function(op, payload)
	if op ~= PlayerProtocol.SERVER.CODE_RESULT or typeof(payload) ~= "table" then
		return
	end
	local data = payload :: any
	codeStatus.Text = tostring(data.message or "")
	codeStatus.TextColor3 = if data.ok then GREEN else CORAL
	if data.ok then
		codeBox.Text = ""
	end
end)

openButton.Activated:Connect(function()
	popout.Visible = not popout.Visible
	if popout.Visible then
		codeStatus.Text = ""
		paint()
	end
end)
closeButton.Activated:Connect(function()
	popout.Visible = false
end)

for _, attribute in {
	PlayerProtocol.ATTRIBUTE.SOUND, PlayerProtocol.ATTRIBUTE.LOW_GRAPHICS, PlayerProtocol.ATTRIBUTE.HIDE_OTHERS,
} do
	player:GetAttributeChangedSignal(attribute):Connect(readAttributes)
end
player:GetAttributeChangedSignal(PlayerProtocol.ATTRIBUTE.SAVED):Connect(paint)

-- Fit on small screens, like the other popouts.
local function fit()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local viewport = camera.ViewportSize
	fitScale.Scale = math.clamp(math.min(viewport.Y / (PANEL_H + 60), viewport.X / (PANEL_W + 40)), 0.5, 1)
end
fit()
local camera = workspace.CurrentCamera
if camera then
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
end

-- Called now with the current values, and again whenever they change: sound level, low graphics, and
-- whether other players are hidden.
function SettingsClient.onChanged(callback: (number, boolean, boolean) -> ())
	table.insert(listeners, callback)
	task.spawn(callback, current.sound, current.lowGraphics, current.hideOthers)
end

readAttributes()

return SettingsClient
