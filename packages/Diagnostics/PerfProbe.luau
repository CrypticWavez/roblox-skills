--!strict
-- @tier T0
-- PerfProbe: pure aggregator for perf/1 stats (docs/runtime-kits.md section 9.7). It turns raw
-- samples into { schema = "perf/1", kind = "stats", device_class, frame_ms = { p50, p95, p99 },
-- memory_mb = { total, [category] = mb }, counts = { ... }, texture_mb_estimate?, source = { place,
-- scene_hash?, studio_version? } } and validates and compares such tables. A missing counter is
-- absent, never 0. Percentiles use the nearest-rank method (sorted ascending, rank ceil(p/100 * n)),
-- so they are always observed samples. Device classes are a convention, not a Roblox list.
-- No requires and no Roblox globals: PerfProbeRoblox reads the engine and calls build().
local PerfProbe = {}

PerfProbe.SCHEMA = "perf/1"
-- Convention (docs/runtime-kits.md 9.7), calibrated later on real devices.
PerfProbe.DEVICE_CLASSES = table.freeze({ "phone_low", "phone", "tablet", "desktop", "console" })
PerfProbe.COUNTERS = table.freeze({
	"instances",
	"parts",
	"triangles",
	"shadowed_lights",
	"particle_rate",
	"playing_sounds",
	"highlights",
})
PerfProbe.MAX_SAMPLES = 100000

local LABEL = "^[a-z][a-z0-9_]*$"

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function wholeNonNegative(value: any): boolean
	return finite(value) and value >= 0 and value % 1 == 0
end

local function isLabel(value: any): boolean
	return type(value) == "string" and #value <= 64 and string.match(value, LABEL) ~= nil
end

local function known(list: { string }, value: any): boolean
	return table.find(list, value) ~= nil
end

