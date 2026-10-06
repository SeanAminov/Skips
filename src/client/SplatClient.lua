--!strict
--[[
	SplatClient — the SPLAT button: splat every eligible opponent in your match, for one ticket.

	The user (2026-09-11): "Splat and revive should be the only things. Splat should be 1 ticket."

	NOTHING HERE DECIDES ANYTHING. It asks once; the server owns the matchup roster, checks the balance,
	charges, and only then lands the effects (DistractionService). The client sends no target, so this
	button can never be a way to tell a bot from a person.

	WHERE IT SITS. In the VS button's place, which is empty for exactly as long as a match runs: the VS
	button hides when a match is found and comes back with the result. Duel or lobby, it is one tap.

	A TAP ON IT IS NEVER A JUMP (the user, 2026-09-11: "make splat not count as a jump tap"). The button
	is exempt from InputController's tap-anywhere contract, so a splat can be
	bought mid-run without costing a hop.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Distraction = require(Shared:WaitForChild("Distraction"))
local MonetizationConfig = require(Shared:WaitForChild("MonetizationConfig"))
local RunProtocol = require(Shared:WaitForChild("RunProtocol"))
local TicketClient = require(script.Parent:WaitForChild("TicketClient"))
local InputController = require(script.Parent:WaitForChild("InputController"))

local SplatClient = {}

export type Opponent = { key: string, name: string, score: number }

local INK = Color3.fromRGB(40, 36, 61)
local PAPER = Color3.fromRGB(255, 253, 244)
local CREAM = Color3.fromRGB(255, 244, 211)
local GOO = Color3.fromRGB(128, 222, 92)
local CORAL = Color3.fromRGB(240, 84, 74)
local TICKET = Color3.fromRGB(255, 137, 172)
local TICKET_ICON = "🎟"

-- The VS button's slot: top-left of the left-edge column.
local CHIP_POS = Vector2.new(14, 92)
local CHIP_SIZE = Vector2.new(76, 48)
local TOAST_X = 102
local PENDING_TIMEOUT = 5
local TOAST_SECONDS = 3

local player = Players.LocalPlayer
local remoteFolder = ReplicatedStorage:WaitForChild(RunProtocol.REMOTE_FOLDER)
local remote = remoteFolder:WaitForChild(Distraction.REMOTE_NAME) :: RemoteEvent
local cost = MonetizationConfig.SPLAT_TICKET_COST

local gui = Instance.new("ScreenGui")
gui.Name = "SkipsSplat"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
-- Above the run HUD and the live table, below the ticket shop it can send you to.
gui.DisplayOrder = 25
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

local function text(parent: Instance, name: string, value: string, size: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.Text = value
	label.TextSize = size
	label.TextColor3 = PAPER
	label.TextStrokeColor3 = INK
	label.TextStrokeTransparency = 0.15
	label.Parent = parent
	return label
end

-- ── the button ───────────────────────────────────────────────────────────────────────────────
local button = Instance.new("TextButton")
button.Name = "Splat"
button.Position = UDim2.fromOffset(CHIP_POS.X, CHIP_POS.Y)
button.Size = UDim2.fromOffset(CHIP_SIZE.X, CHIP_SIZE.Y)
button.BackgroundColor3 = GOO
button.BorderSizePixel = 0
button.AutoButtonColor = true
button.Font = Enum.Font.FredokaOne
button.Text = "SPLAT ALL"
button.TextSize = 15
button.TextColor3 = PAPER
button.TextStrokeColor3 = INK
button.TextStrokeTransparency = 0.1
button.Visible = false
button.Parent = gui
corner(button, 14)
stroke(button, INK, 3)

-- The price, always on the button: a paid action never hides what it costs.
local badge = text(button, "Cost", string.format("%d%s", cost, TICKET_ICON), 14)
badge.AnchorPoint = Vector2.new(0.5, 0.5)
badge.Position = UDim2.new(1, -4, 0, 2)
badge.Size = UDim2.fromOffset(34, 20)
badge.BackgroundTransparency = 0
badge.BackgroundColor3 = TICKET
corner(badge, 10)
stroke(badge, INK, 2)

-- Pressing it is the splat's business alone, never a jump.
InputController.exemptGui(button)

-- ── what happened ────────────────────────────────────────────────────────────────────────────
local toast = text(gui, "Toast", "", 18)
toast.AnchorPoint = Vector2.new(0, 0.5)
toast.Size = UDim2.fromOffset(380, 30)
toast.TextXAlignment = Enum.TextXAlignment.Left
toast.Visible = false

-- ── state ────────────────────────────────────────────────────────────────────────────────────
local opponents: { Opponent } = {}
local pendingSince: number? = nil
local toastUntil = 0

local function say(message: string, colour: Color3)
	toast.Text = message
	toast.TextColor3 = colour
	toast.Visible = true
	toastUntil = os.clock() + TOAST_SECONDS
end

local function placeToast()
	toast.Position = UDim2.fromOffset(TOAST_X, CHIP_POS.Y + CHIP_SIZE.Y * 0.5)
end

local function send()
	if pendingSince then
		return
	end
	pendingSince = os.clock()
	button.Text = "…"
	remote:FireServer(Distraction.CLIENT.BUY)
end

button.Activated:Connect(function()
	if pendingSince or #opponents == 0 then
		return
	end
	if TicketClient.balance() < cost then
		say(string.format("A SPLAT COSTS %d %s", cost, TICKET_ICON), CREAM)
		TicketClient.openShop("SPLAT")
		return
	end
	send()
end)

local REFUSAL_TEXT = {
	[Distraction.REFUSED.OUT] = "NOBODY LEFT TO SPLAT",
	[Distraction.REFUSED.CHOOSING] = "EVERYONE'S PICKING A CARD  •  TRY AGAIN IN A SEC",
	[Distraction.REFUSED.NO_TARGET] = "NOBODY LEFT TO SPLAT",
	[Distraction.REFUSED.BUSY] = "ONE AT A TIME",
	[Distraction.REFUSED.UNAVAILABLE] = "COULDN'T SPLAT RIGHT NOW",
}

remote.OnClientEvent:Connect(function(op, payload)
	if op ~= Distraction.SERVER.RESULT or typeof(payload) ~= "table" then
		return
	end
	local data = payload :: any
	pendingSince = nil
	button.Text = "SPLAT ALL"
	if data.landed == true then
		local count = if typeof(data.count) == "number" then math.max(1, math.floor(data.count)) else 1
		local who = if count == 1 then "THEM" else string.format("%d PLAYERS", count)
		say(string.format("SPLATTED %s!  -%d %s", who, cost, TICKET_ICON), GOO)
	elseif data.reason == Distraction.REFUSED.NO_TICKETS then
		say(string.format("A SPLAT COSTS %d %s", cost, TICKET_ICON), CREAM)
		TicketClient.openShop("SPLAT")
	elseif data.reason == Distraction.REFUSED.IMMUNE then
		local wait = if typeof(data.retryIn) == "number" then data.retryIn else Distraction.IMMUNITY_SECONDS
		say(string.format("STILL WIPING OFF THE LAST ONE  •  %ds", wait), CORAL)
	else
		say(REFUSAL_TEXT[data.reason] or "COULDN'T SPLAT RIGHT NOW", CORAL)
	end
end)

--[[
	Called every frame by the run client with the opponents still running (StageView) and whether this
	player is in a match. Solo shows nothing: nobody beside you in solo is an opponent.
]]
function SplatClient.update(current: { Opponent }, inMatch: boolean)
	opponents = if inMatch then current else {}
	local visible = #opponents > 0
	button.Visible = visible
	local since = pendingSince
	if since and os.clock() - since > PENDING_TIMEOUT then
		-- The reply never came. Let them try again rather than leave the button stuck on "…".
		pendingSince = nil
		button.Text = "SPLAT ALL"
	end
	if toast.Visible and os.clock() >= toastUntil then
		toast.Visible = false
	end
	placeToast()
end

return SplatClient
