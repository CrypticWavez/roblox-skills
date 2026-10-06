--!strict
-- G2 combat cores: Cooldowns (server time, charges, key cap, abuse), Vitals (pools, modifier
-- pipeline, NaN rejection, death, downed, regen, credit) and Hitbox (shapes, overlap, swept
-- tests, rewind history edges, melee activations, the hit-claim validator).
local Cooldowns = require("../packages/GameKit/Cooldowns")
local Hitbox = require("../packages/GameKit/Hitbox")
local Vitals = require("../packages/GameKit/Vitals")
local FakeEnv = require("./fakes/FakeEnv")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function errorText(fn: () -> ()): string
	local ok, err = pcall(fn)
	assert(not ok, "expected an error")
	return tostring(err)
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

-- ---------------------------------------------------------------- Cooldowns

test("Cooldowns: use, ready and remaining follow the server clock to the exact boundary", function(t)
	local env = FakeEnv.new()
	local cd = Cooldowns.new(env)
	t.ok(cd:ready("fire"))
	local ok, remaining = cd:use("fire", 2)
	t.ok(ok)
	t.eq(remaining, 2)
	t.ok(not cd:ready("fire"))
	env:advance(1.5)
	t.near(cd:remaining("fire"), 0.5)
	local again, left, reason = cd:use("fire", 2)
	t.eq({ again, reason }, { false, "cooldown" })
	t.near(left, 0.5)
	env:advance(0.5)
	t.ok(cd:ready("fire"), "ready exactly at the boundary")
	t.ok((cd:use("fire", 2)))
end)

test("Cooldowns: charges recharge one at a time", function(t)
	local env = FakeEnv.new()
	local cd = Cooldowns.new(env)
	t.ok((cd:use("dash", 1, 2)))
	t.ok((cd:use("dash", 1, 2)))
	local ok, remaining, reason = cd:use("dash", 1, 2)
	t.eq({ ok, reason }, { false, "cooldown" })
	t.eq(remaining, 1)
	t.eq({ cd:charges("dash") }, { 0, 2 })
	env:advance(1)
	t.eq({ cd:charges("dash") }, { 1, 2 })
	t.ok((cd:use("dash", 1, 2)))
	env:advance(2)
	t.eq({ cd:charges("dash") }, { 2, 2 })
end)

test("Cooldowns: floating sums never leave a charge just short", function(t)
	local env = FakeEnv.new()
	local cd = Cooldowns.new(env)
	for _ = 1, 20 do
		t.ok((cd:use("tick", 0.1)), "use at " .. env.clock())
		env:advance(0.1)
	end
end)

test("Cooldowns: a clock function works and bad arguments raise", function(t)
	local now = 0
	local cd = Cooldowns.new(function()
		return now
	end)
	cd:use("a", 1)
	now = 1
	t.ok(cd:ready("a"))
	t.ok(string.find(
		errorText(function()
			cd:use("a", NAN)
		end),
		"finite",
		1,
		true
	) ~= nil)
	t.throws(function()
		cd:use("a", -1)
	end)
	t.throws(function()
		cd:use("", 1)
	end)
	t.throws(function()
		cd:use(string.rep("k", 129), 1)
	end)
	t.throws(function()
		cd:use(5 :: any, 1)
	end)
	t.throws(function()
		cd:use("a", 1, 0)
	end)
	t.throws(function()
		cd:use("a", 1, 1.5)
	end)
	t.throws(function()
		cd:use("a", 1, 100)
	end)
	t.throws(function()
		Cooldowns.new({})
	end)
	t.throws(function()
		Cooldowns.new({ maxKeys = 0 }, now)
	end)
end)

test("Cooldowns: key spam is capped and expired keys make room", function(t)
	local env = FakeEnv.new()
	local cd = Cooldowns.new({ maxKeys = 3 }, env)
	for index = 1, 3 do
		t.ok((cd:use("k" .. index, 5)))
	end
	local ok, _, reason = cd:use("k4", 5)
	t.eq({ ok, reason }, { false, "full" })
	t.eq(cd:size(), 3)
	env:advance(5)
	t.ok((cd:use("k4", 5)), "expired keys purged")
	t.eq(cd:size(), 1)
end)

test("Cooldowns: extend, reset and a period change rescale the wait", function(t)
	local env = FakeEnv.new()
	local cd = Cooldowns.new(env)
	t.eq(cd:extend("stun_lock", 1.5), 1.5)
	t.ok(not cd:ready("stun_lock"))
	t.eq(cd:extend("stun_lock", -1), 0.5)
	t.eq(cd:extend("stun_lock", -10), 0)
	cd:use("cast", 2)
	env:advance(1)
	-- Half a charge is outstanding; at a 4 s period that is 2 s.
	local ok, remaining = cd:use("cast", 4)
	t.ok(not ok)
	t.near(remaining, 2)
	cd:reset("cast")
	t.ok(cd:ready("cast"))
	t.throws(function()
		cd:extend("cast", NAN)
	end)
end)

