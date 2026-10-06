--!strict
-- G2 Interact: target checks, prompt distance and line of sight, server-timed holds (too quick,
-- never held, slack), per-player rate limits, own and shared cooldowns, exclusive use, touch
-- targets (kill parts, hazards with re-arm, lap gates) and forged requests from far away.
local FakeEnv = require("./fakes/FakeEnv")
local Interact = require("../packages/GameKit/Interact")

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

local TARGETS = {
	{ id = "use_a", position = v(0, 0, 0) },
	{ id = "hold_a", position = v(20, 0, 0), holdDuration = 1, cooldown = 5 },
	{ id = "station_a", position = v(40, 0, 0), exclusive = true, holdDuration = 0.5, sharedCooldown = 3 },
	{ id = "open_a", position = v(60, 0, 0), lineOfSight = false },
	{ id = "kill_a", kind = "touch", position = v(0, -10, 0), radius = 6, touch = { kill = true } },
	{
		id = "hazard_a",
		kind = "touch",
		position = v(10, -10, 0),
		touch = { damage = 15, interval = 1, damageKind = "hazard_a" },
	},
	{ id = "gate_1", kind = "touch", position = v(100, 0, 0), radius = 10, gate = { order = 1 } },
	{
		id = "gate_2",
		kind = "touch",
		position = v(200, 0, 0),
		radius = 10,
		gate = { order = 2, finish = true },
	},
}

local function server(options: any?)
	local env = FakeEnv.new()
	return Interact.server(Interact.define(TARGETS :: any), options, env), env
end

