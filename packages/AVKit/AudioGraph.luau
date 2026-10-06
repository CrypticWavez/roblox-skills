--!strict
-- @tier T1
-- AudioGraph: the audio-graph/1 mixer on the Audio API (docs/research/visual-audio-assets-2026-10.md
-- 3g and 6.4). A graph is data: buses (each an AudioFader plus an ordered effects chain) that
-- feed their parent up to master, which feeds one AudioDeviceOutput and an AudioAnalyzer tap.
-- The standard buses match settings/1 volume.*: master, music, sfx, ui, ambience, dialogue, world.
-- Games may add child buses (footsteps under sfx). `world` can own an AudioListener on the camera
-- so 3D AudioEmitters reach the mix through the master fader.
--   validate(graph) -> (problems, warnings)  acyclic, every bus reaches master, effect ranges
--   plan(graph, options?) -> { nodes, wires }  deterministic node and wire list (T0)
--   build(plan, env, options?) -> { folder, nodes, wires }  Instances on @lune/roblox or Studio (T1)
--   runtime(graph) -> fader volumes per frame: graph volume x settings/1 effective volume x
--       duck envelope x optional AudioMixer channel gain (T0)
-- Ducking (duck = { by = { bus }, amount, attack, release, mode }): mode "fader" (default) is
-- sidechain-style ducking by fader automation: while any `by` bus has active voices the bus
-- fader moves linearly to `amount` over `attack` seconds and back over `release`. Mode
-- "sidechain" wires the `by` bus into the bus's AudioCompressor Sidechain pin (engine ducking;
-- needs an AudioCompressor in effects). Voice caps: total <= 64 (convention ceiling), warning
-- above 32 (research 3h convention).
local AudioGraph = {}

AudioGraph.SCHEMA = "audio-graph/1"
AudioGraph.BUSES = table.freeze({ "master", "music", "sfx", "ui", "ambience", "dialogue", "world" })
AudioGraph.FADER_MAX = 3 -- AudioFader.Volume 0-3 (docs classes/AudioFader)
AudioGraph.VOICES_BUDGET = 32 -- convention
AudioGraph.VOICES_CEILING = 64 -- convention
AudioGraph.EFFECTS_PER_BUS = 4 -- convention

-- camelCase data key -> { property, min, max }. AudioCompressor ranges are documented (class page);
-- AudioEqualizer and AudioReverb ranges are conventions inside the engine's ranges.
local EFFECTS = {
	AudioCompressor = {
		threshold = { "Threshold", -60, 0 },
		ratio = { "Ratio", 1, 50 },
		attack = { "Attack", 0.0001, 0.5 },
		release = { "Release", 0.01, 5 },
		makeupGain = { "MakeupGain", -30, 30 },
		bypass = { "Bypass" },
	},
	AudioEqualizer = {
		lowGain = { "LowGain", -80, 10 },
		midGain = { "MidGain", -80, 10 },
		highGain = { "HighGain", -80, 10 },
		bypass = { "Bypass" },
	},
	AudioReverb = {
		decayTime = { "DecayTime", 0.1, 20 },
		density = { "Density", 0, 1 },
		diffusion = { "Diffusion", 0, 1 },
		dryLevel = { "DryLevel", -80, 20 },
		wetLevel = { "WetLevel", -80, 20 },
		bypass = { "Bypass" },
	},
}
AudioGraph.EFFECTS = EFFECTS

local BUS_KEYS = { parent = true, volume = true, effects = true, duck = true, listener = true }
local DUCK_KEYS = { by = true, amount = true, attack = true, release = true, mode = true }

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

local function inRange(value: any, min: number, max: number): boolean
	return finite(value) and value >= min and value <= max
end

-- Bus names from master down, parents before children (ties sorted), for deterministic output.
local function order(buses: any): { string }
	local result = {}
	local seen = {}
	local function visit(name: string)
		if seen[name] then
			return
		end
		seen[name] = true
		table.insert(result, name)
		local children = {}
		for _, child in sortedKeys(buses) do
			if buses[child].parent == name then
				table.insert(children, child)
			end
		end
		for _, child in children do
			visit(child)
		end
	end
	visit("master")
	return result
end

-- Ancestors of a bus (parent first); nil when the chain loops or breaks.
local function ancestors(buses: any, name: string): { string }?
	local chain = {}
	local seen = { [name] = true }
	local current = buses[name] and buses[name].parent
	while current ~= nil do
		if seen[current] or buses[current] == nil then
			return nil
		end
		seen[current] = true
		table.insert(chain, current)
		current = buses[current].parent
	end
	return chain
end

