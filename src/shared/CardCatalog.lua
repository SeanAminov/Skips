--!strict
--[[
	CardCatalog — the complete Stage 2 deck and the one authoritative offer roll.

	Every card is data: a short name, atlas icon, color theme, integer offer weights and
	generic stat effects. Most cards stack forever. Ignite and Reinforce repeat only while a distinct
	unlit or unguarded owned rope exists. Add Jumprope and Jump Rope Speed remain eligible through
	their final useful stack, then retire at the shared render/readability limits.
	The in-game choice deliberately shows only the icon and name; effect prose
	belongs in design documentation, not on a timing-game interruption.
	The server stores the three Card objects returned by `rollOffer`; the client receives their IDs
	and resolves those IDs back into these same frozen definitions. Adding a normal card is one row.

	Luck deliberately modifies integer weights rather than a hidden percentage. No fractional weight
	is ever truncated, and any future odds display can call `weightFor` on the exact row used to roll.

	CARDS DO NOT CARRY THEIR OWN CEILINGS. A row says which stat it moves and by how much; how far
	that stat may travel is `SimTuning.STAT_LIMITS`, shared by every card that touches it. On
	2026-09-12 the user restored practical caps for rope count and speed: those two cards use
	`maxStacks`; all other progression remains open-ended.
]]

local SimTuning = require(script.Parent.SimTuning)
local Rng = require(script.Parent.Rng)

type Rng = Rng.Rng

export type Card = {
	id: string,
	name: string,
	iconIndex: number,
	theme: string,
	baseWeight: number,
	luckWeight: number,
	maxStacks: number?, -- nil means the card remains repeatable forever
	requires: { [string]: number }?,
	-- This card consumes one currently open rope slot. `perRopeBase` is the stat's value before any
	-- rope is upgraded (scorePerLoop starts at one; ropeReinforcements starts at zero).
	perRopeStat: string?,
	perRopeBase: number?,
	effects: { {
		stat: string,
		operation: string,
		value: number,
	} },
}

local CardCatalog = {}

-- Rocket fuel was too generous at unlock. Apply one shared 0.55 balance scale to the initial tank
-- and every later capacity bonus so the whole rocket path keeps its original proportions
-- instead of only weakening the first card. Capacity stays integral because fuel burns in ticks.
local ROCKET_FUEL_SCALE = 0.55
local function scaledFuelTicks(originalTicks: number): number
	return math.floor(originalTicks * ROCKET_FUEL_SCALE + 0.5)
end

local cards: { Card } = {
	{
		id = "ADD_JUMPROPE",
		name = "Add Jumprope",
		iconIndex = 3,
		theme = "GOLD",
		baseWeight = 100,
		luckWeight = 0,
		maxStacks = SimTuning.MAX_ROPES - SimTuning.baseStats().ropeCount,
		effects = { { stat = "ropeCount", operation = "ADD", value = 1 } },
	},
	{
		id = "IGNITE_JUMPROPE",
		name = "Ignite Jumprope",
		iconIndex = 7,
		theme = "CORAL",
		baseWeight = 55,
		luckWeight = 12,
		perRopeStat = "scorePerLoop",
		perRopeBase = 1,
		effects = { { stat = "scorePerLoop", operation = "ADD", value = 1 } },
	},
	{
		id = "INCREASE_JUMP_HEIGHT",
		name = "Increase Jump Height",
		iconIndex = 1,
		theme = "BLUE",
		baseWeight = 100,
		luckWeight = 0,
		effects = { { stat = "jumpImpulse", operation = "ADD", value = 1.5 } },
	},
	{
		id = "REINFORCE_JUMP_ROPE",
		name = "Reinforce Jump Rope",
		iconIndex = 10,
		theme = "TEAL",
		baseWeight = 70,
		luckWeight = 8,
		perRopeStat = "ropeReinforcements",
		perRopeBase = 0,
		effects = { { stat = "ropeReinforcements", operation = "ADD", value = 1 } },
	},
	{
		id = "INCREASE_LUCK",
		name = "Increase Luck",
		iconIndex = 9,
		theme = "GREEN",
		baseWeight = 70,
		luckWeight = 4,
		effects = { { stat = "luck", operation = "ADD", value = 1 } },
	},
	{
		id = "JUMP_ROPE_SPEED",
		name = "Increase Jump Rope Speed",
		iconIndex = 2,
		theme = "GOLD",
		baseWeight = 100,
		luckWeight = 0,
		maxStacks = math.ceil((SimTuning.baseStats().ropePeriodTicks - SimTuning.PERIOD_TICKS_MIN) / 8),
		effects = {
			{ stat = "ropePeriodTicks", operation = "ADD", value = -8 },
		},
	},
	{
		id = "ROCKET_SHOES",
		name = "Rocket Shoes",
		iconIndex = 5,
		theme = "CORAL",
		baseWeight = 70,
		luckWeight = 8,
		effects = {
			{ stat = "rocketFuelCapacity", operation = "ADD", value = scaledFuelTicks(90) },
		},
	},
	{
		id = "ROCKET_FUEL",
		name = "Upgrade Rocket Fuel",
		iconIndex = 4,
		theme = "PURPLE",
		baseWeight = 70,
		luckWeight = 8,
		requires = { ROCKET_SHOES = 1 },
		effects = {
			{ stat = "rocketFuelCapacity", operation = "ADD", value = scaledFuelTicks(60) },
		},
	},
	{
		id = "SUPER_ROCKET_SHOES",
		name = "Super Rocket Shoes",
		iconIndex = 8,
		theme = "PURPLE",
		baseWeight = 25,
		luckWeight = 20,
		requires = { ROCKET_SHOES = 1, ROCKET_FUEL = 3 },
		effects = {
			{ stat = "rocketFuelCapacity", operation = "ADD", value = scaledFuelTicks(180) },
			{ stat = "rocketThrust", operation = "MULTIPLY", value = 1.35 },
		},
	},
}

