--!strict
--[[
	CodeConfig — the codes players can redeem in Settings, and what each is worth.

	SERVER ONLY, ON PURPOSE. This file lives in ServerScriptService, which Roblox never sends to a
	client, so a code cannot be read out of the game before it is announced.

	ADDING A CODE IS A ROW:
	    RELEASE = { tickets = 2 },
	    WEEKEND = { tickets = 1, expiresUtc = os.time({ year = 2026, month = 10, day = 1, hour = 0 }) },
	Codes are matched in capitals with spaces removed, so "release", " Release " and "RELEASE" are one
	code. Each account can redeem each code once, recorded on the account itself.

	Tickets are money: every code here is tickets given away. Which codes exist,
	and how generous they are, is the user's call.
]]

export type Code = {
	tickets: number,
	expiresUtc: number?, -- os.time() after which the code stops working; nil never expires
	studioOnly: boolean?, -- redeemable in Studio only, for testing the flow end to end
}

local CodeConfig: { [string]: Code } = {
	-- Launch code: twenty tickets, once, no expiry.
	FRIEND = { tickets = 20 },
}

for code, entry in CodeConfig do
	assert(code:match("^[%u%d]+$") ~= nil, "codes are capitals and digits only: " .. code)
	assert(entry.tickets >= 1 and entry.tickets == math.floor(entry.tickets),
		code .. " must grant a whole number of tickets")
	table.freeze(entry)
end

return table.freeze(CodeConfig)
