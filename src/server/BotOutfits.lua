--!strict
--[[
	BotOutfits — what a bot wears.

	The user (2026-09-11): "make sure the skins are random, right now they're pretty basic, need some
	more creative outfits, maybe on the creator store or through saved data." Bots used to be a blocky
	default body in flat colours. Each one is now dressed from ROBLOX'S OWN FREE CATALOG: a hairstyle,
	sometimes a cap or a hood, now and then shades, a backpack or a floatie, and a real shirt and
	trousers -- what a great many real players actually wear, which is what an undisclosed bot needs.

	WHY ROBLOX'S OWN FREE ITEMS, AS A FIXED LIST.
	  * Made and moderated by Roblox, free, and all ages: nothing a bot wears can raise the game's
	    rating, and nobody's paid design ends up on a stranger.
	  * No player data. Copying real players' saved outfits onto bots would put a real person's look
	    on something that is not them.
	  * Fixed rather than searched at runtime. Checked in Studio on 2026-09-11 against the live catalog
	    (AvatarEditorService:SearchCatalog, creator "Roblox", free, on sale, best-selling first). A live
	    server should not need a web search to dress a bot, and an item Roblox later takes off sale
	    still loads by id.
	  Left out on purpose: the Dia de Muertos skull mask (nothing in this game is spooky), promotional
	  "User Ads" items, and the one classic T-shirt.

	MatchService builds each look with `Players:CreateHumanoidModelFromDescription`. If an item ever
	fails to load, the bot falls back to `plain` -- it is never left without a body.
]]

local BotOutfits = {}

export type Item = { id: number, name: string }

-- The classic new-player "bacon hair", weighted up because a field without one would look odd.
BotOutfits.PAL_HAIR = 63690008

