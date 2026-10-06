--!strict
-- @tier T0
-- WaveDirector: data-defined waves driven by a seeded ProcGen/Rng. A spec lists spawn groups
-- (function names such as enemy_basic, never content) with a cost, weight and first wave; each
-- wave gets a budget from a curve, every Nth wave escalates, and a rest window follows each
-- cleared wave. plan(spec, wave, seed) is pure: the same seed and wave give the same spawns.
--   budget(w)  = floor((base + perWave * (w - 1)) * growth ^ (w - 1)), x multiplier on an
--                escalation wave (w % every == 0)
--   rest(w)    = clamp(base + perWave * (w - 1), min, base) seconds after wave w
-- Groups are bought by weighted draw among those affordable and unlocked (minWave, maxPerWave),
-- one spawn every spawnInterval seconds, lanes assigned in turn from a seeded start. new() runs
-- the plans: tick(now) returns the spawn requests due (never yields), defeated(n) reports units
-- gone; a wave clears when it has spawned everything and nothing is alive.
local Check = require("./Check")
local Events = require("./Events")
local Rng = require("../ProcGen/Rng")
local Signal = require("./Signal")

local WaveDirector = {}

export type Group = { key: string, cost: number, weight: number?, minWave: number?, maxPerWave: number? }
export type Spec = {
	groups: { Group },
	waves: number?, -- number of waves (nil: endless)
	budget: { base: number, perWave: number?, growth: number? },
	escalation: { every: number, multiplier: number }?,
	rest: { base: number, perWave: number?, min: number? }?,
	spawnInterval: number?, -- seconds between spawns in a wave (default 0.75)
	maxAlive: number?, -- spawns wait while this many are alive (default no cap)
	lanes: { string }?,
	firstDelay: number?, -- seconds before wave 1 (default 0)
}
export type Spawn = { group: string, lane: string?, at: number, index: number }
export type Plan = {
	wave: number,
	budget: number,
	escalation: boolean,
	spent: number,
	spawns: { Spawn },
	rest: number,
}

function WaveDirector.validate(spec: any): { string }
	local problems = {}
	if type(spec) ~= "table" then
		return { "spec must be a table" }
	end
	if type(spec.groups) ~= "table" or #spec.groups == 0 then
		table.insert(problems, "groups must be a non-empty list")
	else
		local seen = {}
		for i, group in spec.groups do
			local name = "group " .. (if type(group) == "table" then tostring(group.key) else tostring(i))
			if type(group) ~= "table" or not Check.label(group.key) then
				table.insert(problems, name .. ": key must be a label")
				continue
			end
			if seen[group.key] then
				table.insert(problems, name .. ": duplicate key")
			end
			seen[group.key] = true
			if not Check.finite(group.cost) or group.cost <= 0 then
				table.insert(problems, name .. ": cost must be a finite number > 0")
			end
			if group.weight ~= nil and (not Check.finite(group.weight) or group.weight <= 0) then
				table.insert(problems, name .. ": weight must be a finite number > 0")
			end
			for _, key in { "minWave", "maxPerWave" } do
				local value = group[key]
				if value ~= nil and (not Check.integer(value) or value < 1) then
					table.insert(problems, name .. ": " .. key .. " must be an integer >= 1")
				end
			end
		end
	end
	if spec.waves ~= nil and (not Check.integer(spec.waves) or spec.waves < 1) then
		table.insert(problems, "waves must be an integer >= 1 (or nil for endless)")
	end
	local budget = spec.budget
	if type(budget) ~= "table" or not Check.finite(budget.base) or budget.base <= 0 then
		table.insert(problems, "budget.base must be a finite number > 0")
	elseif
		(budget.perWave ~= nil and not Check.finite(budget.perWave))
		or (budget.growth ~= nil and (not Check.finite(budget.growth) or budget.growth <= 0))
	then
		table.insert(problems, "budget.perWave must be finite and budget.growth > 0")
	end
	local escalation = spec.escalation
	if
		escalation ~= nil
		and (
			type(escalation) ~= "table"
			or not Check.integer(escalation.every)
			or escalation.every < 1
			or not Check.finite(escalation.multiplier)
			or escalation.multiplier <= 0
		)
	then
		table.insert(problems, "escalation needs every (integer >= 1) and multiplier (> 0)")
	end
	local rest = spec.rest
	if rest ~= nil and (type(rest) ~= "table" or not Check.finite(rest.base) or rest.base < 0) then
		table.insert(problems, "rest.base must be a finite number >= 0")
	end
	for _, key in { "spawnInterval", "firstDelay" } do
		local value = spec[key]
		if value ~= nil and (not Check.finite(value) or value < 0) then
			table.insert(problems, key .. " must be a finite number >= 0")
		end
	end
	if spec.maxAlive ~= nil and (not Check.integer(spec.maxAlive) or spec.maxAlive < 1) then
		table.insert(problems, "maxAlive must be an integer >= 1")
	end
	if spec.lanes ~= nil then
		if type(spec.lanes) ~= "table" or #spec.lanes == 0 then
			table.insert(problems, "lanes must be a non-empty list of labels")
		else
			for _, lane in spec.lanes do
				if not Check.label(lane) then
					table.insert(problems, "lane " .. tostring(lane) .. " must be a label")
				end
			end
		end
	end
	return problems
end

function WaveDirector.define(spec: Spec): Spec
	local problems = WaveDirector.validate(spec)
	if #problems > 0 then
		error("WaveDirector.define: " .. table.concat(problems, "; "), 2)
	end
	return Check.freeze(Check.copy(spec))
end

