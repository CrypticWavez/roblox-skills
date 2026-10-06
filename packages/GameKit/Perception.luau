--!strict
-- @tier T0
-- Perception: what an agent sees, hears and remembers. Sight is a cone (fov degrees, sightRange
-- studs) checked against an occlusion hook the adapter supplies (a raycast in Roblox, a grid line
-- in specs); hearing takes noise events within hearingRange x loudness; memory keeps the last
-- known position of each target with a confidence that falls linearly from 1 to 0 over `memory`
-- seconds after it was last sensed (then the target is forgotten). Vectors are { x, y, z }
-- tables; time comes from env.clock. sense() never yields, so it can run in a simulation step.
local Check = require("./Check")

local Perception = {}

export type V3 = { x: number, y: number, z: number }
export type Observer = { pos: V3, look: V3 } -- look: facing direction (any length > 0)
export type Target = { id: string, pos: V3 }
export type Options = {
	fov: number?, -- full cone angle, degrees (default 110, convention)
	sightRange: number?, -- studs (default 80, convention)
	hearingRange: number?, -- studs for loudness 1 (default 40, convention)
	memory: number?, -- seconds a sensed target is remembered (default 6, convention)
	eyeHeight: number?, -- added to observer.pos.y for sight lines (default 0)
	occluded: ((from: V3, to: V3) -> boolean)?, -- true when something blocks the line
}
export type Memory = {
	id: string,
	pos: V3, -- last known position
	seen: boolean, -- sensed by sight on the latest sense()/hear() that touched it
	heard: boolean,
	at: number, -- clock time of the last sensing
	confidence: number, -- 1 when just sensed, 0 at `memory` seconds
}

Perception.DEFAULTS =
	table.freeze({ fov = 110, sightRange = 80, hearingRange = 40, memory = 6, eyeHeight = 0 })

local function option(options: Options?, key: string): any
	local value = options and (options :: any)[key]
	if value == nil then
		return (Perception.DEFAULTS :: any)[key]
	end
	return value
end

function Perception.validate(options: Options?): { string }
	local problems = {}
	local fov = option(options, "fov")
	if not Check.finite(fov) or fov <= 0 or fov > 360 then
		table.insert(problems, "fov must be in (0, 360] degrees")
	end
	for _, key in { "sightRange", "hearingRange", "memory" } do
		local value = option(options, key)
		if not Check.finite(value) or value <= 0 then
			table.insert(problems, key .. " must be a finite number > 0")
		end
	end
	if not Check.finite(option(options, "eyeHeight")) then
		table.insert(problems, "eyeHeight must be finite")
	end
	local occluded = options and options.occluded
	if occluded ~= nil and type(occluded) ~= "function" then
		table.insert(problems, "occluded must be a function")
	end
	return problems
end

-- (visible, reason): reason is "range", "angle" or "occluded" when not visible.
function Perception.canSee(observer: Observer, target: V3, options: Options?): (boolean, string?)
	local eye = { x = observer.pos.x, y = observer.pos.y + option(options, "eyeHeight"), z = observer.pos.z }
	local dx, dy, dz = target.x - eye.x, target.y - eye.y, target.z - eye.z
	local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
	if distance > option(options, "sightRange") then
		return false, "range"
	end
	if distance > 1e-9 then
		local look = observer.look
		local length = math.sqrt(look.x * look.x + look.y * look.y + look.z * look.z)
		assert(length > 0, "Perception.canSee: observer.look must not be zero")
		local cos = (dx * look.x + dy * look.y + dz * look.z) / (distance * length)
		if cos < math.cos(math.rad(option(options, "fov") / 2)) - 1e-9 then
			return false, "angle"
		end
	end
	local occluded = options and options.occluded
	if occluded and occluded(eye, target) then
		return false, "occluded"
	end
	return true, nil
end

-- Whether a noise of `loudness` (default 1) at `source` reaches a listener at `listener`.
function Perception.canHear(listener: V3, source: V3, loudness: number?, options: Options?): boolean
	local dx, dy, dz = source.x - listener.x, source.y - listener.y, source.z - listener.z
	return math.sqrt(dx * dx + dy * dy + dz * dz) <= option(options, "hearingRange") * (loudness or 1)
end

export type Perceiver = {
	options: Options,
	sense: (self: Perceiver, observer: Observer, targets: { Target }) -> { Memory },
	hear: (self: Perceiver, listener: V3, noise: { id: string, pos: V3, loudness: number? }) -> boolean,
	known: (self: Perceiver) -> { Memory },
	best: (self: Perceiver) -> Memory?,
	forget: (self: Perceiver, id: string?) -> (),
}

function Perception.new(options: Options?, env: any): Perceiver
	local problems = Perception.validate(options)
	if type(env) ~= "table" or type(env.clock) ~= "function" then
		table.insert(problems, "env.clock is required")
	end
	if #problems > 0 then
		error("Perception.new: " .. table.concat(problems, "; "), 2)
	end
	local memories: { [string]: Memory } = {}
	local span = option(options, "memory")
	local self: any = { options = table.clone(options or {}) }

	local function decay(now: number)
		for id, m in memories do
			m.confidence = math.max(0, 1 - (now - m.at) / span)
			if m.confidence <= 0 then
				memories[id] = nil
			end
		end
	end

	local function sorted(): { Memory }
		local out = {}
		for _, m in memories do
			table.insert(out, m)
		end
		table.sort(out, function(a, b)
			if a.confidence ~= b.confidence then
				return a.confidence > b.confidence
			end
			return a.id < b.id
		end)
		return out
	end

	-- Looks at every target, refreshes memory for the visible ones and decays the rest. Returns
	-- the memory, most confident first.
	function self.sense(_, observer: Observer, targets: { Target }): { Memory }
		local now = env.clock()
		for _, m in memories do
			m.seen = false
		end
		for _, target in targets do
			if Perception.canSee(observer, target.pos, options) then
				local m = memories[target.id] or { id = target.id, heard = false } :: any
				m.pos, m.seen, m.at, m.confidence = table.clone(target.pos), true, now, 1
				memories[target.id] = m
			end
		end
		decay(now)
		return sorted()
	end

	-- A noise event; returns whether it was heard (and remembered at the noise position).
	function self.hear(_, listener: V3, noise: { id: string, pos: V3, loudness: number? }): boolean
		if not Perception.canHear(listener, noise.pos, noise.loudness, options) then
			return false
		end
		local now = env.clock()
		local m = memories[noise.id] or { id = noise.id, seen = false } :: any
		m.pos, m.heard, m.at, m.confidence = table.clone(noise.pos), true, now, 1
		memories[noise.id] = m
		return true
	end

	function self.known(_): { Memory }
		decay(env.clock())
		return sorted()
	end

	function self.best(_): Memory?
		return self:known()[1]
	end

	function self.forget(_, id: string?)
		if id == nil then
			table.clear(memories)
		else
			memories[id] = nil
		end
	end

	return self
end

return Perception
