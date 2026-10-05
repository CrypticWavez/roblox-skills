--!strict
-- Camera framing for repeatable captures: fit bounds into view from named angles.
local Vec = require("./Vec")

local Camera = {}
type V3 = Vec.V3

Camera.ANGLES = {
	front = { yaw = 0, pitch = 15 },
	["three-quarter"] = { yaw = 35, pitch = 30 },
	side = { yaw = 90, pitch = 15 },
	top = { yaw = 0, pitch = 89 },
}

-- Returns eye position and focus so a bounding sphere fills the vertical field of view.
function Camera.frame(
	min: V3,
	max: V3,
	angle: string | { yaw: number, pitch: number },
	fov: number?,
	margin: number?
): { eye: V3, focus: V3, fov: number, distance: number }
	local a = if type(angle) == "string" then Camera.ANGLES[angle] else angle
	assert(a, "unknown camera angle")
	local f = fov or 70
	local focus = Vec.scale(Vec.add(min, max), 0.5)
	local radius = Vec.length(Vec.sub(max, min)) / 2 * (margin or 1.1)
	local distance = radius / math.sin(math.rad(f) / 2)
	local yaw, pitch = math.rad(a.yaw), math.rad(a.pitch)
	-- SceneKit fronts face -Z, so the "front" camera (yaw 0) sits on -Z looking toward +Z.
	local offset = {
		x = math.sin(yaw) * math.cos(pitch) * distance,
		y = math.sin(pitch) * distance,
		z = -math.cos(yaw) * math.cos(pitch) * distance,
	}
	return { eye = Vec.add(focus, offset), focus = focus, fov = f, distance = distance }
end

-- Standard capture set used by visual QA and Blender previews.
function Camera.captureSet(min: V3, max: V3): { [string]: any }
	local set = {}
	for name in Camera.ANGLES do
		set[name] = Camera.frame(min, max, name)
	end
	return set
end

return Camera
