--!strict
--[[
	LeaderboardClient — the leaderboard popout: four boards, three periods, and where YOU stand.

	PRESENTATION ONLY. Rows arrive already ranked; this sorts nothing and computes no totals. Its own
	ScreenGui, so deleting the file leaves a playable game — which matters more
	than usual here, because the service behind it is switched off whenever the place is unlinked.

	THE LAYOUT THE USER ASKED FOR (2026-09-10): a popout with filters — solo, duo, group or ranked;
	today, this week or all time — "clean and cartoony". Ranked hides the period filters: a rating is
	a standing, not a tally, so it has no "this week".

	YOUR ROW IS ALWAYS THERE. When you are not on the first page, your own place is pinned under the
	list, so you can see where you stand relative to the top even from far below it. When you are too
	far down to count exactly without spending other players' request budget, it says "500+".

	NUMBERS ARE EXACT, via `Leaderboards.formatExact`: a leaderboard is exactly where an abbreviation
	is least acceptable.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Leaderboards = require(Shared:WaitForChild("Leaderboards"))
local RunProtocol = require(Shared:WaitForChild("RunProtocol"))

local LeaderboardClient = {}

local INK = Color3.fromRGB(40, 36, 61)
local PAPER = Color3.fromRGB(255, 253, 244)
local CREAM = Color3.fromRGB(255, 244, 211)
local PANEL = Color3.fromRGB(46, 42, 70)
local STRIPE = Color3.fromRGB(62, 57, 94)
local MUTED = Color3.fromRGB(157, 147, 164)
local GOLD = Color3.fromRGB(247, 197, 84)
local SILVER = Color3.fromRGB(206, 214, 226)
local BRONZE = Color3.fromRGB(222, 150, 92)
local PERIOD_ON = Color3.fromRGB(76, 181, 128)

-- Each board has its own colour, so the active filter reads at a glance before the label does.
local BOARD_COLOURS: { [string]: Color3 } = {
	SOLO = Color3.fromRGB(88, 170, 240),
	DUO = Color3.fromRGB(240, 84, 74),
	GROUP = Color3.fromRGB(247, 170, 52),
	RANKED = Color3.fromRGB(160, 110, 230),
}
local MEDALS: { [number]: Color3 } = { GOLD, SILVER, BRONZE }

local PANEL_W, PANEL_H = 520, 590
local ROWS = 10
local ROW_H, ROW_GAP = 30, 3
local ROWS_TOP = 200

local remoteFolder = ReplicatedStorage:WaitForChild(RunProtocol.REMOTE_FOLDER)
local boardRemote = remoteFolder:WaitForChild(Leaderboards.REMOTE_NAME) :: RemoteEvent

local player = Players.LocalPlayer
local gui = Instance.new("ScreenGui")
gui.Name = "SkipsLeaderboard"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 25
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

-- ── the corner button ────────────────────────────────────────────────────────────────────────
-- Stacked under the VS button, same shape and outline, so the corner reads as one tidy column.
local openButton = chip(gui, "Open", "TOP", Vector2.new(76, 48), Vector2.new(52, 172))
openButton.BackgroundColor3 = GOLD
openButton.TextSize = 21

-- ── the popout ───────────────────────────────────────────────────────────────────────────────
local popout = Instance.new("Frame")
popout.Name = "Popout"
popout.AnchorPoint = Vector2.new(0.5, 0.5)
popout.Position = UDim2.fromScale(0.5, 0.5)
popout.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
popout.BackgroundTransparency = 1
popout.Visible = false
popout.Parent = gui
local fitScale = Instance.new("UIScale")
fitScale.Parent = popout

-- A solid offset shadow: the cartoon "sticker" look, and it lifts the panel off a busy scene.
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

words(panel, "Title", "LEADERBOARDS", 34, Vector2.new(PANEL_W - 130, 40), Vector2.new(PANEL_W / 2, 36))
local subtitle = words(panel, "Subtitle", "", 17, Vector2.new(PANEL_W - 60, 22), Vector2.new(PANEL_W / 2, 66))
subtitle.TextColor3 = CREAM

local closeButton = chip(panel, "Close", "X", Vector2.new(38, 38), Vector2.new(PANEL_W - 30, 30))
closeButton.BackgroundColor3 = Color3.fromRGB(240, 84, 74)

-- Board filters: four equal chips across the top.
local boardChips: { [string]: TextButton } = {}
do
	local width, gap = 110, 10
	local left = (PANEL_W - (#Leaderboards.BOARDS * width + (#Leaderboards.BOARDS - 1) * gap)) / 2
	for index, board in Leaderboards.BOARDS do
		local x = left + (index - 1) * (width + gap) + width / 2
		boardChips[board] = chip(panel, "Board" .. board, Leaderboards.boardLabel(board),
			Vector2.new(width, 40), Vector2.new(x, 108))
	end
end

-- Period filters, hidden on ranked.
local periodChips: { [string]: TextButton } = {}
do
	local width, gap = 140, 12
	local left = (PANEL_W - (#Leaderboards.PERIODS * width + (#Leaderboards.PERIODS - 1) * gap)) / 2
	for index, period in Leaderboards.PERIODS do
		local x = left + (index - 1) * (width + gap) + width / 2
		periodChips[period] = chip(panel, "Period" .. period, Leaderboards.periodLabel(period),
			Vector2.new(width, 32), Vector2.new(x, 152))
	end
end
local rankedCaption = words(panel, "RankedCaption", "CURRENT RATINGS", 18,
	Vector2.new(300, 26), Vector2.new(PANEL_W / 2, 152))
rankedCaption.TextColor3 = MUTED
rankedCaption.Visible = false

-- Column headings.
local headRank = words(panel, "HeadRank", "#", 15, Vector2.new(40, 18), Vector2.new(46, 184))
headRank.TextColor3 = MUTED
local headName = words(panel, "HeadName", "PLAYER", 15, Vector2.new(200, 18), Vector2.new(174, 184))
headName.TextColor3 = MUTED
headName.TextXAlignment = Enum.TextXAlignment.Left
local headValue = words(panel, "HeadValue", "", 15, Vector2.new(160, 18), Vector2.new(PANEL_W - 104, 184))
headValue.TextColor3 = MUTED
headValue.TextXAlignment = Enum.TextXAlignment.Right

type Row = { frame: Frame, bubble: Frame, rank: TextLabel, name: TextLabel, value: TextLabel, ring: UIStroke }

local function makeRow(name: string, y: number): Row
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = UDim2.fromOffset(PANEL_W - 36, ROW_H)
	frame.Position = UDim2.fromOffset(18, y)
	frame.BackgroundColor3 = STRIPE
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = panel
	corner(frame, 10)
	local ring = stroke(frame, GOLD, 3)
	ring.Enabled = false

	local bubble = Instance.new("Frame")
	bubble.Name = "Bubble"
	bubble.AnchorPoint = Vector2.new(0.5, 0.5)
	bubble.Size = UDim2.fromOffset(54, 24)
	bubble.Position = UDim2.fromOffset(32, ROW_H / 2)
	bubble.BackgroundTransparency = 1
	bubble.BorderSizePixel = 0
	bubble.Parent = frame
	corner(bubble, 12)

	local rank = words(bubble, "Rank", "", 16, Vector2.new(54, 24), Vector2.new(27, 12))
	local label = words(frame, "Name", "", 18, Vector2.new(290, 24), Vector2.new(210, ROW_H / 2))
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	local value = words(frame, "Value", "", 18, Vector2.new(150, 24), Vector2.new(PANEL_W - 124, ROW_H / 2))
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.TextColor3 = CREAM
	return { frame = frame, bubble = bubble, rank = rank, name = label, value = value, ring = ring }
end

local rows: { Row } = {}
for index = 1, ROWS do
	rows[index] = makeRow(string.format("Row%d", index), ROWS_TOP + (index - 1) * (ROW_H + ROW_GAP))
end

local divider = Instance.new("Frame")
divider.Name = "Divider"
divider.Size = UDim2.fromOffset(PANEL_W - 60, 3)
divider.Position = UDim2.fromOffset(30, ROWS_TOP + ROWS * (ROW_H + ROW_GAP) + 4)
divider.BackgroundColor3 = INK
divider.BorderSizePixel = 0
divider.Visible = false
divider.Parent = panel

-- The pinned "you" row, under the divider.
local you = makeRow("You", ROWS_TOP + ROWS * (ROW_H + ROW_GAP) + 14)
you.frame.BackgroundColor3 = INK
you.frame.BackgroundTransparency = 0
you.ring.Enabled = true

local status = words(panel, "Status", "", 20, Vector2.new(PANEL_W - 80, 30),
	Vector2.new(PANEL_W / 2, ROWS_TOP + (ROWS * (ROW_H + ROW_GAP)) / 2))
status.TextColor3 = MUTED

-- ── state and painting ───────────────────────────────────────────────────────────────────────
local currentBoard = Leaderboards.BOARD.SOLO
local lastPeriodic = Leaderboards.PERIOD.DAILY

local function currentPeriod(): string
	local periods = Leaderboards.periodsFor(currentBoard)
	return if #periods == 1 then periods[1] else lastPeriodic
end

local function paintRank(row: Row, rank: number?, capped: boolean?)
	local medal = if rank and not capped then MEDALS[rank] else nil
	row.rank.Text = if rank and rank <= 999 and not capped
		then tostring(rank)
		else Leaderboards.formatRank(rank, capped)
	if medal then
		row.bubble.BackgroundTransparency = 0
		row.bubble.BackgroundColor3 = medal
		row.rank.TextColor3 = INK
		row.rank.TextStrokeTransparency = 1
	else
		row.bubble.BackgroundTransparency = 1
		row.rank.TextColor3 = PAPER
		row.rank.TextStrokeTransparency = 0.1
	end
end

local function paintFilters()
	local periodic = #Leaderboards.periodsFor(currentBoard) > 1
	for board, button in boardChips do
		button.BackgroundColor3 = if board == currentBoard then BOARD_COLOURS[board] else MUTED
	end
	for period, button in periodChips do
		button.Visible = periodic
		button.BackgroundColor3 = if period == lastPeriodic then PERIOD_ON else MUTED
	end
	rankedCaption.Visible = not periodic
	headValue.Text = Leaderboards.valueLabel(currentBoard)
	subtitle.Text = if periodic
		then string.format("%s  •  %s  •  %s", Leaderboards.boardLabel(currentBoard),
			Leaderboards.valueLabel(currentBoard), Leaderboards.periodLabel(lastPeriodic))
		else string.format("%s  •  %s", Leaderboards.boardLabel(currentBoard),
			Leaderboards.valueLabel(currentBoard))
end

local function clearRows()
	for _, row in rows do
		row.frame.Visible = false
	end
	you.frame.Visible = false
	divider.Visible = false
end

local function request()
	paintFilters()
	clearRows()
	status.Text = "LOADING…"
	boardRemote:FireServer(Leaderboards.CLIENT.REQUEST, currentBoard, currentPeriod())
end

for board, button in boardChips do
	button.Activated:Connect(function()
		currentBoard = board
		request()
	end)
end
for period, button in periodChips do
	button.Activated:Connect(function()
		lastPeriodic = period
		request()
	end)
end

openButton.Activated:Connect(function()
	popout.Visible = not popout.Visible
	if popout.Visible then
		request()
	end
end)
closeButton.Activated:Connect(function()
	popout.Visible = false
end)

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

boardRemote.OnClientEvent:Connect(function(op, payload)
	local data = if typeof(payload) == "table" then payload :: any else {}

	if op == Leaderboards.SERVER.UNAVAILABLE then
		clearRows()
		-- Said plainly rather than shown as an empty board. An empty leaderboard reads as "nobody
		-- has played"; this is "the game cannot see the boards", and those are different problems.
		status.Text = "LEADERBOARDS ARE OFFLINE"
		return
	end
	if op ~= Leaderboards.SERVER.BOARD or typeof(data.rows) ~= "table" then
		return
	end
	-- A reply for a filter the player has since moved off is stale; drop it rather than paint it.
	if data.board ~= currentBoard or data.period ~= currentPeriod() then
		return
	end

	clearRows()
	local shown, mineShown = 0, false
	for index, entry in data.rows do
		local row = rows[index]
		if row then
			local e = entry :: any
			local mine = e.userId == player.UserId
			shown += 1
			mineShown = mineShown or mine
			row.frame.Visible = true
			row.frame.BackgroundTransparency = if index % 2 == 1 then 0.4 else 1
			row.ring.Enabled = mine
			paintRank(row, e.rank, false)
			row.name.Text = if mine then tostring(e.name) .. "  (you)" else tostring(e.name)
			-- Exact, with separators. This is the whole point of the board.
			row.value.Text = Leaderboards.formatExact(e.value or 0)
		end
	end
	status.Text = if shown == 0 then "NOBODY IS ON THIS BOARD YET" else ""

	-- Your place, pinned underneath, whenever the first page did not already show it.
	local me = if typeof(data.me) == "table" then data.me :: any else nil
	if not mineShown then
		divider.Visible = true
		you.frame.Visible = true
		paintRank(you, me and me.rank, me and me.capped)
		if me and typeof(me.value) == "number" then
			you.name.Text = "YOU"
			you.value.Text = Leaderboards.formatExact(me.value)
		else
			you.name.Text = "YOU  •  NOT ON THIS BOARD YET"
			you.value.Text = ""
		end
	end
end)

return LeaderboardClient
