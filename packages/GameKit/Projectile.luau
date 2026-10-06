--!strict
-- @tier T0
-- Projectile: deterministic ballistic projectiles (gravity, linear drag, max range, lifetime,
-- swept radius, pierce) and server validation of client-predicted shots.
--   * Motion is the closed form of dv/dt = g - k v (k = drag; k = 0 is plain p0 + v t + g t^2/2),
--     so stepping 60 x 1/60 s lands where one 1 s step lands (to rounding) and every step's
--     segment starts where the last ended: no gaps for a cast to miss.
--   * step() casts each segment through an injected cast(origin, delta, radius, state) (Raycast or
--     Spherecast in HitboxRoblox; a fake world in Lune) and stops at the first non-pierceable hit.
--     The cast should ignore targets already in state.hitSet (the adapter filters them out);
--     repeats it returns anyway are skipped, at most MAX_SKIPS times a step.
--     Range is path length summed per step (chords); within a step, time is taken as
--     proportional to distance.
--   * simulation() runs many projectiles with stable integer ids and a cap; it never yields, so
--     an adapter steps it from RunService:BindToSimulation.
--   * validateFire/validateHit check a client-predicted shot in two phases: the fire request
--     (time inside the rewind window, muzzle near the shooter's rewound pose) and the later hit
--     report (on the server-recomputed trajectory within positionTolerance + radius studs after
--     searching +- timeTolerance seconds, inside range and lifetime, near the target's rewound
--     pose). A Spherecast reports the surface contact, up to radius off the path, hence + radius.
--     Tolerances are conventions: 2 studs and 0.1 s by default.
local Check = require("./Check")
local Hitbox = require("./Hitbox")
local Vec = require("../SceneKit/Vec")

local Projectile = {}
Projectile.DEFAULT_GRAVITY = 196.2 -- Workspace.Gravity default
Projectile.MAX_SPEED = 20000 -- studs/s sanity bound (convention)
Projectile.MAX_ACTIVE = 512
Projectile.POSITION_TOLERANCE = 2 -- studs (convention)
Projectile.TIME_TOLERANCE = 0.1 -- seconds (convention)
Projectile.SEARCH_SAMPLES = 32
Projectile.MAX_SKIPS = 8 -- repeated hits on an already-hit target skipped per step

export type V3 = Vec.V3
export type Definition = {
	speed: number,
	gravity: (number | V3)?,
	drag: number?,
	maxRange: number,
	maxLifetime: number?,
	radius: number?,
	pierce: number?,
}
export type Spec = {
	speed: number,
	gravity: V3,
	drag: number,
	maxRange: number,
	maxLifetime: number,
	radius: number,
	pierce: number,
}
export type State = {
	id: number,
	owner: any,
	origin: V3,
	position: V3,
	velocity: V3,
	age: number,
	travelled: number,
	alive: boolean,
	pierced: number,
	hits: { any },
	hitSet: { [any]: boolean }, -- keyed by the target value itself (ids, Instances)
	reason: string?,
}
export type Hit = { fraction: number, position: V3, normal: V3?, target: any?, pierceable: boolean? }
export type Cast = (origin: V3, delta: V3, radius: number, state: State) -> Hit?
export type Event = {
	kind: string, -- "hit" | "expired"
	id: number,
	owner: any,
	position: V3,
	normal: V3?,
	target: any?,
	age: number,
	reason: string?,
	pierced: boolean?, -- a hit the projectile passed through
}

local function isVec(value: any): boolean
	return type(value) == "table"
		and Check.finite(value.x)
		and Check.finite(value.y)
		and Check.finite(value.z)
end

-- Problems with a definition (empty when valid).
function Projectile.validate(def: any): { string }
	if type(def) ~= "table" then
		return { "definition must be a table" }
	end
	local problems = {}
	if not Check.finite(def.speed) or def.speed <= 0 or def.speed > Projectile.MAX_SPEED then
		table.insert(problems, string.format("speed must be finite and in (0, %d]", Projectile.MAX_SPEED))
	end
	local gravity = def.gravity
	if gravity ~= nil and not (Check.finite(gravity) and gravity >= 0) and not isVec(gravity) then
		table.insert(problems, "gravity must be a number >= 0 (downward magnitude) or a finite vector")
	end
	if def.drag ~= nil and (not Check.finite(def.drag) or def.drag < 0) then
		table.insert(problems, "drag must be a finite number >= 0 (1/s)")
	end
	if not Check.finite(def.maxRange) or def.maxRange <= 0 then
		table.insert(problems, "maxRange must be a finite number > 0")
	end
	if def.maxLifetime ~= nil and (not Check.finite(def.maxLifetime) or def.maxLifetime <= 0) then
		table.insert(problems, "maxLifetime must be a finite number > 0")
	end
	if def.radius ~= nil and (not Check.finite(def.radius) or def.radius < 0 or def.radius > 256) then
		table.insert(problems, "radius must be 0-256 (the Spherecast limit)")
	end
	if def.pierce ~= nil and (not Check.integer(def.pierce) or def.pierce < 0 or def.pierce > 64) then
		table.insert(problems, "pierce must be an integer 0-64")
	end
	return problems
end

function Projectile.define(def: Definition): Spec
	local problems = Projectile.validate(def)
	if #problems > 0 then
		error("Projectile.define: " .. table.concat(problems, "; "), 2)
	end
	local gravity: V3
	if def.gravity == nil then
		gravity = { x = 0, y = -Projectile.DEFAULT_GRAVITY, z = 0 }
	elseif type(def.gravity) == "number" then
		gravity = { x = 0, y = -def.gravity, z = 0 }
	else
		local g = def.gravity :: V3
		gravity = { x = g.x, y = g.y, z = g.z }
	end
	local lifetime = def.maxLifetime
	if lifetime == nil then
		-- Long enough to cover maxRange at muzzle speed several times over (drag slows it down).
		lifetime = math.max(1, 4 * def.maxRange / def.speed)
	end
	return table.freeze({
		speed = def.speed,
		gravity = table.freeze(gravity),
		drag = def.drag or 0,
		maxRange = def.maxRange,
		maxLifetime = lifetime :: number,
		radius = def.radius or 0,
		pierce = def.pierce or 0,
	})
end

-- ---------------------------------------------------------------- closed form

-- Velocity after t seconds from initial velocity v0.
function Projectile.velocityAt(spec: Spec, v0: V3, t: number): V3
	local g, k = spec.gravity, spec.drag
	if k == 0 then
		return Vec.add(v0, Vec.scale(g, t))
	end
	local terminal = Vec.scale(g, 1 / k)
	return Vec.add(terminal, Vec.scale(Vec.sub(v0, terminal), math.exp(-k * t)))
end

-- Position after t seconds from p0 with initial velocity v0.
function Projectile.positionAt(spec: Spec, p0: V3, v0: V3, t: number): V3
	local g, k = spec.gravity, spec.drag
	if k == 0 then
		return Vec.add(Vec.add(p0, Vec.scale(v0, t)), Vec.scale(g, 0.5 * t * t))
	end
	local terminal = Vec.scale(g, 1 / k)
	local decay = (1 - math.exp(-k * t)) / k
	return Vec.add(Vec.add(p0, Vec.scale(terminal, t)), Vec.scale(Vec.sub(v0, terminal), decay))
end

-- Path length from t = 0 to t (sum of chords over samples), for validation.
function Projectile.pathLength(spec: Spec, origin: V3, v0: V3, t: number, samples: number?): number
	local n = samples or Projectile.SEARCH_SAMPLES
	local total = 0
	local previous = origin
	for index = 1, n do
		local point = Projectile.positionAt(spec, origin, v0, t * index / n)
		total += Vec.length(Vec.sub(point, previous))
		previous = point
	end
	return total
end

-- ---------------------------------------------------------------- single projectile

-- A new projectile state (direction is normalised; a zero direction raises).
function Projectile.launch(
	spec: Spec,
	origin: V3,
	direction: V3,
	options: { id: number?, owner: any?, inherit: V3? }?
): State
	assert(isVec(origin), "Projectile.launch: origin must be a finite vector")
	assert(
		isVec(direction) and Vec.length(direction) > 1e-9,
		"Projectile.launch: direction must be a non-zero vector"
	)
	local velocity = Vec.scale(Vec.unit(direction), spec.speed)
	if options and options.inherit then
		assert(isVec(options.inherit), "Projectile.launch: inherit must be a finite vector")
		velocity = Vec.add(velocity, options.inherit)
	end
	return {
		id = (options and options.id) or 0,
		owner = options and options.owner,
		origin = Vec.new(origin.x, origin.y, origin.z),
		position = Vec.new(origin.x, origin.y, origin.z),
		velocity = velocity,
		age = 0,
		travelled = 0,
		alive = true,
		pierced = 0,
		hits = {},
		hitSet = {},
		reason = nil,
	}
end

local function validHit(hit: any): boolean
	return type(hit) == "table"
		and Check.finite(hit.fraction)
		and hit.fraction >= 0
		and hit.fraction <= 1
		and isVec(hit.position)
end

-- Advances one projectile by dt, casting the swept segment. Returns (state, events); a dead
-- projectile is left as it is. Raises on a bad dt (simulation code, not client input).
function Projectile.step(spec: Spec, state: State, dt: number, cast: Cast?): (State, { Event })
	local events: { Event } = {}
	if not state.alive then
		return state, events
	end
	assert(Check.finite(dt) and dt >= 0, "Projectile.step: dt must be finite and >= 0")
	local stepDt = dt
	local expire: string? = nil
	if state.age + dt >= spec.maxLifetime then
		stepDt = math.max(0, spec.maxLifetime - state.age)
		expire = "lifetime"
	end
	local p0, v0 = state.position, state.velocity
	local p1 = Projectile.positionAt(spec, p0, v0, stepDt)
	local chord = Vec.length(Vec.sub(p1, p0))
	local limit = 1
	if state.travelled + chord >= spec.maxRange then
		limit = if chord > 0 then math.clamp((spec.maxRange - state.travelled) / chord, 0, 1) else 0
		expire = "range"
	end
	local delta = Vec.scale(Vec.sub(p1, p0), limit)
	if cast then
		-- Each pass either ends the loop, stops the projectile, uses one pierce (bounded by
		-- spec.pierce) or skips a repeat (bounded by MAX_SKIPS), so it always terminates.
		local consumed = 0
		local skips = 0
		while consumed < 1 do
			local from = Vec.add(p0, Vec.scale(delta, consumed))
			local rest = Vec.scale(delta, 1 - consumed)
			if Vec.length(rest) <= 1e-9 then
				break
			end
			local hit = cast(from, rest, spec.radius, state)
			if hit == nil then
				break
			end
			if not validHit(hit) then
				error(
					"Projectile.step: cast returned a malformed hit (fraction 0-1 and a finite position)",
					2
				)
			end
			local h = hit :: Hit
			local f = consumed + (1 - consumed) * h.fraction
			local key = h.target
			if key and state.hitSet[key] then
				-- A target pierced earlier this flight (the cast should exclude state.hitSet, as
				-- HitboxRoblox does with its filter): step past it, a bounded number of times.
				skips += 1
				if skips > Projectile.MAX_SKIPS then
					break
				end
				consumed = f + 1e-6
				continue
			end
			local pierces = key ~= nil and h.pierceable ~= false and state.pierced < spec.pierce
			table.insert(events, {
				kind = "hit",
				id = state.id,
				owner = state.owner,
				position = Vec.new(h.position.x, h.position.y, h.position.z),
				normal = h.normal,
				target = h.target,
				age = state.age + stepDt * limit * f,
				pierced = pierces,
			})
			if key then
				state.hitSet[key] = true
				table.insert(state.hits, h.target)
			end
			if pierces then
				state.pierced += 1
				consumed = f
				continue
			end
			local used = stepDt * limit * f
			state.position = Vec.new(h.position.x, h.position.y, h.position.z)
			state.velocity = Projectile.velocityAt(spec, v0, used)
			state.age += used
			state.travelled += chord * limit * f
			state.alive = false
			state.reason = "hit"
			return state, events
		end
	end
	local used = stepDt * limit
	state.position = Vec.add(p0, delta)
	state.velocity = Projectile.velocityAt(spec, v0, used)
	state.age += used
	state.travelled += chord * limit
	if expire then
		state.alive = false
		state.reason = expire
		table.insert(events, {
			kind = "expired",
			id = state.id,
			owner = state.owner,
			position = Vec.new(state.position.x, state.position.y, state.position.z),
			age = state.age,
			reason = expire,
		})
	end
	return state, events
end

-- ---------------------------------------------------------------- simulation

local Simulation = {}
Simulation.__index = Simulation

type SimFields = {
	spec: Spec,
	_env: any,
	_active: { [number]: State },
	_count: number,
	_nextId: number,
	_max: number,
}
export type Simulation = typeof(setmetatable({} :: SimFields, Simulation))

function Projectile.simulation(spec: Spec, options: { maxActive: number? }?, env: any?): Simulation
	assert(
		type(spec) == "table" and table.isfrozen(spec),
		"Projectile.simulation needs a spec from Projectile.define"
	)
	local max = (options and options.maxActive) or Projectile.MAX_ACTIVE
	assert(Check.integer(max) and max >= 1, "Projectile.simulation: maxActive must be an integer >= 1")
	return setmetatable(
		{ spec = spec, _env = env, _active = {}, _count = 0, _nextId = 1, _max = max },
		Simulation
	)
end

-- Fires a projectile. (id, nil) or (nil, reason) with bad_input or full.
function Simulation.fire(
	self: Simulation,
	origin: V3,
	direction: V3,
	options: { owner: any?, inherit: V3? }?
): (number?, string?)
	if not isVec(origin) or not isVec(direction) or Vec.length(direction) <= 1e-9 then
		return nil, "bad_input"
	end
	if options and options.inherit ~= nil and not isVec(options.inherit) then
		return nil, "bad_input"
	end
	if self._count >= self._max then
		return nil, "full"
	end
	local id = self._nextId
	self._nextId += 1
	self._active[id] = Projectile.launch(
		self.spec,
		origin,
		direction,
		{ id = id, owner = options and options.owner, inherit = options and options.inherit }
	)
	self._count += 1
	return id, nil
end

-- Steps every projectile in id order; finished ones are removed. Returns their events in order.
function Simulation.step(self: Simulation, dt: number, cast: Cast?): { Event }
	local ids = {}
	for id in self._active do
		table.insert(ids, id)
	end
	table.sort(ids)
	local events = {}
	for _, id in ids do
		local state = self._active[id]
		local _, stepEvents = Projectile.step(self.spec, state, dt, cast)
		for _, event in stepEvents do
			table.insert(events, event)
		end
		if not state.alive then
			self._active[id] = nil
			self._count -= 1
		end
	end
	return events
end

function Simulation.get(self: Simulation, id: number): State?
	return self._active[id]
end

function Simulation.remove(self: Simulation, id: number): boolean
	if self._active[id] == nil then
		return false
	end
	self._active[id] = nil
	self._count -= 1
	return true
end

function Simulation.count(self: Simulation): number
	return self._count
end

-- ---------------------------------------------------------------- server validation

export type FireClaim = { origin: any, direction: any, time: any }
export type HitClaim = { hitPoint: any, time: any, target: any? }
export type ValidateOptions = {
	now: number,
	window: number?,
	originTolerance: number?,
	shooterPose: Hitbox.Shape?,
	targetPose: Hitbox.Shape?,
	hitTolerance: number?,
	positionTolerance: number?,
	timeTolerance: number?,
}
export type Detail = { flightTime: number?, error: number?, pathLength: number?, originError: number? }

local function windowOf(options: ValidateOptions): number
	local window = options.window or Hitbox.MAX_REWIND
	assert(Check.finite(window) and window >= 0, "Projectile: window must be finite and >= 0")
	return math.min(window, Hitbox.MAX_REWIND)
end

-- Phase 1: a fire request. (ok, reason?, detail) with bad_claim, future_time, too_old or
-- origin_mismatch (needs options.shooterPose: the shooter rewound to claim.time).
function Projectile.validateFire(
	_spec: Spec, -- for symmetry with validateHit; the fire check needs no ballistics
	claim: FireClaim,
	options: ValidateOptions
): (boolean, string?, Detail)
	local detail: Detail = {}
	if
		type(claim) ~= "table"
		or not isVec(claim.origin)
		or not isVec(claim.direction)
		or Vec.length(claim.direction) <= 1e-9
		or not Check.finite(claim.time)
	then
		return false, "bad_claim", detail
	end
	local now = options.now
	if claim.time > now + 0.01 then
		return false, "future_time", detail
	end
	if now - claim.time > windowOf(options) + 1e-9 then
		return false, "too_old", detail
	end
	if options.shooterPose then
		local err = Hitbox.distance(options.shooterPose, claim.origin)
		detail.originError = err
		if err > (options.originTolerance or 4) then
			return false, "origin_mismatch", detail
		end
	end
	return true, nil, detail
end

-- Smallest distance between the trajectory and point for flight times in [lo, hi]: (t, error).
local function closestTime(
	spec: Spec,
	origin: V3,
	v0: V3,
	point: V3,
	lo: number,
	hi: number
): (number, number)
	local function err(t: number): number
		return Vec.length(Vec.sub(Projectile.positionAt(spec, origin, v0, t), point))
	end
	if hi <= lo then
		return lo, err(lo)
	end
	local n = Projectile.SEARCH_SAMPLES
	local bestT, best = lo, err(lo)
	for index = 1, n do
		local t = lo + (hi - lo) * index / n
		local e = err(t)
		if e < best then
			bestT, best = t, e
		end
	end
	-- Refine around the best sample (the error is smooth and locally unimodal there).
	local step = (hi - lo) / n
	local a, b = math.max(lo, bestT - step), math.min(hi, bestT + step)
	for _ = 1, 40 do
		local m1, m2 = a + (b - a) / 3, b - (b - a) / 3
		if err(m1) <= err(m2) then
			b = m2
		else
			a = m1
		end
	end
	local t = (a + b) / 2
	local e = err(t)
	if e < best then
		return t, e
	end
	return bestT, best
end

-- Trajectory check alone: claim = { origin, direction, fireTime, hitTime, hitPoint }. Returns
-- (ok, reason?, detail) with bad_claim, bad_timing, too_late, off_trajectory, out_of_range.
function Projectile.validateShot(
	spec: Spec,
	claim: any,
	options: ValidateOptions?
): (boolean, string?, Detail)
	local detail: Detail = {}
	if
		type(claim) ~= "table"
		or not isVec(claim.origin)
		or not isVec(claim.direction)
		or Vec.length(claim.direction) <= 1e-9
		or not isVec(claim.hitPoint)
		or not Check.finite(claim.fireTime)
		or not Check.finite(claim.hitTime)
	then
		return false, "bad_claim", detail
	end
	local positionTolerance = (options and options.positionTolerance) or Projectile.POSITION_TOLERANCE
	local timeTolerance = (options and options.timeTolerance) or Projectile.TIME_TOLERANCE
	local flight = claim.hitTime - claim.fireTime
	if flight < -timeTolerance then
		return false, "bad_timing", detail
	end
	if flight > spec.maxLifetime + timeTolerance then
		return false, "too_late", detail
	end
	local origin = claim.origin :: V3
	local v0 = Vec.scale(Vec.unit(claim.direction :: V3), spec.speed)
	local lo = math.max(0, flight - timeTolerance)
	local hi = math.min(spec.maxLifetime, math.max(0, flight + timeTolerance))
	local t, err = closestTime(spec, origin, v0, claim.hitPoint :: V3, lo, hi)
	detail.flightTime = t
	detail.error = err
	if err > positionTolerance + spec.radius then
		return false, "off_trajectory", detail
	end
	local length = Projectile.pathLength(spec, origin, v0, t)
	detail.pathLength = length
	if length > spec.maxRange + positionTolerance then
		return false, "out_of_range", detail
	end
	return true, nil, detail
end

-- Phase 2: a hit report for a shot the server accepted (shot = { origin, direction, time }).
-- Adds future_time, too_old (the report must arrive within the rewind window of its hit time) and
-- target_mismatch (needs options.targetPose: the target rewound to claim.time) to validateShot.
function Projectile.validateHit(
	spec: Spec,
	shot: FireClaim,
	claim: HitClaim,
	options: ValidateOptions
): (boolean, string?, Detail)
	if type(claim) ~= "table" or not Check.finite(claim.time) or not isVec(claim.hitPoint) then
		return false, "bad_claim", {}
	end
	if claim.time > options.now + 0.01 then
		return false, "future_time", {}
	end
	if options.now - claim.time > windowOf(options) + 1e-9 then
		return false, "too_old", {}
	end
	local ok, reason, detail = Projectile.validateShot(spec, {
		origin = shot.origin,
		direction = shot.direction,
		fireTime = shot.time,
		hitTime = claim.time,
		hitPoint = claim.hitPoint,
	}, options)
	if not ok then
		return ok, reason, detail
	end
	if options.targetPose then
		if
			Hitbox.distance(options.targetPose, claim.hitPoint)
			> (options.hitTolerance or 0.5) + spec.radius
		then
			return false, "target_mismatch", detail
		end
	end
	return true, nil, detail
end

return Projectile