-- Budget of a wave and whether it escalates.
function WaveDirector.budget(spec: Spec, wave: number): (number, boolean)
	local b = spec.budget
	local raw = (b.base + (b.perWave or 0) * (wave - 1)) * (b.growth or 1) ^ (wave - 1)
	local escalation = spec.escalation ~= nil and wave % (spec.escalation :: any).every == 0
	if escalation then
		raw *= (spec.escalation :: any).multiplier
	end
	return math.max(0, math.floor(raw + 1e-9)), escalation
end

-- Rest window after a wave, seconds.
function WaveDirector.rest(spec: Spec, wave: number): number
	local r = spec.rest
	if r == nil then
		return 0
	end
	local value = r.base + (r.perWave or 0) * (wave - 1)
	return math.clamp(value, math.min(r.min or 0, r.base), r.base)
end

-- The spawns of one wave (pure; same spec, wave and seed -> same plan).
function WaveDirector.plan(spec: Spec, wave: number, seed: number | string): Plan
	assert(Check.integer(wave) and wave >= 1, "WaveDirector.plan: wave must be an integer >= 1")
	local rng = Rng.new(seed):fork("wave" .. wave)
	local budget, escalation = WaveDirector.budget(spec, wave)
	local remaining = budget
	local counts: { [string]: number } = {}
	local bought: { string } = {}
	while true do
		local choices = {}
		for _, group in spec.groups do
			local unlocked = (group.minWave or 1) <= wave
			local underCap = group.maxPerWave == nil or (counts[group.key] or 0) < group.maxPerWave
			if unlocked and underCap and group.cost <= remaining then
				table.insert(choices, { value = group, weight = group.weight or 1 })
			end
		end
		if #choices == 0 then
			break
		end
		local group = rng:weighted(choices)
		remaining -= group.cost
		counts[group.key] = (counts[group.key] or 0) + 1
		table.insert(bought, group.key)
	end
	local interval = spec.spawnInterval or 0.75
	local lanes = spec.lanes
	local laneStart = if lanes then rng:int(1, #lanes) else 1
	local spawns = {}
	for i, key in bought do
		table.insert(spawns, {
			group = key,
			lane = if lanes then lanes[(laneStart + i - 2) % #lanes + 1] else nil,
			at = (i - 1) * interval,
			index = i,
		})
	end
	return {
		wave = wave,
		budget = budget,
		escalation = escalation,
		spent = budget - remaining,
		spawns = spawns,
		rest = WaveDirector.rest(spec, wave),
	}
end

export type Director = {
	spec: Spec,
	waveStarted: any, -- Signal(wave, plan)
	waveCleared: any, -- Signal(wave)
	finished: any, -- Signal()
	start: (self: Director) -> (),
	tick: (self: Director, now: number?) -> { Spawn & { wave: number } },
	defeated: (self: Director, count: number?) -> (),
	state: (self: Director) -> string,
	snapshot: (self: Director) -> { [string]: any },
}

-- options: seed (required), sink (kit-event/1 progression events, path "waves").
function WaveDirector.new(spec: Spec, options: { seed: number | string, sink: any? }, env: any): Director
	local defined = WaveDirector.define(spec)
	assert(type(options) == "table" and options.seed ~= nil, "WaveDirector.new: options.seed is required")
	assert(type(env) == "table" and type(env.clock) == "function", "WaveDirector.new: env.clock is required")
	local self: any = {
		spec = defined,
		waveStarted = Signal.new(env),
		waveCleared = Signal.new(env),
		finished = Signal.new(env),
	}
	local state = "idle"
	local wave = 0
	local plan: Plan? = nil
	local waveStart, restUntil = 0, 0
	local nextSpawn, alive, spawned = 1, 0, 0

	local function emit(status: string, level: number)
		if options.sink then
			options.sink:emit(
				Events.progression("wave", { path = "waves", status = status :: any, level = level })
			)
		end
	end

	local function begin(now: number)
		wave += 1
		plan = WaveDirector.plan(defined, wave, options.seed)
		state, waveStart, nextSpawn = "active", now, 1
		emit("start", wave)
		self.waveStarted:Fire(wave, plan)
	end

	function self.start(_)
		assert(state == "idle", "WaveDirector: already started")
		state = "rest"
		restUntil = env.clock() + (defined.firstDelay or 0)
	end

	function self.tick(_, now: number?): { any }
		local t = now or env.clock()
		local due = {}
		if state == "rest" and t >= restUntil then
			begin(t)
		end
		if state == "active" and plan then
			local current = plan :: Plan
			while nextSpawn <= #current.spawns do
				local s = current.spawns[nextSpawn]
				if waveStart + s.at > t or (defined.maxAlive and alive >= defined.maxAlive) then
					break
				end
				table.insert(due, { group = s.group, lane = s.lane, at = s.at, index = s.index, wave = wave })
				nextSpawn += 1
				alive += 1
				spawned += 1
			end
			if nextSpawn > #current.spawns and alive == 0 then
				emit("complete", wave)
				self.waveCleared:Fire(wave)
				if defined.waves and wave >= defined.waves then
					state = "done"
					self.finished:Fire()
				else
					state = "rest"
					restUntil = t + current.rest
				end
			end
		end
		return due
	end

	function self.defeated(_, count: number?)
		alive = math.max(0, alive - (count or 1))
	end

	function self.state(_): string
		return state
	end

	function self.snapshot(_): { [string]: any }
		return {
			state = state,
			wave = wave,
			alive = alive,
			spawned = spawned,
			pending = if plan then #(plan :: Plan).spawns - nextSpawn + 1 else 0,
			restUntil = if state == "rest" then restUntil else nil,
		}
	end

	return self
end

return WaveDirector
