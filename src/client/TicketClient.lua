--!strict
--[[
	TicketClient — the ticket count in the corner, and the ticket shop.

	PRESENTATION ONLY. The balance is the server's, read from a player attribute; nothing here grants
	or spends a ticket. Buying goes through Roblox's own purchase prompt, and a ticket appears when
	the SERVER's receipt handler has saved it -- never on this client's say-so. The purchase-finished
	event is used for exactly one thing: to say "thanks, adding it" while the receipt is processed.

	THE FLOW THE USER ASKED FOR (2026-09-10): a revive with no ticket goes to the shop, and buying one
	revives straight away. `Main.client` owns that part; this file only opens, closes and reports.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MonetizationConfig = require(Shared:WaitForChild("MonetizationConfig"))
local PlayerProtocol = require(Shared:WaitForChild("PlayerProtocol"))
local RunProtocol = require(Shared:WaitForChild("RunProtocol"))

local TicketClient = {}

local INK = Color3.fromRGB(40, 36, 61)
local PAPER = Color3.fromRGB(255, 253, 244)
local CREAM = Color3.fromRGB(255, 244, 211)
local PANEL = Color3.fromRGB(46, 42, 70)
local MUTED = Color3.fromRGB(157, 147, 164)
local GREEN = Color3.fromRGB(76, 181, 128)
local CORAL = Color3.fromRGB(240, 84, 74)
local TICKET = Color3.fromRGB(255, 137, 172)
local GOLD = Color3.fromRGB(255, 205, 74)
local PURPLE = Color3.fromRGB(111, 70, 206)
local SKY = Color3.fromRGB(70, 185, 239)
local TICKET_ICON = "🎟"

local PANEL_W, PANEL_H = 560, 600
local CARD_W, CARD_H, CARD_GAP = 240, 170, 16
local GRID_TOP = 126

local player = Players.LocalPlayer
local remoteFolder = ReplicatedStorage:WaitForChild(RunProtocol.REMOTE_FOLDER)

local gui = Instance.new("ScreenGui")
gui.Name = "SkipsTickets"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
-- Above the run HUD and the revive offer: the shop is where a revive sends you.
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

local function bounce(button: GuiButton, scale: UIScale, hoverScale: number?)
	local selectedScale = hoverScale or 1.04
	local function settle(target: number, duration: number, style: Enum.EasingStyle)
		TweenService:Create(scale, TweenInfo.new(duration, style, Enum.EasingDirection.Out), {
			Scale = target,
		}):Play()
	end
	button.MouseEnter:Connect(function()
		settle(selectedScale, 0.12, Enum.EasingStyle.Back)
	end)
	button.MouseLeave:Connect(function()
		settle(1, 0.12, Enum.EasingStyle.Quad)
	end)
	button.SelectionGained:Connect(function()
		settle(selectedScale, 0.12, Enum.EasingStyle.Back)
	end)
	button.SelectionLost:Connect(function()
		settle(1, 0.12, Enum.EasingStyle.Quad)
	end)
	button.Activated:Connect(function()
		scale.Scale = 0.92
		settle(selectedScale, 0.18, Enum.EasingStyle.Back)
	end)
end

-- ── the corner chip ──────────────────────────────────────────────────────────────────────────
-- Under TOP, same shape and outline, so the left edge reads as one tidy column: VS, TOP, tickets.
local openButton = chip(gui, "Open", TICKET_ICON .. " 0", Vector2.new(76, 48), Vector2.new(52, 228))
openButton.BackgroundColor3 = TICKET
openButton.TextSize = 21
openButton.AutoButtonColor = false
local openScale = Instance.new("UIScale")
openScale.Parent = openButton
bounce(openButton, openScale, 1.09)

-- ── the shop ─────────────────────────────────────────────────────────────────────────────────
local popout = Instance.new("Frame")
popout.Name = "Shop"
popout.AnchorPoint = Vector2.new(0.5, 0.5)
popout.Position = UDim2.fromScale(0.5, 0.5)
popout.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
popout.BackgroundTransparency = 1
popout.Visible = false
popout.Parent = gui
local fitScale = Instance.new("UIScale")
fitScale.Parent = popout

-- Fit-to-screen and opening bounce are separate scales so a phone can shrink the whole shop
-- without flattening the little spring motion that gives the panel its toy-like feel.
local shell = Instance.new("Frame")
shell.Name = "Shell"
shell.Size = UDim2.fromScale(1, 1)
shell.BackgroundTransparency = 1
shell.Parent = popout
local shellScale = Instance.new("UIScale")
shellScale.Parent = shell

-- The same solid "sticker" shadow as the leaderboard, so the two popouts read as one family.
local shadow = Instance.new("Frame")
shadow.Name = "Shadow"
shadow.Size = UDim2.fromScale(1, 1)
shadow.Position = UDim2.fromOffset(7, 8)
shadow.BackgroundColor3 = INK
shadow.BorderSizePixel = 0
shadow.Parent = shell
corner(shadow, 26)

local panel = Instance.new("Frame")
panel.Name = "Panel"
-- A tap on an open panel belongs to it, never a jump (InputController).
panel.Active = true
panel.Size = UDim2.fromScale(1, 1)
panel.BackgroundColor3 = PANEL
panel.BorderSizePixel = 0
panel.Parent = shell
corner(panel, 26)
stroke(panel, INK, 4)

words(panel, "Title", "TICKET SHOP", 34, Vector2.new(PANEL_W - 130, 40), Vector2.new(PANEL_W / 2, 36))
local balanceLabel = words(panel, "Balance", "", 22, Vector2.new(PANEL_W - 60, 28), Vector2.new(PANEL_W / 2, 74))
balanceLabel.TextColor3 = TICKET
local reasonLabel = words(panel, "Reason", "", 16, Vector2.new(PANEL_W - 60, 22), Vector2.new(PANEL_W / 2, 104))
reasonLabel.TextColor3 = CREAM

local closeButton = chip(panel, "Close", "X", Vector2.new(38, 38), Vector2.new(PANEL_W - 30, 30))
closeButton.BackgroundColor3 = CORAL
closeButton.AutoButtonColor = false
local closeScale = Instance.new("UIScale")
closeScale.Parent = closeButton
bounce(closeButton, closeScale, 1.08)

local status = words(panel, "Status", "", 18, Vector2.new(PANEL_W - 60, 26), Vector2.new(PANEL_W / 2, PANEL_H - 62))
status.TextColor3 = CREAM
local savedNote = words(panel, "Unsaved", "TICKETS CAN'T BE SAVED IN THIS SESSION", 14,
	Vector2.new(PANEL_W - 60, 20), Vector2.new(PANEL_W / 2, PANEL_H - 30))
savedNote.TextColor3 = MUTED
savedNote.Visible = false

local function setStatus(text: string)
	status.Text = text
end

-- One card per pack that can actually be bought: a product id of 0 stages a pack without offering it.
local packs = MonetizationConfig.offeredPacks()
local packScales: { UIScale } = {}
do
	local columns = math.min(2, math.max(1, #packs))
	local totalWidth = columns * CARD_W + math.max(0, columns - 1) * CARD_GAP
	local left = (PANEL_W - totalWidth) / 2
	for index, pack in packs do
		local column = (index - 1) % columns
		local row = math.floor((index - 1) / columns)
		local x = left + column * (CARD_W + CARD_GAP)
		local y = GRID_TOP + row * (CARD_H + CARD_GAP)
		local card = Instance.new("TextButton")
		card.Name = "Pack" .. pack.id
		card.Size = UDim2.fromOffset(CARD_W, CARD_H)
		card.Position = UDim2.fromOffset(x, y)
		card.BackgroundColor3 = PURPLE
		card.BorderSizePixel = 0
		card.AutoButtonColor = false
		card.Text = ""
		card.Parent = panel
		corner(card, 18)
		stroke(card, GOLD, 4)
		local cardGradient = Instance.new("UIGradient")
		cardGradient.Rotation = 32
		cardGradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, SKY),
			ColorSequenceKeypoint.new(0.48, PURPLE),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(75, 45, 145)),
		})
		cardGradient.Parent = card

		local gloss = Instance.new("Frame")
		gloss.Name = "Shine"
		gloss.Size = UDim2.new(1, -14, 0, 42)
		gloss.Position = UDim2.fromOffset(7, 7)
		gloss.BackgroundColor3 = Color3.new(1, 1, 1)
		gloss.BackgroundTransparency = 0.86
		gloss.BorderSizePixel = 0
		gloss.Parent = card
		corner(gloss, 13)

		local art = Instance.new("ImageLabel")
		art.Name = "Ticket"
		art.AnchorPoint = Vector2.new(0.5, 0.5)
		art.Position = UDim2.fromOffset(53, 71)
		art.Size = UDim2.fromOffset(88, 88)
		art.Rotation = -7
		art.BackgroundColor3 = TICKET
		art.BorderSizePixel = 0
		art.Image = string.format("rbxassetid://%d", pack.iconAssetId)
		art.ScaleType = Enum.ScaleType.Crop
		art.Parent = card
		corner(art, 15)
		stroke(art, GOLD, 3)

		local countText = if pack.tickets == 1 then "1 TICKET" else string.format("%d TICKETS", pack.tickets)
		local count = words(card, "Count", countText, 25, Vector2.new(142, 36), Vector2.new(159, 58))
		count.TextXAlignment = Enum.TextXAlignment.Center

		local price = Instance.new("Frame")
		price.Name = "Price"
		price.AnchorPoint = Vector2.new(0.5, 0.5)
		price.Position = UDim2.fromOffset(159, 113)
		price.Size = UDim2.fromOffset(132, 43)
		price.BackgroundColor3 = GREEN
		price.BorderSizePixel = 0
		price.Parent = card
		corner(price, 15)
		stroke(price, INK, 3)
		words(price, "Amount", string.format("%d ROBUX", pack.priceRobux), 20,
			Vector2.new(124, 34), Vector2.new(66, 21))

		if pack.priceRobux < pack.tickets * MonetizationConfig.BASE_TICKET_PRICE_ROBUX then
			local saving = math.floor(100 * (1 - pack.priceRobux
				/ (pack.tickets * MonetizationConfig.BASE_TICKET_PRICE_ROBUX)) + 0.5)
			local value = words(card, "Value", string.format("BEST VALUE  •  SAVE %d%%", saving), 13,
				Vector2.new(CARD_W - 20, 20), Vector2.new(CARD_W / 2, CARD_H - 13))
			value.TextColor3 = GOLD
		end

		local cardScale = Instance.new("UIScale")
		cardScale.Parent = card
		table.insert(packScales, cardScale)
		bounce(card, cardScale, 1.045)
		card.Activated:Connect(function()
			setStatus("OPENING ROBLOX CHECKOUT…")
			local ok, message = pcall(MarketplaceService.PromptProductPurchase, MarketplaceService,
				player, pack.productId)
			if not ok then
				setStatus("CHECKOUT UNAVAILABLE")
				warn("[Skips] ticket checkout failed: " .. tostring(message))
			end
		end)
	end
	if #packs == 0 then
		words(panel, "Soon", "THE SHOP OPENS SOON", 22, Vector2.new(PANEL_W - 60, 30),
			Vector2.new(PANEL_W / 2, 210)).TextColor3 = MUTED
	end
