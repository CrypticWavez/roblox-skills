--!strict
-- Planar acceleration/turning math for previews; no gravity/collision/character authority.
local MovementProfile = {}
local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end
function MovementProfile.validate(config: any)
	assert(type(config) == "table", "profile required")
	for _, key in { "speed", "acceleration", "deceleration", "turnRate" } do
		assert(
			finite(config[key]) and config[key] > 0 and config[key] <= 1000,
			"positive bounded " .. key .. " required"
		)
	end
	assert(type(config.camera) == "table", "camera profile required")
	assert(
		finite(config.camera.fieldOfView)
			and config.camera.fieldOfView >= 20
			and config.camera.fieldOfView <= 120,
		"invalid field of view"
	)
	assert(
		finite(config.camera.height) and finite(config.camera.distance) and config.camera.distance > 0,
		"invalid camera framing"
	)
	return true
end
function MovementProfile.new(config: any)
	MovementProfile.validate(config)
	local profile = table.clone(config)
	profile.camera = table.clone(config.camera)
	local api = { x = 0, z = 0, heading = 0 }
	function api:step(inputX: number, inputZ: number, dt: number)
		assert(
			finite(inputX) and finite(inputZ) and finite(dt) and dt >= 0 and dt <= 0.25,
			"finite input and dt<=0.25 required"
		)
		local magnitude = math.sqrt(inputX * inputX + inputZ * inputZ)
		local divisor = math.max(1, magnitude)
		local tx, tz = inputX / divisor * profile.speed, inputZ / divisor * profile.speed
		local dx, dz = tx - api.x, tz - api.z
		local distance = math.sqrt(dx * dx + dz * dz)
		local amount = (if magnitude > 0 then profile.acceleration else profile.deceleration) * dt
		local alpha = if distance == 0 then 1 else math.min(1, amount / distance)
		api.x, api.z = api.x + dx * alpha, api.z + dz * alpha
		if magnitude > 0 then
			local target = math.atan2(inputX, inputZ)
			local angle = (target - api.heading + math.pi) % (2 * math.pi) - math.pi
			api.heading += math.clamp(angle, -profile.turnRate * dt, profile.turnRate * dt)
		end
		return {
			x = api.x,
			z = api.z,
			heading = api.heading,
			speed = math.sqrt(api.x * api.x + api.z * api.z),
		}
	end
	function api:camera()
		return table.clone(profile.camera)
	end
	return api
end
return MovementProfile