-- (problems, warnings). Problems block plan/build.
function AudioGraph.validate(graph: any): ({ string }, { string })
	local problems, warnings = {}, {}
	local function problem(text: string)
		table.insert(problems, text)
	end
	if type(graph) ~= "table" then
		return { "graph must be a table" }, {}
	end
	for _, key in sortedKeys(graph) do
		if key ~= "schema" and key ~= "buses" and key ~= "voices" then
			problem(key .. " is not a graph key")
		end
	end
	if graph.schema ~= AudioGraph.SCHEMA then
		problem("schema must be " .. AudioGraph.SCHEMA)
	end
	local buses = graph.buses
	if type(buses) ~= "table" then
		problem("buses must be a table")
		return problems, warnings
	end
	for _, name in AudioGraph.BUSES do
		if buses[name] == nil then
			problem("standard bus " .. name .. " is missing (settings/1 volume." .. name .. ")")
		end
	end
	for _, name in sortedKeys(buses) do
		local bus = buses[name]
		local where = "bus " .. name
		if not label(name) then
			problem(where .. ": name must be a label")
		end
		if type(bus) ~= "table" then
			problem(where .. " must be a table")
			continue
		end
		for _, key in sortedKeys(bus) do
			if not BUS_KEYS[key] then
				problem(where .. ": " .. key .. " is not a bus key")
			end
		end
		if name == "master" then
			if bus.parent ~= nil then
				problem("bus master is the root and has no parent")
			end
		elseif bus.parent == nil then
			problem(where .. " has no parent (only master is a root; orphan buses never reach the output)")
		elseif buses[bus.parent] == nil then
			problem(where .. " parent " .. tostring(bus.parent) .. " does not exist")
		elseif ancestors(buses, name) == nil then
			problem(where .. " is in a parent cycle and never reaches master")
		end
		if bus.volume ~= nil and not inRange(bus.volume, 0, AudioGraph.FADER_MAX) then
			problem(where .. ".volume must be within 0..3 (AudioFader)")
		end
		if bus.listener ~= nil and bus.listener ~= "camera" then
			problem(where .. '.listener must be "camera"')
		end
		local effects = bus.effects
		local hasCompressor = false
		if effects ~= nil then
			if type(effects) ~= "table" then
				problem(where .. ".effects must be a list")
			else
				if #effects > AudioGraph.EFFECTS_PER_BUS then
					problem(
						string.format(
							"%s has %d effects (at most %d, convention)",
							where,
							#effects,
							AudioGraph.EFFECTS_PER_BUS
						)
					)
				end
				for index, effect in effects do
					local at = where .. ".effects[" .. index .. "]"
					local spec = type(effect) == "table" and EFFECTS[effect.class]
					if not spec then
						problem(at .. ".class must be AudioCompressor, AudioEqualizer or AudioReverb")
						continue
					end
					hasCompressor = hasCompressor or effect.class == "AudioCompressor"
					for _, key in sortedKeys(effect) do
						if key ~= "class" then
							local field = spec[key]
							if field == nil then
								problem(at .. ": " .. key .. " is not an " .. effect.class .. " field")
							elseif key == "bypass" then
								if type(effect[key]) ~= "boolean" then
									problem(at .. ".bypass must be a boolean")
								end
							elseif not inRange(effect[key], field[2], field[3]) then
								problem(
									string.format(
										"%s.%s must be within %s..%s",
										at,
										key,
										tostring(field[2]),
										tostring(field[3])
									)
								)
							end
						end
					end
				end
			end
		end
		local duck = bus.duck
		if duck ~= nil then
			if type(duck) ~= "table" then
				problem(where .. ".duck must be a table")
			else
				for _, key in sortedKeys(duck) do
					if not DUCK_KEYS[key] then
						problem(where .. ".duck: " .. key .. " is not a duck key")
					end
				end
				if type(duck.by) ~= "table" or #duck.by == 0 then
					problem(where .. ".duck.by must list the buses that duck it")
				else
					local chain = ancestors(buses, name) or {}
					for _, by in duck.by do
						if by == name then
							problem(where .. " cannot duck itself")
						elseif buses[by] == nil then
							problem(where .. ".duck.by " .. tostring(by) .. " does not exist")
						elseif table.find(chain, by) then
							problem(where .. ".duck.by " .. by .. " is an ancestor (that wiring is a cycle)")
						end
					end
				end
				if not inRange(duck.amount, 0, 1) then
					problem(where .. ".duck.amount must be a gain within 0..1")
				end
				if duck.attack ~= nil and not inRange(duck.attack, 0, 5) then
					problem(where .. ".duck.attack must be within 0..5 s")
				end
				if duck.release ~= nil and not inRange(duck.release, 0, 10) then
					problem(where .. ".duck.release must be within 0..10 s")
				end
				if duck.mode ~= nil and duck.mode ~= "fader" and duck.mode ~= "sidechain" then
					problem(where .. ".duck.mode must be fader or sidechain")
				end
				if duck.mode == "sidechain" and not hasCompressor then
					problem(where .. ".duck.mode sidechain needs an AudioCompressor in effects")
				end
			end
		end
	end
	local voices = graph.voices
	if voices ~= nil then
		if type(voices) ~= "table" then
			problem("voices must be a table")
		else
			for _, key in sortedKeys(voices) do
				local value = voices[key]
				if key ~= "total" and buses[key] == nil then
					problem("voices." .. key .. " is not a bus")
				elseif not (finite(value) and value % 1 == 0 and value >= 1) then
					problem("voices." .. key .. " must be a whole number >= 1")
				end
			end
			local total = voices.total
			if finite(total) then
				if total > AudioGraph.VOICES_CEILING then
					problem(
						string.format(
							"voices.total %d above %d (convention ceiling)",
							total,
							AudioGraph.VOICES_CEILING
						)
					)
				elseif total > AudioGraph.VOICES_BUDGET then
					table.insert(
						warnings,
						string.format(
							"voices.total %d above the %d-voice budget (convention)",
							total,
							AudioGraph.VOICES_BUDGET
						)
					)
				end
			end
		end
	end
	return problems, warnings
