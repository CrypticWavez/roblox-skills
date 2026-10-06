--!strict
-- @tier T3
-- probe: action_vehicle_drive
-- VehicleRigRoblox: two ways to put a Vehicles model into the world.
--   * build(plan, roblox, options) turns Vehicles.rigPlan() into a constraint car: a chassis
--     with a welded VehicleSeat and, per wheel, a strut on a PrismaticConstraint with a
--     SpringConstraint (suspension), a knuckle (a Servo HingeConstraint about Y on steering
--     wheels, a weld otherwise) and a Cylinder wheel on a HingeConstraint (Motor on drive
--     wheels). drive(rig, plan, throttle, steer) sets motor speeds and servo angles; seatInput()
--     reads VehicleSeat.ThrottleFloat/SteerFloat. Signs and tuning are UNVERIFIED until the
--     probe drives it in Studio.
--   * startArcade(vehicle, model, options, env) runs the pure arcade model instead: each
--     simulation step reads input, steps Vehicles and pivots an anchored model (no physics).
-- The builder runs in Lune with @lune/roblox; driving needs Studio.
local AuthorityRoblox = require("./AuthorityRoblox")

local VehicleRigRoblox = {}

export type Rig = {
	model: any,
	chassis: any,
	seat: any,
	wheels: {
		[string]: { wheel: any, strut: any, knuckle: any, axle: any, steer: any?, spring: any, slider: any },
	},
}

local function part(roblox: any, name: string, size: any, cframe: any, parent: any): any
	local p = roblox.Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cframe
	p.Anchored = false
	p.Parent = parent
	return p
end

local function attach(roblox: any, parentPart: any, name: string, cframe: any): any
	local a = roblox.Instance.new("Attachment")
	a.Name = name
	a.CFrame = cframe
	a.Parent = parentPart
	return a
end

type BuildOptions = { cframe: any?, name: string?, parent: any? }

-- Builds the constraint car from a rig plan. options.cframe places the chassis (default the
-- origin); options.name names the model (default "SETUP_ONLY_Vehicle").
function VehicleRigRoblox.build(plan: any, roblox: any, options: BuildOptions?): Rig
	local opts: BuildOptions = options or {}
	local CFrame, Vector3, Enum = roblox.CFrame, roblox.Vector3, roblox.Enum
	local origin = opts.cframe or CFrame.new()
	local model = roblox.Instance.new("Model")
	model.Name = opts.name or "SETUP_ONLY_Vehicle"
	local body = plan.body.size
	local chassis = part(roblox, "Chassis", Vector3.new(body.x, body.y, body.z), origin, model)
	local seatOffset = plan.seat.offset
	local seat = roblox.Instance.new("VehicleSeat")
	seat.Name = "Seat"
	seat.Size = Vector3.new(2, 1, 2)
	seat.CFrame = origin * CFrame.new(seatOffset.x, seatOffset.y, seatOffset.z)
	seat.MaxSpeed = plan.seat.maxSpeed
	seat.Torque = plan.seat.torque
	seat.TurnSpeed = plan.seat.turnSpeed
	seat.Parent = model
	local seatWeld = roblox.Instance.new("WeldConstraint")
	seatWeld.Part0 = chassis
	seatWeld.Part1 = seat
	seatWeld.Parent = chassis
	-- An attachment's primary axis is its X axis; this turns X to point up (for sliders and
	-- steering hinges).
	local upAxis = CFrame.Angles(0, 0, math.rad(90))
	local wheels = {}
	local suspension = plan.suspension
	for _, w in plan.wheels do
		local offset = CFrame.new(w.offset.x, w.offset.y, w.offset.z)
		local strut = part(roblox, "Strut_" .. w.name, Vector3.new(0.4, 0.4, 0.4), origin * offset, model)
		strut.Massless = true
		strut.CanCollide = false
		strut.Transparency = 1
		local slider = roblox.Instance.new("PrismaticConstraint")
		slider.Name = "Suspension_" .. w.name
		slider.Attachment0 = attach(roblox, chassis, "Slide_" .. w.name, offset * upAxis)
		slider.Attachment1 = attach(roblox, strut, "Slide", upAxis)
		slider.LimitsEnabled = true
		slider.LowerLimit = -suspension.maxLength / 2
		slider.UpperLimit = suspension.maxLength / 2
		slider.Parent = strut
		local spring = roblox.Instance.new("SpringConstraint")
		spring.Name = "Spring_" .. w.name
		spring.Attachment0 =
			attach(roblox, chassis, "SpringTop_" .. w.name, offset * CFrame.new(0, suspension.freeLength, 0))
		spring.Attachment1 = attach(roblox, strut, "SpringBottom", CFrame.new())
		spring.Stiffness = suspension.stiffness
		spring.Damping = suspension.damping
		spring.FreeLength = suspension.freeLength
		spring.LimitsEnabled = true
		spring.MinLength = suspension.minLength
		spring.MaxLength = suspension.maxLength
		spring.Parent = strut
		local knuckle = part(roblox, "Knuckle_" .. w.name, Vector3.new(0.4, 0.4, 0.4), origin * offset, model)
		knuckle.Massless = true
		knuckle.CanCollide = false
		knuckle.Transparency = 1
		local steer = nil
		if w.steer then
			steer = roblox.Instance.new("HingeConstraint")
			steer.Name = "Steer_" .. w.name
			steer.Attachment0 = attach(roblox, strut, "Steer", upAxis)
			steer.Attachment1 = attach(roblox, knuckle, "Steer", upAxis)
			steer.ActuatorType = Enum.ActuatorType.Servo
			steer.ServoMaxTorque = plan.steering.servoMaxTorque
			steer.LimitsEnabled = true
			steer.LowerAngle = -plan.steering.maxAngle
			steer.UpperAngle = plan.steering.maxAngle
			steer.Parent = knuckle
		else
			local weld = roblox.Instance.new("WeldConstraint")
			weld.Part0 = strut
			weld.Part1 = knuckle
			weld.Parent = knuckle
		end
		local wheel = part(
			roblox,
			"Wheel_" .. w.name,
			Vector3.new(w.width, w.radius * 2, w.radius * 2),
			origin * offset,
			model
		)
		wheel.Shape = Enum.PartType.Cylinder
		local axle = roblox.Instance.new("HingeConstraint")
		axle.Name = "Axle_" .. w.name
		axle.Attachment0 = attach(roblox, knuckle, "Axle", CFrame.new())
		axle.Attachment1 = attach(roblox, wheel, "Axle", CFrame.new())
		if w.drive then
			axle.ActuatorType = Enum.ActuatorType.Motor
			axle.MotorMaxTorque = plan.motor.maxTorque
			axle.AngularVelocity = 0
		else
			axle.ActuatorType = Enum.ActuatorType.None
		end
		axle.Parent = wheel
		wheels[w.name] = {
			wheel = wheel,
			strut = strut,
			knuckle = knuckle,
			axle = axle,
			steer = steer,
			spring = spring,
			slider = slider,
		}
	end
	model.PrimaryPart = chassis
	if opts.parent ~= nil then
		model.Parent = opts.parent
	end
	return { model = model, chassis = chassis, seat = seat, wheels = wheels }
