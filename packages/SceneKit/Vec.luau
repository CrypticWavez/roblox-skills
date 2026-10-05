--!strict
-- Plain-table vector math ({x, y, z}) so plans run identically in Lune, CI and Studio.
-- Rotations are Roblox orientation degrees (CFrame.fromOrientation order: R = Ry * Rx * Rz).
local Vec = {}

export type V3 = { x: number, y: number, z: number }

function Vec.new(x: number?, y: number?, z: number?): V3
	return { x = x or 0, y = y or 0, z = z or 0 }
end

function Vec.add(a: V3, b: V3): V3
	return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }
end

function Vec.sub(a: V3, b: V3): V3
	return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

function Vec.scale(a: V3, s: number): V3
	return { x = a.x * s, y = a.y * s, z = a.z * s }
end

function Vec.dot(a: V3, b: V3): number
	return a.x * b.x + a.y * b.y + a.z * b.z
end

function Vec.length(a: V3): number
	return math.sqrt(Vec.dot(a, a))
end

function Vec.unit(a: V3): V3
	local l = Vec.length(a)
	return if l == 0 then Vec.new() else Vec.scale(a, 1 / l)
end

function Vec.lerp(a: V3, b: V3, t: number): V3
	return Vec.add(a, Vec.scale(Vec.sub(b, a), t))
end

local function rx(v: V3, deg: number): V3
	local r = math.rad(deg)
	local c, s = math.cos(r), math.sin(r)
	return { x = v.x, y = v.y * c - v.z * s, z = v.y * s + v.z * c }
end

local function ry(v: V3, deg: number): V3
	local r = math.rad(deg)
	local c, s = math.cos(r), math.sin(r)
	return { x = v.x * c + v.z * s, y = v.y, z = -v.x * s + v.z * c }
end

local function rz(v: V3, deg: number): V3
	local r = math.rad(deg)
	local c, s = math.cos(r), math.sin(r)
	return { x = v.x * c - v.y * s, y = v.x * s + v.y * c, z = v.z }
end

-- Apply an orientation (degrees) to a local vector.
function Vec.rotate(v: V3, rot: V3?): V3
	if rot == nil then
		return v
	end
	return ry(rx(rz(v, rot.z), rot.x), rot.y)
end
Vec.rotateY = ry

function Vec.round(v: V3, step: number?): V3
	local s = step or 0.001
	return { x = math.round(v.x / s) * s, y = math.round(v.y / s) * s, z = math.round(v.z / s) * s }
end

function Vec.snap(value: number, grid: number): number
	return math.round(value / grid) * grid
end

return Vec
