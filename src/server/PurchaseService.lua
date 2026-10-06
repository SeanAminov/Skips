--!strict
--[[
	PurchaseService — Roblox receipts in, tickets out. The ONLY place anything bought is granted.

	`MarketplaceService.ProcessReceipt` is the one authoritative purchase signal. The client's
	purchase-finished event says only that a prompt closed, never that Robux changed hands, so nothing
	on the server listens to it.

	A RECEIPT IS GRANTED ONLY ONCE THE TICKETS ARE SAVED. If the store cannot record them right now the
	answer is NotProcessedYet, and Roblox offers the receipt again later -- the next time the player
	joins any server, at the latest. So a player is never charged for tickets that were not kept, and
	because the grant is keyed by the purchase id, never given them twice either.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MonetizationConfig = require(Shared:WaitForChild("MonetizationConfig"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))

local PurchaseService = {}

function PurchaseService.start()
	MarketplaceService.ProcessReceipt = function(receiptInfo)
		local pack = MonetizationConfig.packForProduct(receiptInfo.ProductId)
		if not pack then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		local granted = PlayerDataService.grantTickets(receiptInfo.PlayerId, pack.tickets,
			"purchase:" .. tostring(receiptInfo.PurchaseId))
		return if granted
			then Enum.ProductPurchaseDecision.PurchaseGranted
			else Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Prices live on the Creator Dashboard. A price edited there and forgotten here shows up in the
	-- output rather than in the earnings report.
	task.spawn(function()
		for _, pack in MonetizationConfig.offeredPacks() do
			local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService,
				pack.productId, Enum.InfoType.Product)
			if not ok then
				warn(string.format("[Skips] could not verify ticket pack %s (%d): %s",
					pack.id, pack.productId, tostring(info)))
			elseif typeof(info) == "table" and typeof((info :: any).PriceInRobux) == "number"
				and (info :: any).PriceInRobux ~= pack.priceRobux then
				warn(string.format("[Skips] ticket pack %s costs %d Robux on the dashboard; the game says %d",
					pack.id, (info :: any).PriceInRobux, pack.priceRobux))
			end
		end
	end)
end

return PurchaseService