end

-- A neutral starting graph: a gentle master compressor as a safety limiter, music and ambience
-- ducked under dialogue by fader automation, a camera listener on world. Every value is a
-- convention to tune by ear in the game.
function AudioGraph.default(): any
	return {
		schema = AudioGraph.SCHEMA,
		buses = {
			master = {
				volume = 1,
				effects = {
					{ class = "AudioCompressor", threshold = -6, ratio = 8, attack = 0.005, release = 0.2 },
				},
			},
			music = {
				parent = "master",
				volume = 0.8,
				duck = { by = { "dialogue" }, amount = 0.4, attack = 0.15, release = 0.6 },
			},
			sfx = { parent = "master", volume = 1 },
			ui = { parent = "master", volume = 1 },
			ambience = {
				parent = "master",
				volume = 0.8,
				duck = { by = { "dialogue" }, amount = 0.6, attack = 0.2, release = 0.8 },
			},
			dialogue = { parent = "master", volume = 1 },
			world = { parent = "master", volume = 1, listener = "camera" },
		},
		voices = { total = 32, sfx = 12, ui = 4, music = 2, ambience = 4, dialogue = 2, world = 12 },
	}
end

export type Node = { name: string, class: string, bus: string, props: { [string]: any } }
export type WirePlan = { name: string, from: string, to: string, toPin: string? }
export type Plan = { nodes: { Node }, wires: { WirePlan }, buses: { string }, inputs: { [string]: string } }

local function busNode(name: string): string
	return "Bus_" .. name
end

