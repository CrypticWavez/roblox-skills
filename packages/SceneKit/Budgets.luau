--!strict
-- Budgets: the perf/1 budgets half (docs/runtime-kits.md "perf/1"). Two kinds of limit, kept
-- apart so a report says which kind failed:
--   DOCUMENTED  numbers Roblox publishes (source in the comment next to each);
--   CONVENTIONS factory starting points, to calibrate with MicroProfiler on a 2-4 GB Android
--               phone (about 60% of Android players have 2-4 GB, docs test-on-hardware).
-- CLASSES holds the per-device-class budgets (all conventions except where a row says so).
-- check(stats, class) compares a perf/1 stats record (Diagnostics/PerfProbe writes it) with a
-- class and returns violations; a counter missing from the stats is reported as missing, never
-- treated as 0. Keys are snake_case because Python tools read and write perf/1.
-- Consumers: Validate.dressing (light range), AVKit/Vfx (particle and light limits),
-- AVKit/AudioGraph (voices), Lighting.audit (post-processing per class).
local Budgets = {}

Budgets.SCHEMA = "perf/1"

-- Device classes are a factory convention (no Roblox taxonomy exists).
Budgets.DEVICE_CLASSES = table.freeze({ "phone_low", "phone", "tablet", "desktop", "console" })

-- Counters a perf/1 stats record carries under `counts`, plus the two top-level measures.
Budgets.COUNTERS = table.freeze({
	"instances",
	"parts",
	"triangles",
	"shadowed_lights",
	"particle_rate",
	"playing_sounds",
	"highlights",
})

Budgets.DOCUMENTED = table.freeze({
	-- PointLight/SpotLight/SurfaceLight Range clamp (DevForum 2025-09-23, "Extended light ranges").
	light_range_max = 120,
	-- One emitter: "up to 400 particles per second (100 per second on mobile)" (docs effects/particle-emitters).
	particle_rate_max = 400,
	particle_rate_mobile = 100,
	-- "maximum lifetime of 20 seconds" (same page).
	particle_lifetime_max = 20,
	-- FlipbookFramerate maximum (same page).
	flipbook_fps_max = 30,
	-- "255 simultaneous Highlight instances on the client-side" (docs effects/highlighting).
	highlights_max = 255,
	-- Baseline device: "below 1,000 draw calls and 1,000,000 triangles" (docs performance-optimization/design).
	draw_calls = 1000,
	triangles = 1000000,
	-- 60 FPS frame (same page).
	frame_ms_60fps = 16.67,
	-- Audio uploads: "less than 20 MB in size and 7 minutes in duration" (docs audio/assets).
	audio_file_mb = 20,
	audio_file_seconds = 420,
	-- 4K texture rendering with streaming fallback (DevForum 2026-01-30).
	texture_max = 4096,
	-- AudioFader.Volume range (docs classes/AudioFader).
	fader_volume_max = 3,
	-- AudioEmitter:SetDistanceAttenuation takes up to 400 points (docs classes/AudioEmitter).
	attenuation_points_max = 400,
	-- Lighting.ExposureCompensation range (docs classes/Lighting).
	exposure_min = -5,
	exposure_max = 5,
})

Budgets.CONVENTIONS = table.freeze({
	-- Light Range a dressing pass should stay under; 60 was the cap before 2025-09-23.
	light_range_budget = 60,
	-- Per room-sized volume: local lights and shadow-casting lights.
	lights_per_room = 4,
	shadowed_lights_per_room = 1,
	-- Authoring rate per emitter (the mobile figure) and peak live particles per vfx/1 preset.
	particle_rate_author = 100,
	particles_per_preset = 200,
	-- Overdraw score per preset: sum of live particles x (largest size in studs)^2.
	overdraw_per_preset = 400,
	-- Particles emitted in one burst by one emitter.
	burst_max = 100,
	-- Active Highlights (the first costs about 1 ms on mobile, docs effects/highlighting).
	highlights_active = 8,
	-- Simultaneous voices across every bus, and the hard ceiling a graph may declare.
	voices_total = 32,
	voices_ceiling = 64,
	-- Texture edge for tiling MaterialVariants and props; hero assets need a written reason.
	texture_default = 1024,
	texture_hero = 2048,
	-- Stacked transparent layers at a gameplay focus point.
	transparent_layers = 3,
	-- Owned post-processing instances a preset may enable, per device class (see CLASSES).
	post_effects = 4,
})

