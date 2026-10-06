--!strict
--[[
	InputController — four transports collapsed into one logical button.

	Space, primary mouse, gamepad A and every screen touch have identical meaning. Tracking each
	InputObject separately matters: releasing one finger must not release the logical button while
	a second finger (or another device) is still held.

	BUTTONS ARE NEVER JUMPS (the user, 2026-09-11: "none of the buttons the user clicks should count
	as an input"). A press that lands on a button, a text box or an open panel belongs to that GUI; a
	tap anywhere else on the screen is still the jump. `exemptGui` adds GUI that is none of those, such
	as the SPLAT button.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local InputController = {}
InputController.__index = InputController

export type InputController = typeof(setmetatable(
	{} :: {
		held: { [InputObject]: boolean },
		down: boolean,
		onChanged: (boolean, InputObject?) -> (),
		connections: { RBXScriptConnection },
	},
	{} :: { __index: typeof(InputController) }
))

local function isRunInput(input: InputObject): boolean
	if input.UserInputType == Enum.UserInputType.Touch then
		return true
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		return true
	end
	return input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA
end

local exempt: { GuiObject } = {}

-- Presses that begin on `object` (or anything inside it) are the object's, never a jump.
function InputController.exemptGui(object: GuiObject)
	table.insert(exempt, object)
end

--[[
	Whether a pointer press landed on something the player clicks: any button or text box, anything
	Active (the popout panels are, so a tap on an open panel is not a jump either), or GUI registered
	with `exemptGui`. `GetGuiObjectsAtPosition` takes the same top-bar-free coordinates
	`InputObject.Position` reports: measured in Studio on 2026-09-11, a frame 300 px from the top of the
	screen reads AbsolutePosition 242 (the 58 px bar excluded) and is hit at exactly that point.
]]
local function onExemptGui(input: InputObject): boolean
	if input.UserInputType ~= Enum.UserInputType.MouseButton1
		and input.UserInputType ~= Enum.UserInputType.Touch then
		return false
	end
	local playerGui = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return false
	end
	for _, hit in playerGui:GetGuiObjectsAtPosition(input.Position.X, input.Position.Y) do
		if hit.Visible and (hit:IsA("GuiButton") or hit:IsA("TextBox") or hit.Active) then
			return true
		end
		for _, object in exempt do
			if object.Visible and (hit == object or hit:IsDescendantOf(object)) then
				return true
			end
		end
	end
	return false
end

local function recompute(self: InputController, source: InputObject?)
	local down = next(self.held) ~= nil
	if down ~= self.down then
		self.down = down
		self.onChanged(down, source)
	end
end

function InputController.new(onChanged: (boolean, InputObject?) -> ()): InputController
	local self = setmetatable({
		held = {},
		down = false,
		onChanged = onChanged,
		connections = {},
	}, InputController) :: any

	table.insert(self.connections, UserInputService.InputBegan:Connect(function(input)
		if not isRunInput(input) then
			return
		end
		-- Typing a space into chat is text entry, not game input. Touch remains tap-anywhere even
		-- when a GuiObject processed it, because the approved contract explicitly requires that.
		if input.KeyCode == Enum.KeyCode.Space and UserInputService:GetFocusedTextBox() then
			return
		end
		if onExemptGui(input) then
			return
		end
		self.held[input] = true
		recompute(self, input)
	end))

	table.insert(self.connections, UserInputService.InputEnded:Connect(function(input)
		if self.held[input] then
			self.held[input] = nil
			recompute(self, input)
		end
	end))

	table.insert(self.connections, UserInputService.WindowFocusReleased:Connect(function()
		table.clear(self.held)
		recompute(self, nil)
	end))

	return self
end

function InputController.isDown(self: InputController): boolean
	return self.down
end

-- A GUI click may complete after InputEnded (Activated is intentionally release-driven). Clearing
-- the tracked InputObjects when a card is applied prevents that ordering from leaving a stale
-- mouse/key held across the pause and eating the first real jump afterward.
function InputController.reset(self: InputController)
	table.clear(self.held)
	self.down = false
end

function InputController.destroy(self: InputController)
	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)
	table.clear(self.held)
end

return InputController
