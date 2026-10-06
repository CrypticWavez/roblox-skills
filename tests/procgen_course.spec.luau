-- ProcGen Course generators and Validate.course: determinism per seed, the fixture parameters and
-- a seed sweep pass every check, every link is a jump Measure.canJump accepts with the course's
-- own physics, and broken or mismatched courses fail the right check with the exact reason
-- (a course built for a stronger jumper, a widened gap, a skippable checkpoint, a falling
-- difficulty curve, an open race loop, a too-tight turn, an unbalanced lane, a moved spawn,
-- overlapping arena pieces, a tampered hash). Parameter errors name the parameter.
local Course = require("../packages/ProcGen/Course")
local CourseScene = require("../packages/ProcGen/CourseScene")
local Measure = require("../packages/SceneKit/Measure")
local SK = require("../packages/SceneKit/SceneKit")
local Validate = require("../packages/ProcGen/Validate")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

-- Same parameters as the course fixtures in tools/lune/build_fixtures.luau.
local FIXTURES = {
	{ kind = "linear", seed = 701, length = 24 },
	{ kind = "tower", seed = 702, floors = 4 },
	{ kind = "race_loop", seed = 703 },
	{ kind = "lanes", seed = 704, lanes = 3 },
	{ kind = "micro_arena", seed = 705, players = 8, edge = "wall" },
}

local function find(checks, name)
	for _, c in checks do
		if c.name == name then
			return c
		end
	end
	error("no check " .. name)
end

local function failed(checks)
	local out = {}
	for _, c in checks do
		if not c.pass then
			table.insert(out, c.name .. ": " .. tostring(c.detail))
		end
	end
	return out
end

-- Re-seal after a deliberate edit, so only the check under test can fail.
local function reseal(course)
	course.hash = Course.hash(course)
	return course
end

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = deepCopy(v)
	end
	return out
end

test("same seed gives the same hash, another seed another layout", function(t)
	for _, params in FIXTURES do
		local a, b = Course.generate(params), Course.generate(params)
		t.eq(a.hash, b.hash, params.kind .. " deterministic")
		t.eq(a.schema, "course/1")
		local other = table.clone(params)
		other.seed = params.seed + 1000
		t.ok(Course.generate(other).hash ~= a.hash, params.kind .. " seed changes the layout")
	end
end)

