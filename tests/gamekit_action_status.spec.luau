--!strict
-- G2 StatusEffects (stacking rules, ticks, immunity, multipliers, serialise) and Knockback
-- (impulse maths, falloff, ragdoll requests as events, immunity and combo limits).
local Knockback = require("../packages/GameKit/Knockback")
local StatusEffects = require("../packages/GameKit/StatusEffects")
local FakeEnv = require("./fakes/FakeEnv")

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

local BOOK = StatusEffects.define({
	{ id = "slow_a", duration = 3, maxStacks = 3, tags = { "slow" }, modifiers = { speed = 0.5 } },
	{ id = "haste_a", duration = 5, tags = { "haste" }, modifiers = { speed = 1.2 } },
	{ id = "burn_a", duration = 3.5, tickInterval = 1, tags = { "dot" }, stacking = "refresh" },
	{ id = "bleed_a", duration = 3, stacking = "stack", maxStacks = 5, tickInterval = 1, tags = { "dot" } },
	{ id = "guard_a", duration = 2, stacking = "extend", maxDuration = 5 },
	{ id = "mark_a", duration = 4, stacking = "ignore" },
	{ id = "form_a", duration = 4, stacking = "replace", maxStacks = 3 },
	{ id = "stun_a", duration = 1, tags = { "stun" }, immunityAfter = 1.5, dispellable = false },
	{ id = "aura_a", duration = 0, tags = { "aura" }, modifiers = { damage_taken = 0.9 } },
})

-- ---------------------------------------------------------------- StatusEffects

test("StatusEffects.validate lists definition problems", function(t)
	local problems = StatusEffects.validate({
		{ id = "Bad", duration = 1 },
		{ id = "a", duration = -1, stacking = "pile", maxStacks = 0, tickInterval = 0 },
		{ id = "b", duration = 1, modifiers = { speed = -1 }, tags = { "OK?" }, immunityAfter = NAN },
		{ id = "b", duration = 1, maxDuration = 0, dispellable = "no" },
	})
	for _, needle in
		{
			"id must be a label",
			"duration must be",
			"stacking must be",
			"maxStacks",
			"tickInterval",
			"modifier",
			"is not a label",
			"immunityAfter",
			"duplicate id b",
			"maxDuration",
			"dispellable",
		}
	do
		t.ok(has(problems, needle), needle .. " missing from " .. table.concat(problems, " | "))
	end
	t.eq(StatusEffects.validate(nil), { "effects must be a list" })
	t.throws(function()
		StatusEffects.define({ { id = "x" } } :: any)
	end)
end)

