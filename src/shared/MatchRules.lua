--!strict
--[[
	MatchRules — how a set of finished runs becomes a set of placings.

	SEPARATE FROM THE SERVICE ON PURPOSE. Ranking is the part of a match that decides who won, so it
	is the part worth testing directly, and a pure function over a list of entries can be tested
	without players, remotes, characters or a running server. `MatchService` is plumbing around this.

	THE RULE THE USER SET: points decide it, and dying does not remove you from contention. Your
	score stands after death. If nobody still playing beats it, you win from the grave. This is why
	ranking cannot short-circuit on "last one alive" — being alive is worth nothing by itself.

	THE CUT (2026-09-11): every minute the lowest runner still in is out (`cutCandidate`). It is
	decided here, as a pure function of the table, for the same reason ranking is.
]]

local MatchRules = {}

export type Entry = {
	userId: number,
	name: string,
	score: number,
	loops: number,
	tick: number,        -- simulation ticks the run lasted
	alive: boolean,
	deathReason: string?,
	-- Marked so the UI can say so. A player must be able to tell they were racing bots rather than
	-- be quietly allowed to believe they beat people.
	isBot: boolean?,
}

export type Placing = {
	place: number,
	userId: number,
	name: string,
	score: number,
	loops: number,
	tick: number,
	alive: boolean,
	deathReason: string?,
	isBot: boolean?,
}

--[[
	Ranks entries, best first.

	1. Higher score wins. That is the whole game.
	2. Ties break on FEWER TICKS: the same score reached faster is the better run. This needs no
	   extra state, is derived from the simulation both peers already agree on, and rewards the
	   thing the checkpoint curve is pushing players toward — scoring rate, not survival time.
	3. Still tied, break on userId. Never a coin flip: two runs that are genuinely identical must
	   produce the same order on every machine that ranks them, or a replay and a live match could
	   disagree about who won.

	`table.sort` is not stable in Luau, which is exactly why rule 3 exists rather than leaving equal
	entries to fall wherever the sort put them.
]]
function MatchRules.rank(entries: { Entry }): { Placing }
	local ordered = table.clone(entries)
	table.sort(ordered, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		if a.tick ~= b.tick then
			return a.tick < b.tick
		end
		return a.userId < b.userId
	end)

	local placings: { Placing } = {}
	for index, entry in ordered do
		placings[index] = {
			place = index,
			userId = entry.userId,
			name = entry.name,
			score = entry.score,
			loops = entry.loops,
			tick = entry.tick,
			alive = entry.alive,
			deathReason = entry.deathReason,
			isBot = entry.isBot,
		}
	end
	return placings
end

-- Strictly ahead of everyone else on score. Strictly, because a runner's tick only grows and a tie
-- breaks toward the faster run: a runner level on points is not yet safe.
local function leadsOutright(runner: { userId: number, score: number }, entries: { Entry }): boolean
	for _, other in entries do
		if other.userId ~= runner.userId and other.score >= runner.score then
			return false
		end
	end
	return true
end

--[[
	Can the match still change hands?

	Everyone finished: decided. Two or more runners still in: not decided -- the rope or the next cut
	will settle it. Exactly ONE runner still in: they have won the moment they lead outright, since
	nobody who has finished can score again. Until then they are racing a fallen leader's standing
	score, and the next cut ends it either way (`cutCandidate`).

	WHY THIS NOW ENDS EVERY MATCH (the per-minute cut, 2026-09-11). Each cut removes a runner, and a
	lone runner is either already winning or cut at the next minute, so a match of N is decided within
	N cuts whatever anyone builds. That bound used to come from the checkpoint curve.
]]
function MatchRules.isDecided(entries: { Entry }, finished: { [number]: boolean }): boolean
	local runner: Entry? = nil
	local stillIn = 0
	for _, entry in entries do
		if not finished[entry.userId] then
			stillIn += 1
			runner = entry
		end
	end
	if stillIn == 0 then
		return true
	end
	if stillIn > 1 then
		return false
	end
	return leadsOutright(runner :: Entry, entries)
