-- GameKit Checkpoints: ordered touches with splits, skip / replay / teleport / distance refusals
-- with their reasons, laps, respawn points, progress save and resume, specs from ProcGen courses,
-- kit-event/1 progression events, and invalid specs.
local Checkpoints = require("../packages/GameKit/Checkpoints")
local Course = require("../packages/ProcGen/Course")
local Events = require("../packages/GameKit/Events")
local FakeEnv = require("./fakes/FakeEnv")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

local function v(x, y, z)
	return { x = x, y = y, z = z }
end

-- Three checkpoints 40 studs apart along X, respawns 3 studs up.
local function spec(extra)
	local s = {
		checkpoints = {
			{ pos = v(40, 0, 0), radius = 5, respawn = { pos = v(40, 3, 0), yaw = 90 } },
			{ pos = v(80, 0, 0), radius = 5 },
			{ pos = v(120, 0, 0), radius = 5 },
		},
		start = { pos = v(0, 0, 0), yaw = 90 },
		maxSpeed = 20,
	}
	for k, value in extra or {} do
		s[k] = value
	end
	return s
end

test("ordered touches record splits and finish the run", function(t)
	local env = FakeEnv.new()
	local run = Checkpoints.new(spec(), nil, env)
	local reached, finished = {}, nil
	run.reached:Connect(function(player, index, lap, split)
		table.insert(reached, { player, index, lap, split })
	end)
	run.finishedRun:Connect(function(player, time)
		finished = { player, time }
	end)
	run:start("1")
	for i, x in { 40, 80, 120 } do
		env:advance(3)
		t.eq({ run:touch("1", i, v(x, 0, 1)) }, { true, nil }, "touch " .. i)
	end
	t.eq(reached, { { "1", 1, 1, 3 }, { "1", 2, 1, 6 }, { "1", 3, 1, 9 } })
	t.eq(finished, { "1", 9 })
	local progress = run:progress("1") :: any
	t.eq(progress.finished, true)
	t.eq(progress.time, 9)
	t.eq(progress.splits, { 3, 6, 9 })
	t.eq({ run:touch("1", 1, nil) }, { false, "finished" })
end)

test("skips, replays, teleports and far touches are refused with a reason", function(t)
	local env = FakeEnv.new()
	local run = Checkpoints.new(spec(), nil, env)
	local rejected = {}
	run.rejected:Connect(function(player, index, reason)
		table.insert(rejected, player .. ":" .. index .. ":" .. reason)
	end)
	t.eq({ run:touch("2", 1) }, { false, "not_started" })
	run:start("2")
	env:advance(10)
	t.eq({ run:touch("2", 2, v(80, 0, 0)) }, { false, "skipped" }, "checkpoint 1 missed")
	t.eq({ run:touch("2", 1, v(60, 0, 0)) }, { false, "too_far" }, "20 studs from checkpoint 1")
	t.eq({ run:touch("2", 4) }, { false, "unknown_checkpoint" })
	t.eq({ run:touch("2", 1, v(40, 0, 0)) }, { true, nil })
	t.eq({ run:touch("2", 1, v(40, 0, 0)) }, { false, "already_reached" })
	-- 40 studs (30 after both radii) at maxSpeed 20 takes at least 1.5 s.
	env:advance(1)
	t.eq({ run:touch("2", 2, v(80, 0, 0)) }, { false, "too_fast" })
	env:advance(0.5)
	t.eq({ run:touch("2", 2, v(80, 0, 0)) }, { true, nil })
	t.eq(rejected, {
		"2:1:not_started",
		"2:2:skipped",
		"2:1:too_far",
		"2:4:unknown_checkpoint",
		"2:1:already_reached",
		"2:2:too_fast",
	})
end)