-- Per device class. frame_ms_p95: 33.3 is 30 FPS, 20 is 50 FPS, 16.7 is 60 FPS. triangles on
-- desktop and console is the documented baseline-device figure; every other number is a
-- convention (calibrate on hardware, docs test-on-hardware: the emulator "isn't accurate for
-- memory usage").
Budgets.CLASSES = table.freeze({
	phone_low = table.freeze({
		frame_ms_p95 = 33.3,
		instances = 30000,
		parts = 6000,
		triangles = 300000,
		shadowed_lights = 4,
		particle_rate = 300,
		playing_sounds = 16,
		highlights = 2,
		texture_mb_estimate = 192,
		memory_mb_total = 900,
		post_effects = 1,
	}),
	phone = table.freeze({
		frame_ms_p95 = 20,
		instances = 50000,
		parts = 12000,
		triangles = 600000,
		shadowed_lights = 8,
		particle_rate = 600,
		playing_sounds = 24,
		highlights = 4,
		texture_mb_estimate = 384,
		memory_mb_total = 1500,
		post_effects = 2,
	}),
	tablet = table.freeze({
		frame_ms_p95 = 20,
		instances = 60000,
		parts = 15000,
		triangles = 750000,
		shadowed_lights = 8,
		particle_rate = 800,
		playing_sounds = 32,
		highlights = 8,
		texture_mb_estimate = 512,
		memory_mb_total = 2000,
		post_effects = 3,
	}),
	desktop = table.freeze({
		frame_ms_p95 = 16.7,
		instances = 120000,
		parts = 25000,
		triangles = 1000000,
		shadowed_lights = 16,
		particle_rate = 1500,
		playing_sounds = 32,
		highlights = 8,
		texture_mb_estimate = 1024,
		memory_mb_total = 3000,
		post_effects = 4,
	}),
	console = table.freeze({
		frame_ms_p95 = 16.7,
		instances = 100000,
		parts = 25000,
		triangles = 1000000,
		shadowed_lights = 16,
		particle_rate = 1500,
		playing_sounds = 32,
		highlights = 8,
		texture_mb_estimate = 1024,
		memory_mb_total = 2500,
		post_effects = 4,
	}),
})

-- Which budget keys are documented figures (per class); every other key is a convention.
Budgets.DOCUMENTED_KEYS = table.freeze({
	desktop = table.freeze({ triangles = "docs performance-optimization/design (1,000,000 triangles)" }),
	console = table.freeze({ triangles = "docs performance-optimization/design (1,000,000 triangles)" }),
})

export type Violation = {
	counter: string,
	value: number,
	limit: number,
	kind: "documented" | "convention",
	class: string,
}

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function sortedKeys(map: { [string]: any }): { string }
	local keys = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

-- Problems with a perf/1 stats record (empty when it is well formed). Counters are optional, but
-- a present one must be a finite number >= 0.
function Budgets.validateStats(stats: any): { string }
	local problems = {}
	if type(stats) ~= "table" then
		return { "stats must be a table" }
	end
	if stats.schema ~= Budgets.SCHEMA then
		table.insert(problems, "schema must be " .. Budgets.SCHEMA)
	end
	if stats.kind ~= "stats" then
		table.insert(problems, "kind must be stats")
	end
	if not table.find(Budgets.DEVICE_CLASSES, stats.device_class) then
		table.insert(problems, "device_class " .. tostring(stats.device_class) .. " is not a known class")
	end
	if stats.counts ~= nil and type(stats.counts) ~= "table" then
		table.insert(problems, "counts must be a table")
	end
	for _, key in sortedKeys(if type(stats.counts) == "table" then stats.counts else {}) do
		local value = stats.counts[key]
		if not table.find(Budgets.COUNTERS, key) then
			table.insert(problems, "counts." .. key .. " is not a perf/1 counter")
		elseif not finite(value) or value < 0 then
			table.insert(problems, "counts." .. key .. " must be a finite number >= 0")
		end
	end
	if stats.frame_ms ~= nil then
		if type(stats.frame_ms) ~= "table" then
			table.insert(problems, "frame_ms must be a table")
		else
			for _, key in { "p50", "p95", "p99" } do
				local value = stats.frame_ms[key]
				if value ~= nil and (not finite(value) or value < 0) then
					table.insert(problems, "frame_ms." .. key .. " must be a finite number >= 0")
				end
			end
		end
	end
	if
		stats.texture_mb_estimate ~= nil
		and (not finite(stats.texture_mb_estimate) or stats.texture_mb_estimate < 0)
	then
		table.insert(problems, "texture_mb_estimate must be a finite number >= 0")
	end
	if stats.memory_mb ~= nil and type(stats.memory_mb) ~= "table" then
		table.insert(problems, "memory_mb must be a table")
	end
	return problems
end

local function kindOf(class: string, key: string): "documented" | "convention"
	local documented = Budgets.DOCUMENTED_KEYS[class]
	return if documented and documented[key] then "documented" else "convention"
end

-- Violations of one device class's budgets by a perf/1 stats record, sorted by counter, and the
-- budget counters the stats did not measure. Raises on an unknown class or malformed stats.
function Budgets.check(stats: any, class: string): ({ Violation }, { string })
	local budget = Budgets.CLASSES[class]
	if budget == nil then
		error("Budgets.check: unknown device class " .. tostring(class), 2)
	end
	local problems = Budgets.validateStats(stats)
	if #problems > 0 then
		error("Budgets.check: " .. table.concat(problems, "; "), 2)
	end
	local measured: { [string]: number } = table.clone(stats.counts or {})
	if type(stats.frame_ms) == "table" and stats.frame_ms.p95 ~= nil then
		measured.frame_ms_p95 = stats.frame_ms.p95
	end
	if stats.texture_mb_estimate ~= nil then
		measured.texture_mb_estimate = stats.texture_mb_estimate
	end
	if type(stats.memory_mb) == "table" and finite(stats.memory_mb.total) then
		measured.memory_mb_total = stats.memory_mb.total
	end
	if finite(stats.post_effects) then
		measured.post_effects = stats.post_effects
	end
	local violations: { Violation } = {}
	local missing: { string } = {}
	for _, key in sortedKeys(budget :: any) do
		local limit = (budget :: any)[key]
		local value = measured[key]
		if value == nil then
			table.insert(missing, key)
		elseif value > limit then
			table.insert(
				violations,
				{ counter = key, value = value, limit = limit, kind = kindOf(class, key), class = class }
			)
		end
	end
	return violations, missing
end

-- One line per violation, for reports and validators ("parts 7000 > 6000 (convention, phone_low)").
function Budgets.describe(violations: { Violation }): { string }
	local lines = {}
	for _, v in violations do
		table.insert(
			lines,
			string.format(
				"%s %s > %s (%s, %s)",
				v.counter,
				tostring(v.value),
				tostring(v.limit),
				v.kind,
				v.class
			)
		)
	end
	return lines
end

-- The perf/1 budgets document Python tools read (snake_case, plain tables).
function Budgets.document(): { [string]: any }
	local classes = {}
	local byClass: { [string]: { [string]: number } } = Budgets.CLASSES
	for name, limits in byClass do
		classes[name] = table.clone(limits)
	end
	local documentedKeys = {}
	local keysByClass: { [string]: { [string]: string } } = Budgets.DOCUMENTED_KEYS
	for name, keys in keysByClass do
		documentedKeys[name] = table.clone(keys)
	end
	return {
		schema = Budgets.SCHEMA,
		kind = "budgets",
		classes = classes,
		documented = table.clone(Budgets.DOCUMENTED),
		conventions = table.clone(Budgets.CONVENTIONS),
		documented_keys = documentedKeys,
	}
end

-- Problems with a budgets document (as Budgets.document() returns or a game repo edits).
function Budgets.validate(doc: any): { string }
	if type(doc) ~= "table" then
		return { "budgets must be a table" }
	end
	local problems = {}
	if doc.schema ~= Budgets.SCHEMA then
		table.insert(problems, "schema must be " .. Budgets.SCHEMA)
	end
	if doc.kind ~= "budgets" then
		table.insert(problems, "kind must be budgets")
	end
	if type(doc.classes) ~= "table" then
		table.insert(problems, "classes must be a table")
		return problems
	end
	local reference = Budgets.CLASSES.desktop
	for _, name in sortedKeys(doc.classes) do
		local limits = doc.classes[name]
		if not table.find(Budgets.DEVICE_CLASSES, name) then
			table.insert(problems, "class " .. name .. " is not a known device class")
		elseif type(limits) ~= "table" then
			table.insert(problems, "class " .. name .. " must be a table")
		else
			for _, key in sortedKeys(limits) do
				local value = limits[key]
				if (reference :: any)[key] == nil then
					table.insert(problems, name .. "." .. key .. " is not a budget counter")
				elseif not finite(value) or value <= 0 then
					table.insert(problems, name .. "." .. key .. " must be a finite number > 0")
				end
			end
		end
	end
	return problems
end

return Budgets
