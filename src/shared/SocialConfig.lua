--!strict
--[[
	SocialConfig — the official Skips community and the once-per-account social reward.

	GROUP MEMBERSHIP IS THE ONLY VERIFIABLE SOCIAL ACTION. Roblox has no server API that proves a
	player liked the experience, so the UI asks for a thumbs-up and a community join, but the server
	only pays after `Player:IsInGroupAsync` confirms membership. Presenting an unverifiable Like as
	a verified claim would be exploitable and dishonest.

	The group id is public (it appears in the community URL). Ticket amounts shown to the client are
	display-only; the server re-reads this module when it pays.
]]

local SocialConfig = {}

-- https://www.roblox.com/share/g/213823349 — set by the user on 2026-09-11.
SocialConfig.GROUP_ID = 213823349

-- Like (honor) + verified Join, once per account. Paid only after membership is confirmed.
SocialConfig.GROUP_REWARD_TICKETS = 2

-- Client claim presses are throttled the same way codes are.
SocialConfig.CLAIM_ATTEMPTS_PER_MINUTE = 6

function SocialConfig.validate(): true
	assert(SocialConfig.GROUP_ID == math.floor(SocialConfig.GROUP_ID) and SocialConfig.GROUP_ID > 0,
		"GROUP_ID must be a positive whole number from the live community URL")
	assert(SocialConfig.GROUP_REWARD_TICKETS >= 1
		and SocialConfig.GROUP_REWARD_TICKETS == math.floor(SocialConfig.GROUP_REWARD_TICKETS),
		"GROUP_REWARD_TICKETS must be a whole number of tickets")
	assert(SocialConfig.CLAIM_ATTEMPTS_PER_MINUTE >= 1, "a player must be able to try at least one claim")
	return true
end

SocialConfig.validate()

return table.freeze(SocialConfig)