test("Cooldowns: snapshot and restore round-trip; bad entries are listed", function(t)
	local env = FakeEnv.new()
	local cd = Cooldowns.new(env)
	cd:use("a", 3)
	cd:use("b", 1, 2)
	env:advance(1)
	local snap = cd:snapshot()
	t.eq(snap.a, { remaining = 2, period = 3, max = 1 })
	local other = Cooldowns.new(env)
	t.eq(other:restore(snap), {})
	t.near(other:remaining("a"), 2)
	local problems = other:restore({
		x = { remaining = NAN, period = 1, max = 1 },
		y = { remaining = 50, period = 1, max = 1 },
		z = "nope",
		[7] = {},
	})
	t.eq(#problems, 4)
	t.eq(other:restore(nil), { "snapshot must be a table" })
end)

-- ---------------------------------------------------------------- Vitals

local function basicSpec(extra: { [string]: any }?)
	local def: { [string]: any } = {
		pools = {
			health = { max = 100 },
			shield = { max = 50, regen = 10, regenDelay = 3 },
			stamina = { max = 100, regen = 2.5, regenDelay = 1 },
		},
	}
	for key, value in extra or {} do
		def[key] = value
	end
	return Vitals.define(def :: any)
end

test("Vitals.validate lists every definition problem", function(t)
	local problems = Vitals.validate({
		pools = {
			shield = { max = 10.5 },
			Bad = { max = 1 },
			stamina = { max = 10, regen = -1, start = 20 },
		},
		absorb = { "health", "shield" },
		rounding = "sometimes",
		downed = { bleedout = 0 },
		logSize = 1000,
		modifiers = { { id = "x", apply = 1 }, { id = "x", apply = function() end } },
	})
	for _, needle in
		{
			"rounding must be",
			"max must be an integer",
			"name must be a label",
			"regen must be",
			"start must be",
			"a health pool is required",
			"absorb names unknown pool",
			"downed.bleedout",
			"logSize",
			"apply must be a function",
		}
	do
		t.ok(has(problems, needle), needle .. " in " .. table.concat(problems, " | "))
	end
	t.ok(has(Vitals.validate({ pools = { health = { max = 1 } }, absorb = { "health", "health" } }), "twice"))
	t.ok(has(
		Vitals.validate({
			pools = { health = { max = 1 }, shield = { max = 1 } },
			absorb = { "health", "shield" },
		}),
		"end with health"
	))
	local many = {}
	for index = 1, 17 do
		many["p" .. index] = { max = 1 }
	end
	many.health = { max = 1 }
	t.ok(has(Vitals.validate({ pools = many }), "at most 16 pools"))
	t.eq(Vitals.validate(nil), { "definition must be a table" })
	t.throws(function()
		Vitals.define({ pools = {} } :: any)
	end)
end)

test("Vitals: shield absorbs before health and the record says how", function(t)
	local env = FakeEnv.new()
	local vitals = Vitals.new(basicSpec(), nil, env)
	local changes = {}
	vitals.changed:Connect(function(pool, value)
		table.insert(changes, pool .. "=" .. value)
	end)
	local record =
		vitals:damage({ amount = 70, kind = "impact", source = { attacker = "2", ability = "swing_a" } })
	t.ok(record.ok)
	t.eq(record.amount, 70)
	t.eq(record.applied, 70)
	t.eq(record.absorbed, { shield = 50, health = 20 })
	t.eq(record.source, { attacker = "2", ability = "swing_a" })
	t.eq({ vitals:get("health") }, { 80, 100 })
	t.eq({ vitals:get("shield") }, { 0, 50 })
	t.eq(changes, { "shield=0", "health=80" })
	t.eq(vitals:snapshot(), {
		state = "alive",
		health = 80,
		healthMax = 100,
		shield = 0,
		shieldMax = 50,
		stamina = 100,
		staminaMax = 100,
	})
end)

test("Vitals: NaN, inf, negative and non-number damage is rejected without changing state", function(t)
	local env = FakeEnv.new()
	local vitals = Vitals.new(basicSpec(), nil, env)
	for _, amount in { NAN, math.huge, -math.huge, -5, "10", nil, true } do
		local record = vitals:damage({ amount = amount })
		t.eq({ record.ok, record.reason }, { false, "bad_amount" }, tostring(amount))
	end
	t.eq(vitals:damage(nil :: any).reason, "bad_input")
	t.eq(vitals:damage({ amount = 5, kind = "Fire!" }).reason, "bad_kind")
	t.eq(vitals:damage({ amount = 5, source = { attacker = NAN, position = v(NAN, 0, 0) } }).source, {})
	t.eq({ vitals:get("health") }, { 100, 100 })
	t.eq({ vitals:get("shield") }, { 45, 50 })
	t.eq({ vitals:heal(NAN) }, { 0, "bad_amount" })
	t.eq({ vitals:spend("stamina", math.huge) }, { false, "bad_amount" })
	local huge = vitals:damage({ amount = 1e300 })
	t.eq(huge.amount, Vitals.MAX_VALUE)
	t.eq(vitals:state(), "dead")
end)

test("Vitals: modifiers run by priority (crit, resist, armour, cap) and bad ones are ignored", function(t)
	local env = FakeEnv.new()
	local spec = Vitals.define({ pools = { health = { max = 1000 } } })
	local vitals = Vitals.new(spec, {
		modifiers = {
			Vitals.cap(40),
			Vitals.armor(100),
			Vitals.resist("fire", 0.5),
			Vitals.crit(2),
			{
				id = "broken_nan",
				priority = 60,
				apply = function(ctx)
					ctx.amount = 0 / 0
				end,
			},
			{
				id = "broken_error",
				priority = 70,
				apply = function()
					error("boom")
				end,
			},
		},
	}, env)
	local record = vitals:damage({ amount = 100, kind = "fire", crit = true })
	t.eq(record.amount, 40)
	t.ok(record.crit)
	t.eq(#env.reports, 2)
	local plain = vitals:damage({ amount = 100, kind = "impact" })
	t.eq(plain.amount, 40, "cap still applies: 100 * 100/200 = 50 -> 40")
	local small = vitals:damage({ amount = 30, kind = "impact" })
	t.eq(small.amount, 15)
	t.throws(function()
		Vitals.new(spec, { modifiers = { { id = "x", apply = 5 :: any } } }, env)
	end)
end)

test("Vitals: rounding modes keep pools integer and a block modifier cancels", function(t)
	local env = FakeEnv.new()
	local vitals = Vitals.new(Vitals.define({ pools = { health = { max = 100 } } }), {
		modifiers = {
			{
				id = "block",
				apply = function(ctx)
					if ctx.tags.blocked then
						ctx.cancelled = "blocked"
					end
				end,
			},
		},
	}, env)
	vitals:damage({ amount = 10.5 })
	t.eq(vitals:get("health"), 89)
	local record = vitals:damage({ amount = 50, tags = { "blocked" } })
	t.eq({ record.ok, record.reason, record.cancelledBy }, { false, "cancelled", "blocked" })
	t.eq(vitals:get("health"), 89)
	local floor =
		Vitals.new(Vitals.define({ pools = { health = { max = 100 } }, rounding = "floor" }), nil, env)
	floor:damage({ amount = 10.9 })
	t.eq(floor:get("health"), 90)
	local exact =
		Vitals.new(Vitals.define({ pools = { health = { max = 1.5 } }, rounding = "none" }), nil, env)
	exact:damage({ amount = 0.25 })
	t.eq(exact:get("health"), 1.25)
end)

test("Vitals: crit chance rolls are seeded and deterministic", function(t)
	local function rolls(seed: string): { boolean }
		local env = FakeEnv.new()
		local vitals = Vitals.new(Vitals.define({ pools = { health = { max = 100000 } } }), {
			seed = seed,
			modifiers = { Vitals.crit(2, 0.5) },
		}, env)
		local out = {}
		for _ = 1, 32 do
			table.insert(out, vitals:damage({ amount = 1 }).crit)
		end
		return out
	end
	t.eq(rolls("a"), rolls("a"))
	local a, b = rolls("a"), rolls("b")
	local differs = false
	for index = 1, #a do
		differs = differs or a[index] ~= b[index]
	end
	t.ok(differs, "different seeds give different rolls")
end)

test("Vitals: death fires once, records overkill and credits killer and assists", function(t)
	local env = FakeEnv.new()
	local vitals = Vitals.new(basicSpec(), nil, env)
	local deaths = {}
	vitals.died:Connect(function(record)
		table.insert(deaths, record)
	end)
	vitals:damage({ amount = 60, source = { attacker = "a" } })
	env:advance(1)
	vitals:damage({ amount = 30, source = { attacker = "b" } })
	env:advance(1)
	local lethal = vitals:damage({ amount = 100, source = { attacker = "c" } })
	t.ok(lethal.lethal)
	t.eq(lethal.overkill, 40)
	t.eq(lethal.applied, 60)
	t.eq(vitals:state(), "dead")
	t.eq(#deaths, 1)
	t.eq(vitals:killer(), "c")
	t.eq(vitals:assists(5, "c"), { { attacker = "a", damage = 60 }, { attacker = "b", damage = 30 } })
	t.eq(vitals:assists(1.5, "c"), { { attacker = "b", damage = 30 } })
	t.eq(vitals:damage({ amount = 5 }).reason, "dead")
	t.eq(#deaths, 1)
	t.eq(vitals:kill(), nil)
	t.ok(vitals:revive({ invulnerable = 2, refill = true }))
	t.eq(vitals:get("health"), 100)
	t.eq(vitals:get("shield"), 50)
	t.eq(vitals:damage({ amount = 5 }).reason, "invulnerable")
	env:advance(2)
	t.ok(vitals:damage({ amount = 5 }).ok)
	t.ok(not vitals:revive())
end)

test("Vitals: downed state bleeds out, can be finished or revived", function(t)
	local env = FakeEnv.new()
	local spec = basicSpec({ downed = { bleedout = 10, reviveHealth = 25 } })
	local vitals = Vitals.new(spec, nil, env)
	local downs = 0
	vitals.downed:Connect(function()
		downs += 1
	end)
	vitals:damage({ amount = 500, source = { attacker = "x" } })
	t.eq(vitals:state(), "downed")
	t.eq(downs, 1)
	t.eq(vitals:killer(), "x")
	t.eq({ vitals:heal(10) }, { 0, "not_alive" })
	t.ok(vitals:revive())
	t.eq(vitals:get("health"), 25)
	vitals:damage({ amount = 500 })
	env:advance(9.9)
	vitals:step(0.1)
	t.eq(vitals:state(), "downed")
	env:advance(0.1)
	vitals:step(0.1)
	t.eq(vitals:state(), "dead")
	t.eq(vitals:recent()[1].reason, "bleedout")
	vitals:reset()
	vitals:damage({ amount = 500 })
	local finisher = vitals:damage({ amount = 1, source = { attacker = "y" } })
	t.ok(finisher.lethal)
	t.eq(vitals:state(), "dead")
end)

test("Vitals: regen waits for its delay and carries fractions on integer pools", function(t)
	local env = FakeEnv.new()
	local vitals = Vitals.new(basicSpec(), nil, env)
	t.eq({ vitals:spend("stamina", 0.4) }, { true, nil })
	t.eq(vitals:get("stamina"), 99, "fractional costs round up, never free")
	t.eq({ vitals:spend("stamina", 200) }, { false, "insufficient" })
	t.eq({ vitals:spend("mana", 1) }, { false, "unknown_pool" })
	t.ok(vitals:canSpend("stamina", 99) and not vitals:canSpend("stamina", 99.5))
	vitals:damage({ amount = 20 }) -- shield 50 -> 30 at t = 0
	-- 1/8 s steps keep the clock exact. Stamina (2.5/s, 1 s delay) regenerates from t = 1 and is
	-- back to 100 after four steps; the shield waits its 3 s.
	for _ = 1, 16 do
		env:advance(0.125)
		vitals:step(0.125)
	end
	t.eq(vitals:get("stamina"), 100)
	t.eq(vitals:get("shield"), 30, "shield waits 3 s after the hit")
	vitals:spend("stamina", 9) -- 91 at t = 2
	for _ = 1, 16 do
		env:advance(0.125)
		vitals:step(0.125)
	end
	-- Steps at t = 3.0 .. 4.0 (9 steps): stamina 9 x 0.3125 = 2.81 -> +2, shield 9 x 1.25 = 11.25 -> +11.
	t.eq(vitals:get("stamina"), 93, "whole points only; the fraction carries")
	t.eq(vitals:get("shield"), 41)
	env:advance(0.125)
	vitals:step(0.125)
	t.eq(vitals:get("stamina"), 94, "carried 0.81 + 0.31 crosses a whole point")
	vitals:step(NAN)
	t.ok(#env.reports == 1)
end)

test("Vitals: heal, restore, set and setMax clamp and keep integers", function(t)
	local env = FakeEnv.new()
	local vitals = Vitals.new(basicSpec(), nil, env)
	vitals:damage({ amount = 90 }) -- shield takes 50, health 60
	t.eq({ vitals:heal(15.4) }, { 15, nil })
	t.eq({ vitals:heal(1000) }, { 25, nil })
	t.eq(vitals:restore("shield", 20), 20)
	vitals:setMax("health", 200, true)
	t.eq({ vitals:get("health") }, { 200, 200 })
	vitals:setMax("health", 50)
	t.eq({ vitals:get("health") }, { 50, 50 })
	vitals:set("health", 0)
	t.eq(vitals:state(), "dead")
	t.throws(function()
		vitals:set("mana", 1)
	end)
	t.throws(function()
		vitals:setMax("health", NAN)
	end)
end)

-- ---------------------------------------------------------------- Hitbox shapes

test("Hitbox.validate rejects bad shapes", function(t)
	t.eq(Hitbox.validate(Hitbox.sphere(v(0, 0, 0), 1)), {})
	t.ok(has(Hitbox.validate({ kind = "cone" }), "kind must be"))
	t.ok(has(Hitbox.validate({ kind = "sphere", center = v(NAN, 0, 0), radius = 1 }), "center"))
	t.ok(has(Hitbox.validate({ kind = "sphere", center = v(0, 0, 0), radius = -1 }), "radius"))
	t.ok(has(Hitbox.validate({ kind = "box", center = v(0, 0, 0), size = v(1, 1, 5000) }), "size.z"))
	t.ok(has(
		Hitbox.validate({
			kind = "box",
			center = v(0, 0, 0),
			size = v(1, 1, 1),
			axes = { v(2, 0, 0), v(0, 1, 0), v(0, 0, 1) },
		}),
		"unit"
	))
	t.ok(has(Hitbox.validate({ kind = "capsule", a = v(0, 0, 0), radius = 1 }), "capsule ends"))
	t.eq(Hitbox.validate(5), { "shape must be a table" })
end)

test("Hitbox: closest points, distances and containment for every shape", function(t)
	local sphere = Hitbox.sphere(v(0, 0, 0), 2)
	t.eq(Hitbox.distance(sphere, v(5, 0, 0)), 3)
	t.ok(Hitbox.contains(sphere, v(1, 1, 0)))
	local box = Hitbox.box(v(0, 0, 0), v(2, 4, 6), v(0, 90, 0))
	-- Rotated 90 degrees about Y: the 2-stud width now lies along z, the 6-stud depth along x.
	t.ok(Hitbox.contains(box, v(2.9, 0, 0)))
	t.ok(not Hitbox.contains(box, v(0, 0, 1.5)))
	t.near(Hitbox.distance(box, v(0, 0, 3)), 2, 1e-9)
	local capsule = Hitbox.capsule(v(0, 0, 0), v(0, 10, 0), 1)
	t.near(Hitbox.distance(capsule, v(3, 5, 0)), 2)
	t.near(Hitbox.distance(capsule, v(0, 13, 0)), 2)
	local closest = Hitbox.closestPoint(capsule, v(3, 5, 0))
	t.near(closest.x, 1)
	t.eq(Hitbox.center(capsule), v(0, 5, 0))
	local mn, mx = Hitbox.bounds(box)
	t.near(mx.x, 3, 1e-9)
	t.near(mn.z, -1, 1e-9)
end)

test("Hitbox.overlaps covers every pair, touching counts", function(t)
	local s1 = Hitbox.sphere(v(0, 0, 0), 1)
	t.ok(Hitbox.overlaps(s1, Hitbox.sphere(v(2, 0, 0), 1)), "touching spheres")
	t.ok(not Hitbox.overlaps(s1, Hitbox.sphere(v(2.01, 0, 0), 1)))
	local box = Hitbox.box(v(0, 0, 0), v(2, 2, 2))
	t.ok(Hitbox.overlaps(Hitbox.sphere(v(1.9, 0, 0), 1), box))
	t.ok(not Hitbox.overlaps(box, Hitbox.sphere(v(1.8, 1.8, 0), 1)), "corner gap: distance 1.13 > 1")
	local cap = Hitbox.capsule(v(-5, 0, 0), v(5, 0, 0), 0.5)
	t.ok(Hitbox.overlaps(cap, Hitbox.sphere(v(0, 1.4, 0), 1)))
	t.ok(not Hitbox.overlaps(cap, Hitbox.sphere(v(0, 1.6, 0), 1)))
	t.ok(Hitbox.overlaps(cap, Hitbox.capsule(v(0, 0.9, -5), v(0, 0.9, 5), 0.5)), "skew capsules")
	t.ok(not Hitbox.overlaps(cap, Hitbox.capsule(v(0, 1.1, -5), v(0, 1.1, 5), 0.5)))
	t.ok(Hitbox.overlaps(Hitbox.capsule(v(-5, 1.4, 0), v(5, 1.4, 0), 0.5), box), "capsule over a box face")
	t.ok(not Hitbox.overlaps(Hitbox.capsule(v(-5, 1.6, 0), v(5, 1.6, 0), 0.5), box))
	-- Capsule passing a corner diagonally: closest approach sqrt(2) * 1.6 - 1.414 = 0.849 < 0.9.
	t.ok(Hitbox.overlaps(Hitbox.capsule(v(-5, 3.2, 0), v(5, -6.8, 0), 0.9), box))
end)

test("Hitbox.overlaps: oriented boxes use the separating axes", function(t)
	local a = Hitbox.box(v(0, 0, 0), v(2, 2, 2))
	t.ok(Hitbox.overlaps(a, Hitbox.box(v(1.9, 0, 0), v(2, 2, 2))))
	t.ok(not Hitbox.overlaps(a, Hitbox.box(v(2.1, 0, 0), v(2, 2, 2))))
	-- Their bounding boxes overlap, but the 45-degree box's face separates them.
	local diamond = Hitbox.box(v(2.3, 2.3, 0), v(2, 2, 2), v(0, 0, 45))
	local mn = Hitbox.bounds(diamond)
	t.ok(mn.x < 1 and mn.y < 1, "bounds overlap")
	t.ok(not Hitbox.overlaps(a, diamond))
	t.ok(Hitbox.overlaps(a, Hitbox.box(v(2.3, 0, 0), v(2, 2, 2), v(0, 0, 45))), "rotated corner pokes in")
	-- Two diamond-section rods crossing at right angles, one above the other: their top and bottom
	-- edges are 1.5 - 2 x 0.707 apart, and only the edge-cross-edge axis (z x x = y) separates
	-- them; every face axis overlaps.
	local e1 = Hitbox.box(v(0, 0, 0), v(1, 1, 10), v(0, 0, 45))
	local e2 = Hitbox.box(v(0, 1.5, 0), v(10, 1, 1), v(45, 0, 0))
	t.ok(not Hitbox.overlaps(e1, e2))
	t.ok(Hitbox.overlaps(e1, Hitbox.box(v(0, 1.3, 0), v(10, 1, 1), v(45, 0, 0))))
end)

test("Hitbox.segment: closed-form sphere, slab box and swept-sphere contacts", function(t)
	local hit, fraction, point = Hitbox.segment(Hitbox.sphere(v(0, 0, 0), 1), v(-10, 0, 0), v(20, 0, 0))
	t.ok(hit)
	t.near(fraction :: number, 0.45)
	t.near((point :: any).x, -1)
	t.eq({ Hitbox.segment(Hitbox.sphere(v(0, 0, 0), 1), v(-10, 2, 0), v(20, 0, 0)) }, { false, nil, nil })
	t.eq(select(2, Hitbox.segment(Hitbox.sphere(v(0, 0, 0), 1), v(0, 0, 0), v(5, 0, 0))), 0, "starts inside")
	t.ok(not Hitbox.segment(Hitbox.sphere(v(0, 0, 0), 1), v(5, 0, 0), v(0, 0, 0)), "zero motion outside")
	local box = Hitbox.box(v(0, 0, 0), v(2, 2, 2))
	local _, boxT = Hitbox.segment(box, v(-10, 0, 0), v(20, 0, 0))
	t.near(boxT :: number, 0.45)
	local _, sweptT = Hitbox.segment(box, v(-10, 0, 0), v(20, 0, 0), 1)
	t.near(sweptT :: number, 0.4, 1e-9)
	local rotated = Hitbox.box(v(0, 0, 0), v(2, 2, 2), v(0, 45, 0))
	local _, rotT = Hitbox.segment(rotated, v(-10, 0, 0), v(20, 0, 0))
	t.near(rotT :: number, (10 - math.sqrt(2)) / 20, 1e-9)
	local capsule = Hitbox.capsule(v(0, -5, 0), v(0, 5, 0), 0.5)
	local _, capT = Hitbox.segment(capsule, v(-10, 0, 0), v(20, 0, 0), 0.5)
	t.near(capT :: number, 0.45, 1e-9)
	t.ok(not Hitbox.segment(capsule, v(-10, 6.1, 0), v(20, 0, 0), 0.5))
end)

test("Hitbox activations dedupe, cap, ignore the attacker and do not tunnel", function(t)
	local targets = {
		{ id = "b", shape = Hitbox.box(v(5, 0, 0), v(0.2, 4, 4)) },
		{ id = "a", shape = Hitbox.sphere(v(5, 0, 3), 1) },
		{ id = "self", shape = Hitbox.sphere(v(0, 0, 0), 1) },
	}
	local blade = Hitbox.activation({ ignore = { "self" } })
	-- A 0.5-stud sphere crossing a 0.2-stud wall in one 10-stud frame: the end poses miss it.
	local before, after = Hitbox.sphere(v(0, 0, 0), 0.5), Hitbox.sphere(v(10, 0, 0), 0.5)
	t.eq(Hitbox.activation():test(before, targets), { "self" })
	t.eq(Hitbox.activation({ ignore = { "self" } }):test(after, targets), {})
	t.eq(blade:sweep(before, after, targets), { "b" })
	t.eq(blade:sweep(before, after, targets), {}, "each target once per activation")
	local wide = Hitbox.activation({ maxHits = 1 })
	t.eq(wide:test(Hitbox.sphere(v(5, 0, 2), 2), targets), { "a" }, "sorted ids, capped at one")
	t.eq(wide:hits(), { "a" })
	wide:reset()
	t.eq(wide:hits(), {})
	t.eq(#Hitbox.sweepPoses(before, after, 0.5), 21)
	t.eq(#Hitbox.sweepPoses(before, Hitbox.sphere(v(1000, 0, 0), 0.5), 0.1), Hitbox.MAX_POSES)
end)

-- ---------------------------------------------------------------- Hitbox history and rewind

test("Hitbox.history interpolates, clamps to the newest and refuses the past", function(t)
	local history = Hitbox.history({ capacity = 4 })
	t.eq(select(2, history:at(0)), "empty")
	for index = 0, 5 do
		t.ok(history:record(index, Hitbox.sphere(v(index * 10, 0, 0), 1)))
	end
	t.eq(history:size(), 4)
	t.eq(history:oldest(), 2)
	local mid = history:at(3.25) :: any
	t.near(mid.center.x, 32.5)
	t.eq((history:at(99) :: any).center.x, 50)
	t.eq(select(2, history:at(1.9)), "too_old")
	t.ok(not history:record(4, Hitbox.sphere(v(0, 0, 0), 1)), "time must not go backwards")
	t.ok(history:record(5, Hitbox.sphere(v(99, 0, 0), 1)), "same time replaces")
	t.eq((history:at(5) :: any).center.x, 99)
	t.ok(not history:record(6, { kind = "sphere", center = v(NAN, 0, 0), radius = 1 }))
	t.throws(function()
		Hitbox.history({ capacity = 1 })
	end)
end)

-- A shooter capsule standing at the origin and a target capsule strafing along +x at 20 studs/s,
-- 50 studs down -z, sampled at 64 Hz for one second (exact binary times).
local function arena(options: { [string]: any }?)
	local env = FakeEnv.new()
	local opts: { [string]: any } = { maxRange = 300, fireInterval = 0.1, burst = 2 }
	for key, value in options or {} do
		opts[key] = value
	end
	local validator = Hitbox.validator(opts :: any, env)
	local function step()
		local now = env.clock()
		validator:record("s", Hitbox.capsule(v(0, 0, 0), v(0, 3, 0), 1))
		validator:record("t", Hitbox.capsule(v(20 * now, 0, -50), v(20 * now, 3, -50), 1))
	end
	step()
	for _ = 1, 64 do
		env:advance(1 / 64)
		step()
	end
	return env, validator
end

local function aimAt(x: number)
	local origin = v(0, 1.5, 0)
	local d = v(x, 0, -50)
	return origin, d
end

test("Hitbox.validator accepts a lag-compensated shot that misses the current pose", function(t)
	local env, validator = arena()
	t.eq(env.clock(), 1)
	local origin, direction = aimAt(18)
	local ok, reason, detail =
		validator:check({ shooter = "s", target = "t", time = 0.9, origin = origin, direction = direction })
	t.ok(ok, tostring(reason))
	t.near(detail.rewind :: number, 0.1)
	local now, why =
		validator:check({ shooter = "s", target = "t", time = 1, origin = origin, direction = direction })
	t.eq({ now, why }, { false, "miss" }, "without rewind the target has moved 2 studs")
end)

test(
	"Hitbox.validator rewind window edges: exact edge passes, older fails or clamps, never past 200 ms",
	function(t)
		local env, validator = arena()
		validator:setLatency("s", 0.05) -- window = min(0.2, 0.05 + 0.1 + 0.05) = 0.2
		local origin, direction = aimAt(16)
		local ok = validator:check({
			shooter = "s",
			target = "t",
			time = 0.8,
			origin = origin,
			direction = direction,
		})
		t.ok(ok, "exactly at the 200 ms edge")
		env:advance(0.1)
		local stale, reason, detail = validator:check({
			shooter = "s",
			target = "t",
			time = 0.8 - 1e-6,
			origin = origin,
			direction = direction,
		})
		t.eq({ stale, reason }, { false, "too_old" })
		t.ok((detail.rewind :: number) > 0.2)
		validator:setLatency("s", 5)
		t.ok(validator:check({
			shooter = "s",
			target = "t",
			time = 0.9,
			origin = origin,
			direction = direction,
		}) == false, "latency is clamped to maxRewind")
		t.ok(string.find(
			errorText(function()
				Hitbox.validator({ maxRange = 10, maxRewind = 0.25 } :: any, env)
			end),
			"maxRewind must be <= 0.200",
			1,
			true
		) ~= nil)
		local _, clamped = arena({ clampOld = true })
		local origin2, direction2 = aimAt(17)
		local okClamp, why = clamped:check({
			shooter = "s",
			target = "t",
			time = 0.2,
			origin = origin2,
			direction = direction2,
		})
		t.ok(okClamp, "clampOld validates against the window edge (t = 0.85): " .. tostring(why))
	end
)

test("Hitbox.validator rejects exploit claims with a reason each", function(t)
	-- fireInterval 0 turns the rate limit off, so every attempt below meets the same clock.
	local env, validator = arena({ maxAngle = 10, hitTolerance = 0.5, fireInterval = 0 })
	local origin, direction = aimAt(18)
	local function check(claim: { [string]: any }): (boolean, string?)
		local base: { [string]: any } =
			{ shooter = "s", target = "t", time = 0.9, origin = origin, direction = direction }
		for key, value in claim do
			base[key] = value
		end
		local ok, reason = validator:check(base :: any)
		return ok, reason
	end
	t.eq(env.clock(), 1)
	t.eq({ check({ origin = v(0, 1.5, -45) }) }, { false, "origin_mismatch" }, "teleported muzzle")
	t.eq({ check({ time = 5 }) }, { false, "future_time" })
	t.eq({ check({ origin = v(NAN, 0, 0) }) }, { false, "bad_claim" })
	t.eq({ check({ direction = v(0, 0, 0) }) }, { false, "bad_claim" })
	t.eq({ check({ target = "s" }) }, { false, "self_hit" })
	t.eq({ check({ target = "ghost" }) }, { false, "unknown_target" })
	t.eq({ check({ shooter = "ghost" }) }, { false, "unknown_shooter" })
	t.eq({ check({ hitPoint = v(18, 1.5, -49), direction = v(1, 0, 0) }) }, { false, "bad_angle" })
	t.eq({ check({ hitPoint = v(18, 1.5, -40) }) }, { false, "hitpoint_mismatch" })
	t.eq({ check({ direction = v(1, 0, -50) }) }, { false, "miss" })
	t.eq({ check({ shotId = "shot_1" }) }, { true, nil })
	t.eq({ check({ shotId = "shot_1" }) }, { false, "duplicate_shot" }, "replayed shot id")
	local stats = validator:stats()
	t.eq(stats.accepted, 1)
	t.eq(stats.rejected.bad_claim, 2)
end)

test("Hitbox.validator: rapid fire, range, line of sight and liveness hooks", function(t)
	local env, validator = arena({ maxRange = 30 })
	local origin, direction = aimAt(18)
	local claim = { shooter = "s", target = "t", time = 0.95, origin = origin, direction = direction }
	local far, reason, detail = validator:check(claim :: any)
	t.eq({ far, reason }, { false, "out_of_range" }, "impossible hit distance")
	-- Nearest surface of the rewound target (x = 19 at t = 0.95): |(19, 0, -50)| - radius 1.
	t.near(detail.distance :: number, math.sqrt(19 ^ 2 + 50 ^ 2) - 1, 1e-9)
	t.near(detail.window :: number, 0.15)
	local _, fast = arena({ fireInterval = 0.1, burst = 2 })
	local shot = { shooter = "s", target = "t", time = 0.95, origin = origin, direction = v(19, 0, -50) }
	t.ok((fast:check(shot :: any)))
	t.ok((fast:check(shot :: any)))
	t.eq(select(2, fast:check(shot :: any)), "rate_limited", "third shot inside the burst")
	t.eq(select(2, fast:check({ shooter = "s" } :: any)), "bad_claim", "malformed spam is rejected")
	local blocked = { 0 }
	local _, walls = arena({
		lineOfSight = function()
			blocked[1] += 1
			return false
		end,
	})
	t.eq(select(2, walls:check(shot :: any)), "no_line_of_sight")
	local _, broken = arena({
		lineOfSight = function()
			error("cast failed")
		end,
	})
	t.eq(select(2, broken:check(shot :: any)), "no_line_of_sight")
	local _, dead = arena({
		alive = function()
			return false
		end,
	})
	t.eq(select(2, dead:check(shot :: any)), "target_dead")
	t.ok(blocked[1] == 1)
	t.ok(has(Hitbox.validateOptions({ maxRange = -1, burst = 0, maxAngle = 200, alive = 5 }), "maxRange"))
	t.eq(#Hitbox.validateOptions({ maxRange = -1, burst = 0, maxAngle = 200, alive = 5 }), 4)
	validator:remove("t")
	t.eq(select(2, validator:check(claim :: any)), "unknown_target")
	t.ok(env.clock() == 1)
end)

return cases
