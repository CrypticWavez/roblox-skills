--!strict
-- @tier T0
-- Spring: a closed-form damped harmonic spring, parameterised like spr (damping ratio and
-- undamped frequency in Hz; docs/research/ui-cinematics-feel-2026-10.md 4b and 6.3). Because each
-- step evaluates the exact solution, the result does not depend on frame rate: 60 steps of 1/60 s
-- equal 30 steps of 1/30 s. dampingRatio < 1 overshoots, = 1 settles fastest without overshoot,
-- > 1 is sluggish. Values are numbers or tables of numbers (componentwise, e.g. { x, y, z } or a
-- UDim2-like { xScale = 0, xOffset = 0 }).
--   Spring.new(value, { dampingRatio?, frequency?, target?, epsilon? }) -> spring
--   spring:setTarget(target), spring:impulse(velocity), spring:snap(value)
--   spring:step(dt) -> (value, velocity, settled)
--   Spring.solve(x0, v0, target, dampingRatio, frequency, t) -> (x, v)   one component
local Spring = {}

Spring.DEFAULT_DAMPING = 1
Spring.DEFAULT_FREQUENCY = 4 -- Hz (convention)
Spring.DEFAULT_EPSILON = 1e-4

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Exact displacement and velocity after t seconds for one component.
function Spring.solve(
	x0: number,
	v0: number,
	target: number,
	dampingRatio: number,
	frequency: number,
	t: number
): (number, number)
	local omega = 2 * math.pi * frequency
	local d0 = x0 - target
	if omega == 0 or t == 0 then
		return x0 + v0 * t, v0
	end
	local zeta = dampingRatio
	if math.abs(zeta - 1) < 1e-6 then
		local a, b = d0, v0 + omega * d0
		local decay = math.exp(-omega * t)
		local d = decay * (a + b * t)
		local v = decay * (b - omega * (a + b * t))
		return target + d, v
	elseif zeta < 1 then
		local damped = omega * math.sqrt(1 - zeta * zeta)
		local a = zeta * omega
		local cA, cB = d0, (v0 + a * d0) / damped
		local decay = math.exp(-a * t)
		local cos, sin = math.cos(damped * t), math.sin(damped * t)
		local d = decay * (cA * cos + cB * sin)
		local v = decay * ((-a * cA + damped * cB) * cos + (-a * cB - damped * cA) * sin)
		return target + d, v
	else
		local root = math.sqrt(zeta * zeta - 1)
		local r1 = -omega * (zeta - root)
		local r2 = -omega * (zeta + root)
		local c2 = (v0 - r1 * d0) / (r2 - r1)
		local c1 = d0 - c2
		local e1, e2 = math.exp(r1 * t), math.exp(r2 * t)
		return target + c1 * e1 + c2 * e2, c1 * r1 * e1 + c2 * r2 * e2
	end
end

local function shape(value: any): { any }
	if type(value) == "number" then
		return {}
	end
	assert(type(value) == "table", "Spring: value must be a number or a table of numbers")
	local keys = {}
	for key, component in value do
		assert(finite(component), "Spring: component " .. tostring(key) .. " must be a finite number")
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return keys
end

local function zeroLike(value: any): any
	if type(value) == "number" then
		return 0
	end
	local out = {}
	for key in value do
		out[key] = 0
	end
	return out
end

export type Options = { dampingRatio: number?, frequency: number?, target: any?, epsilon: number? }

function Spring.new(value: any, options: Options?)
	local opts: Options = options or {}
	local damping = if opts.dampingRatio == nil then Spring.DEFAULT_DAMPING else opts.dampingRatio
	local frequency = if opts.frequency == nil then Spring.DEFAULT_FREQUENCY else opts.frequency
	assert(finite(damping) and damping >= 0, "Spring: dampingRatio must be >= 0")
	assert(finite(frequency) and frequency >= 0, "Spring: frequency must be >= 0 Hz")
	if type(value) == "number" then
		assert(finite(value), "Spring: value must be finite")
	end
	local keys = shape(value)
	local epsilon = opts.epsilon or Spring.DEFAULT_EPSILON
	local self: any = {
		value = value,
		velocity = zeroLike(value),
		target = if opts.target ~= nil then opts.target else value,
		dampingRatio = damping,
		frequency = frequency,
	}
	local function sameShape(other: any)
		if type(value) == "number" then
			assert(finite(other), "Spring: target must be a finite number")
			return
		end
		assert(type(other) == "table", "Spring: target must match the value's shape")
		for _, key in keys do
			assert(finite(other[key]), "Spring: target component " .. tostring(key) .. " must be finite")
		end
	end
	sameShape(self.target)

	function self.setTarget(spring: any, target: any)
		sameShape(target)
		spring.target = target
	end

	function self.impulse(spring: any, velocity: any)
		sameShape(velocity)
		if type(value) == "number" then
			spring.velocity += velocity
		else
			local nextVelocity: { [any]: number } = table.clone(spring.velocity)
			for _, key in keys do
				nextVelocity[key] += velocity[key]
			end
			spring.velocity = nextVelocity
		end
	end

	function self.snap(spring: any, at: any)
		sameShape(at)
		spring.value = at
		spring.target = at
		spring.velocity = zeroLike(value)
	end

	function self.step(spring: any, dt: number): (any, any, boolean)
		assert(finite(dt) and dt >= 0, "Spring: dt must be a finite number >= 0")
		if type(value) == "number" then
			local x, v = Spring.solve(spring.value, spring.velocity, spring.target, damping, frequency, dt)
			local settled = math.abs(x - spring.target) < epsilon and math.abs(v) < epsilon
			if settled then
				x, v = spring.target, 0
			end
			spring.value, spring.velocity = x, v
			return x, v, settled
		end
		local nextValue, nextVelocity = {}, {}
		local settled = true
		for _, key in keys do
			local x, v = Spring.solve(
				spring.value[key],
				spring.velocity[key],
				spring.target[key],
				damping,
				frequency,
				dt
			)
			nextValue[key], nextVelocity[key] = x, v
			if math.abs(x - spring.target[key]) >= epsilon or math.abs(v) >= epsilon then
				settled = false
			end
		end
		if settled then
			for _, key in keys do
				nextValue[key], nextVelocity[key] = spring.target[key], 0
			end
		end
		spring.value, spring.velocity = nextValue, nextVelocity
		return nextValue, nextVelocity, settled
	end

	return self
end

return Spring
