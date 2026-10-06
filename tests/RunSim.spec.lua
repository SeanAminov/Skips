--!strict
--[[
	Deterministic run and Stage 2 verification suite for RunSim, tuning, RNG and cards.

	HOW TO RUN IT. This file deliberately does NOT live in `src/`, because it must never ship. To
	run it, copy it to `src/shared/_Spec.lua`, let Rojo sync, require it in Studio and call the
	returned function, then delete the copy:

	    cp tests/RunSim.spec.lua src/shared/_Spec.lua
	    -- in Studio (Edit): require(ReplicatedStorage.Shared._Spec)()
	    rm src/shared/_Spec.lua

	WHAT THIS SUITE CAN AND CANNOT PROVE. It executes the real module
	against real inputs, so it proves the arc, loop counting, death, upgrade cadence, RNG, card effects,
	forged-pick membership and — most importantly — deterministic replay. It proves nothing about
	whether the jump or timed card selector *feels* right. Those questions need human input.
]]

return function()
	local Shared = script.Parent
	local RunSim = require(Shared:WaitForChild("RunSim"))
	local SimTuning = require(Shared:WaitForChild("SimTuning"))
	local Rng = require(Shared:WaitForChild("Rng"))
	local RunProtocol = require(Shared:WaitForChild("RunProtocol"))
	local CardCatalog = require(Shared:WaitForChild("CardCatalog"))
	local MonetizationConfig = require(Shared:WaitForChild("MonetizationConfig"))
	local MatchTuning = require(Shared:WaitForChild("MatchTuning"))
	local MatchProtocol = require(Shared:WaitForChild("MatchProtocol"))
	local MatchRules = require(Shared:WaitForChild("MatchRules"))
	local BotPolicy = require(Shared:WaitForChild("BotPolicy"))
	local Leaderboards = require(Shared:WaitForChild("Leaderboards"))
	local Distraction = require(Shared:WaitForChild("Distraction"))
	local Elo = require(Shared:WaitForChild("Elo"))
	local PlayerProtocol = require(Shared:WaitForChild("PlayerProtocol"))

	local passed, failed = 0, 0
	local lines: { string } = {}

	local function log(s: string)
		table.insert(lines, s)
	end

	local function check(name: string, ok: boolean, detail: string?)
		if ok then
			passed += 1
			log(string.format("  PASS  %s%s", name, detail and ("   " .. detail) or ""))
		else
			failed += 1
			log(string.format("  FAIL  %s%s", name, detail and ("   " .. detail) or ""))
		end
	end

	local function near(a: number, b: number, tolerance: number): boolean
		return math.abs(a - b) <= tolerance
	end

	-- Physics tests need the rope out of the way; a sweep mid-arc would end the run before the
	-- apex. This is a test fixture, not a tuning opinion.
	local NO_ROPE = { ropePeriodTicks = 1000000 }

	--[[
		Steps a run with a scripted hold and reports the arc.
		`holdTicks == 0` is a tap: pressed on tick 1, released on tick 2.
	]]
	local function jumpArc(holdTicks: number): (number, number, number)
		local run = RunSim.new(1, NO_ROPE)
		local apex, jumpTick, landTick = 0, 0, 0
		for t = 1, 400 do
			local down = t >= 1 and t <= math.max(holdTicks, 1)
			local events = run:step(down)
			apex = math.max(apex, run.y)
			if events then
				for _, e in events do
					if e.kind == RunSim.EVENT.JUMP then
						jumpTick = e.tick
					elseif e.kind == RunSim.EVENT.LAND then
						landTick = e.tick
					end
				end
			end
			if landTick > 0 then
				break
			end
		end
		return apex, landTick - jumpTick, landTick
	end

	-- ── 1. definitions validate ──────────────────────────────────────────────────────────────
	log("\n[1] definitions")
	check("SimTuning.validate() passes", (SimTuning.validate()) == true)
	check("DT is exactly 1/TICK_RATE", SimTuning.DT == 1 / SimTuning.TICK_RATE)
	check("NOMINAL_HEIGHT matches the measured place setting (5.5)",
		SimTuning.NOMINAL_HEIGHT == 5.5, string.format("got %.3f", SimTuning.NOMINAL_HEIGHT))
	check("the opening rope cadence is 2 seconds",
		SimTuning.baseStats().ropePeriodTicks == 120,
		string.format("got %d ticks", SimTuning.baseStats().ropePeriodTicks))
	check("the first visible ground sweep is judged instead of being a fake rotation",
		SimTuning.GRACE_TICKS == 89, string.format("first judged tick %d", SimTuning.GRACE_TICKS + 1))
	-- Five keeps the opening offer quick. The 1.1 growth factor raises later targets gently.
	check("upgrade targets grow exponentially with each completed offer",
		SimTuning.upgradeProgressRequired(0) == 5
			and SimTuning.upgradeProgressRequired(1) == 5
			and SimTuning.upgradeProgressRequired(2) == 6
			and SimTuning.upgradeProgressRequired(3) == 6
			and SimTuning.upgradeProgressRequired(4) == 7
			and SimTuning.upgradeProgressRequired(5) == 8
			and SimTuning.upgradeProgressRequired(10) == 12
			and SimTuning.upgradeProgressRequired(10) > SimTuning.upgradeProgressRequired(5))
	check("the gentle curve may repeat an integer target but never gets cheaper",
		(function()
			local previous = SimTuning.upgradeProgressRequired(0)
			for round = 1, 100 do
				local required = SimTuning.upgradeProgressRequired(round)
				if required < previous then return false end
				previous = required
			end
			return true
		end)())
	check("RunProtocol.validate() passes", (RunProtocol.validate()) == true)
	check("sound uses a continuous saved zero-to-one range",
		(PlayerProtocol.validate()) == true
			and PlayerProtocol.DEFAULT_SOUND == 1
			and PlayerProtocol.normaliseSound(-1) == 0
			and math.abs(PlayerProtocol.normaliseSound(0.376) - 0.38) < 1e-9
			and PlayerProtocol.normaliseSound(2) == 1)
	-- Tickets replaced the Robux revive on 2026-09-10. On 2026-09-11 the user approved four packs
	-- starting at 5 Robux per ticket, with the five-pack carrying the only volume discount, and set
	-- what tickets buy: a revive for two, a splat for one, nothing else. The ten-skip gate and the two
	-- five-second windows around a revive remain unchanged.
	check("tickets keep the approved prices, and the revive its gate and windows",
		MonetizationConfig.validate() == true
			and MonetizationConfig.REVIVE_TICKET_COST == 2
			and MonetizationConfig.SPLAT_TICKET_COST == 1
			and MonetizationConfig.BASE_TICKET_PRICE_ROBUX == 5
			and #MonetizationConfig.offeredPacks() == 4
			and MonetizationConfig.MIN_REVIVE_SKIPS == 10
			and MonetizationConfig.REVIVE_OFFER_SECONDS == 5
			and MonetizationConfig.REVIVE_RESUME_COUNTDOWN_SECONDS == 5,
		string.format("%d pack(s), a revive costs %d tickets, after %d skips",
			#MonetizationConfig.offeredPacks(), MonetizationConfig.REVIVE_TICKET_COST,
			MonetizationConfig.MIN_REVIVE_SKIPS))
	check("the accepted future window exceeds the authority delay",
		RunProtocol.MAX_FUTURE_TICKS > RunProtocol.AUTHORITY_DELAY_TICKS)

	-- ── 2. Rng ───────────────────────────────────────────────────────────────────────────────
	log("\n[2] Rng")
	do
		local a, b = Rng.new(12345), Rng.new(12345)
		local same = true
		for _ = 1, 500 do
			if a:nextUint() ~= b:nextUint() then
				same = false
				break
			end
		end
		check("same seed produces the same stream", same)

		local c, d = Rng.new(1), Rng.new(2)
		check("different seeds diverge", c:nextUint() ~= d:nextUint())

		local r = Rng.new(999)
		local inRange, lo, hi = true, math.huge, -math.huge
		local buckets = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
		for _ = 1, 20000 do
			local v = r:nextInt(1, 10)
			if v < 1 or v > 10 or v ~= math.floor(v) then
				inRange = false
			end
			lo, hi = math.min(lo, v), math.max(hi, v)
			buckets[v] += 1
		end
		check("nextInt(1,10) stays in range", inRange, string.format("observed %d..%d", lo, hi))

		-- 20000 draws over 10 buckets: 2000 expected each. A fair generator will not stray far;
		-- this catches a modulo-bias regression, which is the realistic failure here.
		local worst = 0
		for _, n in buckets do
			worst = math.max(worst, math.abs(n - 2000))
		end
		check("nextInt is not visibly biased", worst < 200, string.format("worst bucket off by %d of 2000", worst))

		local seedZero = Rng.new(0)
		check("seed 0 does not produce a dead stream", seedZero:nextUint() ~= 0)

		local list = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
		Rng.new(7):shuffle(list)
		local sum, seen = 0, {}
		for _, v in list do
			sum += v
			seen[v] = true
		end
		local allPresent = true
		for i = 1, 10 do
			if not seen[i] then
				allPresent = false
			end
		end
		check("shuffle keeps every element exactly once", sum == 55 and allPresent and #list == 10)

		local original = Rng.new(42)
		original:nextUint()
		local copy = original:clone()
		check("clone continues the same stream without consuming it",
			copy:nextUint() == original:nextUint())
	end

	-- ── 3. the jump arc ──────────────────────────────────────────────────────────────────────
	log("\n[3] jump arc")
	do
		local tapApex, tapAir = jumpArc(0)
		check("tap apex is a small hop", tapApex > 1.0 and tapApex < 1.5,
			string.format("apex %.3f studs", tapApex))
		check("tap airtime is about 24 ticks", tapAir >= 20 and tapAir <= 28,
			string.format("%d ticks (%.2f s)", tapAir, tapAir / SimTuning.TICK_RATE))

		local fullApex, fullAir = jumpArc(60) -- longer than maxHoldTicks: the window expires
		check("full hold apex clears the body's own height", fullApex > 3.5 and fullApex < 4.5,
			string.format("apex %.3f studs", fullApex))
		check("full hold airtime is about 56 ticks", fullAir >= 48 and fullAir <= 62,
			string.format("%d ticks (%.2f s)", fullAir, fullAir / SimTuning.TICK_RATE))

		check("holding beats tapping", fullApex > tapApex * 2.5,
			string.format("%.3f vs %.3f", fullApex, tapApex))

		-- The hold must be CONTINUOUS (§5): every extra tick held buys height, with no plateau or
		-- step. A card that widened the window would be a placebo if this were not monotonic.
		local monotonic, prevApex = true, -1
		local samples = {}
		for _, h in { 0, 5, 10, 15, 20, 25, 30 } do
			local apex = jumpArc(h)
			table.insert(samples, string.format("%d:%.2f", h, apex))
			if apex <= prevApex then
				monotonic = false
			end
			prevApex = apex
		end
		check("apex increases strictly with hold length", monotonic, table.concat(samples, " "))

		-- Holding past the window must stop buying height, or "hold forever" would be the only
		-- strategy and the timing game would evaporate.
		local atWindow = jumpArc(SimTuning.baseStats().maxHoldTicks)
		local wayPast = jumpArc(SimTuning.baseStats().maxHoldTicks + 120)
		check("the hold window is bounded", near(atWindow, wayPast, 0.001),
			string.format("%.4f vs %.4f", atWindow, wayPast))
	end

	-- ── 4. the rope ──────────────────────────────────────────────────────────────────────────
	log("\n[4] rope, loops and death")
	do
		local run = RunSim.new(1)
		local firstSweep = SimTuning.GRACE_TICKS + 1
		local jumpAt = firstSweep - 11
		local deathTick = 0
		for _ = 1, firstSweep + 1 do
			local events = run:step(false) -- never jump
			if events then
				for _, e in events do
					if e.kind == RunSim.EVENT.DEATH then
						deathTick = e.tick
					end
				end
			end
			if not run.alive then
				break
			end
		end
		check("standing still survives the whole wind-up", deathTick > SimTuning.GRACE_TICKS,
			string.format("died on tick %d, grace ends at %d", deathTick, SimTuning.GRACE_TICKS))
		check("standing still dies on the first real sweep", deathTick == SimTuning.GRACE_TICKS + 1,
			string.format("tick %d", deathTick))
		check("a dead run scores nothing", run.score == 0 and run.loops == 0)

		-- Jump just before the first judged sweep, and stop before the second —
		-- one jump only clears one rope pass, so stepping past it would be asserting that a player
		-- who stopped playing should survive.
		local jumped = RunSim.new(1)
		local loops = 0
		for t = 1, firstSweep + 39 do
			local down = t >= jumpAt and t <= jumpAt + 1
			local events = jumped:step(down)
			if events then
				for _, e in events do
					if e.kind == RunSim.EVENT.LOOP then
						loops += 1
					end
				end
			end
		end
		check("a well-timed jump clears the sweep and scores", loops >= 1 and jumped.alive,
			string.format("%d loop(s), alive=%s", loops, tostring(jumped.alive)))

		-- ...and the converse: stopping after that one jump IS fatal, on the next sweep.
		for _ = jumped.tick + 1, firstSweep + jumped.stats.ropePeriodTicks do
			jumped:step(false)
		end
		check("surviving one sweep does not survive the next", not jumped.alive)
		check("score tracks loops", jumped.score == loops * SimTuning.baseStats().scorePerLoop)

		-- Stepping after death must change nothing at all.
		local dead = RunSim.new(1)
		for _ = 1, firstSweep do
			dead:step(false)
		end
		local digestAfterDeath = dead.digest
		for _ = 1, 50 do
			dead:step(true)
		end
		check("a dead run is inert", dead.digest == digestAfterDeath and not dead.alive)
	end

	-- ── 5. input contract ────────────────────────────────────────────────────────────────────
	log("\n[5] input contract")
	do
		-- Holding the button through a landing must not re-launch (§5 gives us no second input to
		-- fix it with, so the rule has to hold here).
		local run = RunSim.new(1, NO_ROPE)
		local jumps = 0
		for _ = 1, 400 do
			local events = run:step(true) -- button held down forever
			if events then
				for _, e in events do
					if e.kind == RunSim.EVENT.JUMP then
						jumps += 1
					end
				end
			end
		end
		check("holding the button forever yields exactly one jump", jumps == 1,
			string.format("%d jumps", jumps))

		-- Re-pressing mid-air must not buy back hold time.
		local a = RunSim.new(1, NO_ROPE)
		local apexA = 0
		for t = 1, 400 do
			a:step(t <= 3) -- short hold, released early
			apexA = math.max(apexA, a.y)
		end
		local b = RunSim.new(1, NO_ROPE)
		local apexB = 0
		for t = 1, 400 do
			b:step(t <= 3 or (t >= 6 and t <= 40)) -- released, then hammered again mid-air
			apexB = math.max(apexB, b.y)
		end
		check("re-pressing mid-air does not extend the jump", near(apexA, apexB, 0.001),
			string.format("%.4f vs %.4f", apexA, apexB))
	end

	-- ── 6. scored-clear upgrades and difficulty ──────────────────────────────────────────────
	log("\n[6] scored-clear upgrades")
	do
		-- The bar takes one discrete step per scored rope. With the opening two-second rope, the
		-- fifth clear is tick 570 and opens the offer immediately — in the air, with the rope just
		-- past the feet. It must never fill from time alone and can never sit full waiting for a rope.
		local run = RunSim.new(1)
		local upgradeEvents, upgradeTick = 0, 0
		local airborneAtUpgrade, clearedAtUpgrade = false, false
		local heightAtUpgrade = 0
		local progressAfterClears: { number } = {}
		local firstSweep = SimTuning.GRACE_TICKS + 1
		local firstJump = firstSweep - 11
		local expectedUpgradeTick = firstSweep
			+ (SimTuning.upgradeProgressRequired(0) - 1) * run.stats.ropePeriodTicks
		for tick = 1, expectedUpgradeTick do
			local phase = (tick - firstJump) % run.stats.ropePeriodTicks
			local events = run:step(tick >= firstJump and phase <= 1)
			if events then
				local cleared = false
				for _, e in events do
					if e.kind == RunSim.EVENT.LOOP then cleared = true end
					if e.kind == RunSim.EVENT.UPGRADE_READY then
						upgradeEvents += 1
						upgradeTick = e.tick
						clearedAtUpgrade = cleared
						-- Captured HERE, not after the loop: the whole claim is about the state at
						-- this instant, and reporting the run's final height would read as a
						-- grounded offer in a passing test.
						airborneAtUpgrade = not run.grounded and run.y > 0
						heightAtUpgrade = run.y
					end
				end
				if cleared then table.insert(progressAfterClears, run.upgradeProgress) end
			end
		end
		check("the offer opens on a rope clear, in the air, never on the landing",
			upgradeEvents == 1 and clearedAtUpgrade and airborneAtUpgrade
				and upgradeTick == expectedUpgradeTick,
			string.format("round %d at tick %d, %.2f studs up, after %d skips",
				run.upgradeRound, upgradeTick, heightAtUpgrade, run.loops))
		check("the triggering clear consumes exactly one full upgrade bar",
			run.upgradeProgress == 0 and run.loops == SimTuning.upgradeProgressRequired(0))
		check("the bar advances in scored-clear steps and never waits visibly full",
			#progressAfterClears == 5
				and progressAfterClears[1] == 1
				and progressAfterClears[2] == 2
				and progressAfterClears[3] == 3
				and progressAfterClears[4] == 4
				and progressAfterClears[5] == 0)

		local laterRound = RunSim.new(61)
		laterRound.upgradeRound = 3
		laterRound.upgradeProgress = SimTuning.upgradeProgressRequired(3) - 1
		laterRound.tick = SimTuning.GRACE_TICKS
		laterRound.ropes[1].nextSweepTick = SimTuning.GRACE_TICKS + 1
		laterRound.y = 1
		laterRound.grounded = false
		laterRound:step(false)
		check("a later upgrade consumes its exponential clear target",
			laterRound.upgradeRound == 4 and laterRound.upgradeProgress == 0)
		check("clear-based upgrades do not secretly accelerate the rope",
			run.stats.ropePeriodTicks == SimTuning.baseStats().ropePeriodTicks,
			string.format("period %d ticks", run.stats.ropePeriodTicks))

		-- END TO END, on the real offer rather than a synthetic airborne fixture: play until the
		-- fifth clear opens a card, take one, and prove the player comes out the other side of the
		-- pick at the same height, on the same trajectory, with the rope where they left it. This
		-- is the bug the user reported — picking an upgrade dropped them to the floor.
		local live = RunSim.new(1)
		local liveOfferTick = 0
		for tick = 1, 730 do
			local phase = (tick - firstJump) % live.stats.ropePeriodTicks
			local events = live:step(tick >= firstJump and phase <= 1)
			if events then
				for _, e in events do
					if e.kind == RunSim.EVENT.UPGRADE_READY then liveOfferTick = e.tick end
				end
			end
			if liveOfferTick > 0 then break end
		end
		local yAtOffer, vyAtOffer = live.y, live.vy
		local sweepAtOffer = live.ropes[1].nextSweepTick
		local scoreAtOffer = live.score
		RunSim.applyStatEffects(live,
			(CardCatalog.get("INCREASE_JUMP_HEIGHT") :: CardCatalog.Card).effects)
		RunSim.resumeAfterUpgrade(live)
		local stayedUp = not live.grounded and live.y == yAtOffer and live.vy == vyAtOffer
			and live.ropes[1].nextSweepTick == sweepAtOffer and live.score == scoreAtOffer
		-- And the very next tick continues the fall it was already in, rather than restarting.
		live:step(false)
		check("taking a card mid-jump leaves the player in the air on the same arc",
			liveOfferTick > 0 and stayedUp and not live.grounded and live.y > 0
				and live.ropes[1].nextSweepTick == sweepAtOffer,
			string.format("offer at tick %d, %.2f studs up, rope still due at %d",
				liveOfferTick, yAtOffer, sweepAtOffer))

		-- Time alone buys nothing. Keep every rope away for far longer than an opening upgrade used
		-- to take; the bar must remain exactly empty because no point was scored.
		local idle = RunSim.new(1, NO_ROPE)
		idle.ropes[1].nextSweepTick = 1000000
		local idleOffers = 0
		for _ = 1, 2000 do
			local events = idle:step(false)
			if events then
				for _, e in events do
					if e.kind == RunSim.EVENT.UPGRADE_READY then idleOffers += 1 end
				end
			end
		end
		check("time without scored clears never moves the upgrade bar",
			idleOffers == 0 and idle.upgradeRound == 0 and idle.upgradeProgress == 0,
			string.format("%d offer(s), round %d, progress %d",
				idleOffers, idle.upgradeRound, idle.upgradeProgress))

		local floored = RunSim.new(1)
		local ropeSpeed = CardCatalog.get("JUMP_ROPE_SPEED") :: CardCatalog.Card
		for _ = 1, 20 do
			RunSim.applyStatEffects(floored, ropeSpeed.effects)
		end
		check("Jump Rope Speed never passes the period floor",
			floored.stats.ropePeriodTicks == SimTuning.PERIOD_TICKS_MIN,
			string.format("period %d, floor %d", floored.stats.ropePeriodTicks, SimTuning.PERIOD_TICKS_MIN))
	end

	-- ── 7. determinism — the invariant the leaderboard rests on ──────────────────────────────
	log("\n[7] determinism")
	do
		local inputs: { RunSim.InputEvent } = {}
		local r = Rng.new(20260907)
		local t = 1
		while t < 3000 do
			t += r:nextInt(3, 40)
			table.insert(inputs, { tick = t, down = true })
			t += r:nextInt(1, 35)
			table.insert(inputs, { tick = t, down = false })
		end

		-- The rope is disabled for the long trace on purpose. Random inputs are terrible at rope
		-- skipping, so with the rope on this run dies around tick 106 and the digest would only
		-- ever cover a hundred ticks. Without it, all 3000 ticks of arcs, holds and landings get
		-- hashed — which is the thing worth proving reproducible. Death is covered by [4].
		local runA = RunSim.replay(4242, inputs, 3000, NO_ROPE)
		local runB = RunSim.replay(4242, inputs, 3000, NO_ROPE)
		check("same seed + same inputs produce an identical run",
			runA.digest == runB.digest and runA.score == runB.score and runA.tick == runB.tick,
			string.format("digest %d over %d ticks", runA.digest, runA.tick))

		local diedA = RunSim.replay(4242, inputs, 3000)
		local diedB = RunSim.replay(4242, inputs, 3000)
		check("a run that ends in death is equally reproducible",
			diedA.digest == diedB.digest and diedA.tick == diedB.tick and not diedA.alive,
			string.format("digest %d, died on tick %d", diedA.digest, diedA.tick))

		-- Stage 2 snapshots include the RNG stream because a consumed card roll is authoritative
		-- state even before another physics tick moves. Different seeds must therefore diverge.
		local runC = RunSim.replay(999999, inputs, 3000, NO_ROPE)
		check("different seeds carry different authoritative RNG state",
			runC.digest ~= runA.digest)

		-- §6.5: a run is a value. Interleaving two runs on one server must not let them touch.
		local solo = RunSim.replay(4242, inputs, 3000, NO_ROPE)
		local x = RunSim.new(4242, NO_ROPE)
		local y = RunSim.new(777)
		local nextInput, downX, downY = 1, false, false
		for tick = 1, 3000 do
			while nextInput <= #inputs and inputs[nextInput].tick == tick do
				downX = inputs[nextInput].down
				nextInput += 1
			end
			downY = (tick % 7) < 3
			x:step(downX)
			y:step(downY)
		end
		check("two runs stepped side by side do not affect each other",
			x.digest == solo.digest,
			string.format("interleaved %d vs solo %d", x.digest, solo.digest))

		local ok = pcall(function()
			RunSim.replay(1, { { tick = 10, down = true }, { tick = 5, down = false } }, 100)
		end)
		check("out-of-order input is rejected, not silently scored", not ok)

		local okFloat = pcall(function()
			RunSim.replay(1, { { tick = 1.5, down = true } }, 100)
		end)
		check("fractional input ticks are rejected", not okFloat)
	end

	-- ── 8. the rules that are about the SOURCE, not the behaviour ────────────────────────────
	log("\n[8] authoritative snapshots")
	do
		local original = RunSim.new(8080, NO_ROPE)
		for tick = 1, 91 do
			-- Clear the otherwise-normal first sweep at tick 90. NO_ROPE moves every later sweep
			-- out of the fixture; it does not remove the initial grace-ending sweep.
			original:step(tick >= 79 and tick <= 80)
		end

		local restored = RunSim.fromSnapshot(RunSim.snapshot(original))
		local sameAtCheckpoint = restored.digest == original.digest
			and restored.tick == original.tick
			and restored.y == original.y
			and restored.rocketFuel == original.rocketFuel
			and restored.rocketActive == original.rocketActive
			and restored.rng.state == original.rng.state

		for tick = 92, 240 do
			local down = tick >= 130 and tick <= 151
			original:step(down)
			restored:step(down)
		end

		check("snapshot restores the exact authoritative checkpoint", sameAtCheckpoint)
		check("restored run stays deterministic when replayed forward",
			restored.digest == original.digest and restored.tick == original.tick,
			string.format("digest %d at tick %d", restored.digest, restored.tick))

		local detached = RunSim.snapshot(original)
		detached.stats.gravity = 999
		detached.ropes[1].nextSweepTick = -1
		check("snapshot tables do not alias the live run",
			original.stats.gravity ~= 999 and original.ropes[1].nextSweepTick ~= -1)
	end

	-- ── 9. the rules that are about the SOURCE, not the behaviour ────────────────────────────
	-- The design rules require these to be enforced, and they cannot be observed by running
	-- the module — a sim that read `os.clock` would still pass every test above on one machine.
	log("\n[9] source invariants")
	do
		--[[
			Comments must be stripped first. The header of RunSim lists these very identifiers in
			order to forbid them, so a naive scan reports the documentation as a violation — the
			exact false positive a naive scan always gives. It cost a minute here
			and would have cost an hour later.
		]]
		local function stripComments(src: string): string
			src = src:gsub("%-%-%[%[.-%]%]", " ") -- block comments
			src = src:gsub("%-%-[^\n]*", " ")     -- line comments
			return src
		end

		local forbidden = {
			"os%.clock", "os%.time", "DateTime", "tick%s*%(",
			"Humanoid", "Touched", "workspace", "game%s*[:.]",
			"LocalPlayer", "math%.random", "Random%.new",
			"RunService", "Instance%.new",
		}

		for _, moduleName in { "RunSim", "SimTuning", "Rng", "CardCatalog" } do
			local module = Shared:FindFirstChild(moduleName)
			if not module or not module:IsA("ModuleScript") then
				check(moduleName .. " is a ModuleScript", false)
				continue
			end
			local code = stripComments((module :: ModuleScript).Source)
			local hits: { string } = {}
			for _, pattern in forbidden do
				if code:find(pattern) then
					table.insert(hits, (pattern:gsub("%%", "")))
				end
			end
			check(moduleName .. " touches no time source, no Roblox API and no global RNG",
				#hits == 0, #hits > 0 and ("found: " .. table.concat(hits, ", ")) or nil)
		end
	end

	-- ── 10. Stage 2 cards ────────────────────────────────────────────────────────────────────
	log("\n[10] Stage 2 cards")
	do
		check("CardCatalog validates exactly nine definitions",
			(CardCatalog.validate()) == true and #CardCatalog.CARDS == 9)

		local baseStats = SimTuning.baseStats()
		local offerA = CardCatalog.rollOffer(Rng.new(991), 0, {}, baseStats)
		local offerB = CardCatalog.rollOffer(Rng.new(991), 0, {}, baseStats)
		local sameOffer = true
		for index = 1, 3 do
			if offerA[index].id ~= offerB[index].id then
				sameOffer = false
			end
		end
		check("same seed and Luck produce the same three-card offer", sameOffer)
		check("an offer never contains the same card twice",
			offerA[1].id ~= offerA[2].id
				and offerA[1].id ~= offerA[3].id
				and offerA[2].id ~= offerA[3].id)

		local rocketShoesCard = CardCatalog.get("ROCKET_SHOES") :: CardCatalog.Card
		local rocketFuelCard = CardCatalog.get("ROCKET_FUEL") :: CardCatalog.Card
		local superShoesCard = CardCatalog.get("SUPER_ROCKET_SHOES") :: CardCatalog.Card
		check("rocket progression hides fuel and Super Shoes until their prerequisites are owned",
			CardCatalog.isEligible(rocketShoesCard, {}, baseStats)
				and not CardCatalog.isEligible(rocketFuelCard, {}, baseStats)
				and not CardCatalog.isEligible(superShoesCard, {}, baseStats)
				and CardCatalog.isEligible(rocketFuelCard, { ROCKET_SHOES = 1 }, baseStats)
				and not CardCatalog.isEligible(superShoesCard,
					{ ROCKET_SHOES = 1, ROCKET_FUEL = 2 }, baseStats)
				and CardCatalog.isEligible(superShoesCard,
					{ ROCKET_SHOES = 1, ROCKET_FUEL = 3 }, baseStats))
		check("Upgrade Rocket Fuel remains eligible at any stack count",
			rocketFuelCard.maxStacks == nil
				and CardCatalog.isEligible(rocketFuelCard,
					{ ROCKET_SHOES = 1, ROCKET_FUEL = 1000000 }, baseStats))

		local rare = CardCatalog.get("SUPER_ROCKET_SHOES")
		local common = CardCatalog.get("INCREASE_JUMP_HEIGHT")
		check("Luck changes the exact integer weights used by the roll",
			rare ~= nil and common ~= nil
				and CardCatalog.weightFor(rare :: CardCatalog.Card, 3)
					> CardCatalog.weightFor(rare :: CardCatalog.Card, 0)
				and CardCatalog.weightFor(common :: CardCatalog.Card, 3)
					== CardCatalog.weightFor(common :: CardCatalog.Card, 0))

		check("a forged card id resolves to nothing in a stored offer",
			CardCatalog.resolveOfferedCard(offerA, "FORGED_NOT_OFFERED") == nil)

		local deepStacks: { [string]: number } = {
			ADD_JUMPROPE = 100,
			IGNITE_JUMPROPE = 100,
			INCREASE_JUMP_HEIGHT = 100,
			REINFORCE_JUMP_ROPE = 100,
			INCREASE_LUCK = 100,
			JUMP_ROPE_SPEED = 100,
			ROCKET_SHOES = 100,
			ROCKET_FUEL = 100,
			SUPER_ROCKET_SHOES = 100,
		}
		local stillEligible = true
		for _, card in CardCatalog.CARDS do
			local shouldRemain = card.id ~= "ADD_JUMPROPE" and card.id ~= "JUMP_ROPE_SPEED"
			if CardCatalog.isEligible(card, deepStacks, baseStats) ~= shouldRemain then
				stillEligible = false
			end
		end
		check("only rope count and speed retire after reaching their real limits",
			stillEligible and CardCatalog.eligibleCount(deepStacks, baseStats) == #CardCatalog.CARDS - 2)
		local deepOffer = CardCatalog.rollOffer(Rng.new(4), 0, deepStacks, baseStats)
		check("an endless run still receives three distinct upgrade choices",
			#deepOffer == 3
				and deepOffer[1].id ~= deepOffer[2].id
				and deepOffer[1].id ~= deepOffer[3].id
				and deepOffer[2].id ~= deepOffer[3].id)

		local igniteCard = CardCatalog.get("IGNITE_JUMPROPE") :: CardCatalog.Card
		local oneLit = RunSim.new(404)
		RunSim.applyStatEffects(oneLit, igniteCard.effects)
		check("Ignite consumes one unlit rope and returns only when another rope exists",
			igniteCard.name == "Ignite Jumprope"
				and not CardCatalog.isEligible(igniteCard, { IGNITE_JUMPROPE = 1 }, oneLit.stats))
		RunSim.applyStatEffects(oneLit, (CardCatalog.get("ADD_JUMPROPE") :: CardCatalog.Card).effects)
		check("adding a rope creates exactly one new Ignite slot",
			CardCatalog.isEligible(igniteCard, { IGNITE_JUMPROPE = 1 }, oneLit.stats))

		local everyCardMovesAStat = true
		local everyCardKeepsTheArc = true
		local everyCardRetiresTheHold = true
		local everyCardSurvivesTheWire = true
		for _, card in CardCatalog.CARDS do
			local run = RunSim.new(5)
			-- A real offer opens on a rope clear, so the player is always mid-arc when they pick.
			-- Reproduce that: rising, still holding, feet well off the ground.
			for _ = 1, 12 do
				run:step(true)
			end
			assert(not run.grounded and run.y > 0 and run.holding,
				"fixture must be airborne and still holding")

			local before = RunSim.snapshot(run).stats :: any
			RunSim.applyStatEffects(run, card.effects)
			local changed = false
			for key, value in before do
				if (run.stats :: any)[key] ~= value then
					changed = true
					break
				end
			end
			if not changed then
				everyCardMovesAStat = false
			end

			-- Snapshot the arc and the rope schedule the instant before the pick resolves. Add
			-- Jumprope is the one card allowed to lengthen this list; it may never move an entry.
			local heightBefore, velocityBefore = run.y, run.vy
			local groundedBefore = run.grounded
			local sweepsBefore: { number } = {}
			for index, rope in run.ropes do
				sweepsBefore[index] = rope.nextSweepTick
			end

			RunSim.resumeAfterUpgrade(run)

			if run.y ~= heightBefore or run.vy ~= velocityBefore or run.grounded ~= groundedBefore then
				everyCardKeepsTheArc = false
			end
			for index, sweep in sweepsBefore do
				if run.ropes[index].nextSweepTick ~= sweep then
					everyCardKeepsTheArc = false
				end
			end
			if run.holding or run.holdTicksLeft ~= 0 or run.wasDown or run.rocketActive then
				everyCardRetiresTheHold = false
			end

			-- The network path rebuilds this exact authoritative snapshot on the client. The player
			-- must come back to the same arc, still falling toward the same ground.
			local resumed = RunSim.fromSnapshot(RunSim.snapshot(run))
			if resumed.y ~= run.y or resumed.vy ~= run.vy or resumed.grounded ~= run.grounded then
				everyCardSurvivesTheWire = false
			end
			for index, rope in run.ropes do
				if resumed.ropes[index].nextSweepTick ~= rope.nextSweepTick then
					everyCardSurvivesTheWire = false
				end
			end
			resumed:step(false)
			if resumed.grounded or resumed.y <= 0 then
				everyCardSurvivesTheWire = false
			end
		end
		-- REGRESSION. Rocket cards used to carry conflicting private hold ceilings, so a later card
		-- could pull the same stat down. They now share uncapped fuel capacity and only add to it.
		local capOrder = RunSim.new(41)
		local superShoes = CardCatalog.get("SUPER_ROCKET_SHOES") :: CardCatalog.Card
		local rocketShoes = CardCatalog.get("ROCKET_SHOES") :: CardCatalog.Card
		-- Unlock path: shoes, three fuels, then supers (prereqs for a fair Super apply).
		RunSim.applyStatEffects(capOrder, rocketShoes.effects)
		local rocketFuel = CardCatalog.get("ROCKET_FUEL") :: CardCatalog.Card
		for _ = 1, 3 do
			RunSim.applyStatEffects(capOrder, rocketFuel.effects)
		end
		RunSim.applyStatEffects(capOrder, superShoes.effects)
		local fuelAfterSupers = capOrder.stats.rocketFuelCapacity
		RunSim.applyStatEffects(capOrder, rocketShoes.effects)
		check("a later card can never undo a stat an earlier one raised",
			capOrder.stats.rocketFuelCapacity > fuelAfterSupers,
			string.format("%d fuel after Supers, %d after Rocket Shoes",
				fuelAfterSupers, capOrder.stats.rocketFuelCapacity))

		-- Taking the numerical effects in either order must reach the same place. Open all eight rope
		-- slots first: Ignite and Reinforce are only legal once per owned rope, so blindly applying
		-- either twelve times would be testing a state the offer system now forbids.
		local forward, backward = RunSim.new(42), RunSim.new(42)
		local addCard = CardCatalog.get("ADD_JUMPROPE") :: CardCatalog.Card
		for _ = 1, addCard.maxStacks or 0 do
			RunSim.applyStatEffects(forward, addCard.effects)
			RunSim.applyStatEffects(backward, addCard.effects)
		end
		for _, card in CardCatalog.CARDS do
			if card.id ~= "ADD_JUMPROPE" then
				local times = if card.perRopeStat then forward.stats.ropeCount else card.maxStacks or 12
				for _ = 1, times do
					RunSim.applyStatEffects(forward, card.effects)
				end
			end
		end
		for index = #CardCatalog.CARDS, 1, -1 do
			local card = CardCatalog.CARDS[index]
			if card.id ~= "ADD_JUMPROPE" then
				local times = if card.perRopeStat then backward.stats.ropeCount else card.maxStacks or 12
				for _ = 1, times do
					RunSim.applyStatEffects(backward, card.effects)
				end
			end
		end
		local sameEitherWay = true
		for stat, value in forward.stats :: any do
			if (backward.stats :: any)[stat] ~= value then
				sameEitherWay = false
			end
		end
		check("the whole deck reaches the same stats taken in either order", sameEitherWay)

		-- No row may reintroduce a private bound. This is the structural half of the two checks
		-- above: they prove today's rows agree, this one prevents tomorrow's from disagreeing.
		local noPrivateBounds = true
		for _, card in CardCatalog.CARDS do
			for _, effect in card.effects do
				local raw = effect :: any
				if raw.minimum ~= nil or raw.maximum ~= nil then
					noPrivateBounds = false
				end
				if SimTuning.STAT_LIMITS[effect.stat] == nil then
					noPrivateBounds = false
				end
			end
		end
		check("no card carries its own ceiling; every moved stat has a shared limit",
			noPrivateBounds)

		check("every catalog row changes a validated simulation stat", everyCardMovesAStat)
		check("taking a card never moves the player or a pending sweep", everyCardKeepsTheArc)
		check("taking a card retires the hold, because the pick was a press", everyCardRetiresTheHold)
		check("the authoritative resume snapshot returns the player to the same arc",
			everyCardSurvivesTheWire)

		local upgradeSafety = RunSim.new(43)
		RunSim.applyStatEffects(upgradeSafety, rocketShoesCard.effects)
		upgradeSafety.rocketFuel = 1
		upgradeSafety.rocketActive = true
		RunSim.resumeAfterUpgrade(upgradeSafety)
		check("clicking any upgrade stops rockets and starts invulnerability without a refill",
			upgradeSafety.rocketFuel == 1
				and not upgradeSafety.rocketActive
				and upgradeSafety.invulnerableTicks == SimTuning.INVULNERABILITY_TICKS)

		-- Put a lethal grounded sweep on the first protected tick. It must pass harmlessly without
		-- moving the rope schedule, then the same contact must kill once all i-frames have elapsed.
		upgradeSafety.tick = SimTuning.GRACE_TICKS
		upgradeSafety.ropes[1].nextSweepTick = SimTuning.GRACE_TICKS + 1
		upgradeSafety:step(false)
		local survivedUpgradeContact = upgradeSafety.alive
			and upgradeSafety.invulnerableTicks == SimTuning.INVULNERABILITY_TICKS - 1
		for _ = 1, SimTuning.INVULNERABILITY_TICKS - 1 do
			upgradeSafety:step(false)
		end
		upgradeSafety.ropes[1].nextSweepTick = upgradeSafety.tick + 1
		upgradeSafety:step(false)
		check("upgrade i-frames block rope contact and expire on simulation ticks",
			survivedUpgradeContact and not upgradeSafety.alive)

		-- Removed at the user's direction on 2026-09-11: "just remove jumper reinforcement".
		check("Jumper Reinforcement is out of the deck",
			CardCatalog.get("JUMPER_REINFORCEMENT") == nil)

		local saved = RunSim.new(17, { ropeReinforcements = 1 })
		local sawSave = false
		for _ = 1, SimTuning.GRACE_TICKS + 1 do
			local events = saved:step(false)
			if events then
				for _, event in events do
					if event.kind == RunSim.EVENT.ROPE_REINFORCED then sawSave = true end
				end
			end
		end
		local reinforceCard = CardCatalog.get("REINFORCE_JUMP_ROPE") :: CardCatalog.Card
		check("Reinforce Jump Rope absorbs one otherwise lethal strike and opens that rope again",
			sawSave and saved.alive and saved.stats.ropeReinforcements == 0
				and CardCatalog.isEligible(reinforceCard,
					{ REINFORCE_JUMP_ROPE = 1 }, saved.stats))

		local clustered = RunSim.new(171, { ropeCount = 2, ropeReinforcements = 2 })
		clustered.tick = SimTuning.GRACE_TICKS
		clustered.ropes[1].nextSweepTick = SimTuning.GRACE_TICKS + 1
		clustered.ropes[2].nextSweepTick = SimTuning.GRACE_TICKS + 1
		local clusteredEvents = clustered:step(false)
		local reinforcementBreaks = 0
		if clusteredEvents then
			for _, event in clusteredEvents do
				if event.kind == RunSim.EVENT.ROPE_REINFORCED then reinforcementBreaks += 1 end
			end
		end
		check("one broken reinforcement grants i-frames against clustered ropes",
			clustered.alive
				and clustered.stats.ropeReinforcements == 1
				and clustered.invulnerableTicks == SimTuning.INVULNERABILITY_TICKS
				and reinforcementBreaks == 1)
		for _ = saved.tick + 1, SimTuning.GRACE_TICKS + 1 + saved.stats.ropePeriodTicks do
			saved:step(false)
		end
		check("a consumed reinforcement does not absorb the next strike", not saved.alive)

		-- One card, one rope (the user, 2026-09-11: "it's only for one of the jumpropes").
		local single = RunSim.new(172, { ropeCount = 2, ropeReinforcements = 1 })
		check("a Reinforce guard sits on one rope, not on all of them",
			single.ropes[1].guards == 1 and single.ropes[2].guards == 0)
		RunSim.applyStatEffects(single, reinforceCard.effects)
		check("the next card guards the rope with the fewest guards",
			single.ropes[1].guards == 1 and single.ropes[2].guards == 1)
		check("Reinforce is unavailable while every rope already has one guard",
			not CardCatalog.isEligible(reinforceCard, { REINFORCE_JUMP_ROPE = 2 }, single.stats))
		local restored = RunSim.fromSnapshot(RunSim.snapshot(single))
		check("each rope's guards survive an authoritative snapshot",
			restored.ropes[1].guards == 1 and restored.ropes[2].guards == 1)
		local open = RunSim.new(173, { ropeCount = 2, ropeReinforcements = 1 })
		open.tick = SimTuning.GRACE_TICKS
		open.ropes[1].nextSweepTick = SimTuning.GRACE_TICKS + 60
		open.ropes[2].nextSweepTick = SimTuning.GRACE_TICKS + 1
		open:step(false)
		check("a rope with no guard of its own still catches you", not open.alive)

		local fireRun = RunSim.new(23)
		local fireCard = CardCatalog.get("IGNITE_JUMPROPE") :: CardCatalog.Card
		RunSim.applyStatEffects(fireRun, fireCard.effects)
		local firstSweep = SimTuning.GRACE_TICKS + 1
		local jumpAt = firstSweep - 11
		for tick = 1, firstSweep + 39 do
			fireRun:step(tick >= jumpAt and tick <= jumpAt + 1)
		end
		check("one burning rope gives x2 score and two clear progress",
			fireRun.score == 2 and fireRun.loops == 1 and fireRun.upgradeProgress == 2,
			string.format("%d point(s) from %d loop", fireRun.score, fireRun.loops))

		local stackedFire = RunSim.new(24)
		RunSim.applyStatEffects(stackedFire,
			(CardCatalog.get("ADD_JUMPROPE") :: CardCatalog.Card).effects)
		RunSim.applyStatEffects(stackedFire, fireCard.effects)
		RunSim.applyStatEffects(stackedFire, fireCard.effects)
		stackedFire.tick = SimTuning.GRACE_TICKS
		stackedFire.ropes[1].nextSweepTick = SimTuning.GRACE_TICKS + 1
		stackedFire.y = 1
		stackedFire.grounded = false
		stackedFire:step(false)
		check("two distinct burning ropes give x3 score without compounding clear progress",
			stackedFire.score == 3 and stackedFire.loops == 1 and stackedFire.upgradeProgress == 2
				and not CardCatalog.isEligible(fireCard, { IGNITE_JUMPROPE = 2 }, stackedFire.stats),
			string.format("%d point(s) from %d loop", stackedFire.score, stackedFire.loops))

		local oneRopeGuarded = RunSim.new(25, { ropeReinforcements = 1 })
		local doubleGuardApplied = pcall(function()
			RunSim.applyStatEffects(oneRopeGuarded, reinforceCard.effects)
		end)
		local oneRopeBurning = RunSim.new(26, { scorePerLoop = 2 })
		local doubleFireApplied = pcall(function()
			RunSim.applyStatEffects(oneRopeBurning, fireCard.effects)
		end)
		check("the simulation rejects a second guard or fire stack on the same rope",
			not doubleGuardApplied and not doubleFireApplied
				and oneRopeGuarded.stats.ropeReinforcements == 1
				and oneRopeBurning.stats.scorePerLoop == 2)

		-- Luck is rolled by RunSim, not presentation. Find a seed whose first roll procs at eight
		-- Luck stacks (40%), then prove that it doubles the complete award and adds two bonus
		-- discrete step to the same authoritative progress that drives the upgrade bar.
		local luckCard = CardCatalog.get("INCREASE_LUCK") :: CardCatalog.Card
		local luckStacksForProc = 8
		local luckySeed = 0
		for seed = 1, 1000 do
			if Rng.new(seed):nextInt(1, 100)
				<= luckStacksForProc * SimTuning.LUCK_PROC_PERCENT_PER_STACK then
				luckySeed = seed
				break
			end
		end
		check("a deterministic seed exists for the configured Luck proc chance", luckySeed > 0)
		local luckyFire = RunSim.new(luckySeed)
		for _ = 1, luckStacksForProc do
			RunSim.applyStatEffects(luckyFire, luckCard.effects)
		end
		RunSim.applyStatEffects(luckyFire, fireCard.effects)
		luckyFire.tick = SimTuning.GRACE_TICKS
		luckyFire.ropes[1].nextSweepTick = SimTuning.GRACE_TICKS + 1
		luckyFire.y = 1
		luckyFire.grounded = false
		local luckyEvents = luckyFire:step(false)
		local luckyLoop = nil
		if luckyEvents then
			for _, event in luckyEvents do
				if event.kind == RunSim.EVENT.LOOP then
					luckyLoop = event
					break
				end
			end
		end
		check("Luck doubles the complete points award instead of replacing its multiplier",
			luckyFire.score == 4
				and luckyLoop ~= nil
				and luckyLoop.lucky == true
				and luckyLoop.points == 4,
			string.format("score %d", luckyFire.score))
		check("Ignite plus a Luck proc grants four upgrade progress",
			luckyFire.upgradeProgress == 2 + SimTuning.LUCKY_UPGRADE_PROGRESS_BONUS,
			string.format("progress %d", luckyFire.upgradeProgress))

		local addRope = CardCatalog.get("ADD_JUMPROPE") :: CardCatalog.Card

		-- A second rope must land on the OPPOSITE side of the turn. Stepped well into the run so
		-- the first rope is at an arbitrary phase rather than a convenient one: a second rope that
		-- happened to be opposite only from tick zero would be a coincidence, not a rule.
		local extraRopeRun = RunSim.new(31)
		for tick = 1, 137 do
			extraRopeRun:step(tick % 40 <= 12)
		end
		local firstPendingSweep = extraRopeRun.ropes[1].nextSweepTick
		local period = extraRopeRun.stats.ropePeriodTicks
		RunSim.applyStatEffects(extraRopeRun, addRope.effects)
		local secondSweep = extraRopeRun.ropes[2].nextSweepTick
		local separation = math.abs(secondSweep - firstPendingSweep) % period
		check("Add Jumprope puts the new rope exactly opposite the one already turning",
			#extraRopeRun.ropes == 2
				and extraRopeRun.ropes[1].nextSweepTick == firstPendingSweep
				and separation == period // 2,
			string.format("sweeps %d and %d, separation %d of a %d-tick turn",
				firstPendingSweep, secondSweep, separation, period))
		check("a new rope never sweeps sooner than half a turn away",
			secondSweep - extraRopeRun.tick >= period // 2,
			string.format("%d ticks of warning", secondSweep - extraRopeRun.tick))

		-- Every further rope goes in the widest remaining gap, and none of them may disturb a
		-- sweep the player is already steering around.
		local crowded = RunSim.new(37)
		for tick = 1, 91 do
			crowded:step(tick % 40 <= 12)
		end
		local ropesStayPut = true
		local alwaysWarned = true
		for _ = 1, 12 do
			local existing: { number } = {}
			for index, rope in crowded.ropes do
				existing[index] = rope.nextSweepTick
			end
			RunSim.applyStatEffects(crowded, addRope.effects)
			for index, sweep in existing do
				if crowded.ropes[index].nextSweepTick ~= sweep then
					ropesStayPut = false
				end
			end
			local newest = crowded.ropes[#crowded.ropes].nextSweepTick
			if newest - crowded.tick < crowded.stats.ropePeriodTicks // 2 then
				alwaysWarned = false
			end
		end
		check("Add Jumprope stops at the reliable eight-rope presentation limit",
			#crowded.ropes == SimTuning.MAX_ROPES and crowded.stats.ropeCount == SimTuning.MAX_ROPES,
			string.format("%d ropes", #crowded.ropes))
		check("adding a rope never reschedules a rope already in the air", ropesStayPut)
		check("every added rope arrives with at least half a turn of warning", alwaysWarned)

		local heightBase = RunSim.new(32, NO_ROPE)
		local heightUp = RunSim.new(32, NO_ROPE)
		RunSim.applyStatEffects(heightUp,
			(CardCatalog.get("INCREASE_JUMP_HEIGHT") :: CardCatalog.Card).effects)
		local heightBaseApex, heightUpApex = 0, 0
		for tick = 1, 100 do
			heightBase:step(tick == 1)
			heightUp:step(tick == 1)
			heightBaseApex = math.max(heightBaseApex, heightBase.y)
			heightUpApex = math.max(heightUpApex, heightUp.y)
		end
		check("Increase Jump Height raises the actual tap apex", heightUpApex > heightBaseApex + 0.25)

		local speedRun = RunSim.new(33)
		local pendingBeforeSpeed = speedRun.ropes[1].nextSweepTick
		RunSim.applyStatEffects(speedRun,
			(CardCatalog.get("JUMP_ROPE_SPEED") :: CardCatalog.Card).effects)
		check("Jump Rope Speed shortens future periods without moving a pending sweep",
			speedRun.stats.ropePeriodTicks < SimTuning.baseStats().ropePeriodTicks
				and speedRun.ropes[1].nextSweepTick == pendingBeforeSpeed)
		local speedCard = CardCatalog.get("JUMP_ROPE_SPEED") :: CardCatalog.Card
		for _ = 2, speedCard.maxStacks or 0 do
			RunSim.applyStatEffects(speedRun, speedCard.effects)
		end
		check("Jump Rope Speed remains useful through its last offer, then retires",
			speedRun.stats.ropePeriodTicks == SimTuning.PERIOD_TICKS_MIN
				and not CardCatalog.isEligible(speedCard,
					{ JUMP_ROPE_SPEED = speedCard.maxStacks or 0 }, SimTuning.baseStats()))

		local noBoots = RunSim.new(34, NO_ROPE)
		local booted = RunSim.new(34, NO_ROPE)
		booted.grounded = false
		RunSim.applyStatEffects(booted, rocketShoesCard.effects)
		check("Rocket Shoes unlocks a full fuel tank even when chosen mid-air",
			booted.stats.rocketFuelCapacity > 0
				and booted.rocketFuel == booted.stats.rocketFuelCapacity)
		check("the first Rocket Shoes tank is about forty-five percent smaller",
			booted.stats.rocketFuelCapacity == 50,
			string.format("%d fuel ticks", booted.stats.rocketFuelCapacity))
		local scaledRocketPath = RunSim.new(345, NO_ROPE)
		RunSim.applyStatEffects(scaledRocketPath, rocketShoesCard.effects)
		for _ = 1, 3 do
			RunSim.applyStatEffects(scaledRocketPath, rocketFuelCard.effects)
		end
		RunSim.applyStatEffects(scaledRocketPath, superShoesCard.effects)
		check("Rocket Fuel and Super capacity bonuses use the same reduction scale",
			scaledRocketPath.stats.rocketFuelCapacity == 248,
			string.format("%d total fuel ticks", scaledRocketPath.stats.rocketFuelCapacity))

		-- Start with an ordinary tap and release. A fresh press ten ticks into that same jump is the
		-- rocket control: it must do nothing without shoes and burn fuel with them.
		noBoots:step(true)
		booted:step(true)
		for _ = 1, 10 do
			noBoots:step(false)
			booted:step(false)
		end
		local fuelBeforeBurn = booted.rocketFuel
		noBoots:step(true)
		booted:step(true)
		check("a mid-air re-press burns rocket fuel and adds lift",
			booted.rocketActive
				and booted.rocketFuel < fuelBeforeBurn
				and booted.vy > noBoots.vy)

		for _ = 1, 11 do booted:step(true) end
		booted.rocketFuel = 0
		local fuelAfterBurn = booted.rocketFuel
		for _ = 1, 4 do booted:step(true) end
		check("an empty rocket tank stays empty while the button is held",
			booted.rocketFuel == fuelAfterBurn)
		local stayedEmptyInAir = true
		local landingGuard = 0
		while not booted.grounded and landingGuard < 300 do
			booted:step(false)
			landingGuard += 1
			if not booted.grounded and booted.rocketFuel ~= fuelAfterBurn then
				stayedEmptyInAir = false
			end
		end
		check("releasing stops Rocket Shoes but cannot refill them before landing",
			stayedEmptyInAir)
		check("landing fully refills the rocket tank",
			booted.grounded and booted.rocketFuel == booted.stats.rocketFuelCapacity)

		local continuousHold = RunSim.new(341, NO_ROPE)
		RunSim.applyStatEffects(continuousHold, rocketShoesCard.effects)
		for _ = 1, continuousHold.stats.maxHoldTicks + 2 do
			continuousHold:step(true)
		end
		check("one continuous hold naturally transitions from the normal jump to Rocket Shoes",
			continuousHold.rocketActive
				and continuousHold.rocketFuel < continuousHold.stats.rocketFuelCapacity)

		local airborneFuel = RunSim.new(344, NO_ROPE)
		RunSim.applyStatEffects(airborneFuel, rocketShoesCard.effects)
		airborneFuel.y = 4
		airborneFuel.grounded = false
		airborneFuel.rocketFuel = 1
		local oldCapacity = airborneFuel.stats.rocketFuelCapacity
		RunSim.applyStatEffects(airborneFuel, rocketFuelCard.effects)
		check("Upgrade Rocket Fuel increases capacity",
			airborneFuel.stats.rocketFuelCapacity > oldCapacity)
		check("a mid-air upgrade does not refill the rocket tank",
			airborneFuel.rocketFuel == 1)
		local endlessFuel = RunSim.new(343)
		RunSim.applyStatEffects(endlessFuel, rocketShoesCard.effects)
		for _ = 1, 20 do
			RunSim.applyStatEffects(endlessFuel, rocketFuelCard.effects)
		end
		check("Rocket Fuel keeps increasing capacity beyond the old ceiling",
			endlessFuel.stats.rocketFuelCapacity == 710)

		airborneFuel.rocketFuel = 1
		RunSim.applyStatEffects(airborneFuel,
			(CardCatalog.get("INCREASE_LUCK") :: CardCatalog.Card).effects)
		check("collecting any upgrade leaves mid-air rocket fuel untouched",
			airborneFuel.rocketFuel == 1)

		local capacityBeforeSuper = airborneFuel.stats.rocketFuelCapacity
		local thrustBeforeSuper = airborneFuel.stats.rocketThrust
		RunSim.applyStatEffects(airborneFuel, superShoesCard.effects)
		check("Super Rocket Shoes expands the tank and lift together",
			airborneFuel.stats.rocketFuelCapacity > capacityBeforeSuper
				and airborneFuel.stats.rocketThrust > thrustBeforeSuper
				and airborneFuel.rocketFuel == 1)

		-- Stress the resource across many burn/landing-refill boundaries and snapshot round-trips.
		-- This catches fuel under/overflow and a missing digest field without
		-- relying on a real-time Play session.
		local rocketA = RunSim.new(342, NO_ROPE)
		RunSim.applyStatEffects(rocketA, rocketShoesCard.effects)
		RunSim.applyStatEffects(rocketA, rocketFuelCard.effects)
		rocketA.y = 100
		rocketA.grounded = false
		local rocketB = RunSim.fromSnapshot(RunSim.snapshot(rocketA))
		local fuelStayedBounded = true
		for tick = 1, 5000 do
			local down = tick % 47 < 29
			rocketA:step(down)
			rocketB:step(down)
			if rocketA.rocketFuel < 0
				or rocketA.rocketFuel > rocketA.stats.rocketFuelCapacity
				or (rocketA.rocketActive and not down) then
				fuelStayedBounded = false
			end
		end
		check("rocket fuel stays bounded across long alternating burn and landing refill",
			fuelStayedBounded)
		check("rocket flight remains deterministic across a snapshot and long replay",
			rocketA.digest == rocketB.digest and rocketA.tick == rocketB.tick)

		local reviveRun = RunSim.new(35)
		RunSim.applyStatEffects(reviveRun,
			(CardCatalog.get("INCREASE_JUMP_HEIGHT") :: CardCatalog.Card).effects)
		RunSim.applyStatEffects(reviveRun, rocketShoesCard.effects)
		reviveRun.score = 14
		reviveRun.loops = 12
		reviveRun.tick = 500
		reviveRun.rocketFuel = 1
		reviveRun.alive = false
		local upgradedImpulse = reviveRun.stats.jumpImpulse
		reviveRun:revive()
		check("revive keeps score and upgrades, grounds the player, and grants a full-period warning",
			reviveRun.alive and reviveRun.grounded and reviveRun.score == 14
				and reviveRun.stats.jumpImpulse == upgradedImpulse
				and reviveRun.rocketFuel == reviveRun.stats.rocketFuelCapacity
				and reviveRun.ropes[1].nextSweepTick >= 500 + reviveRun.stats.ropePeriodTicks
				and reviveRun.invulnerableTicks == SimTuning.INVULNERABILITY_TICKS)
	end

	-- ── 11. Stage 1/2 structural contracts ──────────────────────────────────────────────────
	-- These assertions are intentionally about source. The architecture itself is the behaviour
	-- under test: both peers must call the one simulation, and presentation must read its rope
	-- schedule rather than inventing a parallel animation clock.
	log("\n[11] Stage 1/2 architecture")
	do
		local serverRoot = game:GetService("ServerScriptService"):FindFirstChild("Server")
		local clientRoot = game:GetService("StarterPlayer").StarterPlayerScripts:FindFirstChild("Client")
		local server = serverRoot and serverRoot:FindFirstChild("RunServer")
		local client = clientRoot and clientRoot:FindFirstChild("Main")
		local input = clientRoot and clientRoot:FindFirstChild("InputController")
		local presenter = clientRoot and clientRoot:FindFirstChild("RunPresenter")
		local ropeView = clientRoot and clientRoot:FindFirstChild("RopeView")
		local audioPresenter = clientRoot and clientRoot:FindFirstChild("AudioPresenter")

		check("Stage 1 source modules are synced",
			server ~= nil and client ~= nil and input ~= nil and presenter ~= nil
				and ropeView ~= nil and audioPresenter ~= nil)
		if server and server:IsA("ModuleScript")
			and client and client:IsA("LocalScript")
			and input and input:IsA("ModuleScript")
			and presenter and presenter:IsA("ModuleScript")
			and ropeView and ropeView:IsA("ModuleScript")
			and audioPresenter and audioPresenter:IsA("ModuleScript") then
			local serverSource = server.Source
			local clientSource = client.Source
			local inputSource = input.Source
			local presenterSource = presenter.Source
			local ropeSource = ropeView.Source
			local audioSource = audioPresenter.Source

			check("client and server both require the shared RunSim",
				serverSource:find('Shared:WaitForChild%("RunSim"%)') ~= nil
					and clientSource:find('Shared:WaitForChild%("RunSim"%)') ~= nil)
			check("server publishes RunSim snapshots and client restores them",
				serverSource:find("RunSim%.snapshot") ~= nil
					and clientSource:find("RunSim%.fromSnapshot") ~= nil)
			check("fixed-step callers pass only boolean state into RunSim",
				serverSource:find("session%.run:step%(session%.inputDown%)") ~= nil
					and clientSource:find("active%.run:step%(active%.inputDown%)") ~= nil)
			check("all four transports feed one input controller",
				inputSource:find("KeyCode%.Space") ~= nil
					and inputSource:find("MouseButton1") ~= nil
					and inputSource:find("ButtonA") ~= nil
					and inputSource:find("UserInputType%.Touch") ~= nil)
			check("drawn rope phase is derived from the simulated next sweep",
				presenterSource:find("rope%.nextSweepTick %- tickFloat") ~= nil)
			check("each burning rope selects its own fire appearance",
				presenterSource:find("index <= run%.stats%.scorePerLoop %- 1") ~= nil
					and ropeSource:find("RopeStyles%.look%(setId, burning, guarded%)") ~= nil)
			check("the fire card uses atlas art and the HUD shows its authoritative multiplier",
				presenterSource:find('makeLabel%(gui, "PointsMultiplier"') ~= nil
					and presenterSource:find('makeLabel%(button, "MultiplierIcon"') == nil
					and presenterSource:find("local pointsBonus = run%.stats%.scorePerLoop") ~= nil
					and presenterSource:find("self%.pointsMultiplier%.Visible = pointsBonus > 1") ~= nil
					and presenterSource:find('string%.format%("%%dX", pointsBonus%)') ~= nil
					and presenterSource:find('FIRE ×', 1, true) == nil)
			-- Application moved into one shared `applyCard` when the deadline auto-pick arrived, so
			-- the ordering is now checked inside that function rather than by file position.
			local membershipCheck = serverSource:find("CardCatalog%.resolveOfferedCard%(session%.offer")
			local applyStart = serverSource:find("applyCard = function")
			local consumeOffer = applyStart and serverSource:find("session%.offer = nil", applyStart)
			local applyEffects = applyStart and serverSource:find("RunSim%.applyStatEffects", applyStart)
			check("server validates membership and consumes an offer before applying a card",
				membershipCheck ~= nil and applyStart ~= nil
					and serverSource:find(
						"CardCatalog%.isEligible%(card, session%.stacks, session%.run%.stats%)") ~= nil
					and consumeOffer ~= nil and applyEffects ~= nil
					and (consumeOffer :: number) < (applyEffects :: number))
			-- The auto-pick must not become a second, thinner version of taking a card. One function,
			-- two callers: a step added to a real pick is automatically added to the deadline's.
			check("a deadline auto-pick applies a card through the same path a click does",
				serverSource:find("applyCard%(player, session, card, oldStacks, false%)") ~= nil
					and serverSource:find("local function autoPickExpiredOffer") ~= nil
					and serverSource:find("applyCard%(player, session, card, session%.stacks") ~= nil)
			-- Which card the deadline lands on is part of the replay, not a private server coin flip.
			check("the auto-pick draws from the run's own seeded RNG",
				serverSource:find("session%.run%.rng:nextInt%(1, #takeable%)") ~= nil)
			check("the auto-pick only ever hands over a card the player could have taken",
				serverSource:find(
					"CardCatalog%.isEligible%(card, session%.stacks, session%.run%.stats%)") ~= nil)
			check("cards support direct pointer activation plus the one-button fallback",
				clientSource:find("PICK_CARD") ~= nil
					and clientSource:find("isPointerInput") ~= nil
					and presenterSource:find("button%.Activated") ~= nil)
			check("card presses move the highlight before activation",
				presenterSource:find("button%.MouseButton1Down") ~= nil)
			check("every rejected card pick unlocks the client for another click",
				RunProtocol.SERVER.CARD_REJECTED == "CARD_REJECTED"
					and serverSource:find("RunProtocol%.SERVER%.CARD_REJECTED") ~= nil
					and clientSource:find("elseif op == RunProtocol%.SERVER%.CARD_REJECTED") ~= nil
					and clientSource:find("active%.pickPending = false") ~= nil)
			check("applying a card resets stale held input on the server and client",
				serverSource:find("RunSim%.resumeAfterUpgrade%(session%.run%)") ~= nil
					and serverSource:find("table%.clear%(session%.pending%)") ~= nil
					and clientSource:find("active%.inputs = {}") ~= nil
					and clientSource:find("active%.lastInputTick = active%.run%.tick") ~= nil
					and clientSource:find("inputController:reset%(%)") ~= nil
					and inputSource:find("function InputController%.reset") ~= nil)
			local rearmAfterEffects = applyEffects
				and serverSource:find("rearmAuthorityClock%(session, resumeAt%)", applyEffects :: number)
			-- `beginOffer` pauses the session from inside the server's own step loop. Without the
			-- guard the loop finished the frame's remaining ticks while the client sat frozen, so a
			-- rope could sweep — and kill — behind a card modal the player was still reading.
			check("the server stops stepping the instant an offer pauses the run",
				serverSource:find("and not session%.paused do") ~= nil)
			check("a card resume restores the client prediction safety gap",
				serverSource:find(
					"local function rearmAuthorityClock%(session: Session, startAt: number%?%)"
				) ~= nil
					and serverSource:find("session%.clockStarted = false") ~= nil
					and rearmAfterEffects ~= nil)
			check("the visible upgrade bar reads discrete scored-clear progress",
				presenterSource:find('upgradeTrack%.Name = "UpgradeTrack"') ~= nil
					and presenterSource:find(
						"run%.upgradeProgress / SimTuning%.upgradeProgressRequired%(run%.upgradeRound%)"
					) ~= nil
					and presenterSource:find("self%.upgradeFill%.Size = UDim2%.fromScale") ~= nil
					and presenterSource:find("run%.upgradeRound %+ 1") ~= nil
					and presenterSource:find("nextUpgradeTick") == nil
					and presenterSource:find("run%.xp") == nil)
			check("Lucky clears show their combined point award and use the authoritative event",
				clientSource:find("event%.lucky") ~= nil
					and clientSource:find("presenter:showLucky%(event%.points") ~= nil
					and presenterSource:find('makeLabel%(gui, "Lucky"') ~= nil
					and presenterSource:find('"LUCKY!  %+%%d"') ~= nil)
			-- The id is non-zero now, so the disabled path no longer runs anywhere. Keep it checked:
			-- it is what protects a fork, a rollback, or a product taken off sale, and dead code
			-- that nothing exercises is exactly the code that quietly rots.
			-- Robux is real even in Studio, so the grant path needs a way to be exercised that is
			-- not a purchase -- and it has to be the SAME function the receipt calls, or the test
			-- proves only that the mock works.
			check("the revive grant is testable in Studio without a purchase",
				serverSource:find('op == "FORCE_GRANT"') ~= nil
					and serverSource:find("grantRevive%(player, session%)") ~= nil
					and serverSource:find("RunService:IsStudio%(%)") ~= nil)
			-- Tickets replaced the Robux revive (2026-09-10). The run server charges through a seam and
			-- never touches a purchase: receipts belong to PurchaseService, and neither the run server
			-- nor the client may take a closed purchase prompt as proof of payment.
			check("the run server never handles a purchase itself",
				serverSource:find("MarketplaceService") == nil
					and serverSource:find("PromptProductPurchaseFinished") == nil
					and clientSource:find("PromptProductPurchaseFinished") == nil)
			check("a revive is charged in tickets through the bootstrap's seam",
				serverSource:find("function RunServer%.spendTickets") ~= nil
					and serverSource:find("MonetizationConfig%.REVIVE_TICKET_COST") ~= nil)
			check("paid revive eligibility counts completed skips, not boosted points",
				serverSource:find("session%.run%.loops >= MonetizationConfig%.MIN_REVIVE_SKIPS") ~= nil
					and serverSource:find("session%.run%.score >= MonetizationConfig") == nil)
			check("revive resumes through one synchronized server-clock countdown",
				serverSource:find("rearmAuthorityClock%(session, resumeAt%)") ~= nil
					and serverSource:find("startAt = resumeAt") ~= nil
					and clientSource:find("active%.startAt = data%.startAt") ~= nil
					and clientSource:find("active%.started = false") ~= nil
					and clientSource:find("active%.resumeCountdown = true") ~= nil
					and clientSource:find("presenter:setGetReadyCountdown") ~= nil
					and clientSource:find("audio:playCountdown%(remaining%)") ~= nil
					and presenterSource:find('"TAP TO GO!\\n%%d"') ~= nil)
			--[[
				The five seconds after a revive are a BACKSTOP, not a wait. The player taps to go the
				moment their hands are back; the deadline exists only so a revived run can never sit
				frozen, which in a match is indistinguishable from losing.

				The tap must not resume anything locally. It asks, the server answers with the new
				shared moment, and the client adopts that number -- otherwise the two peers begin
				stepping on different ticks and prediction is wrong from its very first frame.
			]]
			check("a tap asks the server to resume and adopts the moment it answers with",
				clientSource:find("RunProtocol%.CLIENT%.RESUME_NOW") ~= nil
					and clientSource:find("active%.resumeRequested = true") ~= nil
					and clientSource:find("elseif op == RunProtocol%.SERVER%.RESUME_AT then") ~= nil
					and serverSource:find("local function resumeRevivedRunNow") ~= nil
					and serverSource:find("RunProtocol%.SERVER%.RESUME_AT") ~= nil)
			check("a tap can only pull the resume moment in, never push it out",
				serverSource:find("if resumeAt >= deadline then") ~= nil)
			check("the resumed moment keeps the network lead the opening GO uses",
				serverSource:find("RunProtocol%.START_LEAD_SECONDS") ~= nil)
			check("only matchmaking card choices carry a visible server-owned five-second deadline",
				serverSource:find("session%.matchId ~= nil") ~= nil
					and serverSource:find("session%.offerDeadline = if") ~= nil
					and serverSource:find("MatchTuning%.CARD_DECISION_SECONDS") ~= nil
					and clientSource:find("active%.offerDeadline") ~= nil
					and presenterSource:find("function RunPresenter%.setOfferDeadline") ~= nil)
			check("the competitive offer visibly counts 5, 4, 3, 2, 1",
				presenterSource:find('string%.format%("AUTO%-PICK IN %%d", math%.ceil%(remaining%)%)') ~= nil)
			check("outer upgrade cards sit symmetrically inward, clear of the left controls when hovered",
				presenterSource:find("0%.25 %+ %(index %- 1%) %* 0%.25") ~= nil)
			check("prediction and an authoritative loss share one deduplicated cartoon death cue",
				clientSource:find("local function playDeathCue") ~= nil
					and clientSource:find('audio:play%("MISS"%)') ~= nil
					and clientSource:find("deathSoundPlayed") ~= nil
					and audioSource:find("rbxasset://sounds/uuhhh%.mp3") ~= nil)
			check("card faces contain only atlas art and a short name",
				presenterSource:find("ImageRectOffset") ~= nil
					and presenterSource:find("card%.description") == nil
					and presenterSource:find("card%.rarity") == nil)
			check("Rocket Shoes exposes an icon-only live fuel gauge",
				presenterSource:find('fuelPanel%.Name = "RocketFuel"') ~= nil
					and presenterSource:find('fuelIcon%.Name = "BootIcon"') ~= nil
					and presenterSource:find("run%.rocketFuel / fuelCapacity") ~= nil
					and presenterSource:find(
						"self%.fuelFill%.Size = UDim2%.fromScale%(ratio, 1%)"
					) ~= nil)
			check("authoritative i-frames pulse and restore character opacity",
				presenterSource:find("run%.invulnerableTicks > 0") ~= nil
					and presenterSource:find("LocalTransparencyModifier") ~= nil
					and presenterSource:find("restoreCharacterOpacity%(self%)") ~= nil)
		end
	end

	-- ── 12. match checkpoints ────────────────────────────────────────────────────────────────
	-- A solo run ends when a rope catches you. A competitive run cannot rely on that, because the
	-- rocket build no longer refills from every upgrade; landing tops the tank. These are the
	-- rules that made a match finite, and the central one is a proof rather than a balance opinion.
	--
	-- RETIRED FROM MATCHES on 2026-09-11: the per-minute cut (§13) now ends every match, and match
	-- runs carry no curve. The mechanism stays in RunSim, tested here, as the floor to bring back if
	-- a cut alone proves too gentle.
	log("\n[12] match checkpoints")
	do
		check("MatchTuning.validate() passes", (MatchTuning.validate()) == true)

		--[[
			NO_ROPE lengthens the PERIOD, but the first sweep is scheduled off GRACE_TICKS and lands
			on tick 90 whatever the period is — so a standing fixture dies long before a checkpoint
			at tick 3600 and would prove nothing about checkpoints at all.

			These tests are about the deadline, not the rope, so the hazard is removed outright.
			Reaching into rope state is a fixture, not a rule: `RunSim` is unchanged and the ordinary
			rope tests in section 4 still own that behaviour.
		]]
		local function withoutRopeHazard(run)
			for _, rope in run.ropes do
				rope.nextSweepTick = 1e9
			end
			return run
		end

		local standard = MatchTuning.setFor(MatchTuning.SET_STANDARD)
		check("the empty set is index 1, so a run that asks for nothing gets no clock",
			#MatchTuning.setFor(MatchTuning.SET_NONE) == 0 and MatchTuning.SET_NONE == 1)
		check("the removals are the user's: 10 points by 0:30 and 25 by 0:60",
			standard[1].atTicks == 30 * SimTuning.TICK_RATE and standard[1].requiredScore == 10
				and standard[2].atTicks == 60 * SimTuning.TICK_RATE and standard[2].requiredScore == 25,
			string.format("%d by tick %d, %d by tick %d", standard[1].requiredScore,
				standard[1].atTicks, standard[2].requiredScore, standard[2].atTicks))
		check("a removal every thirty seconds for ten minutes",
			#standard == 20 and standard[#standard].atTicks == 600 * SimTuning.TICK_RATE)

		local strictlyRising = true
		for index = 2, #standard do
			if standard[index].atTicks <= standard[index - 1].atTicks
				or standard[index].requiredScore <= standard[index - 1].requiredScore then
				strictlyRising = false
			end
		end
		check("every checkpoint demands more, later", strictlyRising)

		--[[
			THE TERMINATION PROOF, exercised here and not only asserted at load.

			`maxAttainableScore` uses proof-only ceilings (not play caps): many ropes, the fastest
			period floor, high Fire, and every clear rolling Lucky, all from tick zero. No real run
			reaches that. The final checkpoint asks for more than it, so no run reaches the final
			checkpoint either — a match cannot outlive the curve, whatever the players build.
		]]
		local final = standard[#standard]
		local ceiling = MatchTuning.maxAttainableScore(final.atTicks)
		check("no run can survive the last checkpoint of the standard curve",
			final.requiredScore > ceiling,
			string.format("asks %d by %.0f min; absolute ceiling is %d",
				final.requiredScore, final.atTicks / SimTuning.TICK_RATE / 60, math.floor(ceiling)))
		check("and it ends inside ten minutes",
			final.atTicks <= 10 * 60 * SimTuning.TICK_RATE,
			string.format("%.1f minutes", final.atTicks / SimTuning.TICK_RATE / 60))

		-- A solo run must be completely unaffected. Checkpoints are opt-in by construction: the
		-- empty set is the default, so nothing can acquire a deadline by accident.
		local solo = withoutRopeHazard(RunSim.new(7, NO_ROPE))
		for _ = 1, standard[1].atTicks + 120 do
			solo:step(false)
		end
		check("a solo run is never judged against a checkpoint",
			solo.alive and solo.checkpointIndex == 0 and solo.score == 0,
			string.format("alive=%s index=%d", tostring(solo.alive), solo.checkpointIndex))

		-- The same run on the competitive set is eliminated when the deadline arrives — on that
		-- exact tick, not one early or late.
		local paced = withoutRopeHazard(RunSim.new(7, NO_ROPE, MatchTuning.SET_STANDARD))
		local deathTick, deathReason, deathRequired = 0, nil, 0
		for _ = 1, standard[1].atTicks + 120 do
			local events = paced:step(false)
			if events then
				for _, e in events do
					if e.kind == RunSim.EVENT.DEATH then
						deathTick, deathReason, deathRequired = e.tick, e.reason, e.requiredScore or 0
					end
				end
			end
			if not paced.alive then
				break
			end
		end
		check("falling behind the pace ends the run exactly on the checkpoint tick",
			not paced.alive
				and deathTick == standard[1].atTicks
				and deathReason == RunSim.DEATH_REASON.CHECKPOINT
				and deathRequired == standard[1].requiredScore,
			string.format("died tick %d, reason %s", deathTick, tostring(deathReason)))

		-- Meeting the requirement exactly survives it, and the pass is reported so the HUD can
		-- show it. A boundary that kills a player who hit the number would be indefensible.
		local ahead = withoutRopeHazard(RunSim.new(7, NO_ROPE, MatchTuning.SET_STANDARD))
		ahead.score = standard[1].requiredScore
		local passedIndex = 0
		for _ = 1, standard[1].atTicks + 5 do
			local events = ahead:step(false)
			if events then
				for _, e in events do
					if e.kind == RunSim.EVENT.CHECKPOINT_PASSED then
						passedIndex = e.checkpointIndex or 0
					end
				end
			end
		end
		check("meeting the requirement exactly survives it and reports the pass",
			ahead.alive and passedIndex == 1 and ahead.checkpointIndex == 1,
			string.format("alive=%s passed=%d", tostring(ahead.alive), passedIndex))

		-- A checkpoint is judged once. Rebuilding from authority mid-match must not re-test history.
		local resumed = RunSim.fromSnapshot(RunSim.snapshot(ahead))
		check("checkpoint progress survives an authoritative snapshot",
			resumed.checkpointIndex == ahead.checkpointIndex
				and resumed.checkpointSet == ahead.checkpointSet
				and resumed.digest == ahead.digest)

		-- Two runs on one seed and one set are the same course. This is the property the whole
		-- competitive mode rests on: nobody gets an easier rope than the person they are racing.
		local a = RunSim.new(99, nil, MatchTuning.SET_STANDARD)
		local b = RunSim.new(99, nil, MatchTuning.SET_STANDARD)
		local sameCourse = true
		for tick = 1, 400 do
			local down = tick % 37 <= 2
			a:step(down)
			b:step(down)
			if a.digest ~= b.digest then
				sameCourse = false
				break
			end
		end
		check("a shared seed and checkpoint set is a shared course", sameCourse,
			string.format("digest %d", a.digest))
	end

	-- ── 13. matches ──────────────────────────────────────────────────────────────────────────
	-- Ranking is the part of a match a player would notice being wrong, so it lives in a pure
	-- module and is tested directly rather than through a running server. The rest of this section
	-- is about the seams: one seed for everyone, and a dead competitor who stays dead.
	log("\n[13] matches")
	do
		check("MatchProtocol.validate() passes", (MatchProtocol.validate()) == true)
		check("MatchRules.validate() passes", (MatchRules.validate()) == true)
		check("a lobby fills toward eight, with bots after a short wait",
			MatchProtocol.LOBBY_TARGET == 8
				and MatchProtocol.BOT_FILL_SECONDS > 0
				and MatchProtocol.BOT_FILL_SECONDS <= 10,
			string.format("target %d, bots after %ds", MatchProtocol.LOBBY_TARGET,
				MatchProtocol.BOT_FILL_SECONDS))

		--[[
			THE RULE THE USER SET. Dying does not remove you from contention: your score stands, and
			if the field cannot beat it while they play on, you win from the grave. Ranking must
			therefore never consult liveness for order.
		]]
		local graveyard = MatchRules.rank({
			{ userId = 11, name = "alive-but-behind", score = 30, loops = 7, tick = 900, alive = true },
			{ userId = 22, name = "dead-in-front", score = 41, loops = 9, tick = 700, alive = false,
				deathReason = RunSim.DEATH_REASON.ROPE },
			{ userId = 33, name = "eliminated", score = 12, loops = 4, tick = 3600, alive = false,
				deathReason = RunSim.DEATH_REASON.CHECKPOINT },
		})
		check("a dead player with the highest score is still winning",
			graveyard[1].userId == 22 and not graveyard[1].alive and graveyard[1].place == 1,
			string.format("first is %s", graveyard[1].name))
		check("placings carry why each run ended",
			graveyard[1].deathReason == RunSim.DEATH_REASON.ROPE
				and graveyard[3].deathReason == RunSim.DEATH_REASON.CHECKPOINT)

		-- Equal scores break toward the faster run: the checkpoint curve rewards scoring rate, so
		-- the tie-break should agree with it rather than reward sitting around.
		local tied = MatchRules.rank({
			{ userId = 1, name = "slow", score = 50, loops = 10, tick = 1200, alive = false },
			{ userId = 2, name = "fast", score = 50, loops = 10, tick = 800, alive = false },
		})
		check("the same score reached faster places higher", tied[1].userId == 2)

		--[[
			A ranking that depends on input order is a ranking that can disagree with itself. Luau's
			`table.sort` is not stable, so genuinely identical entries need an explicit final
			tie-break or two machines could hand back different winners for the same match.
		]]
		local identical = {
			{ userId = 7, name = "g", score = 25, loops = 5, tick = 600, alive = false },
			{ userId = 4, name = "d", score = 25, loops = 5, tick = 600, alive = false },
			{ userId = 9, name = "i", score = 25, loops = 5, tick = 600, alive = false },
		}
		local firstOrder = MatchRules.rank(identical)
		local reversed = { identical[3], identical[2], identical[1] }
		local secondOrder = MatchRules.rank(reversed)
		local stable = true
		for index = 1, #firstOrder do
			if firstOrder[index].userId ~= secondOrder[index].userId then
				stable = false
			end
		end
		check("identical runs rank identically however they arrive", stable,
			string.format("%d, %d, %d", firstOrder[1].userId, firstOrder[2].userId, firstOrder[3].userId))
		check("ranking never mutates the list it was handed",
			identical[1].userId == 7 and identical[3].userId == 9)

		-- Being dead is not being finished: a revive may still be coming, and the user chose to allow
		-- that in matches. Since the cut (2026-09-11) a lone runner who leads outright has already
		-- won, and one still behind a fallen leader has not.
		local roster = {
			{ userId = 1, name = "a", score = 10, loops = 3, tick = 400, alive = false },
			{ userId = 2, name = "b", score = 20, loops = 6, tick = 700, alive = true },
		}
		check("two runners still in is a match still being played",
			MatchRules.isDecided(roster, { [1] = false, [2] = false }) == false)
		check("a lone runner who leads everyone outright has already won",
			MatchRules.isDecided(roster, { [1] = true, [2] = false }) == true)
		check("a match resolves once everyone is finished",
			MatchRules.isDecided(roster, { [1] = true, [2] = true }) == true)
		check("a dead player who may still revive, behind the leader, holds the match open",
			MatchRules.isDecided(roster, { [1] = false, [2] = true }) == false)

		-- The live table a player watches all match is the one that decides it. Same function,
		-- so there is no reordering surprise at the buzzer.
		local live = MatchRules.liveTable(roster)
		local final = MatchRules.rank(roster)
		check("the live scoreboard and the final placings use one ordering",
			live[1].userId == final[1].userId and live[2].userId == final[2].userId)

		--[[
			THE CUT (the user, 2026-09-11): "every minute it should eliminate one player... the player
			with the least amount of points... so the max length time will be 8 minutes." Pure, so it
			is tested here directly, including that it really does end every match.
		]]
		local field = {
			{ userId = 1, name = "leader", score = 90, loops = 20, tick = 3000, alive = true },
			{ userId = 2, name = "fallen", score = 60, loops = 14, tick = 1500, alive = false },
			{ userId = 3, name = "middle", score = 40, loops = 10, tick = 3000, alive = true },
			{ userId = 4, name = "last", score = 12, loops = 4, tick = 3000, alive = true },
		}
		local firstCut = MatchRules.cutCandidate(field, { [2] = true })
		check("the cut takes the lowest runner still in",
			firstCut ~= nil and firstCut.userId == 4, if firstCut then firstCut.name else "nobody")
		local notTwice = MatchRules.cutCandidate(field, { [2] = true, [4] = true })
		check("someone already out is never cut again, however low their score",
			notTwice ~= nil and notTwice.userId == 3)
		local tieCut = MatchRules.cutCandidate({
			{ userId = 1, name = "quick", score = 10, loops = 3, tick = 500, alive = true },
			{ userId = 2, name = "slow", score = 10, loops = 3, tick = 700, alive = true },
			{ userId = 3, name = "top", score = 50, loops = 9, tick = 700, alive = true },
		}, {})
		check("a tie at the bottom goes the way the table orders it: the slower run is cut",
			tieCut ~= nil and tieCut.userId == 2)

		-- Duels are never cut (the user, 2026-09-11): the most points at a five-minute buzzer wins, with
		-- a one-minute warning at 4:00 that changes no rule.
		local buzzer = MatchRules.rank({
			{ userId = 1, name = "points", score = 90, loops = 20, tick = 18000, alive = true },
			{ userId = 2, name = "skips", score = 40, loops = 25, tick = 18000, alive = true },
		})
		check("a duel's buzzer is decided on points, like everything else", buzzer[1].userId == 1)
		check("a duel warns at 4:00 and ends at 5:00",
			MatchTuning.DUEL_FINAL_MINUTE_SECONDS == 240 and MatchTuning.DUEL_CUTOFF_SECONDS == 300)

		-- Played out: a full lobby where one runner fell early with a score nobody catches, and the
		-- rest keep scoring at their own rates. Every minute the bottom runner goes; the last one left
		-- must be cut too, for failing to catch the fallen leader -- all within eight cuts.
		local lobby = {}
		local lobbyOut: { [number]: boolean } = {}
		for index = 1, 8 do
			lobby[index] = { userId = index, name = "r" .. index, score = 0, loops = 0, tick = 0, alive = true }
			lobbyOut[index] = false
		end
		lobby[8].score, lobby[8].alive, lobbyOut[8] = 10000, false, true
		local cuts = 0
		while not MatchRules.isDecided(lobby, lobbyOut) and cuts < 20 do
			for index, runner in lobby do
				if not lobbyOut[index] then
					runner.score += index * 60
					runner.tick += 60 * SimTuning.TICK_RATE
				end
			end
			cuts += 1
			local victim = MatchRules.cutCandidate(lobby, lobbyOut)
			if victim then
				lobbyOut[victim.userId] = true
				lobby[victim.userId].alive = false
			end
		end
		check("a full lobby is decided within eight cuts, even chasing a fallen leader",
			MatchRules.isDecided(lobby, lobbyOut) and cuts <= 8 and MatchRules.rank(lobby)[1].userId == 8,
			string.format("%d cuts", cuts))
		check("a cut comes once a minute", MatchTuning.CUT_INTERVAL_SECONDS == 60)

		-- One seed and one checkpoint set is the entire fairness guarantee: rope timings, card
		-- rolls and Luck procs are identical for everyone in the match.
		local seed = 4242
		local one = RunSim.new(seed, nil, MatchTuning.SET_STANDARD)
		local two = RunSim.new(seed, nil, MatchTuning.SET_STANDARD)
		local sameCourse = true
		for tick = 1, 600 do
			local down = tick % 41 <= 2
			one:step(down)
			two:step(down)
			if one.digest ~= two.digest then
				sameCourse = false
				break
			end
		end
		check("two match runs on one seed are the same course", sameCourse,
			string.format("digest %d after %d ticks", one.digest, one.tick))

		-- Different inputs on the same course must still diverge, or the "same seed" property would
		-- be hiding a simulation that ignores the player.
		local diverged = RunSim.new(seed, nil, MatchTuning.SET_STANDARD)
		for tick = 1, 600 do
			diverged:step(tick % 23 <= 4)
		end
		check("the same course still rewards different play",
			diverged.digest ~= one.digest)

		--[[
			SOURCE INVARIANTS FOR THE MATCH SEAM.

			These are about shape, because the failures they catch are silent. A match that let
			`startRun` fire on death would resurrect a dead competitor into a fresh solo run and
			nobody would see an error; a match that generated a seed per participant would hand
			everyone a different course and still look like it worked.
		]]
		local serverRoot = game:GetService("ServerScriptService"):FindFirstChild("Server")
		local matchModule = serverRoot and serverRoot:FindFirstChild("MatchService")
		local runModule = serverRoot and serverRoot:FindFirstChild("RunServer")
		local bootModule = serverRoot and serverRoot:FindFirstChild("Main")
		check("the match service is synced and started", matchModule ~= nil and bootModule ~= nil)
		if matchModule and matchModule:IsA("ModuleScript")
			and runModule and runModule:IsA("ModuleScript")
			and bootModule and bootModule:IsA("LuaSourceContainer") then
			local matchSource = matchModule.Source
			local runSource = runModule.Source
			local bootSource = bootModule.Source

			check("the bootstrap starts runs before matches",
				bootSource:find("RunServer%.start%(%)") ~= nil
					and bootSource:find("MatchService%.start%(%)") ~= nil
					and (bootSource:find("RunServer%.start%(%)") :: number)
						< (bootSource:find("MatchService%.start%(%)") :: number))

			-- The load-bearing flag. Without it a dead competitor restarts into a solo run.
			check("a match run never auto-restarts on death",
				matchSource:find("autoRestart = false") ~= nil)
			check("every post-death restart goes through one policy",
				runSource:find("local function restartOrFinish") ~= nil
					and select(2, runSource:gsub("restartOrFinish%(player, session%)", "")) >= 4)

			-- One seed, handed out together, or players are not racing. No curve since the cut.
			check("every participant is handed the same seed, and no checkpoint curve",
				matchSource:find("seed = match%.seed") ~= nil
					and matchSource:find("checkpointSet = MatchTuning%.SET_NONE") ~= nil
					and matchSource:find("SET_STANDARD") == nil
					-- Exactly ONE seed is drawn per match. A second draw anywhere in this file would
					-- be a per-player seed, which is the same defect as no shared seed at all:
					-- everyone racing on a different course while the scoreboard pretends otherwise.
					and select(2, matchSource:gsub("seedSource:NextInteger", "")) == 1)

			-- A match may read a run. It may never step or score one.
			check("the match service never reaches into the simulation",
				matchSource:find("RunServer%.summaryOf") ~= nil
					and matchSource:find(":step%(") == nil
					and matchSource:find("RunSim%.") == nil)
			-- It ends one in exactly one way -- the cut, or the match being decided -- and only by
			-- asking the run's owner, which then refuses any revive for that run.
			check("a match ends a run only through the cut, by asking the run's owner",
				matchSource:find("local function runCut") ~= nil
					and matchSource:find("MatchRules%.cutCandidate") ~= nil
					and matchSource:find("RunServer%.retireFromMatch%(p%.player, cut%)") ~= nil
					and matchSource:find("BotRunner%.retire%(p%.bot, cut%)") ~= nil
					and runSource:find("function RunServer%.retireFromMatch") ~= nil
					and runSource:find("and not session%.retired") ~= nil)
			check("every client hears when the next cut comes and who is in danger",
				matchSource:find("else match%.nextCutAt") ~= nil
					and matchSource:find("row%.danger = ") ~= nil
					and matchSource:find("MatchTuning%.CUT_INTERVAL_SECONDS") ~= nil)
			check("a duel is never cut: a warning at 4:00, and the most points at the 5:00 buzzer",
				matchSource:find("MatchTuning%.DUEL_FINAL_MINUTE_SECONDS") ~= nil
					and matchSource:find("MatchTuning%.DUEL_CUTOFF_SECONDS") ~= nil
					and matchSource:find("local function reachCutoff") ~= nil
					and matchSource:find("cutoffAt = if duel then match%.cutoffAt") ~= nil)

			-- Every waiting state is bounded. A screen that never changes is the thing a player
			-- cannot recover from.
			check("queues, challenges and countdowns are all bounded",
				matchSource:find("BOT_FILL_SECONDS") ~= nil
					and matchSource:find("CHALLENGE_TIMEOUT_SECONDS") ~= nil
					and matchSource:find("COUNTDOWN_SECONDS") ~= nil
					and matchSource:find("lastChallengeAt%[player%]") ~= nil
					and matchSource:find("CHALLENGE_COOLDOWN_SECONDS") ~= nil)

			-- Forfeiting keeps the score already earned: leaving is not a way to erase a bad run.
			check("leaving a match finishes the player rather than deleting their score",
				matchSource:find("local function leaveMatch") ~= nil
					and matchSource:find("markFinished%(match, participant%)") ~= nil)
		end

		--[[
			THE CLIENT SIDE OF THE SEAM.

			The scoreboard a player watches all match is the one that decides it, so the client must
			render the order it was given and never form a second opinion. A local sort would be
			exactly that second opinion, and the two could disagree at the worst possible moment.
		]]
		local clientRoot = game:GetService("StarterPlayer").StarterPlayerScripts:FindFirstChild("Client")
		local matchClient = clientRoot and clientRoot:FindFirstChild("MatchClient")
		local matchUi = clientRoot and clientRoot:FindFirstChild("MatchPresenter")
		local mainClient = clientRoot and clientRoot:FindFirstChild("Main")
		check("the match client and its screens are synced",
			matchClient ~= nil and matchUi ~= nil)
		if matchClient and matchClient:IsA("ModuleScript")
			and matchUi and matchUi:IsA("ModuleScript")
			and mainClient and mainClient:IsA("LuaSourceContainer") then
			local clientSrc = matchClient.Source
			local uiSrc = matchUi.Source
			local mainSrc = mainClient.Source

			check("the client never re-ranks what the server sent",
				clientSrc:find("table%.sort") == nil and uiSrc:find("table%.sort") == nil)
			check("match presentation cannot reach the simulation",
				uiSrc:find("RunSim") == nil and clientSrc:find("RunSim") == nil
					and uiSrc:find(":step%(") == nil)
			check("match countdowns render against the server clock, not a local one",
				clientSrc:find("workspace:GetServerTimeNow%(%)") ~= nil
					and clientSrc:find("rosterStartAt") ~= nil)

			-- Deleting the whole match layer must leave a playable solo game (§6.4). The only thing
			-- the run client knows about it is one side-effect require.
			check("the run client depends on the match layer only to load it",
				mainSrc:find('require%(script%.Parent:WaitForChild%("MatchClient"%)%)') ~= nil
					and select(2, mainSrc:gsub("MatchClient", "")) == 1)
			check("match screens live on their own ScreenGui, above the run HUD",
				uiSrc:find('gui%.Name = "SkipsMatch"') ~= nil
					and uiSrc:find("gui%.DisplayOrder = 20") ~= nil)

			-- A dead player is dimmed, never removed: their score still counts and can still win,
			-- which is the rule the whole mode turns on.
			check("the live table dims eliminated players instead of dropping them",
				uiSrc:find("local out = e%.alive == false") ~= nil
					and uiSrc:find("slot%.row%.Visible = false") ~= nil)
			check("a solo player is never forced through a multiplayer panel",
				uiSrc:find('button%(gui, "Entry"') ~= nil)
			check("a duel's timer turns from green to gold to red as it nears zero",
				uiSrc:find("function MatchPresenter%.setDuelTimer") ~= nil
					and uiSrc:find("GREEN:Lerp%(GOLD") ~= nil and uiSrc:find("GOLD:Lerp%(CORAL") ~= nil
					and clientSrc:find("presenter:setDuelTimer%(cutoffAt %- now%)") ~= nil)
			check("the matchmaking bars fill as rounded pills too",
				uiSrc:find("barCorner%.CornerRadius = UDim%.new%(1, 0%)") ~= nil)
		end

		if matchModule and matchModule:IsA("ModuleScript") then
			local matchSrc = matchModule.Source
			-- The farm the user asked to close: queue a duel, wait for the bot fill, beat it,
			-- repeat. A padded duel is practice; matchmaking counts either way.
			check("a duel padded with a bot is not worth a win",
				matchSrc:find("awardsWin = not %(mode == MatchProtocol%.MODE%.DUEL and botCount > 0%)") ~= nil)
			check("a bot topping the table is nobody's win",
				matchSrc:find("winner%.isBot ~= true") ~= nil)
			-- Bots face the same rope as the humans beside them, or their score means nothing next
			-- to a real one.
			check("bots are spawned on the match's own seed, with no curve",
				matchSrc:find("BotRunner%.spawn%(match%.seed, MatchTuning%.SET_NONE%)") ~= nil)
			check("bots advance on the fixed timestep, not the scoreboard clock",
				matchSrc:find("BotRunner%.advance%(bot, dt, RunProtocol%.MAX_STEPS_PER_FRAME%)") ~= nil)
			check("real opponents are preferred and bots only fill after the wait",
				matchSrc:find("waitedFor%(leftover, now%) >= MatchProtocol%.BOT_FILL_SECONDS") ~= nil
					and matchSrc:find("waitedFor%(head, now%) >= MatchProtocol%.BOT_FILL_SECONDS") ~= nil)
			-- Studio's Server & Clients mode names its simulated players Player1, Player2... with
			-- UserIds -1, -2... Bots once started at -1, so the first bot and the first test player
			-- shared a key in `byUserId` and one silently overwrote the other -- in precisely the mode
			-- anyone would reach for to test matchmaking. Bots now start a million below zero.
			local botModule = serverRoot and serverRoot:FindFirstChild("BotRunner")
			local botSrc = if botModule and botModule:IsA("ModuleScript") then botModule.Source else ""
			check("bot ids can never collide with Studio's simulated test players",
				botSrc:find("local BOT_ID_BASE = %-1000000") ~= nil
					and botSrc:find("userId = BOT_ID_BASE %- nextBotSerial") ~= nil
					and botSrc:find("userId = %-nextBotSerial") == nil)
		end
	end

	-- ── 14. bots ─────────────────────────────────────────────────────────────────────────────
	-- Bots exist so a queue never strands anyone. The design claim worth testing is the one the
	-- user asked for: that they do not really win. They are not handicapped physics -- they play
	-- the real game and take the SAFE cards, so they score slower and the cut takes them. These tests
	-- drive `BotPolicy` over a real `RunSim`, which is exactly what `BotRunner` does on the server.
	log("\n[14] bots")
	do
		check("BotPolicy.validate() passes", (BotPolicy.validate()) == true)

		-- The mechanism that makes bots lose is which cards they refuse. If either multiplier ever
		-- reaches this list, bots keep pace with the curve and the whole design quietly inverts.
		local seenMultiplier, safeRankedBelow, takesExtraRope = false, false, false
		for _, id in BotPolicy.PREFERRED_CARDS do
			if id == "ADD_JUMPROPE" then
				takesExtraRope = true
			end
			if BotPolicy.MULTIPLIER_CARDS[id] then
				seenMultiplier = true
			elseif seenMultiplier then
				safeRankedBelow = true
			end
		end
		check("a bot prefers every safe card over a score multiplier",
			seenMultiplier and not safeRankedBelow)
		-- Add Jumprope is allowed but ranked last, so a bot builds toward more ropes slowly. It only
		-- became survivable once the planner started re-targeting on the soonest sweep.
		check("a bot will reach for more ropes, but only as a last resort", takesExtraRope)
		check("the planner re-targets when another rope sweeps sooner",
			BotPolicy.shouldReplan({ tick = 5, ropes = { { nextSweepTick = 9 } } },
				{ pressAtTick = 20, releaseAtTick = 23, sweepTick = 30 }) == true)
		check("the planner keeps a plan that is still the soonest hazard",
			BotPolicy.shouldReplan({ tick = 5, ropes = { { nextSweepTick = 30 } } },
				{ pressAtTick = 20, releaseAtTick = 23, sweepTick = 30 }) == false)

		-- Given an offer containing a multiplier and a safe card, it reaches past the multiplier.
		local offered = {
			CardCatalog.get("ADD_JUMPROPE"),
			CardCatalog.get("REINFORCE_JUMP_ROPE"),
			CardCatalog.get("IGNITE_JUMPROPE"),
		}
		check("with no skill to weigh, a bot defaults to the conservative card",
			(function()
				local picked = BotPolicy.chooseCard(offered)
				return picked ~= nil and picked.id == "REINFORCE_JUMP_ROPE"
			end)())

		-- The taste dial. At a high safe bias the bot hoards; at a low one it builds. Both must be
		-- reachable, or the difficulty bands are decoration.
		local hoarder = { leadTicks = 11, holdTicks = 3, jitterTicks = 0,
			whiffPercent = 0, safeBiasPercent = 99 }
		local builder = { leadTicks = 11, holdTicks = 3, jitterTicks = 0,
			whiffPercent = 0, safeBiasPercent = 1 }
		local safePicks, greedyPicks = 0, 0
		for seed = 1, 40 do
			local a = BotPolicy.chooseCard(offered, hoarder, Rng.new(seed))
			local b = BotPolicy.chooseCard(offered, builder, Rng.new(seed))
			if a and a.id == "REINFORCE_JUMP_ROPE" then safePicks += 1 end
			if b and BotPolicy.MULTIPLIER_CARDS[b.id] then greedyPicks += 1 end
		end
		check("card taste actually follows the skill band's bias",
			safePicks >= 35 and greedyPicks >= 35,
			string.format("%d/40 safe at bias 99, %d/40 greedy at bias 1", safePicks, greedyPicks))

		--[[
			Plays a bot: policy for input, preferred cards on every offer, and no checkpoint curve, as
			match runs have none since the cut. Returns the run so the caller can inspect how it died.
		]]
		local function playBot(seed: number, skill, maxTicks: number)
			local run = RunSim.new(seed, nil, MatchTuning.SET_NONE)
			local rng = Rng.new(seed + 7919)
			local stacks: { [string]: number } = {}
			local plan = nil
			local reason: string? = nil
			for _ = 1, maxTicks do
				if not run.alive then
					break
				end
				if not plan or run.tick >= plan.sweepTick then
					plan = BotPolicy.plan(run, skill, rng)
				end
				local events = run:step(BotPolicy.isDown(plan, run.tick + 1))
				if events then
					for _, e in events do
						if e.kind == RunSim.EVENT.DEATH then
							reason = e.reason
						end
						if e.kind == RunSim.EVENT.UPGRADE_READY
							and CardCatalog.eligibleCount(stacks, run.stats) > 0 then
							local offer = CardCatalog.rollOffer(run.rng, run.stats.luck, stacks, run.stats)
							local card = BotPolicy.chooseCard(offer)
							local owned = stacks[card.id] or 0
							if CardCatalog.isEligible(card, stacks, run.stats) then
								stacks[card.id] = owned + 1
								RunSim.applyStatEffects(run, card.effects)
								RunSim.resumeAfterUpgrade(run)
							end
						end
					end
				end
			end
			return run, reason, stacks
		end

		--[[
			THE CLAIM, TESTED, for the cut (2026-09-11). Every minute the lowest runner still in is
			out, so a bot loses the way the design intends -- by taste, not by handicap. The strongest
			band, choosing cards with its own taste as BotRunner does, is set against a greedy stand-in
			with perfect timing that takes every multiplier; over ten seeds the greedy build must
			outscore it by the first cut, and by a wide margin. Measured 2026-09-11: 133 against 30.
		]]
		local function scoreAtFirstCut(seed: number, skill): number
			local run = RunSim.new(seed, nil, MatchTuning.SET_NONE)
			local rng = Rng.new(seed + 7919)
			local stacks: { [string]: number } = {}
			local plan = nil
			for _ = 1, MatchTuning.CUT_INTERVAL_SECONDS * SimTuning.TICK_RATE do
				if not run.alive then
					break
				end
				if BotPolicy.shouldReplan(run, plan) then
					plan = BotPolicy.plan(run, skill, rng)
				end
				local events = run:step(BotPolicy.isDown(plan, run.tick + 1))
				if events then
					for _, e in events do
						if e.kind == RunSim.EVENT.UPGRADE_READY
							and CardCatalog.eligibleCount(stacks, run.stats) > 0 then
							local offer = CardCatalog.rollOffer(run.rng, run.stats.luck, stacks, run.stats)
							local card = BotPolicy.chooseCard(offer, skill, rng)
							local owned = if card then stacks[card.id] or 0 else 0
							if card and CardCatalog.isEligible(card, stacks, run.stats) then
								stacks[card.id] = owned + 1
								RunSim.applyStatEffects(run, card.effects)
								RunSim.resumeAfterUpgrade(run)
							end
						end
					end
				end
			end
			return run.score
		end
		local best = BotPolicy.SKILLS[#BotPolicy.SKILLS]
		local greedy = { leadTicks = 11, holdTicks = 4, jitterTicks = 0, whiffPercent = 0, safeBiasPercent = 1 }
		local botTotal, greedyTotal = 0, 0
		for seed = 1, 10 do
			botTotal += scoreAtFirstCut(seed * 97 + 5, best)
			greedyTotal += scoreAtFirstCut(seed * 97 + 5, greedy)
		end
		check("a greedy build outscores the strongest bot by the first cut",
			greedyTotal > botTotal * 2,
			string.format("mean %.1f against the bot's %.1f", greedyTotal / 10, botTotal / 10))

		local bot = playBot(2026, best, 3 * 60 * SimTuning.TICK_RATE)
		check("a bot still plays well enough to be worth beating",
			bot.loops > 10,
			string.format("%d clears", bot.loops))

		-- Deterministic from the seed, like every other run in this game. Two servers replaying one
		-- bot must produce one bot, or a match could not be verified after the fact.
		local a, aReason = playBot(31337, best, 900)
		local b, bReason = playBot(31337, best, 900)
		check("a bot is reproducible from its seed",
			a.digest == b.digest and a.score == b.score and aReason == bReason,
			string.format("digest %d, score %d", a.digest, a.score))

		-- Different bands really are different players, not the same run relabelled.
		local weak = playBot(31337, BotPolicy.SKILLS[1], 900)
		check("skill bands produce genuinely different runs", weak.digest ~= a.digest)

		-- A whiff must actually skip the jump rather than silently pressing anyway.
		check("a plan of nil means the button stays up",
			BotPolicy.isDown(nil, 100) == false)
		-- A whiff must COMMIT to missing that sweep. It used to come back as nil, which the planner
		-- read as plan again, so the miss was re-rolled every tick and bots almost never missed.
		local alwaysWhiff = { leadTicks = 11, holdTicks = 3, jitterTicks = 0, whiffPercent = 99,
			safeBiasPercent = 50 }
		local whiffPlan = BotPolicy.plan({ tick = 5, ropes = { { nextSweepTick = 100 } } },
			alwaysWhiff, Rng.new(3))
		check("a whiff commits to skipping that sweep instead of re-rolling next tick",
			whiffPlan ~= nil and BotPolicy.isDown(whiffPlan, 89) == false
				and BotPolicy.shouldReplan({ tick = 6, ropes = { { nextSweepTick = 100 } } },
					whiffPlan) == false)
		local held = BotPolicy.isDown({ pressAtTick = 10, releaseAtTick = 13, sweepTick = 21 }, 11)
		local released = BotPolicy.isDown({ pressAtTick = 10, releaseAtTick = 13, sweepTick = 21 }, 13)
		check("a bot holds only across its planned window", held and not released)
	end

	-- ── 15. leaderboards ─────────────────────────────────────────────────────────────────────
	-- The persistence layer cannot be exercised here: `DataStoreService` is unreachable while the
	-- place is unlinked. So everything that CAN be pure is pure — period rollover and number
	-- formatting — and the rest is pinned at the source, which is the only honest coverage
	-- available until the place is published.
	log("\n[15] leaderboards")
	do
		check("Leaderboards.validate() passes", (Leaderboards.validate()) == true)
		check("the boards the user asked for: solo, duo, group and ranked",
			#Leaderboards.BOARDS == 4 and #Leaderboards.PERIODS == 3
				and Leaderboards.BOARD.SOLO ~= nil and Leaderboards.BOARD.DUO ~= nil
				and Leaderboards.BOARD.GROUP ~= nil and Leaderboards.BOARD.RANKED ~= nil)
		-- A rating is a standing, not a tally. "Your rating this week" would be a second number for
		-- the same thing, and the moment it disagreed with the ranked screen one of them would lie.
		check("ranked has no daily or weekly board",
			#Leaderboards.periodsFor("RANKED") == 1
				and Leaderboards.isValid("RANKED", "ALL_TIME")
				and not Leaderboards.isValid("RANKED", "DAILY")
				and Leaderboards.isValid("SOLO", "DAILY")
				and not Leaderboards.isValid("WINS", "DAILY"))
		check("a duel counts on the duo board and a lobby on the group board",
			Leaderboards.boardForMatchMode("DUEL") == "DUO"
				and Leaderboards.boardForMatchMode("LOBBY") == "GROUP")
		check("a rank reads exactly, and says so when the count stopped early",
			Leaderboards.formatRank(12, false) == "#12"
				and Leaderboards.formatRank(1234, false) == "#1,234"
				and Leaderboards.formatRank(500, true) == "500+"
				and Leaderboards.formatRank(nil, false) ~= "")

		--[[
			ROLLOVER IS THE STORE NAME. A new day is a new, empty store and yesterday's is untouched,
			which is why nothing anywhere resets a board. The alternative — one store plus a
			scheduled wipe — needs a job that must never fail and loses history when it does.
		]]
		local t = 1789000000
		local day = 86400
		check("a new UTC day is a different store",
			Leaderboards.keyFor("DUO", "DAILY", t) ~= Leaderboards.keyFor("DUO", "DAILY", t + day))
		check("the same UTC day is the same store",
			Leaderboards.keyFor("DUO", "DAILY", t) == Leaderboards.keyFor("DUO", "DAILY", t + 60))
		check("all-time never rolls over",
			Leaderboards.keyFor("DUO", "ALL_TIME", t)
				== Leaderboards.keyFor("DUO", "ALL_TIME", t + day * 900))
		check("publishing cannot silently rename or reset the permanent leaderboard stores",
			Leaderboards.keyFor("SOLO", "ALL_TIME", t) == "LB_S_ALL"
				and Leaderboards.keyFor("DUO", "ALL_TIME", t) == "LB_D_ALL"
				and Leaderboards.keyFor("GROUP", "ALL_TIME", t) == "LB_G_ALL"
				and Leaderboards.keyFor("RANKED", "ALL_TIME", t) == "LB_R_ALL")

		-- Weeks must start on Monday. A weekly board that resets on a Thursday is the kind of thing
		-- nobody notices until a player asks why.
		-- 1970-01-05 was the first Monday of the epoch; 1970-01-04 (Sunday) must be the week before.
		local mondayFirst = 4 * day        -- Mon 5 Jan 1970 00:00 UTC
		local sundayBefore = mondayFirst - 60
		check("a week boundary falls on Monday, not Thursday",
			Leaderboards.weekNumber(mondayFirst) ~= Leaderboards.weekNumber(sundayBefore)
				and Leaderboards.weekNumber(mondayFirst)
					== Leaderboards.weekNumber(mondayFirst + day * 6),
			string.format("mon=%d, sun before=%d",
				Leaderboards.weekNumber(mondayFirst), Leaderboards.weekNumber(sundayBefore)))

		-- Six distinct stores, none colliding, all inside Roblox's 50-character name cap.
		local names: { [string]: boolean } = {}
		local collided, tooLong = false, false
		for _, board in Leaderboards.BOARDS do
			for _, period in Leaderboards.periodsFor(board) do
				local key = Leaderboards.keyFor(board, period, 4102444800)
				if names[key] then collided = true end
				if #key > 50 then tooLong = true end
				names[key] = true
			end
		end
		check("every board has its own store name, within the length cap",
			not collided and not tooLong)

		--[[
			THE USER'S REQUIREMENT: "make sure for points you can know what number is it".

			`formatExact` is what a leaderboard row uses, and it is exact — an abbreviation cannot
			satisfy that. `formatShort` exists only for genuinely narrow space and keeps three
			significant figures so it is never more than about half a percent out.
		]]
		check("the exact form is exact, and grouped",
			Leaderboards.formatExact(0) == "0"
				and Leaderboards.formatExact(999) == "999"
				and Leaderboards.formatExact(1000) == "1,000"
				and Leaderboards.formatExact(120727) == "120,727"
				and Leaderboards.formatExact(1234567) == "1,234,567",
			Leaderboards.formatExact(1234567))
		check("the short form keeps three significant figures",
			Leaderboards.formatShort(1234) == "1.23K"
				and Leaderboards.formatShort(1234567) == "1.23M"
				and Leaderboards.formatShort(12345678) == "12.3M"
				and Leaderboards.formatShort(1500000000) == "1.5B",
			Leaderboards.formatShort(12345678))
		check("small numbers are never abbreviated, because it buys nothing",
			Leaderboards.formatShort(7) == "7" and Leaderboards.formatShort(999) == "999")

		-- The bound that makes the short form trustworthy at a glance.
		local worstError = 0
		for _, value in {1000, 1049, 4321, 99999, 123456, 987654321, 5555555555} do
			local text = Leaderboards.formatShort(value)
			local scale = ({ K = 1e3, M = 1e6, B = 1e9, T = 1e12 })[text:sub(-1)]
			if scale then
				local parsed = tonumber(text:sub(1, -2)) * scale
				worstError = math.max(worstError, math.abs(parsed - value) / value)
			end
		end
		check("the short form is never far from the truth",
			worstError < 0.006, string.format("worst error %.3f%%", worstError * 100))

		-- Source invariants: the parts that cannot run here.
		local serverRoot = game:GetService("ServerScriptService"):FindFirstChild("Server")
		local lbModule = serverRoot and serverRoot:FindFirstChild("LeaderboardService")
		local bootModule = serverRoot and serverRoot:FindFirstChild("Main")
		check("the leaderboard service is synced", lbModule ~= nil)
		if lbModule and lbModule:IsA("ModuleScript")
			and bootModule and bootModule:IsA("LuaSourceContainer") then
			local lbSrc = lbModule.Source
			local bootSrc = bootModule.Source

			-- A leaderboard that took the match down with it would be worse than no leaderboard.
			-- A failed read must say "offline", never show an empty board, which reads as "nobody has
			-- played"; and one failed call on a live server must not switch the boards off for good.
			check("every DataStore call goes through StoreAccess, and a failed read is never an empty board",
				lbSrc:find("StoreAccess%.try") ~= nil and lbSrc:find("StoreAccess%.write") ~= nil
					and lbSrc:find("local available = true") == nil
					and lbSrc:find("if not fresh then") ~= nil)
			check("leaderboard writes receive a bounded server-shutdown drain",
				lbSrc:find("local pendingWrites = 0") ~= nil
					and lbSrc:find("game:BindToClose") ~= nil
					and lbSrc:find("SHUTDOWN_DRAIN_SECONDS") ~= nil)

			-- Wins accumulate; points are a personal best. Getting these the wrong way round would
			-- either wipe a total or freeze a high score.
			check("wins add up and points keep the larger value",
				lbSrc:find("%(current or 0%) %+ amount") ~= nil
					and lbSrc:find("current >= value") ~= nil)
			check("concurrent writes use UpdateAsync, not read-then-write",
				lbSrc:find("UpdateAsync") ~= nil and lbSrc:find("SetAsync") == nil)

			-- Bot ids are negative. One reaching a board would sit there namelessly forever.
			check("a bot can never reach a leaderboard",
				lbSrc:find("if userId <= 0 then") ~= nil)

			-- A board read is a DataStore call with a request budget attached.
			check("board reads are cached and rate limited",
				lbSrc:find("REQUEST_COOLDOWN_SECONDS") ~= nil
					and lbSrc:find("CACHE_SECONDS") ~= nil)
			-- Finding your own place must never mean reading the whole board: count only the entries
			-- above you, cap the scan, and check the request budget before each further page.
			check("your own rank is found without reading the whole board",
				lbSrc:find("function LeaderboardService%.rankOf") ~= nil
					and lbSrc:find("value %+ 1") ~= nil
					and lbSrc:find("RANK_SCAN_PAGES") ~= nil
					and lbSrc:find("GetRequestBudgetForRequestType") ~= nil)
			check("a rating is stored as the latest value, never as a best or a sum",
				lbSrc:find("function LeaderboardService%.setRating") ~= nil
					and lbSrc:find("return latest") ~= nil)

			-- The wiring lives in the bootstrap so matches never depend on persistence existing.
			check("matches do not know that leaderboards exist",
				bootSrc:find("MatchService%.onWin = function") ~= nil
					and bootSrc:find("LeaderboardService%.addWin") ~= nil)
			check("solo scores reach the solo board",
				bootSrc:find("RunServer%.onRunEnded") ~= nil
					and bootSrc:find("LeaderboardService%.submitScore") ~= nil)
			check("only solo runs reach the solo board",
				bootSrc:find("summary%.matchId == nil") ~= nil)
			check("a win lands on the board for the mode it was won in",
				bootSrc:find("Leaderboards%.boardForMatchMode%(mode%)") ~= nil)

			--[[
				AGAINST AN IN-MEMORY ORDERED STORE (2026-09-11: "make sure leaderboards will work once we
				connect"). This place is unlinked, so no real DataStore is reachable from here. Instead the
				service's own source, and StoreAccess's, are loaded as a live server would load them --
				PlaceId set, not Studio -- against a fake DataStoreService that behaves the way Roblox's
				ordered stores are documented to: UpdateAsync transforms where nil leaves the key alone,
				integer values only, names up to 50 characters, descending sorted pages of at most a
				hundred with a minimum value, and pages you advance.
			]]
			local fakeData: { [string]: { [string]: number } } = {}
			local writes = 0
			local function orderedStore(name: string)
				local data = fakeData[name] or {}
				fakeData[name] = data
				local store = {}
				function store.UpdateAsync(_, key: string, transform: (number?) -> number?)
					local nextValue = transform(data[key])
					if nextValue ~= nil then
						assert(nextValue == math.floor(nextValue), "an ordered store only takes integers")
						data[key] = nextValue
						writes += 1
					end
					return nextValue
				end
				function store.GetAsync(_, key: string)
					return data[key]
				end
				function store.GetSortedAsync(_, ascending: boolean, pageSize: number, minValue: number?, maxValue: number?)
					assert(pageSize >= 1 and pageSize <= 100, "Roblox pages hold one to a hundred entries")
					local sorted = {}
					for key, value in data do
						if (minValue == nil or value >= minValue) and (maxValue == nil or value <= maxValue) then
							table.insert(sorted, { key = key, value = value })
						end
					end
					table.sort(sorted, function(a, b)
						if a.value ~= b.value then
							return if ascending then a.value < b.value else a.value > b.value
						end
						return a.key < b.key
					end)
					local pages = { page = 1, IsFinished = #sorted <= pageSize }
					function pages.GetCurrentPage(self)
						local out = {}
						for index = (self.page - 1) * pageSize + 1, math.min(#sorted, self.page * pageSize) do
							table.insert(out, sorted[index])
						end
						return out
					end
					function pages.AdvanceToNextPageAsync(self)
						self.page += 1
						self.IsFinished = self.page * pageSize >= #sorted
					end
					return pages
				end
				return store
			end
			local fakeServices = {
				DataStoreService = {
					GetOrderedDataStore = function(_, name: string)
						assert(#name <= 50, "store names are capped at 50 characters")
						return orderedStore(name)
					end,
					GetRequestBudgetForRequestType = function()
						return 100
					end,
				},
				Players = {
					GetNameFromUserIdAsync = function(_, userId: number)
						return "player" .. userId
					end,
				},
				UserService = {
					GetUserInfosByUserIdsAsync = function(_, ids: { number })
						local infos = {}
						for _, id in ids do
							table.insert(infos, { Id = id, Username = "player" .. id, DisplayName = "P" .. id })
						end
						return infos
					end,
				},
				RunService = { IsStudio = function()
					return false
				end },
			}
			local fakeGame = setmetatable({ PlaceId = 1 }, {
				__index = function(_, key)
					if key == "GetService" then
						return function(_, name: string)
							return fakeServices[name] or game:GetService(name)
						end
					end
					return nil
				end,
			})
			local specEnv = getfenv(1)
			local liveModules: { [string]: any } = {}
			local function loadLive(name: string)
				local module = serverRoot:FindFirstChild(name) :: ModuleScript
				local fn = assert(loadstring(module.Source, "=" .. name))
				local fakeScript = { Parent = { WaitForChild = function(_, child: string)
					return { liveModule = child }
				end } }
				setfenv(fn, setmetatable({
					game = fakeGame,
					script = fakeScript,
					require = function(target: any)
						if typeof(target) == "table" and target.liveModule then
							return liveModules[target.liveModule]
						end
						return specEnv.require(target)
					end,
				}, { __index = specEnv }))
				liveModules[name] = fn()
				return liveModules[name]
			end
			loadLive("StoreAccess")
			local Live = loadLive("LeaderboardService")
			local SOLO, DUO = Leaderboards.BOARD.SOLO, Leaderboards.BOARD.DUO
			local ALL, DAY = Leaderboards.PERIOD.ALL_TIME, Leaderboards.PERIOD.DAILY
			local function stored(board: string, period: string, userId: number): number?
				local data = fakeData[Leaderboards.keyFor(board, period, os.time())]
				return if data then data[tostring(userId)] else nil
			end

			Live.submitScore(101, 50)
			Live.submitScore(101, 30)
			Live.submitScore(101, 80)
			check("a live solo best lands on every period's board and is never lowered",
				stored(SOLO, ALL, 101) == 80 and stored(SOLO, DAY, 101) == 80)
			check("a score that is not a new best costs no write",
				writes == 6, string.format("%d writes for three runs, one of them lower", writes))
			Live.addWin(202, DUO)
			Live.addWin(202, DUO)
			Live.addWin(-1000001, DUO)
			check("live wins add up, and a bot's never lands",
				stored(DUO, ALL, 202) == 2 and stored(DUO, ALL, -1000001) == nil)
			Live.setRating(303, 140)
			Live.setRating(303, 120)
			check("a live rating keeps the latest value, even when it fell",
				stored(Leaderboards.BOARD.RANKED, ALL, 303) == 120)
			for index = 1, 150 do
				Live.submitScore(1000 + index, index * 10)
			end
			local top = Live.top(SOLO, ALL)
			check("a live board reads back its top 25, highest first, with names",
				top ~= nil and #top == 25 and top[1].userId == 1150 and top[1].value == 1500
					and top[1].name == "player1150" and top[25].value == 1260)
			local standing = Live.rankOf(SOLO, ALL, 1010)
			check("a player's own place is counted across pages, however far down",
				standing ~= nil and standing.rank == 141 and standing.value == 100 and not standing.capped,
				if standing then string.format("rank %s", tostring(standing.rank)) else "unreadable")
		end
	end

	-- ── 16. the splat, and bots that pass as players ─────────────────────────────────────────
	-- The credit-bought distraction and the decision to stop disclosing bots, tested together
	-- because they meet at one point: a splat bought against a bot must still do what was paid for.
	log("\n[16] splat and undisclosed bots")
	do
		check("Distraction.validate() passes", (Distraction.validate()) == true)
		check("a splat lasts three to five seconds, as asked",
			Distraction.DURATION_SECONDS >= 3 and Distraction.DURATION_SECONDS <= 5
				and Distraction.MIN_SECONDS == 3 and Distraction.MAX_SECONDS == 5,
			string.format("%d seconds", Distraction.DURATION_SECONDS))
		check("nobody can be held blind for most of a match",
			Distraction.IMMUNITY_SECONDS >= Distraction.MAX_SECONDS * 3,
			string.format("blind at most %d%% of the time",
				math.floor(100 * Distraction.MAX_SECONDS / Distraction.IMMUNITY_SECONDS)))

		-- ALL AGES. Roblox names "jump scares" and "shrieking or screaming" as Mild content, which
		-- closes a game to ages 5-8. The sound must stay the licensed comedic slide whistle.
		check("the splat sound is the licensed slide whistle, never a scream",
			Distraction.SOUND_ID == "rbxassetid://9119198140")
		check("the splat works without any uploaded art", Distraction.IMAGE_ID == "")

		-- A blinded bot is never sharper than a sighted one, in any band -- and genuinely worse.
		local neverSharper, actuallyWorse = true, true
		for _, skill in BotPolicy.SKILLS do
			local blind = BotPolicy.blinded(skill,
				Distraction.BOT_JITTER_MULTIPLIER, Distraction.BOT_WHIFF_PERCENT)
			if blind.jitterTicks < skill.jitterTicks or blind.whiffPercent < skill.whiffPercent then
				neverSharper = false
			end
			if not (blind.jitterTicks > skill.jitterTicks and blind.whiffPercent > skill.whiffPercent) then
				actuallyWorse = false
			end
		end
		check("blindness never makes a bot sharper", neverSharper)
		check("and it makes every skill band genuinely worse", actuallyWorse)

		-- Behaviour, not only numbers: one bot, one seed, one rope, sighted against blind.
		local function survive(skill, ticks: number)
			local run = RunSim.new(4242, nil, MatchTuning.SET_NONE)
			local rng = Rng.new(99)
			local plan = nil
			for _ = 1, ticks do
				if not run.alive then
					break
				end
				if BotPolicy.shouldReplan(run, plan) then
					plan = BotPolicy.plan(run, skill, rng)
				end
				run:step(BotPolicy.isDown(plan, run.tick + 1))
			end
			return run
		end
		local best = BotPolicy.SKILLS[#BotPolicy.SKILLS]
		local sighted = survive(best, 1200)
		local blinded = survive(BotPolicy.blinded(best,
			Distraction.BOT_JITTER_MULTIPLIER, Distraction.BOT_WHIFF_PERCENT), 1200)
		check("a splatted bot really does play worse",
			blinded.loops < sighted.loops,
			string.format("sighted %d clears, blind %d clears", sighted.loops, blinded.loops))

		-- Undisclosed means the names have to pass too.
		local shaped, spellsBot, distinct, count = true, false, {}, 0
		for serial = 1, 500 do
			local name = BotPolicy.nameFor(Rng.new(serial * 104729 + 17))
			local underscores = select(2, name:gsub("_", ""))
			if #name < 3 or #name > 20 or not name:match("^[%w_]+$") or underscores > 1
				or name:sub(1, 1) == "_" or name:sub(-1) == "_" then
				shaped = false
			end
			if name:lower():find("bot", 1, true) then
				spellsBot = true
			end
			if not distinct[name] then
				distinct[name] = true
				count += 1
			end
		end
		check("bot names are shaped like Roblox usernames", shaped)
		check("no bot name spells out 'bot'", not spellsBot)
		check("bot names vary", count >= 300, string.format("%d distinct names in 500", count))

		local serverRoot = game:GetService("ServerScriptService"):FindFirstChild("Server")
		local clientRoot = game:GetService("StarterPlayer").StarterPlayerScripts:FindFirstChild("Client")
		local service = serverRoot and serverRoot:FindFirstChild("DistractionService")
		local runner = serverRoot and serverRoot:FindFirstChild("BotRunner")
		local matches = serverRoot and serverRoot:FindFirstChild("MatchService")
		local splat = clientRoot and clientRoot:FindFirstChild("DistractionClient")
		check("the splat's server and client halves are synced", service ~= nil and splat ~= nil)
		if service and service:IsA("ModuleScript") and splat and splat:IsA("ModuleScript")
			and runner and runner:IsA("ModuleScript") and matches and matches:IsA("ModuleScript") then
			local svc, cli, bots, mat = service.Source, splat.Source, runner.Source, matches.Source

			-- Nothing sold may edit anyone's simulation.
			check("a splat never touches the victim's simulation or input",
				cli:find("RunSim") == nil and cli:find(":step%(") == nil
					and cli:find("InputController") == nil and svc:find("RunSim") == nil)
			-- A splat on a live server is always paid: server-owned group preflight, one charge, then
			-- apply. If nobody from the original matchup remains eligible after the yield, it refunds.
			local buyAt = svc:find("local function buy%(")
			local buyEnd = buyAt and svc:find("\nend\n\nfunction DistractionService.start", buyAt, true)
			local buyBody = if buyAt and buyEnd then svc:sub(buyAt, buyEnd) else ""
			local targetAt = buyAt and svc:find("local originalTargets, reason, retryIn = eligibleOpponents%(player%)", buyAt)
			local preflightAt = targetAt and svc:find("#originalTargets == 0", targetAt, true)
			local chargeAt = preflightAt and svc:find("DistractionService.spendTickets, player", preflightAt, true)
			local applyAt = chargeAt and svc:find("pcall%(DistractionService%.apply", chargeAt)
			local refundAt = applyAt and svc:find("refundFailedSplat%(player", applyAt)
			check("a group splat is charged once before it lands and refunds when nobody can be hit",
				targetAt ~= nil and preflightAt ~= nil and chargeAt ~= nil and applyAt ~= nil and refundAt ~= nil
					and chargeAt < applyAt and svc:find("MonetizationConfig%.SPLAT_TICKET_COST") ~= nil
					and select(2, buyBody:gsub("DistractionService%.spendTickets", "")) == 1)
			check("paid splat requests are throttled per buyer",
				svc:find("lastBuyAt%[player%]") ~= nil
					and svc:find("Distraction%.BUY_COOLDOWN_SECONDS") ~= nil)
			check("the free test splats still exist only in Studio",
				svc:find("if not RunService:IsStudio%(%) then") ~= nil
					and select(2, svc:gsub("OnServerEvent", "")) == 1)
			check("the server, not the buyer, supplies every opponent in the active match",
				svc:find("MatchService%.opponents%(player%)") ~= nil
					and mat:find("function MatchService%.opponents") ~= nil
					and svc:find("originalMatchByUserId") ~= nil)
			local buyer = clientRoot and clientRoot:FindFirstChild("SplatClient")
			local buyerSrc = if buyer and buyer:IsA("ModuleScript") then buyer.Source else ""
			check("the SPLAT button sends no target, shows its price, and decides nothing",
				buyerSrc:find("Distraction%.CLIENT%.BUY") ~= nil
					and buyerSrc:find("UserId") == nil
					and buyerSrc:find("SPLAT WHO", 1, true) == nil
					and buyerSrc:find("SPLAT ALL", 1, true) ~= nil
					and buyerSrc:find("FireServer%(Distraction%.CLIENT%.BUY%)") ~= nil
					and buyerSrc:find("SPLAT_TICKET_COST") ~= nil)
			local inputModule = clientRoot and clientRoot:FindFirstChild("InputController")
			local inputSrc = if inputModule and inputModule:IsA("ModuleScript") then inputModule.Source else ""
			check("tapping SPLAT is never also a jump",
				buyerSrc:find("InputController%.exemptGui%(button%)") ~= nil
					and inputSrc:find("GetGuiObjectsAtPosition") ~= nil
					and inputSrc:find("if onExemptGui%(input%) then") ~= nil)
			check("no button, text box or open panel press is ever also a jump",
				inputSrc:find('hit:IsA%("GuiButton"%)') ~= nil and inputSrc:find('hit:IsA%("TextBox"%)') ~= nil
					and inputSrc:find("hit%.Active") ~= nil)
			check("immunity, liveness and the card choice are all checked on the server",
				svc:find("Distraction%.IMMUNITY_SECONDS") ~= nil
					and svc:find("target%.busy") ~= nil
					and svc:find("not target%.alive") ~= nil)
			check("a paid splat on a bot still blinds the bot",
				svc:find("BotRunner%.blind%(") ~= nil and bots:find("BotPolicy%.blinded%(") ~= nil)
			-- Shown once, hidden when it ends: it moves, it never flashes. The per-frame animation is
			-- the only code that runs many times a second, so it is the only place a strobe could come
			-- from -- and it must not touch visibility at all.
			local NL = string.char(10)
			local frameStart = cli:find("local function frame%(%)")
			local frameEnd = frameStart and cli:find(NL .. "end" .. NL, frameStart, true)
			local frameBody = if frameStart and frameEnd then cli:sub(frameStart, frameEnd) else ""
			check("the splat shakes but never flashes",
				select(2, cli:gsub("canvas%.Visible = true", "")) == 1
					and cli:find("Visible = not") == nil
					and frameBody ~= "" and frameBody:find("Visible") == nil)
			check("the splat covers every other screen, card offers included",
				cli:find("gui%.DisplayOrder = 100") ~= nil)

			-- Undisclosed: nothing that marks a bot ever reaches a client.
			check("bot status never leaves the server",
				mat:find("isBot = p%.isBot }") == nil
					and mat:find("forClient%(MatchRules%.liveTable") ~= nil
					and mat:find("placings = forClient%(placings%)") ~= nil
					and mat:find("awardsWin = match%.awardsWin") == nil)
			check("bots take time over their cards the way people do",
				bots:find("THINK_MIN_SECONDS") ~= nil
					and bots:find("function BotRunner%.isThinking") ~= nil
					and bots:find("if bot%.thinking > 0 then") ~= nil)

			-- Dressed from Roblox's own free catalog (the user, 2026-09-11: "need some more creative
			-- outfits"). The module is data plus one pure-ish builder, so it is loaded and exercised
			-- directly; the HumanoidDescriptions it makes are never parented to anything.
			local outfits = serverRoot and serverRoot:FindFirstChild("BotOutfits")
			local outfitsFn = if outfits and outfits:IsA("ModuleScript") then loadstring(outfits.Source) else nil
			local BotOutfits = if outfitsFn then outfitsFn() else nil
			local looks, distinct = {}, 0
			if BotOutfits then
				for seed = 1, 40 do
					local d = BotOutfits.describe(Random.new(seed))
					local look = table.concat({ d.HairAccessory, d.HatAccessory, tostring(d.Shirt), tostring(d.Pants),
						tostring(d.TorsoColor) }, "|")
					d:Destroy()
					if not looks[look] then
						looks[look] = true
						distinct += 1
					end
				end
			end
			check("bots dress from Roblox's own free catalog, and no two look alike",
				BotOutfits ~= nil and BotOutfits.validate() == true and #BotOutfits.HAIR >= 40
					and #BotOutfits.SHIRTS >= 10 and #BotOutfits.PANTS >= 8 and distinct >= 38
					and mat:find("BotOutfits%.describe%(") ~= nil,
				string.format("%d different looks in 40 bots", distinct))
		end
	end

	-- ── 17. ranked ───────────────────────────────────────────────────────────────────────────
	-- Chess Elo from the user's starting number, humans only, paired by rating. The maths is pure
	-- and tested directly; the seams -- no bots, captured ratings, deltas not overwrites, one
	-- failed call never switching persistence off -- are pinned at the source, because the failures
	-- they prevent are silent.
	log("\n[17] ranked")
	do
		check("Elo.validate() passes", (Elo.validate()) == true)
		check("everyone starts at 100, the user's number", Elo.START == 100)
		check("two equal ratings are a coin flip", math.abs(Elo.expected(100, 100) - 0.5) < 1e-9)
		check("the two sides' expectations add up to one",
			math.abs(Elo.expected(180, 95) + Elo.expected(95, 180) - 1) < 1e-9)

		local function duel(ratingA: number, ratingB: number, gamesA: number, gamesB: number,
			scoreA: number, scoreB: number)
			return Elo.rate({
				{ userId = 1, rating = ratingA, games = gamesA, score = scoreA, tick = 900 },
				{ userId = 2, rating = ratingB, games = gamesB, score = scoreB, tick = 900 },
			})
		end

		local even = duel(100, 100, 0, 0, 40, 10)
		check("between equals, the winner gains exactly what the loser drops",
			even[1].delta > 0 and even[1].delta == -even[2].delta,
			string.format("%+d / %+d", even[1].delta, even[2].delta))

		local upset = duel(100, 300, 25, 25, 40, 10)
		local expectedWin = duel(300, 100, 25, 25, 40, 10)
		check("an upset is worth far more than beating someone below you",
			upset[1].delta > expectedWin[1].delta * 2,
			string.format("upset %+d, expected win %+d", upset[1].delta, expectedWin[1].delta))

		local fresh = duel(100, 100, 0, 0, 40, 10)
		local settled = duel(100, 100, 30, 30, 40, 10)
		check("a new player's rating moves twice as fast for their first 20 rated matches",
			fresh[1].delta == settled[1].delta * 2 and Elo.kFactor(19) == 40 and Elo.kFactor(20) == 20,
			string.format("provisional %+d, established %+d", fresh[1].delta, settled[1].delta))

		local floored = duel(5, 5, 30, 30, 1, 99)
		check("a rating never goes below zero", floored[1].after == 0,
			string.format("5 fell to %d", floored[1].after))

		-- A draw only when two runs are identical in score AND time. MatchRules breaks that final tie
		-- by userId purely so placings display in order; an account number must never move a rating.
		local tied = Elo.rate({
			{ userId = 1, rating = 100, games = 0, score = 20, tick = 700 },
			{ userId = 2, rating = 100, games = 0, score = 20, tick = 700 },
		})
		local swapped = Elo.rate({
			{ userId = 2, rating = 100, games = 0, score = 20, tick = 700 },
			{ userId = 1, rating = 100, games = 0, score = 20, tick = 700 },
		})
		check("identical runs are a draw, whatever their account numbers",
			tied[1].delta == 0 and tied[2].delta == 0 and swapped[1].delta == 0 and swapped[2].delta == 0)
		local faster = Elo.rate({
			{ userId = 1, rating = 100, games = 0, score = 20, tick = 600 },
			{ userId = 2, rating = 100, games = 0, score = 20, tick = 700 },
		})
		check("the same score reached faster wins, exactly as it does on the placings",
			faster[1].delta > 0 and faster[2].delta < 0)

		-- Lobbies: every pair is one game and K is shared across the field, so eight players move a
		-- rating about as much as one duel does rather than seven times as much.
		local field = {}
		for i = 1, 8 do
			table.insert(field, { userId = i, rating = 100, games = 30, score = 100 - i, tick = 900 })
		end
		local lobby = Elo.rate(field)
		local oneDuel = duel(100, 100, 30, 30, 40, 10)
		local net = 0
		for _, change in lobby do
			net += change.delta
		end
		check("winning an eight-player lobby moves a rating one duel's worth",
			lobby[1].delta == oneDuel[1].delta and lobby[8].delta == -oneDuel[1].delta,
			string.format("lobby winner %+d, duel winner %+d", lobby[1].delta, oneDuel[1].delta))
		check("an evenly rated lobby creates and destroys no rating", net == 0,
			string.format("net %+d", net))

		local serverRoot = game:GetService("ServerScriptService"):FindFirstChild("Server")
		local matchModule = serverRoot and serverRoot:FindFirstChild("MatchService")
		local ratingModule = serverRoot and serverRoot:FindFirstChild("RatingService")
		local storeModule = serverRoot and serverRoot:FindFirstChild("StoreAccess")
		local bootModule = serverRoot and serverRoot:FindFirstChild("Main")
		check("the rating and store-access services are synced", ratingModule ~= nil and storeModule ~= nil)
		if matchModule and matchModule:IsA("ModuleScript")
			and ratingModule and ratingModule:IsA("ModuleScript")
			and storeModule and storeModule:IsA("ModuleScript")
			and bootModule and bootModule:IsA("LuaSourceContainer") then
			local mat, rat, sa, boot = matchModule.Source, ratingModule.Source, storeModule.Source, bootModule.Source

			-- A bot in a rated match would put a number on the board no person earned against a person.
			check("a ranked match can never contain a bot",
				mat:find("assert%(not ranked or botCount == 0") ~= nil
					and mat:find("formMatch%(MatchProtocol%.MODE%.DUEL, { a, b }, 0, true%)") ~= nil
					and mat:find("formMatch%(MatchProtocol%.MODE%.LOBBY, group, 0, true%)") ~= nil)
			check("the rating window starts tight and widens the longer you wait",
				mat:find("local function ratingWindow") ~= nil
					and mat:find("RANKED_WINDOW_GROWTH_PER_SECOND") ~= nil
					and mat:find("RANKED_WINDOW_OPEN_SECONDS") ~= nil)
			check("a result is rated from the numbers captured when the match formed",
				mat:find("match%.ratingsBefore%[player%.UserId%]") ~= nil
					and mat:find("Elo%.rate%(rated%)") ~= nil)
			check("matches do not know where ratings are kept",
				mat:find('WaitForChild%("RatingService"%)') == nil
					and boot:find("MatchService%.onRated = function") ~= nil
					and boot:find("MatchService%.ratingOf = function") ~= nil)
			check("a rating change is saved as a delta, not an overwrite",
				rat:find("record%.rating %+ delta") ~= nil and rat:find("UpdateAsync") ~= nil)
			check("a retried rating save can never count one match twice",
				rat:find("stored%.last == matchKey") ~= nil and rat:find("last = matchKey") ~= nil)
			check("every saved rating is mirrored to the ranked board",
				rat:find("LeaderboardService%.setRating%(") ~= nil)
			-- Found while auditing the hookups: a player whose match could not form was removed from
			-- the queue and never put back, while their screen still said SEARCHING. Queue servicing
			-- now never removes anyone itself; `formMatch` removes exactly the players it places.
			local servicingStart = mat:find("local function readyIn", 1, true)
			local servicingEnd = mat:find("local function serviceQueues(", 1, true)
			check("a queued player whose match could not form keeps their place",
				servicingStart ~= nil and servicingEnd ~= nil and servicingEnd > servicingStart
					and mat:sub(servicingStart, servicingEnd):find("table.remove", 1, true) == nil)

			--[[
				ONE BAD MOMENT MUST NOT SWITCH PERSISTENCE OFF.

				Before StoreAccess, the first failed DataStore call marked leaderboards unavailable for
				the rest of the server's life -- on a live server, one throttled request would have
				silently thrown away every win after it, for hours. Only an unlinked or API-less Studio
				session may now switch a feature off; on a live server a failure is that call's alone.
			]]
			check("only a Studio or unlinked session can switch persistence off",
				sa:find("if sessionOnly%(%) then%s+offline = true") ~= nil
					and select(2, sa:gsub("offline = true", "")) == 1
					and sa:find("RunService:IsStudio%(%)") ~= nil)
			check("ratings go through the same guarded store access as leaderboards",
				rat:find("StoreAccess%.try") ~= nil and rat:find("StoreAccess%.write") ~= nil
					and rat:find("pcall") == nil)
		end
	end

	-- ── 18. netcode and the solo flow ────────────────────────────────────────────────────────
	-- Pinned at the source, because every failure here is a player's press that silently did
	-- nothing: a late input dropped, a card resume that shrank the latency gap by a round trip, a
	-- client waiting forever for an offer authority never made -- "stuck in the floor".
	log("\n[18] netcode and the solo flow")
	do
		check("RunProtocol.validate() passes", (RunProtocol.validate()) == true)
		check("the authority delay can stretch to cover a slow connection",
			RunProtocol.MAX_AUTHORITY_DELAY_TICKS > RunProtocol.AUTHORITY_DELAY_TICKS
				and RunProtocol.MAX_FUTURE_TICKS > RunProtocol.MAX_AUTHORITY_DELAY_TICKS)
		local serverRoot = game:GetService("ServerScriptService"):FindFirstChild("Server")
		local clientRoot = game:GetService("StarterPlayer").StarterPlayerScripts:FindFirstChild("Client")
		local server = serverRoot and serverRoot:FindFirstChild("RunServer")
		local client = clientRoot and clientRoot:FindFirstChild("Main")
		local presenter = clientRoot and clientRoot:FindFirstChild("RunPresenter")
		check("the run modules are synced", server ~= nil and client ~= nil and presenter ~= nil)
		if server and server:IsA("ModuleScript") and client and client:IsA("LuaSourceContainer")
			and presenter and presenter:IsA("ModuleScript") then
			local srv, cli, pre = server.Source, client.Source, presenter.Source
			check("each run's authority delay comes from the player's measured ping",
				srv:find("GetNetworkPing") ~= nil
					and srv:find("session%.delayTicks / SimTuning%.TICK_RATE") ~= nil)
			check("a late input is applied at the next tick, never dropped",
				srv:find("math%.max%(inputTick, session%.run%.tick %+ 1, session%.lastInputTick %+ 1%)") ~= nil
					and srv:find("input arrived after its authoritative tick") == nil)
			local appliedAt = srv:find("RunProtocol.SERVER.CARD_APPLIED", 1, true)
			check("a card resume hands both peers one shared moment",
				appliedAt ~= nil and srv:find("startAt = resumeAt,", appliedAt, true) ~= nil)
			local clientApplied = cli:find("elseif op == RunProtocol.SERVER.CARD_APPLIED then", 1, true)
			local clientRejected = cli:find("elseif op == RunProtocol.SERVER.CARD_REJECTED then", 1, true)
			check("the client resumes on that moment rather than on arrival",
				clientApplied ~= nil and clientRejected ~= nil
					and cli:sub(clientApplied, clientRejected):find("active.startAt = data.startAt", 1, true) ~= nil)
			check("a client paused for an upgrade authority never saw lets go",
				cli:find("local function releaseStaleUpgradePause") ~= nil
					and cli:find("active%.awaitingRound = event%.upgradeRound") ~= nil)
			check("a lost solo run waits for the player instead of restarting",
				srv:find("autoRestart = if opts%.autoRestart == nil then false") ~= nil
					and srv:find("RunProtocol%.SERVER%.RUN_OVER") ~= nil
					and srv:find("local function playAgain") ~= nil
					and cli:find("RunProtocol%.CLIENT%.PLAY_AGAIN") ~= nil)
			check("pausing is solo only and stops on the tick the player paused at",
				srv:find("local function requestPause") ~= nil
					and srv:find("if session%.matchId ~= nil") ~= nil
					and srv:find("if pauseAt and session%.run%.tick >= pauseAt then") ~= nil)
			check("pausing mid-hold ends the hold on both peers",
				cli:find("if active%.lastSentDown then") ~= nil)
			check("the camera keeps a high jump in frame",
				pre:find("CAMERA_FULL_FOLLOW_ABOVE") ~= nil)
			check("multiplayer keeps the local runner centered until spectating",
				pre:find("centreLane = framing%.focusLane or 0") ~= nil
					and pre:find("%(framing%.minLane %+ framing%.maxLane%) %* 0%.5") == nil)
		end
	end

	-- ── 19. tickets, first-time help, match analytics ──────────────────────────────────────────
	-- Tickets are money, so the checks here are about the two ways money goes wrong: a ticket
	-- granted or charged twice, and a revive handed out before its ticket was taken.
	log("\n[19] tickets, first-time help, match analytics")
	do
		check("PlayerProtocol.validate() passes", (PlayerProtocol.validate()) == true)
		check("the first-time hint lasts the user's ten seconds of jumping",
			PlayerProtocol.TUTORIAL_TICKS == 10 * SimTuning.TICK_RATE)
		check("a pack with product id 0 is never offered", (function()
			for _, pack in MonetizationConfig.offeredPacks() do
				if pack.productId <= 0 then
					return false
				end
			end
			return true
		end)())
		local expectedPacks = {
			{ productId = 3712026681, iconAssetId = 119231224894642, tickets = 1, priceRobux = 5 },
			{ productId = 3712424111, iconAssetId = 128979012571609, tickets = 2, priceRobux = 10 },
			{ productId = 3712424157, iconAssetId = 91991179212933, tickets = 3, priceRobux = 15 },
			{ productId = 3712424214, iconAssetId = 80844318121505, tickets = 5, priceRobux = 20 },
		}
		local offered = MonetizationConfig.offeredPacks()
		local exactLadder = #offered == #expectedPacks
		local everyReceiptResolves = true
		for index, expected in expectedPacks do
			local pack = offered[index]
			exactLadder = exactLadder and pack ~= nil
				and pack.productId == expected.productId
				and pack.iconAssetId == expected.iconAssetId
				and pack.tickets == expected.tickets
				and pack.priceRobux == expected.priceRobux
			everyReceiptResolves = everyReceiptResolves
				and MonetizationConfig.packForProduct(expected.productId) == pack
		end
		check("the shop exposes exactly the approved 1/2/3/5 ticket price ladder", exactLadder)
		check("every approved Developer Product resolves to its server receipt grant", everyReceiptResolves)

		local serverRoot = game:GetService("ServerScriptService"):FindFirstChild("Server")
		local clientRoot = game:GetService("StarterPlayer").StarterPlayerScripts:FindFirstChild("Client")
		local data = serverRoot and serverRoot:FindFirstChild("PlayerDataService")
		local purchase = serverRoot and serverRoot:FindFirstChild("PurchaseService")
		local analytics = serverRoot and serverRoot:FindFirstChild("MatchAnalytics")
		local boot = serverRoot and serverRoot:FindFirstChild("Main")
		local run = serverRoot and serverRoot:FindFirstChild("RunServer")
		local shop = clientRoot and clientRoot:FindFirstChild("TicketClient")
		local main = clientRoot and clientRoot:FindFirstChild("Main")
		check("the ticket, purchase and analytics modules are synced",
			data ~= nil and purchase ~= nil and analytics ~= nil and shop ~= nil)
		if data and data:IsA("ModuleScript") and purchase and purchase:IsA("ModuleScript")
			and analytics and analytics:IsA("ModuleScript") and boot and boot:IsA("LuaSourceContainer")
			and run and run:IsA("ModuleScript") and shop and shop:IsA("ModuleScript")
			and main and main:IsA("LuaSourceContainer") then
			local dataSrc, buySrc, logSrc = data.Source, purchase.Source, analytics.Source
			local bootSrc, runSrc, shopSrc, mainSrc = boot.Source, run.Source, shop.Source, main.Source

			check("a spend is decided by the stored balance, inside the write",
				dataSrc:find("if r%.tickets < amount then") ~= nil and dataSrc:find("UpdateAsync") ~= nil)
			check("every ticket change is keyed, so a retry can never grant or charge twice",
				dataSrc:find("if record%.ops%[key%] then") ~= nil
					and dataSrc:find('"spend:" %.%. HttpService:GenerateGUID') ~= nil)
			check("a purchase is keyed by its Roblox purchase id",
				buySrc:find('"purchase:" %.%. tostring%(receiptInfo%.PurchaseId%)') ~= nil)
			check("tickets are granted only by the receipt handler, never by a client",
				buySrc:find("MarketplaceService%.ProcessReceipt = function") ~= nil
					and shopSrc:find("ProcessReceipt") == nil
					and shopSrc:find("SetAttribute") == nil
					and mainSrc:find("PromptProductPurchaseFinished") == nil)
			check("a receipt is granted only once its tickets are saved",
				buySrc:find("if granted") ~= nil and buySrc:find("NotProcessedYet") ~= nil)
			check("the four-pack shop is a bouncy two-column grid with a visible value badge",
				shopSrc:find("local columns = math.min%(2") ~= nil
					and shopSrc:find("TweenService") ~= nil
					and shopSrc:find("BEST VALUE") ~= nil
					and shopSrc:find('rbxassetid://%%d') ~= nil
					and shopSrc:find("PromptProductPurchase") ~= nil)
			-- Charge first, then revive: never the other way round, and a run that vanished while the
			-- ticket was being taken gets it back.
			local spendAt = runSrc:find("RunServer.spendTickets, player", 1, true)
			local grantAt = spendAt and runSrc:find("grantRevive(player, session)", spendAt, true)
			check("a revive is granted only after its ticket has been taken",
				spendAt ~= nil and grantAt ~= nil and runSrc:find("RunServer%.refundTickets%(player") ~= nil)
			-- The user (2026-09-11): "when a player is in the shop during a revive, it pauses the revive
			-- counter". Closing the shop carries it on from the second it stopped on.
			check("the ticket shop pauses the revive countdown, and closing it carries on",
				runSrc:find("local function resumeAfterShopping") ~= nil
					and runSrc:find("remaining = session%.shoppingRemaining") ~= nil
					and mainSrc:find("RunProtocol%.CLIENT%.REVIVE_SHOP_CLOSED") ~= nil
					and mainSrc:find("revivePausedRemaining") ~= nil)
			check("a refused purchase unfreezes the displayed revive counter",
				mainSrc:find("active%.purchasePending = false%s+active%.revivePausedRemaining = nil") ~= nil)
			check("an expired revive cannot leave its ticket shop covering the run-over screen",
				mainSrc:find("if TicketClient%.isOpen%(%) then%s+TicketClient%.closeShop%(%)") ~= nil)
			check("the bootstrap wires tickets into revives and matches into analytics",
				bootSrc:find("RunServer%.spendTickets = PlayerDataService%.spendTickets") ~= nil
					and bootSrc:find("MatchService%.onResolved = function") ~= nil)
			check("the bootstrap wires tickets into the splat the same way",
				bootSrc:find("DistractionService%.spendTickets = PlayerDataService%.spendTickets") ~= nil
					and bootSrc:find("DistractionService%.refundTickets = PlayerDataService%.refundTickets") ~= nil)
			check("a failed live player-data load never opens a blank spendable record",
				dataSrc:find("local loadedSafely = StoreAccess%.offline%(%)") ~= nil
					and dataSrc:find("if not loadedSafely and not StoreAccess%.offline%(%) then") ~= nil
					and dataSrc:find("player:Kick") ~= nil)
			-- Tickets buy exactly two things (the user, 2026-09-11): a revive and a splat. A third use
			-- would be a third server file spending tickets, and needs the user's say-so first.
			local chargers = {}
			for _, module in serverRoot:GetDescendants() do
				if module:IsA("LuaSourceContainer") and module.Name ~= "PlayerDataService" and module.Name ~= "Main"
					and (module :: any).Source:find("spendTickets", 1, true) then
					table.insert(chargers, module.Name)
				end
			end
			table.sort(chargers)
			check("tickets buy exactly two things: a revive and a splat",
				table.concat(chargers, ",") == "DistractionService,RunServer", table.concat(chargers, ", "))
			check("the first-time hint is remembered on the account, not just the session",
				dataSrc:find("tutorialDone") ~= nil
					and mainSrc:find("PlayerProtocol%.CLIENT%.TUTORIAL_DONE") ~= nil
					and mainSrc:find("PlayerProtocol%.TUTORIAL_TICKS") ~= nil)
			-- The user asked to see WHEN and HOW matchmaking runs end; nobody asked to know WHO.
			check("the match log records when and why, and identifies no one",
				logSrc:find("LogCustomEvent") ~= nil
					and logSrc:find("reason = run%.reason") ~= nil
					and logSrc:find("userId =") == nil and logSrc:find("%.UserId") == nil
					and logSrc:find("DisplayName") == nil)
			-- Codes are tickets given away, so the list must never reach a client and each account
			-- must only ever cash a code once. Launch: only FRIEND (20 tickets).
			local codes = serverRoot:FindFirstChild("CodeConfig")
			local codeSrc = if codes and codes:IsA("ModuleScript") then codes.Source else ""
			check("codes live only on the server and pay each account once",
				codes ~= nil
					and game:GetService("ReplicatedStorage").Shared:FindFirstChild("CodeConfig") == nil
					and dataSrc:find("if r%.redeemed%[code%] then") ~= nil
					and dataSrc:find("CODE_ATTEMPTS_PER_MINUTE") ~= nil)
			check("FRIEND is the only redeemable code and grants twenty tickets",
				codeSrc:find("FRIEND = { tickets = 20 }", 1, true) ~= nil
					and codeSrc:find("STUDIOTEST", 1, true) == nil
					and select(2, codeSrc:gsub("\n\t[%u%d]+ = %{ tickets", "")) == 1)
			-- Community reward: Like is asked in UI; Join is server-verified once and forever.
			local SocialConfig = require(Shared:WaitForChild("SocialConfig"))
			local community = clientRoot and clientRoot:FindFirstChild("CommunityClient")
			local communitySrc = if community and community:IsA("ModuleScript") then community.Source else ""
			check("SocialConfig.validate() passes with the live community id",
				(SocialConfig.validate()) == true and SocialConfig.GROUP_ID == 213823349
					and SocialConfig.GROUP_REWARD_TICKETS == 2)
			check("the community reward is server-verified, atomic and permanent",
				dataSrc:find("socialRewards") ~= nil
					and dataSrc:find("IsInGroupAsync") ~= nil
					and dataSrc:find("GROUP_CLAIM_OP") ~= nil
					and dataSrc:find("r%.socialRewards%.groupJoin = true") ~= nil
					and dataSrc:find("r%.tickets %+%= reward") ~= nil
					and dataSrc:find("CLAIM_GROUP") ~= nil)
			check("the COMMUNITY panel has no raw Discord link and cannot become jump input",
				communitySrc ~= ""
					and mainSrc:find("CommunityClient") ~= nil
					and communitySrc:find("discord%.gg") == nil
					and communitySrc:find("http") == nil
					and communitySrc:find("PromptJoinAsync") ~= nil
					and communitySrc:find("panel%.Active = true") ~= nil
					and communitySrc:find("Community links are on the Roblox game page") ~= nil)
			local simModule = game:GetService("ReplicatedStorage").Shared:FindFirstChild("RunSim")
			local simSrc = if simModule and simModule:IsA("ModuleScript") then simModule.Source else ""
			local settingsModule = clientRoot and clientRoot:FindFirstChild("SettingsClient")
			local settingsSrc = if settingsModule and settingsModule:IsA("ModuleScript")
				then settingsModule.Source else ""
			check("sound is a draggable percentage bar, not four preset buttons",
				settingsSrc:find('soundTrack.Name = "SoundSlider"', 1, true) ~= nil
					and settingsSrc:find("previewSoundAt", 1, true) ~= nil
					and settingsSrc:find("SOUND_LABELS", 1, true) == nil)
			check("old four-step sound saves migrate before one means full volume",
				dataSrc:find("v = 2", 1, true) ~= nil
					and dataSrc:find("LEGACY_SOUND_LEVELS", 1, true) ~= nil
					and dataSrc:find("value.v == nil or value.v == 1", 1, true) ~= nil)
			check("settings are presentation only: no run code reads one",
				mainSrc:find("SettingsClient%.onChanged") ~= nil
					and simSrc:find("SkipsSound") == nil and simSrc:find("lowGraphics") == nil
					and runSrc:find("SkipsSound") == nil and runSrc:find("LowGraphics") == nil)
			check("hiding other players only changes what is drawn",
				mainSrc:find("stage:setHideOthers%(hideOthers%)") ~= nil
					and simSrc:find("hideOthers") == nil and simSrc:find("HideOthers") == nil
					and runSrc:find("hideOthers") == nil and runSrc:find("HideOthers") == nil)
		end
	end

	-- ── 20. the lane view, spectating, rope looks ────────────────────────────────────────────
	-- Other runs are drawn beside yours as ghosts from views the server reads off their runs. The
	-- claims worth pinning: a view is read-only, bots cannot be told apart in it, the rope has the
	-- four looks the user named, and the server stopped paying for character replication nobody sees.
	log("\n[20] the lane view, spectating, rope looks")
	do
		local ViewProtocol = require(Shared:WaitForChild("ViewProtocol"))
		local RunView = require(Shared:WaitForChild("RunView"))
		local RopeStyles = require(Shared:WaitForChild("RopeStyles"))
		check("ViewProtocol.validate() passes", (ViewProtocol.validate()) == true)
		check("RopeStyles.validate() passes", (RopeStyles.validate()) == true)

		local plain = RopeStyles.look(nil, false, false)
		local fire = RopeStyles.look(nil, true, false)
		local guard = RopeStyles.look(nil, false, true)
		local both = RopeStyles.look(nil, true, true)
		check("a rope has four looks: normal, on fire, guarded, and on fire and guarded",
			plain ~= fire and plain ~= guard and fire ~= both and guard ~= both
				and plain.guard == nil and fire.guard == nil and guard.guard ~= nil and both.guard ~= nil
				and fire.sparks and both.sparks and not plain.sparks and not guard.sparks)
		check("an unknown cosmetic set falls back to the classic rope",
			RopeStyles.look("NOT_A_SET", false, false) == plain)

		-- A view is read from a real run and carries exactly what a ghost needs.
		local viewed = RunSim.new(777)
		RunSim.applyStatEffects(viewed, (CardCatalog.get("ADD_JUMPROPE") :: CardCatalog.Card).effects)
		RunSim.applyStatEffects(viewed, (CardCatalog.get("IGNITE_JUMPROPE") :: CardCatalog.Card).effects)
		RunSim.applyStatEffects(viewed, (CardCatalog.get("REINFORCE_JUMP_ROPE") :: CardCatalog.Card).effects)
		for _ = 1, 30 do
			viewed:step(false)
		end
		local digestBefore = viewed.digest
		local view = RunView.of(viewed)
		check("a view carries the rope schedule, fire, guard and clock of the run it was read from",
			#view.ropes == #viewed.ropes and view.ropes[1] == viewed.ropes[1].nextSweepTick
				and view.burning == 1
				and view.guarded[1] == true and view.guarded[2] == false
				and view.tick == viewed.tick
				and view.period == viewed.stats.ropePeriodTicks)
		check("reading a view changes nothing about the run", viewed.digest == digestBefore)

		local serverRoot = game:GetService("ServerScriptService"):FindFirstChild("Server")
		local clientRoot = game:GetService("StarterPlayer").StarterPlayerScripts:FindFirstChild("Client")
		local viewModule = serverRoot and serverRoot:FindFirstChild("ViewService")
		local matchModule = serverRoot and serverRoot:FindFirstChild("MatchService")
		local runModule = serverRoot and serverRoot:FindFirstChild("RunServer")
		local stageModule = clientRoot and clientRoot:FindFirstChild("StageView")
		local presenterModule = clientRoot and clientRoot:FindFirstChild("RunPresenter")
		check("the lane view is synced", viewModule ~= nil and stageModule ~= nil)
		if viewModule and viewModule:IsA("ModuleScript") and matchModule and matchModule:IsA("ModuleScript")
			and runModule and runModule:IsA("ModuleScript") and stageModule and stageModule:IsA("ModuleScript")
			and presenterModule and presenterModule:IsA("ModuleScript") then
			local viewSrc, matSrc, runSrc = viewModule.Source, matchModule.Source, runModule.Source
			local stageSrc, preSrc = stageModule.Source, presenterModule.Source

			-- Bots are undisclosed (§7): the lane view must not become what gives them away.
			check("bots cannot be told apart in the lane view",
				viewSrc:find("isBot") == nil
					and matSrc:find('key = "s" %.%. slot') ~= nil
					and matSrc:find('rig = match%.id %.%. "_" %.%. slot') ~= nil)
			check("every match participant's look comes from one rig folder, humans and bots alike",
				matSrc:find("local function buildRigs") ~= nil
					and matSrc:find("CreateHumanoidModelFromDescription") ~= nil
					and matSrc:find("character:Clone%(%)") ~= nil
					and matSrc:find("clearRigs%(match%)") ~= nil)
			check("the server no longer moves every character sixty times a second",
				runSrc:find("CFrame%.new%(0, session%.run%.y, 0%)") == nil)
			check("ghosts are drawn from views only: the lane view never touches a run",
				stageSrc:find("RunSim") == nil and stageSrc:find(":step%(") == nil)
			check("your rope and every ghost's are drawn by the same code",
				preSrc:find("RopeView%.new") ~= nil and stageSrc:find("RopeView%.new") ~= nil)
			check("a guard sleeve is drawn only on the rope that carries it, yours and every ghost's",
				preSrc:find("rope%.guards > 0") ~= nil and stageSrc:find("sample%.guarded%[index%]") ~= nil)
			check("a burning rope is transmitted and drawn for local and ghost runs",
				viewSrc:find("entry%.burning") ~= nil
					and preSrc:find("index <= run%.stats%.scorePerLoop %- 1") ~= nil
					and stageSrc:find("index <= %(sample%.burning or 0%)") ~= nil)
			check("the run's bars fill as rounded pills, matching their outlines",
				preSrc:find("upgradeFillCorner%.CornerRadius = UDim%.new%(1, 0%)") ~= nil
					and preSrc:find("fuelFillCorner%.CornerRadius = UDim%.new%(1, 0%)") ~= nil)
			check("at most three other lanes on screen, and runners who go out are taken out",
				stageSrc:find("ViewProtocol%.MAX_SHOWN") ~= nil and stageSrc:find("ghost%.out") ~= nil
					and viewSrc:find("ViewProtocol%.MAX_GHOST_ROPES") ~= nil)
			check("spectating goes back and forth with arrows",
				stageSrc:find("prevButton") ~= nil and stageSrc:find("nextButton") ~= nil
					and stageSrc:find("local function cycle") ~= nil)
		end
	end

	log(string.format("\n=== %d passed, %d failed ===", passed, failed))
	return table.concat(lines, "\n")
end
