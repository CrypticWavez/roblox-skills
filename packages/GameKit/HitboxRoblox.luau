--!strict
-- @tier T3
-- probe: action_hitbox_shapecast
-- HitboxRoblox: engine spatial queries behind the pure Hitbox and Projectile cores.
--   * shapeOf(part) turns a BasePart (CFrame + Size; Ball parts become spheres) into a Hitbox
--     shape, for position histories (record each simulation step) and exact filtering.
--   * frame(shape, roblox) gives the CFrame and Size (or radius) a query needs.
--   * query(worldRoot, shape, overlapParams, roblox) runs GetPartBoundsInBox or
--     GetPartBoundsInRadius (bounding-box broad phase) and keeps only parts the pure Hitbox test
--     really overlaps; sweepQuery() repeats it over Hitbox.sweepPoses so a fast swing cannot skip
--     a target between frames.
--   * caster(worldRoot, raycastParams, roblox, options) is a Projectile cast: Raycast for radius
--     0, Spherecast otherwise, Blockcast when options.block gives a box size (the box faces the
--     direction of travel), with hits already taken by this projectile added to the filter.
--     shapecast(worldRoot, part, delta, params, options) casts a part's own geometry
--     (WorldRoot:Shapecast) and returns the same hit table. Engine casts miss parts the shape
--     starts inside (WorldRoot docs), so casters pair with a query at the muzzle when that
--     matters.
-- Lune can run shapeOf and frame with @lune/roblox; the queries need Studio (the probe).
local Hitbox = require("./Hitbox")
local Vec = require("../SceneKit/Vec")

local HitboxRoblox = {}

local function v3(value: any): Vec.V3
	return Vec.new(value.X, value.Y, value.Z)
end
HitboxRoblox.fromVector3 = v3

-- A Hitbox shape for a BasePart's current CFrame and Size.
function HitboxRoblox.shapeOf(part: any): Hitbox.Shape
	local cframe = part.CFrame
	local size = part.Size
	local ok, shape = pcall(function()
		return part.Shape
	end)
	if ok and shape ~= nil and shape.Name == "Ball" then
		return Hitbox.sphere(v3(cframe.Position), math.min(size.X, size.Y, size.Z) / 2)
	end
	return Hitbox.boxAxes(
		v3(cframe.Position),
		v3(size),
		v3(cframe.RightVector),
		v3(cframe.UpVector),
		Vec.scale(v3(cframe.LookVector), -1)
	)
end

-- The CFrame and size of a query volume: boxes (exact), spheres (CFrame and radius) and
-- capsules (their axis-aligned bounds).
function HitboxRoblox.frame(shape: Hitbox.Shape, roblox: any): (any, any)
	local CFrame, Vector3 = roblox.CFrame, roblox.Vector3
	if shape.kind == "sphere" then
		local c = shape.center :: Vec.V3
		return CFrame.new(c.x, c.y, c.z), shape.radius
	elseif shape.kind == "box" then
		local c, s = shape.center :: Vec.V3, shape.size :: Vec.V3
		local axes = shape.axes
		if axes == nil then
			return CFrame.new(c.x, c.y, c.z), Vector3.new(s.x, s.y, s.z)
		end
		local x, y, z = axes[1], axes[2], axes[3]
		return CFrame.fromMatrix(
			Vector3.new(c.x, c.y, c.z),
			Vector3.new(x.x, x.y, x.z),
			Vector3.new(y.x, y.y, y.z),
			Vector3.new(z.x, z.y, z.z)
		),
			Vector3.new(s.x, s.y, s.z)
	end
	local lo, hi = Hitbox.bounds(shape)
	local center = Vec.scale(Vec.add(lo, hi), 0.5)
	local size = Vec.sub(hi, lo)
	return CFrame.new(center.x, center.y, center.z), Vector3.new(size.x, size.y, size.z)
end

-- Parts that truly overlap shape (broad phase by the engine, narrow phase by Hitbox).
function HitboxRoblox.query(worldRoot: any, shape: Hitbox.Shape, overlapParams: any, roblox: any): { any }
	local cframe, extent = HitboxRoblox.frame(shape, roblox)
	local candidates
	if shape.kind == "sphere" then
		candidates = worldRoot:GetPartBoundsInRadius(cframe.Position, extent, overlapParams)
	else
		candidates = worldRoot:GetPartBoundsInBox(cframe, extent, overlapParams)
	end
	local hits = {}
	for _, part in candidates do
		if Hitbox.overlaps(shape, HitboxRoblox.shapeOf(part)) then
			table.insert(hits, part)
		end
	end
	return hits
end

-- query() over the poses between prev and curr; each part once, in first-hit order.
function HitboxRoblox.sweepQuery(
	worldRoot: any,
	prev: Hitbox.Shape,
	curr: Hitbox.Shape,
	overlapParams: any,
	roblox: any,
	maxStep: number?
): { any }
	local seen = {}
	local hits = {}
	for _, pose in Hitbox.sweepPoses(prev, curr, maxStep) do
		for _, part in HitboxRoblox.query(worldRoot, pose, overlapParams, roblox) do
			if not seen[part] then
				seen[part] = true
				table.insert(hits, part)
			end
		end
	end
	return hits