end

-- Sets motor speeds and steering angles from input in [-1, 1] (non-finite is 0). Forward is
-- -Z; a positive angular velocity about +X rolls the contact patch towards -Z, so forward
-- uses negative motor speed (UNVERIFIED until action_vehicle_drive runs).
function VehicleRigRoblox.drive(rig: Rig, plan: any, throttle: number, steer: number)
	local function clamp(value: number): number
		if value ~= value or value == math.huge or value == -math.huge then
			return 0
		end
		return math.clamp(value, -1, 1)
	end
	local t, s = clamp(throttle), clamp(steer)
	for _, entry in rig.wheels do
		if entry.axle.ActuatorType.Name == "Motor" then
			entry.axle.AngularVelocity = -t * plan.motor.maxAngularVelocity
		end
		if entry.steer then
			entry.steer.TargetAngle = s * plan.steering.maxAngle
		end
	end
end

-- The seat's input as Vehicles input.
function VehicleRigRoblox.seatInput(seat: any): { throttle: number, steer: number }
	return { throttle = seat.ThrottleFloat, steer = seat.SteerFloat }
end

-- Places an anchored model at the arcade state (position, heading about Y).
function VehicleRigRoblox.pivot(model: any, state: any, roblox: any)
	local p = state.position
	model:PivotTo(roblox.CFrame.new(p.x, p.y, p.z) * roblox.CFrame.Angles(0, state.heading, 0))
end

-- Runs the arcade model on an anchored model: each simulation step reads input(), steps the
-- Vehicles instance and pivots the model. Returns (stop, how).
function VehicleRigRoblox.startArcade(
	vehicle: any,
	model: any,
	options: {
		runService: any,
		input: () -> any,
		roblox: any,
		allowFallback: boolean?,
		onEvents: ((events: { any }) -> ())?,
	},
	_env: any
): (() -> (), string)
	local unbind, how = AuthorityRoblox.bindStep(options.runService, function(dt: number)
		local state, events = vehicle:step(dt, options.input())
		VehicleRigRoblox.pivot(model, state, options.roblox)
		if options.onEvents and #events > 0 then
			options.onEvents(events)
		end
	end, { allowFallback = options.allowFallback })
	if unbind == nil then
		error("VehicleRigRoblox.startArcade: " .. how, 2)
	end
	return unbind :: () -> (), how
end

return VehicleRigRoblox
