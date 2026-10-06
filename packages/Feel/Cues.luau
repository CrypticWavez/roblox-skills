--!strict
-- @tier T0
-- Cues: one data-defined feedback moment fired across every channel at once: VFX (an AVKit
-- VfxLibrary preset id), sound (an AVKit AudioCues id), camera shake, hit-stop, haptics, a
-- screen flash or tint, and a popup. Sinks are functions the caller passes (FeelRoblox wires
-- them to VfxPoolRoblox, AudioGraphRoblox, Shake, HitStop, Haptics, Screen and Popups), so this
-- module never touches the engine.
-- Rules (validate): a cue with a sound must also have a visual channel (vfx, flash, tint, popup,
-- caption or `visual`, the name of a visual the caller already shows, e.g. "ui" or
-- "animation") - accessibility: never audio alone. Values are in range and ids known when lists
-- are given. Per frame at most `budget` cues fire (convention 6); higher priorities win the slots.
--   Cues.validate(cues, known?) -> problems
--   Cues.new(cues, sinks, options?) -> cues;  cues:fire(id, context?) -> (channels?, reason?)
--   cues:frame() starts a new frame;  cues:bindMarkers(track, { Marker = cueId }, context?)
local Cues = {}

Cues.BUDGET = 6 -- cues per frame (convention)
Cues.HIT_STOP_MAX = 0.2 -- mirrors Feel/HitStop.MAX
Cues.CHANNELS = table.freeze({ "vfx", "sound", "shake", "hitStop", "haptic", "flash", "tint", "popup" })

local KEYS = {
	vfx = true,
	sound = true,
	shake = true,
	hitStop = true,
	haptic = true,
	flash = true,
	tint = true,
	popup = true,
	caption = true,
	visual = true,
	priority = true,
}
local VISUAL = { "vfx", "flash", "tint", "popup", "caption", "visual" }
local SHAKE_PRESETS = { "hit_light", "hit_heavy", "blast", "land", "rumble" }
local HAPTIC_TYPES = { "UIClick", "GameplayCollision", "GameplayExplosion", "Custom" }

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

local function knows(list: any, id: string): boolean
	if list == nil then
		return true
	end
	if list[id] ~= nil then
		return true
	end
	return table.find(list, id) ~= nil
end

-- Neutral default cues by function; ids match AVKit VfxLibrary presets and AudioCues cues.
local DEFAULTS: { [string]: any } = {
	hit_light = {
		vfx = "hit_spark",
		sound = "hit_light",
		shake = "hit_light",
		hitStop = 0.03,
		haptic = "GameplayCollision",
		priority = 5,
	},
	hit_heavy = {
		vfx = "hit_spark",
		sound = "hit_heavy",
		shake = "hit_heavy",
		hitStop = 0.08,
		haptic = "GameplayCollision",
		flash = { intensity = 0.15, duration = 0.08 },
		priority = 7,
	},
	blast = {
		vfx = "explosion_small",
		sound = "explosion",
		shake = "blast",
		hitStop = 0.05,
		haptic = "GameplayExplosion",
		flash = { intensity = 0.3, duration = 0.15 },
		priority = 8,
	},
	land = { vfx = "impact_dust", sound = "impact_soft", shake = "land", priority = 3 },
	pickup = { vfx = "pickup_sparkle", sound = "pickup", popup = { kind = "pickup" }, priority = 4 },
	heal = { vfx = "heal_glow", sound = "heal", popup = { kind = "heal" }, priority = 5 },
	reward = { vfx = "reward_burst", sound = "reward", popup = { kind = "reward" }, priority = 6 },
	level_up = {
		vfx = "levelup_burst",
		sound = "level_up",
		tint = { amount = 0.25, duration = 0.8 },
		haptic = "UIClick",
		priority = 8,
	},
	ui_confirm = { sound = "ui_confirm", visual = "ui", haptic = "UIClick", priority = 4 },
	ui_error = { sound = "ui_error", visual = "ui", priority = 5 },
}
Cues.DEFAULTS = DEFAULTS