local byId: { [string]: Card } = {}
local integerStats = table.freeze({
	maxHoldTicks = true,
	rocketFuelCapacity = true,
	ropePeriodTicks = true,
	ropeCount = true,
	scorePerLoop = true,
	ropeReinforcements = true,
	luck = true,
})

function CardCatalog.validate(): true
	-- Nine since 2026-09-11: Jumper Reinforcement was removed at the user's direction ("just remove
	-- jumper reinforcement"). Its atlas cell, 6, is simply unused.
	assert(#cards == 9, string.format("CardCatalog must contain exactly 9 cards, got %d", #cards))
	local base = SimTuning.baseStats() :: any
	local seen: { [string]: boolean } = {}
	for index, card in cards do
		assert(card.id:match("^[A-Z][A-Z0-9_]*$") ~= nil, string.format("card %d has an invalid id", index))
		assert(not seen[card.id], "duplicate card id " .. card.id)
		seen[card.id] = true
		assert(card.name ~= "", card.id .. " needs a player-facing name")
		assert(card.iconIndex >= 1 and card.iconIndex <= 10 and card.iconIndex == math.floor(card.iconIndex),
			card.id .. " iconIndex must address one of the ten atlas cells")
		assert(card.theme ~= "", card.id .. " needs a color theme")
		assert(card.baseWeight > 0 and card.baseWeight == math.floor(card.baseWeight),
			card.id .. " baseWeight must be a positive integer")
		assert(card.luckWeight >= 0 and card.luckWeight == math.floor(card.luckWeight),
			card.id .. " luckWeight must be a non-negative integer")
		if card.maxStacks ~= nil then
			assert(card.maxStacks > 0 and card.maxStacks == math.floor(card.maxStacks),
				card.id .. " maxStacks must be a positive integer when present")
		end
		if card.perRopeStat then
			local stat = card.perRopeStat :: string
			local baseValue = card.perRopeBase
			assert(typeof(base[stat]) == "number", card.id .. " names an unknown per-rope stat")
			assert(typeof(baseValue) == "number" and baseValue == base[stat],
				card.id .. " per-rope baseline must match the base stat")
			assert(#card.effects == 1 and card.effects[1].stat == stat
				and card.effects[1].operation == "ADD" and card.effects[1].value == 1,
				card.id .. " must consume exactly one rope slot")
		end
		assert(#card.effects > 0, card.id .. " must change at least one stat")
		for effectIndex, effect in card.effects do
			assert(typeof(base[effect.stat]) == "number",
				string.format("%s effect %d targets unknown stat %q", card.id, effectIndex, effect.stat))
			assert(effect.operation == "ADD" or effect.operation == "MULTIPLY",
				string.format("%s effect %d has an invalid operation", card.id, effectIndex))
			if integerStats[effect.stat] then
				assert(effect.value == math.floor(effect.value),
					string.format("%s makes integer stat %s fractional", card.id, effect.stat))
			end
			assert(SimTuning.STAT_LIMITS[effect.stat] ~= nil,
				string.format("%s moves %s, which has no limit to clamp against", card.id, effect.stat))
			if card.maxStacks == nil then
				assert(SimTuning.STAT_LIMITS[effect.stat].maximum == nil,
					string.format("repeatable %s moves capped stat %s", card.id, effect.stat))
			end
			local identity = if effect.operation == "ADD" then 0 else 1
			assert(effect.value ~= identity,
				string.format("%s effect %d is a no-op on %s", card.id, effectIndex, effect.stat))
			if card.maxStacks ~= nil then
				local limit = SimTuning.STAT_LIMITS[effect.stat]
				local function valueAfter(stacks: number): number
					local value = base[effect.stat]
					for _ = 1, stacks do
						value = if effect.operation == "ADD" then value + effect.value else value * effect.value
						value = math.clamp(value, limit.minimum, limit.maximum or math.huge)
					end
					return value
				end
				assert(valueAfter(card.maxStacks) ~= valueAfter(card.maxStacks - 1),
					card.id .. " must remain useful through its final offered stack")
				assert(valueAfter(card.maxStacks + 1) == valueAfter(card.maxStacks),
					card.id .. " must retire exactly when its shared stat limit is reached")
			end
		end
		byId[card.id] = card
	end
	for _, card in cards do
		if card.requires then
			for prerequisiteId, stacksRequired in card.requires do
				local prerequisite = byId[prerequisiteId]
				assert(prerequisite ~= nil, card.id .. " requires unknown card " .. prerequisiteId)
				assert(prerequisiteId ~= card.id, card.id .. " cannot require itself")
				assert(stacksRequired >= 1 and stacksRequired == math.floor(stacksRequired),
					card.id .. " prerequisite stacks must be a positive integer")
				local prerequisiteCap = (prerequisite :: Card).maxStacks
				assert(prerequisiteCap == nil or stacksRequired <= prerequisiteCap,
					card.id .. " requires more stacks than " .. prerequisiteId .. " allows")
			end
		end
	end
	return true
end

function CardCatalog.get(cardId: string): Card?
	return byId[cardId]
end

function CardCatalog.weightFor(card: Card, luck: number): number
	assert(luck >= 0 and luck == math.floor(luck), "luck must be a non-negative integer")
	return card.baseWeight + luck * card.luckWeight
end

function CardCatalog.isEligible(card: Card, stacks: { [string]: number }, stats: SimTuning.Stats): boolean
	local owned = stacks[card.id] or 0
	if card.maxStacks ~= nil and owned >= card.maxStacks then
		return false
	end
	if card.requires then
		for prerequisiteId, stacksRequired in card.requires do
			if (stacks[prerequisiteId] or 0) < stacksRequired then
				return false
			end
		end
	end
	if card.perRopeStat then
		local used = (stats :: any)[card.perRopeStat] - (card.perRopeBase or 0)
		if used >= stats.ropeCount then
			return false
		end
	end
	return true
end

function CardCatalog.eligibleCount(stacks: { [string]: number }, stats: SimTuning.Stats): number
	local count = 0
	for _, card in cards do
		if CardCatalog.isEligible(card, stacks, stats) then
			count += 1
		end
	end
	return count
end

function CardCatalog.rollOffer(
	rng: Rng,
	luck: number,
	stacks: { [string]: number },
	stats: SimTuning.Stats
): { Card }
	local eligible: { Card } = {}
	for _, card in cards do
		if CardCatalog.isEligible(card, stacks, stats) then
			table.insert(eligible, card)
		end
	end
	assert(#eligible > 0, "no cards remain eligible")
	local actionable = table.clone(eligible)

	local offer: { Card } = {}
	for _ = 1, 3 do
		-- Normal offers remain three different cards. If fewer than three actionable definitions
		-- remain in an extreme run, repeat those choices: only one card can be taken from the modal,
		-- so each duplicate is still actionable and progression never crashes on an undersized pool.
		local pool = if #eligible > 0 then eligible else actionable
		local totalWeight = 0
		for _, card in pool do
			totalWeight += CardCatalog.weightFor(card, luck)
		end
		local roll = rng:nextInt(1, totalWeight)
		local chosenIndex = 1
		for index, card in pool do
			roll -= CardCatalog.weightFor(card, luck)
			if roll <= 0 then
				chosenIndex = index
				break
			end
		end
		if pool == eligible then
			table.insert(offer, table.remove(eligible, chosenIndex))
		else
			table.insert(offer, pool[chosenIndex])
		end
	end
	return offer
end

function CardCatalog.resolveOfferedCard(offer: { Card }, cardId: string): Card?
	for _, card in offer do
		if card.id == cardId then
			return card
		end
	end
	return nil
end

CardCatalog.validate()
for _, card in cards do
	for _, effect in card.effects do
		table.freeze(effect)
	end
	if card.requires then
		table.freeze(card.requires)
	end
	table.freeze(card.effects)
	table.freeze(card)
end

CardCatalog.CARDS = table.freeze(cards)

return table.freeze(CardCatalog)
