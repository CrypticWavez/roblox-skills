--!strict
-- G2 Zones: shape checks, exact signed distances (AABB, sphere, concave prism), hysteresis on
-- the boundary, swept crossings (no tunnelling through thin gates or kill volumes), hazard
-- ticks on the server clock, kill volumes, untrusted positions, priorities, and the course
-- (sectors, laps, finish, wrong gate, wrong way, too fast).
local FakeEnv = require("./fakes/FakeEnv")
local Zones = require("../packages/GameKit/Zones")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function v(x: number, y: number, z: number)
	return { x = x, y = y, z = z }
end

local function has(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

local function kinds(events: { any }): string
	local out = {}
	for _, event in events do
		table.insert(out, event.kind .. ":" .. event.zone)
	end
	return table.concat(out, ",")
end

local NAN = 0 / 0
-- An L-shaped (concave) footprint: the notch at x > 5, z > 5 is outside.
local L_SHAPE = {
	{ x = 0, z = 0 },
	{ x = 10, z = 0 },
	{ x = 10, z = 5 },
	{ x = 5, z = 5 },
	{ x = 5, z = 10 },
	{ x = 0, z = 10 },
}

-- ---------------------------------------------------------------- definitions

test("validate: every problem is listed; define raises them joined", function(t)
	local problems = Zones.validate({
		{ id = "Bad Id", shape = Zones.sphere(v(0, 0, 0), 1) },
		{ id = "a", shape = { kind = "cone" } },
		{ id = "a", shape = Zones.sphere(v(0, 0, 0), -1) },
		{ id = "h", shape = Zones.box(v(0, 0, 0), v(1, 1, 1)), kind = "hazard" },
		{ id = "g", shape = Zones.box(v(0, 0, 0), v(1, 1, 1)), gate = { order = 1 } },
		{
			id = "bow",
			shape = Zones.prism(
				{ { x = 0, z = 0 }, { x = 4, z = 4 }, { x = 4, z = 0 }, { x = 0, z = 4 } },
				0,
				1
			),
		},
		{ id = "flat", shape = Zones.prism({ { x = 0, z = 0 }, { x = 1, z = 1 }, { x = 2, z = 2 } }, 0, 1) },
		{ id = "inv", shape = { kind = "aabb", min = v(1, 1, 1), max = v(0, 0, 0) } },
		{ id = "slab", shape = Zones.prism(L_SHAPE, 2, 2) },
		{
			id = "hz",
			shape = Zones.sphere(v(0, 0, 0), 1),
			kind = "hazard",
			hazard = { amount = NAN, interval = 0 },
		},
		{
			id = "gt",
			shape = Zones.sphere(v(0, 0, 0), 1),
			kind = "gate",
			gate = { order = 0, direction = v(0, 0, 0) },
		},
		{ id = "k", shape = Zones.sphere(v(0, 0, 0), 1), kind = "lava" },
	})
	t.ok(has(problems, "zones[1].id must be a label"))
	t.ok(has(problems, "zones[2].shape: shape kind"))
	t.ok(has(problems, 'zones[3].id "a" is duplicated'))
	t.ok(has(problems, "zones[3].shape: sphere radius"))
	t.ok(has(problems, "zones[4].hazard { amount, interval } is required"))
	t.ok(has(problems, "zones[5].gate is only for kind gate"))
	t.ok(has(problems, "zones[6].shape: prism polygon edges"))
	t.ok(has(problems, "zones[7].shape: prism polygon has no area"))
	t.ok(has(problems, "zones[8].shape: aabb min must be <= max"))
	t.ok(has(problems, "zones[9].shape: prism needs finite minY < maxY"))
	t.ok(has(problems, "zones[10].hazard.amount") and has(problems, "zones[10].hazard.interval"))
	t.ok(has(problems, "zones[11].gate.order") and has(problems, "zones[11].gate.direction"))
	t.ok(has(problems, "zones[12].kind"))
	t.eq(Zones.validate({})[1], "zones must list 1-256 zones")
	t.eq(Zones.validate(nil)[1], "zones must be a list")
	local ok, err = pcall(Zones.define, { { id = "x", shape = { kind = "cone" } } } :: any)
	t.ok(not ok and string.find(tostring(err), "shape kind", 1, true) ~= nil)
	local set = Zones.define({
		{ id = "b", shape = Zones.sphere(v(0, 0, 0), 1) },
		{ id = "a", shape = Zones.sphere(v(0, 0, 0), 1) },
	})
	t.eq(set.ids, { "a", "b" }, "ids are sorted for a stable event order")
	t.ok(table.isfrozen(set.zones.a) and set.zones.a.hysteresis == Zones.HYSTERESIS)
end)

-- ---------------------------------------------------------------- geometry

test("distance: exact signed distances for AABB, sphere and a concave prism", function(t)
	local box = Zones.box(v(0, 0, 0), v(4, 2, 6))
	t.near(Zones.distance(box, v(0, 0, 0)), -1, 1e-12, "centre: nearest face is y")
	t.near(Zones.distance(box, v(5, 0, 0)), 3, 1e-12)
	t.near(Zones.distance(box, v(5, 4, 0)), math.sqrt(9 + 9), 1e-12, "edge region")
	t.near(Zones.distance(Zones.sphere(v(1, 1, 1), 2), v(1, 1, 5)), 2, 1e-12)
	local prism = Zones.prism(L_SHAPE, 0, 4)
	t.near(
		Zones.distance(prism, v(2, 2, 2)),
		-2,
		1e-12,
		"inside the long arm, 2 from the walls and the floor"
	)
	t.near(Zones.distance(prism, v(8, 2, 8)), 3, 1e-12, "the notch is outside, 3 from its corner edges")
	t.near(Zones.distance(prism, v(2, 7, 2)), 3, 1e-12, "above the roof")
	t.near(Zones.distance(prism, v(-3, 8, 2)), 5, 1e-12, "outside both: sqrt(3^2 + 4^2)")
	t.ok(Zones.contains(prism, v(4.9, 1, 9)))
	t.ok(not Zones.contains(prism, v(5.1, 1, 9)))
	local lo, hi = Zones.bounds(prism)
	t.eq({ lo.x, lo.y, lo.z, hi.x, hi.y, hi.z }, { 0, 0, 0, 10, 4, 10 })
end)

test(
	"crosses: segments that pass through a shape between samples are caught, with the entry fraction",
	function(t)
		local gate = Zones.box(v(50, 5, 0), v(1, 10, 20))
		local hit, fraction = Zones.crosses(gate, v(0, 5, 0), v(100, 5, 0))
		t.ok(hit)
		t.near(fraction :: number, 0.495, 1e-12)
		t.ok(not Zones.crosses(gate, v(0, 50, 0), v(100, 50, 0)), "passes over")
		local ball = Zones.sphere(v(10, 0, 0), 2)
		local bh, bf = Zones.crosses(ball, v(0, 0, 0), v(20, 0, 0))
		t.ok(bh)
		t.near(bf :: number, 0.4, 1e-12)
		t.ok(not Zones.crosses(ball, v(0, 3, 0), v(20, 3, 0)))
		t.ok(not Zones.crosses(ball, v(20, 0, 0), v(30, 0, 0)), "moving away")
		local prism = Zones.prism(L_SHAPE, 0, 4)
		local ph, pf = Zones.crosses(prism, v(-10, 2, 2), v(10, 2, 2))
		t.ok(ph)
		t.near(pf :: number, 0.5, 1e-12)
		t.ok(not Zones.crosses(prism, v(6, 2, 20), v(20, 2, 6)), "cuts across the notch only")
		t.ok(not Zones.crosses(prism, v(2, 9, 2), v(2, 5, 2)), "stays above the roof")
		local sh, sf = Zones.crosses(prism, v(2, 9, 2), v(2, 1, 2))
		t.ok(sh)
		t.near(sf :: number, 5 / 8, 1e-12, "drops in through the roof")
	end
)

-- ---------------------------------------------------------------- tracker

test("tracker: hysteresis keeps a jittering body inside until it is clearly out", function(t)
	local env = FakeEnv.new()
	local set =
		Zones.define({ { id = "room", shape = Zones.box(v(0, 0, 0), v(10, 10, 10)), hysteresis = 0.5 } })
	local tracker = Zones.tracker(set, nil, env)
	local entered, exited = 0, 0
	tracker.entered:Connect(function()
		entered += 1
	end)
	tracker.exited:Connect(function()
		exited += 1
	end)
	local path = { 6, 5.01, 5, 5.3, 4.9, 5.49, 5.2, 5.51, 5.2, 5.0, 4 }
	local log = {}
	for _, x in path do
		local events = tracker:update("p1", v(x, 0, 0))
		table.insert(log, kinds(events))
	end
	t.eq(log, { "", "", "enter:room", "", "", "", "", "exit:room", "", "enter:room", "" })
	t.eq(entered, 2)
	t.eq(exited, 1)
	t.ok(tracker:isInside("p1", "room"))
	t.eq(tracker:occupants("room"), { "p1" })
	-- The same path without hysteresis flickers.
	local raw = Zones.tracker(
		Zones.define({ { id = "room", shape = Zones.box(v(0, 0, 0), v(10, 10, 10)), hysteresis = 0 } }),
		nil,
		env
	)
	local flips = 0
	for _, x in path do
		flips += #raw:update("p1", v(x, 0, 0))
	end
	t.ok(flips > 3, "without hysteresis the boundary jitter flickers: " .. flips)
end)

test(
	"tracker: fast bodies cannot tunnel through gates or kill volumes; plain areas are not swept",
	function(t)
		local env = FakeEnv.new()
		local set = Zones.define({
			{
				id = "gate",
				shape = Zones.box(v(50, 5, 0), v(1, 10, 20)),
				kind = "gate",
				gate = { order = 1, finish = true, direction = v(1, 0, 0) },
			},
			{ id = "pit", shape = Zones.box(v(80, 5, 0), v(1, 10, 20)), kind = "kill" },
			{ id = "strip", shape = Zones.box(v(90, 5, 0), v(1, 10, 20)) },
		})
		local tracker = Zones.tracker(set, nil, env)
		local killed = {}
		tracker.killed:Connect(function(body, zone)
			table.insert(killed, body .. "@" .. zone)
		end)
		tracker:update("car", v(0, 5, 0))
		local events = tracker:update("car", v(100, 5, 0))
		t.eq(kinds(events), "enter:gate,exit:gate,enter:pit,kill:pit,exit:pit")
		t.eq(events[1].swept, true)
		t.eq(events[1].forward, true)
		t.eq(events[2].reason, "swept")
		t.eq(killed, { "car@pit" })
		-- Coming back the other way is a backward crossing.
		local back = tracker:update("car", v(10, 5, 0))
		t.eq(back[1].zone, "gate")
		t.eq(back[1].forward, false)
	end
)

test("tracker: hazards tick on the server clock while inside, capped after a long gap", function(t)
	local env = FakeEnv.new()
	local set = Zones.define({
		{
			id = "acid",
			shape = Zones.sphere(v(0, 0, 0), 5),
			kind = "hazard",
			hazard = { amount = 4, interval = 0.5, damageKind = "acid" },
		},
		{
			id = "slow",
			shape = Zones.sphere(v(100, 0, 0), 5),
			kind = "hazard",
			hazard = { amount = 1, interval = 1, immediate = false },
		},
	})
	local tracker = Zones.tracker(set, nil, env)
	local total = 0
	tracker.hazard:Connect(function(_body, _zone, amount, kind)
		t.eq(kind, "acid")
		total += amount
	end)
	local ticks = 0
	local function count(events: { any })
		for _, event in events do
			if event.kind == "hazard" then
				ticks += 1
			end
		end
	end
	count(tracker:update("p", v(0, 0, 0)))
	t.eq(ticks, 1, "immediate tick on entry")
	for _ = 1, 10 do
		env:advance(0.1)
		count(tracker:update("p", v(0, 0, 0)))
	end
	t.eq(ticks, 3, "t = 0, 0.5, 1.0")
	env:advance(60)
	count(tracker:update("p", v(0, 0, 0)))
	t.eq(ticks, 3 + Zones.MAX_TICKS_PER_UPDATE, "owed ticks are capped, not banked")
	env:advance(0.4)
	count(tracker:update("p", v(0, 0, 0)))
	t.eq(ticks, 3 + Zones.MAX_TICKS_PER_UPDATE, "the schedule restarts from the catch-up")
	t.eq(total, ticks * 4)
	-- Leaving stops ticks; immediate = false waits one interval.
	count(tracker:update("p", v(100, 0, 0)))
	local before = ticks
	env:advance(0.9)
	count(tracker:update("p", v(100, 0, 0)))
	t.eq(ticks, before)
	env:advance(0.1)
	local slowEvents = tracker:update("p", v(100, 0, 0))
	t.eq(kinds(slowEvents), "hazard:slow")
end)

test("tracker: untrusted positions are refused, capacity holds, removal exits, priorities order", function(t)
	local env = FakeEnv.new()
	local set = Zones.define({
		{ id = "map", shape = Zones.box(v(0, 0, 0), v(100, 100, 100)), priority = 0 },
		{ id = "base", shape = Zones.sphere(v(0, 0, 0), 10), priority = 5, tags = { "safe" } },
		{ id = "core", shape = Zones.sphere(v(0, 0, 0), 2), priority = 5 },
	})
	local tracker = Zones.tracker(set, { maxBodies = 2 }, env)
	local events, reason = tracker:update("p1", v(NAN, 0, 0))
	t.eq(#events, 0)
	t.eq(reason, "bad_position")
	t.eq(select(2, tracker:update("p1", { x = 1, y = math.huge, z = 0 })), "bad_position")
	t.eq(select(2, tracker:update("p1", "here" :: any)), "bad_position")
	t.eq(select(2, tracker:update(nil, v(0, 0, 0))), "bad_body")
	t.eq(tracker:count(), 0, "refused updates create no body")
	tracker:update("p1", v(1, 0, 0))
	t.eq(tracker:inside("p1"), { "base", "core", "map" })
	t.eq(tracker:current("p1"), "base")
	tracker:update("p2", v(40, 0, 0))
	t.eq(select(2, tracker:update("p3", v(0, 0, 0))), "full")
	local gone = tracker:remove("p1")
	t.eq(kinds(gone), "exit:base,exit:core,exit:map")
	t.eq(gone[1].reason, "removed")
	t.eq(#tracker:remove("p1"), 0)
	t.eq(tracker:count(), 1)
	-- step() updates in sorted id order.
	tracker:remove("p2")
	local stepped = tracker:step({ b = v(0, 0, 0), a = v(0, 0, 0) })
	t.eq(stepped[1].body, "a")
	t.eq(stepped[#stepped].body, "b")
	t.throws(function()
		Zones.tracker({ zones = {}, ids = {} } :: any, nil, env)
	end)
end)

-- ---------------------------------------------------------------- course

local function courseSet(minTime: number?)
	return Zones.define({
		{
			id = "g1",
			shape = Zones.box(v(100, 5, 0), v(1, 10, 20)),
			kind = "gate",
			gate = { order = 1, direction = v(1, 0, 0), minTime = minTime },
		},
		{
			id = "g2",
			shape = Zones.box(v(200, 5, 0), v(1, 10, 20)),
			kind = "gate",
			gate = { order = 2, direction = v(1, 0, 0) },
		},
		{
			id = "finish",
			shape = Zones.box(v(300, 5, 0), v(1, 10, 20)),
			kind = "gate",
			gate = { order = 3, finish = true },
		},
	})
end

test("course: in-order gates make sectors, laps and a finish with exact times", function(t)
	local env = FakeEnv.new({ start = 10 })
	local course = Zones.course(courseSet(), { laps = 2 }, env)
	course:start("p1")
	local log = {}
	for lap = 1, 2 do
		for _, gate in { "g1", "g2", "finish" } do
			env:advance(2)
			for _, event in course:cross("p1", gate, true) do
				table.insert(log, event.kind)
				if event.kind == "lap" then
					t.near(event.lapTime :: number, 6, 1e-12, "lap " .. lap)
				elseif event.kind == "finish" then
					t.near(event.total :: number, 12, 1e-12)
				elseif event.kind == "sector" then
					t.near(event.split :: number, 2, 1e-12)
				end
			end
		end
	end
	t.eq(log, { "sector", "sector", "sector", "lap", "sector", "sector", "sector", "lap", "finish" })
	local progress = course:progress("p1") :: any
	t.ok(progress.finished)
	t.eq(progress.laps, { 6, 6 })
	t.eq(#course:cross("p1", "g1", true), 0, "a finished racer is ignored")
	t.eq(course:progress("nobody"), nil)
end)

test("course: shortcuts, backwards crossings and teleports between gates are refused", function(t)
	local env = FakeEnv.new()
	local course = Zones.course(courseSet(1.5), { laps = 1 }, env)
	course:start("cheat")
	course:start("fair")
	env:advance(1)
	local skip = course:cross("cheat", "finish", true)
	t.eq(skip[1].kind, "wrong_gate")
	t.eq(skip[1].expected, 1)
	t.eq(course:cross("cheat", "g1", false)[1].kind, "wrong_way")
	t.eq(course:cross("cheat", "g1", true)[1].kind, "too_fast", "1 s after the start beats minTime 1.5")
	env:advance(1)
	t.eq(course:cross("fair", "g1", true)[1].kind, "sector")
	t.eq(course:cross("cheat", "g1", true)[1].kind, "sector")
	env:advance(1)
	course:cross("fair", "g2", true)
	t.eq(course:standings(), { "fair", "cheat" })
	t.eq(#course:cross("ghost", "g1", true), 0, "unstarted bodies are ignored")
	t.eq(#course:cross("fair", "nope", true), 0)
end)

test("course: tracker gate events drive the course; bad gate layouts are refused", function(t)
	local env = FakeEnv.new()
	local set = courseSet()
	local tracker = Zones.tracker(set, nil, env)
	local course = Zones.course(set, nil, env)
	course:start("car")
	local results = {}
	tracker:update("car", v(0, 5, 0))
	for _, x in { 150, 250, 350 } do
		env:advance(1)
		for _, event in course:observe(tracker:update("car", v(x, 5, 0))) do
			table.insert(results, event.kind)
		end
	end
	t.eq(results, { "sector", "sector", "sector", "lap", "finish" })

	local gap = Zones.define({
		{ id = "a", shape = Zones.sphere(v(0, 0, 0), 1), kind = "gate", gate = { order = 1 } },
		{ id = "b", shape = Zones.sphere(v(5, 0, 0), 1), kind = "gate", gate = { order = 3, finish = true } },
	})
	t.ok(has(Zones.validateCourse(gap), "without gaps"))
	local twoFinish = Zones.define({
		{ id = "a", shape = Zones.sphere(v(0, 0, 0), 1), kind = "gate", gate = { order = 1, finish = true } },
		{ id = "b", shape = Zones.sphere(v(5, 0, 0), 1), kind = "gate", gate = { order = 2, finish = true } },
	})
	t.ok(has(Zones.validateCourse(twoFinish), "only one gate"))
	local early = Zones.define({
		{ id = "a", shape = Zones.sphere(v(0, 0, 0), 1), kind = "gate", gate = { order = 1, finish = true } },
		{ id = "b", shape = Zones.sphere(v(5, 0, 0), 1), kind = "gate", gate = { order = 2 } },
	})
	t.ok(has(Zones.validateCourse(early), "highest order"))
	local none = Zones.define({ { id = "a", shape = Zones.sphere(v(0, 0, 0), 1) } })
	t.ok(has(Zones.validateCourse(none), "at least one gate"))
	t.ok(has(Zones.validateCourse(set, { laps = 0 }), "laps"))
	t.throws(function()
		Zones.course(gap, nil, env)
	end)
end)

return cases