BotOutfits.HAIR = table.freeze({
	{ id = 451221329, name = "True Blue Hair" },
	{ id = 1103003368, name = "Orange Beanie with Black Hair" },
	{ id = 2956239660, name = "Belle Of Belfast Long Red Hair" },
	{ id = 451220849, name = "Lavender Updo" },
	{ id = 63690008, name = "Pal Hair" },
	{ id = 3814474927, name = "Cool Side Shave" },
	{ id = 3814476174, name = "Colorful Braids" },
	{ id = 7193442167, name = "Pony Tail - Black" },
	{ id = 376524487, name = "Blonde Spiked Hair" },
	{ id = 9244021842, name = "Side Part - Black" },
	{ id = 6993754725, name = "Straight Bangs - Black" },
	{ id = 9244111257, name = "Wavy Middle Part - Black" },
	{ id = 9244095135, name = "Pony Tail - Blonde" },
	{ id = 7193448258, name = "Wavy Middle Part - Brown" },
	{ id = 376526888, name = "Straight Blonde Hair" },
	{ id = 9243987340, name = "Short and Sleek - Blonde" },
	{ id = 376548738, name = "Brown Charmer Hair" },
	{ id = 9174355709, name = "Sideswept Dreads - Black" },
	{ id = 9243992729, name = "Short and Sleek - Black" },
	{ id = 9244089488, name = "Medium Middle Part - Black" },
	{ id = 7193444640, name = "Pony Tail - Red" },
	{ id = 9244097555, name = "Pony Tail - Brown" },
	{ id = 9244038785, name = "Surfer - Red" },
	{ id = 376527350, name = "Black Ponytail" },
	{ id = 9174354743, name = "Top Knot - Black" },
	{ id = 7193448988, name = "Straight Bangs - Blonde" },
	{ id = 9174353649, name = "Surfer - Black" },
	{ id = 7193450455, name = "Curly Afro - Black" },
	{ id = 7193449810, name = "Straight Bangs - Brown" },
	{ id = 7193386173, name = "Side Part - Blonde" },
	{ id = 9244122897, name = "Straight Bangs - Red" },
	{ id = 7193445686, name = "Wavy Middle Part - Blonde" },
	{ id = 9244114211, name = "Wavy Middle Part - Red" },
	{ id = 7193401217, name = "Short Fringe - Black" },
	{ id = 9244070571, name = "Sideswept Dreads - Brown" },
	{ id = 7193419595, name = "Side Part - Brown" },
	{ id = 9243995099, name = "Short and Sleek - Red" },
	{ id = 62234425, name = "Brown Hair" },
	{ id = 9244067444, name = "Sideswept Dreads - Blonde" },
	{ id = 6993758617, name = "Short and Sleek - Brown" },
	{ id = 7193405096, name = "Curly Fade - Black" },
	{ id = 7193455510, name = "Braided Hair - Red" },
	{ id = 9244024443, name = "Side Part - Red" },
	{ id = 9244148336, name = "Braided Hair - Blonde" },
	{ id = 9244060144, name = "Top Knot - Brown" },
	{ id = 7193452166, name = "Short Curls - Black" },
	{ id = 9244033194, name = "Surfer - Brown" },
	{ id = 9244057408, name = "Top Knot - Blonde" },
	{ id = 9244010432, name = "Curly Fade - Brown" },
	{ id = 9244064248, name = "Top Knot - Red" },
	{ id = 7193451306, name = "Curly Afro - Cool Brown" },
	{ id = 7193437847, name = "Medium Middle Part - Brown" },
	{ id = 7193454569, name = "Braided Hair - Black" },
	{ id = 9244091757, name = "Medium Middle Part - Red" },
	{ id = 9244150641, name = "Braided Hair - Cool Brown" },
	{ id = 7193424874, name = "Medium Middle Part - Blonde" },
	{ id = 9244125859, name = "Curly Afro - Blonde" },
	{ id = 7193397693, name = "Short Fringe - Blonde" },
	{ id = 9244145658, name = "Short Curls - Red" },
	{ id = 9244082349, name = "Sideswept Dreads - Red" },
	{ id = 9244029916, name = "Surfer - Blonde" },
	{ id = 9244134513, name = "Short Curls - Blonde" },
	{ id = 9244014391, name = "Curly Fade - Red" },
	{ id = 9243976603, name = "Short Fringe - Brown" },
	{ id = 9244131570, name = "Curly Afro - Red" },
	{ id = 9244137452, name = "Short Curls - Cool Brown" },
	{ id = 9243983205, name = "Short Fringe - Red" },
	{ id = 9244008307, name = "Curly Fade - Blonde" },
}) :: { Item }

BotOutfits.HATS = table.freeze({
	{ id = 607702162, name = "Roblox Baseball Cap" },
	{ id = 617605556, name = "Medieval Hood of Mystery" },
	{ id = 417457461, name = "ROBLOX 'R' Baseball Cap" },
	{ id = 4819740796, name = "Robox" },
	{ id = 607700713, name = "Roblox Logo Visor" },
	{ id = 2646473721, name = "Roblox Visor" },
	{ id = 48474313, name = "Red Roblox Cap" },
	{ id = 3403874988, name = "The Encierro Cap" },
	{ id = 73806172412277, name = "Roblox Learn Plumera Crown" },
	{ id = 4047554959, name = "International Fedora - Brazil" },
	{ id = 3409612660, name = "International Fedora - USA" },
	{ id = 4489239608, name = "International Fedora - United Kingdom" },
	{ id = 4324158403, name = "International Fedora - Japan" },
	{ id = 3398308134, name = "International Fedora - Canada" },
	{ id = 4094878701, name = "International Fedora - Mexico" },
	{ id = 3033910400, name = "International Fedora - Germany" },
	{ id = 3033908130, name = "International Fedora - France" },
	{ id = 3940375351, name = "International Fedora - Philippines" },
	{ id = 4645400486, name = "International Fedora - Australia" },
	{ id = 3656493304, name = "International Fedora - South Korea" },
	{ id = 4246228452, name = "International Fedora - Spain" },
}) :: { Item }