test("StatusEffects: refresh restarts the timer and caps stacks", function(t)
	local env = FakeEnv.new()
	local fx = StatusEffects.new(BOOK, nil, env)
	t.eq({ fx:apply("slow_a") }, { true, nil })
	env:advance(2)
	fx:apply("slow_a", { stacks = 5 })
	t.eq(fx:stacks("slow_a"), 3)
	t.eq(fx:remaining("slow_a"), 3)
	t.eq(fx:multiplier("speed"), 0.125)
	fx:apply("haste_a")
	t.eq(fx:multiplier("speed"), 0.125 * 1.2)
	env:advance(3)
	local events = fx:step()
	t.eq(#events, 1)
	t.eq({ events[1].kind, events[1].id }, { "expired", "slow_a" })
	t.eq(fx:multiplier("speed"), 1.2)
	t.eq({ fx:apply("nope") }, { false, "unknown_effect" })
	t.eq({ fx:apply("slow_a", { stacks = 0 }) }, { false, "bad_input" })
	t.eq({ fx:apply("slow_a", { duration = NAN }) }, { false, "bad_input" })
end)

test("StatusEffects: extend respects maxDuration, ignore keeps the first, replace resets", function(t)
	local env = FakeEnv.new()
	local fx = StatusEffects.new(BOOK, nil, env)
	fx:apply("guard_a")
	fx:apply("guard_a")
	t.eq(fx:remaining("guard_a"), 4)
	fx:apply("guard_a")
	t.eq(fx:remaining("guard_a"), 5, "capped at maxDuration from now")
	fx:apply("mark_a", { source = "1" })
	t.eq({ fx:apply("mark_a", { source = "2" }) }, { false, "ignored" })
	fx:apply("form_a", { stacks = 3 })
	env:advance(1)
	fx:apply("form_a", { stacks = 1, magnitude = 2 })
	t.eq(fx:stacks("form_a"), 1)
	t.eq(fx:remaining("form_a"), 4)
end)

test("StatusEffects: stack mode keeps an expiry per stack", function(t)
	local env = FakeEnv.new()
	local fx = StatusEffects.new(BOOK, nil, env)
	fx:apply("bleed_a")
	env:advance(1)
	fx:apply("bleed_a", { stacks = 2 })
	t.eq(fx:stacks("bleed_a"), 3)
	env:advance(2)
	fx:step()
	t.eq(fx:stacks("bleed_a"), 2, "the first stack ended at t = 3")
	env:advance(1)
	fx:step()
	t.ok(not fx:has("bleed_a"))
	for _ = 1, 7 do
		fx:apply("bleed_a")
	end
	t.eq(fx:stacks("bleed_a"), 5)
end)

test("StatusEffects: ticks are step-size independent and refresh spam cannot reset them", function(t)
	local function ticks(stepSize: number, refreshEvery: number?): { number }
		local env = FakeEnv.new()
		local fx = StatusEffects.new(BOOK, nil, env)
		fx:apply("burn_a")
		local times = {}
		local elapsed, sinceRefresh = 0, 0
		while elapsed < 6 do
			env:advance(stepSize)
			elapsed += stepSize
			sinceRefresh += stepSize
			if refreshEvery and sinceRefresh >= refreshEvery and elapsed < 2.5 then
				sinceRefresh = 0
				fx:apply("burn_a")
			end
			for _, event in fx:step() do
				if event.kind == "tick" then
					table.insert(times, event.t)
				end
			end
		end
		return times
	end
	t.eq(ticks(0.25), { 1, 2, 3 })
	t.eq(ticks(4), { 1, 2, 3 }, "one big step catches up the same ticks")
	t.eq(ticks(0.25, 0.5), { 1, 2, 3, 4, 5 }, "refreshing extends the burn but keeps one tick per second")
end)

test("StatusEffects: a huge step skips a backlog beyond the per-step tick cap", function(t)
	local env = FakeEnv.new()
	local book = StatusEffects.define({ { id = "aura_tick", duration = 0, tickInterval = 0.01 } })
	local fx = StatusEffects.new(book, nil, env)
	fx:apply("aura_tick")
	env:advance(100)
	local events = fx:step()
	t.eq(#events, StatusEffects.MAX_TICKS_PER_STEP)
	env:advance(0.01)
	t.eq(#fx:step(), 1)
	t.eq(fx:remaining("aura_tick"), math.huge)
end)

test("StatusEffects: immunity by tag, by id and after expiry (anti stun-lock)", function(t)
	local env = FakeEnv.new()
	local fx = StatusEffects.new(BOOK, nil, env)
	fx:grantImmunity("tag:stun", 2)
	t.eq({ fx:apply("stun_a") }, { false, "immune" })
	t.ok(fx:isImmune("stun_a"))
	env:advance(2)
	t.ok((fx:apply("stun_a")))
	t.eq(fx:dispel(), 0, "stun is not dispellable")
	env:advance(1)
	fx:step()
	t.eq({ fx:apply("stun_a") }, { false, "immune" }, "immunityAfter blocks a chain stun")
	env:advance(1.5)
	fx:step()
	t.ok((fx:apply("stun_a")))
	t.ok(fx:hasTag("stun"))
	t.eq(fx:removeTag("stun"), 1)
	t.eq({ fx:apply("stun_a") }, { true, nil }, "removal is not expiry: no immunity")
end)

test("StatusEffects: capacity, permanent effects, dispel and clear", function(t)
	local env = FakeEnv.new()
	local fx = StatusEffects.new(BOOK, { limit = 2 }, env)
	fx:apply("aura_a")
	fx:apply("slow_a")
	t.eq({ fx:apply("haste_a") }, { false, "full" })
	t.eq(fx:multiplier("damage_taken"), 0.9)
	env:advance(1000)
	fx:step()
	t.ok(fx:has("aura_a"), "duration 0 lasts until removed")
	t.eq(fx:dispel("aura"), 1)
	t.eq(#fx:list(), 0)
	fx:apply("slow_a")
	fx:clear()
	t.ok(not fx:has("slow_a"))
end)

test("StatusEffects: serialise and restore round-trip; bad text is refused", function(t)
	local env = FakeEnv.new()
	local fx = StatusEffects.new(BOOK, nil, env)
	fx:apply("slow_a", { stacks = 2 })
	fx:apply("bleed_a")
	env:advance(0.5)
	fx:apply("bleed_a")
	fx:apply("aura_a")
	fx:grantImmunity("tag:stun", 1.25)
	local text = fx:serialize()
	t.eq(text, "se/1;aura_a=p;bleed_a=2.500,3.000;slow_a=2.500,2.500;!tag:stun=1.250")
	local restored = StatusEffects.restore(BOOK, text, nil, env) :: any
	t.ok(restored ~= nil)
	t.eq(restored:serialize(), text)
	t.eq(restored:stacks("bleed_a"), 2)
	t.eq({ restored:apply("stun_a") }, { false, "immune" })
	for _, bad in { 5, "se/2;x=1", "se/1;slow_a=abc", "se/1;slow_a=1,1,1,1", "se/1;!tag:x=p", "se/1;??" } do
		t.eq(select(2, StatusEffects.restore(BOOK, bad, nil, env)), "bad_format", tostring(bad))
	end
	t.eq(select(2, StatusEffects.restore(BOOK, "se/1;ghost_a=1", nil, env)), "unknown_effect")
end)

-- ---------------------------------------------------------------- Knockback

test("Knockback.compute: horizontal direction plus lift, falloff, resistance and caps", function(t)
	local result = Knockback.compute({ origin = v(0, 0, 0), target = v(10, 5, 0), force = 50, upward = 20 })
	t.eq(result.velocity, v(50, 20, 0))
	t.eq(result.strength, 1)
	local free =
		Knockback.compute({ origin = v(0, 0, 0), target = v(3, 4, 0), force = 10, horizontal = false })
	t.near(free.velocity.y, 8)
	local linear = Knockback.compute({ origin = v(0, 0, 0), target = v(5, 0, 0), force = 100, radius = 10 })
	t.eq(linear.velocity, v(50, 0, 0))
	local quad = Knockback.compute({
		origin = v(0, 0, 0),
		target = v(5, 0, 0),
		force = 100,
		radius = 10,
		falloff = "quadratic",
	})
	t.eq(quad.velocity, v(25, 0, 0))
	local flat = Knockback.compute({
		origin = v(0, 0, 0),
		target = v(5, 0, 0),
		force = 100,
		radius = 10,
		falloff = "none",
	})
	t.eq(flat.speed, 100)
	local outside = Knockback.compute({ origin = v(0, 0, 0), target = v(12, 0, 0), force = 100, radius = 10 })
	t.eq(outside.speed, 0)
	local resisted =
		Knockback.compute({ origin = v(0, 0, 0), target = v(1, 0, 0), force = 40, resistance = 0.25 })
	t.eq(resisted.speed, 30)
	local immune = Knockback.compute({ origin = v(0, 0, 0), target = v(1, 0, 0), force = 40, resistance = 3 })
	t.eq(immune.speed, 0)
	local capped =
		Knockback.compute({ origin = v(0, 0, 0), target = v(1, 0, 0), force = 300, maxSpeed = 120 })
	t.eq(capped.velocity, v(120, 0, 0))
	local onTop = Knockback.compute({ origin = v(2, 0, 2), target = v(2, 0, 2), force = 50, upward = 10 })
	t.eq(onTop.velocity, v(0, 10, 0), "no direction: lift only, no arbitrary sideways push")
	t.eq(Knockback.impulse(result, 2), v(100, 40, 0))
end)

test("Knockback.compute raises on bad parameters", function(t)
	t.throws(function()
		Knockback.compute({ origin = v(0, 0, 0), target = v(1, 0, 0), force = NAN })
	end)
	t.throws(function()
		Knockback.compute({ origin = v(NAN, 0, 0), target = v(1, 0, 0), force = 1 })
	end)
	t.throws(function()
		Knockback.compute({ origin = v(0, 0, 0), target = v(1, 0, 0), force = 1e9 })
	end)
	local problems = Knockback.validate({ force = 1, radius = 0, falloff = "cubic", maxSpeed = -1 })
	t.eq(#problems, 5)
	t.throws(function()
		Knockback.impulse({ velocity = v(1, 0, 0) } :: any, -1)
	end)
end)

test("Knockback tracker: ragdoll requests, post-ragdoll immunity and combo limits", function(t)
	local env = FakeEnv.new()
	local kb = Knockback.new({
		ragdollThreshold = 80,
		ragdollDuration = function(speed)
			return speed / 100
		end,
		immunity = 0.5,
		comboWindow = 2,
		comboLimit = 3,
	}, env)
	local requests = {}
	kb.ragdollRequested:Connect(function(target, request)
		table.insert(requests, { target = target, duration = request.duration })
	end)
	local light = { origin = v(0, 0, 0), target = v(1, 0, 0), force = 30 }
	local heavy = { origin = v(0, 0, 0), target = v(1, 0, 0), force = 90 }
	for _ = 1, 3 do
		t.ok((kb:apply("a", light)))
	end
	t.eq(select(2, kb:apply("a", light)), "combo_limit", "a fourth hit inside the 2 s window ends the juggle")
	env:advance(2)
	local result = kb:apply("a", heavy) :: any
	t.ok(result.ragdoll)
	t.eq(result.ragdollDuration, 0.9)
	t.eq(requests, { { target = "a", duration = 0.9 } })
	t.eq(select(2, kb:apply("a", light)), "immune")
	t.ok(kb:immune("a"))
	env:advance(1.4)
	t.ok((kb:apply("a", light)), "immunity ends after ragdoll + 0.5 s")
	t.eq(
		select(2, kb:apply("b", { origin = v(0, 0, 0), target = v(20, 0, 0), force = 10, radius = 5 })),
		"no_effect"
	)
	t.eq(
		select(2, kb:apply("b", { origin = v(NAN, 0, 0), target = v(1, 0, 0), force = 1 } :: any)),
		"bad_params"
	)
	kb:forget("a")
	t.ok(not kb:immune("a"))
	t.throws(function()
		Knockback.new({ comboLimit = 0, immunityScale = 2, ragdollDuration = -1 }, env)
	end)
end)

test("Knockback tracker: immunityScale softens instead of blocking", function(t)
	local env = FakeEnv.new()
	local kb = Knockback.new({ ragdollThreshold = 50, immunityScale = 0.5 }, env)
	local hit = { origin = v(0, 0, 0), target = v(0, 0, 1), force = 60 }
	t.ok((kb:apply(7, hit) :: any).ragdoll)
	local softened = kb:apply(7, hit) :: any
	t.eq(softened.speed, 30)
	t.ok(not softened.ragdoll, "a softened hit under the threshold does not ragdoll again")
end)

return cases
