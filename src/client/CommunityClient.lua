--!strict
--[[
	CommunityClient — left-edge COMMUNITY popout: verified Like+Join reward, honest Like/Follow
	copy, and a pointer to Roblox Social Links for Discord (16+).

	No raw Discord invite, username, QR code or external URL appears in-game. The server alone pays
	the community reward after `IsInGroupAsync` confirms membership.
]]

local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerProtocol = require(Shared:WaitForChild("PlayerProtocol"))
local RunProtocol = require(Shared:WaitForChild("RunProtocol"))
local SocialConfig = require(Shared:WaitForChild("SocialConfig"))

local CommunityClient = {}

local INK = Color3.fromRGB(40, 36, 61)
local PAPER = Color3.fromRGB(255, 253, 244)
local CREAM = Color3.fromRGB(255, 244, 211)
local PANEL = Color3.fromRGB(46, 42, 70)
local MUTED = Color3.fromRGB(157, 147, 164)
local GREEN = Color3.fromRGB(76, 181, 128)
local CORAL = Color3.fromRGB(240, 84, 74)
local GOLD = Color3.fromRGB(247, 197, 84)
local BLUE = Color3.fromRGB(93, 151, 213)
local PINK = Color3.fromRGB(255, 137, 172)

local PANEL_W, PANEL_H = 440, 620
local TICKET = "🎟"

local player = Players.LocalPlayer
local remoteFolder = ReplicatedStorage:WaitForChild(RunProtocol.REMOTE_FOLDER)
local playerRemote = remoteFolder:WaitForChild(PlayerProtocol.REMOTE_NAME) :: RemoteEvent

local gui = Instance.new("ScreenGui")
gui.Name = "SkipsCommunity"
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

local function words(parent: Instance, name: string, text: string, size: number,
	box: Vector2, centre: Vector2, colour: Color3?): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Size = UDim2.fromOffset(box.X, box.Y)
	label.Position = UDim2.fromOffset(centre.X, centre.Y)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.Text = text
	label.TextSize = size
	label.TextColor3 = colour or PAPER
	label.TextStrokeColor3 = INK
	label.TextStrokeTransparency = 0.1
	label.TextWrapped = true
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

