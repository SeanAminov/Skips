--!strict
--[[
	AvatarNormalizer — presentation-tier belt and braces for the place's 5.5-stud R15 setting.

	Fairness does not depend on this module: RunSim never reads a character. This exists so the
	avatar the player sees agrees with the fixed nominal body the simulation judges. Accessories are
	deliberately excluded from measurement; a giant hat is decoration, not body height.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SimTuning = require(Shared:WaitForChild("SimTuning"))

local AvatarNormalizer = {}

local BODY_PARTS = table.freeze({
	Head = true,
	UpperTorso = true,
	LowerTorso = true,
	LeftUpperArm = true,
	LeftLowerArm = true,
	LeftHand = true,
	RightUpperArm = true,
	RightLowerArm = true,
	RightHand = true,
	LeftUpperLeg = true,
	LeftLowerLeg = true,
	LeftFoot = true,
	RightUpperLeg = true,
	RightLowerLeg = true,
	RightFoot = true,
})

local SCALE_NAMES = table.freeze({
	"BodyHeightScale",
	"BodyWidthScale",
	"BodyDepthScale",
	"HeadScale",
})

local function measureBody(character: Model): (number, number)
	local low = math.huge
	local high = -math.huge
	for _, child in character:GetChildren() do
		if child:IsA("BasePart") and BODY_PARTS[child.Name] then
			low = math.min(low, child.Position.Y - child.Size.Y * 0.5)
			high = math.max(high, child.Position.Y + child.Size.Y * 0.5)
		end
	end
	assert(low < high, "AvatarNormalizer: could not measure an R15 body")
	return low, high
end

local function getScale(humanoid: Humanoid, name: string): NumberValue
	local value = humanoid:WaitForChild(name, 5)
	assert(value and value:IsA("NumberValue"), "AvatarNormalizer: missing " .. name)
	return value
end

function AvatarNormalizer.prepare(character: Model): (BasePart, number)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid
	local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart
	assert(humanoid and humanoid:IsA("Humanoid"), "AvatarNormalizer: missing Humanoid")
	assert(root and root:IsA("BasePart"), "AvatarNormalizer: missing HumanoidRootPart")
	assert(humanoid.RigType == Enum.HumanoidRigType.R15, "AvatarNormalizer: the place must force R15")

	humanoid.AutomaticScalingEnabled = true
	local bodyType = humanoid:FindFirstChild("BodyTypeScale")
	if bodyType and bodyType:IsA("NumberValue") then
		bodyType.Value = 0
	end
	local proportion = humanoid:FindFirstChild("BodyProportionScale")
	if proportion and proportion:IsA("NumberValue") then
		proportion.Value = 0
	end

	-- Two short correction passes converge packages whose scale values settle one frame after a
	-- change. This is visual normalization only; no measured number crosses into RunSim.
	for _ = 1, 2 do
		local low, high = measureBody(character)
		local height = high - low
		if math.abs(height - SimTuning.NOMINAL_HEIGHT) <= 0.02 then
			break
		end
		local factor = SimTuning.NOMINAL_HEIGHT / height
		for _, name in SCALE_NAMES do
			local value = getScale(humanoid, name)
			value.Value *= factor
		end
		task.wait()
	end

	local low, high = measureBody(character)
	local finalHeight = high - low
	if math.abs(finalHeight - SimTuning.NOMINAL_HEIGHT) > 0.08 then
		warn(string.format(
			"[Skips] avatar presentation height is %.3f studs; expected %.3f",
			finalHeight,
			SimTuning.NOMINAL_HEIGHT
		))
	end

	humanoid.WalkSpeed = 0
	humanoid.JumpHeight = 0
	humanoid.JumpPower = 0
	humanoid.AutoRotate = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)

	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
		end
	end
	root.Anchored = true

	return root, root.Position.Y - low
end

return AvatarNormalizer
