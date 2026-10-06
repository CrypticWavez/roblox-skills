--!strict
-- G2 Movement: definition checks, jumps (coyote time, air jumps, buffer), dash (charges, air
-- dashes, exact end), slide (speed gate, friction, jump cancel, falling off), ledge rules
-- (height band, reach, facing), sprint stamina with exact fractional drain and an exhaustion
-- latch, and the server travel checks (teleport, fly, rubber-band, granted teleports).
local Cooldowns = require("../packages/GameKit/Cooldowns")
local FakeEnv = require("./fakes/FakeEnv")
local Movement = require("../packages/GameKit/Movement")
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

local FULL = {
	sprint = { multiplier = 1.5, pool = "stamina", drain = 10, minToStart = 20 },
	jump = { airJumps = 1 },
	dash = { distance = 12, duration = 0.2, cooldown = 1, charges = 2, airDashes = 1 },
	slide = { speed = 30, duration = 1, minSpeed = 20, friction = 10, cooldown = 0.5 },
	ledge = { minHeight = 2, maxHeight = 8, maxDistance = 3, maxAngle = 45, climbTime = 0.5 },
}

local function rig(def: any?)
	local env = FakeEnv.new()
	local vitals =
		Vitals.new(Vitals.define({ pools = { health = { max = 100 }, stamina = { max = 100 } } }), nil, env)
	local cooldowns = Cooldowns.new(env)
	local controller =
		Movement.new(Movement.define(def or FULL), { vitals = vitals, cooldowns = cooldowns }, env)
	return controller, env, vitals
end

local function kinds(output: any): string
	local out = {}
	for _, event in output.events do
		table.insert(out, event.kind)
	end
	return table.concat(out, ",")
end

test("validate: problems listed, engine defaults filled, define raises", function(t)
	local problems = Movement.validate({
		walkSpeed = 0,
		sprint = { multiplier = 1, drain = 5 },
		jump = { airJumps = 11, coyoteTime = 2 },
		dash = { distance = 500, duration = 0.1, charges = 0 },
		slide = { speed = 10, duration = 9, jumpCancel = 1 },
		ledge = { minHeight = 5, maxHeight = 4, maxDistance = 0, climbTime = 0 },
	})
	for _, needle in
		{
			"walkSpeed",
			"sprint.multiplier",
			"sprint.drain and minToStart need sprint.pool",
			"jump.airJumps",
			"jump.coyoteTime",
			"dash.charges",
			"dash speed",
			"slide.duration",
			"slide.jumpCancel",
			"ledge.maxHeight",
			"ledge.maxDistance",
			"ledge.climbTime",
		}
	do
		t.ok(has(problems, needle), needle)
	end
	t.eq(Movement.validate(nil)[1], "definition must be a table")
	local spec = Movement.define({})
	t.eq(spec.walkSpeed, 16)
	t.near(spec.jumpVelocity, math.sqrt(2 * 196.2 * 7.2), 1e-12)
	t.eq(spec.jump.airJumps, 0)
	t.ok(not pcall(Movement.define, { walkSpeed = NAN } :: any))
	local limits = Movement.limits(Movement.define(FULL :: any))
	t.eq(limits.horizontal, 60, "the dash (12 / 0.2) is the fastest move")
	t.near(limits.rise, math.max(math.sqrt(2 * 196.2 * 7.2), 8 / 0.5), 1e-12)
	t.throws(function()
		Movement.new(Movement.define(FULL :: any), nil, FakeEnv.new())
	end, "costed or cooled-down moves need their services")
end)

test("jump: ground jump, coyote time, one air jump, then a buffered jump on landing", function(t)
	local c, env = rig()
	local ok = c:request("jump")
	t.ok(ok)
	local out = c:step()
	t.eq(kinds(out), "jump")
	t.near(out.events[1].velocity, c.spec.jumpVelocity, 1e-12)
	t.eq(c:mode(), "air")
	c:setGrounded(false)
	env:advance(0.3)
	c:step()
	t.ok(c:request("jump"), "the air jump")
	t.eq(c:step().events[1].air, true)
	local buffered, reason = c:request("jump")
	t.ok(buffered)
	t.eq(reason, "buffered")
	env:advance(0.08)
	c:setGrounded(true)
	t.eq(kinds(c:step()), "land,jump", "landing inside the buffer jumps at once")
	t.eq(c:mode(), "air")
	-- Outside the buffer the press is forgotten.
	c:setGrounded(false)
	env:advance(0.2)
	c:step()
	c:request("jump") -- air jump (restored on landing)
	c:step()
	c:request("jump") -- buffered
	env:advance(0.2)
	c:setGrounded(true)
	t.eq(kinds(c:step()), "land")
	t.eq(c:mode(), "ground")

	-- Coyote time: a ground jump shortly after walking off an edge, not after.
	c:setGrounded(false)
	c:step()
	env:advance(0.05)
	t.ok(c:request("jump"))
	t.eq(c:step().events[1].air, false, "coyote jump counts as a ground jump")
	local late, env2 = rig({ jump = { airJumps = 0, buffer = 0 } })
	late:setGrounded(false)
	late:step()
	env2:advance(0.15)
	local refused, why = late:request("jump")
	t.ok(not refused)
	t.eq(why, "no_jumps")
end)