end

export type CasterOptions = {
	-- Maps a hit Instance to a target (a character model, a player id); nil means world
	-- geometry, which stops the projectile.
	resolve: ((instance: any) -> any)?,
	-- Whether a resolved target lets the projectile through (when it has pierce left).
	pierceable: ((instance: any, target: any) -> boolean)?,
	-- Cast a box of this size (studs, { x, y, z }) with Blockcast instead of a ray or sphere.
	block: Vec.V3?,
}

-- The Projectile hit table for an engine RaycastResult over a cast of length studs.
local function convert(result: any, length: number, opts: CasterOptions): any
	local instance = result.Instance
	local target = if opts.resolve then opts.resolve(instance) else nil
	return {
		fraction = math.clamp(result.Distance / length, 0, 1),
		position = v3(result.Position),
		normal = v3(result.Normal),
		target = target,
		instance = instance,
		pierceable = if target ~= nil and opts.pierceable
			then opts.pierceable(instance, target)
			else target ~= nil,
	}
end

-- A CFrame at from whose LookVector is direction, built from its axes (CFrame.lookAt's
-- straight-down -Z case comes out reversed in @lune/roblox, and a vertical cast needs a
-- different up vector anyway).
local function facing(roblox: any, from: any, direction: any): any
	local look = direction.Unit
	local up = if math.abs(look.Y) > 0.99 then roblox.Vector3.new(1, 0, 0) else roblox.Vector3.new(0, 1, 0)
	local right = look:Cross(up).Unit
	return roblox.CFrame.fromMatrix(from, right, right:Cross(look), -look)
end
HitboxRoblox.facing = facing

-- RaycastParams like base with extra Instances excluded (Exclude filters only; an Include
-- filter is returned unchanged and the Projectile core skips repeats itself).
local function excluding(base: any, extra: { any }, roblox: any): any
	if #extra == 0 or base.FilterType ~= roblox.Enum.RaycastFilterType.Exclude then
		return base
	end
	local params = roblox.RaycastParams.new()
	params.FilterType = base.FilterType
	local list = table.clone(base.FilterDescendantsInstances)
	for _, instance in extra do
		table.insert(list, instance)
	end
	params.FilterDescendantsInstances = list
	params.CollisionGroup = base.CollisionGroup
	params.IgnoreWater = base.IgnoreWater
	params.RespectCanCollide = base.RespectCanCollide
	return params
end

-- A Projectile cast function over the engine. Instances a projectile has already hit are
-- excluded from its later casts through a per-cast copy of the params (the shared params
-- object is never changed).
function HitboxRoblox.caster(
	worldRoot: any,
	raycastParams: any,
	roblox: any,
	options: CasterOptions?
): (origin: Vec.V3, delta: Vec.V3, radius: number, state: any) -> any
	local opts: CasterOptions = options or {}
	local Vector3 = roblox.Vector3
	local taken: { [any]: { any } } = setmetatable({}, { __mode = "k" }) :: any
	return function(origin: Vec.V3, delta: Vec.V3, radius: number, state: any): any
		local length = Vec.length(delta)
		if length <= 1e-9 then
			return nil
		end
		local params = excluding(raycastParams, taken[state] or {}, roblox)
		local from = Vector3.new(origin.x, origin.y, origin.z)
		local direction = Vector3.new(delta.x, delta.y, delta.z)
		local result
		if opts.block then
			local size = opts.block :: Vec.V3
			local frame = facing(roblox, from, direction)
			result = worldRoot:Blockcast(frame, Vector3.new(size.x, size.y, size.z), direction, params)
		elseif radius > 0 then
			result = worldRoot:Spherecast(from, radius, direction, params)
		else
			result = worldRoot:Raycast(from, direction, params)
		end
		if result == nil then
			return nil
		end
		local hit = convert(result, length, opts)
		if hit.target ~= nil then
			taken[state] = taken[state] or {}
			table.insert(taken[state], result.Instance)
		end
		return hit
	end
end

-- Casts part's own geometry along delta (WorldRoot:Shapecast; the part need not be in the
-- world). Returns the Projectile hit table (plus instance) or nil.
function HitboxRoblox.shapecast(
	worldRoot: any,
	part: any,
	delta: Vec.V3,
	params: any,
	roblox: any,
	options: CasterOptions?
): any?
	local length = Vec.length(delta)
	if length <= 1e-9 then
		return nil
	end
	local result = worldRoot:Shapecast(part, roblox.Vector3.new(delta.x, delta.y, delta.z), params)
	if result == nil then
		return nil
	end
	return convert(result, length, options or {})
end

-- Records a part's pose into a Hitbox validator's history for id (call it every simulation step).
function HitboxRoblox.record(validator: any, id: any, part: any): boolean
	return validator:record(id, HitboxRoblox.shapeOf(part))
end

return HitboxRoblox