BotOutfits.SHIRTS = table.freeze({
	{ id = 607785314, name = "ROBLOX Jacket" },
	{ id = 398633584, name = "Denim Jacket with White Hoodie" },
	{ id = 3670737444, name = "Roblox Shirt - Simple Pattern" },
	{ id = 398634295, name = "Pastel Starburst Top with Gray Jacket" },
	{ id = 398635081, name = "Blue Plaid Shirt" },
	{ id = 144076358, name = "Blue and Black Motorcycle Shirt" },
	{ id = 382538059, name = "Green Jersey" },
	{ id = 4047884939, name = "My Favorite Pizza Shirt" },
	{ id = 4047884046, name = "Guitar Tee with Black Jacket" },
	{ id = 4047886060, name = "Purple and Teal Top" },
	{ id = 144076436, name = "Grey Striped Shirt with Denim Jacket" },
	{ id = 382538295, name = "Guitar Tee with Black Jacket" },
	{ id = 382537085, name = "I <3 Pizza Shirt" },
	{ id = 382537702, name = "Teal Shirt" },
}) :: { Item }

BotOutfits.PANTS = table.freeze({
	{ id = 398633812, name = "Black Jeans with White Shoes" },
	{ id = 398634487, name = "Beautiful You Jeans" },
	{ id = 398635338, name = "Ripped Skater Pants" },
	{ id = 144076760, name = "Dark Green Jeans" },
	{ id = 382537950, name = "Jean Shorts with White Shoes" },
	{ id = 382538503, name = "Black Jeans with Sneakers" },
	{ id = 382537569, name = "Black Jeans" },
	{ id = 382537806, name = "Jean Shorts" },
}) :: { Item }

BotOutfits.FACE = table.freeze({
	{ id = 376527500, name = "Orange Shades" },
	{ id = 376526673, name = "Stylish Aviators" },
	{ id = 3798251754, name = "Sugar Shades" },
	{ id = 99390776933762, name = "Roblox Learn Ducky Head" },
}) :: { Item }

BotOutfits.NECK = table.freeze({
	{ id = 376527115, name = "Jade Necklace with Shell Pendant" },
	{ id = 107016726530712, name = "Roblox Learn Heart Necklace" },
}) :: { Item }

BotOutfits.BACK = table.freeze({
	{ id = 98752422639730, name = "Dog Backpack" },
	{ id = 3798239844, name = "Frosting Flyers" },
	{ id = 71409823493730, name = "Silver Block" },
}) :: { Item }

BotOutfits.SHOULDER = table.freeze({
	{ id = 119934643965525, name = "Starwisp" },
	{ id = 3581868178, name = "Goldrow" },
}) :: { Item }

BotOutfits.WAIST = table.freeze({
	{ id = 3798231832, name = "Party Unicorn Floatie" },
	{ id = 8835792701, name = "Performance Keychain" },
}) :: { Item }

-- How often each slot is filled. Everyone has hair and clothes most of the time; the fun extras are rare
-- enough that a lobby of seven has a couple, not a costume party.
BotOutfits.CHANCE = table.freeze({
	palHair = 0.12,
	hair = 0.94,
	hat = 0.35,
	face = 0.16,
	neck = 0.07,
	back = 0.09,
	shoulder = 0.04,
	waist = 0.05,
	clothes = 0.85,
})

BotOutfits.SKIN = table.freeze({
	Color3.fromRGB(255, 204, 153), Color3.fromRGB(234, 184, 146), Color3.fromRGB(204, 142, 105),
	Color3.fromRGB(160, 110, 80), Color3.fromRGB(106, 74, 58), Color3.fromRGB(245, 205, 48),
})
local FLAT_SHIRTS = {
	Color3.fromRGB(13, 105, 172), Color3.fromRGB(196, 40, 28), Color3.fromRGB(75, 151, 75),
	Color3.fromRGB(245, 205, 48), Color3.fromRGB(107, 50, 124), Color3.fromRGB(255, 102, 204),
	Color3.fromRGB(17, 17, 17), Color3.fromRGB(242, 243, 243),
}
local FLAT_PANTS = {
	Color3.fromRGB(39, 70, 45), Color3.fromRGB(13, 105, 172), Color3.fromRGB(99, 95, 98),
	Color3.fromRGB(17, 17, 17), Color3.fromRGB(163, 75, 75),
}

