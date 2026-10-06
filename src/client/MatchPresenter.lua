--!strict
--[[
	MatchPresenter — the screens around a match: queueing, the roster, the live table, the result.

	SEPARATE FROM `RunPresenter` ON PURPOSE. `RunPresenter` draws one player's run and reads their
	simulation; this draws everyone else. They sit on different ScreenGuis so a match screen can
	never accidentally depend on run state, and deleting this whole file must leave a playable solo
	game behind.

	PRESENTATION ONLY. Every number here arrives from the server already ranked by `MatchRules`. This
	file sorts nothing, decides nothing, and owns no clock except the countdowns it renders against
	server timestamps it was handed.
]]

local Players = game:GetService("Players")

local MatchPresenter = {}
MatchPresenter.__index = MatchPresenter

local INK = Color3.fromRGB(40, 36, 61)
local CREAM = Color3.fromRGB(255, 244, 211)
local PAPER = Color3.fromRGB(255, 253, 244)
local PANEL = Color3.fromRGB(46, 42, 70)
local GOLD = Color3.fromRGB(247, 197, 84)
local GREEN = Color3.fromRGB(76, 181, 128)
local CORAL = Color3.fromRGB(240, 84, 74)
local MUTED = Color3.fromRGB(157, 147, 164)
local PURPLE = Color3.fromRGB(160, 110, 230)

local MAX_ROWS = 8
-- Room at the top of the live table for the countdown to the next cut.
local BOARD_HEAD = 28

-- How the searching bar fills: quickly at first, then ever more slowly, never quite full. It says
-- "working on it" without promising a time, which neither kind of queue can honestly promise.
local SEARCH_BAR_SECONDS = 6
local SEARCH_BAR_CAP = 0.92

type BoardRow = { row: Frame, place: TextLabel, name: TextLabel, score: TextLabel }

export type MatchPresenter = typeof(setmetatable(
	{} :: {
		gui: ScreenGui,
		entryButton: TextButton,
		queuePanel: Frame,
		queueStatus: TextLabel,
		queueBar: Frame,
		queueBarFill: Frame,
		duelButton: TextButton,
		lobbyButton: TextButton,
		cancelButton: TextButton,
		casualChip: TextButton,
		rankedChip: TextButton,
		kindNote: TextLabel,
		kind: string,
		-- Non-empty exactly while this client believes it is queued: the searching line without
		-- its clock, which `setQueueElapsed` appends every frame.
		queueLine: string,
		rosterPanel: Frame,
		rosterTitle: TextLabel,
		rosterList: TextLabel,
		rosterCount: TextLabel,
		rosterBarFill: Frame,
		boardPanel: Frame,
		boardRows: { BoardRow },
		cutHeader: TextLabel,
		cutBanner: TextLabel,
		-- True while the local player's row is the one the next cut would take.
		dangerMine: boolean,
		bannerToken: number,
		timerFrame: Frame,
		timerLabel: TextLabel,
		timerStroke: UIStroke,
		timerScale: UIScale,
		resultPanel: Frame,
		resultTitle: TextLabel,
		resultRating: TextLabel,
		resultList: TextLabel,
		rejoinButton: TextButton,
		soloButton: TextButton,
		challengePanel: Frame,
		challengeLabel: TextLabel,
		acceptButton: TextButton,
		declineButton: TextButton,
		localUserId: number,
		onQueue: (string, string) -> (),
		onLeaveQueue: () -> (),
		onAccept: () -> (),
		onDecline: () -> (),
		onPlaySolo: () -> (),
	},
	{} :: { __index: typeof(MatchPresenter) }
))

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
	text.TextStrokeTransparency = 0.05
	text.Parent = parent
	return text
end

