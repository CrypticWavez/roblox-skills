--!strict
-- Diagnostics/PerfProbe (perf/1 aggregator: percentiles, validation, build, collector, compare)
-- and Diagnostics/PerfProbeRoblox's mapping against tests/fakes/FakePerfEngine. The real engine
-- reading is probe perf_capture (T3, pending until it runs in Studio).
local FakeEnv = require("./fakes/FakeEnv")
local FakePerfEngine = require("./fakes/FakePerfEngine")
local PerfProbe = require("../packages/Diagnostics/PerfProbe")
local PerfProbeRoblox = require("../packages/Diagnostics/PerfProbeRoblox")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function mentions(problems: { string }, needle: string): boolean
	for _, problem in problems do
		if string.find(problem, needle, 1, true) then
			return true
		end
	end
	return false
end

local function valid(): { [string]: any }
	return {
		schema = "perf/1",
		kind = "stats",
		device_class = "desktop",
		frame_ms = { p50 = 16, p95 = 20, p99 = 33 },
		memory_mb = { total = 900, lua_heap = 50 },
		counts = { instances = 1000, parts = 200, particle_rate = 12.5 },
		source = { place = "diagnostic" },
	}
end

test("nearest-rank percentiles are observed samples", function(t)
	local samples = {}
	for value = 1, 100 do
		table.insert(samples, 101 - value) -- unsorted input
	end
	t.eq(PerfProbe.percentile(samples, 50), 50)
	t.eq(PerfProbe.percentile(samples, 95), 95)
	t.eq(PerfProbe.percentile(samples, 99), 99)
	t.eq(PerfProbe.percentile(samples, 100), 100)
	t.eq(PerfProbe.percentile({ 7 }, 99), 7)
	t.eq(PerfProbe.percentile({ 1, 2 }, 50), 1)
	t.eq(PerfProbe.percentile({}, 50), nil)
	t.eq(samples[1], 100, "input is not reordered")
	t.throws(function()
		PerfProbe.percentile(samples, 0)
	end)
	t.throws(function()
		PerfProbe.percentile(samples, 101)
	end)
end)

test("frameStats rejects broken samples and returns nil when empty", function(t)
	t.eq(PerfProbe.frameStats({ 16, 17, 40 }), { p50 = 17, p95 = 40, p99 = 40 })
	t.eq(PerfProbe.frameStats({}), nil)
	for _, bad in { { 1, -1 }, { 0 / 0 }, { math.huge } } do
		t.throws(function()
			PerfProbe.frameStats(bad)
		end)
	end
end)

test("validate accepts perf/1 and names every problem", function(t)
	t.eq(PerfProbe.validate(valid()), {})
	local minimal =
		{ schema = "perf/1", kind = "stats", device_class = "phone_low", source = { place = "p" } }
	t.eq(PerfProbe.validate(minimal), {}, "every group is optional except the envelope")
	local bad = valid()
	bad.schema = "perf/2"
	bad.kind = "budgets"
	bad.device_class = "laptop"
	bad.frame_ms = { p50 = 30, p95 = 20, p99 = 10, p75 = 1 }
	bad.memory_mb = { total = -1, LuaHeap = 2, ok_key = 0 / 0 }
	bad.counts = { instances = 1.5, parts = -1, unknown = 1, particle_rate = math.huge }
	bad.texture_mb_estimate = -2
	bad.source = { place = "", scene_hash = 5 }
	bad.extra = true
	local problems = PerfProbe.validate(bad)
	for _, needle in
		{
			"schema must be perf/1",
			"kind must be stats",
			"device_class must be one of",
			"p50 <= p95 <= p99",
			"frame_ms has an unknown key p75",
			"memory_mb.total must be",
			"memory_mb key LuaHeap",
			"memory_mb.ok_key",
			"counts.instances must be a whole number",
			"counts.parts must be a whole number",
			"unknown counter unknown",
			"counts.particle_rate",
			"texture_mb_estimate",
			"source.place",
			"source.scene_hash",
			"unknown key extra",
		}
	do
		t.ok(mentions(problems, needle), needle .. " in " .. table.concat(problems, "; "))
	end
	t.eq(PerfProbe.validate("x"), { "stats must be a table" })
end)