local function card(parent: Instance, name: string, y: number, height: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Size = UDim2.fromOffset(PANEL_W - 40, height)
	frame.Position = UDim2.fromOffset(PANEL_W / 2, y)
	frame.BackgroundColor3 = Color3.fromRGB(35, 32, 54)
	frame.BorderSizePixel = 0
	frame.Active = true
	frame.Parent = parent
	corner(frame, 18)
	stroke(frame, INK, 3)
	return frame
end

-- Left-edge column after STYLE: VS, TOP, tickets, settings, style, community.
local openButton = chip(gui, "Open", "COM", Vector2.new(76, 48), Vector2.new(52, 396))
openButton.BackgroundColor3 = PINK
openButton.TextSize = 20

local popout = Instance.new("Frame")
popout.Name = "Community"
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
panel.Active = true
panel.Size = UDim2.fromScale(1, 1)
panel.BackgroundColor3 = PANEL
panel.BorderSizePixel = 0
panel.Parent = popout
corner(panel, 26)
stroke(panel, INK, 4)

words(panel, "Title", "COMMUNITY", 34, Vector2.new(PANEL_W - 130, 40), Vector2.new(PANEL_W / 2, 36))
local closeButton = chip(panel, "Close", "X", Vector2.new(38, 38), Vector2.new(PANEL_W - 30, 30))
closeButton.BackgroundColor3 = CORAL

local rewardTickets = SocialConfig.GROUP_REWARD_TICKETS
local joinCard = card(panel, "JoinCard", 70, 168)
words(joinCard, "Heading", "LIKE + JOIN THE SKIPS COMMUNITY", 18,
	Vector2.new(PANEL_W - 70, 24), Vector2.new((PANEL_W - 40) / 2, 28), GOLD)
words(joinCard, "Sub", string.format(
	"Like Skips on the game page, join once, claim %d %s. We verify community join.",
	rewardTickets, TICKET), 14,
	Vector2.new(PANEL_W - 70, 44), Vector2.new((PANEL_W - 40) / 2, 68), CREAM)
local joinButton = chip(joinCard, "JoinClaim", "JOIN + CLAIM", Vector2.new(220, 42),
	Vector2.new((PANEL_W - 40) / 2, 122))
joinButton.BackgroundColor3 = GREEN
local joinStatus = words(joinCard, "Status", "", 14,
	Vector2.new(PANEL_W - 70, 22), Vector2.new((PANEL_W - 40) / 2, 152), CREAM)

local likeCard = card(panel, "LikeCard", 250, 110)
words(likeCard, "Heading", "LIKE SKIPS", 18,
	Vector2.new(PANEL_W - 70, 24), Vector2.new((PANEL_W - 40) / 2, 28), GOLD)
words(likeCard, "Text", "A thumbs-up on the Roblox game page helps more players find Skips!", 14,
	Vector2.new(PANEL_W - 70, 40), Vector2.new((PANEL_W - 40) / 2, 62), CREAM)
local likeButton = chip(likeCard, "LikeGotIt", "GOT IT!", Vector2.new(140, 34),
	Vector2.new((PANEL_W - 40) / 2, 92))
likeButton.BackgroundColor3 = BLUE
likeButton.TextSize = 16

local followCard = card(panel, "FollowCard", 372, 96)
words(followCard, "Heading", "FOLLOW FOR UPDATES", 18,
	Vector2.new(PANEL_W - 70, 24), Vector2.new((PANEL_W - 40) / 2, 28), GOLD)
words(followCard, "Text", "Follow Skips on the Roblox game page for update alerts.", 14,
	Vector2.new(PANEL_W - 70, 40), Vector2.new((PANEL_W - 40) / 2, 66), CREAM)

local discordCard = card(panel, "DiscordCard", 480, 96)
words(discordCard, "Heading", "COMMUNITY SERVER", 18,
	Vector2.new(PANEL_W - 70, 24), Vector2.new((PANEL_W - 40) / 2, 28), GOLD)
words(discordCard, "Text", "Community links are on the Roblox game page (16+).", 14,
	Vector2.new(PANEL_W - 70, 40), Vector2.new((PANEL_W - 40) / 2, 66), CREAM)

local busy = false
local likeDismissed = false

local function paintClaimed()
	local claimed = player:GetAttribute(PlayerProtocol.ATTRIBUTE.GROUP_CLAIMED) == true
	if claimed then
		joinButton.Text = "CLAIMED ✓"
		joinButton.BackgroundColor3 = MUTED
		joinButton.AutoButtonColor = false
		joinStatus.Text = string.format("COMMUNITY BONUS CLAIMED! +%d %s", rewardTickets, TICKET)
		joinStatus.TextColor3 = GREEN
	elseif not busy then
		joinButton.Text = "JOIN + CLAIM"
		joinButton.BackgroundColor3 = GREEN
		joinButton.AutoButtonColor = true
	end
end

local function setStatus(text: string, ok: boolean?)
	joinStatus.Text = text
	if ok == true then
		joinStatus.TextColor3 = GREEN
	elseif ok == false then
		joinStatus.TextColor3 = CORAL
	else
		joinStatus.TextColor3 = CREAM
	end
end

local function claimFromServer()
	playerRemote:FireServer(PlayerProtocol.CLIENT.CLAIM_GROUP)
end

local function joinAndClaim()
	if busy then
		return
	end
	if player:GetAttribute(PlayerProtocol.ATTRIBUTE.GROUP_CLAIMED) == true then
		paintClaimed()
		return
	end
	busy = true
	joinButton.Text = "CHECKING…"
	joinButton.BackgroundColor3 = MUTED
	joinButton.AutoButtonColor = false
	setStatus("CHECKING…")

	task.spawn(function()
		local ok, result = pcall(function()
			return GroupService:PromptJoinAsync(SocialConfig.GROUP_ID)
		end)
		if not ok then
			busy = false
			paintClaimed()
			setStatus("CAN'T CHECK RIGHT NOW — TRY AGAIN SOON", false)
			return
		end
		if result == Enum.GroupMembershipStatus.None then
			busy = false
			paintClaimed()
			setStatus("JOIN THE COMMUNITY TO CLAIM", false)
			return
		end
		if result == Enum.GroupMembershipStatus.JoinRequestPending then
			busy = false
			paintClaimed()
			setStatus("JOIN REQUEST PENDING — TRY AGAIN SOON", false)
			return
		end
		-- Joined or AlreadyMember: server verifies and pays (or asks for a rejoin if cache lags).
		claimFromServer()
	end)
end

joinButton.Activated:Connect(joinAndClaim)
likeButton.Activated:Connect(function()
	likeDismissed = true
	likeButton.Text = "THANKS!"
	likeButton.BackgroundColor3 = MUTED
	likeButton.AutoButtonColor = false
end)

playerRemote.OnClientEvent:Connect(function(op, payload)
	if op ~= PlayerProtocol.SERVER.GROUP_RESULT or typeof(payload) ~= "table" then
		return
	end
	busy = false
	local data = payload :: any
	setStatus(tostring(data.message or ""), data.ok == true)
	paintClaimed()
end)

player:GetAttributeChangedSignal(PlayerProtocol.ATTRIBUTE.GROUP_CLAIMED):Connect(paintClaimed)

openButton.Activated:Connect(function()
	popout.Visible = not popout.Visible
	if popout.Visible then
		if not likeDismissed then
			likeButton.Text = "GOT IT!"
			likeButton.BackgroundColor3 = BLUE
			likeButton.AutoButtonColor = true
		end
		paintClaimed()
	end
end)
closeButton.Activated:Connect(function()
	popout.Visible = false
end)

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

paintClaimed()

return CommunityClient
