--!strict
-- @tier T1
-- probe: worldcycle_phases
-- WorldCycle: a day/night clock driven by server time, so every client computes the same sky
-- without replication traffic. The day is a list of phases (clock hour -> SceneKit/Lighting
-- preset); the last `blend` hours before each phase boundary blend the outgoing preset into the
-- incoming one (Lighting.blend), and Lighting.ClockTime always follows the clock itself. An
-- optional weather overlay (a preset and an amount 0..1 that ramps over seconds) blends on top.
--   WorldCycle.validate(config) -> problems
--   WorldCycle.clock(serverTime, config) -> hours 0..24
--   WorldCycle.state(serverTime, config, weather?) -> { clockTime, phase, next, t, preset }
--   WorldCycle.new(config) -> cycle;  cycle:step(serverTime) -> state? (rate-limited)
--   cycle:setWeather(presetId?, amount, seconds, serverTime);  WorldCycle.apply(lighting, state, env?)
-- serverTime is Workspace:GetServerTimeNow() on clients and servers (the caller reads it; this
-- module never touches the engine except through Lighting.apply). Values marked convention are
-- starting points: a game tunes day length and phases.
local Lighting = require("../SceneKit/Lighting")

local WorldCycle = {}

-- Convention: a 20-minute day, phases on the function-named Lighting presets.
WorldCycle.DEFAULT = table.freeze({
	dayLength = 1200,
	offset = 0,
	blend = 0.75,
	applyInterval = 1,
	phases = table.freeze({
		table.freeze({ name = "night", at = 0, preset = "night_clear" }),
		table.freeze({ name = "dawn", at = 5.5, preset = "blue_hour" }),
		table.freeze({ name = "morning", at = 7, preset = "golden_hour" }),
		table.freeze({ name = "day", at = 9, preset = "bright_noon" }),
		table.freeze({ name = "evening", at = 17, preset = "golden_hour" }),
		table.freeze({ name = "dusk", at = 19, preset = "blue_hour" }),
		table.freeze({ name = "late_night", at = 20.5, preset = "night_clear" }),
	}),
})

local KEYS = { dayLength = true, offset = true, blend = true, applyInterval = true, phases = true }

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function label(value: any): boolean
	return type(value) == "string" and #value <= 64 and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

function WorldCycle.validate(config: any): { string }
	local problems = {}
	if type(config) ~= "table" then
		return { "config must be a table" }
	end
	local keys = {}
	for key in config do
		table.insert(keys, tostring(key))
	end
	table.sort(keys)
	for _, key in keys do
		if not KEYS[key] then
			table.insert(problems, key .. " is not a WorldCycle key")
		end
	end
	if not (finite(config.dayLength) and config.dayLength >= 10) then
		table.insert(problems, "dayLength must be >= 10 seconds")
	end
	if config.offset ~= nil and not finite(config.offset) then
		table.insert(problems, "offset must be a number of seconds")
	end
	if config.applyInterval ~= nil and not (finite(config.applyInterval) and config.applyInterval >= 0) then
		table.insert(problems, "applyInterval must be >= 0 seconds")
	end
	local blend = config.blend or 0
	if not (finite(blend) and blend >= 0) then
		table.insert(problems, "blend must be >= 0 hours")
	end
	local phases = config.phases
	if type(phases) ~= "table" or #phases == 0 then
		table.insert(problems, "phases must be a non-empty list")
		return problems
	end
	local names = {}
	for index, phase in phases do
		local where = "phases[" .. index .. "]"
		if type(phase) ~= "table" then
			table.insert(problems, where .. " must be a table")
			continue
		end
		if not label(phase.name) then
			table.insert(problems, where .. ".name must be a label")
		elseif names[phase.name] then
			table.insert(problems, where .. ".name " .. phase.name .. " is used twice")
		end
		names[phase.name or ""] = true
		if not (finite(phase.at) and phase.at >= 0 and phase.at < 24) then
			table.insert(problems, where .. ".at must be a clock hour in 0..24")
		elseif index > 1 and finite(phases[index - 1].at) and phase.at <= phases[index - 1].at then
			table.insert(problems, where .. ".at must be after the previous phase")
		end
		if type(phase.preset) ~= "string" or Lighting.resolve(phase.preset) == nil then
			table.insert(
				problems,
				where .. ".preset " .. tostring(phase.preset) .. " is not a Lighting preset"
			)
		end
	end
	if #problems == 0 and blend > 0 then
		for index, phase in phases do
			local nextAt = if index < #phases then phases[index + 1].at else phases[1].at + 24
			if nextAt - phase.at < blend then
				table.insert(problems, "phase " .. phase.name .. " is shorter than the blend window")
			end
		end
	end
	return problems
