--!strict
--[[
	RopeView — draws one lane's ropes: the curved skipping rope, its handles, and its look.

	Split out of RunPresenter when other players' lanes arrived (2026-09-10), so the local rope and every
	ghost rope are drawn by the same code and can never disagree about what a rope looks like. It draws
	what it is told: the angle comes from the simulation's rope schedule (RunPresenter for the local run,
	StageView for everyone else), and the look from `RopeStyles` -- normal or guarded.

	WHERE THE ROPE IS HELD, AND WHY THESE NUMBERS (moved here with the drawing). Measured on a spawned
	R15 in this place: the idle hands rest 0.396 of body height above the feet. A single circle centred
	on the grip either floats beside the hands or goes through the head, so the ENDS are pinned at the
	grip and the MIDDLE traces an ellipse about its own centre, sized to touch the ground and clear the
	crown; the `1 - u²` envelope blends between them, which is what slack looks like. HIGH clears the
	tallest accessory rather than the skull (the hair is the tallest thing on a Roblox character), and
	DEPTH swings the rope around the arms instead of through them. The rope travels with the player, its
	low point trailing just under the feet but never below the floor: grounded at a sweep it catches the
	feet, airborne it passes under -- exactly what the simulation just decided.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RopeStyles = require(Shared:WaitForChild("RopeStyles"))
local SimTuning = require(Shared:WaitForChild("SimTuning"))

local RopeView = {}
RopeView.__index = RopeView

-- All fractions of NOMINAL_HEIGHT, so the shape survives a change to the body size -- and §5.1 fixes
-- that size for every player, so this stays honest for everyone.
local ROPE_GRIP = 0.396 -- measured hand height; handles stay at the hands
local ROPE_LOW = 0.02 -- bottom of the swing: just clear of the ground
local ROPE_HIGH = 1.68 -- a tall, exaggerated cartoon arc that clears hands-up jump poses
local ROPE_DEPTH = 1.12 -- a broad ellipse makes front/back rotation readable at the camera angle
local ROPE_FOOT_GAP = 0.15 -- how far under the feet the rope trails while airborne

type Visual = {
	folder: Folder,
	segments: { Part },
	guards: { Part },
	handles: { Part },
	light: PointLight,
	sparks: ParticleEmitter,
	guardShown: boolean,
}

export type RopeView = typeof(setmetatable(
	{} :: {
		parent: Instance,
		name: string,
		segmentCount: number,
		visuals: { Visual },
	},
	{} :: { __index: typeof(RopeView) }
))

local function makePart(parent: Instance, name: string, color: Color3): Part
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

local function setCylinderBetween(part: Part, a: Vector3, b: Vector3, thickness: number)
	local delta = b - a
	part.Size = Vector3.new(delta.Magnitude, thickness, thickness)
	part.CFrame = CFrame.lookAt((a + b) * 0.5, b) * CFrame.Angles(0, math.pi * 0.5, 0)
end

local function createVisual(self: RopeView, index: number): Visual
	local folder = Instance.new("Folder")
	folder.Name = self.name .. "Rope" .. index
	folder.Parent = self.parent
	local segments: { Part } = {}
	local guards: { Part } = {}
	for segmentIndex = 1, self.segmentCount do
		local segment = makePart(folder, "Segment" .. segmentIndex, Color3.fromRGB(157, 96, 58))
		segment.Shape = Enum.PartType.Cylinder
		segments[segmentIndex] = segment
		-- The guard sleeve is a second, fatter, see-through cylinder over each segment.
		local guard = makePart(folder, "Guard" .. segmentIndex, Color3.fromRGB(92, 214, 255))
		guard.Shape = Enum.PartType.Cylinder
		guard.Material = Enum.Material.ForceField
		guard.Transparency = 1
		guards[segmentIndex] = guard
	end
	local handles: { Part } = {}
	for handleIndex = 1, 2 do
		local handle = makePart(folder, "Handle" .. handleIndex, Color3.fromRGB(82, 47, 30))
		handle.Shape = Enum.PartType.Cylinder
		handle.Size = Vector3.new(0.78, 0.22, 0.22)
		handles[handleIndex] = handle
	end
	local middle = segments[math.ceil(self.segmentCount / 2)]
	local light = Instance.new("PointLight")
	light.Name = "Glow"
	light.Brightness = 1.4
	light.Range = 8
	light.Enabled = false
	light.Parent = middle
	-- Embers for a burning rope: small, short-lived and few, so they sell fire without hiding timing.
	local sparks = Instance.new("ParticleEmitter")
	sparks.Name = "Embers"
	sparks.Color = ColorSequence.new(Color3.fromRGB(255, 214, 90), Color3.fromRGB(255, 90, 40))
	sparks.LightEmission = 0.8
	sparks.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.18),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparks.Lifetime = NumberRange.new(0.25, 0.45)
	sparks.Speed = NumberRange.new(1, 3)
	sparks.SpreadAngle = Vector2.new(180, 180)
	sparks.Rate = 26
	sparks.Enabled = false
	sparks.Parent = middle
	return {
		folder = folder,
		segments = segments,
		guards = guards,
		handles = handles,
		light = light,
		sparks = sparks,
		guardShown = false,
	}
