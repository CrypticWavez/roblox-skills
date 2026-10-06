--!strict
-- G2 Abilities: definition checks and the server cast pipeline with real Vitals, Cooldowns and
-- StatusEffects: cost, cooldown and charges on the server clock, global cooldown, blocking
-- statuses, targets and range, wind-ups, channels with exact ticks, interrupts and refunds,
-- and the abuse cases (spam while busy, cast-cancel to dodge cooldowns, casting while dead).
local Abilities = require("../packages/GameKit/Abilities")
local Cooldowns = require("../packages/GameKit/Cooldowns")
local FakeEnv = require("./fakes/FakeEnv")
local StatusEffects = require("../packages/GameKit/StatusEffects")
local Vitals = require("../packages/GameKit/Vitals")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function has(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

local function v(x: number, y: number, z: number)
	return { x = x, y = y, z = z }
end

local NAN = 0 / 0

-- Neutral test abilities (function names, no content).
local BOOK = {
	{ id = "instant_a", cooldown = 2, cost = { energy = 10 }, effects = { { kind = "damage", amount = 5 } } },
	{ id = "dash_a", cooldown = 3, charges = 2, gcd = false, effects = { { kind = "move" } } },
	{
		id = "windup_a",
		cooldown = 4,
		castTime = 0.5,
		cost = { energy = 20 },
		refundOnInterrupt = 0.5,
		target = "unit",
		range = 30,
		effects = { { kind = "damage", amount = 25 } },
	},
	{
		id = "channel_a",
		cooldown = 8,
		channel = 1,
		tickInterval = 0.25,
		target = "point",
		range = 40,
		blockedBy = { "silence" },
		effects = {
			{ kind = "zone", phase = "release" },
			{ kind = "damage", phase = "tick" },
			{ kind = "burst", phase = "end" },
		},
	},
	{ id = "steady_a", cooldown = 1, castTime = 1, interruptible = false, effects = { { kind = "shield" } } },
}

local function rig(options: any?)
	local env = FakeEnv.new()
	local vitals =
		Vitals.new(Vitals.define({ pools = { health = { max = 100 }, energy = { max = 50 } } }), nil, env)
	local statuses = StatusEffects.new(
		StatusEffects.define({
			{ id = "silence_a", duration = 2, tags = { "silence" } },
			{ id = "stun_a", duration = 1, tags = { "stun" } },
		}),
		nil,
		env
	)
	local cooldowns = Cooldowns.new(env)
	local positions = { foe = v(20, 0, 0), far = v(100, 0, 0) }
	local opts = {
		vitals = vitals,
		cooldowns = cooldowns,
		statuses = statuses,
		gcd = 0.5,
		origin = function()
			return v(0, 0, 0)
		end,
		locate = function(target: any)
			return positions[target]
		end,
	}
	for k, value in options or {} do
		(opts :: any)[k] = value
	end
	local caster = Abilities.caster(Abilities.define(BOOK :: any), opts, env)
	return caster, env, vitals, statuses, cooldowns
end

local function kinds(events: { any }): string
	local out = {}
	for _, event in events do
		table.insert(out, event.kind .. (if event.effect then "/" .. event.effect.kind else ""))
	end
	return table.concat(out, ",")
end

test("validate: every problem is listed; define raises them joined", function(t)
	local problems = Abilities.validate({
		{ id = "Bad", cooldown = -1, effects = {} },
		{ id = "a", cooldown = 0, charges = 2, effects = { { kind = "x", phase = "tick" } } },
		{ id = "a", cooldown = 1, channel = 2, effects = { { kind = 1 } }, cost = { energy = 0 } },
		{
			id = "b",
			cooldown = 1,
			tickInterval = 1,
			target = "area",
			range = NAN,
			refundOnInterrupt = 2,
			effects = { { kind = "x", phase = "later" } },
		},
		{
			id = "c",
			cooldown = 1,
			castTime = 61,
			blockedBy = { "Not A Tag" },
			interruptible = "yes",
			gcd = 1,
			effects = "none",
		},
	})
	t.ok(has(problems, "abilities[1].id must be a label"))
	t.ok(has(problems, "abilities[1].cooldown"))
	t.ok(has(problems, "abilities[2].charges need a cooldown"))
	t.ok(has(problems, "abilities[2].effects[1] uses phase tick without a channel"))
	t.ok(has(problems, 'abilities[3].id "a" is duplicated'))
	t.ok(has(problems, "abilities[3].tickInterval must be > 0"))
	t.ok(has(problems, "abilities[3].effects[1].kind"))
	t.ok(has(problems, "abilities[3].cost"))
	t.ok(has(problems, "abilities[4].tickInterval only applies"))
	t.ok(has(problems, "abilities[4].target"))
	t.ok(has(problems, "abilities[4].range"))
	t.ok(has(problems, "abilities[4].refundOnInterrupt"))
	t.ok(has(problems, "abilities[4].effects[1].phase"))
	t.ok(has(problems, "abilities[5].castTime"))
	t.ok(has(problems, "abilities[5].blockedBy"))
	t.ok(has(problems, "abilities[5].interruptible"))
	t.ok(has(problems, "abilities[5].gcd"))
	t.ok(has(problems, "abilities[5].effects must be a list"))
	t.eq(#Abilities.validate(BOOK), 0)
	t.ok(not pcall(Abilities.define, { { id = "x", cooldown = NAN, effects = {} } } :: any))
end)

test("cast: instant ability pays cost, starts cooldown and global cooldown on the server clock", function(t)
	local caster, env, vitals = rig()
	local ok, reason, events = caster:cast("instant_a")
	t.ok(ok, reason)
	t.eq(kinds(events), "cast_start,release,effect/damage")
	t.eq(events[3].effect.amount, 5)
	t.eq(select(1, vitals:get("energy")), 40)
	t.eq(select(2, caster:cast("instant_a")), "global_cooldown")
	env:advance(0.5)
	t.eq(select(2, caster:cast("instant_a")), "cooldown")
	t.near(caster:remaining("instant_a"), 1.5, 1e-9)
	env:advance(1.5)
	t.ok(caster:cast("instant_a"))
	t.eq(select(1, vitals:get("energy")), 30)
	-- Not enough energy: refused and nothing is spent.
	vitals:set("energy", 5)
	env:advance(2)
	local refused, why, pool = caster:cast("instant_a")
	t.ok(not refused)
	t.eq(why, "cost")
	t.eq(pool, "energy")
	t.eq(select(1, vitals:get("energy")), 5)
	t.eq(caster:remaining("instant_a"), 0, "a refused cast starts no cooldown")
end)

test("cast: charges allow bursts and recharge in sequence; gcd = false skips the global cooldown", function(t)
	local caster, env = rig()
	t.ok(caster:cast("dash_a"))
	t.ok(caster:cast("dash_a"), "second charge, no global cooldown")
	t.eq(select(2, caster:cast("dash_a")), "cooldown")
	env:advance(3)
	t.ok(caster:cast("dash_a"))
	t.eq(select(2, caster:cast("dash_a")), "cooldown")
end)

test("wind-up: releases at the exact cast end; interrupts refund a fraction, keep the cooldown", function(t)
	local caster, env, vitals = rig()
	local ok, _, started = caster:cast("windup_a", "foe")
	t.ok(ok)
	t.eq(kinds(started), "cast_start")
	t.eq(caster:state(), "casting")
	t.eq(caster:serialize(), "fsm/1:ability:casting")
	t.eq(select(2, caster:cast("instant_a")), "busy", "no casting while casting")
	env:advance(0.3)
	t.eq(#caster:step(), 0)
	env:advance(0.4)
	local released = caster:step()
	t.eq(kinds(released), "release,effect/damage")
	t.eq(released[1].t, 0.5, "release time is the cast end, not the late step")
	t.eq(released[2].target, "foe")
	t.eq(caster:state(), "idle")

	-- Interrupted wind-up: half the energy back, the cooldown stays (cast-cancel spam burns it).
	env:advance(4)
	vitals:set("energy", 50)
	t.ok(caster:cast("windup_a", "foe"))
	t.eq(select(1, vitals:get("energy")), 30)
	local cut = caster:interrupt("moved")
	t.eq(kinds(cut), "interrupted")
	t.eq(cut[1].refund.energy, 10)
	t.eq(select(1, vitals:get("energy")), 40)
	t.eq(select(2, caster:cast("windup_a", "foe")), "global_cooldown")
	env:advance(0.6)
	t.eq(select(2, caster:cast("windup_a", "foe")), "cooldown")
	t.eq(#caster:step(), 0, "nothing releases after an interrupt")
end)

test("targets: unit and point shapes, range with tolerance, and the checkTarget hook", function(t)
	local caster, env = rig()
	t.eq(select(2, caster:cast("windup_a")), "bad_target")
	t.eq(select(2, caster:cast("windup_a", { x = 1 } :: any)), "bad_target")
	t.eq(select(2, caster:cast("windup_a", "ghost")), "bad_target", "unknown unit cannot be located")
	local far, reason, distance = caster:cast("windup_a", "far")
	t.ok(not far)
	t.eq(reason, "out_of_range")
	t.eq(distance, 100)
	t.eq(select(2, caster:cast("channel_a", v(NAN, 0, 0))), "bad_target")
	t.eq(select(2, caster:cast("channel_a", v(0, 0, 41.5))), "out_of_range")
	t.ok(caster:cast("channel_a", v(0, 0, 40.5)), "inside range + 1 stud tolerance")
	env:advance(10)
	local walled = rig({
		checkTarget = function(_def: any, target: any)
			return target ~= "foe", "no_line_of_sight"
		end,
	})
	t.eq(select(2, walled:cast("windup_a", "foe")), "no_line_of_sight")
	t.eq(select(2, caster:cast("nope")), "unknown_ability")
	t.eq(select(2, caster:cast(42 :: any)), "unknown_ability")
end)

test("channel: ticks land on exact times whatever the step size, then the end effect", function(t)
	local function run(dt: number): { string }
		local caster, env = rig()
		local log = {}
		local _, _, events = caster:cast("channel_a", v(10, 0, 0))
		for _, event in events do
			table.insert(
				log,
				string.format(
					"%s@%g",
					event.kind .. (if event.effect then "/" .. event.effect.kind else ""),
					event.t
				)
			)
		end
		local elapsed = 0
		while elapsed < 1.5 do
			env:advance(dt)
			elapsed += dt
			for _, event in caster:step() do
				table.insert(
					log,
					string.format(
						"%s@%g",
						event.kind .. (if event.effect then "/" .. event.effect.kind else ""),
						event.t
					)
				)
			end
		end
		return log
	end
	local fine = run(1 / 60)
	local coarse = run(0.7)
	t.eq(fine, coarse, "same events and times at 60 Hz and at 0.7 s steps")
	t.eq(fine, {
		"cast_start@0",
		"release@0",
		"effect/zone@0",
		"channel_tick@0.25",
		"effect/damage@0.25",
		"channel_tick@0.5",
		"effect/damage@0.5",
		"channel_tick@0.75",
		"effect/damage@0.75",
		"channel_tick@1",
		"effect/damage@1",
		"channel_end@1",
		"effect/burst@1",
	})
end)

test("statuses and death: blocking tags refuse and interrupt; uninterruptible casts finish", function(t)
	local caster, env, vitals, statuses = rig()
	statuses:apply("silence_a")
	local refused, reason, tag = caster:cast("channel_a", v(1, 0, 0))
	t.ok(not refused)
	t.eq(reason, "blocked")
	t.eq(tag, "silence")
	env:advance(2.5)
	statuses:step()
	t.ok(caster:cast("channel_a", v(1, 0, 0)))
	env:advance(0.3)
	caster:step()
	statuses:apply("silence_a")
	env:advance(0.1)
	local cut = caster:step()
	t.eq(kinds(cut), "interrupted")
	t.eq(cut[1].reason, "blocked")

	-- steady_a cannot be interrupted by moves, only by death.
	env:advance(10)
	statuses:clear()
	t.ok(caster:cast("steady_a"))
	t.eq(#caster:interrupt("moved"), 0)
	vitals:kill()
	env:advance(0.1)
	local dead = caster:step()
	t.eq(dead[1].reason, "dead")
	t.eq(select(2, caster:cast("instant_a")), "dead")
	t.eq(caster:state(), "idle")
end)

test("abuse: request spam while busy changes nothing; refused casts never commit", function(t)
	local caster, env, vitals, _, cooldowns = rig()
	t.ok(caster:cast("steady_a"))
	local energy = select(1, vitals:get("energy"))
	for _ = 1, 100 do
		t.eq(select(2, caster:cast("instant_a")), "busy")
	end
	t.eq(select(1, vitals:get("energy")), energy)
	t.eq(cooldowns:remaining("ability:instant_a"), 0)
	env:advance(1)
	t.eq(kinds(caster:step()), "release,effect/shield")
	-- Without vitals, a costed ability is refused rather than free.
	local env2 = FakeEnv.new()
	local bare = Abilities.caster(Abilities.define(BOOK :: any), { cooldowns = Cooldowns.new(env2) }, env2)
	t.eq(select(2, bare:cast("instant_a")), "cost")
	t.ok(bare:cast("dash_a"))
	t.throws(function()
		Abilities.caster(Abilities.define(BOOK :: any), {} :: any, env2)
	end)
end)

return cases
