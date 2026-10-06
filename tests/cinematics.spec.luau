--!strict
-- G4 specs: Cinematics (cinematics/1) and Cinematics/Spline. validate rejects non-monotonic keys
-- and every other malformed field with its path; sample is exact at keys for every
-- interpolation and the same at any frame rate; eventsBetween is (t0, t1] so each event fires
-- once on the frame that reaches it, and the player flushes the last ones at t = duration; hold-to-skip fires only
-- onSkip = "fire" events; reduce turns moves into cuts; constant_speed walks the path evenly;
-- bake/digest are deterministic and the orbit fixture's bake is golden (cinematics-orbit).
-- CinematicsRoblox runs here against a fake camera and RunService (camera restore, events,
-- skip through an IAS action, letterbox and fade overlay); the real camera is probe
-- cin_play_sample.
local roblox = require("@lune/roblox")

local Cinematics = require("../packages/Cinematics/Cinematics")
local CinematicsRoblox = require("../packages/Cinematics/CinematicsRoblox")
local Signal = require("../packages/GameKit/Signal")
local Spline = require("../packages/Cinematics/Spline")
local FakeEnv = require("./fakes/FakeEnv")
local Golden = require("./lib/Golden")

local ORBIT = require("../fixtures/kits/shared/cin_setup_only_orbit")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function contains(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

local function near3(t: any, a: { number }, b: { number }, tol: number, message: string)
	for index = 1, 3 do
		t.near(a[index], b[index], tol, message .. "[" .. index .. "]")
	end
end

-- A small valid cutscene; patch(cin) edits a deep copy.
local function base(patch: ((any) -> ())?): any
	local cin: any = {
		schema = "cinematics/1",
		id = "probe_pan",
		duration = 2,
		camera = {
			keys = {
				{ t = 0, position = { 0, 10, -20 }, lookAt = { 0, 2, 0 }, fov = 70 },
				{ t = 1, position = { 12, 8, -12 }, lookAt = { 0, 2, 0 }, fov = 60 },
				{ t = 2, position = { 20, 6, 0 }, lookAt = { 0, 2, 0 }, fov = 50 },
			},
		},
		letterbox = { { t = 0, v = 0 }, { t = 0.5, v = 0.1 } },
		fades = { { t = 0, v = 1 }, { t = 0.25, v = 0 } },
		subtitles = { { t = 0.5, duration = 1, key = "cin.sample.line" } },
		events = {
			{ t = 0, name = "started", onSkip = "drop" },
			{ t = 1, name = "middle", onSkip = "drop" },
			{ t = 1, name = "middle_too", onSkip = "fire" },
			{ t = 2, name = "done", onSkip = "fire" },
		},
		skip = { allowed = true, after = 0.5, hold = 0.25 },
	}
	if patch then
		patch(cin)
	end
	return cin
end

-- ---------------------------------------------------------------- validate

test("validate rejects non-monotonic keys", function(t)
	local problems = Cinematics.validate(base(function(cin)
		cin.camera.keys[2].t = 0
	end))
	t.ok(
		contains(problems, "camera.keys[2].t must be greater than the previous entry's (strictly increasing)"),
		table.concat(problems, " | ")
	)
	local swapped = Cinematics.validate(base(function(cin)
		cin.letterbox = { { t = 0.5, v = 0.1 }, { t = 0.2, v = 0 } }
	end))
	t.ok(contains(swapped, "letterbox[2].t must be greater than the previous entry's"))
	local events = Cinematics.validate(base(function(cin)
		cin.events = { { t = 1, name = "a" }, { t = 0.5, name = "b" } }
	end))
	t.ok(contains(events, "events[2].t must not be before the previous event (sorted)"))
	t.throws(function()
		Cinematics.define(base(function(cin)
			cin.camera.keys[3].t = 1
		end))
	end)
end)

test("validate names every malformed field", function(t)
	local function problemsOf(patch: (any) -> ()): { string }
		return Cinematics.validate(base(patch))
	end
	local expectations = {
		{
			function(c)
				c.schema = "cinematics/0"
			end,
			"schema must be cinematics/1",
		},
		{
			function(c)
				c.id = "Bad Id"
			end,
			"id must be a lower_snake label",
		},
		{
			function(c)
				c.extra = true
			end,
			"unknown field extra",
		},
		{
			function(c)
				c.space = "screen"
			end,
			"space must be world or anchor",
		},
		{
			function(c)
				c.camera.interpolation = "bouncy"
			end,
			"camera.interpolation must be catmull_rom, linear or hold",
		},
		{
			function(c)
				c.camera.timing = "fast"
			end,
			"camera.timing must be keys or constant_speed",
		},
		{
			function(c)
				c.camera.keys = { c.camera.keys[1] }
			end,
			"camera.keys needs at least two keys",
		},
		{
			function(c)
				c.camera.keys[1].t = 0.1
			end,
			"camera.keys must start at t = 0",
		},
		{
			function(c)
				c.camera.keys[3].t = 1.5
			end,
			"camera.keys must end at t = duration",
		},
		{
			function(c)
				c.camera.keys[2].lookAt = nil
			end,
			"camera.keys[2] needs lookAt or orientation",
		},
		{
			function(c)
				c.camera.keys[2].lookAt = nil
				c.camera.keys[2].orientation = { 0, 0, 0 }
			end,
			"camera.keys[2]: every key uses the same aim",
		},
		{
			function(c)
				c.camera.keys[1].lookAt = { 0, 10, -20 }
			end,
			"camera.keys[1]: lookAt equals position",
		},
		{
			function(c)
				c.camera.keys[1].lookAt = { 0, 50, -20 }
			end,
			"looking straight up or down is ambiguous",
		},
		{
			function(c)
				c.camera.keys[1].fov = 150
			end,
			"camera.keys[1].fov must be within 1-120",
		},
		{
			function(c)
				c.camera.keys[1].roll = 270
			end,
			"camera.keys[1].roll must be within -180..180 degrees",
		},
		{
			function(c)
				c.camera.keys[1].ease = "Wobble.Out"
			end,
			"camera.keys[1].ease Wobble.Out is not Style.Direction",
		},
		{
			function(c)
				c.camera.keys[2].position = { 1, 2 }
			end,
			"camera.keys[2].position must be { x, y, z }",
		},
		{
			function(c)
				c.letterbox[2].v = 0.4
			end,
			"letterbox[2].v must be within 0-0.25",
		},
		{
			function(c)
				c.fades[1].v = -1
			end,
			"fades[1].v must be within 0-1",
		},
		{
			function(c)
				c.subtitles[1].key = "Not a key!"
			end,
			"subtitles[1].key must be a localisation key",
		},
		{
			function(c)
				c.subtitles[1].duration = 0
			end,
			"subtitles[1].duration must be > 0",
		},
		{
			function(c)
				c.events[1].name = "Started"
			end,
			"events[1].name must be a lower_snake label",
		},
		{
			function(c)
				c.events[1].onSkip = "maybe"
			end,
			"events[1].onSkip must be fire or drop",
		},
		{
			function(c)
				c.events[1].payload = { fn = print }
			end,
			"events[1].payload must be plain JSON data",
		},
		{
			function(c)
				c.events[4].t = 3
			end,
			"events[4].t must be within 0..duration",
		},
		{
			function(c)
				c.skip.after = 11
			end,
			"skip.after must be within 0-10 s",
		},
		{
			function(c)
				c.skip.allowed = "yes"
			end,
			"skip.allowed must be a boolean",
		},
		{
			function(c)
				c.duration = 0
			end,
			"duration must be within 0-300 s",
		},
	}
	for _, item in expectations do
		local problems = problemsOf(item[1])
		t.ok(contains(problems, item[2]), item[2] .. " not in: " .. table.concat(problems, " | "))
	end
	t.eq(Cinematics.validate(nil), { "cutscene must be a table" })
	t.eq(Cinematics.validate(base()), {})
	t.eq(Cinematics.validate(ORBIT), {}, "the orbit fixture is valid")
end)

-- ---------------------------------------------------------------- sampling

test("sample is exact at keys for catmull_rom, linear and hold", function(t)
	for _, interpolation in { "catmull_rom", "linear", "hold" } do
		local cin = Cinematics.define(base(function(c)
			c.camera.interpolation = interpolation
		end))
		for _, key in cin.camera.keys do
			local s = Cinematics.sample(cin, key.t)
			near3(t, s.position, key.position, 1e-9, interpolation .. " position at " .. key.t)
			near3(t, s.lookAt :: any, key.lookAt, 1e-9, interpolation .. " lookAt at " .. key.t)
			t.near(s.fov, key.fov, 1e-9, interpolation .. " fov at " .. key.t)
		end
	end
	local orbit = Cinematics.define(ORBIT)
	for _, key in orbit.camera.keys do
		near3(t, Cinematics.sample(orbit, key.t).position, key.position, 1e-9, "orbit at " .. key.t)
	end
end)

test("sample clamps time, eases channels, picks subtitles and rejects NaN", function(t)
	local cin = Cinematics.define(base())
	near3(t, Cinematics.sample(cin, -5).position, { 0, 10, -20 }, 1e-9, "before start")
	near3(t, Cinematics.sample(cin, 99).position, { 20, 6, 0 }, 1e-9, "after end")
	t.eq(Cinematics.sample(cin, 99).t, 2)
	t.near(Cinematics.sample(cin, 0.25).letterbox, 0.05, 1e-12, "linear letterbox midway")
	t.eq(Cinematics.sample(cin, 1.5).letterbox, 0.1, "held after the last key")
	t.eq(Cinematics.sample(cin, 0).fade, 1)
	t.eq(Cinematics.sample(cin, 0.3).fade, 0)
	t.eq(Cinematics.sample(cin, 0.4).subtitle, nil)
	t.eq(Cinematics.sample(cin, 0.5).subtitle, "cin.sample.line")
	t.eq(Cinematics.sample(cin, 1.5).subtitle, nil, "a subtitle ends at t + duration")
	t.near(
		Cinematics.channelAt({ { t = 0, v = 0, ease = "Quad.In" }, { t = 1, v = 1 } }, 0.5, 0),
		0.25,
		1e-12
	)
	t.eq(Cinematics.channelAt(nil, 0.5, 7), 7)
	t.throws(function()
		Cinematics.sample(cin, 0 / 0)
	end)
end)

test("hold interpolation cuts and reduce turns camera moves into cuts", function(t)
	local cin = Cinematics.define(base())
	local moving = Cinematics.sample(cin, 0.5)
	t.ok(moving.position[1] > 0 and moving.position[1] < 12, "catmull_rom moves between keys")
	local reduced = Cinematics.reduce(cin)
	t.eq(reduced.camera.interpolation, "hold")
	local held = Cinematics.sample(reduced, 0.99)
	near3(t, held.position, { 0, 10, -20 }, 1e-12, "holds the earlier key")
	t.eq(held.fov, 70)
	near3(t, Cinematics.sample(reduced, 1).position, { 12, 8, -12 }, 1e-12, "cuts at the key")
	t.eq(Cinematics.sample(reduced, 0.3).fade, Cinematics.sample(cin, 0.3).fade, "fades stay")
	t.ok(table.isfrozen(reduced))
end)

test("orientation keys interpolate angles the short way round", function(t)
	local cin = Cinematics.define({
		schema = "cinematics/1",
		id = "turn",
		duration = 1,
		camera = {
			interpolation = "linear",
			keys = {
				{ t = 0, position = { 0, 0, 0 }, orientation = { 0, 170, 0 }, fov = 70 },
				{ t = 1, position = { 0, 0, 10 }, orientation = { 10, -170, 20 }, fov = 70 },
			},
		},
	})
	local s = Cinematics.sample(cin, 0.5)
	t.near((s.orientation :: any)[1], 5, 1e-9)
	t.near((s.orientation :: any)[2], 180, 1e-9, "170 -> -170 passes through 180, not 0")
	t.near(s.roll, 10, 1e-9)
end)

test("constant_speed walks the path at an even rate", function(t)
	local cin = Cinematics.define(base(function(c)
		c.camera.timing = "constant_speed"
		-- Uneven key times: the walk ignores them.
		c.camera.keys[2].t = 0.2
	end))
	local previous = Cinematics.sample(cin, 0).position
	local steps = {}
	for index = 1, 20 do
		local p = Cinematics.sample(cin, index / 10).position
		table.insert(steps, Spline.distance(previous, p))
		previous = p
	end
	local lo, hi = math.huge, 0
	for _, d in steps do
		lo, hi = math.min(lo, d), math.max(hi, d)
	end
	t.ok(hi - lo < 0.02 * hi, string.format("step lengths vary %.4f..%.4f", lo, hi))
	near3(t, Cinematics.sample(cin, 2).position, { 20, 6, 0 }, 1e-9, "ends on the last key")
end)

-- ---------------------------------------------------------------- events

test("eventsBetween is (t0, t1] at both boundaries", function(t)
	local cin = Cinematics.define(base())
	local function names(list: { any }): { string }
		local out = {}
		for _, event in list do
			table.insert(out, event.name)
		end
		return out
	end
	t.eq(names(Cinematics.eventsBetween(cin, -math.huge, 0)), { "started" }, "the first frame reaches t = 0")
	t.eq(names(Cinematics.eventsBetween(cin, 0, 0.5)), {}, "t0 excluded: t = 0 already fired")
	t.eq(
		names(Cinematics.eventsBetween(cin, 0.5, 1)),
		{ "middle", "middle_too" },
		"t1 included; simultaneous events keep order"
	)
	t.eq(names(Cinematics.eventsBetween(cin, 1, 1.5)), {}, "a frame at 1 already fired them")
	t.eq(names(Cinematics.eventsBetween(cin, 1, 1)), {}, "empty interval")
	t.eq(names(Cinematics.eventsBetween(cin, 1.5, 1)), {}, "reversed interval")
	t.eq(names(Cinematics.eventsBetween(cin, 1.5, 2)), { "done" }, "the frame reaching the end fires it")
	t.eq(names(Cinematics.eventsBetween(cin, 1.5, math.huge)), { "done" })
	t.eq(names(Cinematics.skipEvents(cin, 0.6)), { "middle_too", "done" })
	t.eq(names(Cinematics.skipEvents(cin, 1)), { "done" }, "events at the played time already fired")
	t.eq(names(Cinematics.skipEvents(cin, -math.huge)), { "middle_too", "done" }, "before the first frame")
end)

test("a skip before the first frame fires onSkip = fire events at t = 0", function(t)
	local cin = Cinematics.define(base(function(c)
		c.skip.after = 0
		c.events[1].onSkip = "fire"
	end))
	local frame = Cinematics.player(cin):skip()
	t.ok(frame ~= nil, "skip.after = 0 allows an immediate skip")
	local names = {}
	for _, event in (frame :: any).events do
		table.insert(names, event.name)
	end
	t.eq(names, { "started", "middle_too", "done" })
	local player = Cinematics.player(cin)
	t.eq(#player:step(0).events, 1, "step(0) fires t = 0")
	t.eq(#player:step(0).events, 0, "a second step(0) does not refire it")
	t.eq(#(player:skip() :: any).events, 2, "nor does a skip after it")
end)

test("the player fires every event exactly once at any frame rate", function(t)
	local cin = Cinematics.define(base())
	for _, dts in { { 1 / 30 }, { 1 / 60 }, { 1 / 144 }, { 0.013, 0.05, 0.021, 0.2 }, { 5 } } do
		local player = Cinematics.player(cin)
		local fired = {}
		local index = 0
		local last
		repeat
			index += 1
			last = player:step(dts[(index - 1) % #dts + 1])
			for _, event in last.events do
				table.insert(fired, event.name)
			end
		until last.state ~= "playing" or index > 10000
		t.eq(last.state, "finished")
		t.eq(fired, { "started", "middle", "middle_too", "done" }, "dt " .. dts[1])
		t.eq(player:time(), 2)
		t.eq(#player:step(1).events, 0, "nothing after the end")
	end
end)

test("hold-to-skip waits for skip.after and skip.hold and fires only onSkip = fire events", function(t)
	local cin = Cinematics.define(base())
	local player = Cinematics.player(cin)
	player:step(0.1)
	t.eq(player:canSkip(), false, "not before skip.after")
	t.eq(player:skip(), nil)
	local frame = player:step(0.1, true)
	t.eq(frame.skipProgress, 0, "holding before skip.after does not count")
	player:step(0.3)
	frame = player:step(0.1, true)
	t.near(frame.skipProgress, 0.4, 1e-9)
	frame = player:step(0.1, false)
	t.eq(frame.skipProgress, 0, "releasing resets the hold")
	player:step(0.1, true)
	player:step(0.1, true)
	frame = player:step(0.1, true)
	t.eq(frame.state, "skipped")
	local names = {}
	for _, event in frame.events do
		table.insert(names, event.name)
	end
	t.eq(names, { "middle_too", "done" }, "skipped at 0.9: the drop event is dropped")
	t.eq(player:time(), 2)
	t.eq(player:state(), "skipped")
	local locked = Cinematics.player(cin, { skippable = false })
	locked:step(1.5)
	t.eq(locked:skip(), nil, "skippable = false")
	local never = Cinematics.player(Cinematics.define(base(function(c)
		c.skip.allowed = false
	end)))
	never:step(1.5)
	t.eq(never:canSkip(), false)
	local stopped = Cinematics.player(cin)
	stopped:stop()
	t.eq(stopped:state(), "stopped")
	t.eq(#stopped:step(1).events, 0)
	t.throws(function()
		Cinematics.player(cin):step(-1)
	end)
end)

-- ---------------------------------------------------------------- spline

test("Spline: centripetal Catmull-Rom passes through its points, Bezier hits its ends", function(t)
	local points = { { 0, 0, 0 }, { 10, 0, 0 }, { 10, 10, 0 }, { 0, 10, 5 } }
	for segment = 1, 3 do
		near3(t, Spline.point(points, segment, 0), points[segment], 1e-12, "start of " .. segment)
		near3(t, Spline.point(points, segment, 1), points[segment + 1], 1e-12, "end of " .. segment)
	end
	local line = { { 0, 0, 0 }, { 10, 0, 0 } }
	near3(t, Spline.point(line, 1, 0.5), { 5, 0, 0 }, 1e-9, "two points: a straight segment")
	local p0, _, _, p3 = Spline.controls(line, 1)
	t.eq(p0, { -10, 0, 0 }, "reflected phantom start")
	t.eq(p3, { 20, 0, 0 }, "reflected phantom end")
	-- Repeated points do not divide by zero.
	local repeated = Spline.catmullRom({ 1, 1, 1 }, { 1, 1, 1 }, { 2, 2, 2 }, { 2, 2, 2 }, 0.5)
	t.ok(repeated[1] == repeated[1], "no NaN")
	t.eq(Spline.bezier({ 0 }, { 1 }, { 2 }, { 3 }, 0), { 0 })
	t.eq(Spline.bezier({ 0 }, { 1 }, { 2 }, { 3 }, 1), { 3 })
	t.near(Spline.bezier({ 0 }, { 1 }, { 2 }, { 3 }, 0.5)[1], 1.5, 1e-12)
	local arc = Spline.arcTable(line, 16)
	t.near(arc.total, 10, 1e-9)
	local segment, u = Spline.atDistance(arc, 2.5)
	t.eq(segment, 1)
	t.near(u, 0.25, 1e-3)
	t.eq({ Spline.atDistance(arc, -1) }, { 1, 0 })
	t.eq({ Spline.atDistance(arc, 99) }, { 1, 1 })
	t.throws(function()
		Spline.controls(line, 2)
	end)
	t.throws(function()
		Spline.arcTable(line, 1)
	end)
end)

-- ---------------------------------------------------------------- bake and golden

test("bake has one row per frame including the end and is deterministic", function(t)
	local cin = Cinematics.define(base())
	local bake = Cinematics.bake(cin, 30)
	t.eq(bake.schema, Cinematics.BAKE_SCHEMA)
	t.eq(#bake.frames, 61)
	t.eq(bake.frames[61][1], 2)
	t.eq(#bake.columns, #bake.frames[1])
	local odd = Cinematics.bake(
		Cinematics.define(base(function(c)
			c.duration = 2.05
			c.camera.keys[3].t = 2.05
		end)),
		10
	)
	t.eq(odd.frames[#odd.frames][1], 2.05, "a duration between frames still gets its end row")
	t.eq(Cinematics.digest(cin, 30), Cinematics.digest(Cinematics.define(base()), 30))
	t.ok(Cinematics.digest(cin, 30) ~= Cinematics.digest(cin, 24))
	t.throws(function()
		Cinematics.bake(cin, 0)
	end)
	t.throws(function()
		Cinematics.bake(cin, 241)
	end)
end)

test("golden cinematics-orbit: the orbit fixture's bake and digest", function(t)
	local orbit = Cinematics.define(ORBIT)
	local ok, message = Golden.check("cinematics-orbit", {
		schema = "cinematics-orbit/1",
		digest30 = Cinematics.digest(orbit, 30),
		digest60 = Cinematics.digest(orbit, 60),
		bake4 = Cinematics.bake(orbit, 4),
	})
	t.ok(ok, message)
end)

-- ---------------------------------------------------------------- CinematicsRoblox in Lune

local function cameraFake(env: any): any
	return {
		CameraType = roblox.Enum.CameraType.Custom,
		CFrame = roblox.CFrame.new(1, 2, 3),
		Focus = roblox.CFrame.new(),
		FieldOfView = 70,
		Destroying = Signal.new(env),
	}
end

local function actionFake(env: any): any
	return { Pressed = Signal.new(env), Released = Signal.new(env) }
end

test("CinematicsRoblox.cframe aims at lookAt, applies roll and the anchor", function(t)
	local sample: any = { position = { 0, 0, 10 }, lookAt = { 0, 0, 0 }, roll = 0, fov = 70 }
	local cf = CinematicsRoblox.cframe(sample, roblox)
	t.near(cf.LookVector.Z, -1, 1e-6)
	sample.roll = 90
	t.near(CinematicsRoblox.cframe(sample, roblox).UpVector.X, -1, 1e-6, "roll turns the up vector")
	local anchored = CinematicsRoblox.cframe(
		{ position = { 0, 0, 10 }, lookAt = { 0, 0, 0 }, roll = 0, fov = 70 } :: any,
		roblox,
		roblox.CFrame.new(100, 0, 0)
	)
	t.near(anchored.Position.X, 100, 1e-6)
	local oriented = CinematicsRoblox.cframe(
		{ position = { 0, 5, 0 }, orientation = { 0, 90, 0 }, roll = 0 } :: any,
		roblox
	)
	t.near(oriented.LookVector.X, -1, 1e-6, "yaw 90 looks down -X")
	-- lookAt matches CFrame.lookAt semantics in every direction (Lune 0.10's own lookAt mirrors
	-- -Z targets, so the adapter does not use it).
	local V = roblox.Vector3.new
	for _, target in { V(0, 0, -1), V(0, 0, 1), V(1, 0, -1), V(-3, 2, 5), V(1, 0, 0) } do
		local frame = CinematicsRoblox.lookAt(roblox, V(0, 0, 0), target)
		local unit = target.Unit
		t.near(frame.LookVector.X, unit.X, 1e-6)
		t.near(frame.LookVector.Y, unit.Y, 1e-6)
		t.near(frame.LookVector.Z, unit.Z, 1e-6)
		t.near(frame.RightVector.Y, 0, 1e-6, "no roll: right stays level")
		t.ok(frame.UpVector.Y > 0, "up stays up")
	end
	local down = CinematicsRoblox.lookAt(roblox, V(0, 10, 0), V(0, 0, 0))
	t.near(down.LookVector.Y, -1, 1e-6, "straight down")
	t.near(down.RightVector.X, 1, 1e-6, "vertical views use +X as right (convention)")
	t.eq(CinematicsRoblox.lookAt(roblox, V(1, 2, 3), V(1, 2, 3)), roblox.CFrame.new(1, 2, 3), "eye == target")
	local camera = roblox.Instance.new("Camera")
	camera.CFrame =
		CinematicsRoblox.lookAt(roblox, roblox.Vector3.new(0, 10, 0), roblox.Vector3.new(0, 10, -1))
	camera.FieldOfView = 55
	local key = CinematicsRoblox.keyFromCamera(camera, 1.5, 10)
	t.eq(key, { t = 1.5, position = { 0, 10, 0 }, lookAt = { 0, 10, -10 }, fov = 55 })
end)

test("CinematicsRoblox.play drives the camera, fires events once and restores everything", function(t)
	local env = FakeEnv.new({ roblox = roblox })
	local preRender = Signal.new(env)
	env:register("RunService", { PreRender = preRender })
	local camera = cameraFake(env)
	local gui = roblox.Instance.new("ScreenGui")
	local cin = Cinematics.define(base())
	local events, finished = {}, {}
	local handle = CinematicsRoblox.play(cin, {
		camera = camera,
		env = env,
		parent = gui,
		text = function(key)
			return "T:" .. key
		end,
		onEvent = function(name, _payload, skipped)
			table.insert(events, name .. (if skipped then ":skipped" else ""))
		end,
		onFinished = function(state)
			table.insert(finished, state)
		end,
	})
	t.eq(camera.CameraType, roblox.Enum.CameraType.Scriptable)
	t.eq(events, { "started" }, "t = 0 events fire on the first frame")
	local overlay = gui:FindFirstChild("CinematicOverlay")
	t.ok(overlay ~= nil and overlay.DisplayOrder == 80)
	for _ = 1, 45 do
		preRender:Fire(1 / 60)
	end
	local s = Cinematics.sample(cin, handle:time())
	t.near(camera.CFrame.Position.X, s.position[1], 1e-4)
	t.near(camera.FieldOfView, s.fov, 1e-6)
	t.near(overlay.TopBar.Size.Y.Scale, s.letterbox, 1e-6)
	t.eq(overlay.Fade.BackgroundTransparency, 1)
	t.eq(overlay.Subtitle.Text, "T:cin.sample.line")
	t.ok(overlay.SkipHint.Visible, "skippable after skip.after")
	for _ = 1, 120 do
		preRender:Fire(1 / 60)
	end
	t.eq(events, { "started", "middle", "middle_too", "done" })
	t.eq(finished, { "finished" })
	t.eq(handle:state(), "finished")
	t.eq(camera.CameraType, roblox.Enum.CameraType.Custom, "camera type restored")
	t.eq(camera.CFrame, roblox.CFrame.new(1, 2, 3), "camera CFrame restored")
	t.eq(camera.FieldOfView, 70)
	t.eq(overlay.Parent, nil, "overlay destroyed")
	preRender:Fire(1 / 60)
	t.eq(#finished, 1, "disconnected after the end")
	t.throws(function()
		CinematicsRoblox.play(
			base(function(c)
				c.duration = -1
			end),
			{ camera = camera, env = env }
		)
	end)
end)

test("CinematicsRoblox.play: hold the IAS skip action, camera loss stops, reduced motion cuts", function(t)
	local env = FakeEnv.new({ roblox = roblox })
	local preRender = Signal.new(env)
	env:register("RunService", { PreRender = preRender })
	local camera = cameraFake(env)
	local action = actionFake(env)
	local context = { Enabled = false }
	local events, finished = {}, {}
	local cin = Cinematics.define(base())
	CinematicsRoblox.play(cin, {
		camera = camera,
		env = env,
		skipAction = action,
		skipContext = context,
		onEvent = function(name, _payload, skipped)
			table.insert(events, name .. (if skipped then ":skipped" else ""))
		end,
		onFinished = function(state)
			table.insert(finished, state)
		end,
	})
	t.eq(context.Enabled, true, "the cinematic context is on while playing")
	for _ = 1, 40 do
		preRender:Fire(1 / 60)
	end
	action.Pressed:Fire()
	for _ = 1, 20 do
		preRender:Fire(1 / 60)
	end
	t.eq(finished, { "skipped" })
	t.eq(events, { "started", "middle_too:skipped", "done:skipped" })
	t.eq(context.Enabled, false, "and off again")
	t.eq(camera.CameraType, roblox.Enum.CameraType.Custom)
	-- The camera going away stops the run.
	local lost = {}
	CinematicsRoblox.play(cin, {
		camera = camera,
		env = env,
		onFinished = function(state)
			table.insert(lost, state)
		end,
	})
	camera.Destroying:Fire()
	t.eq(lost, { "stopped" })
	-- Reduced motion: cuts between keys.
	local reduced = CinematicsRoblox.play(cin, { camera = camera, env = env, reducedMotion = true })
	for _ = 1, 30 do
		preRender:Fire(1 / 60)
	end
	t.near(camera.CFrame.Position.X, 0, 1e-6, "still on the first key at t = 0.5")
	reduced:stop()
	t.eq(reduced:state(), "stopped")
	-- onEvent errors are reported, not raised.
	CinematicsRoblox.play(cin, {
		camera = camera,
		env = env,
		onEvent = function()
			error("listener broke")
		end,
	})
	t.ok(contains(env.reports, "Cinematics onEvent error"))
end)

return cases
