--!strict
-- G2 Vehicles: definition checks, determinism with the same seed, independence from how frames
-- split time, throttle/brake/reverse, top speed and boost, steering authority, grip and drift,
-- untrusted inputs, hitch handling and the rig plan.
local FakeEnv = require("./fakes/FakeEnv")
local Vehicles = require("../packages/GameKit/Vehicles")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function has(list: { string }, needle: string): boolean
	for _, item in list do
		if string.find(item, needle, 1, true) then
			return true
		end
	end
	return false
end

local NAN = 0 / 0

local DEF = {
	maxSpeed = 50,
	acceleration = 20,
	brake = 40,
	reverseSpeed = 10,
	coast = 5,
	steerRate = 2,
	steerSpeed = 10,
	grip = 8,
	drift = { grip = 1, minSpeed = 15, steer = 1.5, exitSlip = 2, noise = 6 },
	boost = { multiplier = 1.5, duration = 2, cooldown = 3 },
}

local function car(seed: any?, def: any?)
	return Vehicles.new(Vehicles.define(def or DEF), { seed = seed }, FakeEnv.new())
end

-- A fixed input script: accelerate, turn, drift, boost, brake.
local function drive(vehicle: any, dt: number): { [string]: any }
	local events = {}
	local function run(seconds: number, input: any)
		local steps = math.round(seconds / dt)
		for _ = 1, steps do
			local _, stepEvents = vehicle:step(dt, input)
			for _, event in stepEvents do
				table.insert(events, string.format("%s@%.4f", event.kind, event.t))
			end
		end
	end
	run(2, { throttle = 1 })
	run(1, { throttle = 1, steer = 1 })
	run(1, { throttle = 1, steer = 1, handbrake = true })
	run(0.5, { throttle = 1 })
	run(1, { throttle = 1, boost = true })
	run(1, { throttle = -1 })
	return { snapshot = vehicle:snapshot(), events = events }
end

test("validate: every problem is listed; define fills derived defaults", function(t)
	local problems = Vehicles.validate({
		maxSpeed = 0,
		acceleration = NAN,
		brake = -1,
		steerRate = 30,
		grip = 2,
		drift = { grip = 3, noise = -1 },
		boost = { multiplier = 1, duration = 0, cooldown = -1 },
		step = 1,
		rig = { wheelRadius = 0, suspension = { stiffness = 0 } },
	})
	for _, needle in
		{
			"maxSpeed",
			"acceleration",
			"brake",
			"steerRate",
			"drift.grip",
			"drift.noise",
			"boost.multiplier",
			"boost.duration",
			"boost.cooldown",
			"step",
			"rig.wheelRadius",
			"rig.suspension",
		}
	do
		t.ok(has(problems, needle), needle)
	end
	t.eq(Vehicles.validate(42)[1], "definition must be a table")
	local spec = Vehicles.define({ maxSpeed = 40, acceleration = 10, brake = 20, steerRate = 1, grip = 5 })
	t.eq(spec.reverseSpeed, 16)
	t.eq(spec.step, 1 / 60)
	t.ok(not pcall(Vehicles.define, { maxSpeed = 1 } :: any))
	t.eq(Vehicles.limits(Vehicles.define(DEF :: any)).horizontal, 75)
end)