end

-- Studio only: hand yourself tickets to test the shop and a ticket revive without buying.
if RunService:IsStudio() then
	local playerRemote = remoteFolder:WaitForChild(PlayerProtocol.REMOTE_NAME) :: RemoteEvent
	local grant = chip(panel, "StudioGrant", string.format("STUDIO: +%d %s", PlayerProtocol.STUDIO_GRANT_TICKETS,
		TICKET_ICON), Vector2.new(170, 30), Vector2.new(PANEL_W / 2, PANEL_H - 96))
	grant.TextSize = 15
	grant.Activated:Connect(function()
		playerRemote:FireServer(PlayerProtocol.CLIENT.STUDIO_GRANT)
	end)
end

function TicketClient.balance(): number
	local value = player:GetAttribute(PlayerProtocol.ATTRIBUTE.TICKETS)
	return if typeof(value) == "number" then value else 0
end

local lastBalance = TicketClient.balance()

-- Why the shop is open: nil when the player opened it, or "REVIVE" / "SPLAT" when a purchase sent them.
local shopReason: string? = nil

-- Tickets buy exactly two things (2026-09-11), and the shop says so every time it opens.
local function paintReason()
	if shopReason == "REVIVE" then
		local short = math.max(1, MonetizationConfig.REVIVE_TICKET_COST - TicketClient.balance())
		reasonLabel.Text = string.format("GET %d MORE %s AND YOUR RUN COMES STRAIGHT BACK", short, TICKET_ICON)
	elseif shopReason == "SPLAT" then
		reasonLabel.Text = string.format("SPLAT EVERY OPPONENT FOR %d %s  •  USE THE SPLAT ALL BUTTON",
			MonetizationConfig.SPLAT_TICKET_COST, TICKET_ICON)
	else
		reasonLabel.Text = string.format("REVIVE  %d %s     •     SPLAT ALL OPPONENTS  %d %s",
			MonetizationConfig.REVIVE_TICKET_COST, TICKET_ICON, MonetizationConfig.SPLAT_TICKET_COST, TICKET_ICON)
	end
