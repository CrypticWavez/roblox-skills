--!strict
-- @tier T0
-- AudioCues: data-defined sound cues and voice admission for the audio-graph/1 mixer.
-- A cue: { bus, slot, volume, pitchVariance, cooldown, maxConcurrent, priority, spatial, loop,
-- autoLoad, caption }. `slot` is a provenance key the game maps to approved audio (assets table);
-- no asset ids live here, and an unmapped slot is reported as missing_asset (never silence that
-- looks like success). request() admits a voice or says why not: unknown_cue, missing_asset,
-- cooldown, max_concurrent, voices (bus or total cap reached and nothing of lower priority to
-- steal). Random volume and pitch come from a seeded ProcGen/Rng, so the same seed and calls give
-- the same voices. activity() counts voices per bus including child buses, which is what
-- AudioGraph ducking reads.
local Rng = require("../ProcGen/Rng")

local AudioCues = {}

AudioCues.VOLUME_MAX = 2 -- convention (AudioPlayer.Volume allows 0-10)
AudioCues.PITCH_VARIANCE_MAX = 0.5 -- convention
AudioCues.MAX_CONCURRENT_MAX = 16 -- convention

local CUE_KEYS = {
	bus = true,
	slot = true,
	volume = true,
	pitchVariance = true,
	cooldown = true,
	maxConcurrent = true,
	priority = true,
	spatial = true,
	loop = true,
	autoLoad = true,
	caption = true,
}

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function label(value: any): boolean
	return type(value) == "string" and #value <= 64 and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function sortedKeys(map: any): { string }
	local keys = {}
	for key in map do
		table.insert(keys, tostring(key))
	end
	table.sort(keys)
	return keys
end

local function cue(bus: string, priority: number, extra: { [string]: any }?): any
	local result: any = {
		bus = bus,
		volume = 1,
		pitchVariance = 0,
		cooldown = 0.03,
		maxConcurrent = 4,
		priority = priority,
		spatial = false,
		loop = false,
	}
	for key, value in extra or {} do
		result[key] = value
	end
	return result
end

-- Neutral default cues, named by function. Slots default to "sfx_<cue id>"; the game maps them.
-- VfxLibrary presets and Feel cues name these ids.
local DEFAULTS: { [string]: any } = {
	ui_click = cue("ui", 3, { cooldown = 0.05, maxConcurrent = 2 }),
	ui_hover = cue("ui", 1, { volume = 0.5, cooldown = 0.08, maxConcurrent = 1 }),
	ui_confirm = cue("ui", 4, { maxConcurrent = 2 }),
	ui_cancel = cue("ui", 4, { maxConcurrent = 2 }),
	ui_error = cue("ui", 5, { cooldown = 0.2, maxConcurrent = 1 }),
	ui_notify = cue("ui", 5, { cooldown = 0.25, maxConcurrent = 1 }),
	hit_light = cue("sfx", 5, { volume = { 0.8, 1 }, pitchVariance = 0.08, maxConcurrent = 6 }),
	hit_heavy = cue("sfx", 7, { volume = { 0.9, 1 }, pitchVariance = 0.05, maxConcurrent = 3 }),
	impact_soft = cue("sfx", 3, { volume = { 0.6, 0.8 }, pitchVariance = 0.1, maxConcurrent = 4 }),
	heal = cue("sfx", 5, { cooldown = 0.2, maxConcurrent = 2 }),
	pickup = cue("sfx", 4, { volume = { 0.8, 1 }, pitchVariance = 0.06, cooldown = 0.05, maxConcurrent = 4 }),
	level_up = cue("sfx", 8, { cooldown = 1, maxConcurrent = 1 }),
	reward = cue("sfx", 6, { cooldown = 0.2, maxConcurrent = 2 }),
	celebrate = cue("sfx", 4, { cooldown = 1, maxConcurrent = 1 }),
	whoosh = cue("sfx", 3, { volume = { 0.6, 0.8 }, pitchVariance = 0.12, maxConcurrent = 4 }),
	shot = cue("sfx", 6, { volume = { 0.85, 1 }, pitchVariance = 0.05, maxConcurrent = 6 }),
	explosion = cue("sfx", 8, { volume = { 0.9, 1 }, pitchVariance = 0.06, maxConcurrent = 3 }),
	splash = cue("sfx", 3, { pitchVariance = 0.1, maxConcurrent = 3 }),
	shield_up = cue("sfx", 6, { cooldown = 0.3, maxConcurrent = 2 }),
	teleport = cue("sfx", 6, { cooldown = 0.3, maxConcurrent = 2 }),
	spawn = cue("sfx", 5, { maxConcurrent = 3 }),
	despawn = cue("sfx", 4, { maxConcurrent = 3 }),
	status_tick = cue("sfx", 4, { volume = 0.7, cooldown = 0.1, maxConcurrent = 3 }),
	charge = cue("sfx", 6, { loop = true, maxConcurrent = 2 }),
	aura_hum = cue("sfx", 3, { loop = true, volume = 0.5, maxConcurrent = 2, autoLoad = false }),
	footstep = cue(
		"world",
		2,
		{ spatial = true, volume = { 0.5, 0.7 }, pitchVariance = 0.12, cooldown = 0.08, maxConcurrent = 6 }
	),
	ambience_bed = cue("ambience", 2, { loop = true, volume = 0.6, maxConcurrent = 2, autoLoad = false }),
	dialogue_line = cue("dialogue", 9, { cooldown = 0, maxConcurrent = 1, caption = "dialogue_line" }),
}
for id, definition in DEFAULTS do
	definition.slot = "sfx_" .. id
