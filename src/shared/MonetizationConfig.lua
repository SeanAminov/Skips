--!strict
--[[
	MonetizationConfig — tickets, the one thing this game sells, and what a revive costs in them.

	TICKETS REPLACED THE ROBUX REVIVE on 2026-09-10 (the user: "hook up UI with the tickets and
	replace roblox revive payment"). A revive used to open Roblox's purchase prompt inside the five
	seconds a player has to decide; tickets are bought beforehand, in packs, and spent in-game with no
	prompt in the way. On 2026-09-11 the user set the pack ladder: 1 / 2 / 3 / 5 tickets for
	5 / 10 / 15 / 20 Robux.

	TICKETS BUY EXACTLY TWO THINGS (the user, 2026-09-11: "Splat and revive should be the only things.
	Splat should be 1 ticket and revive two tickets."). A revive at two tickets is the old 10 Robux
	revive at the two-pack's price. "+1000 points" and "reset an opponent's upgrades" were proposed
	and dropped by the same message; a third use is a new decision for the user, and suite §19 fails
	if a third server file starts spending tickets.

	PRICES ARE OWNED BY CREATOR DASHBOARD, NOT BY LUAU. `priceRobux` only records what a pack is meant
	to cost and labels the shop; `PurchaseService` reads each real price back with `GetProductInfo` at
	startup and warns when the two disagree.

	A PACK WITH PRODUCT ID 0 IS NEVER OFFERED. That is how a new pack is staged before its Developer
	Product exists.

	NOTHING ELSE IS FOR SALE. No paid cards, Luck, odds or multipliers. A new
	use for tickets is a new decision for the user, not a row added here.
]]

export type Pack = {
	id: string,
	productId: number,
	iconAssetId: number,
	tickets: number,
	priceRobux: number,
}

local MonetizationConfig = {
	--[[
		These four products were verified live against this experience on 2026-09-11. Receipt grants
		look up this table on the server; the client only uses it to draw the shop and open Roblox's
		own checkout. The five-pack is the value pack at 4 Robux per ticket.
	]]
	TICKET_PACKS = table.freeze({
		table.freeze({ id = "TICKETS_1", productId = 3712026681, iconAssetId = 119231224894642,
			tickets = 1, priceRobux = 5 }),
		table.freeze({ id = "TICKETS_2", productId = 3712424111, iconAssetId = 128979012571609,
			tickets = 2, priceRobux = 10 }),
		table.freeze({ id = "TICKETS_3", productId = 3712424157, iconAssetId = 91991179212933,
			tickets = 3, priceRobux = 15 }),
		table.freeze({ id = "TICKETS_5", productId = 3712424214, iconAssetId = 80844318121505,
			tickets = 5, priceRobux = 20 }),
	}) :: { Pack },
	BASE_TICKET_PRICE_ROBUX = 5,
	REVIVE_TICKET_COST = 2,
	-- One splat covering every eligible opponent in the current match (DistractionService), charged
	-- once before any effect appears.
	SPLAT_TICKET_COST = 1,
	MIN_REVIVE_SKIPS = 10,
	REVIVE_OFFER_SECONDS = 5,
	-- A DEADLINE, not a wait. The player taps to go the instant their hands are back on the
	-- controls; this is only how long the game waits before starting without them, so a revived run
	-- can never sit frozen -- which in a match would quietly cost them the whole thing.
	REVIVE_RESUME_COUNTDOWN_SECONDS = 5,
	-- How long a dead run waits while its player is in the ticket shop buying the ticket to revive
	-- it. Roblox's purchase prompt can take a while to read; the run must not expire underneath it.
	REVIVE_SHOPPING_SECONDS = 120,
	-- How long a dead run waits while its ticket is taken from the store.
	REVIVE_SPEND_HOLD_SECONDS = 30,
}

function MonetizationConfig.packForProduct(productId: number): Pack?
	for _, pack in MonetizationConfig.TICKET_PACKS do
		if pack.productId > 0 and pack.productId == productId then
			return pack
		end
	end
	return nil
end

-- The packs that can actually be bought right now.
function MonetizationConfig.offeredPacks(): { Pack }
	local offered: { Pack } = {}
	for _, pack in MonetizationConfig.TICKET_PACKS do
		if pack.productId > 0 then
			table.insert(offered, pack)
		end
	end
	return offered
end

function MonetizationConfig.validate(): true
	local ids: { [string]: boolean } = {}
	local products: { [number]: boolean } = {}
	local previousTickets = 0
	local previousUnitPrice = math.huge
	for index, pack in MonetizationConfig.TICKET_PACKS do
		assert(pack.id ~= "" and not ids[pack.id], string.format("ticket pack %d needs a unique id", index))
		ids[pack.id] = true
		assert(pack.productId >= 0 and pack.productId == math.floor(pack.productId),
			pack.id .. " productId must be a non-negative integer")
		if pack.productId > 0 then
			assert(not products[pack.productId], pack.id .. " shares a product id with another pack")
			products[pack.productId] = true
		end
		assert(pack.iconAssetId > 0 and pack.iconAssetId == math.floor(pack.iconAssetId),
			pack.id .. " needs the uploaded Developer Product icon")
		assert(pack.tickets >= 1 and pack.tickets == math.floor(pack.tickets), pack.id .. " must sell whole tickets")
		assert(pack.priceRobux >= 1 and pack.priceRobux == math.floor(pack.priceRobux),
			pack.id .. " must cost a whole positive number of Robux")
		assert(pack.tickets > previousTickets, "ticket packs must stay in ascending quantity order")
		local unitPrice = pack.priceRobux / pack.tickets
		assert(unitPrice <= previousUnitPrice, pack.id .. " must not be worse value than the smaller pack")
		previousTickets = pack.tickets
		previousUnitPrice = unitPrice
	end
	assert(#MonetizationConfig.TICKET_PACKS == 4, "the approved shop has four ticket packs")
	assert(MonetizationConfig.BASE_TICKET_PRICE_ROBUX == 5, "one ticket must cost the approved 5 Robux")
	assert(MonetizationConfig.TICKET_PACKS[1].tickets == 1
		and MonetizationConfig.TICKET_PACKS[1].priceRobux == MonetizationConfig.BASE_TICKET_PRICE_ROBUX,
		"the first pack must establish the one-ticket price")
	assert(MonetizationConfig.REVIVE_TICKET_COST == 2, "the approved revive price is two tickets")
	assert(MonetizationConfig.SPLAT_TICKET_COST == 1, "the approved splat price is one ticket")
	assert(MonetizationConfig.MIN_REVIVE_SKIPS >= 10, "a revive must never be offered before ten skips")
	assert(MonetizationConfig.REVIVE_OFFER_SECONDS == 5, "the approved revive decision window is five seconds")
	assert(MonetizationConfig.REVIVE_RESUME_COUNTDOWN_SECONDS == 5,
		"a revived run needs the approved five-second get-ready")
	assert(MonetizationConfig.REVIVE_SHOPPING_SECONDS > MonetizationConfig.REVIVE_OFFER_SECONDS,
		"shopping for a ticket must hold the run longer than the decision window")
	assert(MonetizationConfig.REVIVE_SPEND_HOLD_SECONDS > 0, "taking a ticket must hold the run")
	return true
end

MonetizationConfig.validate()
return table.freeze(MonetizationConfig)