test("laps repeat the checkpoints; the last gate of the last lap finishes", function(t)
	local env = FakeEnv.new()
	local run = Checkpoints.new(spec({ laps = 2, maxSpeed = 1000 }), nil, env)
	run:start("3")
	for lap = 1, 2 do
		for i = 1, 3 do
			env:advance(1)
			t.eq({ run:touch("3", i) }, { true, nil }, string.format("lap %d gate %d", lap, i))
			if lap == 1 and i == 3 then
				t.eq({ run:touch("3", 3) }, { false, "already_reached" }, "the line just crossed")
				t.eq({ run:touch("3", 2) }, { false, "skipped" }, "gate 2 of lap 2 before gate 1")
			end
		end
	end
	local p = run:progress("3") :: any
	t.eq(p.finished, true)
	t.eq(#p.splits, 6)
end)

test("respawn goes to the last reached checkpoint (or the start)", function(t)
	local env = FakeEnv.new()
	local run = Checkpoints.new(spec({ maxSpeed = 1000 }), nil, env)
	run:start("4")
	t.eq(run:respawn("4"), { pos = v(0, 0, 0), yaw = 90 })
	env:advance(1)
	run:touch("4", 1)
	t.eq(run:respawn("4"), { pos = v(40, 3, 0), yaw = 90 })
	env:advance(1)
	run:touch("4", 2)
	t.eq(run:respawn("4"), { pos = v(80, 3, 0) }, "no respawn: 3 studs over the checkpoint")
	t.eq(run:respawn("unknown"), { pos = v(0, 0, 0), yaw = 90 })
end)

test("progress resumes after a rejoin; bad progress is refused", function(t)
	local env = FakeEnv.new()
	local run = Checkpoints.new(spec({ maxSpeed = 1000 }), nil, env)
	run:start("5")
	env:advance(2)
	run:touch("5", 1)
	local saved = run:progress("5")
	run:remove("5")
	t.eq(run:progress("5"), nil)
	t.eq({ run:resume("5", saved) }, { true, nil })
	env:advance(2)
	t.eq({ run:touch("5", 2) }, { true, nil })
	t.eq(
		{ run:resume("6", { stage = 2, splits = { 1 }, startedAt = 0, lastAt = 0 }) },
		{ false, "bad_progress" }
	)
	t.eq(
		{ run:resume("6", { stage = 9, splits = {}, startedAt = 0, lastAt = 0 }) },
		{ false, "bad_progress" }
	)
end)

test("fromCourse: linear courses end on the finish pad, race loops use gates and laps", function(t)
	local linear = Course.linear({ seed = 701, length = 24 })
	local s = Checkpoints.fromCourse(linear)
	t.eq(#s.checkpoints, #linear.checkpoints + 1)
	t.eq(s.checkpoints[#s.checkpoints].pos, linear.finish.pos)
	t.eq(s.start.pos, linear.spawn.pos)
	t.eq(s.maxSpeed, linear.profile.walkSpeed * 1.25)
	t.eq(Checkpoints.validate(s), {})
	local race = Course.raceLoop({ seed = 703, laps = 2 })
	local r = Checkpoints.fromCourse(race)
	t.eq(#r.checkpoints, #race.checkpoints)
	t.eq(r.laps, 2)
	t.throws(function()
		Checkpoints.fromCourse({ schema = "layout/1" })
	end)
end)

test("progression events go to the sink", function(t)
	local env = FakeEnv.new()
	local sink = Events.recorder({ clock = env.clock, strict = true })
	local run = Checkpoints.new(spec({ maxSpeed = 1000 }), { sink = sink }, env)
	run:start("7")
	for i = 1, 3 do
		env:advance(1)
		run:touch("7", i)
	end
	local statuses = {}
	for _, event in sink.events do
		t.eq(event.player, "7")
		table.insert(statuses, event.progression.status .. ":" .. event.progression.level)
	end
	t.eq(statuses, { "start:0", "custom:1", "custom:2", "custom:3", "complete:3" })
end)

test("invalid specs list every problem", function(t)
	t.eq(Checkpoints.validate({ checkpoints = {}, start = { pos = v(0, 0, 0) }, laps = 0, maxSpeed = -1 }), {
		"checkpoints must be a non-empty list",
		"laps must be an integer >= 1",
		"maxSpeed must be a finite number > 0",
	})
	t.eq(Checkpoints.validate({ checkpoints = { { pos = v(0, 0, 0), radius = 0 } } }), {
		"checkpoint 1 radius must be > 0",
		"start needs pos { x, y, z }",
	})
	t.throws(function()
		Checkpoints.new({} :: any, nil, FakeEnv.new())
	end)
end)

return cases