-- Nearest-rank percentile of finite samples; nil for an empty list. p in (0, 100].
function PerfProbe.percentile(samples: { number }, p: number): number?
	assert(finite(p) and p > 0 and p <= 100, "PerfProbe.percentile: p must be in (0, 100]")
	if #samples == 0 then
		return nil
	end
	local sorted = table.clone(samples)
	table.sort(sorted)
	local rank = math.max(1, math.ceil(p / 100 * #sorted))
	return sorted[rank]
end

-- { p50, p95, p99 } of frame times in milliseconds, or nil without samples. Raises on a
-- non-finite or negative sample (a broken clock must not average away).
function PerfProbe.frameStats(samplesMs: { number }): { p50: number, p95: number, p99: number }?
	assert(type(samplesMs) == "table", "PerfProbe.frameStats: samples must be a list")
	assert(#samplesMs <= PerfProbe.MAX_SAMPLES, "PerfProbe.frameStats: too many samples")
	for index, value in samplesMs do
		assert(
			finite(value) and value >= 0,
			"PerfProbe.frameStats: sample " .. index .. " is not a finite ms >= 0"
		)
	end
	if #samplesMs == 0 then
		return nil
	end
	return {
		p50 = PerfProbe.percentile(samplesMs, 50) :: number,
		p95 = PerfProbe.percentile(samplesMs, 95) :: number,
		p99 = PerfProbe.percentile(samplesMs, 99) :: number,
	}
end

-- Problems with a perf/1 stats table (empty when valid).
function PerfProbe.validate(stats: any): { string }
	if type(stats) ~= "table" then
		return { "stats must be a table" }
	end
	local problems = {}
	local function add(text: string)
		table.insert(problems, text)
	end
	if stats.schema ~= PerfProbe.SCHEMA then
		add("schema must be perf/1")
	end
	if stats.kind ~= "stats" then
		add("kind must be stats")
	end
	if not known(PerfProbe.DEVICE_CLASSES, stats.device_class) then
		add("device_class must be one of " .. table.concat(PerfProbe.DEVICE_CLASSES, ", "))
	end
	local frame = stats.frame_ms
	if frame ~= nil then
		if type(frame) ~= "table" then
			add("frame_ms must be a table")
		else
			for _, key in { "p50", "p95", "p99" } do
				if not (finite(frame[key]) and frame[key] >= 0) then
					add("frame_ms." .. key .. " must be a finite number >= 0")
				end
			end
			for key in frame do
				if key ~= "p50" and key ~= "p95" and key ~= "p99" then
					add("frame_ms has an unknown key " .. tostring(key))
				end
			end
			if
				finite(frame.p50)
				and finite(frame.p95)
				and finite(frame.p99)
				and not (frame.p50 <= frame.p95 and frame.p95 <= frame.p99)
			then
				add("frame_ms must satisfy p50 <= p95 <= p99")
			end
		end
	end
	local memory = stats.memory_mb
	if memory ~= nil then
		if type(memory) ~= "table" then
			add("memory_mb must be a table")
		else
			if not (finite(memory.total) and memory.total >= 0) then
				add("memory_mb.total must be a finite number >= 0")
			end
			for key, value in memory do
				if not isLabel(key) then
					add("memory_mb key " .. tostring(key) .. " must be a lower_snake label")
				elseif not (finite(value) and value >= 0) then
					add("memory_mb." .. key .. " must be a finite number >= 0")
				end
			end
		end
	end
	local counts = stats.counts
	if counts ~= nil then
		if type(counts) ~= "table" then
			add("counts must be a table")
		else
			for key, value in counts do
				if not known(PerfProbe.COUNTERS, key) then
					add("counts has an unknown counter " .. tostring(key))
				elseif key == "particle_rate" then
					if not (finite(value) and value >= 0) then
						add("counts.particle_rate must be a finite number >= 0")
					end
				elseif not wholeNonNegative(value) then
					add("counts." .. key .. " must be a whole number >= 0")
				end
			end
		end
	end
	local texture = stats.texture_mb_estimate
	if texture ~= nil and not (finite(texture) and texture >= 0) then
		add("texture_mb_estimate must be a finite number >= 0")
	end
	local source = stats.source
	if type(source) ~= "table" then
		add("source must be a table with place")
	else
		if type(source.place) ~= "string" or #source.place == 0 or #source.place > 128 then
			add("source.place must be a non-empty string of at most 128 characters")
		end
		for _, key in { "scene_hash", "studio_version" } do
			if source[key] ~= nil and (type(source[key]) ~= "string" or #source[key] > 64) then
				add("source." .. key .. " must be a string of at most 64 characters")
			end
		end
	end
	for key in stats do
		if
			not known(
				{
					"schema",
					"kind",
					"device_class",
					"frame_ms",
					"memory_mb",
					"counts",
					"texture_mb_estimate",
					"source",
				},
				key
			)
		then
			add("unknown key " .. tostring(key))
		end
	end
	return problems
end

export type BuildInput = {
	deviceClass: string,
	frameSamplesMs: { number }?,
	memory: { [string]: number }?, -- must include total when present
	counts: { [string]: number }?,
	textureMbEstimate: number?,
	source: { place: string, sceneHash: string?, studioVersion: string? },
}

-- Builds and validates a perf/1 stats table; raises listing every problem.
function PerfProbe.build(input: BuildInput): { [string]: any }
	assert(type(input) == "table", "PerfProbe.build: input must be a table")
	local source = input.source or ({} :: any)
	local stats: { [string]: any } = {
		schema = PerfProbe.SCHEMA,
		kind = "stats",
		device_class = input.deviceClass,
		source = {
			place = source.place,
			scene_hash = source.sceneHash,
			studio_version = source.studioVersion,
		},
	}
	if input.frameSamplesMs then
		stats.frame_ms = PerfProbe.frameStats(input.frameSamplesMs)
	end
	if input.memory then
		stats.memory_mb = table.clone(input.memory)
	end
	if input.counts then
		stats.counts = table.clone(input.counts)
	end
	stats.texture_mb_estimate = input.textureMbEstimate
	local problems = PerfProbe.validate(stats)
	if #problems > 0 then
		error("PerfProbe.build: " .. table.concat(problems, "; "), 2)
	end
	return stats
end

-- An incremental collector for adapters: frame(ms), memory(category, mb), count(counter, n),
-- then build(deviceClass, source). Samples beyond MAX_SAMPLES are dropped and counted.
function PerfProbe.collector(): any
	local samples: { number } = {}
	local memory: { [string]: number } = {}
	local counts: { [string]: number } = {}
	local self: any = { dropped = 0 }
	function self.frame(_: any, ms: number)
		assert(finite(ms) and ms >= 0, "PerfProbe collector: frame ms must be finite and >= 0")
		if #samples >= PerfProbe.MAX_SAMPLES then
			self.dropped += 1
			return
		end
		table.insert(samples, ms)
	end
	function self.memory(_: any, category: string, mb: number)
		assert(category == "total" or isLabel(category), "PerfProbe collector: category must be a label")
		assert(finite(mb) and mb >= 0, "PerfProbe collector: memory mb must be finite and >= 0")
		memory[category] = mb
	end
	function self.count(_: any, counter: string, value: number)
		assert(
			known(PerfProbe.COUNTERS, counter),
			"PerfProbe collector: unknown counter " .. tostring(counter)
		)
		counts[counter] = value
	end
	function self.samples(_: any): number
		return #samples
	end
	function self.build(
		_: any,
		deviceClass: string,
		source: any,
		textureMbEstimate: number?
	): { [string]: any }
		return PerfProbe.build({
			deviceClass = deviceClass,
			frameSamplesMs = if #samples > 0 then samples else nil,
			memory = if next(memory) ~= nil then memory else nil,
			counts = if next(counts) ~= nil then counts else nil,
			textureMbEstimate = textureMbEstimate,
			source = source,
		})
	end
	return self
end

-- Differences after - before for every number present in both (before/after evidence for the
-- performance pass). Absent on either side stays absent.
function PerfProbe.compare(before: any, after: any): { [string]: any }
	local delta: { [string]: any } = {}
	for _, group in { "frame_ms", "memory_mb", "counts" } do
		local a, b = before[group], after[group]
		if type(a) == "table" and type(b) == "table" then
			local out = {}
			for key, value in b do
				if finite(value) and finite(a[key]) then
					out[key] = value - a[key]
				end
			end
			if next(out) ~= nil then
				delta[group] = out
			end
		end
	end
	if finite(before.texture_mb_estimate) and finite(after.texture_mb_estimate) then
		delta.texture_mb_estimate = after.texture_mb_estimate - before.texture_mb_estimate
	end
	return delta
end

-- Lower snake name for a memory category such as an Enum.DeveloperMemoryTag item name
-- ("GraphicsTexture" -> "graphics_texture", "LuaHeap" -> "lua_heap").
function PerfProbe.categoryName(name: string): string
	local spaced = string.gsub(name, "(%l)(%u)", "%1_%2")
	spaced = string.gsub(spaced, "(%u)(%u%l)", "%1_%2")
	local lowered = string.lower(string.gsub(spaced, "[^%w_]", "_"))
	return lowered
end

return PerfProbe