test("build and the collector produce valid perf/1; absent counters stay absent", function(t)
	local stats = PerfProbe.build({
		deviceClass = "phone",
		frameSamplesMs = { 16, 16, 17, 50 },
		memory = { total = 500 },
		counts = { instances = 10 },
		source = { place = "diagnostic", sceneHash = "778d1d9a" },
	})
	t.eq(stats.frame_ms, { p50 = 16, p95 = 50, p99 = 50 })
	t.eq(stats.counts, { instances = 10 })
	t.eq(stats.counts.parts, nil, "a counter nobody measured is absent, not 0")
	t.eq(stats.source.scene_hash, "778d1d9a")
	t.throws(function()
		PerfProbe.build({ deviceClass = "toaster", source = { place = "p" } })
	end)
	local collector = PerfProbe.collector()
	collector:frame(10)
	collector:frame(20)
	collector:memory("total", 100)
	collector:memory("graphics_texture", 30)
	collector:count("parts", 3)
	local built = collector:build("desktop", { place = "diagnostic" }, 12)
	t.eq(PerfProbe.validate(built), {})
	t.eq(built.texture_mb_estimate, 12)
	t.eq(built.frame_ms, { p50 = 10, p95 = 20, p99 = 20 })
	t.throws(function()
		collector:count("bogus", 1)
	end)
	t.throws(function()
		collector:memory("Bad Name", 1)
	end)
	t.throws(function()
		collector:frame(-1)
	end)
	local empty = PerfProbe.collector():build("desktop", { place = "p" })
	t.eq(empty.frame_ms, nil)
	t.eq(empty.memory_mb, nil)
	t.eq(empty.counts, nil)
end)

test("compare gives after - before only where both sides measured", function(t)
	local before = valid()
	local after = valid()
	after.frame_ms = { p50 = 14, p95 = 18, p99 = 30 }
	after.counts = { instances = 900, parts = 250, highlights = 2 }
	after.memory_mb = { total = 850 }
	t.eq(PerfProbe.compare(before, after), {
		frame_ms = { p50 = -2, p95 = -2, p99 = -3 },
		counts = { instances = -100, parts = 50 },
		memory_mb = { total = -50 },
	})
end)

test("categoryName turns enum item names into labels", function(t)
	t.eq(PerfProbe.categoryName("GraphicsTexture"), "graphics_texture")
	t.eq(PerfProbe.categoryName("LuaHeap"), "lua_heap")
	t.eq(PerfProbe.categoryName("Internal"), "internal")
	t.eq(PerfProbe.categoryName("GeometryCSG"), "geometry_csg")
	t.eq(PerfProbe.categoryName("PhysicsCollision"), "physics_collision")
end)