end

-- Clock hour 0..24 at serverTime.
function WorldCycle.clock(serverTime: number, config: any): number
	assert(finite(serverTime), "WorldCycle.clock: serverTime must be finite")
	local seconds = (serverTime + (config.offset or 0)) % config.dayLength
	return seconds / config.dayLength * 24
end

export type Weather = { preset: string?, amount: number }
export type State = {
	clockTime: number,
	phase: string,
	next: string,
	t: number, -- blend progress into `next` (0 outside the blend window)
	preset: any, -- the Lighting preset to apply (ClockTime already set)
	weather: Weather?,
}

-- The phase active at `hour` (index) and the hours until the next phase starts.
local function phaseAt(phases: any, hour: number): (number, number)
	local index = #phases
	for i, phase in phases do
		if hour >= phase.at then
			index = i
		end
	end
	local nextAt = if index < #phases then phases[index + 1].at else phases[1].at + 24
	local current = if hour < phases[index].at then hour + 24 else hour
	return index, nextAt - current
end

function WorldCycle.state(serverTime: number, config: any, weather: Weather?): State
	local hour = WorldCycle.clock(serverTime, config)
	local phases = config.phases
	local index, untilNext = phaseAt(phases, hour)
	local nextIndex = if index < #phases then index + 1 else 1
	local blend = config.blend or 0
	local t = 0
	if blend > 0 and untilNext < blend then
		t = 1 - untilNext / blend
	end
	local from, to = phases[index], phases[nextIndex]
	local preset = if t > 0 then Lighting.blend(from.preset, to.preset, t) else Lighting.copy(from.preset)
	if weather and weather.preset and weather.amount > 0 then
		preset = Lighting.blend(preset, weather.preset, weather.amount)
	end
	preset.lighting = preset.lighting or {}
	preset.lighting.ClockTime = hour
	return { clockTime = hour, phase = from.name, next = to.name, t = t, preset = preset, weather = weather }
end

-- Writes a state's preset with SceneKit/Lighting.apply (owned instances only).
function WorldCycle.apply(lighting: any, state: State, env: any?, options: any?): any
	return Lighting.apply(lighting, state.preset, env, options)
end

function WorldCycle.new(config: any?)
	local cfg = config or WorldCycle.DEFAULT
	local problems = WorldCycle.validate(cfg)
	assert(#problems == 0, "WorldCycle: " .. table.concat(problems, "; "))
	local interval = cfg.applyInterval or 1
	local lastApplied = -math.huge
	local lastPhase = nil
	local weather = { preset = nil :: string?, from = 0, to = 0, start = 0, duration = 0 }
	local api = {}

	local function weatherAt(serverTime: number): Weather?
		if weather.preset == nil then
			return nil
		end
		local amount = weather.to
		if weather.duration > 0 and serverTime < weather.start + weather.duration then
			local x = math.clamp((serverTime - weather.start) / weather.duration, 0, 1)
			amount = weather.from + (weather.to - weather.from) * x
		end
		return { preset = weather.preset, amount = amount }
	end

	-- Ramps a weather overlay (a Lighting preset such as overcast, dense_fog or storm_dim) to
	-- `amount` over `seconds`. presetId nil with amount 0 clears it after the ramp.
	function api:setWeather(presetId: string?, amount: number, seconds: number, serverTime: number)
		assert(presetId == nil or Lighting.resolve(presetId) ~= nil, "WorldCycle: unknown weather preset")
		assert(finite(amount) and amount >= 0 and amount <= 1, "WorldCycle: weather amount must be 0..1")
		assert(finite(seconds) and seconds >= 0, "WorldCycle: seconds must be >= 0")
		local current = weatherAt(serverTime)
		local from = if current then current.amount else 0
		if presetId ~= nil and presetId ~= weather.preset then
			from = 0
		end
		weather = {
			preset = presetId or weather.preset,
			from = from,
			to = amount,
			start = serverTime,
			duration = seconds,
		}
	end

	-- The state to apply now, or nil when less than applyInterval passed since the last one and
	-- the phase did not change (Lighting writes are not free; convention 1 s).
	function api:step(serverTime: number): State?
		local state = WorldCycle.state(serverTime, cfg, weatherAt(serverTime))
		if serverTime - lastApplied < interval and state.phase == lastPhase then
			return nil
		end
		lastApplied = serverTime
		lastPhase = state.phase
		return state
	end

	function api:state(serverTime: number): State
		return WorldCycle.state(serverTime, cfg, weatherAt(serverTime))
	end

	return api
end

return WorldCycle
