--!strict
-- Player-scale measurement helpers. ENGINE values are Roblox defaults (StarterPlayer /
-- Workspace); GUIDE values are level-design guidelines for an unscaled R15 character and
-- should be overridden per game when avatar scale, WalkSpeed or JumpHeight change.
local Scene = require("./Scene")
local Vec = require("./Vec")

local Measure = {}
type V3 = Vec.V3

Measure.ENGINE = {
	gravity = 196.2, -- Workspace.Gravity
	walkSpeed = 16, -- StarterPlayer.CharacterWalkSpeed
	jumpHeight = 7.2, -- StarterPlayer.CharacterJumpHeight
	maxSlopeAngle = 89, -- StarterPlayer.CharacterMaxSlopeAngle
	cameraDistance = 12.5, -- typical default third-person zoom
}

Measure.GUIDE = {
	characterHeight = 5.5, -- R15 default, head included
	characterWidth = 2.5, -- shoulder span with arms at rest
	comfortableStep = 1, -- stair rise players walk without noticing
	maxStep = 2, -- above this treat as a jump
	doorMin = { width = 4, height = 7 },
	doorComfort = { width = 6, height = 8 },
	ceilingMin = 9, -- below this the default camera clips in third person
	ceilingComfort = 12,
	corridorMin = 6, -- two players pass
	corridorComfort = 10,
	halfCover = 3,
	fullCover = 6,
	railingHeight = 3.5,
}

function Measure.distance(a: V3, b: V3): number
	return Vec.length(Vec.sub(a, b))
end

function Measure.horizontalDistance(a: V3, b: V3): number
	return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
end

-- Angle in degrees between two directions.
function Measure.angle(a: V3, b: V3): number
	local la, lb = Vec.length(a), Vec.length(b)
	if la == 0 or lb == 0 then
		return 0
	end
	return math.deg(math.acos(math.clamp(Vec.dot(a, b) / (la * lb), -1, 1)))
end

-- Slope of a ramp in degrees from rise/run.
function Measure.slope(rise: number, run: number): number
	return math.deg(math.atan2(rise, run))
end

function Measure.bounds(spec: Scene.PartSpec): { min: V3, max: V3, size: V3 }
	local min, max = Scene.specBounds(spec)
	return { min = min, max = max, size = Vec.sub(max, min) }
end

-- Horizontal distance a default character covers in the air when landing `rise` studs higher
-- (negative rise = lower landing). nil when the rise exceeds jump height.
function Measure.jumpReach(rise: number, engine: { [string]: number }?): number?
	local e = engine or Measure.ENGINE
	local g, h, speed = e.gravity, e.jumpHeight, e.walkSpeed
	if rise > h then
		return nil
	end
	local v0 = math.sqrt(2 * g * h)
	local t = (v0 + math.sqrt(v0 * v0 - 2 * g * rise)) / g
	return speed * t
end

-- Can a player clear `gap` studs horizontally landing `rise` higher? margin keeps it fair.
function Measure.canJump(gap: number, rise: number, margin: number?): boolean
	local reach = Measure.jumpReach(rise)
	return reach ~= nil and gap <= reach * (1 - (margin or 0.15))
end

function Measure.doorClearance(width: number, height: number): { pass: boolean, comfortable: boolean }
	local g = Measure.GUIDE
	return {
		pass = width >= g.doorMin.width and height >= g.doorMin.height,
		comfortable = width >= g.doorComfort.width and height >= g.doorComfort.height,
	}
end

function Measure.ceilingClearance(height: number): { pass: boolean, comfortable: boolean }
	return { pass = height >= Measure.GUIDE.ceilingMin, comfortable = height >= Measure.GUIDE.ceilingComfort }
end

function Measure.corridorWidth(width: number, players: number?): { pass: boolean, comfortable: boolean }
	local needed = math.max(Measure.GUIDE.corridorMin, (players or 2) * Measure.GUIDE.characterWidth + 1)
	return { pass = width >= needed, comfortable = width >= math.max(needed, Measure.GUIDE.corridorComfort) }
end

function Measure.coverClass(height: number): string
	if height >= Measure.GUIDE.fullCover then
		return "full"
	elseif height >= Measure.GUIDE.halfCover then
		return "half"
	end
	return "none"
end

-- Segment vs axis-aligned box (slab method). Returns entry fraction or nil.
local function segmentHitsBox(a: V3, b: V3, min: V3, max: V3): number?
	local tmin, tmax = 0, 1
	for _, axis in { "x", "y", "z" } do
		local origin, delta = (a :: any)[axis], (b :: any)[axis] - (a :: any)[axis]
		local lo, hi = (min :: any)[axis], (max :: any)[axis]
		if math.abs(delta) < 1e-9 then
			if origin < lo or origin > hi then
				return nil
			end
		else
			local t1, t2 = (lo - origin) / delta, (hi - origin) / delta
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	return tmin
end
Measure.segmentHitsBox = segmentHitsBox

-- Sightline between two points against a scene's opaque parts (AABB approximation, so it
-- is conservative for rotated parts). Returns visible + first blocker id.
function Measure.sightline(
	scene,
	from: V3,
	to: V3,
	ignoreRoles: { [string]: boolean }?
): { visible: boolean, blocker: string?, distance: number }
	local best, blocker = math.huge, nil
	for _, spec in scene.specs do
		if (spec.transparency or 0) < 0.5 and not (ignoreRoles and ignoreRoles[spec.role]) then
			local min, max = Scene.specBounds(spec)
			local t = segmentHitsBox(from, to, min, max)
			if t and t > 1e-6 and t < 1 - 1e-6 and t < best then
				best, blocker = t, spec.id
			end
		end
	end
	return { visible = blocker == nil, blocker = blocker, distance = Measure.distance(from, to) }
end

-- Clear space behind a character for the default camera boom along `back` direction.
function Measure.cameraClearance(
	scene,
	characterPos: V3,
	back: V3,
	boom: number?
): { clear: boolean, available: number }
	local head = Vec.add(characterPos, { x = 0, y = 1.5, z = 0 })
	local length = boom or Measure.ENGINE.cameraDistance
	local target = Vec.add(head, Vec.scale(Vec.unit(back), length))
	local best = 1
	for _, spec in scene.specs do
		if (spec.transparency or 0) < 0.5 then
			local min, max = Scene.specBounds(spec)
			local t = segmentHitsBox(head, target, min, max)
			if t and t > 1e-6 and t < best then
				best = t
			end
		end
	end
	return { clear = best >= 1, available = best * length }
end

return Measure