end

local function paintBalance()
	paintReason()
	local balance = TicketClient.balance()
	openButton.Text = string.format("%s %d", TICKET_ICON, balance)
	balanceLabel.Text = string.format("YOU HAVE %d %s", balance, TICKET_ICON)
	savedNote.Visible = player:GetAttribute(PlayerProtocol.ATTRIBUTE.SAVED) == false
end

local closedCallbacks: { () -> () } = {}

function TicketClient.openShop(reason: string?)
	popout.Visible = true
	shellScale.Scale = 0.82
	TweenService:Create(shellScale, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1,
	}):Play()
	for index, cardScale in packScales do
		cardScale.Scale = 0.72
		task.delay((index - 1) * 0.045, function()
			if not popout.Visible or not cardScale.Parent then return end
			TweenService:Create(cardScale,
				TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end)
	end
	shopReason = reason
	setStatus("")
	paintBalance()
end

-- Closed by the game (a revive went through): no callbacks, nothing was declined.
function TicketClient.closeShop()
	popout.Visible = false
end

function TicketClient.isOpen(): boolean
	return popout.Visible
end

-- Called when the PLAYER closes the shop. A revive waiting on it takes that as "no thanks".
function TicketClient.onShopClosed(callback: () -> ())
	table.insert(closedCallbacks, callback)
end

openButton.Activated:Connect(function()
	if popout.Visible then
		popout.Visible = false
		for _, callback in closedCallbacks do
			task.spawn(callback)
		end
	else
		TicketClient.openShop()
	end
end)
closeButton.Activated:Connect(function()
	popout.Visible = false
	for _, callback in closedCallbacks do
		task.spawn(callback)
	end
end)

MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchased)
	if userId ~= player.UserId or not MonetizationConfig.packForProduct(productId) then
		return
	end
	-- Only a message. The ticket is real when the server's receipt handler has saved it and the
	-- balance changes -- this event proves nothing about payment, so it grants nothing.
	setStatus(if purchased then "THANKS!  ADDING YOUR TICKET…" else "")
end)

local function onBalanceChanged()
	local balance = TicketClient.balance()
	if balance > lastBalance and popout.Visible then
		setStatus(string.format("GOT IT!  YOU HAVE %d %s", balance, TICKET_ICON))
	end
	lastBalance = balance
	paintBalance()
end
player:GetAttributeChangedSignal(PlayerProtocol.ATTRIBUTE.TICKETS):Connect(onBalanceChanged)
player:GetAttributeChangedSignal(PlayerProtocol.ATTRIBUTE.SAVED):Connect(paintBalance)
paintBalance()

-- Fit on small screens: the popout shrinks as one piece rather than overflowing a phone.
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

return TicketClient