end
AudioCues.DEFAULTS = DEFAULTS

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, child in value do
		out[key] = copy(child)
	end
	return out
end

-- Deep copy of the default cue table.
function AudioCues.defaults(): { [string]: any }
	return copy(DEFAULTS)
end

local function isUnder(graph: any, bus: string, root: string): boolean
	local current: string? = bus
	local guard = 0
	while current ~= nil and guard < 64 do
		if current == root then
			return true
		end
		local node = graph.buses[current]
		current = node and node.parent
		guard += 1
	end
	return false
end

-- Problems with a cue table (empty when valid). With a graph, buses must exist and spatial cues
-- must sit on world or a bus under it (3D sound reaches the mix through the world listener).
function AudioCues.validate(cues: any, graph: any?): { string }
	local problems = {}
	if type(cues) ~= "table" then
		return { "cues must be a table" }
	end
	for _, id in sortedKeys(cues) do
		local definition = cues[id]
		local where = "cue " .. id
		if not label(id) then
			table.insert(problems, where .. ": id must be a label")
		end
		if type(definition) ~= "table" then
			table.insert(problems, where .. " must be a table")
			continue
		end
		for _, key in sortedKeys(definition) do
			if not CUE_KEYS[key] then
				table.insert(problems, where .. ": " .. key .. " is not a cue field")
			end
		end
		if not label(definition.bus) then
			table.insert(problems, where .. ".bus must be a bus name")
		elseif definition.bus == "master" then
			table.insert(problems, where .. " cannot play on master (use a standard bus)")
		elseif graph ~= nil and graph.buses[definition.bus] == nil then
			table.insert(problems, where .. ".bus " .. definition.bus .. " is not in the graph")
		end
		if not label(definition.slot) then
			table.insert(problems, where .. ".slot must be a provenance key label (no asset ids)")
		end
		local volume = definition.volume
		if type(volume) == "table" then
			if
				#volume ~= 2
				or not finite(volume[1])
				or not finite(volume[2])
				or volume[1] > volume[2]
				or volume[1] < 0
				or volume[2] > AudioCues.VOLUME_MAX
			then
				table.insert(problems, where .. ".volume range must be { min, max } within 0..2")
			end
		elseif volume ~= nil and not (finite(volume) and volume >= 0 and volume <= AudioCues.VOLUME_MAX) then
			table.insert(problems, where .. ".volume must be within 0..2")
		end
		local variance = definition.pitchVariance
		if
			variance ~= nil
			and not (finite(variance) and variance >= 0 and variance <= AudioCues.PITCH_VARIANCE_MAX)
		then
			table.insert(problems, where .. ".pitchVariance must be within 0..0.5")
		end
		local cooldown = definition.cooldown
		if cooldown ~= nil and not (finite(cooldown) and cooldown >= 0 and cooldown <= 10) then
			table.insert(problems, where .. ".cooldown must be within 0..10 s")
		end
		local maxConcurrent = definition.maxConcurrent
		if
			maxConcurrent ~= nil
			and not (
				finite(maxConcurrent)
				and maxConcurrent % 1 == 0
				and maxConcurrent >= 1
				and maxConcurrent <= AudioCues.MAX_CONCURRENT_MAX
			)
		then
			table.insert(problems, where .. ".maxConcurrent must be a whole number 1..16")
		end
		local priority = definition.priority
		if
			priority ~= nil
			and not (finite(priority) and priority % 1 == 0 and priority >= 0 and priority <= 10)
		then
			table.insert(problems, where .. ".priority must be a whole number 0..10")
		end
		for _, key in { "spatial", "loop", "autoLoad" } do
			if definition[key] ~= nil and type(definition[key]) ~= "boolean" then
				table.insert(problems, where .. "." .. key .. " must be a boolean")
			end
		end
		if definition.caption ~= nil and not label(definition.caption) then
			table.insert(problems, where .. ".caption must be a localisation key label")
		end
		if
			definition.spatial == true
			and graph ~= nil
			and label(definition.bus)
			and graph.buses[definition.bus] ~= nil
			and not isUnder(graph, definition.bus, "world")
		then
			table.insert(problems, where .. " is spatial, so its bus must be world or under it")
		end
	end
	return problems
end

export type Voice = {
	id: number,
	cue: string,
	bus: string,
	slot: string,
	volume: number,
	speed: number,
	loop: boolean,
	spatial: boolean,
	priority: number,
	started: number,
	content: string?,
}

export type Options = {
	graph: any?,
	assets: { [string]: string }?,
	seed: (number | string)?,
}