test("PerfProbeRoblox maps Stats, a world walk and Heartbeat into perf/1", function(t)
	local env = FakeEnv.new()
	local runService = FakePerfEngine.runService()
	env:register("RunService", runService)
	env:register(
		"Stats",
		FakePerfEngine.stats({
			total = 812.5,
			byTag = { LuaHeap = 40, GraphicsTexture = 120, Broken = "raise" },
			instances = 4321,
			triangles = nil, -- server and Edit mode report no scene triangles
		})
	)
	env:register(
		"Workspace",
		FakePerfEngine.folder({
			FakePerfEngine.instance("Part"),
			FakePerfEngine.instance("MeshPart"),
			FakePerfEngine.instance("PointLight", { Shadows = true, Enabled = true }),
			FakePerfEngine.instance("SpotLight", { Shadows = false }),
			FakePerfEngine.instance("ParticleEmitter", { Rate = 20, Enabled = true }),
			FakePerfEngine.instance("ParticleEmitter", { Rate = 50, Enabled = false }),
			FakePerfEngine.instance("Sound", { IsPlaying = true }),
			FakePerfEngine.instance("AudioPlayer", { IsPlaying = false }),
			FakePerfEngine.instance("Highlight", { Enabled = true }),
			FakePerfEngine.instance("Folder"),
		})
	)
	local wall = 0
	local stats
	env.spawn(function()
		stats = PerfProbeRoblox.capture(env, {
			frames = 3,
			timeout = 10,
			now = function()
				return wall
			end,
			memoryTags = {
				FakePerfEngine.tag("LuaHeap"),
				FakePerfEngine.tag("GraphicsTexture"),
				FakePerfEngine.tag("Broken"),
			},
			place = "diagnostic",
			studioVersion = "0.741",
		})
	end)
	for _, dt in { 1 / 60, 1 / 30, 1 / 20, 1 / 10 } do
		runService:fire(dt)
		env:advance(1 / 60)
	end
	t.ok(stats ~= nil, "capture finished")
	t.eq(PerfProbe.validate(stats), {})
	t.eq(stats.memory_mb, { total = 812.5, lua_heap = 40, graphics_texture = 120 })
	t.eq(stats.counts.instances, 4321)
	t.eq(stats.counts.triangles, nil, "unreported triangles stay absent")
	t.eq(stats.counts.parts, 2)
	t.eq(stats.counts.shadowed_lights, 1)
	t.eq(stats.counts.particle_rate, 20)
	t.eq(stats.counts.playing_sounds, 1)
	t.eq(stats.counts.highlights, 1)
	t.near(stats.frame_ms.p50, 1000 / 30, 1e-9)
	t.near(stats.frame_ms.p99, 50, 1e-9)
	t.eq(runService:listeners(), 0, "Heartbeat connection released")
	t.eq(stats.source, { place = "diagnostic", studio_version = "0.741" })
end)

test("PerfProbeRoblox stops waiting for frames at the timeout and survives missing Stats members", function(t)
	local env = FakeEnv.new()
	local runService = FakePerfEngine.runService()
	env:register("RunService", runService)
	env:register("Stats", FakePerfEngine.stats({ total = "raise" }))
	local wall = 0
	local stats
	env.spawn(function()
		stats = PerfProbeRoblox.capture(env, {
			frames = 60,
			timeout = 2,
			now = function()
				return wall
			end,
			memoryTags = {},
		})
	end)
	runService:fire(1 / 60) -- one frame, then Heartbeat stops (Edit mode may not step)
	for _ = 1, 3 do
		wall += 1
		env:advance(1 / 60)
	end
	t.ok(stats ~= nil, "timed out instead of hanging")
	t.eq(stats.memory_mb, nil, "a raising GetTotalMemoryUsageMb leaves memory absent")
	t.eq(stats.frame_ms, { p50 = 1000 / 60, p95 = 1000 / 60, p99 = 1000 / 60 })
	t.eq(runService:listeners(), 0)
	t.throws(function()
		PerfProbeRoblox.capture(FakeEnv.new(), {})
	end, "Stats is required")
	t.throws(function()
		PerfProbeRoblox.frames(runService, 1, 1, os.clock, env, 0)
	end, "a zero poll would spin the scheduler")
end)

test("the world walk refuses to report a truncated count", function(t)
	local children = {}
	for _ = 1, 5 do
		table.insert(children, FakePerfEngine.instance("Part"))
	end
	local counts, truncated = PerfProbeRoblox.walk(FakePerfEngine.folder(children), 3)
	t.ok(truncated)
	t.eq(counts.parts, 3)
	local env = FakeEnv.new()
	env:register("Stats", FakePerfEngine.stats({ total = 1 }))
	local saved = PerfProbeRoblox.WALK_LIMIT
	PerfProbeRoblox.WALK_LIMIT = 3
	local stats = PerfProbeRoblox.capture(env, { root = FakePerfEngine.folder(children), memoryTags = {} })
	PerfProbeRoblox.WALK_LIMIT = saved
	t.eq(stats.counts, nil, "a truncated walk reports no counts rather than low ones")
end)

return cases