test("validate: every problem is listed; define raises them joined", function(t)
	local problems = Interact.validate({
		{ id = "x", kind = "door" },
		{ id = "x", maxDistance = 0, holdDuration = 61, cooldown = -1, exclusive = 1 },
		{ id = "t", kind = "touch" },
		{ id = "u", kind = "touch", touch = { damage = 0, kill = "yes" }, holdDuration = 1 },
		{ id = "p", touch = { kill = true }, gate = { order = 0 } },
		{ id = "Bad Id", position = v(NAN, 0, 0) },
	})
	for _, needle in
		{
			"targets[1].kind",
			'targets[2].id "x" is duplicated',
			"targets[2].maxDistance",
			"targets[2].holdDuration",
			"targets[2].cooldown",
			"targets[2].exclusive",
			"targets[3] (touch) needs touch, gate or data",
			"targets[4].touch.damage",
			"targets[4].touch.kill",
			"targets[4].holdDuration is only for prompts",
			"targets[5].touch is only for kind touch",
			"targets[5].gate is only for kind touch",
			"targets[5].gate.order",
			"targets[6].id must be a label",
			"targets[6].position",
		}
	do
		t.ok(has(problems, needle), needle)
	end
	t.eq(#Interact.validate(TARGETS), 0)
	t.ok(not pcall(Interact.define, { { id = "x", kind = "door" } } :: any))
end)

test("prompt: distance with slack, bad input, unknown targets, wrong kind and disabled", function(t)
	local s = server()
	local ok, reason, event = s:finish("p1", "use_a", v(11.9, 0, 0))
	t.ok(ok, reason)
	t.eq(event.kind, "triggered")
	t.eq(event.target, "use_a")
	t.eq(select(2, s:finish("p1", "use_a", v(12.1, 0, 0))), "too_far")
	t.eq(select(2, s:finish("p1", "use_a", v(NAN, 0, 0))), "bad_input")
	t.eq(select(2, s:finish("p1", "nope", v(0, 0, 0))), "unknown_target")
	t.eq(select(2, s:finish("p1", 5 :: any, v(0, 0, 0))), "unknown_target")
	t.eq(select(2, s:finish("p1", "kill_a", v(0, -10, 0))), "wrong_kind")
	t.eq(select(2, s:finish(nil, "use_a", v(0, 0, 0))), "bad_input")
	s:setEnabled("use_a", false)
	t.eq(select(2, s:finish("p1", "use_a", v(0, 0, 0))), "disabled")
	s:setEnabled("use_a", true)
	t.ok(s:finish("p1", "use_a", v(0, 0, 0)))
end)

test("hold: the server times the hold; short, missing and slack holds", function(t)
	local s, env = server()
	t.eq(select(2, s:finish("p1", "hold_a", v(20, 0, 0))), "not_held", "Triggered without a hold")
	t.ok(s:begin("p1", "hold_a", v(20, 0, 0)))
	env:advance(0.5)
	t.eq(select(2, s:finish("p1", "hold_a", v(20, 0, 0))), "too_quick")
	t.eq(select(2, s:finish("p1", "hold_a", v(20, 0, 0))), "not_held", "a refused hold is cleared")
	t.ok(s:begin("p1", "hold_a", v(20, 0, 0)))
	env:advance(0.95)
	t.ok(s:finish("p1", "hold_a", v(20, 0, 0)), "0.1 s of slack for latency")
	t.eq(select(2, s:begin("p1", "hold_a", v(20, 0, 0))), "cooldown")
	t.near(s:remaining("p1", "hold_a"), 5, 1e-9)
	t.ok(s:begin("p2", "hold_a", v(20, 0, 0)), "cooldowns are per player")
	-- Walking away during the hold fails the final distance check.
	env:advance(1)
	t.eq(select(2, s:finish("p2", "hold_a", v(40, 0, 0))), "too_far")
end)

test("line of sight: the hook refuses blocked prompts; lineOfSight = false skips it", function(t)
	local s = server({
		lineOfSight = function(_from: any, _to: any, _id: string)
			return false
		end,
	})
	t.eq(select(2, s:finish("p1", "use_a", v(1, 0, 0))), "no_line_of_sight")
	t.ok(s:finish("p1", "open_a", v(61, 0, 0)))
end)

test("rate limit: a burst over the per-player budget is refused and refills over time", function(t)
	local s, env = server({ rate = 4, window = 1 })
	for _ = 1, 4 do
		t.ok(s:finish("spam", "use_a", v(0, 0, 0)))
	end
	t.eq(select(2, s:finish("spam", "use_a", v(0, 0, 0))), "rate_limited")
	t.ok(s:finish("calm", "use_a", v(0, 0, 0)), "other players are unaffected")
	env:advance(0.25)
	t.ok(s:finish("spam", "use_a", v(0, 0, 0)), "one token back after window / rate")
	t.eq(select(2, s:finish("spam", "use_a", v(0, 0, 0))), "rate_limited")
	local stats = s:stats()
	t.eq(stats.rate_limited, 2)
	t.eq(stats.accepted, 6)
end)

test("exclusive and shared cooldowns: one user at a time, one use for everyone", function(t)
	local s, env = server()
	t.ok(s:begin("p1", "station_a", v(40, 0, 0)))
	t.eq(select(2, s:begin("p2", "station_a", v(40, 0, 0))), "busy")
	s:cancel("p1", "station_a")
	t.ok(s:begin("p2", "station_a", v(40, 0, 0)))
	env:advance(0.5)
	t.ok(s:finish("p2", "station_a", v(40, 0, 0)))
	t.eq(select(2, s:begin("p1", "station_a", v(40, 0, 0))), "cooldown", "shared cooldown")
	env:advance(3)
	t.ok(s:begin("p1", "station_a", v(40, 0, 0)))
	s:forget("p1")
	t.ok(s:begin("p3", "station_a", v(40, 0, 0)), "a leaving player frees the station")
	s:setEnabled("station_a", false)
	t.eq(select(2, s:begin("p3", "station_a", v(40, 0, 0))), "disabled")
end)

test("touch: kill parts, hazards that re-arm, gates; forged touches from afar are refused", function(t)
	local s, env = server()
	local ok, _, kill = s:touch("p1", "kill_a", v(3, -10, 0))
	t.ok(ok)
	t.eq(kill.kind, "kill")
	t.eq(kill.damageKind, "kill")
	t.eq(select(2, s:touch("p1", "kill_a", v(0, 50, 0))), "too_far", "a forged touch from far away")
	local _, _, hazard = s:touch("p1", "hazard_a", v(10, -10, 0))
	t.eq(hazard.kind, "hazard")
	t.eq(hazard.damage, 15)
	t.eq(hazard.damageKind, "hazard_a")
	t.eq(select(2, s:touch("p1", "hazard_a", v(10, -10, 0))), "cooldown", "re-arms after interval")
	env:advance(1)
	t.ok(s:touch("p1", "hazard_a", v(10, -10, 0)))
	local _, _, gate = s:touch("p1", "gate_2", v(205, 0, 0))
	t.eq(gate.kind, "gate")
	t.eq(gate.order, 2)
	t.eq(gate.finish, true)
	t.ok(s:touch("p1", "gate_2", v(205, 0, 0)), "gates re-arm at once (interval 0)")
	t.eq(select(2, s:touch("p1", "use_a", v(0, 0, 0))), "wrong_kind")
	t.eq(select(2, s:begin("p1", "gate_1", v(100, 0, 0))), "wrong_kind")
	-- Moving targets resolve through the locate hook.
	local moving = Interact.server(Interact.define(TARGETS :: any), {
		locate = function(id: string)
			return if id == "kill_a" then v(500, 0, 0) else nil
		end,
	}, FakeEnv.new())
	t.eq(select(2, moving:touch("p1", "kill_a", v(0, -10, 0))), "too_far")
	t.ok(moving:touch("p1", "kill_a", v(502, 0, 0)))
end)

return cases
