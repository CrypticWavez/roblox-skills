--!strict
-- @tier T0
-- Vehicles: a pure arcade car model on the XZ plane (throttle, brake and reverse, speed-scaled
-- steering, lateral grip, handbrake drift, boost) integrated in fixed steps, plus rigPlan(),
-- the data VehicleRigRoblox turns into a VehicleSeat chassis with hinge and spring constraints.
--   * step(dt, input) accumulates dt and integrates whole fixed steps (default 1/60 s, at most
--     MAX_SUBSTEPS per call; the rest carries over), so the result depends on elapsed time and
--     input, not on how frames split it. Drift slip noise comes from a seeded ProcGen/Rng:
--     the same seed and the same inputs give the same path.
--   * Inputs are untrusted (they come from a client's IAS actions): non-finite values are 0
--     and everything is clamped. Vehicles.limits(spec) is the top speed for server travel checks
--     (Movement.checkTravel).
--   * Heading follows Roblox: yaw 0 looks down -Z (CFrame.LookVector), positive yaw turns left.
--   * No content: every number is the game's (an example lives in the docs, not here).
local Check = require("./Check")
local Signal = require("./Signal")
local Vec = require("../SceneKit/Vec")

local Vehicles = {}
Vehicles.STEP = 1 / 60
Vehicles.MAX_SUBSTEPS = 8
Vehicles.MAX_SPEED = 2000

export type V3 = Vec.V3
export type Definition = {
	maxSpeed: number,
	acceleration: number,
	brake: number,
	reverseSpeed: number?,
	coast: number?,
	steerRate: number,
	steerSpeed: number?,
	grip: number,
	drift: { grip: number, minSpeed: number?, steer: number?, exitSlip: number?, noise: number? }?,
	boost: { multiplier: number, duration: number, cooldown: number }?,
	step: number?,
	rig: {
		size: V3?,
		wheelRadius: number?,
		wheelBase: number?,
		trackWidth: number?,
		maxSteerAngle: number?,
		suspension: { stiffness: number, damping: number, travel: number }?,
		torque: number?,
	}?,
}
export type Spec = { [string]: any }
export type Input = { throttle: number?, steer: number?, handbrake: boolean?, boost: boolean? }
export type State = {
	position: V3,
	heading: number,
	velocity: V3,
	forwardSpeed: number,
	lateralSpeed: number,
	drifting: boolean,
	boostLeft: number,
	boostCooldown: number,
	odometer: number,
	time: number,
}
export type Event = { kind: string, t: number }

local function positive(value: any, hi: number): boolean
	return Check.finite(value) and value > 0 and value <= hi
end

-- Problems with a definition (empty when valid).
function Vehicles.validate(def: any): { string }
	if type(def) ~= "table" then
		return { "definition must be a table" }
	end
	local problems = {}
	local function need(ok: boolean, message: string)
		if not ok then
			table.insert(problems, message)
		end
	end
	need(positive(def.maxSpeed, Vehicles.MAX_SPEED), "maxSpeed must be in (0, 2000] studs/s")
	need(positive(def.acceleration, 1e5), "acceleration must be > 0 studs/s^2")
	need(positive(def.brake, 1e5), "brake must be > 0 studs/s^2")
	need(
		def.reverseSpeed == nil
			or (
				Check.finite(def.reverseSpeed)
				and def.reverseSpeed >= 0
				and def.reverseSpeed <= Vehicles.MAX_SPEED
			),
		"reverseSpeed must be 0-2000"
	)
	need(def.coast == nil or (Check.finite(def.coast) and def.coast >= 0), "coast must be >= 0 studs/s^2")
	need(positive(def.steerRate, 20), "steerRate must be in (0, 20] rad/s")
	need(
		def.steerSpeed == nil or positive(def.steerSpeed, Vehicles.MAX_SPEED),
		"steerSpeed must be in (0, 2000]"
	)
	need(
		Check.finite(def.grip) and def.grip >= 0 and def.grip <= 1000,
		"grip must be 0-1000 (1/s lateral damping)"
	)
	need(
		def.step == nil or (Check.finite(def.step) and def.step >= 1 / 240 and def.step <= 0.1),
		"step must be 1/240-0.1 s"
	)
	local drift = def.drift
	if drift ~= nil then
		if type(drift) ~= "table" then
			table.insert(problems, "drift must be a table")
		else
			need(
				Check.finite(drift.grip)
					and drift.grip >= 0
					and Check.finite(def.grip)
					and drift.grip <= def.grip,
				"drift.grip must be 0..grip"
			)
			need(
				drift.minSpeed == nil or (Check.finite(drift.minSpeed) and drift.minSpeed >= 0),
				"drift.minSpeed must be >= 0"
			)
			need(drift.steer == nil or positive(drift.steer, 5), "drift.steer must be in (0, 5]")
			need(
				drift.exitSlip == nil or (Check.finite(drift.exitSlip) and drift.exitSlip >= 0),
				"drift.exitSlip must be >= 0"
			)
			need(
				drift.noise == nil or (Check.finite(drift.noise) and drift.noise >= 0),
				"drift.noise must be >= 0"
			)
		end
	end
	local boost = def.boost
	if boost ~= nil then
		if type(boost) ~= "table" then
			table.insert(problems, "boost must be a table")
		else
			need(
				Check.finite(boost.multiplier) and boost.multiplier > 1 and boost.multiplier <= 5,
				"boost.multiplier must be in (1, 5]"
			)
			need(positive(boost.duration, 60), "boost.duration must be in (0, 60]")
			need(
				Check.finite(boost.cooldown) and boost.cooldown >= 0 and boost.cooldown <= 3600,
				"boost.cooldown must be 0-3600"
			)
		end
	end
	local rig = def.rig
	if rig ~= nil then
		if type(rig) ~= "table" then
			table.insert(problems, "rig must be a table")
		else
			if rig.size ~= nil then
				need(
					type(rig.size) == "table"
						and positive(rig.size.x, 512)
						and positive(rig.size.y, 512)
						and positive(rig.size.z, 512),
					"rig.size must be a vector of 0-512 studs"
				)
			end
			for _, field in { "wheelRadius", "wheelBase", "trackWidth" } do
				need(
					rig[field] == nil or positive(rig[field], 512),
					"rig." .. field .. " must be in (0, 512]"
				)
			end
			need(
				rig.maxSteerAngle == nil or positive(rig.maxSteerAngle, 80),
				"rig.maxSteerAngle must be in (0, 80] degrees"
			)
			need(rig.torque == nil or positive(rig.torque, 1e12), "rig.torque must be > 0")
			if rig.suspension ~= nil then
				local s = rig.suspension
				need(
					type(s) == "table"
						and positive(s.stiffness, 1e9)
						and Check.finite(s.damping)
						and s.damping >= 0
						and positive(s.travel, 64),
					"rig.suspension needs stiffness > 0, damping >= 0, travel in (0, 64]"
				)
			end
		end
	end
	return problems
end

function Vehicles.define(def: Definition): Spec
	local problems = Vehicles.validate(def)
	if #problems > 0 then
		error("Vehicles.define: " .. table.concat(problems, "; "), 2)
	end
	local spec = Check.copy(def) :: any
	spec.reverseSpeed = def.reverseSpeed or def.maxSpeed * 0.4
	spec.coast = def.coast or def.acceleration * 0.25
	spec.steerSpeed = def.steerSpeed or def.maxSpeed * 0.25
	spec.step = def.step or Vehicles.STEP
	if spec.drift then
		spec.drift.minSpeed = spec.drift.minSpeed or def.maxSpeed * 0.3
		spec.drift.steer = spec.drift.steer or 1.5
		spec.drift.exitSlip = spec.drift.exitSlip or 2
		spec.drift.noise = spec.drift.noise or 0
	end
	return Check.freeze(spec)
end

-- Top speed with boost, and no vertical allowance beyond the ground (for travel checks).
function Vehicles.limits(spec: Spec): { horizontal: number, rise: number }
	local boost = if spec.boost then spec.boost.multiplier else 1
	return { horizontal = spec.maxSpeed * boost, rise = spec.maxSpeed * 0.5 }
end

function Vehicles.forward(heading: number): V3
	return Vec.new(-math.sin(heading), 0, -math.cos(heading))
end

function Vehicles.right(heading: number): V3
	return Vec.new(math.cos(heading), 0, -math.sin(heading))
end

local function clampInput(value: any, lo: number, hi: number): number
	if not Check.finite(value) then
		return 0
	end
	return math.clamp(value, lo, hi)
end

-- ---------------------------------------------------------------- simulation

local Vehicle = {}
Vehicle.__index = Vehicle

type Fields = {
	spec: Spec,
	state: State,
	changed: Signal.Signal,
	_rng: any,
	_carry: number,
	_events: { Event },
}
export type Vehicle = typeof(setmetatable({} :: Fields, Vehicle))

-- A vehicle at position facing heading (radians). options.seed seeds drift noise.
function Vehicles.new(
	spec: Spec,
	options: { position: V3?, heading: number?, seed: (number | string)? }?,
	env: any
): Vehicle
	assert(
		type(spec) == "table" and table.isfrozen(spec) and spec.step,
		"Vehicles.new needs a spec from Vehicles.define"
	)
	assert(type(env) == "table" and type(env.rng) == "function", "Vehicles.new needs env.rng")
	local opts = options or {}
	local position = opts.position or Vec.new(0, 0, 0)
	local heading = opts.heading or 0
	assert(
		Check.finite(position.x) and Check.finite(position.y) and Check.finite(position.z),
		"Vehicles.new: position must be finite"
	)
	assert(Check.finite(heading), "Vehicles.new: heading must be finite")
	return setmetatable({
		spec = spec,
		state = {
			position = Vec.new(position.x, position.y, position.z),
			heading = heading,
			velocity = Vec.new(0, 0, 0),
			forwardSpeed = 0,
			lateralSpeed = 0,
			drifting = false,
			boostLeft = 0,
			boostCooldown = 0,
			odometer = 0,
			time = 0,
		},
		changed = Signal.new(env),
		_rng = env.rng(opts.seed or 0),
		_carry = 0,
		_events = {},
	}, Vehicle)
end

local function substep(
	self: Vehicle,
	h: number,
	throttle: number,
	steer: number,
	handbrake: boolean,
	boost: boolean
)
	local spec = self.spec
	local s = self.state
	local events = self._events
	-- Boost.
	if spec.boost then
		if boost and s.boostLeft <= 0 and s.boostCooldown <= 0 then
			s.boostLeft = spec.boost.duration
			s.boostCooldown = spec.boost.duration + spec.boost.cooldown
			table.insert(events, { kind = "boost_start", t = s.time })
		end
		if s.boostLeft > 0 then
			s.boostLeft = math.max(0, s.boostLeft - h)
			if s.boostLeft <= 1e-12 then
				s.boostLeft = 0
				table.insert(events, { kind = "boost_end", t = s.time + h })
			end
		end
		s.boostCooldown = math.max(0, s.boostCooldown - h)
	end
	local boosting = s.boostLeft > 0
	local multiplier = if boosting then spec.boost.multiplier else 1
	local top = spec.maxSpeed * multiplier
	local f = Vehicles.forward(s.heading)
	local r = Vehicles.right(s.heading)
	local vf = Vec.dot(s.velocity, f)
	local vr = Vec.dot(s.velocity, r)

	-- Longitudinal: throttle, brake, reverse, coast; over the top speed (boost ended) it coasts down.
	if throttle > 0 then
		if vf < 0 then
			vf = math.min(0, vf + spec.brake * throttle * h)
		elseif vf < top then
			vf = math.min(top, vf + spec.acceleration * multiplier * throttle * h)
		else
			vf = math.max(top, vf - spec.coast * h)
		end
	elseif throttle < 0 then
		if vf > 0 then
			vf = math.max(0, vf + spec.brake * throttle * h)
		else
			vf = math.max(-spec.reverseSpeed, vf + spec.acceleration * throttle * h)
		end
	else
		local drop = spec.coast * h
		vf = if vf > 0 then math.max(0, vf - drop) else math.min(0, vf + drop)
	end

	-- Drift state.
	local drift = spec.drift
	if drift then
		if not s.drifting and handbrake and math.abs(vf) >= drift.minSpeed then
			s.drifting = true
			table.insert(events, { kind = "drift_start", t = s.time })
		elseif
			s.drifting
			and ((not handbrake and math.abs(vr) <= drift.exitSlip) or math.abs(vf) < drift.minSpeed * 0.5)
		then
			-- Released and gripping again, or slowed below half the drift speed.
			s.drifting = false
			table.insert(events, { kind = "drift_end", t = s.time })
		end
	end

	-- Steering scales with speed up to steerSpeed and flips in reverse.
	local authority = math.clamp(math.abs(vf) / spec.steerSpeed, 0, 1)
	local direction = if vf >= 0 then 1 else -1
	local rate = steer * spec.steerRate * authority * direction
	if s.drifting then
		rate *= drift.steer
	end
	local turn = rate * h
	-- Rotating the heading leaves the momentum pointing the old way: that is the slip grip removes.
	local newHeading = s.heading + turn
	local velocity = Vec.add(Vec.scale(f, vf), Vec.scale(r, vr))
	local nf = Vehicles.forward(newHeading)
	local nr = Vehicles.right(newHeading)
	vf = Vec.dot(velocity, nf)
	vr = Vec.dot(velocity, nr)
	local grip = if s.drifting then drift.grip else spec.grip
	vr *= math.exp(-grip * h)
	if s.drifting and drift.noise > 0 then
		vr += (self._rng:next() * 2 - 1) * drift.noise * h
	end
	s.heading = newHeading
	s.velocity = Vec.add(Vec.scale(nf, vf), Vec.scale(nr, vr))
	local moved = Vec.scale(s.velocity, h)
	s.position = Vec.add(s.position, moved)
	s.odometer += Vec.length(moved)
	s.forwardSpeed = vf
	s.lateralSpeed = vr
	s.time += h
end

-- Advances by dt with input (clamped; non-finite values are 0). Returns (state, events).
-- Never yields; integrates whole fixed steps and carries the remainder.
function Vehicle.step(self: Vehicle, dt: number, input: Input?): (State, { Event })
	assert(Check.finite(dt) and dt >= 0, "Vehicle.step: dt must be finite and >= 0")
	local i = input or {}
	local throttle = clampInput(i.throttle, -1, 1)
	local steer = clampInput(i.steer, -1, 1)
	local handbrake = i.handbrake == true
	local boost = i.boost == true
	local h = self.spec.step
	self._carry += dt
	local steps = 0
	while self._carry + 1e-9 >= h and steps < Vehicles.MAX_SUBSTEPS do
		substep(self, h, throttle, steer, handbrake, boost)
		self._carry -= h
		steps += 1
	end
	if steps == Vehicles.MAX_SUBSTEPS and self._carry >= h then
		self._carry = 0 -- a long hitch is dropped, not replayed in a burst
	end
	self._carry = math.max(0, self._carry)
	local events = self._events
	self._events = {}
	if #events > 0 then
		self.changed:Fire(events)
	end
	return self.state, events
end

function Vehicle.speed(self: Vehicle): number
	return Vec.length(self.state.velocity)
end

-- Places the vehicle (respawn, reset to track) and stops it.
function Vehicle.place(self: Vehicle, position: V3, heading: number)
	assert(
		Check.finite(position.x)
			and Check.finite(position.y)
			and Check.finite(position.z)
			and Check.finite(heading),
		"Vehicle.place: finite position and heading"
	)
	local s = self.state
	s.position = Vec.new(position.x, position.y, position.z)
	s.heading = heading
	s.velocity = Vec.new(0, 0, 0)
	s.forwardSpeed = 0
	s.lateralSpeed = 0
	s.drifting = false
	self._carry = 0
end

-- A compact, rounded snapshot for digests and attributes.
function Vehicle.snapshot(self: Vehicle): { [string]: number | boolean }
	local s = self.state
	local function r(x: number): number
		return math.round(x * 1000) / 1000
	end
	return {
		x = r(s.position.x),
		z = r(s.position.z),
		heading = r(s.heading),
		speed = r(Vec.length(s.velocity)),
		slip = r(s.lateralSpeed),
		drifting = s.drifting,
		boost = r(s.boostLeft),
	}
end

function Vehicle.destroy(self: Vehicle)
	self.changed:Destroy()
end

-- ---------------------------------------------------------------- rig plan

-- The chassis description VehicleRigRoblox builds: a body part, four wheels with motor hinges
-- (rear drive), steering hinges (front, servo), springs and a VehicleSeat. Pure data; sizes
-- are the game's (rig fields) or neutral defaults.
function Vehicles.rigPlan(spec: Spec): { [string]: any }
	local rig = spec.rig or {}
	local size = rig.size or Vec.new(6, 2, 10)
	local radius = rig.wheelRadius or 1.2
	local base = rig.wheelBase or size.z * 0.8
	local track = rig.trackWidth or size.x + radius
	local suspension = rig.suspension or { stiffness = 4000, damping = 200, travel = 1 }
	local wheels = {}
	for _, corner in
		{ { "front_left", -1, -1 }, { "front_right", 1, -1 }, { "rear_left", -1, 1 }, { "rear_right", 1, 1 } }
	do
		local name, sx, sz = corner[1], corner[2], corner[3]
		table.insert(wheels, {
			name = name,
			offset = Vec.new(sx * track / 2, -size.y / 2, sz * base / 2),
			radius = radius,
			width = radius * 0.8,
			steer = sz < 0,
			drive = sz > 0,
		})
	end
	local maxAngular = spec.maxSpeed / radius
	return {
		body = { size = size },
		seat = {
			offset = Vec.new(0, size.y / 2 + 0.5, 0),
			maxSpeed = spec.maxSpeed,
			torque = rig.torque or 10000,
			turnSpeed = spec.steerRate,
		},
		wheels = wheels,
		motor = { maxAngularVelocity = maxAngular, maxTorque = rig.torque or 10000 },
		steering = { maxAngle = rig.maxSteerAngle or 30, servoMaxTorque = (rig.torque or 10000) * 2 },
		suspension = {
			stiffness = suspension.stiffness,
			damping = suspension.damping,
			freeLength = suspension.travel * 2,
			minLength = 0,
			maxLength = suspension.travel * 3,
		},
	}
end

return Vehicles