export type Known = { vfx: any?, sounds: any? }

function Cues.validate(cues: any, known: Known?): { string }
	local problems = {}
	if type(cues) ~= "table" then
		return { "cues must be a table" }
	end
	local lists: any = known or {}
	for _, id in sortedKeys(cues) do
		local cue = cues[id]
		local where = "cue " .. id
		if not label(id) then
			table.insert(problems, where .. ": id must be a label")
		end
		if type(cue) ~= "table" then
			table.insert(problems, where .. " must be a table")
			continue
		end
		for _, key in sortedKeys(cue) do
			if not KEYS[key] then
				table.insert(problems, where .. ": " .. key .. " is not a cue field")
			end
		end
		local channels = 0
		for _, channel in Cues.CHANNELS do
			if cue[channel] ~= nil then
				channels += 1
			end
		end
		if channels == 0 then
			table.insert(problems, where .. " fires nothing")
		end
		if cue.sound ~= nil then
			local visual = false
			for _, key in VISUAL do
				if cue[key] ~= nil then
					visual = true
				end
			end
			if not visual then
				table.insert(problems, where .. " has a sound but no visual channel (never audio alone)")
			end
			if not label(cue.sound) then
				table.insert(problems, where .. ".sound must be an AudioCues id")
			elseif not knows(lists.sounds, cue.sound) then
				table.insert(problems, where .. ".sound " .. cue.sound .. " is not a known cue")
			end
		end
		if cue.vfx ~= nil then
			if not label(cue.vfx) then
				table.insert(problems, where .. ".vfx must be a VfxLibrary preset id")
			elseif not knows(lists.vfx, cue.vfx) then
				table.insert(problems, where .. ".vfx " .. cue.vfx .. " is not a known preset")
			end
		end
		local shake = cue.shake
		if shake ~= nil then
			if type(shake) == "string" then
				if not table.find(SHAKE_PRESETS, shake) then
					table.insert(problems, where .. ".shake " .. shake .. " is not a Shake preset")
				end
			elseif not (finite(shake) and shake > 0 and shake <= 1) then
				table.insert(problems, where .. ".shake must be a preset or trauma in (0, 1]")
			end
		end
		if
			cue.hitStop ~= nil
			and not (finite(cue.hitStop) and cue.hitStop > 0 and cue.hitStop <= Cues.HIT_STOP_MAX)
		then
			table.insert(problems, where .. ".hitStop must be within (0, 0.2] seconds")
		end
		local haptic = cue.haptic
		if haptic ~= nil then
			local kind = if type(haptic) == "table" then haptic.type else haptic
			if not table.find(HAPTIC_TYPES, kind) then
				table.insert(
					problems,
					where .. ".haptic type must be one of " .. table.concat(HAPTIC_TYPES, ", ")
				)
			end
		end
		for _, key in { "flash", "tint", "popup" } do
			if cue[key] ~= nil and type(cue[key]) ~= "table" then
				table.insert(problems, where .. "." .. key .. " must be a table")
			end
		end
		if type(cue.flash) == "table" then
			local intensity = cue.flash.intensity
			if intensity ~= nil and not (finite(intensity) and intensity > 0 and intensity <= 0.5) then
				table.insert(problems, where .. ".flash.intensity must be within (0, 0.5]")
			end
		end
		if type(cue.popup) == "table" and cue.popup.kind ~= nil and not label(cue.popup.kind) then
			table.insert(problems, where .. ".popup.kind must be a label")
		end
		if cue.caption ~= nil and not label(cue.caption) then
			table.insert(problems, where .. ".caption must be a localisation key label")
		end
		if cue.visual ~= nil and not label(cue.visual) then
			table.insert(problems, where .. ".visual must be a label")
		end
		local priority = cue.priority
		if
			priority ~= nil
			and not (finite(priority) and priority % 1 == 0 and priority >= 0 and priority <= 10)
		then
			table.insert(problems, where .. ".priority must be a whole number 0..10")
		end
	end
	return problems
end

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

