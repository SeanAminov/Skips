--!strict
--[[
	Rng — a deterministic pseudo-random generator, written out by hand.

	WHY NOT `Random.new(seed)`:
	Roblox's Random is seeded and is almost certainly identical across client and server today.
	"Almost certainly" is the problem. The design requires that the same seed and the
	same inputs reproduce a run exactly, on both peers, forever — that is what makes the
	leaderboard defensible and replays possible. Depending on an engine implementation detail to
	hold that guarantee means a Roblox update could silently invalidate every stored run. Thirty
	lines of xorshift removes the dependency entirely.

	`math.random` is worse still: it is process-global, so any other code calling it would shift
	this run's stream.

	xorshift32 (Marsaglia 2003), period 2^32 - 1. Not cryptographic and not meant to be — it picks
	which three of ten cards you are offered. What it must be is *identical everywhere*, and
	integer arithmetic through bit32 makes it so.
]]

local Rng = {}
Rng.__index = Rng

export type Rng = typeof(setmetatable(
	{} :: { state: number },
	{} :: { __index: typeof(Rng) }
))

local UINT32 = 4294967296

--[[
	Any integer seed is accepted. Zero is the one state xorshift cannot leave — it maps to itself
	forever — so it is remapped rather than rejected: a caller passing 0 wants a usable stream, and
	erroring on it would turn a harmless input into a crashed run.
]]
function Rng.new(seed: number): Rng
	local s = math.floor(seed) % UINT32
	if s < 0 then
		s += UINT32
	end
	if s == 0 then
		s = 2463534242 -- Marsaglia's own suggested default
	end
	return setmetatable({ state = s }, Rng) :: any
end

-- Next 32-bit unsigned integer. The shift triple (13, 17, 5) is the canonical one; other triples
-- work but this is the tested pairing and there is no reason to invent another.
function Rng.nextUint(self: Rng): number
	local x = self.state
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	x = bit32.bxor(x, bit32.lshift(x, 5))
	self.state = x
	return x
end

-- Float in [0, 1).
function Rng.nextFloat(self: Rng): number
	return self:nextUint() / UINT32
end

--[[
	Integer in [min, max] inclusive.

	Uses rejection sampling rather than a plain modulo. Modulo is biased whenever the range does
	not divide 2^32 — for a 3-of-10 card offer the bias is small, but the design rules say
	displayed odds must be the odds actually rolled, and a modulo would quietly make that false.
	The loop terminates with probability 1 and in practice almost always on the first draw.
]]
function Rng.nextInt(self: Rng, min: number, max: number): number
	assert(max >= min, "Rng.nextInt: max must be >= min")
	local span = max - min + 1
	local limit = UINT32 - (UINT32 % span) -- largest multiple of span that fits
	local v = self:nextUint()
	while v >= limit do
		v = self:nextUint()
	end
	return min + (v % span)
end

--[[
	Fisher-Yates, in place, drawing from this stream. Used by the card offer: shuffle the eligible
	deck and take the first three, so the three offered are drawn from one roll rather than three
	independent ones that could collide.
]]
function Rng.shuffle<T>(self: Rng, list: { T }): { T }
	for i = #list, 2, -1 do
		local j = self:nextInt(1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

-- A copy that advances independently. Lets a caller look ahead without disturbing the run's own
-- stream — the alternative is accidentally consuming a draw the run was going to make.
function Rng.clone(self: Rng): Rng
	return setmetatable({ state = self.state }, Rng) :: any
end

return Rng