end

function RopeView.new(parent: Instance, name: string, segmentCount: number?): RopeView
	return setmetatable({
		parent = parent,
		name = name,
		segmentCount = segmentCount or 18,
		visuals = {},
	}, RopeView) :: any
end

function RopeView.setCount(self: RopeView, count: number)
	while #self.visuals < count do
		table.insert(self.visuals, createVisual(self, #self.visuals + 1))
	end
	while #self.visuals > count do
		local visual = table.remove(self.visuals)
		if visual then
			visual.folder:Destroy()
		end
	end
end

--[[
	Draws rope `index` for a lane whose ground point is `ground`, at `angle` in its turn, around a body
	whose feet are `playerY` above that ground.
]]
function RopeView.draw(
	self: RopeView,
	index: number,
	ground: Vector3,
	angle: number,
	burning: boolean,
	guarded: boolean,
	playerY: number,
	lowGraphics: boolean,
	setId: string?
)
	local visual = self.visuals[index]
	if not visual then
		return
	end
	local look = RopeStyles.look(setId, burning, guarded)
	local height = SimTuning.NOMINAL_HEIGHT
	local count = self.segmentCount
	local halfWidth = 3.05 + (index - 1) * 0.06
	local gripY = height * ROPE_GRIP
	local centreY = height * (ROPE_LOW + ROPE_HIGH) * 0.5
	local verticalRadius = height * (ROPE_HIGH - ROPE_LOW) * 0.5
	local depthRadius = height * ROPE_DEPTH

	-- The rope rides with the player, its low point trailing just under the feet -- but never below
	-- the floor, so a grounded sweep meets the ground at the feet instead of sinking through it.
	local followY = math.max(0, playerY - height * ROPE_FOOT_GAP)
	local base = ground + Vector3.new(0, followY, 0)

	local points: { Vector3 } = {}
	for pointIndex = 0, count do
		local u = -1 + 2 * pointIndex / count
		local envelope = 1 - u * u
		points[pointIndex + 1] = base + Vector3.new(
			u * halfWidth,
			gripY + envelope * ((centreY - gripY) + verticalRadius * math.cos(angle)),
			envelope * depthRadius * math.sin(angle)
		)
	end

	local guard = look.guard
	for segmentIndex, segment in visual.segments do
		local a, b = points[segmentIndex], points[segmentIndex + 1]
		setCylinderBetween(segment, a, b, look.thickness)
		segment.Material = look.material
		segment.Color = if segmentIndex % 2 == 0 then look.colorA else look.colorB
		local sleeve = visual.guards[segmentIndex]
		if guard then
			setCylinderBetween(sleeve, a, b, guard.thickness)
			sleeve.Color = guard.color
			sleeve.Material = guard.material
			sleeve.Transparency = guard.transparency
		elseif visual.guardShown then
			sleeve.Transparency = 1
		end
	end
	visual.guardShown = guard ~= nil

	for handleIndex, side in { -1, 1 } do
		local handle = visual.handles[handleIndex]
		handle.Color = look.handleColor
		handle.Material = look.handleMaterial
		handle.CFrame = CFrame.new(base + Vector3.new(side * (halfWidth + 0.18), gripY, 0))
			* CFrame.Angles(0, 0, math.pi * 0.5)
	end

	local glow = look.glow
	visual.light.Enabled = glow ~= nil and not lowGraphics
	if glow then
		visual.light.Color = glow
	end
	visual.sparks.Enabled = look.sparks and not lowGraphics
end

function RopeView.destroy(self: RopeView)
	self:setCount(0)
end

return RopeView
