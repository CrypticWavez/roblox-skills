--!strict
-- @tier T0
-- Knockback: velocity-change maths for hits and blasts, with no physics in the core. compute()
-- turns an origin, a target position (or an explicit direction), a force and an optional lift
-- into a velocity change; radius + falloff scale blasts by distance; resistance (0-1, e.g. a
-- StatusEffects multiplier) and maxSpeed cap it. A tracker adds the rules that keep combat fair:
-- a ragdoll request (an event, never a physics call) when the speed reaches a threshold, an
-- immunity window after a ragdoll, and a combo limit per target so juggles end. The adapter
-- applies the result: BasePart:ApplyImpulse(Knockback.impulse(result, mass)) or the assembly's
-- velocity, and a Ragdoll state when ragdollRequested fires.
--   local kb = Knockback.new({ ragdollThreshold = 80, comboWindow = 2, comboLimit = 4 }, env)
--   kb.ragdollRequested:Connect(function(target, request) ... end)
--   local result, reason = kb:apply("7", { origin = a, target = b, force = 60, upward = 25 })
local Check = require("./Check")
local Signal = require("./Signal")
local Vec = require("../SceneKit/Vec")

local Knockback = {}
Knockback.__index = Knockback
Knockback.FALLOFF = table.freeze({ none = true, linear = true, quadratic = true })
Knockback.DEFAULT_RAGDOLL = 1.5 -- seconds (convention)
Knockback.MAX_FORCE = 10000 -- studs/s; far beyond any sane hit (convention)

export type V3 = Vec.V3
export type Params = {
	origin: V3,
	target: V3,
	direction: V3?,
	force: number,
	upward: number?,
	radius: number?,
	falloff: string?,
	resistance: number?,
	maxSpeed: number?,
	horizontal: boolean?,
}
export type Result = {
	velocity: V3,
	speed: number,
	strength: number,
	direction: V3,
	ragdoll: boolean,
	ragdollDuration: number,
}
export type Options = {
	ragdollThreshold: number?,
	ragdollDuration: (number | (speed: number) -> number)?,
	immunity: number?,
	immunityScale: number?,
	comboWindow: number?,
	comboLimit: number?,
}

local function isVec(value: any): boolean
	return type(value) == "table"
		and Check.finite(value.x)
		and Check.finite(value.y)
		and Check.finite(value.z)
end

-- Problems with compute() parameters (empty when valid).
function Knockback.validate(params: any): { string }
	if type(params) ~= "table" then
		return { "params must be a table" }
	end
	local problems = {}
	if not isVec(params.origin) then
		table.insert(problems, "origin must be a finite vector")
	end
	if not isVec(params.target) then
		table.insert(problems, "target must be a finite vector")
	end
	if params.direction ~= nil and not isVec(params.direction) then
		table.insert(problems, "direction must be a finite vector")
	end
	if not Check.finite(params.force) or params.force < 0 or params.force > Knockback.MAX_FORCE then
		table.insert(problems, string.format("force must be finite and 0-%d", Knockback.MAX_FORCE))
	end
	if
		params.upward ~= nil
		and (not Check.finite(params.upward) or math.abs(params.upward) > Knockback.MAX_FORCE)
	then
		table.insert(problems, "upward must be finite")
	end
	if params.radius ~= nil and (not Check.finite(params.radius) or params.radius <= 0) then
		table.insert(problems, "radius must be finite and > 0")
	end
	if params.falloff ~= nil and not Knockback.FALLOFF[params.falloff] then
		table.insert(problems, "falloff must be none, linear or quadratic")
	end
	if params.resistance ~= nil and not Check.finite(params.resistance) then
		table.insert(problems, "resistance must be finite")
	end
	if params.maxSpeed ~= nil and (not Check.finite(params.maxSpeed) or params.maxSpeed < 0) then
		table.insert(problems, "maxSpeed must be finite and >= 0")
	end
	return problems
end

-- The velocity change for one hit. Raises on invalid params (they come from game code).
-- Direction: params.direction, else target - origin; horizontal (default true) drops the vertical
-- part so lift comes only from upward. A zero direction (target on the origin) pushes straight up.
function Knockback.compute(params: Params): Result
	local problems = Knockback.validate(params)
	if #problems > 0 then
		error("Knockback.compute: " .. table.concat(problems, "; "), 2)
	end
	local horizontal = params.horizontal ~= false
	local raw = params.direction or Vec.sub(params.target, params.origin)
	if horizontal then
		raw = { x = raw.x, y = 0, z = raw.z }
	end
	local direction = Vec.unit(raw)
	local strength = 1
	if params.radius then
		local distance = Vec.length(Vec.sub(params.target, params.origin))
		if distance >= params.radius then
			strength = 0
		else
			local falloff = params.falloff or "linear"
			local t = 1 - distance / params.radius
			strength = if falloff == "none" then 1 elseif falloff == "linear" then t else t * t
		end
	end
	strength *= 1 - math.clamp(params.resistance or 0, 0, 1)
	local upward = params.upward or 0
	local velocity =
		Vec.add(Vec.scale(direction, params.force * strength), { x = 0, y = upward * strength, z = 0 })
	local speed = Vec.length(velocity)
	if params.maxSpeed and speed > params.maxSpeed then
		velocity = if speed > 0 then Vec.scale(velocity, params.maxSpeed / speed) else velocity
		speed = params.maxSpeed
	end
	return {
		velocity = velocity,
		speed = speed,
		strength = strength,
		direction = direction,
		ragdoll = false,
		ragdollDuration = 0,
	}