-- Deterministic nodes and wires. Each bus: fader, then its effects in data order; its tail feeds
-- the parent's fader. Master's tail feeds "Output" (AudioDeviceOutput; options.silent leaves it
-- unwired) and "Analyzer_master". Listener buses get "Listener_<bus>" wired into the fader.
-- Sidechain ducks wire the `by` bus tail into the compressor's "Sidechain" pin. inputs[bus] is
-- the node a source (AudioPlayer or AudioListener) wires into.
function AudioGraph.plan(graph: any, options: { silent: boolean? }?): Plan
	local problems = AudioGraph.validate(graph)
	assert(#problems == 0, "AudioGraph.plan: " .. table.concat(problems, "; "))
	local buses = graph.buses
	local names = order(buses)
	local plan: Plan = { nodes = {}, wires = {}, buses = names, inputs = {} }
	local tails = {}
	local compressors = {}
	local function wire(from: string, to: string, toPin: string?)
		local name = "Wire_" .. from .. "_" .. to .. (if toPin then "_" .. toPin else "")
		table.insert(plan.wires, { name = name, from = from, to = to, toPin = toPin })
	end
	for _, name in names do
		local bus = buses[name]
		local fader = busNode(name)
		table.insert(
			plan.nodes,
			{ name = fader, class = "AudioFader", bus = name, props = { Volume = bus.volume or 1 } }
		)
		plan.inputs[name] = fader
		local tail = fader
		for index, effect in bus.effects or {} do
			local node = string.format("%s_fx%d_%s", fader, index, effect.class)
			local props = {}
			for key, value in effect do
				if key ~= "class" then
					props[EFFECTS[effect.class][key][1]] = value
				end
			end
			table.insert(plan.nodes, { name = node, class = effect.class, bus = name, props = props })
			wire(tail, node)
			tail = node
			if effect.class == "AudioCompressor" and compressors[name] == nil then
				compressors[name] = node
			end
		end
		tails[name] = tail
		if bus.listener == "camera" then
			local listener = "Listener_" .. name
			table.insert(plan.nodes, { name = listener, class = "AudioListener", bus = name, props = {} })
			wire(listener, fader)
		end
	end
	for _, name in names do
		local parent = buses[name].parent
		if parent ~= nil then
			wire(tails[name], plan.inputs[parent])
		end
	end
	table.insert(plan.nodes, { name = "Output", class = "AudioDeviceOutput", bus = "master", props = {} })
	table.insert(
		plan.nodes,
		{ name = "Analyzer_master", class = "AudioAnalyzer", bus = "master", props = {} }
	)
	if not (options and options.silent) then
		wire(tails.master, "Output")
	end
	wire(tails.master, "Analyzer_master")
	for _, name in names do
		local duck = buses[name].duck
		if duck and duck.mode == "sidechain" then
			for _, by in duck.by do
				wire(tails[by], compressors[name], "Sidechain")
			end
		end
	end
	return plan
end

export type Built = { folder: any, nodes: { [string]: any }, wires: { [string]: any } }

-- Creates the planned Instances under options.parent (a Folder named "AudioGraph" is made).
-- AudioListener nodes go under options.camera when given (a listener elsewhere hears from its
-- parent's position). env is @lune/roblox or a GameKit env with .roblox.
function AudioGraph.build(plan: Plan, env: any, options: { parent: any?, camera: any? }?): Built
	local lib = if env.roblox then env.roblox else env
	local opts: any = options or {}
	local folder = lib.Instance.new("Folder")
	folder.Name = "AudioGraph"
	local nodes = {}
	for _, node in plan.nodes do
		local instance = lib.Instance.new(node.class)
		instance.Name = node.name
		for _, key in sortedKeys(node.props) do
			(instance :: any)[key] = node.props[key]
		end
		instance:SetAttribute("AudioGraphBus", node.bus)
		if node.class == "AudioListener" and opts.camera ~= nil then
			instance.Parent = opts.camera
		else
			instance.Parent = folder
		end
		nodes[node.name] = instance
	end
	local wires = {}
	for _, spec in plan.wires do
		local wire = lib.Instance.new("Wire")
		wire.Name = spec.name
		wire.SourceInstance = nodes[spec.from]
		wire.TargetInstance = nodes[spec.to]
		if spec.toPin then
			wire.TargetName = spec.toPin
		end
		wire.Parent = folder
		wires[spec.name] = wire
	end
	if opts.parent ~= nil then
		folder.Parent = opts.parent
	end
	return { folder = folder, nodes = nodes, wires = wires }
end

-- Fader automation per frame. activity: { [bus] = playing voices } (AudioCues:activity()).
-- effective: settings/1 Settings.effective (volume[bus] already includes master). mixer: optional
-- AudioMixer:step output keyed by bus. Returns { [bus] = fader Volume }.
-- Master's fader stays at its graph volume: the user's master volume is already in every
-- standard bus's effective volume, so applying it again would square it.
function AudioGraph.runtime(graph: any)
	local problems = AudioGraph.validate(graph)
	assert(#problems == 0, "AudioGraph.runtime: " .. table.concat(problems, "; "))
	local buses = graph.buses
	local names = order(buses)
	local duckGain: { [string]: number } = {}
	for _, name in names do
		duckGain[name] = 1
	end
	local api = {}
	function api:step(
		dt: number,
		activity: { [string]: number }?,
		effective: any?,
		mixer: { [string]: number }?
	): { [string]: number }
		assert(finite(dt) and dt >= 0, "AudioGraph.runtime: invalid dt")
		local active = activity or {}
		local volume = if effective and effective.volume then effective.volume else {}
		local out = {}
		for _, name in names do
			local bus = buses[name]
			local duck = bus.duck
			if duck and duck.mode ~= "sidechain" then
				local ducking = false
				for _, by in duck.by do
					if (active[by] or 0) > 0 then
						ducking = true
					end
				end
				local target = if ducking then duck.amount else 1
				local span = 1 - duck.amount
				local seconds = if ducking then duck.attack or 0.1 else duck.release or 0.5
				local current = duckGain[name]
				if span <= 0 or seconds <= 0 then
					current = target
				else
					local stepSize = span * dt / seconds
					if current > target then
						current = math.max(target, current - stepSize)
					else
						current = math.min(target, current + stepSize)
					end
				end
				duckGain[name] = current
			end
			local user = 1
			if name ~= "master" and table.find(AudioGraph.BUSES, name) and finite(volume[name]) then
				user = math.clamp(volume[name], 0, 1)
			end
			local channel = if mixer and finite(mixer[name]) then math.clamp(mixer[name], 0, 1) else 1
			out[name] =
				math.clamp((bus.volume or 1) * user * duckGain[name] * channel, 0, AudioGraph.FADER_MAX)
		end
		return out
	end
	function api:duckGain(name: string): number
		return duckGain[name] or 1
	end
	return api
end

return AudioGraph
