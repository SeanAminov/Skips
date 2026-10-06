--!strict
--[[
	CosmeticsClient — the STYLE button: the placeholder for rope styles and effects.

	The user (2026-09-10): "I also later want to add cosmetics so maybe have that for now so we have
	different looking jump ropes or maybe particle effects etc (will need to work on later, just setup
	button for now)". The looks are already data -- `RopeStyles` holds every rope's four looks as a set --
	so a cosmetic rope will be one more set plus a way to own it, and this panel is where choosing one
	will live. For now it says what is coming, and nothing here can be bought.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RopeStyles = require(Shared:WaitForChild("RopeStyles"))

local CosmeticsClient = {}

local INK = Color3.fromRGB(40, 36, 61)
local PAPER = Color3.fromRGB(255, 253, 244)
local CREAM = Color3.fromRGB(255, 244, 211)
local PANEL = Color3.fromRGB(46, 42, 70)
local MUTED = Color3.fromRGB(157, 147, 164)
local PURPLE = Color3.fromRGB(160, 110, 230)
local CORAL = Color3.fromRGB(240, 84, 74)

local PANEL_W, PANEL_H = 400, 320

local player = Players.LocalPlayer
local gui = Instance.new("ScreenGui")
gui.Name = "SkipsCosmetics"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 30
gui.Parent = player:WaitForChild("PlayerGui")

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

local function words(parent: Instance, name: string, text: string, size: number, box: Vector2,
	centre: Vector2): TextLabel
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
	b.TextSize = 16
	b.TextColor3 = PAPER
	b.TextStrokeColor3 = INK
	b.TextStrokeTransparency = 0.25
	b.Parent = parent
	corner(b, 14)
	stroke(b, INK, 3)
	return b
end

-- Last in the left-edge column before COMMUNITY: VS, TOP, tickets, settings, style.
local openButton = chip(gui, "Open", "STYLE", Vector2.new(76, 48), Vector2.new(52, 340))
openButton.BackgroundColor3 = PURPLE
openButton.TextSize = 19

local popout = Instance.new("Frame")
popout.Name = "Cosmetics"
popout.AnchorPoint = Vector2.new(0.5, 0.5)
popout.Position = UDim2.fromScale(0.5, 0.5)
popout.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
popout.BackgroundTransparency = 1
popout.Visible = false
popout.Parent = gui

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

words(panel, "Title", "STYLE", 34, Vector2.new(PANEL_W - 130, 40), Vector2.new(PANEL_W / 2, 36))
local closeButton = chip(panel, "Close", "X", Vector2.new(38, 38), Vector2.new(PANEL_W - 30, 30))
closeButton.BackgroundColor3 = CORAL

local soon = words(panel, "Soon", "COMING SOON", 30, Vector2.new(PANEL_W - 60, 40), Vector2.new(PANEL_W / 2, 100))
soon.TextColor3 = PURPLE
words(panel, "Ropes", "ROPE STYLES", 20, Vector2.new(PANEL_W - 60, 24), Vector2.new(PANEL_W / 2, 150)).TextColor3 = CREAM
words(panel, "Trails", "JUMP TRAILS  •  LANDING EFFECTS", 18, Vector2.new(PANEL_W - 60, 24),
	Vector2.new(PANEL_W / 2, 182)).TextColor3 = CREAM
local current = RopeStyles.SETS[RopeStyles.DEFAULT_SET]
words(panel, "Current", string.format("YOUR ROPE: %s", string.upper(current.name)), 16,
	Vector2.new(PANEL_W - 60, 22), Vector2.new(PANEL_W / 2, 238)).TextColor3 = MUTED
words(panel, "Note", "LOOKS ONLY  •  NEVER CHANGES HOW A RUN PLAYS", 13, Vector2.new(PANEL_W - 60, 20),
	Vector2.new(PANEL_W / 2, 270)).TextColor3 = MUTED

openButton.Activated:Connect(function()
	popout.Visible = not popout.Visible
end)
closeButton.Activated:Connect(function()
	popout.Visible = false
end)

return CosmeticsClient
