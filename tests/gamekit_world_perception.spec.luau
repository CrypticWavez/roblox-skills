-- GameKit Perception: the vision cone (range, angle, occlusion hook), hearing scaled by loudness,
-- memory decay over time, ordering by confidence, forgetting, and invalid options.
local FakeEnv = require("./fakes/FakeEnv")
local Perception = require("../packages/GameKit/Perception")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

local function v(x, y, z)
	return { x = x, y = y, z = z }
end

local OBSERVER = { pos = v(0, 0, 0), look = v(0, 0, 1) }

test("vision cone: range, angle and occlusion with reasons", function(t)
	local options = { fov = 90, sightRange = 50 }
	t.eq({ Perception.canSee(OBSERVER, v(0, 0, 20), options) }, { true, nil })
	t.eq({ Perception.canSee(OBSERVER, v(0, 0, 60), options) }, { false, "range" })
	t.eq({ Perception.canSee(OBSERVER, v(19, 0, 20), options) }, { true, nil }, "just inside 45 degrees")
	t.eq({ Perception.canSee(OBSERVER, v(20, 0, 19), options) }, { false, "angle" }, "just outside")
	t.eq({ Perception.canSee(OBSERVER, v(20, 0, 10), options) }, { false, "angle" })
	t.eq({ Perception.canSee(OBSERVER, v(0, 0, -5), options) }, { false, "angle" }, "behind")
	-- A wall at z = 10 for x in [-5, 5] blocks lines that cross it.
	local wall = table.clone(options)
	wall.occluded = function(from, to)
		if (from.z - 10) * (to.z - 10) >= 0 then
			return false
		end
		local f = (10 - from.z) / (to.z - from.z)
		local x = from.x + (to.x - from.x) * f
		return math.abs(x) <= 5
	end
	t.eq({ Perception.canSee(OBSERVER, v(0, 0, 20), wall) }, { false, "occluded" })
	t.eq({ Perception.canSee(OBSERVER, v(15, 0, 20), wall) }, { true, nil }, "line passes beside the wall")
	t.eq({ Perception.canSee(OBSERVER, v(0, 0, 8), wall) }, { true, nil }, "in front of the wall")
	t.eq({ Perception.canSee(OBSERVER, v(0, 0, 200), { fov = 360, sightRange = 300 }) }, { true, nil })
end)

test("hearing scales with loudness", function(t)
	local options = { hearingRange = 30 }
	t.ok(Perception.canHear(v(0, 0, 0), v(0, 0, 25), 1, options))
	t.ok(not Perception.canHear(v(0, 0, 0), v(0, 0, 35), 1, options))
	t.ok(Perception.canHear(v(0, 0, 0), v(0, 0, 35), 1.5, options))
	t.ok(not Perception.canHear(v(0, 0, 0), v(0, 0, 25), 0.5, options))
end)

test("memory: last known position, linear decay, forgetting", function(t)
	local env = FakeEnv.new()
	local p = Perception.new({ fov = 90, sightRange = 50, hearingRange = 30, memory = 4 }, env)
	local seen = p:sense(OBSERVER, { { id = "a", pos = v(0, 0, 10) }, { id = "b", pos = v(0, 0, -10) } })
	t.eq(#seen, 1, "b is behind")
	t.eq(seen[1].id, "a")
	t.eq(seen[1].confidence, 1)
	t.eq(seen[1].seen, true)
	env:advance(1)
	t.ok(p:hear(v(0, 0, 0), { id = "b", pos = v(0, 0, -10), loudness = 1 }))
	env:advance(1)
	-- a moved out of sight: memory keeps its last position and fades.
	local known = p:sense(OBSERVER, { { id = "a", pos = v(0, 0, -20) } })
	t.eq(known[1].id, "b", "heard 1 s ago: more confident")
	t.near(known[1].confidence, 0.75)
	t.eq(known[2].id, "a")
	t.near(known[2].confidence, 0.5)
	t.eq(known[2].pos, v(0, 0, 10), "last known position")
	t.eq(known[2].seen, false)
	t.eq(p:best().id, "b")
	env:advance(3)
	t.eq(#p:known(), 0, "both forgotten after 4 s")
	p:sense(OBSERVER, { { id = "c", pos = v(1, 0, 5) } })
	p:forget("c")
	t.eq(p:known(), {})
	t.eq(p:hear(v(0, 0, 0), { id = "far", pos = v(0, 0, 100) }), false)
end)

test("invalid options list problems", function(t)
	t.eq(Perception.validate({ fov = 0, sightRange = -1, memory = math.huge, occluded = 5 :: any }), {
		"fov must be in (0, 360] degrees",
		"sightRange must be a finite number > 0",
		"memory must be a finite number > 0",
		"occluded must be a function",
	})
	t.throws(function()
		Perception.new(nil, {})
	end, "env.clock required")
end)

return cases