test("dash: exact speed and end time, charges, one air dash per airtime, bad directions", function(t)
	local c, env = rig()
	c:setInput(v(0, 0, 1), false)
	t.eq(select(2, c:request("dash", v(0, 0, 0))), "bad_direction")
	t.eq(select(2, c:request("dash", v(NAN, 0, 1))), "bad_direction")
	t.ok(c:request("dash"))
	local out = c:step()
	t.eq(kinds(out), "dash_start")
	t.near(out.velocity.z, 60, 1e-12)
	t.eq(out.walkSpeed, 60)
	t.eq(select(2, c:request("dash")), "busy")
	env:advance(0.25)
	local ended = c:step()
	t.eq(kinds(ended), "dash_end")
	t.eq(ended.events[1].t, 0.2)
	t.eq(ended.velocity, nil)
	t.eq(c:mode(), "ground")
	t.ok(c:request("dash", v(1, 0, 0)), "second charge")
	env:advance(0.25)
	c:step()
	t.eq(select(2, c:request("dash")), "cooldown")
	-- Airborne: one dash, restored on landing.
	env:advance(2)
	c:setGrounded(false)
	c:step()
	t.ok(c:request("dash"))
	env:advance(0.25)
	c:step()
	t.eq(c:mode(), "air")
	env:advance(1)
	t.eq(select(2, c:request("dash")), "no_air_dash")
	c:setGrounded(true)
	c:step()
	t.ok(c:request("dash"))
	t.eq(select(2, c:request("fly")), "unknown_action")
end)

test("slide: needs speed, decays with friction, jump-cancels and ends when falling", function(t)
	local c, env = rig()
	c:setInput(v(1, 0, 0), false)
	c:step()
	t.eq(select(2, c:request("slide")), "too_slow", "walking (16) is under minSpeed 20")
	c:setInput(v(1, 0, 0), true)
	c:step()
	t.ok(c:sprinting())
	t.ok(c:request("slide"))
	t.near(c:step().velocity.x, 30, 1e-12)
	env:advance(0.5)
	local mid = c:step()
	t.near(mid.velocity.x, 25, 1e-9, "30 - 10 * 0.5")
	env:advance(0.6)
	local ended = c:step()
	t.ok(string.find(kinds(ended), "slide_end", 1, true) ~= nil)
	t.eq(c:mode(), "ground")
	-- Jump cancel.
	env:advance(1)
	c:step()
	t.ok(c:request("slide"))
	c:step()
	t.ok(c:request("jump"))
	t.eq(kinds(c:step()), "slide_end,jump")
	-- Falling off an edge ends the slide.
	c:setGrounded(true)
	c:step()
	env:advance(1)
	c:step()
	t.ok(c:request("slide"))
	c:step()
	c:setGrounded(false)
	env:advance(0.1)
	local fell = c:step()
	t.eq(fell.events[1].reason, "fell")
	t.eq(c:mode(), "air")
	t.eq(select(2, c:request("slide")), "busy")
end)

test("ledge: height band, reach and facing; the climb ends on time and restores air jumps", function(t)
	local c, env = rig()
	local wall = v(0, 0, -1) -- the wall faces -z, so moving +z goes into it
	c:setInput(v(0, 0, 1), false)
	t.eq(select(2, c:request("ledge", { height = 1, distance = 1, normal = wall })), "too_low")
	t.eq(select(2, c:request("ledge", { height = 9, distance = 1, normal = wall })), "too_high")
	t.eq(select(2, c:request("ledge", { height = 5, distance = 4, normal = wall })), "too_far")
	t.eq(select(2, c:request("ledge", { height = NAN, distance = 1, normal = wall })), "bad_probe")
	c:setInput(v(1, 0, 1), false)
	t.ok(c:request("ledge", { height = 5, distance = 1, normal = wall }), "45 degrees is inside maxAngle")
	c:reset()
	c:setInput(v(1, 0, 0.5), false)
	t.eq(select(2, c:request("ledge", { height = 5, distance = 1, normal = wall })), "not_facing")
	c:setInput(v(0, 0, -1), false)
	t.eq(
		select(2, c:request("ledge", { height = 5, distance = 1, normal = wall })),
		"not_facing",
		"moving away"
	)
	c:setInput(v(0, 0, 1), false)
	c:setGrounded(false)
	c:step()
	c:request("jump") -- coyote
	c:step()
	c:request("jump") -- air jump used
	c:step()
	t.ok(c:request("ledge", { height = 5, distance = 1, normal = wall }))
	t.eq(c:mode(), "climb")
	t.eq(select(2, c:request("dash")), "busy")
	env:advance(0.6)
	c:setGrounded(true)
	local out = c:step()
	t.eq(kinds(out), "climb_start,climb_end,land")
	t.eq(out.events[2].t, 0.5)
	t.eq(c:mode(), "ground")
	t.eq(c:serialize(), "fsm/1:move:ground")
end)