end

-- The impulse (mass x velocity change) for BasePart:ApplyImpulse.
function Knockback.impulse(result: Result, mass: number): V3
	Check.assertFinite(mass, "Knockback.impulse mass")
	assert(mass >= 0, "Knockback.impulse: mass must be >= 0")
	return Vec.scale(result.velocity, mass)
end

type Fields = {
	options: Options,
	applied: Signal.Signal,
	ragdollRequested: Signal.Signal,
	_env: any,
	_immuneUntil: { [string]: number },
	_history: { [string]: { number } },
}
export type Tracker = typeof(setmetatable({} :: Fields, Knockback))

function Knockback.new(options: Options?, env: any): Tracker
	assert(type(env) == "table" and type(env.clock) == "function", "Knockback.new needs an env with clock()")
	local opts: Options = options or {}
	local problems = {}
	for _, key in { "ragdollThreshold", "immunity", "comboWindow" } do
		local value = (opts :: any)[key]
		if value ~= nil and (not Check.finite(value) or value < 0) then
			table.insert(problems, key .. " must be finite and >= 0")
		end
	end
	if
		opts.immunityScale ~= nil
		and (not Check.finite(opts.immunityScale) or opts.immunityScale < 0 or opts.immunityScale > 1)
	then
		table.insert(problems, "immunityScale must be 0-1")
	end
	if opts.comboLimit ~= nil and (not Check.integer(opts.comboLimit) or opts.comboLimit < 1) then
		table.insert(problems, "comboLimit must be an integer >= 1")
	end
	local duration = opts.ragdollDuration
	if
		duration ~= nil
		and type(duration) ~= "function"
		and (not Check.finite(duration) or (duration :: number) < 0)
	then
		table.insert(problems, "ragdollDuration must be finite and >= 0, or a function of speed")
	end
	if #problems > 0 then
		error("Knockback.new: " .. table.concat(problems, "; "), 2)
	end
	return setmetatable({
		options = table.freeze(table.clone(opts)),
		applied = Signal.new(env),
		ragdollRequested = Signal.new(env),
		_env = env,
		_immuneUntil = {},
		_history = {},
	}, Knockback)
end

local function key(id: any): string
	return tostring(id)
end

-- Applies knockback to target (any id). Returns (result, nil) or (nil, reason) with bad_params,
-- immune, combo_limit or no_effect. A ragdoll is requested (signal) when the speed reaches
-- ragdollThreshold; the target is then immune (or scaled by immunityScale) until the ragdoll
-- plus the immunity window ends.
function Knockback.apply(self: Tracker, target: any, params: Params): (Result?, string?)
	if #Knockback.validate(params) > 0 then
		return nil, "bad_params"
	end
	local id = key(target)
	local now = self._env.clock()
	local opts = self.options
	local scale = 1
	if (self._immuneUntil[id] or -math.huge) > now then
		scale = opts.immunityScale or 0
		if scale <= 0 then
			return nil, "immune"
		end
	end
	if opts.comboLimit and opts.comboWindow then
		local history: { number } = self._history[id] or {}
		local kept = {}
		for _, at in history do
			if now - at < opts.comboWindow then
				table.insert(kept, at)
			end
		end
		self._history[id] = kept
		if #kept >= opts.comboLimit then
			return nil, "combo_limit"
		end
	end
	local result = Knockback.compute(params)
	if scale ~= 1 then
		result.velocity = Vec.scale(result.velocity, scale)
		result.speed *= scale
		result.strength *= scale
	end
	if result.speed <= 0 then
		return nil, "no_effect"
	end
	if opts.comboLimit and opts.comboWindow then
		table.insert(self._history[id], now)
	end
	local threshold = opts.ragdollThreshold
	if threshold and result.speed >= threshold then
		local duration = opts.ragdollDuration
		local seconds: number = if type(duration) == "function"
			then duration(result.speed)
			else (duration :: number?) or Knockback.DEFAULT_RAGDOLL
		if not Check.finite(seconds) or seconds < 0 then
			seconds = Knockback.DEFAULT_RAGDOLL
		end
		result.ragdoll = true
		result.ragdollDuration = seconds
		self._immuneUntil[id] = now + seconds + (opts.immunity or 0)
		self.ragdollRequested:Fire(
			target,
			{ duration = seconds, velocity = result.velocity, speed = result.speed }
		)
	end
	self.applied:Fire(target, result)
	return result, nil
end

-- Whether target is inside a post-ragdoll immunity window.
function Knockback.immune(self: Tracker, target: any): boolean
	return (self._immuneUntil[key(target)] or -math.huge) > self._env.clock()
end

-- Drops a target's state (despawn, PlayerRemoving).
function Knockback.forget(self: Tracker, target: any)
	self._immuneUntil[key(target)] = nil
	self._history[key(target)] = nil
end

return Knockback