function Cues.defaults(): { [string]: any }
	return copy(DEFAULTS)
end

export type Sinks = {
	vfx: ((id: string, context: any) -> ())?,
	sound: ((id: string, context: any) -> ())?,
	shake: ((amount: any, context: any) -> ())?,
	hitStop: ((seconds: number, context: any) -> ())?,
	haptic: ((pattern: any, context: any) -> ())?,
	flash: ((spec: any, context: any) -> ())?,
	tint: ((spec: any, context: any) -> ())?,
	popup: ((spec: any, context: any) -> ())?,
}

export type Options = { budget: number?, known: Known?, report: ((string) -> ())? }

function Cues.new(cues: { [string]: any }, sinks: Sinks, options: Options?)
	local opts: any = options or {}
	local problems = Cues.validate(cues, opts.known)
	assert(#problems == 0, "Cues: " .. table.concat(problems, "; "))
	assert(type(sinks) == "table", "Cues: sinks table required")
	local budget = opts.budget or Cues.BUDGET
	assert(finite(budget) and budget >= 1 and budget % 1 == 0, "Cues: budget must be a whole number >= 1")
	local definitions = copy(cues)
	local report = opts.report or function(_message: string) end
	local fired: { { id: string, priority: number } } = {}
	local counters = { fired = 0, dropped = 0, sinkErrors = 0 }
	local api = {}

	-- Starts a new frame (call once per frame before firing).
	function api:frame()
		table.clear(fired)
	end

	-- Fires every channel of cue `id`. context is passed to each sink (position, target,
	-- anchor, value for popups ...). Returns the channel names that fired, or (nil, reason):
	-- unknown_cue, frame_budget (the frame is full of equal or higher priorities).
	function api:fire(id: string, context: any?): ({ string }?, string?)
		local cue = definitions[id]
		if cue == nil then
			return nil, "unknown_cue"
		end
		local priority = cue.priority or 5
		if #fired >= budget then
			local weakest = 1
			for index, entry in fired do
				if entry.priority < fired[weakest].priority then
					weakest = index
				end
			end
			if fired[weakest].priority >= priority then
				counters.dropped += 1
				return nil, "frame_budget"
			end
			-- the slot goes to the stronger cue; already-fired channels cannot be recalled
			table.remove(fired, weakest)
		end
		table.insert(fired, { id = id, priority = priority })
		counters.fired += 1
		local channels = {}
		for _, channel in Cues.CHANNELS do
			local value = cue[channel]
			local sink = (sinks :: any)[channel]
			if value ~= nil and sink ~= nil then
				local argument = if type(value) == "table" then copy(value) else value
				if channel == "haptic" and type(value) == "string" then
					argument = { type = value }
				end
				local ok, err = pcall(sink, argument, context)
				if ok then
					table.insert(channels, channel)
				else
					counters.sinkErrors += 1
					report("Feel.Cues: " .. id .. " " .. channel .. " failed: " .. tostring(err))
				end
			end
		end
		return channels, nil
	end

	-- Fires cues from animation markers: map = { MarkerName = cueId }. track is Animator-like
	-- (GetMarkerReachedSignal(name) returns a signal with Connect). context(param) or a table is
	-- passed to fire. Returns the connections (call Disconnect on each, or api:unbind(list)).
	function api:bindMarkers(track: any, map: { [string]: string }, context: any?): { any }
		local connections = {}
		for _, marker in sortedKeys(map) do
			local cueId = map[marker]
			assert(definitions[cueId] ~= nil, "Cues.bindMarkers: unknown cue " .. tostring(cueId))
			local connection = track:GetMarkerReachedSignal(marker):Connect(function(param: any)
				local ctx = if type(context) == "function" then context(param, marker) else context
				api:fire(cueId, ctx)
			end)
			table.insert(connections, connection)
		end
		return connections
	end

	function api:unbind(connections: { any })
		for _, connection in connections do
			connection:Disconnect()
		end
	end

	function api:stats(): any
		return table.clone(counters)
	end

	return api
end

return Cues