end

--[[
	Who the next cut removes (the user, 2026-09-11: "every minute it should eliminate one player... the
	player with the least amount of points gets eliminated"): the lowest-placed runner still in, placed
	by the same `rank` the live table and the result use, so a cut always takes the bottom row of the
	table everyone is watching. Someone who has finished -- to the rope, or to an earlier cut -- is never
	cut again; their score stands.

	A LONE RUNNER is cut only while someone who has finished still leads them: they had the minute to
	catch up and did not. Leading outright, they are not cut -- `isDecided` has already given them the
	match. Nil when nobody is cut.
]]
function MatchRules.cutCandidate(entries: { Entry }, finished: { [number]: boolean }): Placing?
	local ranked = MatchRules.rank(entries)
	local stillIn: { Placing } = {}
	for _, placing in ranked do
		if not finished[placing.userId] then
			table.insert(stillIn, placing)
		end
	end
	if #stillIn >= 2 then
		return stillIn[#stillIn]
	end
	local last = stillIn[1]
	if last and not leadsOutright(last, entries) then
		return last
	end
	return nil
end

-- The live table shown while playing. Same ordering as the final placings, so the scoreboard a
-- player watches all match is the one that decides it — no reordering surprise at the end.
function MatchRules.liveTable(entries: { Entry }): { Placing }
	return MatchRules.rank(entries)
end

function MatchRules.validate(): true
	-- The load-time proof of the one rule a player would notice being broken: the dead leader wins.
	-- userId 1 is dead with the top score; userId 2 is still playing on a lower one.
	local graveyard: { Entry } = {
		{ userId = 2, name = "b", score = 30, loops = 7, tick = 500, alive = true },
		{ userId = 1, name = "a", score = 40, loops = 9, tick = 600, alive = false },
	}
	local ranked = MatchRules.rank(graveyard)
	assert(ranked[1].userId == 1 and not ranked[1].alive,
		"a dead player with the highest score must still be winning")

	-- Equal scores break toward the faster run, then toward the lower userId, never toward chance.
	local tied: { Entry } = {
		{ userId = 3, name = "c", score = 40, loops = 9, tick = 600, alive = false },
		{ userId = 1, name = "a", score = 40, loops = 9, tick = 500, alive = false },
		{ userId = 2, name = "b", score = 40, loops = 9, tick = 500, alive = false },
	}
	local order = MatchRules.rank(tied)
	assert(order[1].userId == 1 and order[2].userId == 2 and order[3].userId == 3,
		"ties must resolve identically on every machine that ranks them")

	-- The cut takes the bottom runner still in, never someone already finished.
	local field: { Entry } = {
		{ userId = 1, name = "a", score = 50, loops = 9, tick = 900, alive = true },
		{ userId = 2, name = "b", score = 5, loops = 2, tick = 300, alive = false },
		{ userId = 3, name = "c", score = 20, loops = 5, tick = 900, alive = true },
	}
	local cut = MatchRules.cutCandidate(field, { [2] = true })
	assert(cut ~= nil and cut.userId == 3, "the cut must take the lowest runner still in")

	-- A lone runner behind a fallen leader is cut; leading outright, they have won instead.
	local chasing = MatchRules.cutCandidate(graveyard, { [1] = true })
	assert(chasing ~= nil and chasing.userId == 2 and not MatchRules.isDecided(graveyard, { [1] = true }),
		"a lone runner behind the fallen leader must be cut, not crowned")
	local ahead: { Entry } = {
		{ userId = 1, name = "a", score = 40, loops = 9, tick = 600, alive = false },
		{ userId = 2, name = "b", score = 41, loops = 9, tick = 500, alive = true },
	}
	assert(MatchRules.cutCandidate(ahead, { [1] = true }) == nil and MatchRules.isDecided(ahead, { [1] = true }),
		"a lone runner leading outright has already won")
	return true
end

MatchRules.validate()

return table.freeze(MatchRules)
