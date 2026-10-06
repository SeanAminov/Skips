--!strict
--[[
	RopeStyles — what a rope looks like, as data.

	FOUR LOOKS, one per state the user named (2026-09-10): a normal rope, a rope on fire, a rope with a
	protection guard, and a rope on fire AND guarded. The states are the simulation's: a rope is on fire
	when an Ignite card has lit it, and guarded while it carries its own Reinforce Jump Rope guard, waiting to absorb
	a hit. How each state LOOKS is this table, and nothing else.

	COSMETICS ARE A NEW SET, NOT NEW CODE. A cosmetic rope is another entry in `SETS` with its own four
	looks; presenters ask `RopeStyles.look(setId, burning, guarded)` and draw whatever comes back. A
	cosmetic can change colour, material and sparkle -- and never the rope's shape or thickness range,
	because a rope that is harder to read would be a gameplay change bought in a shop (§7).

	Presentation only: nothing here is read by the simulation.
]]

export type Guard = {
	color: Color3,
	transparency: number,
	thickness: number, -- the sleeve's diameter, drawn around the rope
	material: Enum.Material,
}

export type Look = {
	colorA: Color3, -- alternating segment colours: fibre twist, or flame
	colorB: Color3,
	material: Enum.Material,
	thickness: number,
	handleColor: Color3,
	handleMaterial: Enum.Material,
	glow: Color3?, -- a light along the rope, nil for none
	sparks: boolean, -- embers along the rope
	guard: Guard?, -- the protection sleeve, nil for none
}

export type LookSet = {
	name: string,
	NORMAL: Look,
	FIRE: Look,
	GUARD: Look,
	FIRE_GUARD: Look,
}

local RopeStyles = {}

-- The guard is a translucent cyan sleeve with Roblox's shimmering ForceField material: it reads as
-- "shielded" at a glance and still lets the rope inside show through, so the timing never hides.
local GUARD_SLEEVE: Guard = table.freeze({
	color = Color3.fromRGB(92, 214, 255),
	transparency = 0.15,
	thickness = 0.42,
	material = Enum.Material.ForceField,
})

local FIBRE_A = Color3.fromRGB(157, 96, 58)
local FIBRE_B = Color3.fromRGB(126, 72, 43)
local FLAME_A = Color3.fromRGB(255, 220, 63)
local FLAME_B = Color3.fromRGB(255, 75, 39)

local DEFAULT: LookSet = {
	name = "Classic",
	NORMAL = {
		colorA = FIBRE_A,
		colorB = FIBRE_B,
		material = Enum.Material.SmoothPlastic,
		thickness = 0.16,
		handleColor = Color3.fromRGB(82, 47, 30),
		handleMaterial = Enum.Material.SmoothPlastic,
		glow = nil,
		sparks = false,
		guard = nil,
	},
	FIRE = {
		colorA = FLAME_A,
		colorB = FLAME_B,
		material = Enum.Material.Neon,
		thickness = 0.2,
		handleColor = Color3.fromRGB(255, 97, 44),
		handleMaterial = Enum.Material.Neon,
		glow = Color3.fromRGB(255, 126, 39),
		sparks = true,
		guard = nil,
	},
	GUARD = {
		colorA = FIBRE_A,
		colorB = FIBRE_B,
		material = Enum.Material.SmoothPlastic,
		thickness = 0.16,
		handleColor = Color3.fromRGB(64, 170, 220),
		handleMaterial = Enum.Material.Neon,
		glow = Color3.fromRGB(92, 214, 255),
		sparks = false,
		guard = GUARD_SLEEVE,
	},
	FIRE_GUARD = {
		colorA = FLAME_A,
		colorB = FLAME_B,
		material = Enum.Material.Neon,
		thickness = 0.2,
		handleColor = Color3.fromRGB(64, 170, 220),
		handleMaterial = Enum.Material.Neon,
		glow = Color3.fromRGB(255, 170, 120),
		sparks = true,
		guard = GUARD_SLEEVE,
	},
}

RopeStyles.DEFAULT_SET = "DEFAULT"

RopeStyles.SETS = table.freeze({
	DEFAULT = DEFAULT,
}) :: { [string]: LookSet }

-- The thickness a look may use. A cosmetic outside it would change how readable the rope is.
RopeStyles.MIN_THICKNESS = 0.12
RopeStyles.MAX_THICKNESS = 0.24

function RopeStyles.look(setId: string?, burning: boolean, guarded: boolean): Look
	local set = RopeStyles.SETS[setId or RopeStyles.DEFAULT_SET] or RopeStyles.SETS[RopeStyles.DEFAULT_SET]
	if burning and guarded then
		return set.FIRE_GUARD
	elseif burning then
		return set.FIRE
	elseif guarded then
		return set.GUARD
	end
	return set.NORMAL
end

function RopeStyles.validate(): true
	assert(RopeStyles.SETS[RopeStyles.DEFAULT_SET] ~= nil, "the default rope set must exist")
	for setId, set in RopeStyles.SETS do
		for _, state in { "NORMAL", "FIRE", "GUARD", "FIRE_GUARD" } do
			local look = (set :: any)[state] :: Look
			assert(look ~= nil, string.format("rope set %s has no %s look", setId, state))
			assert(look.thickness >= RopeStyles.MIN_THICKNESS and look.thickness <= RopeStyles.MAX_THICKNESS,
				string.format("rope set %s %s is outside the readable thickness range", setId, state))
			local guarded = state == "GUARD" or state == "FIRE_GUARD"
			assert((look.guard ~= nil) == guarded,
				string.format("rope set %s %s must %s a guard", setId, state, if guarded then "show" else "not show"))
		end
	end
	return true
end

RopeStyles.validate()

for _, set in RopeStyles.SETS do
	for _, state in { "NORMAL", "FIRE", "GUARD", "FIRE_GUARD" } do
		table.freeze((set :: any)[state])
	end
	table.freeze(set)
end

return table.freeze(RopeStyles)
