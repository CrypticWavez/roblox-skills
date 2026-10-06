--!strict
-- @tier T0
-- AudioDirector: pure event and music-state routing over an AudioMixer, moved from
-- Creator/AudioDirector (which now re-exports it). The backend ({ play(key, def) -> boolean,
-- stop(key) }) is caller-owned: AVKit/AudioGraphRoblox implements it on the Audio API. Unconfigured
-- events report missing_asset; inspect() never claims hearing (NOT_VERIFIED).
local AudioDirector = {}
local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end
local function nonempty(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 120
end

function AudioDirector.new(config: any, mixer: any, backend: any)
	assert(
		type(config) == "table" and type(config.events) == "table" and type(config.states) == "table",
		"events/states required"
	)
	assert(
		type(backend) == "table" and type(backend.play) == "function" and type(backend.stop) == "function",
		"explicit backend required"
	)
	local events, states, channels = {}, {}, {}
	local count = 0
	for key, definition in config.events do
		assert(
			nonempty(key) and type(definition) == "table" and nonempty(definition.channel),
			"invalid event/channel"
		)
		assert(type(definition.looped) == "boolean", "explicit loop state required")
		assert(
			finite(definition.gain) and definition.gain >= 0 and definition.gain <= 1,
			"invalid event gain"
		)
		assert(type(definition.configured) == "boolean", "explicit asset configuration required")
		count += 1
		assert(count <= 64, "event capacity")
		events[key] = table.clone(definition)
	end
	for key, layers in config.states do
		assert(nonempty(key) and type(layers) == "table", "invalid state")
		local copy = {}
		for channel, value in layers do
			assert(nonempty(channel) and finite(value) and value >= 0 and value <= 1, "invalid music layer")
			copy[channel], channels[channel] = value, true
		end
		states[key] = copy
	end
	for channel in channels do
		mixer:fade(channel, 0, 0)
	end
	local active, trace, time, closed, state = {}, {}, 0, false, ""
	local api = {}
	local function record(kind, key, result)
		table.insert(trace, { time = time, kind = kind, key = key, result = result })
		if #trace > 128 then
			table.remove(trace, 1)
		end
	end
	function api:emit(key: string): (boolean, string?)
		if closed then
			return false, "closed"
		end
		local definition = events[key]
		if not definition then
			record("event", key, "unknown_event")
			return false, "unknown_event"
		end
		if not definition.configured then
			record("event", key, "missing_asset")
			return false, "missing_asset"
		end
		local ok, played = pcall(backend.play, key, table.clone(definition))
		if not ok or played ~= true then
			record("event", key, "backend_rejected")
			return false, "backend_rejected"
		end
		active[key] = true
		record("event", key, "backend_accepted")
		return true, nil
	end
	function api:setState(key: string, duration: number, reduced: boolean)
		assert(not closed and states[key], "unknown or closed music state")
		assert(
			finite(duration) and duration >= 0 and duration <= 60 and type(reduced) == "boolean",
			"invalid state transition"
		)
		if state == key then
			return false
		end
		for channel in channels do
			mixer:fade(channel, states[key][channel] or 0, if reduced then 0 else duration)
		end
		state = key
		record("state", key, "requested")
		return true
	end
	function api:step(dt: number)
		assert(finite(dt) and dt >= 0, "invalid audio step")
		if closed then
			return {}
		end
		time += dt
		return mixer:step(dt)
	end
	function api:inspect()
		local copy = {}
		for _, entry in trace do
			table.insert(copy, table.clone(entry))
		end
		return {
			state = state,
			events = copy,
			permission = "unverified",
			hearing = "NOT_VERIFIED",
			closed = closed,
		}
	end
	function api:destroy()
		if closed then
			return
		end
		closed = true
		for key in active do
			pcall(backend.stop, key)
		end
		for channel in channels do
			mixer:fade(channel, 0, 0)
		end
		table.clear(active)
	end
	return api
end

return AudioDirector
