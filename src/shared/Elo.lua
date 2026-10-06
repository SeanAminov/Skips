--!strict
--[[
	Elo — ratings for ranked play, done the way chess does it.

	THE FORMULA IS THE STANDARD ONE (Arpad Elo, as FIDE uses it). The expected score of A against B is
	    E(A) = 1 / (1 + 10 ^ ((R(B) - R(A)) / 400))
	and after a game
	    R(A)' = R(A) + K * (S(A) - E(A))
	with S = 1 for a win, 0.5 for a draw, 0 for a loss. Beat someone rated above you and you gain a
	lot; beat someone far below you and you gain almost nothing. Nothing here is invented.

	START AT 100 — the user's number. The absolute value is arbitrary in Elo; only differences mean
	anything, so 100 changes what the numbers look like, not how the system behaves.

	K-FACTOR, FIDE-STYLE: 40 for a player's first 20 rated matches, so a newcomer reaches their real
	level quickly instead of grinding up from 100; 20 after that, so an established rating is stable
	and one bad match does not undo a week.

	FLOORED AT ZERO. A negative rating reads as a bug to a player. The cost is a little inflation at
	the very bottom, which is the standard trade and far cheaper than explaining "-37" to a nine-year-old.

	MORE THAN TWO PLAYERS. Chess Elo is one-on-one, and a ranked lobby has up to eight. So a lobby is
	scored as every PAIR of players having played one game, decided by who finished higher; each
	player's K is divided by (N - 1) so an eight-player lobby moves a rating about as much as one
	duel rather than seven. For N = 2 this is exactly ordinary Elo.

	WHO BEAT WHOM IS THE MATCH RULE, NOT A NEW ONE. Higher score wins; equal scores go to the faster
	run (fewer ticks), as `MatchRules` ranks them. The one difference: two runs identical in both
	score and ticks are a DRAW here (0.5 each). `MatchRules` breaks that final tie by userId purely so
	placings display in a stable order — an account number must never decide a rating.

	PURE AND DETERMINISTIC: no DataStores, no clock, no players. Persistence is `RatingService`'s job.
]]

local Elo = {}

Elo.START = 100
Elo.SCALE = 400
Elo.K_PROVISIONAL = 40
Elo.PROVISIONAL_GAMES = 20
Elo.K_ESTABLISHED = 20
Elo.FLOOR = 0

export type Rated = {
	userId: number,
	rating: number,
	games: number, -- rated matches played BEFORE this one
	score: number,
	tick: number,
}

export type Change = {
	userId: number,
	before: number,
	after: number,
	delta: number,
}

-- The chance, from 0 to 1, that a player rated `rating` beats one rated `opponent`.
function Elo.expected(rating: number, opponent: number): number
	return 1 / (1 + 10 ^ ((opponent - rating) / Elo.SCALE))
end

function Elo.kFactor(games: number): number
	return if games < Elo.PROVISIONAL_GAMES then Elo.K_PROVISIONAL else Elo.K_ESTABLISHED
end

-- 1 if `a` finished above `b`, 0 if below, 0.5 only if the two runs are identical.
function Elo.outcome(a: Rated, b: Rated): number
	if a.score ~= b.score then
		return if a.score > b.score then 1 else 0
	end
	if a.tick ~= b.tick then
		return if a.tick < b.tick then 1 else 0
	end
	return 0.5
end

--[[
	New ratings for every player in one finished ranked match.

	Ratings come back as whole numbers, because they are stored in an OrderedDataStore, which only
	holds integers. Rounding happens once per match on the final value, never on the intermediate
	pairwise terms, so a lobby's rounding error is one point at most.
]]
function Elo.rate(players: { Rated }): { Change }
	local count = #players
	local changes: { Change } = {}
	for i, a in players do
		local surplus = 0
		for j, b in players do
			if i ~= j then
				surplus += Elo.outcome(a, b) - Elo.expected(a.rating, b.rating)
			end
		end
		local k = Elo.kFactor(a.games) / math.max(1, count - 1)
		local after = math.floor(math.max(Elo.FLOOR, a.rating + k * surplus) + 0.5)
		changes[i] = {
			userId = a.userId,
			before = a.rating,
			after = after,
			delta = after - a.rating,
		}
	end
	return changes
end

function Elo.validate(): true
	assert(Elo.START >= Elo.FLOOR, "players must start at or above the floor")
	assert(Elo.SCALE > 0, "the Elo scale must be positive")
	assert(Elo.K_PROVISIONAL >= Elo.K_ESTABLISHED and Elo.K_ESTABLISHED > 0,
		"a provisional K must move ratings at least as fast as an established one")
	assert(math.abs(Elo.expected(Elo.START, Elo.START) - 0.5) < 1e-9,
		"two equal ratings must be a coin flip")
	assert(math.abs(Elo.expected(150, 90) + Elo.expected(90, 150) - 1) < 1e-9,
		"the two sides' expectations must add up to one")
	-- The duel sanity check: equal players, one win, and the two changes cancel exactly.
	local duel = Elo.rate({
		{ userId = 1, rating = Elo.START, games = 0, score = 30, tick = 900 },
		{ userId = 2, rating = Elo.START, games = 0, score = 12, tick = 600 },
	})
	assert(duel[1].delta > 0 and duel[1].delta == -duel[2].delta,
		"between equals, the winner's gain must be exactly the loser's loss")
	return true
end

Elo.validate()

return table.freeze(Elo)