local function one(pick: Random, list: { Item }): number
	return list[pick:NextInteger(1, #list)].id
end

local function colour(pick: Random, list: { Color3 }): Color3
	return list[pick:NextInteger(1, #list)]
end

-- A body in flat colours: the fallback, and the base every outfit is layered on.
function BotOutfits.plain(pick: Random): HumanoidDescription
	local description = Instance.new("HumanoidDescription")
	local skin = colour(pick, BotOutfits.SKIN :: any)
	description.HeadColor = skin
	description.LeftArmColor = skin
	description.RightArmColor = skin
	description.TorsoColor = colour(pick, FLAT_SHIRTS)
	local pants = colour(pick, FLAT_PANTS)
	description.LeftLegColor = pants
	description.RightLegColor = pants
	return description
end

--[[
	A random outfit. `pick` is seeded per bot, so the same bot looks the same on every client for the
	whole match. Every slot rolls on its own, so the combinations run to the hundreds of thousands.
]]
function BotOutfits.describe(pick: Random): HumanoidDescription
	local description = BotOutfits.plain(pick)
	local chance = BotOutfits.CHANCE
	local roll = pick:NextNumber()
	if roll < chance.palHair then
		description.HairAccessory = tostring(BotOutfits.PAL_HAIR)
	elseif roll < chance.hair then
		description.HairAccessory = tostring(one(pick, BotOutfits.HAIR))
	end
	if pick:NextNumber() < chance.hat then
		description.HatAccessory = tostring(one(pick, BotOutfits.HATS))
	end
	if pick:NextNumber() < chance.face then
		description.FaceAccessory = tostring(one(pick, BotOutfits.FACE))
	end
	if pick:NextNumber() < chance.neck then
		description.NeckAccessory = tostring(one(pick, BotOutfits.NECK))
	end
	if pick:NextNumber() < chance.back then
		description.BackAccessory = tostring(one(pick, BotOutfits.BACK))
	end
	if pick:NextNumber() < chance.shoulder then
		description.ShouldersAccessory = tostring(one(pick, BotOutfits.SHOULDER))
	end
	if pick:NextNumber() < chance.waist then
		description.WaistAccessory = tostring(one(pick, BotOutfits.WAIST))
	end
	if pick:NextNumber() < chance.clothes then
		description.Shirt = one(pick, BotOutfits.SHIRTS)
		description.Pants = one(pick, BotOutfits.PANTS)
	end
	return description
end

function BotOutfits.validate(): true
	local seen: { [number]: string } = {}
	for label, list in {
		HAIR = BotOutfits.HAIR, HATS = BotOutfits.HATS, SHIRTS = BotOutfits.SHIRTS,
		PANTS = BotOutfits.PANTS, FACE = BotOutfits.FACE, NECK = BotOutfits.NECK,
		BACK = BotOutfits.BACK, SHOULDER = BotOutfits.SHOULDER, WAIST = BotOutfits.WAIST,
	} do
		assert(#list >= 1, label .. " needs at least one item")
		for _, item in list do
			assert(item.id > 0 and item.id == math.floor(item.id), label .. " ids must be positive integers")
			assert(seen[item.id] == nil, string.format("%s: %d is listed twice", label, item.id))
			seen[item.id] = label
		end
	end
	assert(seen[BotOutfits.PAL_HAIR] == "HAIR", "Pal Hair must be one of the hairs")
	for name, value in BotOutfits.CHANCE do
		assert(value >= 0 and value <= 1, name .. " must be a probability")
	end
	assert(BotOutfits.CHANCE.palHair < BotOutfits.CHANCE.hair, "Pal Hair is a share of the hair roll")
	return true
end

BotOutfits.validate()

return BotOutfits