test("sprint: stamina drains exactly at any step rate and exhaustion latches until minToStart", function(t)
	local c, env, vitals = rig()
	c:setInput(v(1, 0, 0), true)
	t.eq(kinds(c:step()), "sprint_start")
	for _ = 1, 60 do
		env:advance(1 / 60)
		c:step()
	end
	t.eq(select(1, vitals:get("stamina")), 90, "10 per second, not 60 rounded-up steps")
	t.eq(c:step().walkSpeed, 24)
	vitals:set("stamina", 3)
	local ended = nil
	for _ = 1, 60 do
		env:advance(1 / 60)
		local out = c:step()
		if kinds(out) == "sprint_end" then
			ended = out
		end
	end
	t.ok(ended, "sprint ends when stamina runs out")
	t.eq(c:step().walkSpeed, 16)
	vitals:set("stamina", 19)
	c:step()
	t.ok(not c:sprinting(), "exhausted below minToStart")
	vitals:set("stamina", 20)
	c:step()
	t.ok(c:sprinting())
	c:setInput(v(0, 0, 0), true)
	t.eq(kinds(c:step()), "sprint_end", "standing still is not sprinting")
	c:setInput({ x = NAN, z = 1 } :: any, true)
	t.eq(c:step().walkSpeed, 16, "bad input is no input")
end)

test("travel: teleports and flying are refused; falls and granted teleports are fine", function(t)
	local env = FakeEnv.new()
	local spec = Movement.define(FULL :: any)
	local watcher = Movement.watcher(spec, nil, env)
	t.ok(watcher:observe("p", v(0, 0, 0)))
	env:advance(0.1)
	t.ok(watcher:observe("p", v(6, 0, 0)), "dash speed 60 for 0.1 s")
	env:advance(0.1)
	local ok, reason, detail = watcher:observe("p", v(60, 0, 0))
	t.ok(not ok)
	t.eq(reason, "teleport")
	t.eq(detail.resetTo.x, 6, "rubber-band to the last accepted position")
	t.eq(detail.strikes, 1)
	env:advance(0.1)
	t.eq(select(2, watcher:observe("p", v(6, 40, 0))), "fly")
	env:advance(0.1)
	t.ok(watcher:observe("p", v(6, -500, 0)), "falling is never limited")
	watcher:teleport("p", v(1000, 0, 0))
	env:advance(0.1)
	t.ok(watcher:observe("p", v(1001, 0, 0)))
	t.eq(select(2, watcher:observe("q", v(NAN, 0, 0))), "bad_input")
	watcher:forget("p")
	t.ok(watcher:observe("p", v(0, 0, 0)), "a forgotten body starts fresh")
	t.eq(select(2, Movement.checkTravel(Movement.limits(spec), v(0, 0, 0), v(1, 0, 0), -1)), "bad_input")
end)

test("determinism: the same input script gives the same outputs", function(t)
	local function run(): { string }
		local c, env = rig()
		local log = {}
		local script = {
			{ "input", v(1, 0, 0), true },
			{ "slide" },
			{ "jump" },
			{ "air" },
			{ "dash" },
			{ "jump" },
			{ "ground" },
			{ "dash", v(0, 0, -1) },
		}
		for index, op in script do
			if op[1] == "input" then
				c:setInput(op[2], op[3])
			elseif op[1] == "air" then
				c:setGrounded(false)
			elseif op[1] == "ground" then
				c:setGrounded(true)
			else
				local ok, reason = c:request(op[1], op[2])
				table.insert(log, string.format("%d %s %s %s", index, op[1], tostring(ok), tostring(reason)))
			end
			env:advance(0.13)
			local out = c:step()
			table.insert(log, string.format("%s %.6f %s", out.mode, out.walkSpeed, kinds(out)))
		end
		return log
	end
	t.eq(run(), run())
end)

return cases