test("fixture courses pass every check", function(t)
	for _, params in FIXTURES do
		local checks = Validate.course(Course.generate(params))
		t.eq(failed(checks), {}, params.kind .. " checks")
		t.ok(#checks >= 6, params.kind .. " has its checks")
	end
end)

test("seed sweep: every kind passes every check on 8 seeds", function(t)
	for _, kind in Course.KINDS do
		for seed = 1, 8 do
			local course = Course.generate({ kind = kind, seed = "sweep" .. seed })
			t.eq(failed(Validate.course(course)), {}, kind .. " seed " .. seed)
		end
	end
end)

test("every link walks or passes Measure.canJump with the course physics", function(t)
	for _, scale in { 1, { jumpHeight = 10, walkSpeed = 20 }, { jumpHeight = 5, walkSpeed = 14 } } do
		for _, kind in { "linear", "tower" } do
			local course = Course.generate({ kind = kind, seed = 11, playerScale = scale })
			local margin = course.params.margin or Course.MARGIN
			local jumps = 0
			for _, segment in course.segments do
				local a, b = course.pads[segment.from], course.pads[segment.to]
				local gap, rise = Course.padGap(a, b), b.pos.y - a.pos.y
				local walk = gap <= Course.WALK_GAP and math.abs(rise) <= Measure.GUIDE.maxStep
				if not walk then
					jumps += 1
					t.ok(
						Measure.canJump(math.max(gap, 0), rise, margin, course.profile),
						string.format("%s segment %d gap %.2f rise %.2f", kind, segment.index, gap, rise)
					)
				end
			end
			t.ok(jumps > 0, kind .. " has jumps")
		end
	end
end)

test("a stronger jumper's course is rejected for the default player with the exact reason", function(t)
	local course = Course.linear({
		seed = 21,
		length = 16,
		difficultyCurve = 0.9,
		segmentKinds = { "gap" },
		playerScale = { jumpHeight = 12, walkSpeed = 24 },
	})
	t.eq(failed(Validate.course(course)), {}, "valid for its own player")
	local default = Measure.profile()
	course.profile = {
		gravity = default.gravity,
		walkSpeed = default.walkSpeed,
		jumpHeight = default.jumpHeight,
		characterHeight = default.characterHeight,
		characterWidth = default.characterWidth,
	}
	reseal(course)
	local check = find(Validate.course(course), "jumpable_gaps")
	t.eq(check.pass, false, "too far for the default jump")
	-- First failing segment, recomputed from Measure alone.
	local margin = course.params.margin
	local expected
	for _, segment in course.segments do
		local a, b = course.pads[segment.from], course.pads[segment.to]
		local gap, rise = Course.padGap(a, b), b.pos.y - a.pos.y
		if not Measure.canJump(math.max(gap, 0), rise, margin) then
			local reach = Measure.jumpReach(rise) :: number
			expected = string.format(
				"segment %d gap: gap %.2f > safe %.2f (reach %.2f, margin %.2f)",
				segment.index,
				gap,
				reach * (1 - margin),
				reach,
				margin
			)
			break
		end
	end
	t.ok(expected ~= nil, "a segment is out of reach")
	t.eq(string.sub(check.detail, 1, #expected), expected, "reason")
	t.eq(find(Validate.course(course), "reachability").pass, false, "finish unreachable")
end)

test("a widened gap fails jumpable_gaps and reachability", function(t)
	local course = Course.linear({ seed = 701, length = 24 })
	local profile, margin = course.profile, course.params.margin
	local target
	for _, segment in course.segments do
		local a, b = course.pads[segment.from], course.pads[segment.to]
		if segment.kind == "gap" and math.abs(b.pos.y - a.pos.y) < 1e-6 then
			target = segment
			break
		end
	end
	t.ok(target ~= nil, "fixture has a flat gap")
	local a, b = course.pads[target.from], course.pads[target.to]
	local dx, dz = b.pos.x - a.pos.x, b.pos.z - a.pos.z
	local len = math.sqrt(dx * dx + dz * dz)
	local push = (Course.safeGap(0, profile, margin) :: number) + 2
	for i = target.to, #course.pads do
		local pad = course.pads[i]
		pad.pos = { x = pad.pos.x + dx / len * push, y = pad.pos.y, z = pad.pos.z + dz / len * push }
	end
	reseal(course)
	local checks = Validate.course(course)
	local gaps = find(checks, "jumpable_gaps")
	t.eq(gaps.pass, false)
	local gap = Course.padGap(a, b)
	local reach = Measure.jumpReach(0, profile) :: number
	local expected = string.format(
		"segment %d gap: gap %.2f > safe %.2f (reach %.2f, margin %.2f)",
		target.index,
		gap,
		reach * (1 - margin),
		reach,
		margin
	)
	t.eq(gaps.detail, expected)
	t.eq(find(checks, "reachability").pass, false)
end)

test("a checkpoint that can be skipped fails checkpoint_gating", function(t)
	local course = Course.linear({ seed = 701, length = 24 })
	t.ok(#course.checkpoints >= 1, "fixture has checkpoints")
	-- Put the finish pad one short hop from the spawn.
	local spawn, finish = course.pads[1], course.pads[#course.pads]
	finish.pos = {
		x = spawn.pos.x + Course.exitDistance(spawn, 1, 0) + finish.size.x / 2 + 3,
		y = spawn.pos.y,
		z = spawn.pos.z,
	}
	finish.yaw = 0
	reseal(course)
	local check = find(Validate.course(course), "checkpoint_gating")
	t.eq(check.pass, false)
	local cp = course.checkpoints[1]
	local expected =
		string.format("finish reachable without checkpoint 1 (pad %d (%s))", cp.pad, course.pads[cp.pad].id)
	t.eq(string.sub(check.detail, 1, #expected), expected)
end)

test("checkpoint spacing follows the rules", function(t)
	local course = Course.linear({ seed = 701, length = 24, checkpointEvery = 6 })
	t.eq(find(Validate.course(course), "checkpoint_spacing").pass, true)
	local strict = find(Validate.course(course, { maxCheckpointSegments = 3 }), "checkpoint_spacing")
	t.eq(strict.pass, false)
	t.ok(string.find(strict.detail, "spawn -> checkpoint 1: ", 1, true) ~= nil, strict.detail)
end)

test("a falling difficulty curve fails difficulty_curve; the tolerance is a rule", function(t)
	local course = Course.linear({
		seed = 5,
		length = 30,
		segmentKinds = { "gap" },
		difficultyCurve = { from = 0.95, to = 0.05 },
	})
	local check = find(Validate.course(course), "difficulty_curve")
	t.eq(check.pass, false)
	t.ok(
		string.match(
			check.detail,
			"^segment %d+ difficulty %d%.%d%d drops %d%.%d%d below %d%.%d%d %(segment %d+%)"
		)
	)
	t.eq(find(Validate.course(course, { difficultyTolerance = 1 }), "difficulty_curve").pass, true)
	local rising = Course.linear({ seed = 5, length = 30, segmentKinds = { "gap" } })
	t.eq(find(Validate.course(rising), "difficulty_curve").pass, true)
end)

test("tower: a checkpoint ends every floor but the last, the finish on top", function(t)
	local course = Course.tower({ seed = 702, floors = 4 })
	t.eq(#course.checkpoints, 3)
	for floor, cp in course.checkpoints do
		t.eq(cp.floor, floor)
	end
	t.eq(course.pads[#course.pads].role, "finish")
	local top = -math.huge
	for _, pad in course.pads do
		top = math.max(top, pad.pos.y)
	end
	t.eq(course.pads[#course.pads].pos.y, top, "finish is the highest pad")
	t.throws(function()
		Course.tower({ seed = 1, floorHeight = 4 })
	end, "a floor lower than the headroom")
end)

test("race loop is closed and a broken loop fails loop_closed", function(t)
	local course = Course.raceLoop({ seed = 703 })
	local checks = Validate.course(course)
	t.eq(find(checks, "loop_closed").pass, true)
	t.eq(course.finish.gate, #course.checkpoints, "the last gate is the finish line")
	local spacing = course.lapLength / #course.samples
	for g, gate in course.checkpoints do
		local nextGate = course.checkpoints[g % #course.checkpoints + 1]
		local steps = (nextGate.sample - gate.sample) % #course.samples
		t.ok(steps * spacing <= Course.MAX_GATE_SPACING, "gates within the spacing")
	end
	local open = deepCopy(course)
	for _ = 1, 25 do
		table.remove(open.samples)
	end
	reseal(open)
	local check = find(Validate.course(open), "loop_closed")
	t.eq(check.pass, false)
	t.ok(string.find(check.detail, "last-to-first step", 1, true) ~= nil)
end)

test("race loop: a tighter minTurnRadius rule fails min_turn_radius; gates fill long laps", function(t)
	local course = Course.raceLoop({ seed = 703 })
	local check = find(Validate.course(course, { minTurnRadius = 1000 }), "min_turn_radius")
	t.eq(check.pass, false)
	t.ok(string.match(check.detail, "^tightest at sample %d+$") ~= nil)
	local long = Course.raceLoop({ seed = 3, length = 2600, gates = 3 })
	t.ok(#long.checkpoints >= math.ceil(long.lapLength / Course.MAX_GATE_SPACING), "gates added")
	t.eq(failed(Validate.course(long)), {})
end)

test("lanes have exactly equal lengths and an unbalanced lane fails lane_balance", function(t)
	for seed = 1, 6 do
		local course = Course.lanes({ seed = seed, lanes = 4 })
		local length = #course.paths[1]
		for lane = 2, #course.paths do
			t.eq(#course.paths[lane], length, "lane " .. lane .. " seed " .. seed)
		end
	end
	local course = Course.lanes({ seed = 704, lanes = 3 })
	local cells = course.paths[1]
	local last = cells[#cells]
	-- Detour of 6 cells at the base end of lane 1 (still connected, still ending on the last row).
	local x, y = last[1], last[2]
	for _, step in { { -1, 0 }, { -1, 0 }, { -1, 0 }, { 1, 0 }, { 1, 0 }, { 1, 0 } } do
		x += step[1]
		table.insert(cells, { x, y })
	end
	reseal(course)
	local check = find(Validate.course(course), "lane_balance")
	t.eq(check.pass, false)
	t.eq(check.detail, string.format("lane lengths %d..%d cells", #course.paths[2], #cells))
end)

test("micro arena spawns are fair and a moved spawn fails spawn_fairness", function(t)
	local course = Course.microArena({ seed = 705, players = 8, edge = "wall" })
	local checks = Validate.course(course)
	for _, name in { "spawn_fairness", "spawn_symmetry", "spawn_separation", "spawn_clear", "piece_overlap" } do
		t.eq(find(checks, name).pass, true, name)
	end
	local moved = deepCopy(course)
	local s = moved.spawn.slots[1]
	s.pos = { x = s.pos.x * 0.6, y = s.pos.y, z = s.pos.z * 0.6 }
	reseal(moved)
	local after = Validate.course(moved)
	t.eq(find(after, "spawn_fairness").pass, false)
	t.eq(find(after, "spawn_symmetry").pass, false)
	t.ok(string.find(find(after, "spawn_symmetry").detail, "spawn ", 1, true) ~= nil)
end)

test("micro arena pieces never overlap; an overlap fails piece_overlap", function(t)
	for players = 2, 16 do
		local course = Course.microArena({ seed = players, players = players })
		t.eq(find(Validate.course(course), "piece_overlap").pass, true, "players " .. players)
	end
	local course = Course.microArena({ seed = 705, players = 8 })
	local first, second = course.segments[1], course.segments[2]
	second.pos = first.pos
	second.yaw = first.yaw
	reseal(course)
	local check = find(Validate.course(course), "piece_overlap")
	t.eq(check.pass, false)
	t.eq(
		string.sub(check.detail, 1, #(first.role .. " 1 overlaps " .. second.role .. " 2")),
		first.role .. " 1 overlaps " .. second.role .. " 2"
	)
end)

test("a tampered manifest fails course_hash; a non-course fails course_schema", function(t)
	local course = Course.linear({ seed = 1, length = 8 })
	course.pads[2].pos = { x = 0, y = 0, z = 0 }
	t.eq(find(Validate.course(course), "course_hash").pass, false)
	local bad = Validate.course({ schema = "layout/1" })
	t.eq(#bad, 1)
	t.eq(bad[1].name, "course_schema")
	t.eq(bad[1].pass, false)
end)

test("parameter errors name the parameter", function(t)
	local function message(fn)
		local ok, err = pcall(fn)
		t.eq(ok, false, "expected an error")
		return tostring(err)
	end
	local cases_ = {
		{
			function()
				Course.linear({ seed = 1, length = 0 })
			end,
			"length must be an integer",
		},
		{
			function()
				Course.linear({ seed = 1, difficultyCurve = 2 })
			end,
			"difficultyCurve must be a number in [0, 1]",
		},
		{
			function()
				Course.linear({ seed = 1, segmentKinds = { "teleport" } })
			end,
			"unknown linear segment kind teleport",
		},
		{
			function()
				Course.linear({ seed = 1, playerScale = { jumpHeight = -1 } })
			end,
			"playerScale: Measure.profile: jumpHeight must be a finite number > 0",
		},
		{
			function()
				Course.linear({ length = 4 })
			end,
			"seed must be a number or a string",
		},
		{
			function()
				Course.raceLoop({ seed = 1, length = 200 })
			end,
			"is too short for minTurnRadius",
		},
		{
			function()
				Course.lanes({ seed = 1, cellSize = 2 })
			end,
			"narrower than a lane",
		},
		{
			function()
				Course.microArena({ seed = 1, shape = "hexagon" })
			end,
			"shape must be round or square",
		},
		{
			function()
				Course.generate({ kind = "maze", seed = 1 })
			end,
			"unknown kind maze",
		},
		{
			function()
				Course.curve({ points = { { 0, 0.1 }, { 0.5, 0.5 } } })
			end,
			"must start at t = 0 and end at t = 1",
		},
	}
	for _, case in cases_ do
		local err = message(case[1])
		t.ok(string.find(err, case[2], 1, true) ~= nil, err)
	end
end)

test("playerScale scales the course with the character", function(t)
	local function longestGap(course)
		local longest = 0
		for _, segment in course.segments do
			longest = math.max(longest, segment.gap)
		end
		return longest
	end
	local base = Course.linear({ seed = 9, segmentKinds = { "gap" }, difficultyCurve = 0.8 })
	local strong = Course.linear({
		seed = 9,
		segmentKinds = { "gap" },
		difficultyCurve = 0.8,
		playerScale = { jumpHeight = 12 },
	})
	t.ok(longestGap(strong) > longestGap(base), "a higher jump gets longer gaps")
	local big = Course.microArena({ seed = 9, players = 8, playerScale = 1.5 })
	local small = Course.microArena({ seed = 9, players = 8 })
	t.ok(big.arena.area > small.arena.area, "bigger bodies get a bigger arena")
	t.eq(Measure.profile(1.5).characterHeight, Measure.GUIDE.characterHeight * 1.5)
	t.eq(Measure.profile(1.5).jumpHeight, Measure.ENGINE.jumpHeight, "body scale keeps JumpHeight")
	t.throws(function()
		Measure.profile(0)
	end)
end)

test("toScene emits a valid SceneKit plan with gameplay attributes", function(t)
	for _, params in FIXTURES do
		local course = Course.generate(params)
		local scene = Course.toScene(course, "greybox")
		t.ok(#scene.specs > 0, params.kind .. " has parts")
		t.eq(scene.name, "Course_" .. params.kind)
		t.ok(SK.Validate.summary(SK.Validate.scene(scene)).pass, params.kind .. " scene checks")
		local record = (scene.meta :: any).courses[1]
		t.eq(record.hash, course.hash)
		local checkpoints, spawns, finish = 0, 0, 0
		for _, spec in scene.specs do
			local a = spec.attributes or {}
			t.ok(type(a.asset) == "string" and string.match(a.asset, "^course_[a-z_]+$") ~= nil, spec.id)
			checkpoints += if a.Checkpoint and spec.name ~= "post" and spec.name ~= "crossbar" then 1 else 0
			spawns += if a.SpawnSlot then 1 else 0
			finish += if a.Finish then 1 else 0
		end
		t.ok(spawns >= 1, params.kind .. " spawn")
		if params.kind == "linear" or params.kind == "tower" or params.kind == "race_loop" then
			t.eq(checkpoints, #course.checkpoints, params.kind .. " checkpoint parts")
			t.eq(finish, 1, params.kind .. " finish part")
		end
	end
	local linear = Course.generate(FIXTURES[1])
	local first = Course.toScene(linear):manifest()
	local again = Course.toScene(Course.generate(FIXTURES[1])):manifest()
	t.eq(SK.Scene.compare(first, again).identical, true, "same course, same plan")
	t.throws(function()
		CourseScene.toScene({ schema = "course/1", kind = "maze" })
	end)
end)

return cases