function AudioCues.new(cues: { [string]: any }, options: Options?)
	local opts: any = options or {}
	local problems = AudioCues.validate(cues, opts.graph)
	assert(#problems == 0, "AudioCues: " .. table.concat(problems, "; "))
	local definitions = copy(cues)
	local graph = opts.graph
	local caps: { [string]: number } = if graph and graph.voices then graph.voices else {}
	local rng = Rng.new(opts.seed or "audio-cues")
	local voices: { [number]: Voice } = {}
	local lastStart: { [string]: number } = {}
	local serial = 0
	local counters = { admitted = 0, refused = 0, stolen = 0 }
	local api = {}

	local function sortedVoices(): { Voice }
		local list = {}
		for _, voice in voices do
			table.insert(list, voice)
		end
		table.sort(list, function(a, b)
			return a.id < b.id
		end)
		return list
	end

	-- The weakest voice (lowest priority, then oldest) below `priority`, optionally on one bus.
	local function victim(priority: number, bus: string?): Voice?
		local weakest: Voice? = nil
		for _, voice in sortedVoices() do
			if (bus == nil or voice.bus == bus) and voice.priority < priority then
				if weakest == nil or voice.priority < weakest.priority then
					weakest = voice
				end
			end
		end
		return weakest
	end

	local function count(predicate: (Voice) -> boolean): number
		local total = 0
		for _, voice in voices do
			if predicate(voice) then
				total += 1
			end
		end
		return total
	end

	-- Admits one voice of `id` at time `now` (seconds). Returns (voice, stolen voices) or
	-- (nil, reason). The caller stops every stolen voice and later calls release(voice.id).
	function api:request(id: string, now: number): (Voice?, any)
		assert(finite(now), "AudioCues: now must be a finite number")
		local definition = definitions[id]
		local function refuse(reason: string): (nil, string)
			counters.refused += 1
			return nil, reason
		end
		if definition == nil then
			return refuse("unknown_cue")
		end
		local content = nil
		if opts.assets ~= nil then
			content = opts.assets[definition.slot]
			if type(content) ~= "string" or content == "" then
				return refuse("missing_asset")
			end
		end
		local cooldown = definition.cooldown or 0
		if lastStart[id] ~= nil and now - lastStart[id] < cooldown then
			return refuse("cooldown")
		end
		local maxConcurrent = definition.maxConcurrent or 4
		if count(function(voice)
			return voice.cue == id
		end) >= maxConcurrent then
			return refuse("max_concurrent")
		end
		local priority = definition.priority or 5
		local stolen = {}
		local busCap = caps[definition.bus]
		if busCap ~= nil and count(function(voice)
			return voice.bus == definition.bus
		end) >= busCap then
			local weakest = victim(priority, definition.bus)
			if weakest == nil then
				return refuse("voices")
			end
			table.insert(stolen, weakest)
		end
		local totalCap = caps.total
		if totalCap ~= nil then
			local live = 0
			for _, voice in voices do
				if not table.find(stolen, voice) then
					live += 1
				end
			end
			if live >= totalCap then
				local weakest = nil
				for _, voice in sortedVoices() do
					if
						not table.find(stolen, voice)
						and voice.priority < priority
						and (weakest == nil or voice.priority < weakest.priority)
					then
						weakest = voice
					end
				end
				if weakest == nil then
					return refuse("voices")
				end
				table.insert(stolen, weakest)
			end
		end
		for _, voice in stolen do
			voices[voice.id] = nil
			counters.stolen += 1
		end
		local volume = definition.volume or 1
		if type(volume) == "table" then
			volume = rng:range(volume[1], volume[2])
		end
		local variance = definition.pitchVariance or 0
		local speed = if variance > 0 then 1 + rng:range(-variance, variance) else 1
		serial += 1
		local voice: Voice = {
			id = serial,
			cue = id,
			bus = definition.bus,
			slot = definition.slot,
			volume = volume,
			speed = speed,
			loop = definition.loop == true,
			spatial = definition.spatial == true,
			priority = priority,
			started = now,
			content = content,
		}
		voices[serial] = voice
		lastStart[id] = now
		counters.admitted += 1
		return voice, stolen
	end

	-- Ends a voice (finished, stopped or stolen elsewhere). False when it is not active.
	function api:release(voiceId: number): boolean
		if voices[voiceId] == nil then
			return false
		end
		voices[voiceId] = nil
		return true
	end

	-- Active voices per bus; a voice also counts on every ancestor bus when a graph is known.
	function api:activity(): { [string]: number }
		local result = {}
		for _, voice in voices do
			local bus: string? = voice.bus
			local guard = 0
			while bus ~= nil and guard < 64 do
				result[bus] = (result[bus] or 0) + 1
				local node = graph and graph.buses[bus]
				bus = node and node.parent
				guard += 1
			end
		end
		return result
	end

	function api:active(): { Voice }
		return sortedVoices()
	end

	function api:cue(id: string): any
		return copy(definitions[id])
	end

	function api:stats(): any
		local result: any = table.clone(counters)
		result.active = count(function()
			return true
		end)
		return result
	end

	return api
end

return AudioCues
