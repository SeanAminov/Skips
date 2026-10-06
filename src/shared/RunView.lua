--!strict
--[[
	RunView — what an onlooker may see of a run: a small flat value made from its state.

	Pure and read-only. Everything a ghost needs to be drawn -- how high it is, whether it is rising,
	where each rope is in its turn, which ropes burn, whether a guard is up, the score -- and nothing
	that would let anyone reconstruct inputs or cards. Used by the server for players' runs and for
	bots alike, so the two produce identical shapes.
]]

local RunView = {}

export type View = {
	tick: number,
	y: number,
	grounded: boolean,
	rising: boolean,
	alive: boolean,
	score: number,
	burning: number, -- first N ropes burn; each Ignite consumes one distinct rope
	guarded: { boolean }, -- per rope: a Reinforce guard is on it
	period: number,
	ropes: { number },
}

function RunView.of(run: any): View
	local ropes: { number } = {}
	local guarded: { boolean } = {}
	for index, rope in run.ropes do
		ropes[index] = rope.nextSweepTick
		guarded[index] = (rope.guards or 0) > 0
	end
	return {
		tick = run.tick,
		-- Centimetre precision is far below what a lane view can show, and keeps the packet small.
		y = math.floor(run.y * 100 + 0.5) / 100,
		grounded = run.grounded,
		rising = run.vy > 0,
		alive = run.alive,
		score = run.score,
		burning = math.max(0, run.stats.scorePerLoop - 1),
		guarded = guarded,
		period = run.stats.ropePeriodTicks,
		ropes = ropes,
	}
end

return RunView
