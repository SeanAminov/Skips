--!strict
--[[
	RunPresenter — cartoony, disposable visuals over the deterministic run.

	The avatar, camera, curved rope and HUD only read RunSim state. The rope has no animation clock:
	every segment is rebuilt from `nextSweepTick`, so the friendly curve can never lie about the tick
	that scores or ends a run. Upgrade choices follow the reference hierarchy: icon, short name, and
	an unmistakable selected state. Mechanical prose stays out of the play surface.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardCatalog = require(Shared:WaitForChild("CardCatalog"))
local RunProtocol = require(Shared:WaitForChild("RunProtocol"))
local RunSim = require(Shared:WaitForChild("RunSim"))
local SimTuning = require(Shared:WaitForChild("SimTuning"))
local ViewProtocol = require(Shared:WaitForChild("ViewProtocol"))
local RopeView = require(script.Parent:WaitForChild("RopeView"))

type Run = RunSim.Run
type OfferCard = {
	button: ImageButton,
	icon: ImageLabel,
	nameLabel: TextLabel,
	stroke: UIStroke,
	scale: UIScale,
}
-- How the camera frames the lanes on screen (StageView): the span of lanes shown, and -- while
-- spectating -- whose lane and height to follow instead of your own.
export type Framing = {
	minLane: number,
	maxLane: number,
	focusLane: number?,
	focusY: number?,
}

local ICON_ATLAS = "rbxassetid://111503507808579"
-- Roblox serves this upload as a 1024x512 texture even though the source PNG is larger.
-- ImageRect coordinates address the served texture, not the source file dimensions.
local ICON_ATLAS_SIZE = Vector2.new(1024, 512)
local ICON_COLUMNS = 5
local ICON_ROWS = 2

local THEME_COLORS: { [string]: Color3 } = {
	BLUE = Color3.fromRGB(93, 151, 213),
	CORAL = Color3.fromRGB(255, 112, 104),
	GOLD = Color3.fromRGB(213, 166, 93),
	GREEN = Color3.fromRGB(76, 181, 128),
	PURPLE = Color3.fromRGB(145, 111, 207),
	TEAL = Color3.fromRGB(74, 174, 184),
}

-- The level badge atop the upgrade bar, by screen fraction, and the pause button that must clear it.
local UPGRADE_BADGE_X, UPGRADE_BADGE_Y, UPGRADE_BADGE_SIZE = 0.95, 0.225, 58
-- The score multiplier sits to the badge's upper-left so the two progression readouts form one
-- cluster without covering the vertical bar. It stays hidden at the base x1 award.
local MULTIPLIER_BADGE_X, MULTIPLIER_BADGE_Y = 0.875, 0.175
local MULTIPLIER_BADGE_SIZE = Vector2.new(92, 42)
local PAUSE_SIZE = Vector2.new(76, 52)
local PAUSE_TOP = 92
-- Just under Roblox's own top bar, which the HUD ignores the inset of.
local PAUSE_MIN_TOP = 60
local PAUSE_GAP = 8

local RunPresenter = {}
RunPresenter.__index = RunPresenter

export type RunPresenter = typeof(setmetatable(
	{} :: {
		gui: ScreenGui,
		scoreLabel: TextLabel,
		luckyLabel: TextLabel,
		luckyToken: number,
		flashOriginalTransparency: { [BasePart]: number },
		flashVisible: boolean,
		statusLabel: TextLabel,
		fuelPanel: Frame,
		fuelFill: Frame,
		fuelStroke: UIStroke,
		fuelWasActive: boolean?,
		hintPanel: Frame,
		upgradeTrack: Frame,
		upgradeFill: Frame,
		upgradeLevel: TextLabel,
		pointsMultiplier: TextLabel,
		offerPanel: Frame,
		offerTimer: TextLabel,
		offerCards: { OfferCard },
		offerIndex: number,
		offerPointerIndex: number?,
		onOfferChosen: (number) -> (),
		revivePanel: Frame,
		reviveButton: TextButton,
		reviveTimer: TextLabel,
		reviveStatus: TextLabel,
		-- What the offer on screen costs, in tickets, as the server said.
		reviveCost: number,
		onReviveChosen: () -> (),
		onReviveDeclined: () -> (),
		ropeFolder: Folder,
		ropeView: RopeView.RopeView,
		sceneryFolder: Folder,
		sceneryBuilt: boolean,
		armsPosed: boolean,
		root: BasePart?,
		humanoid: Humanoid?,
		jumpTrack: AnimationTrack?,
		wasAirborne: boolean,
		baseRoot: CFrame,
		groundPosition: Vector3,
		colorEffect: ColorCorrectionEffect,
		bloomEffect: BloomEffect,
		blurEffect: BlurEffect,
		reviveSecondary: TextButton,
		onReviveClosed: () -> (),
		pauseButton: TextButton,
		pausedPanel: Frame,
		pausedStatus: TextLabel,
		resumeButton: TextButton,
		onPause: () -> (),
		onResume: () -> (),
		runOverPanel: Frame,
		runOverScore: TextLabel,
		runOverDetail: TextLabel,
		onPlayAgain: () -> (),
		pingLabel: TextLabel,
		tripStartedAt: number?,
		hintEnabled: boolean,
		lowGraphics: boolean,
		sceneryExtras: { Instance },
		shadowsWere: boolean,
		framing: Framing?,
		spectating: boolean,
	},
	{} :: { __index: typeof(RunPresenter) }
))

local function makeLabel(parent: Instance, name: string, size: UDim2, position: UDim2): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Size = size
	label.Position = position
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextColor3 = Color3.fromRGB(255, 253, 244)
	label.TextStrokeColor3 = Color3.fromRGB(40, 36, 61)
	label.TextStrokeTransparency = 0.05
	label.Parent = parent
	return label
end

local function round(object: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = object
end

--[[
	A CanvasGroup that clips its children to the track's rounded shape.

	`ClipsDescendants` clips to the RECTANGLE, so a fill inside a rounded track poked its square
	corners out past the rounding -- the user spotted exactly that on the level-up bar. A CanvasGroup
	clips to its own UICorner. The outline stays on the outer track, so the group never has to draw
	outside itself.
]]
local function clipTo(track: GuiObject, radius: number): CanvasGroup
	local clip = Instance.new("CanvasGroup")
	clip.Name = "Clip"
	clip.Size = UDim2.fromScale(1, 1)
	clip.BackgroundTransparency = 1
	clip.BorderSizePixel = 0
	clip.Parent = track
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = clip
	return clip
end

local function outline(object: GuiObject, color: Color3, thickness: number): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = object
	return stroke
end

local function iconRect(index: number): (Vector2, Vector2)
	local zero = index - 1
	local column = zero % ICON_COLUMNS
	local row = math.floor(zero / ICON_COLUMNS)
	local cell = Vector2.new(ICON_ATLAS_SIZE.X / ICON_COLUMNS, ICON_ATLAS_SIZE.Y / ICON_ROWS)
	return Vector2.new(column * cell.X, row * cell.Y), cell
end

local function makeWorldPart(parent: Instance, name: string, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Color = color
	part.Parent = parent
	return part
end

local function createOfferCard(self: RunPresenter, index: number): OfferCard
	local button = Instance.new("ImageButton")
	button.Name = "Card" .. index
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	-- Keep the row evenly spaced, but pull both outside cards inward. At hover scale the old 20/80%
	-- centres let Card 1 grow underneath the permanent left-side buttons on narrower viewports.
	button.Position = UDim2.fromScale(0.25 + (index - 1) * 0.25, 0.56)
	button.Size = UDim2.fromScale(0.235, 0.56)
	button.BackgroundColor3 = THEME_COLORS.BLUE
	button.BackgroundTransparency = 0.08
	button.AutoButtonColor = false
	button.Selectable = true
	button.Image = ""
	button.ZIndex = 12
	button.Parent = self.offerPanel
	round(button, 22)
	local stroke = outline(button, Color3.fromRGB(255, 255, 255), 3)

	local scale = Instance.new("UIScale")
	scale.Scale = 0.92
	scale.Parent = button

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.39)
	icon.Size = UDim2.fromScale(0.84, 0.62)
	icon.BackgroundTransparency = 1
	icon.Image = ICON_ATLAS
	icon.ScaleType = Enum.ScaleType.Fit
	icon.ZIndex = 13
	icon.Parent = button

	local nameLabel = makeLabel(button, "Name", UDim2.fromScale(0.86, 0.2), UDim2.fromScale(0.5, 0.83))
	nameLabel.TextWrapped = true
	nameLabel.TextScaled = true
	nameLabel.TextStrokeTransparency = 0.72
	nameLabel.TextColor3 = Color3.fromRGB(52, 45, 64)
	nameLabel.ZIndex = 13

	button.MouseEnter:Connect(function()
		if self.offerPanel.Visible then
			self.offerPointerIndex = index
			self:setOfferIndex(index)
		end
	end)
	button.MouseLeave:Connect(function()
		if self.offerPointerIndex == index then
			self.offerPointerIndex = nil
		end
	end)
	button.MouseButton1Down:Connect(function()
		-- Touch has no hover and mouse users expect the outline to move on press, not after release.
		if self.offerPanel.Visible then
			self.offerPointerIndex = index
			self:setOfferIndex(index)
		end
	end)
	button.Activated:Connect(function()
		if self.offerPanel.Visible then
			self:setOfferIndex(index)
			self.onOfferChosen(index)
		end
	end)

	return {
		button = button,
		icon = icon,
		nameLabel = nameLabel,
		stroke = stroke,
		scale = scale,
	}
end

function RunPresenter.new(): RunPresenter
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild("SkipsHUD")
	if old then old:Destroy() end
	for _, name in { "SkipsLocalRopes", "SkipsLocalScenery" } do
		local worldVisual = workspace:FindFirstChild(name)
		if worldVisual then worldVisual:Destroy() end
	end
	for _, name in { "SkipsColor", "SkipsBloom", "SkipsBlur" } do
		local effect = Lighting:FindFirstChild(name)
		if effect then effect:Destroy() end
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "SkipsHUD"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 10
	gui.Parent = playerGui

	local score = makeLabel(gui, "Score", UDim2.fromOffset(380, 86), UDim2.fromScale(0.5, 0.09))
	score.TextScaled = true
	score.Text = "0"
	local luckyLabel = makeLabel(gui, "Lucky", UDim2.fromOffset(300, 46), UDim2.fromScale(0.5, 0.16))
	luckyLabel.Text = "LUCKY!"
	luckyLabel.TextScaled = true
	luckyLabel.TextColor3 = Color3.fromRGB(255, 224, 79)
	luckyLabel.TextStrokeColor3 = Color3.fromRGB(121, 58, 109)
	luckyLabel.TextTransparency = 1
	luckyLabel.TextStrokeTransparency = 1
	local status = makeLabel(gui, "Status", UDim2.fromScale(0.62, 0.11), UDim2.fromScale(0.5, 0.41))
	status.TextScaled = true
	status.Text = "GET READY!"

	-- Rocket fuel stays icon-first like the card UI: one chunky boot tile and a readable gauge,
	-- with no mechanical paragraph competing with the rope. It remains hidden until shoes unlock.
	local fuelPanel = Instance.new("Frame")
	fuelPanel.Name = "RocketFuel"
	fuelPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	fuelPanel.Position = UDim2.fromScale(0.5, 0.84)
	fuelPanel.Size = UDim2.fromOffset(330, 38)
	fuelPanel.BackgroundColor3 = Color3.fromRGB(42, 37, 62)
	fuelPanel.BackgroundTransparency = 0.08
	fuelPanel.BorderSizePixel = 0
	fuelPanel.Visible = false
	fuelPanel.Parent = gui
	round(fuelPanel, 19)
	outline(fuelPanel, Color3.fromRGB(255, 255, 255), 3)

	local fuelIcon = Instance.new("ImageLabel")
	fuelIcon.Name = "BootIcon"
	fuelIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	fuelIcon.Position = UDim2.fromOffset(25, 19)
	fuelIcon.Size = UDim2.fromOffset(42, 42)
	fuelIcon.BackgroundTransparency = 1
	fuelIcon.Image = ICON_ATLAS
	local fuelIconOffset, fuelIconSize = iconRect(5)
	fuelIcon.ImageRectOffset = fuelIconOffset
	fuelIcon.ImageRectSize = fuelIconSize
	fuelIcon.Parent = fuelPanel

	local fuelTrack = Instance.new("Frame")
	fuelTrack.Name = "Track"
	fuelTrack.AnchorPoint = Vector2.new(0, 0.5)
	fuelTrack.Position = UDim2.fromOffset(53, 19)
	fuelTrack.Size = UDim2.fromOffset(263, 22)
	fuelTrack.BackgroundColor3 = Color3.fromRGB(25, 23, 42)
	fuelTrack.BorderSizePixel = 0
	fuelTrack.Parent = fuelPanel
	round(fuelTrack, 11)
	local fuelStroke = outline(fuelTrack, Color3.fromRGB(181, 139, 235), 2)
	local fuelClip = clipTo(fuelTrack, 11)

	local fuelFill = Instance.new("Frame")
	fuelFill.Name = "Fill"
	fuelFill.Size = UDim2.fromScale(1, 1)
	fuelFill.BackgroundColor3 = Color3.fromRGB(164, 112, 236)
	fuelFill.BorderSizePixel = 0
	fuelFill.Parent = fuelClip
	-- Rounded ends: the fill grows as a pill inside the pill, never as a flat-ended block.
	local fuelFillCorner = Instance.new("UICorner")
	fuelFillCorner.CornerRadius = UDim.new(1, 0)
	fuelFillCorner.Parent = fuelFill
	local fuelGradient = Instance.new("UIGradient")
	fuelGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(112, 213, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(190, 91, 236)),
	})
	fuelGradient.Parent = fuelFill

	local hintPanel = Instance.new("Frame")
	hintPanel.Name = "Hint"
	hintPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	hintPanel.Position = UDim2.fromScale(0.5, 0.93)
	hintPanel.Size = UDim2.fromOffset(370, 42)
	hintPanel.BackgroundColor3 = Color3.fromRGB(42, 37, 62)
	hintPanel.BackgroundTransparency = 0.15
	hintPanel.BorderSizePixel = 0
	hintPanel.Parent = gui
	round(hintPanel, 21)
	local hint = makeLabel(hintPanel, "Text", UDim2.fromScale(0.9, 0.78), UDim2.fromScale(0.5, 0.5))
	hint.Font = Enum.Font.GothamBold
	hint.TextScaled = true
	hint.TextStrokeTransparency = 1
	hint.Text = "PRESS   •   HOLD   •   RELEASE"

	-- The reference keeps a slim vertical level bar on the right. This bar reads RunSim's discrete
	-- clear progress: it moves only when a rope scores, and its final step opens the offer at once.
	local upgradeTrack = Instance.new("Frame")
	upgradeTrack.Name = "UpgradeTrack"
	upgradeTrack.AnchorPoint = Vector2.new(0.5, 0.5)
	upgradeTrack.Position = UDim2.fromScale(0.95, 0.52)
	upgradeTrack.Size = UDim2.fromScale(0.026, 0.5)
	upgradeTrack.BackgroundColor3 = Color3.fromRGB(42, 37, 62)
	upgradeTrack.BackgroundTransparency = 0.08
	upgradeTrack.BorderSizePixel = 0
	upgradeTrack.Parent = gui
	round(upgradeTrack, 18)
	outline(upgradeTrack, Color3.fromRGB(255, 253, 244), 3)
	local upgradeClip = clipTo(upgradeTrack, 18)

	local upgradeFill = Instance.new("Frame")
	upgradeFill.Name = "Fill"
	upgradeFill.AnchorPoint = Vector2.new(0, 1)
	upgradeFill.Position = UDim2.fromScale(0, 1)
	upgradeFill.Size = UDim2.fromScale(1, 0)
	upgradeFill.BackgroundColor3 = Color3.fromRGB(255, 91, 124)
	upgradeFill.BorderSizePixel = 0
	upgradeFill.Parent = upgradeClip
	-- The user (2026-09-11): "the outline is oval, but the bar goes up by rectangles". The fill's
	-- leading edge is rounded now, so it rises as a pill that matches the outline around it.
	local upgradeFillCorner = Instance.new("UICorner")
	upgradeFillCorner.CornerRadius = UDim.new(1, 0)
	upgradeFillCorner.Parent = upgradeFill
	local upgradeGradient = Instance.new("UIGradient")
	upgradeGradient.Rotation = 90
	upgradeGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 194, 91)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 83, 148)),
	})
	upgradeGradient.Parent = upgradeFill

	local upgradeLevel = makeLabel(gui, "UpgradeLevel", UDim2.fromOffset(UPGRADE_BADGE_SIZE, UPGRADE_BADGE_SIZE),
		UDim2.fromScale(UPGRADE_BADGE_X, UPGRADE_BADGE_Y))
	upgradeLevel.BackgroundTransparency = 0
	upgradeLevel.BackgroundColor3 = Color3.fromRGB(42, 37, 62)
	upgradeLevel.TextScaled = true
	upgradeLevel.Text = "1"
	round(upgradeLevel, 29)
	outline(upgradeLevel, Color3.fromRGB(255, 253, 244), 3)

	local pointsMultiplier = makeLabel(gui, "PointsMultiplier",
		UDim2.fromOffset(MULTIPLIER_BADGE_SIZE.X, MULTIPLIER_BADGE_SIZE.Y),
		UDim2.fromScale(MULTIPLIER_BADGE_X, MULTIPLIER_BADGE_Y))
	pointsMultiplier.BackgroundTransparency = 0
	pointsMultiplier.BackgroundColor3 = Color3.fromRGB(91, 68, 204)
	pointsMultiplier.TextColor3 = Color3.fromRGB(255, 247, 196)
	pointsMultiplier.TextScaled = true
	pointsMultiplier.Text = "2X"
	pointsMultiplier.Visible = false
	round(pointsMultiplier, 21)
	outline(pointsMultiplier, Color3.fromRGB(255, 253, 244), 3)
	local multiplierGradient = Instance.new("UIGradient")
	multiplierGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(119, 95, 238)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(76, 181, 213)),
	})
	multiplierGradient.Rotation = 18
	multiplierGradient.Parent = pointsMultiplier

	local offerPanel = Instance.new("Frame")
	offerPanel.Name = "CardOffer"
	offerPanel.Size = UDim2.fromScale(1, 1)
	offerPanel.BackgroundColor3 = Color3.fromRGB(24, 28, 47)
	offerPanel.BackgroundTransparency = 0.45
	offerPanel.BorderSizePixel = 0
	offerPanel.Visible = false
	offerPanel.Active = true
	offerPanel.ZIndex = 10
	offerPanel.Parent = gui
	local offerTitle = makeLabel(offerPanel, "Title", UDim2.fromScale(0.72, 0.14), UDim2.fromScale(0.5, 0.14))
	offerTitle.TextScaled = true
	offerTitle.Text = "CHOOSE AN UPGRADE"
	offerTitle.TextStrokeTransparency = 0
	offerTitle.ZIndex = 15

	-- A paused run has stopped scoring while everyone else keeps going, so the choice carries a
	-- deadline. Showing it is the honest thing: the game is going to pick for you, and finding
	-- that out by having it happen is worse than watching a number run down.
	local offerTimer = makeLabel(offerPanel, "Deadline", UDim2.fromScale(0.5, 0.07),
		UDim2.fromScale(0.5, 0.26))
	offerTimer.TextScaled = true
	offerTimer.TextStrokeTransparency = 0
	offerTimer.ZIndex = 15
	offerTimer.Text = ""

	local revivePanel = Instance.new("Frame")
	revivePanel.Name = "ReviveOffer"
	revivePanel.AnchorPoint = Vector2.new(0.5, 0.5)
	revivePanel.Position = UDim2.fromScale(0.5, 0.52)
	revivePanel.Size = UDim2.fromOffset(410, 330)
	revivePanel.BackgroundColor3 = Color3.fromRGB(255, 244, 211)
	revivePanel.BorderSizePixel = 0
	revivePanel.Visible = false
	revivePanel.Active = true
	revivePanel.ZIndex = 30
	revivePanel.Parent = gui
	round(revivePanel, 32)
	outline(revivePanel, Color3.fromRGB(79, 56, 75), 5)

	local reviveTitle = makeLabel(revivePanel, "Title", UDim2.fromScale(0.86, 0.16), UDim2.fromScale(0.5, 0.14))
	reviveTitle.Text = "REVIVE RUN?"
	reviveTitle.TextColor3 = Color3.fromRGB(63, 48, 72)
	reviveTitle.TextStrokeTransparency = 1
	reviveTitle.TextScaled = true
	reviveTitle.ZIndex = 31
	local reviveTimer = makeLabel(revivePanel, "Timer", UDim2.fromOffset(104, 104), UDim2.fromScale(0.5, 0.37))
	reviveTimer.BackgroundTransparency = 0
	reviveTimer.BackgroundColor3 = Color3.fromRGB(255, 111, 104)
	reviveTimer.Text = "10"
	reviveTimer.TextScaled = true
	reviveTimer.ZIndex = 31
	round(reviveTimer, 52)
	outline(reviveTimer, Color3.fromRGB(255, 255, 255), 4)

	local reviveButton = Instance.new("TextButton")
	reviveButton.Name = "Revive"
	reviveButton.AnchorPoint = Vector2.new(0.5, 0.5)
	reviveButton.Position = UDim2.fromScale(0.5, 0.67)
	reviveButton.Size = UDim2.fromScale(0.78, 0.18)
	reviveButton.BackgroundColor3 = Color3.fromRGB(76, 181, 128)
	reviveButton.BorderSizePixel = 0
	reviveButton.Font = Enum.Font.FredokaOne
	reviveButton.Text = "REVIVE"
	reviveButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	reviveButton.TextScaled = true
	reviveButton.ZIndex = 31
	reviveButton.Parent = revivePanel
	round(reviveButton, 22)
	outline(reviveButton, Color3.fromRGB(44, 117, 87), 3)

	-- A real button, not a line of grey text: the way out of the revive offer was easy to miss when it
	-- looked like a caption. In solo it skips the offer and starts the next run in one press.
	local newRunButton = Instance.new("TextButton")
	newRunButton.Name = "NewRun"
	newRunButton.AnchorPoint = Vector2.new(0.5, 0.5)
	newRunButton.Position = UDim2.fromScale(0.5, 0.855)
	newRunButton.Size = UDim2.fromScale(0.58, 0.12)
	newRunButton.BackgroundColor3 = Color3.fromRGB(157, 147, 164)
	newRunButton.BorderSizePixel = 0
	newRunButton.Font = Enum.Font.FredokaOne
	newRunButton.Text = "NEW RUN"
	newRunButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	newRunButton.TextScaled = true
	newRunButton.ZIndex = 31
	newRunButton.Parent = revivePanel
	round(newRunButton, 18)
	outline(newRunButton, Color3.fromRGB(90, 76, 96), 3)

	-- The corner X closes the offer without starting anything.
	local reviveClose = Instance.new("TextButton")
	reviveClose.Name = "Close"
	reviveClose.AnchorPoint = Vector2.new(0.5, 0.5)
	reviveClose.Position = UDim2.new(1, -16, 0, 16)
	reviveClose.Size = UDim2.fromOffset(44, 44)
	reviveClose.BackgroundColor3 = Color3.fromRGB(255, 111, 104)
	reviveClose.BorderSizePixel = 0
	reviveClose.Font = Enum.Font.FredokaOne
	reviveClose.Text = "X"
	reviveClose.TextColor3 = Color3.fromRGB(255, 255, 255)
	reviveClose.TextScaled = true
	reviveClose.ZIndex = 32
	reviveClose.Parent = revivePanel
	round(reviveClose, 22)
	outline(reviveClose, Color3.fromRGB(79, 56, 75), 3)

	local reviveStatus = makeLabel(revivePanel, "Message", UDim2.fromScale(0.86, 0.08), UDim2.fromScale(0.5, 0.955))
	reviveStatus.Font = Enum.Font.GothamBold
	reviveStatus.TextColor3 = Color3.fromRGB(122, 98, 114)
	reviveStatus.TextStrokeTransparency = 1
	reviveStatus.TextScaled = true
	reviveStatus.ZIndex = 31

	-- ── pause, solo only ─────────────────────────────────────────────────────────────────────
	-- Top right, level with VS on the left. It never shares the corner with the live match table,
	-- because a match run cannot be paused.
	local pauseButton = Instance.new("TextButton")
	pauseButton.Name = "Pause"
	pauseButton.AnchorPoint = Vector2.new(1, 0)
	pauseButton.Position = UDim2.new(1, -14, 0, PAUSE_TOP)
	pauseButton.Size = UDim2.fromOffset(PAUSE_SIZE.X, PAUSE_SIZE.Y)
	pauseButton.BackgroundColor3 = Color3.fromRGB(93, 151, 213)
	pauseButton.BorderSizePixel = 0
	pauseButton.Font = Enum.Font.FredokaOne
	pauseButton.Text = "II"
	pauseButton.TextColor3 = Color3.fromRGB(255, 253, 244)
	pauseButton.TextStrokeColor3 = Color3.fromRGB(40, 36, 61)
	pauseButton.TextStrokeTransparency = 0.2
	pauseButton.TextScaled = true
	pauseButton.Visible = false
	pauseButton.ZIndex = 5
	pauseButton.Parent = gui
	round(pauseButton, 14)
	outline(pauseButton, Color3.fromRGB(40, 36, 61), 3)

	--[[
		The pause button never sits on the level badge (the user, 2026-09-11: "move the pause button to
		not overlap with xp upgrade bar, can move up slightly"). The badge is placed by screen fraction
		and the button in pixels, so on a shorter screen they met. The button now rises toward the top
		as far as the Roblox top bar allows; on a screen too short even for that it moves to the
		badge's left instead.
	]]
	local function layoutPause()
		local camera = workspace.CurrentCamera
		local height = if camera then camera.ViewportSize.Y else 1080
		local badgeTop = UPGRADE_BADGE_Y * height - UPGRADE_BADGE_SIZE * 0.5
		local top = math.min(PAUSE_TOP, badgeTop - PAUSE_GAP - PAUSE_SIZE.Y)
		if top >= PAUSE_MIN_TOP then
			pauseButton.AnchorPoint = Vector2.new(1, 0)
			pauseButton.Position = UDim2.new(1, -14, 0, top)
		else
			pauseButton.AnchorPoint = Vector2.new(1, 0.5)
			pauseButton.Position = UDim2.new(UPGRADE_BADGE_X, -(UPGRADE_BADGE_SIZE * 0.5 + PAUSE_GAP),
				UPGRADE_BADGE_Y, 0)
		end
	end
	layoutPause()
	if workspace.CurrentCamera then
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(layoutPause)
	end

	local pausedPanel = Instance.new("Frame")
	pausedPanel.Name = "Paused"
	pausedPanel.Size = UDim2.fromScale(1, 1)
	pausedPanel.BackgroundColor3 = Color3.fromRGB(24, 28, 47)
	pausedPanel.BackgroundTransparency = 0.4
	pausedPanel.BorderSizePixel = 0
	pausedPanel.Visible = false
	pausedPanel.Active = true
	pausedPanel.ZIndex = 40
	pausedPanel.Parent = gui
	local pausedTitle = makeLabel(pausedPanel, "Title", UDim2.fromScale(0.6, 0.14), UDim2.fromScale(0.5, 0.36))
	pausedTitle.TextScaled = true
	pausedTitle.Text = "PAUSED"
	pausedTitle.ZIndex = 41
	local resumeButton = Instance.new("TextButton")
	resumeButton.Name = "Resume"
	resumeButton.AnchorPoint = Vector2.new(0.5, 0.5)
	resumeButton.Position = UDim2.fromScale(0.5, 0.54)
	resumeButton.Size = UDim2.fromOffset(280, 72)
	resumeButton.BackgroundColor3 = Color3.fromRGB(76, 181, 128)
	resumeButton.BorderSizePixel = 0
	resumeButton.Font = Enum.Font.FredokaOne
	resumeButton.Text = "RESUME"
	resumeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	resumeButton.TextScaled = true
	resumeButton.ZIndex = 41
	resumeButton.Parent = pausedPanel
	round(resumeButton, 22)
	outline(resumeButton, Color3.fromRGB(44, 117, 87), 4)
	local pausedStatus = makeLabel(pausedPanel, "Status", UDim2.fromScale(0.6, 0.05), UDim2.fromScale(0.5, 0.65))
	pausedStatus.TextScaled = true
	pausedStatus.Text = ""
	pausedStatus.ZIndex = 41

	-- ── a finished solo run waits here until the player asks for the next one ────────────────
	local runOverPanel = Instance.new("Frame")
	runOverPanel.Name = "RunOver"
	runOverPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	runOverPanel.Position = UDim2.fromScale(0.5, 0.52)
	runOverPanel.Size = UDim2.fromOffset(400, 320)
	runOverPanel.BackgroundColor3 = Color3.fromRGB(255, 244, 211)
	runOverPanel.BorderSizePixel = 0
	runOverPanel.Visible = false
	runOverPanel.Active = true
	runOverPanel.ZIndex = 30
	runOverPanel.Parent = gui
	round(runOverPanel, 32)
	outline(runOverPanel, Color3.fromRGB(79, 56, 75), 5)
	local runOverTitle = makeLabel(runOverPanel, "Title", UDim2.fromScale(0.86, 0.15), UDim2.fromScale(0.5, 0.14))
	runOverTitle.Text = "RUN OVER"
	runOverTitle.TextColor3 = Color3.fromRGB(63, 48, 72)
	runOverTitle.TextStrokeTransparency = 1
	runOverTitle.TextScaled = true
	runOverTitle.ZIndex = 31
	local runOverScore = makeLabel(runOverPanel, "Score", UDim2.fromScale(0.8, 0.26), UDim2.fromScale(0.5, 0.37))
	runOverScore.TextScaled = true
	runOverScore.TextColor3 = Color3.fromRGB(255, 111, 104)
	runOverScore.TextStrokeColor3 = Color3.fromRGB(79, 56, 75)
	runOverScore.Text = "0"
	runOverScore.ZIndex = 31
	local runOverDetail = makeLabel(runOverPanel, "Detail", UDim2.fromScale(0.86, 0.09), UDim2.fromScale(0.5, 0.57))
	runOverDetail.Font = Enum.Font.GothamBold
	runOverDetail.TextScaled = true
	runOverDetail.TextColor3 = Color3.fromRGB(122, 98, 114)
	runOverDetail.TextStrokeTransparency = 1
	runOverDetail.Text = ""
	runOverDetail.ZIndex = 31
	local runOverButton = Instance.new("TextButton")
	runOverButton.Name = "PlayAgain"
	runOverButton.AnchorPoint = Vector2.new(0.5, 0.5)
	runOverButton.Position = UDim2.fromScale(0.5, 0.8)
	runOverButton.Size = UDim2.fromScale(0.78, 0.2)
	runOverButton.BackgroundColor3 = Color3.fromRGB(76, 181, 128)
	runOverButton.BorderSizePixel = 0
	runOverButton.Font = Enum.Font.FredokaOne
	runOverButton.Text = "PLAY AGAIN"
	runOverButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	runOverButton.TextScaled = true
	runOverButton.ZIndex = 31
	runOverButton.Parent = runOverPanel
	round(runOverButton, 22)
	outline(runOverButton, Color3.fromRGB(44, 117, 87), 3)

	-- Bottom left and quiet: a high ping is named so a late jump reads as the connection, not the game.
	local pingLabel = makeLabel(gui, "Ping", UDim2.fromOffset(330, 24), UDim2.new(0, 14, 1, -14))
	pingLabel.AnchorPoint = Vector2.new(0, 1)
	pingLabel.TextXAlignment = Enum.TextXAlignment.Left
	pingLabel.TextScaled = true
	pingLabel.Text = ""
	pingLabel.Visible = false

	local ropeFolder = Instance.new("Folder")
	ropeFolder.Name = "SkipsLocalRopes"
	ropeFolder.Parent = workspace
	local sceneryFolder = Instance.new("Folder")
	sceneryFolder.Name = "SkipsLocalScenery"
	sceneryFolder.Parent = workspace

	local colorEffect = Instance.new("ColorCorrectionEffect")
	colorEffect.Name = "SkipsColor"
	colorEffect.Brightness = 0.04
	colorEffect.Contrast = 0.08
	colorEffect.Saturation = 0.18
	colorEffect.TintColor = Color3.fromRGB(255, 247, 232)
	colorEffect.Parent = Lighting
	local bloomEffect = Instance.new("BloomEffect")
	bloomEffect.Name = "SkipsBloom"
	bloomEffect.Intensity = 0.35
	bloomEffect.Size = 24
	bloomEffect.Threshold = 1.25
	bloomEffect.Parent = Lighting
	local blurEffect = Instance.new("BlurEffect")
	blurEffect.Name = "SkipsBlur"
	blurEffect.Size = 0
	blurEffect.Parent = Lighting

	local self = setmetatable({
		gui = gui,
		scoreLabel = score,
		luckyLabel = luckyLabel,
		luckyToken = 0,
		flashOriginalTransparency = {},
		flashVisible = false,
		statusLabel = status,
		fuelPanel = fuelPanel,
		fuelFill = fuelFill,
		fuelStroke = fuelStroke,
		fuelWasActive = nil,
		hintPanel = hintPanel,
		upgradeTrack = upgradeTrack,
		upgradeFill = upgradeFill,
		upgradeLevel = upgradeLevel,
		pointsMultiplier = pointsMultiplier,
		offerPanel = offerPanel,
		offerTimer = offerTimer,
		offerCards = {},
		offerIndex = 1,
		offerPointerIndex = nil,
		onOfferChosen = function(_index: number) end,
		revivePanel = revivePanel,
		reviveButton = reviveButton,
		reviveTimer = reviveTimer,
		reviveStatus = reviveStatus,
		reviveCost = 1,
		onReviveChosen = function() end,
		onReviveDeclined = function() end,
		ropeFolder = ropeFolder,
		ropeView = RopeView.new(ropeFolder, "Local"),
		sceneryFolder = sceneryFolder,
		sceneryBuilt = false,
		armsPosed = false,
		humanoid = nil,
		jumpTrack = nil,
		wasAirborne = false,
		root = nil,
		baseRoot = CFrame.new(),
		groundPosition = Vector3.zero,
		colorEffect = colorEffect,
		bloomEffect = bloomEffect,
		blurEffect = blurEffect,
		reviveSecondary = newRunButton,
		onReviveClosed = function() end,
		pauseButton = pauseButton,
		pausedPanel = pausedPanel,
		pausedStatus = pausedStatus,
		resumeButton = resumeButton,
		onPause = function() end,
		onResume = function() end,
		runOverPanel = runOverPanel,
		runOverScore = runOverScore,
		runOverDetail = runOverDetail,
		onPlayAgain = function() end,
		pingLabel = pingLabel,
		tripStartedAt = nil,
		hintEnabled = true,
		lowGraphics = false,
		sceneryExtras = {},
		shadowsWere = Lighting.GlobalShadows,
		framing = nil,
		spectating = false,
	}, RunPresenter) :: any
	for index = 1, 3 do
		self.offerCards[index] = createOfferCard(self, index)
	end
	reviveButton.Activated:Connect(function()
		if self.revivePanel.Visible then self.onReviveChosen() end
	end)
	newRunButton.Activated:Connect(function()
		if self.revivePanel.Visible then self.onReviveDeclined() end
	end)
	reviveClose.Activated:Connect(function()
		if self.revivePanel.Visible then self.onReviveClosed() end
	end)
	pauseButton.Activated:Connect(function()
		if self.pauseButton.Visible then self.onPause() end
	end)
	resumeButton.Activated:Connect(function()
		if self.pausedPanel.Visible then self.onResume() end
	end)
	runOverButton.Activated:Connect(function()
		if self.runOverPanel.Visible then self.onPlayAgain() end
	end)
	return self
end

--[[
	Scenery layout.

	FIXED TABLES, NEVER RANDOM. Presentation must not consume the run's RNG stream (§6.3), and a
	backdrop that reshuffles every run reads as noise rather than variety.

	The distances are chosen against the actual camera, not by eye: it sits 15.5 studs behind the
	player at FOV 46, so the visible slice is only ~47 studs wide at 40 studs out and ~77 at 90.
	Trees from this pack are 18-33 studs tall — placed any nearer than the mid-forties they stop
	being a backdrop and start being an obstruction in front of the rope.

	`z` is negative because the camera looks down -Z from behind the player: scenery belongs behind
	them, never between them and the lens.
]]
--[[
	The camera sits off to one side, and this is why.

	Measured over 2.5 s of swinging: the rope actually intersects the body on 6% of frames (a graze
	at the ankles during the ground sweep, which is what a skipping rope does), but it is DRAWN ON
	TOP OF THE TORSO on 43%. From a dead-front camera the rope's swing plane is edge-on, so its
	rotation is invisible and all you see is a bar crossing the character. The reference game reads
	because it is side-on — the rope circles a character in profile.

	32° is the compromise: enough that the swing reads as a circle going round the player, little
	enough that you still see your own avatar's face, which is the entire point of §5.1.

	THE SCENERY MUST ROTATE WITH IT. The layout below was composed for a camera looking down -Z,
	with a centre gap kept clear behind the player's head. Turn the camera and that gap swings off
	to one side, putting a tree squarely behind the score again — the exact thing that layout was
	measured to prevent. So the same yaw is applied to every scenery placement, which keeps each
	piece in the same position *relative to the camera* and makes the composition survive any
	future change to this angle.
]]
local CAMERA_YAW_DEGREES = 24
--[[
	DISTANCE HAS A FLOOR, and I first computed it against the wrong thing.

	FieldOfView is vertical, so the visible half-height at the subject is `distance * tan(23°)` =
	0.4245 * distance. My first attempt sized that against the rope's swing top (5.88) and landed
	on 10.5 — which cut the player's head off, because **the binding constraint is the player at
	the apex of a jump, not the rope**: a full hold reaches ~3.9 studs, plus a 5.4-stud body, so
	the frame has to reach 9.3.

	Against a fixed focus at 2.59 that would need 15.8 studs — further away than we started. The
	way to get closer is to stop framing the ground and start framing the *action*: the focus sits
	higher and rises with the player, so the frame follows the jump instead of trying to contain
	it from below.

	Half-follow rather than full: at 1.0 the player would be pinned to the centre of the screen and
	the jump would read as the world falling away, which destroys the sense of height that the
	upgrades exist to sell.
]]
local CAMERA_DISTANCE = 13
--[[
	NEGATIVE LIFT: the camera sits BELOW the focus and looks slightly up.

	Above and looking down flattens a jump — the ground fills the frame and rising toward the lens
	reads as getting smaller. From underneath, height is sold instead of measured: the character
	climbs against sky, and the tree line drops away as they go. That is the whole fantasy the
	jump-height upgrades are selling, so the camera should be on its side.
]]
local CAMERA_LIFT = -1.2
local CAMERA_FOCUS_BASE = 0.85 -- × body height: sits at chest/head height, not at the feet
local CAMERA_FOCUS_FOLLOW = 0.5 -- how much of the player's rise the focus takes up
--[[
	Past this height the focus follows the player fully instead of by half.

	Half-follow sells an ordinary jump, but the frame only reaches about 5.5 studs above the focus,
	so above ~8 studs the head used to leave the top of the screen -- the user's "when we jump higher,
	our camera isn't following us". From here up the head stays a steady distance below the top, and
	the camera eases back a little to keep some of the rope and ground in view.
]]
local CAMERA_FULL_FOLLOW_ABOVE = 7
local CAMERA_PULLBACK_PER_STUD = 0.2
local CAMERA_PULLBACK_MAX = 5
-- Room either side of the outermost lanes on screen, so a rope at the edge is never cut off.
local STAGE_MARGIN = 9

-- A lost run tips the avatar over backwards about its feet, with a little overshoot: a cartoon
-- pratfall to go with the cartoon sound, instead of a character who just stands there.
local TRIP_DEGREES = 78
local TRIP_SECONDS = 0.45

local function easeOutBack(t: number): number
	local c1 = 1.70158
	local c3 = c1 + 1
	return 1 + c3 * (t - 1) ^ 3 + c1 * (t - 1) ^ 2
end

-- Rotate a ground-plane offset about the origin by the camera's yaw, so scenery composed for the
-- old head-on view lands in the same place on screen.
local function rotateByCameraYaw(x: number, z: number): (number, number)
	local theta = math.rad(CAMERA_YAW_DEGREES)
	local c, s = math.cos(theta), math.sin(theta)
	return x * c + z * s, -x * s + z * c
end

--[[
	One dial for how far apart the park sits, applied to every placement's X.

	Kept as a multiplier rather than baked into the tables so the composition stays intact when it
	changes: the centre gap that keeps trees off the player and the score is expressed in the same
	coordinates, so it widens by the same factor and cannot accidentally close up.
]]
local SCENERY_SPREAD = 1.45

type SceneryPlacement = { x: number, z: number, yaw: number, scale: number }

--[[
	Distances and scales are solved against the camera, not guessed.

	Roblox's FieldOfView is VERTICAL, so at FOV 46 the visible half-height at distance d is
	d * tan(23°) ≈ 0.4245 d, measured from the camera's eye at y ≈ 5.8. The first pass put the near
	band at z = -46 (d = 61.5, top of frame ≈ y 32) and scaled the tallest tree to its full 33.5
	studs — so the canopies were sliced off by the top edge. Each band now clears its own frame
	height with a margin.

	near  z ≈ -56  ->  d 71.5,  frame top ≈ y 36,  tallest placed ≈ 28
	mid   z ≈ -74  ->  d 89.5,  frame top ≈ y 44,  tallest placed ≈ 33
	far   z ≈ -92  ->  d 107.5, frame top ≈ y 51,  tallest placed ≈ 40
]]
--[[
	THE CENTRE IS DELIBERATELY EMPTY.

	Measured through the real camera, the first layout put five trees and two rocks inside the
	middle third of the screen above the halfway line — directly behind the player's head and the
	score readout. In a game read entirely from one silhouette against one rope, that is not
	decoration, it is camouflage over the only two things the player needs to see.

	So no tree is placed within |x| < 16 in the near band, |x| < 19 in the mid, or |x| < 22 in the
	far. The gap widens with distance because the frustum does. What fills the middle instead is
	sky and open lawn, which is exactly the contrast a dark avatar and a white score want behind
	them.
]]
local TREE_LAYOUT: { SceneryPlacement } = {
	-- near band: the readable silhouettes, framing the edges
	{ x = -29, z = -55, yaw = 0.35, scale = 0.84 },
	{ x = -17, z = -59, yaw = 2.10, scale = 0.76 },
	{ x = 16, z = -58, yaw = 1.15, scale = 0.80 },
	{ x = 28, z = -54, yaw = 3.30, scale = 0.86 },
	-- mid band
	{ x = -45, z = -72, yaw = 5.05, scale = 1.00 },
	{ x = -33, z = -77, yaw = 0.80, scale = 0.92 },
	{ x = -19, z = -73, yaw = 2.60, scale = 0.88 },
	{ x = 20, z = -75, yaw = 4.60, scale = 0.90 },
	{ x = 34, z = -71, yaw = 1.90, scale = 1.02 },
	{ x = 48, z = -76, yaw = 3.75, scale = 0.96 },
	-- far band: fills the horizon, deliberately the largest so the park has depth
	{ x = -57, z = -90, yaw = 2.25, scale = 1.15 },
	{ x = -39, z = -96, yaw = 0.15, scale = 1.08 },
	{ x = 24, z = -97, yaw = 5.40, scale = 1.12 },
	{ x = 41, z = -91, yaw = 3.05, scale = 1.04 },
	{ x = 56, z = -88, yaw = 1.45, scale = 1.00 },
	--[[
		Outer and horizon bands, added when the camera came closer.

		The frame is roughly 94 studs wide at the old far band and ~140 at the horizon, while the
		trees only spanned ±57 — so the edges of the shot ran out into bare lawn, which is what
		read as "plain". These fill the sides and give the skyline something to sit against. They
		are also the cheapest depth cue available: the same templates at the same scale, further
		away, read as distance rather than as more clutter.

		The centre gap keeps widening with distance for the same reason it exists at all — the
		frustum widens, so a fixed gap would close up behind the player.
	]]
	{ x = -88, z = -108, yaw = 1.05, scale = 1.20 },
	{ x = -66, z = -114, yaw = 4.35, scale = 1.16 },
	{ x = -44, z = -106, yaw = 2.55, scale = 1.10 },
	{ x = 32, z = -110, yaw = 0.65, scale = 1.14 },
	{ x = 54, z = -104, yaw = 3.85, scale = 1.08 },
	{ x = 78, z = -112, yaw = 5.15, scale = 1.22 },
	{ x = -118, z = -140, yaw = 2.85, scale = 1.30 },
	{ x = -86, z = -148, yaw = 0.45, scale = 1.26 },
	{ x = -52, z = -136, yaw = 3.55, scale = 1.18 },
	{ x = 44, z = -142, yaw = 1.75, scale = 1.24 },
	{ x = 82, z = -134, yaw = 4.95, scale = 1.28 },
	{ x = 116, z = -146, yaw = 2.15, scale = 1.32 },
}

-- A small neighborhood behind the tree line. It breaks the empty horizon into colorful shapes
-- while preserving the clean central silhouette needed to read the player and rope.
local BUILDING_LAYOUT: { SceneryPlacement } = {
	{ x = -42, z = -86, yaw = 0.10, scale = 0.92 },
	{ x = -24, z = -94, yaw = -0.08, scale = 0.82 },
	{ x = 25, z = -92, yaw = 0.12, scale = 0.86 },
	{ x = 44, z = -84, yaw = -0.12, scale = 0.94 },
	{ x = -78, z = -118, yaw = 0.18, scale = 1.06 },
	{ x = -53, z = -126, yaw = -0.06, scale = 0.98 },
	{ x = 55, z = -124, yaw = 0.08, scale = 1.02 },
	{ x = 82, z = -116, yaw = -0.16, scale = 1.08 },
}

-- Tall far-background shapes fill the specific sky gap visible behind the avatar. Their bases sit
-- behind the neighborhood and trees; the distance keeps them readable as skyline, not obstacles.
local SKYLINE_LAYOUT: { SceneryPlacement } = {
	{ x = -48, z = -154, yaw = 0.04, scale = 1.04 },
	{ x = -29, z = -162, yaw = -0.05, scale = 0.88 },
	{ x = -13, z = -170, yaw = 0.06, scale = 1.12 },
	{ x = 10, z = -174, yaw = -0.03, scale = 1.18 },
	{ x = 27, z = -164, yaw = 0.05, scale = 0.92 },
	{ x = 47, z = -156, yaw = -0.04, scale = 1.08 },
}

local PROP_LAYOUT: { SceneryPlacement } = {
	{ x = -15, z = -12, yaw = 2.90, scale = 0.85 },
	{ x = 16, z = -13, yaw = 0.90, scale = 0.90 },
	{ x = -12, z = -16, yaw = 0.40, scale = 1.00 },
	{ x = 11, z = -18, yaw = 2.20, scale = 1.10 },
	{ x = -19, z = -24, yaw = 4.00, scale = 0.90 },
	{ x = 20, z = -26, yaw = 1.30, scale = 1.15 },
	-- these two were measured sitting on the horizon line directly behind the player; moved out
	{ x = -14, z = -28, yaw = 5.20, scale = 1.00 },
	{ x = 13, z = -31, yaw = 3.10, scale = 0.95 },
	{ x = -26, z = -36, yaw = 1.70, scale = 1.20 },
	{ x = 27, z = -38, yaw = 4.80, scale = 1.05 },
	-- these two bridge the gap left when the tree line moved back, so the middle distance is not
	-- an empty stretch of lawn
	{ x = -16, z = -45, yaw = 0.60, scale = 1.25 },
	{ x = 18, z = -47, yaw = 3.90, scale = 1.30 },
	-- and these scatter out to the sides, where the closer camera exposed bare ground
	{ x = -34, z = -30, yaw = 2.40, scale = 1.10 },
	{ x = 33, z = -33, yaw = 5.60, scale = 1.15 },
	{ x = -42, z = -52, yaw = 1.05, scale = 1.35 },
	{ x = 45, z = -56, yaw = 3.45, scale = 1.40 },
	{ x = -24, z = -62, yaw = 4.25, scale = 1.20 },
	{ x = 26, z = -66, yaw = 0.85, scale = 1.28 },
}

local function buildGround(self: RunPresenter)
	local ground = self.groundPosition
	--[[
		The lawn must out-reach AND out-rank the default Baseplate.

		That baseplate is 2048x2048 with its top at exactly y = 0, while the lawn's top sat at
		y = -0.035 across only 500 studs. So beyond the lawn's edge — which is well inside the
		camera's view of the horizon — the player saw a grey band across the sky line, and the
		baseplate also won every pixel where the two overlapped. Wider, and 0.055 studs higher,
		fixes both. It is decoration only: the baseplate still does the colliding.
	]]
	local lawn = makeWorldPart(self.sceneryFolder, "Lawn", Color3.fromRGB(103, 193, 116))
	lawn.Size = Vector3.new(2400, 0.65, 2400)
	lawn.CFrame = CFrame.new(ground + Vector3.new(0, -0.305, -8))
	lawn.CastShadow = true
	local path = makeWorldPart(self.sceneryFolder, "Path", Color3.fromRGB(245, 209, 151))
	path.Size = Vector3.new(7, 0.1, 120)
	path.CFrame = CFrame.new(ground + Vector3.new(0, -0.01, -8))
	path.CastShadow = true
end

--[[
	Clones one authored mesh into the local scenery folder.

	Templates are cycled rather than indexed one-to-one, so the layout tables above stay valid
	whatever the pack contains — adding or removing a tree changes the mix, never breaks the build.
]]
local function placeTemplate(
	self: RunPresenter,
	templates: { MeshPart },
	index: number,
	name: string,
	place: SceneryPlacement,
	-- Far or decorative pieces that low graphics puts away.
	extra: boolean?
)
	local template = templates[((index - 1) % #templates) + 1]
	local copy = template:Clone()
	copy.Name = name
	copy.Size = template.Size * place.scale
	copy.Anchored = true
	copy.CanCollide = false
	copy.CanQuery = false
	copy.CanTouch = false
	local x, z = rotateByCameraYaw(place.x * SCENERY_SPREAD, place.z)
	copy.CFrame = CFrame.new(self.groundPosition + Vector3.new(x, copy.Size.Y * 0.5, z))
		* CFrame.Angles(0, place.yaw + math.rad(CAMERA_YAW_DEGREES), 0)
	copy.Parent = if extra and self.lowGraphics then nil else self.sceneryFolder
	if extra then
		table.insert(self.sceneryExtras, copy)
	end
end

--[[
	The primitive park, kept as a fallback and nothing more.

	THE PLACE FILE IS NOT IN GIT. A fresh checkout of this repo has every line of code and none of
	the models, so the asset folder can legitimately be absent. §6.4 says deleting the presentation
	layer must leave the run mechanically identical — a missing tree is therefore not allowed to be
	fatal, and erroring here would make the game unplayable over decoration.
]]
local function buildPrimitiveScenery(self: RunPresenter)
	local ground = self.groundPosition
	for treeIndex, position in {
		Vector3.new(-10, 0, -7), Vector3.new(10, 0, -8), Vector3.new(-14, 0, -14), Vector3.new(14, 0, -15),
	} do
		local trunk = makeWorldPart(self.sceneryFolder, "TreeTrunk" .. treeIndex, Color3.fromRGB(139, 87, 58))
		trunk.Shape = Enum.PartType.Cylinder
		trunk.Size = Vector3.new(4.5, 0.9, 0.9)
		trunk.CFrame = CFrame.new(ground + position + Vector3.new(0, 2.15, 0)) * CFrame.Angles(0, 0, math.pi * 0.5)
		trunk.CastShadow = true
		for crownIndex, crownOffset in {
			Vector3.new(0, 4.8, 0), Vector3.new(-1.1, 4.45, 0.2), Vector3.new(1.1, 4.5, -0.1),
		} do
			local crownColor = if treeIndex % 2 == 0 then Color3.fromRGB(64, 162, 105) else Color3.fromRGB(74, 177, 111)
			local crown = makeWorldPart(self.sceneryFolder, "TreeCrown" .. treeIndex .. "_" .. crownIndex, crownColor)
			crown.Shape = Enum.PartType.Ball
			crown.Size = Vector3.new(3.3, 3.3, 3.3)
			crown.CFrame = CFrame.new(ground + position + crownOffset)
			crown.CastShadow = true
		end
	end
end

--[[
	Scenery is cloned from `ReplicatedStorage.Assets.Scenery` — authored place content installed
	from the Creator Store, with its provenance recorded as attributes on that folder (§8).

	It is deliberately NOT under `ReplicatedStorage.Shared`: that folder belongs to Rojo and is
	overwritten on every sync, so a model placed there would vanish the next time source changed.
]]
local function buildScenery(self: RunPresenter)
	if self.sceneryBuilt then return end
	self.sceneryBuilt = true

	buildGround(self)

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local scenery = assets and assets:FindFirstChild("Scenery")
	local treeFolder = scenery and scenery:FindFirstChild("Trees")
	local propFolder = scenery and scenery:FindFirstChild("Props")
	local buildingFolder = scenery and scenery:FindFirstChild("Buildings")
	local skylineFolder = scenery and scenery:FindFirstChild("Skylines")

	local trees: { MeshPart } = {}
	local props: { MeshPart } = {}
	local buildings: { MeshPart } = {}
	local skylines: { MeshPart } = {}
	if treeFolder then
		for _, child in treeFolder:GetChildren() do
			if child:IsA("MeshPart") then table.insert(trees, child) end
		end
	end
	if propFolder then
		for _, child in propFolder:GetChildren() do
			if child:IsA("MeshPart") then table.insert(props, child) end
		end
	end
	if buildingFolder then
		for _, child in buildingFolder:GetChildren() do
			if child:IsA("MeshPart") then table.insert(buildings, child) end
		end
	end
	if skylineFolder then
		for _, child in skylineFolder:GetChildren() do
			if child:IsA("MeshPart") then table.insert(skylines, child) end
		end
	end

	if #trees == 0 then
		warn("[Skips] ReplicatedStorage.Assets.Scenery.Trees is empty or missing; "
			.. "falling back to primitive scenery. The place file carries the models and is not in git.")
		buildPrimitiveScenery(self)
		return
	end

	for index, place in TREE_LAYOUT do
		placeTemplate(self, trees, index, string.format("Tree%02d", index), place, index > 15)
	end
	if #buildings > 0 then
		for index, place in BUILDING_LAYOUT do
			placeTemplate(self, buildings, index, string.format("Building%02d", index), place, true)
		end
	end
	if #skylines > 0 then
		for index, place in SKYLINE_LAYOUT do
			placeTemplate(self, skylines, index, string.format("Skyline%02d", index), place, true)
		end
	end
	if #props > 0 then
		for index, place in PROP_LAYOUT do
			placeTemplate(self, props, index, string.format("Prop%02d", index), place, index > 12)
		end
	end
end

function RunPresenter.setOfferChosenCallback(self: RunPresenter, callback: (number) -> ())
	self.onOfferChosen = callback
end

function RunPresenter.setReviveCallbacks(
	self: RunPresenter,
	onChosen: () -> (),
	onDeclined: () -> (),
	onClosed: (() -> ())?
)
	self.onReviveChosen = onChosen
	self.onReviveDeclined = onDeclined
	self.onReviveClosed = onClosed or onDeclined
end

--[[
	Angle the arms out so the hands read as holding the handles.

	WHY A STATIC OFFSET AND NOT A PER-FRAME ONE. An animation drives the joint every frame, and the
	animator runs after Heartbeat — where this presenter's render loop lives — so anything written
	to the joint's live transform here would be overwritten before it was ever drawn. Both rig
	systems expose a separate *rest* offset that the animation composes on top of. Setting that
	once tilts the arms permanently while the idle still breathes over it: one assignment instead
	of a second frame hook, and it cannot fight the animator because it is not playing the same
	game.

	TWO RIG SYSTEMS, AND THIS PLACE USES THE NEWER ONE. Measured on the live character: there are
	**zero Motor6Ds**, and `LeftShoulder` is an `AnimationConstraint` whose offset lives on
	`Attachment0` (the attachment on `UpperTorso`), not on a `C0`. The first version of this
	function guarded on `IsA("Motor6D")`, so it silently posed nothing — which is why it is written
	to report success rather than assume it, and why `render` retries until it actually lands.
	Motor6D is still handled, because the rig depends on place settings that can change.

	Idempotent on purpose: `beginRun` runs again on every restart, and composing a rotation onto
	the live offset each time would wind the arms further out on every death until the avatar was
	doing a star jump. The baseline is stashed the first time and read back after.
]]
--[[
	NEGATIVE: the arms are pulled IN toward the body, not spread out.

	Measured with the published jump clip playing: the clip itself adds **1.05 studs of outward
	hand spread** on top of whatever rest pose it is applied over. At the old +24 the hands sat
	1.90 out while idle and reached **2.93** mid-jump — against a rope whose end region is at
	3.05. That is the contact the player was seeing.

	The rig sets a hard floor here: hands hang about 1.62 out with no offset at all, so no amount
	of tucking gets them near the torso's 0.98 half-width. A negative offset buys back what it
	can — but only so far. **-26 measured no better than -12** (idle 1.38 vs 1.37, jump 2.62 vs
	2.64), so the shoulder rotation is spent as a lever and winding it further is wasted motion.
	What did still help was `ROPE_DEPTH`, swinging the rope further clear of them: 0.82 -> 1.05
	took arm contact from 10% of frames to 4%. Beyond that the only lever left is the clip
	itself, which would have to be re-authored — not a number in this file.
]]
local ARM_OUT_DEGREES = -12
local ARM_FORWARD_DEGREES = 7
local STOCK_JUMP_ANIMATION_ID = "rbxassetid://507765000"

--[[
	Applies a rest-offset rotation to one named joint, handling both rig systems.

	The baseline is stashed the first time and every write is `baseline * offset`, never
	`current * offset`, so calling this every frame is safe — it sets an absolute pose rather than
	compounding one. That matters because the airborne pose below is driven per tick.
]]
local function setJointOffset(character: Model, limbName: string, jointName: string, offset: CFrame): boolean
	local limb = character:FindFirstChild(limbName)
	local joint = limb and limb:FindFirstChild(jointName)
	if not joint then
		return false
	end

	local function apply(host: Instance, current: CFrame, write: (CFrame) -> ()): boolean
		local baseline = host:GetAttribute("RopeBaseOffset")
		if typeof(baseline) ~= "CFrame" then
			baseline = current
			host:SetAttribute("RopeBaseOffset", baseline)
		end
		write((baseline :: CFrame) * offset)
		return true
	end

	if joint:IsA("AnimationConstraint") then
		local attachment = joint.Attachment0
		if attachment then
			return apply(attachment, attachment.CFrame, function(value)
				attachment.CFrame = value
			end)
		end
	elseif joint:IsA("Motor6D") then
		return apply(joint, joint.C0, function(value)
			joint.C0 = value
		end)
	end
	return false
end

local function poseArmsForRope(character: Model): boolean
	local posed = 0
	for _, spec in {
		{ limb = "LeftUpperArm", joint = "LeftShoulder", side = -1 },
		{ limb = "RightUpperArm", joint = "RightShoulder", side = 1 },
	} do
		local offset = CFrame.Angles(
			math.rad(ARM_FORWARD_DEGREES),
			0,
			math.rad(ARM_OUT_DEGREES) * spec.side
		)
		if setJointOffset(character, spec.limb, spec.joint, offset) then
			posed += 1
		end
	end
	return posed == 2
end

local function restoreCharacterOpacity(self: RunPresenter)
	for part, transparency in self.flashOriginalTransparency do
		if part.Parent then
			part.LocalTransparencyModifier = transparency
		end
	end
	table.clear(self.flashOriginalTransparency)
	self.flashVisible = false
end

local function updateInvulnerabilityFlash(self: RunPresenter, run: Run)
	local visible = run.invulnerableTicks > 0 and (run.tick // 4) % 2 == 0
	if visible == self.flashVisible then return end
	if not visible then
		restoreCharacterOpacity(self)
		return
	end
	local root = self.root
	local character = root and root.Parent
	if not character or not character:IsA("Model") then return end
	for _, instance in character:GetDescendants() do
		if instance:IsA("BasePart") then
			self.flashOriginalTransparency[instance] = instance.LocalTransparencyModifier
			instance.LocalTransparencyModifier = math.max(instance.LocalTransparencyModifier, 0.58)
		end
	end
	self.flashVisible = true
end

function RunPresenter.beginRun(self: RunPresenter, baseRoot: CFrame, groundPosition: Vector3)
	restoreCharacterOpacity(self)
	self.baseRoot = baseRoot
	self.groundPosition = groundPosition
	self.statusLabel.Text = "GET READY!"
	self.scoreLabel.Text = "0"
	self.luckyToken += 1
	self.luckyLabel.TextTransparency = 1
	self.luckyLabel.TextStrokeTransparency = 1
	self.fuelPanel.Visible = false
	self.fuelWasActive = nil
	self.upgradeFill.Size = UDim2.fromScale(1, 0)
	self.upgradeLevel.Text = "1"
	self.pointsMultiplier.Visible = false
	self.offerPanel.Visible = false
	self.revivePanel.Visible = false
	self.runOverPanel.Visible = false
	self.pausedPanel.Visible = false
	self.tripStartedAt = nil
	self:setSpectating(false)
	self.blurEffect.Size = 0
	self.hintPanel.Visible = self.hintEnabled
	-- The default place spawn is useful for authoring but its gray star pad cuts through the park.
	-- Hide it only for this client; Studio still owns and saves the actual spawn geometry.
	local spawn = workspace:FindFirstChildWhichIsA("SpawnLocation")
	if spawn then
		spawn.LocalTransparencyModifier = 1
		for _, decoration in spawn:GetDescendants() do
			if decoration:IsA("Decal") or decoration:IsA("Texture") then decoration.Transparency = 1 end
		end
	end
	buildScenery(self)
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	self.root = if root and root:IsA("BasePart") then root else nil
	-- Measured failing on the first attempt: at beginRun the character's limbs are not reliably
	-- present yet, so this succeeded zero times out of two. `render` retries until it lands.
	self.armsPosed = if character then poseArmsForRope(character) else false

	--[[
		Humanoid state has to be pinned down HERE, on the client, as well as in AvatarNormalizer.

		`SetStateEnabled` is per-peer: the server disabling Jumping and Freefall does not bind on
		the client that owns the character, so those states could still be entered locally.
	]]
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	self.humanoid = humanoid
	if humanoid then
		-- Use Roblox's familiar hands-up jump/fall presentation. The deterministic simulation still
		-- owns the arc; these states only animate the puppet and are driven from that state below.
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)

		-- An anchored, CFrame-driven character does not reliably keep a Humanoid air state long
		-- enough for Animate to start its clip. Play Roblox's standard R15 jump ourselves so the
		-- requested familiar hands-in-the-air silhouette is guaranteed, while the sim still owns
		-- every stud of motion and every hit.
		if self.jumpTrack then
			self.jumpTrack:Stop(0)
			self.jumpTrack:Destroy()
			self.jumpTrack = nil
		end
		self.wasAirborne = false
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			local animation = Instance.new("Animation")
			animation.AnimationId = STOCK_JUMP_ANIMATION_ID
			local ok, track = pcall(function()
				return animator:LoadAnimation(animation)
			end)
			animation:Destroy()
			if ok and track then
				track.Priority = Enum.AnimationPriority.Action4
				track.Looped = false
				self.jumpTrack = track
			else
				warn("[Skips] standard jump animation failed to load: " .. tostring(track))
			end
		end
	end
end

function RunPresenter.setStarted(self: RunPresenter)
	self.statusLabel.Text = ""
	self.hintPanel.Visible = self.hintEnabled
end

function RunPresenter.showLucky(self: RunPresenter, points: number)
	self.luckyToken += 1
	local token = self.luckyToken
	local label = self.luckyLabel
	label.Text = string.format("LUCKY!  +%d", points)
	label.Size = UDim2.fromOffset(250, 38)
	label.TextTransparency = 0
	label.TextStrokeTransparency = 0.05
	TweenService:Create(
		label,
		TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = UDim2.fromOffset(330, 54) }
	):Play()
	task.delay(0.65, function()
		if self.luckyToken ~= token or not label.Parent then return end
		TweenService:Create(
			label,
			TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ TextTransparency = 1, TextStrokeTransparency = 1 }
		):Play()
	end)
end

function RunPresenter.setGetReadyCountdown(self: RunPresenter, seconds: number)
	-- The player taps to go; this number is only how long until the game goes without them,
	-- so the prompt leads and the count is the quieter half of the message.
	self.statusLabel.Text = string.format("TAP TO GO!\n%d", math.max(1, math.ceil(seconds)))
	self.hintPanel.Visible = false
end

function RunPresenter.setEnded(self: RunPresenter, skips: number)
	self.offerPanel.Visible = false
	self.blurEffect.Size = 0
	self.statusLabel.Text = string.format("OOPS!\n%d SKIPS", skips)
end

function RunPresenter.showRevive(self: RunPresenter, cost: number, balance: number)
	self.offerPanel.Visible = false
	self.hintPanel.Visible = false
	self.statusLabel.Text = ""
	self.reviveCost = cost
	self.reviveButton.Text = string.format("REVIVE  •  %d 🎟", cost)
	self.reviveButton.BackgroundColor3 = Color3.fromRGB(76, 181, 128)
	self.revivePanel.Visible = true
	self:setReviveBalance(balance)
	self.blurEffect.Size = 14
end

function RunPresenter.setReviveBalance(self: RunPresenter, balance: number)
	self.reviveStatus.Text = if balance >= self.reviveCost
		then string.format("YOU HAVE %d 🎟  •  KEEP SCORE + UPGRADES", balance)
		elseif balance > 0 then string.format("YOU HAVE %d 🎟  •  REVIVE TAKES YOU TO THE SHOP", balance)
		else "NO TICKETS YET  •  REVIVE TAKES YOU TO THE SHOP"
end

-- The match ended this run: the per-minute cut took it, or the match was decided while it ran. A run
-- that was already down to the rope keeps saying so.
function RunPresenter.setRetired(self: RunPresenter, reason: string)
	if reason == RunSim.DEATH_REASON.CUT then
		self.statusLabel.Text = "CUT!\nLOWEST SCORE"
	elseif reason == RunSim.DEATH_REASON.MATCH_OVER then
		self.statusLabel.Text = "MATCH OVER!"
	end
	self.offerPanel.Visible = false
	self.blurEffect.Size = 0
end

-- The PRESS • HOLD • RELEASE hint is for first-time players only (PlayerProtocol.TUTORIAL_TICKS).
function RunPresenter.setHintEnabled(self: RunPresenter, enabled: boolean)
	self.hintEnabled = enabled
	if not enabled then
		self.hintPanel.Visible = false
	end
end

--[[
	LOW GRAPHICS (the user, 2026-09-10), for devices that struggle: shadows, bloom and colour grading
	off, the far scenery put away, the fire glow dropped. Presentation only --
	the run is identical either way.
]]
function RunPresenter.setLowGraphics(self: RunPresenter, low: boolean)
	self.lowGraphics = low
	self.bloomEffect.Enabled = not low
	self.colorEffect.Enabled = not low
	Lighting.GlobalShadows = if low then false else self.shadowsWere
	for _, part in self.sceneryExtras do
		part.Parent = if low then nil else self.sceneryFolder
	end
end

function RunPresenter.updateRevive(self: RunPresenter, seconds: number)
	self.reviveTimer.Text = tostring(math.max(0, math.ceil(seconds)))
	local urgent = seconds <= 3
	self.reviveTimer.BackgroundColor3 = if urgent
		then Color3.fromRGB(255, 75, 88)
		else Color3.fromRGB(255, 111, 104)
end

function RunPresenter.setReviveStatus(self: RunPresenter, message: string)
	self.reviveStatus.Text = message
end

function RunPresenter.hideRevive(self: RunPresenter)
	self.revivePanel.Visible = false
	self.blurEffect.Size = 0
end

function RunPresenter.setPauseCallbacks(self: RunPresenter, onPause: () -> (), onResume: () -> ())
	self.onPause = onPause
	self.onResume = onResume
end

function RunPresenter.setPauseVisible(self: RunPresenter, visible: boolean)
	if self.pauseButton.Visible ~= visible then
		self.pauseButton.Visible = visible
	end
end

function RunPresenter.showPaused(self: RunPresenter)
	self.pausedPanel.Visible = true
	self.pausedStatus.Text = ""
	self.resumeButton.Visible = true
	self.hintPanel.Visible = false
	self.blurEffect.Size = 10
end

function RunPresenter.setPausedStatus(self: RunPresenter, text: string)
	self.pausedStatus.Text = text
	self.resumeButton.Visible = false
end

function RunPresenter.hidePaused(self: RunPresenter)
	if self.pausedPanel.Visible then
		self.pausedPanel.Visible = false
		self.blurEffect.Size = 0
	end
end

function RunPresenter.setPlayAgainCallback(self: RunPresenter, callback: () -> ())
	self.onPlayAgain = callback
end

local function withCommas(value: number): string
	local formatted = tostring(math.floor(value))
	while true do
		local replaced, count = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
		formatted = replaced
		if count == 0 then
			break
		end
	end
	return formatted
end

function RunPresenter.showRunOver(self: RunPresenter, score: number, skips: number, best: number)
	self.revivePanel.Visible = false
	self.offerPanel.Visible = false
	self.statusLabel.Text = ""
	self.hintPanel.Visible = false
	self.runOverScore.Text = withCommas(score)
	self.runOverDetail.Text = string.format("%s SKIPS   •   BEST %s", withCommas(skips), withCommas(best))
	self.runOverPanel.Visible = true
	self.blurEffect.Size = 10
end

function RunPresenter.hideRunOver(self: RunPresenter)
	if self.runOverPanel.Visible then
		self.runOverPanel.Visible = false
		self.blurEffect.Size = 0
	end
end

-- Solo offers NEW RUN (skip the revive and start again at once); a match has no next run to start,
-- so the same button declines and the player watches the rest.
function RunPresenter.setReviveMode(self: RunPresenter, inMatch: boolean)
	self.reviveSecondary.Text = if inMatch then "NO THANKS" else "NEW RUN"
end

-- A high ping is named rather than felt as a game that eats jumps.
function RunPresenter.setPing(self: RunPresenter, pingMs: number)
	if pingMs >= RunProtocol.PING_LIMIT_SECONDS * 1000 then
		self.pingLabel.Visible = true
		self.pingLabel.Text = string.format("PING %d ms  •  JUMPS MAY LAND LATE", pingMs)
		self.pingLabel.TextColor3 = Color3.fromRGB(255, 111, 104)
	elseif pingMs >= RunProtocol.PING_WARN_SECONDS * 1000 then
		self.pingLabel.Visible = true
		self.pingLabel.Text = string.format("HIGH PING  %d ms", pingMs)
		self.pingLabel.TextColor3 = Color3.fromRGB(255, 205, 96)
	else
		self.pingLabel.Visible = false
	end
end

-- The direction lanes run across the screen: the camera's right, flattened onto the ground.
function RunPresenter.laneRight(self: RunPresenter): Vector3
	local theta = math.rad(CAMERA_YAW_DEGREES)
	return Vector3.new(math.cos(theta), 0, -math.sin(theta))
end

function RunPresenter.setFraming(self: RunPresenter, framing: Framing?)
	self.framing = framing
end

-- Once you are out of a match you are taken out of the picture, as everyone is who goes out, and the
-- camera watches the run you pick instead (StageView).
function RunPresenter.setSpectating(self: RunPresenter, spectating: boolean)
	if self.spectating == spectating then
		return
	end
	self.spectating = spectating
	local root = self.root
	local character = root and root.Parent
	if character and character:IsA("Model") then
		for _, descendant in character:GetDescendants() do
			if descendant:IsA("BasePart") or descendant:IsA("Decal") then
				(descendant :: any).LocalTransparencyModifier = if spectating then 1 else 0
			end
		end
	end
	if spectating then
		self.ropeView:setCount(0)
	end
end

function RunPresenter.waitingForOffer(self: RunPresenter)
	self.statusLabel.Text = "UPGRADE READY!"
end

function RunPresenter.setOfferIndex(self: RunPresenter, selectedIndex: number)
	self.offerIndex = math.clamp(selectedIndex, 1, 3)
	for index, card in self.offerCards do
		local selected = index == self.offerIndex
		card.scale.Scale = if selected then 1.08 else 0.92
		card.stroke.Thickness = if selected then 6 else 2
		card.stroke.Color = if selected then Color3.fromRGB(255, 255, 255) else Color3.fromRGB(235, 229, 222)
		card.stroke.Transparency = if selected then 0 else 0.32
		card.button.BackgroundTransparency = if selected then 0.02 else 0.18
		card.button.ZIndex = if selected then 18 else 12
		card.icon.ZIndex = card.button.ZIndex + 1
		card.nameLabel.ZIndex = card.button.ZIndex + 1
	end
end

function RunPresenter.showOffer(
	self: RunPresenter,
	cards: { CardCatalog.Card },
	stackCounts: { number },
	luck: number
)
	assert(#cards == 3, "RunPresenter.showOffer needs exactly three cards")
	self.statusLabel.Text = ""
	self.hintPanel.Visible = false
	self.offerPointerIndex = nil
	self.offerPanel:SetAttribute("Luck", luck)
	for index, card in cards do
		local visual = self.offerCards[index]
		local offset, size = iconRect(card.iconIndex)
		visual.button.BackgroundColor3 = THEME_COLORS[card.theme] or THEME_COLORS.BLUE
		visual.button:SetAttribute("CardId", card.id)
		visual.button:SetAttribute("StackCount", stackCounts[index] or 0)
		visual.icon.ImageRectOffset = offset
		visual.icon.ImageRectSize = size
		visual.icon.Visible = true
		visual.nameLabel.Text = card.name
	end
	self.offerPanel.Visible = true
	self.blurEffect.Size = 14
	self:setOfferIndex(1)
end

--[[
	Card selection does NOT cycle, deliberately.

	It used to step the highlight on a timer so a one-button player could reach all three. Removed
	at the user's request: a highlight that moves on its own means the card under your finger is not
	the card you get, and in a game about pressing at the right moment that is exactly the wrong
	thing to teach.

	Selection is now only ever the player's: hover or tap a card to choose it. The consequence is
	honest and worth knowing — a keyboard or gamepad player with no pointer can only take the
	highlighted card, which is card 1. If that matters, the fix is a second input, and §5 makes
	that RED.
]]

function RunPresenter.getOfferIndex(self: RunPresenter): number
	return self.offerIndex
end

--[[
	The seconds left before the game chooses a card for you.

	Fed the remaining time against the SERVER's deadline every frame rather than counting down
	locally. A local timer would drift from the one the server actually acts on, and the moment
	they disagreed the modal would close while the label still read 2.
]]
function RunPresenter.setOfferDeadline(self: RunPresenter, seconds: number?)
	if not seconds then
		self.offerTimer.Text = ""
		return
	end
	local remaining = math.max(0, seconds)
	self.offerTimer.Text = string.format("AUTO-PICK IN %d", math.ceil(remaining))
	-- Warm at leisure, hot in the last two seconds. One colour change carries the urgency
	-- without adding a flashing element on top of three cards the player is trying to read.
	self.offerTimer.TextColor3 = if remaining <= 2
		then Color3.fromRGB(255, 138, 126)
		else Color3.fromRGB(255, 244, 211)
end

function RunPresenter.hideOffer(self: RunPresenter)
	self.offerPanel.Visible = false
	self.blurEffect.Size = 0
	self.hintPanel.Visible = self.hintEnabled
	self.statusLabel.Text = ""
end

-- The ropes themselves are drawn by RopeView, shared with every ghost lane (StageView). The
-- measurements behind the rope's shape moved there with the drawing.

function RunPresenter.render(self: RunPresenter, run: Run, previousY: number, alpha: number)
	local renderAlpha = math.clamp(alpha, 0, 1)
	local y = previousY + (run.y - previousY) * renderAlpha
	local tripAngle = 0
	if run.alive then
		self.tripStartedAt = nil
	else
		local started = self.tripStartedAt
		if not started then
			started = os.clock()
			self.tripStartedAt = started
		end
		tripAngle = TRIP_DEGREES * easeOutBack(math.clamp((os.clock() - (started :: number)) / TRIP_SECONDS, 0, 1))
	end
	if self.root and self.root.Parent then
		local stand = self.baseRoot * CFrame.new(0, y, 0)
		if tripAngle ~= 0 then
			-- Tip over backwards about the feet: the rope caught them, so that is where they pivot.
			local feet = self.baseRoot.Position.Y - self.groundPosition.Y
			stand = stand * CFrame.new(0, -feet, 0) * CFrame.Angles(math.rad(tripAngle), 0, 0)
				* CFrame.new(0, feet, 0)
		end
		self.root.CFrame = stand
		if not self.armsPosed then
			local character = self.root.Parent
			if character:IsA("Model") then
				self.armsPosed = poseArmsForRope(character)
			end
		end
	end

	--[[
		THE SIMULATION OWNS GROUNDEDNESS, so the puppet's animation state is driven from it.

		`AvatarNormalizer` anchors the root and this presenter moves it by CFrame, so the character
		never physically lands on anything: the Humanoid's FloorMaterial reads Air the instant it
		leaves the ground and nothing ever contradicts it. That is why it stuck in the fall
		animation after the first jump and stayed there — Roblox's state machine was guessing at
		physics that is not happening.

		So the state is asserted from the sim every tick — rising, falling or grounded — which
		keeps the jump and fall animations while making a stuck state impossible by construction.
		The grounded branch is the safety: whatever Roblox thinks is happening, the instant the sim
		says the feet are down the Humanoid is put back to Running.

		`vy` is the sim's own vertical velocity, so the switch from jump to fall lands exactly at
		the apex the physics computed rather than wherever the engine guessed the peak was.
	]]
	local humanoid = self.humanoid
	if humanoid and humanoid.Parent then
		local desired: Enum.HumanoidStateType
		if run.grounded then
			desired = Enum.HumanoidStateType.Running
		elseif run.vy > 0 then
			desired = Enum.HumanoidStateType.Jumping
		else
			desired = Enum.HumanoidStateType.Freefall
		end
		if humanoid:GetState() ~= desired then
			humanoid:ChangeState(desired)
		end

		local airborne = not run.grounded
		local track = self.jumpTrack
		if track then
			if airborne and not self.wasAirborne then
				track:Play(0.05)
			elseif not airborne and self.wasAirborne then
				track:Stop(0.08)
			end
		end
		self.wasAirborne = airborne
	end

	self.scoreLabel.Text = tostring(run.score)
	local upgradeProgress = math.clamp(
		run.upgradeProgress / SimTuning.upgradeProgressRequired(run.upgradeRound),
		0,
		1
	)
	self.upgradeFill.Size = UDim2.fromScale(1, upgradeProgress)
	self.upgradeLevel.Text = tostring(run.upgradeRound + 1)
	local pointsBonus = run.stats.scorePerLoop
	self.pointsMultiplier.Visible = pointsBonus > 1
	if pointsBonus > 1 then
		self.pointsMultiplier.Text = string.format("%dX", pointsBonus)
	end

	local fuelCapacity = run.stats.rocketFuelCapacity
	local fuelUnlocked = fuelCapacity > 0
	if self.fuelPanel.Visible ~= fuelUnlocked then
		self.fuelPanel.Visible = fuelUnlocked
	end
	if fuelUnlocked then
		local ratio = math.clamp(run.rocketFuel / fuelCapacity, 0, 1)
		self.fuelFill.Size = UDim2.fromScale(ratio, 1)
		if self.fuelWasActive ~= run.rocketActive then
			self.fuelFill.BackgroundColor3 = if run.rocketActive
				then Color3.fromRGB(255, 124, 57)
				else Color3.fromRGB(164, 112, 236)
			self.fuelStroke.Color = if run.rocketActive
				then Color3.fromRGB(255, 225, 105)
				else Color3.fromRGB(181, 139, 235)
			self.fuelWasActive = run.rocketActive
		end
	end
	updateInvulnerabilityFlash(self, run)
	if self.spectating then
		-- Out of the match: taken out of the picture, rope and all, as everyone is who goes out.
		self.ropeView:setCount(0)
	else
		self.ropeView:setCount(#run.ropes)
		local tickFloat = run.tick + renderAlpha
		-- Ignite and Reinforce each claim one distinct rope. No rope can be lit or guarded twice.
		for index, rope in run.ropes do
			local period = run.stats.ropePeriodTicks
			local remaining = (rope.nextSweepTick - tickFloat) % period
			local angle = math.pi - (remaining / period) * math.pi * 2
			self.ropeView:draw(index, self.groundPosition, angle,
				index <= run.stats.scorePerLoop - 1, rope.guards > 0, y,
				self.lowGraphics)
		end
	end

	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.FieldOfView = 46
		local framing = self.framing
		-- Whose height the camera follows: yours, or -- once you are out -- the run you are watching.
		local subjectY = if framing and framing.focusY then framing.focusY else y
		local follow = subjectY * CAMERA_FOCUS_FOLLOW
			+ math.max(0, subjectY - CAMERA_FULL_FOLLOW_ABOVE) * (1 - CAMERA_FOCUS_FOLLOW)
		local distance = CAMERA_DISTANCE
			+ math.clamp((subjectY - CAMERA_FULL_FOLLOW_ABOVE) * CAMERA_PULLBACK_PER_STUD, 0, CAMERA_PULLBACK_MAX)
		local centreLane = 0
		if framing then
			-- Lane zero belongs to the local runner, so multiplayer must widen around them rather
			-- than pulling the camera toward the middle of the group. Once eliminated, focusLane
			-- deliberately moves the anchor to the runner being spectated.
			centreLane = framing.focusLane or 0
			-- Back off until every lane on screen fits across it, whatever shape the screen is.
			local reach = math.max(framing.maxLane - centreLane, centreLane - framing.minLane)
			local span = 2 * reach * ViewProtocol.LANE_SPACING + STAGE_MARGIN
			local viewport = camera.ViewportSize
			local aspect = if viewport.Y > 0 then viewport.X / viewport.Y else 16 / 9
			distance = math.max(distance, (span * 0.5) / (math.tan(math.rad(camera.FieldOfView * 0.5)) * aspect))
		end
		local theta = math.rad(CAMERA_YAW_DEGREES)
		local right = Vector3.new(math.cos(theta), 0, -math.sin(theta))
		local focus = self.groundPosition + right * (centreLane * ViewProtocol.LANE_SPACING)
			+ Vector3.new(0, SimTuning.NOMINAL_HEIGHT * CAMERA_FOCUS_BASE + follow, 0)
		local offset = Vector3.new(math.sin(theta) * distance, CAMERA_LIFT, math.cos(theta) * distance)
		camera.CFrame = CFrame.lookAt(focus + offset, focus)
		camera.Focus = CFrame.new(focus)
	end
end

function RunPresenter.destroy(self: RunPresenter)
	restoreCharacterOpacity(self)
	self.gui:Destroy()
	self.ropeFolder:Destroy()
	self.sceneryFolder:Destroy()
	self.colorEffect:Destroy()
	self.bloomEffect:Destroy()
	self.blurEffect:Destroy()
end

return RunPresenter
