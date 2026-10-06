--!strict
-- @tier T3
-- probe: perf_capture
-- PerfProbeRoblox: reads the engine into a perf/1 stats table through PerfProbe. Services come
-- from env.services (Stats, RunService, Workspace) and Roblox datatypes from env.roblox, so the
-- mapping runs in Lune against fakes; the real engine reading is the perf_capture probe.
--   memory_mb  Stats:GetTotalMemoryUsageMb() and GetMemoryUsageMbForTag per DeveloperMemoryTag
--   counts     instances = Stats.InstanceCount; parts, shadowed_lights, particle_rate,
--              playing_sounds and highlights from a bounded walk of the root (default Workspace);
--              triangles = Stats.SceneTriangleCount where the engine exposes it (client render)
--   frame_ms   Heartbeat step times over `frames` steps, ended early at `timeout` seconds
-- Stats member names are UNVERIFIED until perf_capture has run; any read that fails leaves that
-- counter absent (never 0). Read-only: it creates, changes and uploads nothing.
local PerfProbe = require("./PerfProbe")

local PerfProbeRoblox = {}

PerfProbeRoblox.WALK_LIMIT = 200000

export type Options = {
	deviceClass: string?, -- default "desktop" (Studio on a PC)
	place: string?, -- label for source.place (default "diagnostic")
	sceneHash: string?,
	studioVersion: string?,
	frames: number?, -- Heartbeat samples to take (default 0: no frame timing)
	timeout: number?, -- seconds to wait for frames (default 5)
	now: (() -> number)?, -- wall clock for the timeout (default os.clock; Studio Edit mode has no game time)
	poll: number?, -- seconds between sample checks while waiting (default 1/60; must be > 0)
	root: any?, -- instance whose descendants are counted (default Workspace)
	memoryTags: { any }?, -- DeveloperMemoryTag items (default env.roblox.Enum.DeveloperMemoryTag:GetEnumItems())
}

local function read(object: any, key: string): any
	local ok, value = pcall(function()
		return object[key]
	end)
	return if ok then value else nil
end

local function call(object: any, method: string, ...: any): any
	local args = table.pack(...)
	local ok, value = pcall(function()
		return object[method](object, table.unpack(args, 1, args.n))
	end)
	return if ok then value else nil
end

local function isA(instance: any, className: string): boolean
	local ok, result = pcall(function()
		return instance:IsA(className)
	end)
	return ok and result == true
end

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

-- Counts from one bounded walk of root's descendants. Returns counts and whether it was truncated.
function PerfProbeRoblox.walk(root: any, limit: number?): ({ [string]: number }, boolean)
	local cap = limit or PerfProbeRoblox.WALK_LIMIT
	local descendants = call(root, "GetDescendants") or {}
	local counts = { parts = 0, shadowed_lights = 0, particle_rate = 0, playing_sounds = 0, highlights = 0 }
	local truncated = #descendants > cap
	for index, instance in descendants do
		if index > cap then
			break
		end
		if isA(instance, "BasePart") then
			counts.parts += 1
		elseif isA(instance, "Light") then
			if read(instance, "Shadows") == true and read(instance, "Enabled") ~= false then
				counts.shadowed_lights += 1
			end
		elseif isA(instance, "ParticleEmitter") then
			local rate = read(instance, "Rate")
			if read(instance, "Enabled") ~= false and finite(rate) and rate > 0 then
				counts.particle_rate += rate
			end
		elseif isA(instance, "Sound") or isA(instance, "AudioPlayer") then
			if read(instance, "IsPlaying") == true then
				counts.playing_sounds += 1
			end
		elseif isA(instance, "Highlight") then
			if read(instance, "Enabled") ~= false then
				counts.highlights += 1
			end
		end
	end
	return counts, truncated
end

-- Memory categories: total plus one lower_snake key per tag that reads as a finite number.
function PerfProbeRoblox.memory(stats: any, tags: { any }): { [string]: number }
	local memory: { [string]: number } = {}
	local total = call(stats, "GetTotalMemoryUsageMb")
	if finite(total) and total >= 0 then
		memory.total = total
	end
	for _, tag in tags do
		local mb = call(stats, "GetMemoryUsageMbForTag", tag)
		local name = read(tag, "Name")
		if type(name) == "string" and finite(mb) and mb >= 0 then
			memory[PerfProbe.categoryName(name)] = mb
		end
	end
	return memory
end

-- Heartbeat step times in ms, at most `frames`, waiting at most `timeout` seconds of `now()` and
-- checking every `poll` seconds (env.wait; a positive poll so a scheduler never spins on wait(0)).
-- Yields; never call it from a simulation step.
function PerfProbeRoblox.frames(
	runService: any,
	frames: number,
	timeout: number,
	now: () -> number,
	env: any,
	poll: number?
): { number }
	local interval = poll or 1 / 60
	assert(finite(interval) and interval > 0, "PerfProbeRoblox.frames: poll must be a positive number")
	local samples: { number } = {}
	if frames <= 0 then
		return samples
	end
	local heartbeat = read(runService, "Heartbeat")
	if heartbeat == nil then
		return samples
	end
	local connection = call(heartbeat, "Connect", function(dt: number)
		if #samples < frames and finite(dt) and dt >= 0 then
			table.insert(samples, dt * 1000)
		end
	end)
	local started = now()
	while #samples < frames and now() - started < timeout do
		env.wait(interval)
	end
	if connection then
		call(connection, "Disconnect")
	end
	return samples
end

-- Captures one perf/1 stats table. Raises (PerfProbe.build) if the result is invalid.
function PerfProbeRoblox.capture(env: any, options: Options?): { [string]: any }
	local opts: Options = options or {}
	local services = env.services
	local stats = services.Stats
	assert(stats ~= nil, "PerfProbeRoblox: env.services.Stats is missing")
	local tags = opts.memoryTags
	if tags == nil then
		local enum = env.roblox and env.roblox.Enum
		local tagEnum = enum and read(enum, "DeveloperMemoryTag")
		tags = (tagEnum and call(tagEnum, "GetEnumItems")) or {}
	end
	local collector = PerfProbe.collector()
	for category, mb in PerfProbeRoblox.memory(stats, tags :: { any }) do
		collector:memory(category, mb)
	end
	local instances = read(stats, "InstanceCount")
	if finite(instances) and instances >= 0 then
		collector:count("instances", math.floor(instances))
	end
	local triangles = read(stats, "SceneTriangleCount")
	if finite(triangles) and triangles >= 0 then
		collector:count("triangles", math.floor(triangles))
	end
	local root = opts.root or services.Workspace
	if root ~= nil then
		local counts, truncated = PerfProbeRoblox.walk(root)
		if not truncated then
			for counter, value in counts do
				collector:count(counter, value)
			end
		end
	end
	local runService = services.RunService
	if runService ~= nil and (opts.frames or 0) > 0 then
		local now = opts.now or os.clock
		local timeout = opts.timeout or 5
		for _, ms in PerfProbeRoblox.frames(runService, opts.frames :: number, timeout, now, env, opts.poll) do
			collector:frame(ms)
		end
	end
	return collector:build(opts.deviceClass or "desktop", {
		place = opts.place or "diagnostic",
		sceneHash = opts.sceneHash,
		studioVersion = opts.studioVersion,
	})
end

return PerfProbeRoblox