local function round(object: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = object
end

local function outline(object: GuiObject, color: Color3, thickness: number): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = object
	return stroke
end

local function button(parent: Instance, name: string, text: string, size: UDim2,
	position: UDim2, fill: Color3): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.Size = size
	b.Position = position
	b.BackgroundColor3 = fill
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Font = Enum.Font.FredokaOne
	b.TextScaled = true
	b.TextColor3 = PAPER
	b.TextStrokeColor3 = INK
	b.TextStrokeTransparency = 0.2
	b.Text = text
	b.Parent = parent
	round(b, 14)
	outline(b, INK, 3)
	return b
end

local function panel(parent: Instance, name: string, size: UDim2, position: UDim2): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Size = size
	frame.Position = position
	frame.BackgroundColor3 = PANEL
	frame.BackgroundTransparency = 0.06
	frame.BorderSizePixel = 0
	frame.Visible = false
	-- A tap on an open panel belongs to it, never a jump (InputController).
	frame.Active = true
	frame.Parent = parent
	round(frame, 22)
	outline(frame, INK, 4)
	return frame
end

--[[
	A pill-shaped progress bar whose fill is clipped to the pill.

	A plain Frame's ClipsDescendants clips to its RECTANGLE, so a fill inside a rounded track pokes
	its square corners out past the rounding -- the defect the user spotted on the level-up bar. The
	fill lives inside a CanvasGroup, which clips to its own rounded corners; the outline stays on the
	outer frame, so the group never has to draw outside itself.
]]
local function progressBar(parent: Instance, name: string, size: UDim2, position: UDim2,
	fill: Color3): (Frame, Frame)
	local track = Instance.new("Frame")
	track.Name = name
	track.AnchorPoint = Vector2.new(0.5, 0.5)
	track.Size = size
	track.Position = position
	track.BackgroundColor3 = INK
	track.BorderSizePixel = 0
	track.Parent = parent
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track
	outline(track, PAPER, 2)

	local clip = Instance.new("CanvasGroup")
	clip.Name = "Clip"
	clip.Size = UDim2.fromScale(1, 1)
	clip.BackgroundTransparency = 1
	clip.BorderSizePixel = 0
	clip.Parent = track
	local clipCorner = Instance.new("UICorner")
	clipCorner.CornerRadius = UDim.new(1, 0)
	clipCorner.Parent = clip

	local bar = Instance.new("Frame")
	bar.Name = "Fill"
	bar.Size = UDim2.fromScale(0, 1)
	bar.BackgroundColor3 = fill
	bar.BorderSizePixel = 0
	bar.Parent = clip
	-- Rounded ends too, so the fill itself is a pill growing inside the pill.
	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(1, 0)
	barCorner.Parent = bar
	return track, bar
end

function MatchPresenter.new(): MatchPresenter
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "SkipsMatch"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	-- Above the run HUD: a match result must not be drawn underneath the score.
	gui.DisplayOrder = 20
	gui.Parent = playerGui

	-- ── the way in ───────────────────────────────────────────────────────────────────────────
	-- A small corner button rather than a panel over the game. A player who only ever wants to skip
	-- rope alone should never have to dismiss multiplayer to do it, and this must never cover the
	-- rope during a run.
	local entryButton = button(gui, "Entry", "VS",
		UDim2.fromOffset(76, 48), UDim2.fromScale(0.5, 0.5), CORAL)
	entryButton.AnchorPoint = Vector2.new(0, 0)
	entryButton.Position = UDim2.new(0, 14, 0, 92)

	-- ── queue ────────────────────────────────────────────────────────────────────────────────
	-- Casual or ranked first, then the mode. Neither label mentions bots: they are undisclosed by the
	-- user's decision, so casual is "quick, not rated" and ranked is "rated, may take a while".
	local queuePanel = panel(gui, "Queue", UDim2.fromOffset(430, 360), UDim2.fromScale(0.5, 0.5))
	local queueTitle = label(queuePanel, "Title", UDim2.fromScale(0.9, 0.12), UDim2.fromScale(0.5, 0.1))
	queueTitle.TextScaled = true
	queueTitle.Text = "PLAY AGAINST OTHERS"
	local casualChip = button(queuePanel, "Casual", "CASUAL",
		UDim2.fromScale(0.4, 0.105), UDim2.fromScale(0.28, 0.25), GREEN)
	local rankedChip = button(queuePanel, "Ranked", "RANKED",
		UDim2.fromScale(0.4, 0.105), UDim2.fromScale(0.72, 0.25), MUTED)
	local kindNote = label(queuePanel, "KindNote", UDim2.fromScale(0.9, 0.065), UDim2.fromScale(0.5, 0.355))
	kindNote.TextScaled = true
	kindNote.TextColor3 = CREAM
	kindNote.Text = ""
	local duelButton = button(queuePanel, "Duel", "1v1 DUEL",
		UDim2.fromScale(0.82, 0.14), UDim2.fromScale(0.5, 0.52), CORAL)
	local lobbyButton = button(queuePanel, "Lobby", "LOBBY  •  8 PLAYERS",
		UDim2.fromScale(0.82, 0.14), UDim2.fromScale(0.5, 0.69), GOLD)
	local queueStatus = label(queuePanel, "Status", UDim2.fromScale(0.9, 0.085), UDim2.fromScale(0.5, 0.5))
	queueStatus.TextScaled = true
	queueStatus.TextColor3 = CREAM
	queueStatus.Text = ""
	queueStatus.Visible = false
	-- The loading bar the user asked for: it fills while the search runs, so a wait reads as work.
	local queueBar, queueBarFill = progressBar(queuePanel, "Searching",
		UDim2.new(0.8, 0, 0, 16), UDim2.fromScale(0.5, 0.62), GOLD)
	queueBar.Visible = false
	local cancelButton = button(queuePanel, "Cancel", "CANCEL",
		UDim2.fromScale(0.5, 0.12), UDim2.fromScale(0.5, 0.86), MUTED)
	cancelButton.Visible = false

	-- ── roster / loading ─────────────────────────────────────────────────────────────────────
	local rosterPanel = panel(gui, "Roster", UDim2.fromOffset(430, 340), UDim2.fromScale(0.5, 0.5))
	local rosterTitle = label(rosterPanel, "Title", UDim2.fromScale(0.9, 0.15), UDim2.fromScale(0.5, 0.13))
	rosterTitle.TextScaled = true
	rosterTitle.Text = "MATCH FOUND"
	local rosterList = label(rosterPanel, "Players", UDim2.fromScale(0.86, 0.5), UDim2.fromScale(0.5, 0.47))
	rosterList.TextWrapped = true
	rosterList.TextSize = 20
	rosterList.TextColor3 = CREAM
	rosterList.Text = ""
	local rosterCount = label(rosterPanel, "Countdown", UDim2.fromScale(0.9, 0.14), UDim2.fromScale(0.5, 0.8))
	rosterCount.TextScaled = true
	rosterCount.TextColor3 = GOLD
	rosterCount.Text = ""
	-- The loading beat drawn as progress, so "about to start" reads at a glance.
	local _rosterBar, rosterBarFill = progressBar(rosterPanel, "Loading",
		UDim2.new(0.8, 0, 0, 14), UDim2.fromScale(0.5, 0.925), GREEN)

	-- ── the live table ───────────────────────────────────────────────────────────────────────
	-- Top-right and compact: it must be readable at a glance mid-jump without covering the rope.
	local boardPanel = panel(gui, "Scores", UDim2.fromOffset(230, BOARD_HEAD + 24 + MAX_ROWS * 26),
		UDim2.fromScale(0.5, 0.5))
	boardPanel.AnchorPoint = Vector2.new(1, 0)
	boardPanel.Position = UDim2.new(1, -14, 0, 92)
	boardPanel.BackgroundTransparency = 0.25
	-- The countdown to the next cut: every minute the bottom runner still in is out (2026-09-11).
	local cutHeader = label(boardPanel, "NextCut", UDim2.new(1, -16, 0, 22), UDim2.new(0.5, 0, 0, 20))
	cutHeader.TextScaled = true
	cutHeader.TextColor3 = CREAM
	cutHeader.Text = ""
	-- Who was just cut, big and brief, so a row leaving the race is never a mystery.
	local cutBanner = label(gui, "CutBanner", UDim2.fromOffset(560, 38), UDim2.fromScale(0.5, 0.29))
	cutBanner.TextScaled = true
	cutBanner.TextColor3 = GOLD
	cutBanner.Text = ""
	cutBanner.Visible = false
	-- A duel's timer, big and centred under the score: green, then gold, then red as it nears 0:00.
	local timerFrame = Instance.new("Frame")
	timerFrame.Name = "DuelTimer"
	timerFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	timerFrame.Position = UDim2.fromScale(0.5, 0.2)
	timerFrame.Size = UDim2.fromOffset(150, 50)
	timerFrame.BackgroundColor3 = PANEL
	timerFrame.BackgroundTransparency = 0.1
	timerFrame.BorderSizePixel = 0
	timerFrame.Visible = false
	timerFrame.Parent = gui
	round(timerFrame, 25)
	local timerStroke = outline(timerFrame, GREEN, 4)
	local timerScale = Instance.new("UIScale")
	timerScale.Parent = timerFrame
	local timerLabel = label(timerFrame, "Time", UDim2.fromScale(0.86, 0.8), UDim2.fromScale(0.5, 0.5))
	timerLabel.TextScaled = true
	timerLabel.TextColor3 = GREEN
	timerLabel.Text = ""
	local boardRows: { BoardRow } = {}
	for index = 1, MAX_ROWS do
		local row = Instance.new("Frame")
		row.Name = string.format("Row%d", index)
		row.Size = UDim2.new(1, -12, 0, 24)
		row.Position = UDim2.new(0, 6, 0, BOARD_HEAD + 14 + (index - 1) * 26)
		row.BackgroundColor3 = INK
		row.BackgroundTransparency = 1
		row.BorderSizePixel = 0
		row.Visible = false
		row.Parent = boardPanel
		round(row, 8)
		local place = label(row, "Place", UDim2.fromOffset(26, 20), UDim2.new(0, 18, 0.5, 0))
		place.TextScaled = true
		place.TextColor3 = GOLD
		local name = label(row, "Name", UDim2.new(1, -104, 0, 20), UDim2.new(0, 40, 0.5, 0))
		name.AnchorPoint = Vector2.new(0, 0.5)
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextSize = 17
		local score = label(row, "Score", UDim2.fromOffset(64, 20), UDim2.new(1, -38, 0.5, 0))
		score.TextScaled = true
		score.TextXAlignment = Enum.TextXAlignment.Right
		boardRows[index] = { row = row, place = place, name = name, score = score }
	end

	-- ── result ───────────────────────────────────────────────────────────────────────────────
	local resultPanel = panel(gui, "Result", UDim2.fromOffset(460, 430), UDim2.fromScale(0.5, 0.5))
	local resultTitle = label(resultPanel, "Title", UDim2.fromScale(0.9, 0.14), UDim2.fromScale(0.5, 0.12))
	resultTitle.TextScaled = true
	resultTitle.Text = ""
	-- Ranked only: the rating change, the one number a ranked player looks for first.
	local resultRating = label(resultPanel, "Rating", UDim2.fromScale(0.86, 0.07), UDim2.fromScale(0.5, 0.225))
	resultRating.TextScaled = true
	resultRating.Text = ""
	local resultList = label(resultPanel, "Placings", UDim2.fromScale(0.86, 0.44), UDim2.fromScale(0.5, 0.5))
	resultList.TextWrapped = true
	resultList.TextSize = 19
	resultList.TextColor3 = CREAM
	resultList.Text = ""
	local rejoinButton = button(resultPanel, "Rejoin", "PLAY AGAIN",
		UDim2.fromScale(0.78, 0.12), UDim2.fromScale(0.5, 0.79), GREEN)
	local soloButton = button(resultPanel, "Solo", "BACK TO SOLO",
		UDim2.fromScale(0.78, 0.12), UDim2.fromScale(0.5, 0.92), MUTED)

	-- ── incoming challenge ───────────────────────────────────────────────────────────────────
	local challengePanel = panel(gui, "Challenge", UDim2.fromOffset(360, 190), UDim2.fromScale(0.5, 0.5))
	challengePanel.AnchorPoint = Vector2.new(0.5, 0)
	challengePanel.Position = UDim2.new(0.5, 0, 0, 74)
	local challengeLabel = label(challengePanel, "Text", UDim2.fromScale(0.9, 0.42), UDim2.fromScale(0.5, 0.3))
	challengeLabel.TextScaled = true
	challengeLabel.TextWrapped = true
	challengeLabel.Text = ""
	local acceptButton = button(challengePanel, "Accept", "ACCEPT",
		UDim2.fromScale(0.42, 0.26), UDim2.fromScale(0.29, 0.74), GREEN)
	local declineButton = button(challengePanel, "Decline", "DECLINE",
		UDim2.fromScale(0.42, 0.26), UDim2.fromScale(0.71, 0.74), MUTED)

	local self = setmetatable({
		gui = gui,
		entryButton = entryButton,
		queuePanel = queuePanel,
		queueStatus = queueStatus,
		queueBar = queueBar,
		queueBarFill = queueBarFill,
		duelButton = duelButton,
		lobbyButton = lobbyButton,
		cancelButton = cancelButton,
		casualChip = casualChip,
		rankedChip = rankedChip,
		kindNote = kindNote,
		kind = "CASUAL",
		queueLine = "",
		rosterPanel = rosterPanel,
		rosterTitle = rosterTitle,
		rosterList = rosterList,
		rosterCount = rosterCount,
		rosterBarFill = rosterBarFill,
		boardPanel = boardPanel,
		boardRows = boardRows,
		cutHeader = cutHeader,
		cutBanner = cutBanner,
		dangerMine = false,
		bannerToken = 0,
		timerFrame = timerFrame,
		timerLabel = timerLabel,
		timerStroke = timerStroke,
		timerScale = timerScale,
		resultPanel = resultPanel,
		resultTitle = resultTitle,
		resultRating = resultRating,
		resultList = resultList,
		rejoinButton = rejoinButton,
		soloButton = soloButton,
		challengePanel = challengePanel,
		challengeLabel = challengeLabel,
		acceptButton = acceptButton,
		declineButton = declineButton,
		localUserId = player.UserId,
		onQueue = function(_mode, _kind) end,
		onLeaveQueue = function() end,
		onAccept = function() end,
		onDecline = function() end,
		onPlaySolo = function() end,
	}, MatchPresenter) :: any

	entryButton.Activated:Connect(function()
		if self.queuePanel.Visible then
			self:hideQueue()
		elseif self.queueLine ~= "" then
			-- Still searching: reopen on the search, not on the menu. Showing the mode buttons here
			-- used to invite a second queue while the first was still live on the server.
			self.queuePanel.Visible = true
		else
			self:showQueue()
		end
	end)
	duelButton.Activated:Connect(function() self.onQueue("DUEL", self.kind) end)
	lobbyButton.Activated:Connect(function() self.onQueue("LOBBY", self.kind) end)
	casualChip.Activated:Connect(function() self:setKind("CASUAL") end)
	rankedChip.Activated:Connect(function() self:setKind("RANKED") end)
	cancelButton.Activated:Connect(function() self.onLeaveQueue() end)
	acceptButton.Activated:Connect(function() self.onAccept() end)
	declineButton.Activated:Connect(function() self.onDecline() end)
	rejoinButton.Activated:Connect(function()
		self:hideResult()
		self:showQueue()
	end)
	soloButton.Activated:Connect(function()
		self:hideResult()
		self.onPlaySolo()
	end)

	self:setKind("CASUAL")
	return self
end

function MatchPresenter.setCallbacks(
	self: MatchPresenter,
	onQueue: (string, string) -> (),
	onLeaveQueue: () -> (),
	onAccept: () -> (),
	onDecline: () -> (),
	onPlaySolo: () -> ()
)
	self.onQueue = onQueue
	self.onLeaveQueue = onLeaveQueue
	self.onAccept = onAccept
	self.onDecline = onDecline
	self.onPlaySolo = onPlaySolo
end

-- Casual is quick and unrated; ranked is rated, which is why it can take a while. Neither note
-- mentions bots, which are undisclosed by the user's decision.
function MatchPresenter.setKind(self: MatchPresenter, kind: string)
	self.kind = kind
	local ranked = kind == "RANKED"
	self.casualChip.BackgroundColor3 = if ranked then MUTED else GREEN
	self.rankedChip.BackgroundColor3 = if ranked then PURPLE else MUTED
	self.kindNote.Text = if ranked then "RATED  •  MAY TAKE A WHILE" else "QUICK MATCH  •  NOT RATED"
end

-- ─── queue ───────────────────────────────────────────────────────────────────────────────────

function MatchPresenter.showQueue(self: MatchPresenter)
	self.queueLine = ""
	self.queuePanel.Visible = true
	self.queueStatus.Text = ""
	self.queueStatus.Visible = false
	self.queueBar.Visible = false
	self.duelButton.Visible = true
	self.lobbyButton.Visible = true
	self.casualChip.Visible = true
	self.rankedChip.Visible = true
	self.cancelButton.Visible = false
	self:setKind(self.kind)
end

function MatchPresenter.hideQueue(self: MatchPresenter)
	self.queuePanel.Visible = false
end

-- Waiting is the state players abandon a mode over, so say what is being waited for rather than
-- spinning: how many are here, how many it takes, and how long it has been.
function MatchPresenter.setQueued(self: MatchPresenter, mode: string, waiting: number, target: number,
	kind: string?, rating: number?, ratingsOnline: boolean?)
	self.queuePanel.Visible = true
	self.duelButton.Visible = false
	self.lobbyButton.Visible = false
	self.casualChip.Visible = false
	self.rankedChip.Visible = false
	self.cancelButton.Visible = true
	self.queueStatus.Visible = true
	self.queueBar.Visible = true
	self.queueBarFill.Size = UDim2.fromScale(0, 1)
	if kind == "RANKED" then
		-- Offline is said out loud: a rating that is not being saved must not look like one that is.
		self.kindNote.Text = if rating
			then string.format("RANKED  •  YOUR RATING %d%s", rating,
				if ratingsOnline == false then "  •  OFFLINE, NOT SAVED" else "")
			else "RANKED"
	else
		self.kindNote.Text = "QUICK MATCH  •  NOT RATED"
	end
	local modeName = if mode == "DUEL" then "DUEL" else "LOBBY"
	self.queueLine = string.format("FINDING A %s  %d / %d", modeName, waiting, target)
	self.queueStatus.Text = self.queueLine
	self.queueStatus.TextColor3 = if waiting >= target then GREEN else CREAM
end

-- Called every frame while queued, against the server's own timestamp for when the search began.
function MatchPresenter.setQueueElapsed(self: MatchPresenter, seconds: number)
	if self.queueLine == "" then
		return
	end
	local whole = math.max(0, math.floor(seconds))
	self.queueStatus.Text = string.format("%s   %d:%02d", self.queueLine, whole // 60, whole % 60)
	local progress = math.min(SEARCH_BAR_CAP, 1 - math.exp(-math.max(0, seconds) / SEARCH_BAR_SECONDS))
	self.queueBarFill.Size = UDim2.fromScale(progress, 1)
end

-- ─── roster ──────────────────────────────────────────────────────────────────────────────────

function MatchPresenter.showRoster(self: MatchPresenter, mode: string, roster: { any }, ranked: boolean?)
	self.queueLine = ""
	self.entryButton.Visible = false
	self.queuePanel.Visible = false
	self.resultPanel.Visible = false
	self.challengePanel.Visible = false
	self.rosterPanel.Visible = true
	local title = if mode == "DUEL" then "DUEL FOUND" else "LOBBY FOUND"
	self.rosterTitle.Text = if ranked then "RANKED " .. title else title
	local names: { string } = {}
	for _, entry in roster do
		local who = tostring((entry :: any).name)
		if (entry :: any).userId == self.localUserId then
			who = who .. "  (you)"
		end
		table.insert(names, who)
	end
	self.rosterList.Text = table.concat(names, "\n")
	self.rosterCount.Text = ""
	self.rosterBarFill.Size = UDim2.fromScale(0, 1)
end

function MatchPresenter.setRosterCountdown(self: MatchPresenter, seconds: number, total: number?)
	if not self.rosterPanel.Visible then
		return
	end
	self.rosterCount.Text = string.format("STARTING IN %d", math.max(0, math.ceil(seconds)))
	if total and total > 0 then
		self.rosterBarFill.Size = UDim2.fromScale(math.clamp(1 - seconds / total, 0, 1), 1)
	end
end

function MatchPresenter.hideRoster(self: MatchPresenter)
	self.rosterPanel.Visible = false
end

-- ─── the live table ──────────────────────────────────────────────────────────────────────────

--[[
	Draws the ranked table the server sent.

	Rows are never re-sorted here. The order arrived from `MatchRules`, which is the same function
	that produces the final placings, so what a player watches all match is what decides it. Sorting
	locally would be a second opinion about who is winning, and the two could disagree.
]]
function MatchPresenter.setScores(self: MatchPresenter, placings: { any })
	self.boardPanel.Visible = true
	-- Only as tall as the rows it holds, so a duel's table stays clear of the upgrade bar below it.
	self.boardPanel.Size = UDim2.fromOffset(230, BOARD_HEAD + 24 + math.min(#placings, MAX_ROWS) * 26)
	local dangerMine = false
	for index, slot in self.boardRows do
		local entry = placings[index]
		if not entry then
			slot.row.Visible = false
		else
			local e = entry :: any
			local mine = e.userId == self.localUserId
			-- The row the next cut would take, marked so everyone can see who has to catch up.
			local danger = e.danger == true
			dangerMine = dangerMine or (danger and mine)
			slot.row.Visible = true
			slot.row.BackgroundColor3 = if danger then CORAL else INK
			slot.row.BackgroundTransparency = if danger then 0.3 elseif mine then 0.35 else 1
			slot.place.Text = tostring(e.place)
			slot.name.Text = tostring(e.name)
			slot.score.Text = tostring(e.score)
			-- Out of the running reads as dimmed, not as removed: their score still counts and can
			-- still win, which is the rule the whole mode turns on.
			local out = e.alive == false
			slot.name.TextColor3 = if out then MUTED else PAPER
			slot.score.TextColor3 = if out then MUTED else (if mine then GOLD else PAPER)
		end
	end
	self.dangerMine = dangerMine
end

-- Called every frame with the time left to the next cut, read against the server's timestamp.
function MatchPresenter.setCutCountdown(self: MatchPresenter, seconds: number?)
	if not seconds then
		self.cutHeader.Text = ""
		return
	end
	local whole = math.max(0, math.ceil(seconds))
	local clock = string.format("%d:%02d", whole // 60, whole % 60)
	if self.dangerMine then
		self.cutHeader.Text = "YOU'RE LOWEST  •  " .. clock
		self.cutHeader.TextColor3 = CORAL
	else
		self.cutHeader.Text = "NEXT CUT  " .. clock
		self.cutHeader.TextColor3 = if whole <= 10 then GOLD else CREAM
	end
end

-- Someone was just cut. Said once, for a few seconds.
function MatchPresenter.showCut(self: MatchPresenter, name: string, minute: number, you: boolean)
	self.bannerToken += 1
	local token = self.bannerToken
	self.cutBanner.Text = if you
		then string.format("YOU WERE CUT  •  LOWEST AT %d:00", minute)
		else string.format("%s WAS CUT  •  LOWEST AT %d:00", string.upper(name), minute)
	self.cutBanner.TextColor3 = if you then CORAL else GOLD
	self.cutBanner.Visible = true
	task.delay(3.5, function()
		if self.bannerToken == token then
			self.cutBanner.Visible = false
		end
	end)
end

-- A duel's final minute has begun: a warning only.
function MatchPresenter.showFinalMinute(self: MatchPresenter)
	self.bannerToken += 1
	local token = self.bannerToken
	self.cutBanner.Text = "1 MINUTE LEFT!  MOST POINTS WINS"
	self.cutBanner.TextColor3 = GOLD
	self.cutBanner.Visible = true
	task.delay(4, function()
		if self.bannerToken == token then
			self.cutBanner.Visible = false
		end
	end)
end

--[[
	The duel timer's colour: green with plenty of time, turning gold across the middle minutes and
	red over the last one (the user, 2026-09-11: "a timer that changes colors the closer to 0 it gets").
]]
local function timerColour(seconds: number): Color3
	if seconds >= 150 then
		return GREEN
	elseif seconds >= 60 then
		return GREEN:Lerp(GOLD, (150 - seconds) / 90)
	end
	return GOLD:Lerp(CORAL, math.clamp((60 - seconds) / 60, 0, 1))
end

-- A duel's clock, every frame: the time left to the buzzer, when the most points wins.
function MatchPresenter.setDuelTimer(self: MatchPresenter, seconds: number)
	local whole = math.max(0, math.ceil(seconds))
	local colour = timerColour(seconds)
	self.timerFrame.Visible = true
	self.timerLabel.Text = string.format("%d:%02d", whole // 60, whole % 60)
	self.timerLabel.TextColor3 = colour
	self.timerStroke.Color = colour
	-- The last ten seconds pulse once a second.
	self.timerScale.Scale = if seconds > 0 and seconds <= 10 then 1 + 0.14 * (seconds % 1) else 1
	self.cutHeader.Text = if seconds <= 60 then "FINAL MINUTE  •  MOST POINTS WINS" else "MOST POINTS AT 0:00 WINS"
	self.cutHeader.TextColor3 = if seconds <= 60 then colour else CREAM
end

function MatchPresenter.hideScores(self: MatchPresenter)
	self.boardPanel.Visible = false
	self.cutHeader.Text = ""
	self.dangerMine = false
	self.timerFrame.Visible = false
	for _, slot in self.boardRows do
		slot.row.Visible = false
	end
end

-- ─── result ──────────────────────────────────────────────────────────────────────────────────

function MatchPresenter.showResult(self: MatchPresenter, placings: { any }, ratings: { any }?)
	self.entryButton.Visible = false
	self.rosterPanel.Visible = false
	self.queuePanel.Visible = false
	self.resultPanel.Visible = true

	local mine: any = nil
	local rows: { string } = {}
	for _, entry in placings do
		local e = entry :: any
		if e.userId == self.localUserId then
			mine = e
		end
		local suffix = if e.alive == false and e.deathReason == "CUT" then "  (cut)"
			elseif e.alive == false and e.deathReason == "CHECKPOINT" then "  (off the pace)"
			else ""
		table.insert(rows, string.format("%d.  %s  —  %d%s", e.place, tostring(e.name), e.score, suffix))
	end
	self.resultList.Text = table.concat(rows, "\n")

	if mine and mine.place == 1 then
		self.resultTitle.Text = "YOU WIN!"
		self.resultTitle.TextColor3 = GOLD
	elseif mine then
		self.resultTitle.Text = string.format("%d%s PLACE", mine.place,
			({ "st", "nd", "rd" })[mine.place] or "th")
		self.resultTitle.TextColor3 = CREAM
	else
		self.resultTitle.Text = "MATCH OVER"
		self.resultTitle.TextColor3 = CREAM
	end

	local change: any = nil
	if typeof(ratings) == "table" then
		for _, entry in ratings :: any do
			if entry.userId == self.localUserId then
				change = entry
			end
		end
	end
	if change and typeof(change.after) == "number" and typeof(change.delta) == "number" then
		self.resultRating.Text = string.format("RATING %d   (%s%d)", change.after,
			if change.delta >= 0 then "+" else "", change.delta)
		self.resultRating.TextColor3 = if change.delta >= 0 then GREEN else CORAL
	else
		self.resultRating.Text = ""
	end
end

function MatchPresenter.hideResult(self: MatchPresenter)
	self.resultPanel.Visible = false
	self.entryButton.Visible = true
end

-- ─── challenge ───────────────────────────────────────────────────────────────────────────────

function MatchPresenter.showChallenge(self: MatchPresenter, fromName: string)
	self.challengePanel.Visible = true
	self.challengeLabel.Text = string.format("%s CHALLENGED YOU", fromName)
end

function MatchPresenter.hideChallenge(self: MatchPresenter)
	self.challengePanel.Visible = false
end

function MatchPresenter.destroy(self: MatchPresenter)
	self.gui:Destroy()
end

return MatchPresenter