test("determinism: the same seed and inputs give the same path; another seed drifts differently", function(t)
	local a = drive(car(7), 1 / 60)
	local b = drive(car(7), 1 / 60)
	local c = drive(car(8), 1 / 60)
	t.eq(a, b)
	t.ok(a.snapshot.x ~= c.snapshot.x or a.snapshot.z ~= c.snapshot.z, "drift noise follows the seed")
	-- Without noise the seed does not matter.
	local quiet = table.clone(DEF) :: any
	quiet.drift = { grip = 1, minSpeed = 15, steer = 1.5, exitSlip = 2, noise = 0 }
	t.eq(drive(car(1, quiet), 1 / 60), drive(car(2, quiet), 1 / 60))
	t.ok(#a.events >= 4, table.concat(a.events, " "))
end)

test("fixed steps: 60 Hz, 30 Hz and 12 Hz frames give identical results", function(t)
	local fine = drive(car(3), 1 / 60)
	t.eq(drive(car(3), 1 / 30), fine)
	t.eq(drive(car(3), 1 / 12), fine)
end)

test("longitudinal: acceleration, top speed, coast, brake then reverse", function(t)
	local v = car(0)
	for _ = 1, 60 do
		v:step(1 / 60, { throttle = 1 })
	end
	t.near(v.state.forwardSpeed, 20, 1e-9)
	t.ok(v.state.position.z < -9 and math.abs(v.state.position.x) < 1e-9, "heading 0 drives down -Z")
	for _ = 1, 600 do
		v:step(1 / 60, { throttle = 1 })
	end
	t.near(v.state.forwardSpeed, 50, 1e-9, "capped at maxSpeed")
	for _ = 1, 60 do
		v:step(1 / 60, {})
	end
	t.near(v.state.forwardSpeed, 45, 1e-9, "coasts down at 5 studs/s^2")
	for _ = 1, 120 do
		v:step(1 / 60, { throttle = -1 })
	end
	t.ok(v.state.forwardSpeed < 0, "brakes (45 / 40 s) then reverses")
	for _ = 1, 600 do
		v:step(1 / 60, { throttle = -1 })
	end
	t.near(v.state.forwardSpeed, -10, 1e-9, "reverse speed cap")
end)

test("boost: raises the cap for its duration, has a cooldown, then coasts back down", function(t)
	local v = car(0)
	for _ = 1, 600 do
		v:step(1 / 60, { throttle = 1 })
	end
	local log = {}
	for _ = 1, 150 do
		local _, events = v:step(1 / 60, { throttle = 1, boost = true })
		for _, event in events do
			table.insert(log, event.kind)
		end
	end
	t.eq(log, { "boost_start", "boost_end" })
	t.ok(v.state.forwardSpeed > 50 and v.state.forwardSpeed <= 75)
	-- Holding boost during the cooldown does nothing.
	local again = {}
	for _ = 1, 120 do
		local _, events = v:step(1 / 60, { throttle = 1, boost = true })
		for _, event in events do
			table.insert(again, event.kind)
		end
	end
	t.eq(#again, 0, "cooldown 3 s after a 2 s boost")
	-- The boost's last step (step 120) already coasts: 151 steps at 5 studs/s^2 from 75.
	t.near(v.state.forwardSpeed, 75 - 151 * 5 / 60, 1e-6, "over the cap it coasts down")
	for _ = 1, 300 do
		v:step(1 / 60, { throttle = 1 })
	end
	t.near(v.state.forwardSpeed, 50, 1e-6, "and settles on the normal cap")
end)

test(
	"steering: no turn at rest, speed-scaled authority, reversed in reverse; grip and drift slip",
	function(t)
		local v = car(0)
		for _ = 1, 60 do
			v:step(1 / 60, { steer = 1 })
		end
		t.eq(v.state.heading, 0, "a parked car does not turn")
		for _ = 1, 120 do
			v:step(1 / 60, { throttle = 1 })
		end
		local before = v.state.heading
		v:step(1 / 60, { throttle = 1, steer = 1 })
		t.near(v.state.heading - before, 2 / 60, 1e-12, "full authority above steerSpeed")
		local reverse = car(0)
		for _ = 1, 600 do
			reverse:step(1 / 60, { throttle = -1 })
		end
		reverse:step(1 / 60, { throttle = -1, steer = 1 })
		t.ok(reverse.state.heading < 0, "steering flips in reverse")

		-- Grip vs drift: the same turn slips far more with the handbrake.
		local function slipAfter(handbrake: boolean): number
			local quiet = table.clone(DEF) :: any
			quiet.drift = { grip = 1, minSpeed = 15, steer = 1.5, exitSlip = 2, noise = 0 }
			local c = car(0, quiet)
			for _ = 1, 150 do
				c:step(1 / 60, { throttle = 1 })
			end
			local most = 0
			for _ = 1, 30 do
				c:step(1 / 60, { throttle = 1, steer = 1, handbrake = handbrake })
				most = math.max(most, math.abs(c.state.lateralSpeed))
			end
			return most
		end
		local grip, drift = slipAfter(false), slipAfter(true)
		t.ok(drift > grip * 3, string.format("drift slip %.3f vs grip slip %.3f", drift, grip))
	end
)

test("untrusted input and hitches: NaN is zero, values clamp, long frames are dropped", function(t)
	local a, b = car(0), car(0)
	for _ = 1, 60 do
		a:step(1 / 60, { throttle = 1, steer = 0 })
		b:step(1 / 60, { throttle = 99, steer = NAN, handbrake = "yes" :: any })
	end
	t.eq(a:snapshot(), b:snapshot())
	local c = car(0)
	c:step(1 / 60, { throttle = NAN })
	t.eq(c.state.forwardSpeed, 0)
	local hitch = car(0)
	hitch:step(1, { throttle = 1 })
	t.near(hitch.state.time, 8 / 60, 1e-12, "at most MAX_SUBSTEPS per call; the rest is dropped")
	t.throws(function()
		hitch:step(-1)
	end)
	t.throws(function()
		hitch:step(NAN)
	end)
	hitch:place({ x = 5, y = 0, z = 5 }, math.pi)
	t.eq(hitch:speed(), 0)
	t.near(Vehicles.forward(math.pi).z, 1, 1e-12)
end)

test("rigPlan: four wheels, front steer, rear drive, motor speed from top speed", function(t)
	local plan = Vehicles.rigPlan(Vehicles.define({
		maxSpeed = 60,
		acceleration = 20,
		brake = 40,
		steerRate = 2,
		grip = 8,
		rig = { wheelRadius = 1.5, maxSteerAngle = 25 },
	}))
	t.eq(#plan.wheels, 4)
	local steer, drive = 0, 0
	for _, wheel in plan.wheels do
		steer += if wheel.steer then 1 else 0
		drive += if wheel.drive then 1 else 0
		t.eq(wheel.radius, 1.5)
	end
	t.eq(steer, 2)
	t.eq(drive, 2)
	t.eq(plan.wheels[1].name, "front_left")
	t.ok(plan.wheels[1].offset.z < 0, "front is -Z")
	t.eq(plan.motor.maxAngularVelocity, 40)
	t.eq(plan.steering.maxAngle, 25)
	t.eq(plan.seat.maxSpeed, 60)
end)

return cases
