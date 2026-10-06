--!strict
-- Scene-level validation: part budget, door/ceiling/stair clearances from authoring
-- metadata, stair headroom, stairs/ramps cut by other structure, props intersecting structure
-- and unsupported props; scenes with lights or signs also get light_placement and sign_text.
local Measure = require("./Measure")
local Scene = require("./Scene")
local Vec = require("./Vec")

local Validate = {}
type Scene = Scene.Scene
export type Check = { name: string, pass: boolean, value: any, limit: any?, detail: string? }

local EPS = 1e-3

local function overlapVolume(amin, amax, bmin, bmax): number
	local x = math.min(amax.x, bmax.x) - math.max(amin.x, bmin.x)
	local y = math.min(amax.y, bmax.y) - math.max(amin.y, bmin.y)
	local z = math.min(amax.z, bmax.z) - math.max(amin.z, bmin.z)
	if x <= 0 or y <= 0 or z <= 0 then
		return 0
	end
	return x * y * z
end

local STRUCTURE = { wall = true, floor = true, roof = true, stair = true, foundation = true, trim = true }

-- Oriented box of a spec in world space: centre, unit local axes and half extents. Wedges and
-- cylinders are represented by their box, which contains them, so tests built on it are
-- conservative for those shapes and exact for blocks at any rotation.
type Box = { c: Vec.V3, axes: { Vec.V3 }, half: { number } }

local function orientedBox(spec: Scene.PartSpec): Box
	return {
		c = spec.pos,
		axes = {
			Vec.rotate({ x = 1, y = 0, z = 0 }, spec.rot),
			Vec.rotate({ x = 0, y = 1, z = 0 }, spec.rot),
			Vec.rotate({ x = 0, y = 0, z = 1 }, spec.rot),
		},
		half = { spec.size.x / 2, spec.size.y / 2, spec.size.z / 2 },
	}
end

local function cross(a: Vec.V3, b: Vec.V3): Vec.V3
	return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x }
end

-- Half length of a box's projection onto a unit axis.
local function projectedRadius(box: Box, axis: Vec.V3): number
	local r = 0
	for i, a in box.axes do
		r += box.half[i] * math.abs(Vec.dot(a, axis))
	end
	return r
end

-- Penetration depth of two parts' oriented boxes: the smallest overlap of their projections over
-- the 15 separating-axis candidates (both boxes' face normals and the cross products of their
-- edges), i.e. how far one must move to stop intersecting. 0 when they are apart or only touch.
-- Unlike a world AABB this does not grow with yaw, so touching steps of a flight built at
-- 30 degrees stay at 0 instead of reporting their inflated bounding boxes as an overlap.
function Validate.penetration(a: Scene.PartSpec, b: Scene.PartSpec): number
	local ba, bb = orientedBox(a), orientedBox(b)
	local d = Vec.sub(bb.c, ba.c)
	local candidates = {}
	for i = 1, 3 do
		table.insert(candidates, ba.axes[i])
		table.insert(candidates, bb.axes[i])
	end
	for i = 1, 3 do
		for j = 1, 3 do
			local c = cross(ba.axes[i], bb.axes[j])
			local length = Vec.length(c)
			-- Parallel edges give no new axis; the face normals already cover that case.
			if length > 1e-6 then
				table.insert(candidates, Vec.scale(c, 1 / length))
			end
		end
	end
	local depth = math.huge
	for _, axis in candidates do
		local overlap = projectedRadius(ba, axis) + projectedRadius(bb, axis) - math.abs(Vec.dot(d, axis))
		if overlap <= 0 then
			return 0
		end
		depth = math.min(depth, overlap)
	end
	return depth
end

-- Lowest height at which the vertical line through (x, z) enters a part's oriented box, or nil
-- when the line misses it (touching an edge counts as a miss). Exact for blocks at any rotation.
local function verticalEntry(box: Box, x: number, z: number): number?
	local lo, hi = -math.huge, math.huge
	for i, axis in box.axes do
		local h = box.half[i]
		-- Projection of (x, y, z) - centre onto this axis is k + axis.y * y.
		local k = axis.x * (x - box.c.x) + axis.z * (z - box.c.z) - axis.y * box.c.y
		if math.abs(axis.y) < 1e-9 then
			if math.abs(k) >= h then
				return nil
			end
		else
			local y0, y1 = (-h - k) / axis.y, (h - k) / axis.y
			if y0 > y1 then
				y0, y1 = y1, y0
			end
			lo, hi = math.max(lo, y0), math.min(hi, y1)
		end
	end
	return if lo < hi then lo else nil
end

-- A stair/ramp part sunk deeper than this (1/1000 stud) into other structure is cut, not touching.
local STAIR_CUT_DEPTH = EPS
-- Same depth for a prop sunk into structure.
local PROP_CLIP_DEPTH = EPS

-- Widest run of a door opening that stays clear once every other collidable part intruding into
-- its passage is subtracted. The passage is the opening rectangle extruded through the wall plus
-- half a character width on each side, so a partition that starts at the wall face inside the
-- doorway counts as well as one that crosses it. Measured in the door's own frame (u along the
-- wall, n across it) from each part's corners: exact for parts square to the door, conservative
-- otherwise. Records without a wall axis (hand-written metadata) fall back to the nominal width.
function Validate.doorClearWidth(door: any, specs: { Scene.PartSpec }, bounds: { { any } }?): number
	local dir = door.dir
	if dir == nil then
		return door.width
	end
	local nx, nz = -dir.z, dir.x
	local halfW = door.width / 2
	local reach = (door.thickness or 1) / 2 + Measure.GUIDE.characterWidth / 2
	local y0, y1 = door.pos.y, door.pos.y + door.height
	local ex = math.abs(dir.x) * halfW + math.abs(nx) * reach
	local ez = math.abs(dir.z) * halfW + math.abs(nz) * reach
	local blocked = {}
	for i, spec in specs do
		if spec.canCollide ~= false then
			local box = if bounds then bounds[i] else { Scene.specBounds(spec) }
			local bmin, bmax = box[1], box[2]
			if
				bmin.x < door.pos.x + ex - EPS
				and bmax.x > door.pos.x - ex + EPS
				and bmin.z < door.pos.z + ez - EPS
				and bmax.z > door.pos.z - ez + EPS
				and bmin.y < y1 - EPS
				and bmax.y > y0 + EPS
			then
				local u0, u1, n0, n1 = math.huge, -math.huge, math.huge, -math.huge
				local hx, hy, hz = spec.size.x / 2, spec.size.y / 2, spec.size.z / 2
				for _, sx in { -1, 1 } do
					for _, sy in { -1, 1 } do
						for _, sz in { -1, 1 } do
							local c = Vec.add(
								spec.pos,
								Vec.rotate({ x = sx * hx, y = sy * hy, z = sz * hz }, spec.rot)
							)
							local dx, dz = c.x - door.pos.x, c.z - door.pos.z
							local u, n = dx * dir.x + dz * dir.z, dx * nx + dz * nz
							u0, u1 = math.min(u0, u), math.max(u1, u)
							n0, n1 = math.min(n0, n), math.max(n1, n)
						end
					end
				end
				if n0 < reach - EPS and n1 > -reach + EPS and u0 < halfW - EPS and u1 > -halfW + EPS then
					table.insert(blocked, { math.max(u0, -halfW), math.min(u1, halfW) })
				end
			end
		end
	end
	table.sort(blocked, function(a, b)
		return a[1] < b[1]
	end)
	local cursor, best = -halfW, 0
	for _, span in blocked do
		best = math.max(best, span[1] - cursor)
		cursor = math.max(cursor, span[2])
	end
	return math.max(best, halfW - cursor)
end

function Validate.scene(scene: Scene, options: { maxParts: number?, groundY: number? }?): { Check }
	local checks: { Check } = {}
	local maxParts = options and options.maxParts or 5000
	table.insert(
		checks,
		{ name = "part_budget", pass = #scene.specs <= maxParts, value = #scene.specs, limit = maxParts }
	)

	local bounds = {}
	for i, spec in scene.specs do
		local min, max = Scene.specBounds(spec)
		bounds[i] = { min, max }
	end

	local badDoors = {}
	for _, door in scene.meta.doors do
		if door.kind == "door" then
			local clear = Validate.doorClearWidth(door, scene.specs, bounds)
			if not Measure.doorClearance(clear, door.height).pass then
				table.insert(
					badDoors,
					string.format("%s %.1fx%.1f clear %.2f", door.group, door.width, door.height, clear)
				)
			end
		end
	end
	table.insert(checks, {
		name = "door_clearance",
		pass = #badDoors == 0,
		value = #badDoors,
		limit = 0,
		detail = table.concat(badDoors, "; "),
	})

	local lowRooms = {}
	for _, room in scene.meta.rooms do
		if not Measure.ceilingClearance(room.clearHeight).pass then
			table.insert(lowRooms, room.id)
		end
		if math.min(room.rect.w, room.rect.d) < Measure.GUIDE.corridorMin then
			table.insert(lowRooms, room.id .. "(narrow)")
		end
	end
	table.insert(checks, {
		name = "room_clearance",
		pass = #lowRooms == 0,
		value = #lowRooms,
		limit = 0,
		detail = table.concat(lowRooms, ","),
	})

	local badStairs = {}
	for index, stair in scene.meta.stairs do
		if stair.stepRise > Measure.GUIDE.maxStep then
			table.insert(badStairs, "stair" .. index .. " rise " .. stair.stepRise)
		end
	end
	table.insert(checks, {
		name = "stair_step_rise",
		pass = #badStairs == 0,
		value = #badStairs,
		limit = 0,
		detail = table.concat(badStairs, ";"),
	})

	-- Stairs and ramps buried in or cut by other structure (railings across a flight, a ramp
	-- sunk into a foundation). Steps of one flight only touch, so any real overlap is a defect.
	-- Measured on oriented boxes, so the result does not depend on the yaw a scene is built at;
	-- world AABBs only serve as a quick reject (an AABB overlap bounds the box penetration).
	local cutStairs = {}
	for i, spec in scene.specs do
		if spec.role == "stair" and spec.canCollide ~= false then
			local amin, amax = bounds[i][1], bounds[i][2]
			for j, other in scene.specs do
				local bmin, bmax = bounds[j][1], bounds[j][2]
				if
					j ~= i
					and STRUCTURE[other.role]
					and other.canCollide ~= false
					and (other.role ~= "stair" or j > i)
					and math.min(amax.x, bmax.x) - math.max(amin.x, bmin.x) > STAIR_CUT_DEPTH
					and math.min(amax.y, bmax.y) - math.max(amin.y, bmin.y) > STAIR_CUT_DEPTH
					and math.min(amax.z, bmax.z) - math.max(amin.z, bmin.z) > STAIR_CUT_DEPTH
					and Validate.penetration(spec, other) > STAIR_CUT_DEPTH
				then
					table.insert(cutStairs, spec.id .. " x " .. other.id)
				end
			end
		end
	end
	table.insert(checks, {
		name = "stair_obstruction",
		pass = #cutStairs == 0,
		value = #cutStairs,
		limit = 0,
		detail = table.concat(cutStairs, ",", 1, math.min(#cutStairs, 5)),
	})

	-- Headroom: vertical clearance above each step's walking surface to the nearest solid part,
	-- found by casting the vertical line through the step centre into each part's oriented box
	-- (world AABBs only pre-filter). For parts square to the world this is the AABB bottom, as
	-- before; for parts built at another yaw the AABB would spread over neighbouring steps.
	local minHeadroom = math.huge
	for s, spec in scene.specs do
		if spec.role == "stair" and spec.shape == "Block" then
			local top = bounds[s][2]
			local cx, cz = spec.pos.x, spec.pos.z
			for i, other in scene.specs do
				local b = bounds[i]
				if
					other ~= spec
					and (other.transparency or 0) < 0.5
					and other.canCollide ~= false
					and b[2].y > top.y + 0.01
					and cx > b[1].x
					and cx < b[2].x
					and cz > b[1].z
					and cz < b[2].z
				then
					local entry = verticalEntry(orientedBox(other), cx, cz)
					if entry and entry > top.y + 0.01 then
						minHeadroom = math.min(minHeadroom, entry - top.y)
					end
				end
			end
		end
	end
	local headroomPass = minHeadroom >= Measure.GUIDE.characterHeight + 0.5
	table.insert(checks, {
		name = "stair_headroom",
		pass = headroomPass,
		value = if minHeadroom == math.huge then "open" else math.round(minHeadroom * 100) / 100,
		limit = Measure.GUIDE.characterHeight + 0.5,
	})

	-- Props intersecting structure and props with nothing under them. A world-AABB overlap is
	-- confirmed on the oriented boxes, so a prop standing against a wall of a building built at
	-- 30 degrees is not reported for its inflated bounding box (axis-aligned results are unchanged).
	local clipping, floating = {}, {}
	local groundY = options and options.groundY or 0
	for i, spec in scene.specs do
		if spec.role == "prop" then
			local pmin, pmax = bounds[i][1], bounds[i][2]
			local supported = math.abs(pmin.y - groundY) < 0.05
			for j, other in scene.specs do
				if STRUCTURE[other.role] then
					local omin, omax = bounds[j][1], bounds[j][2]
					if
						overlapVolume(pmin, pmax, omin, omax) > 0.05
						and Validate.penetration(spec, other) > PROP_CLIP_DEPTH
					then
						table.insert(clipping, spec.id)
						break
					end
					if
						not supported
						and math.abs(omax.y - pmin.y) < 0.05
						and pmin.x < omax.x
						and omin.x < pmax.x
						and pmin.z < omax.z
						and omin.z < pmax.z
					then
						supported = true
					end
				end
			end
			if not supported then
				table.insert(floating, spec.id)
			end
		end
	end
	table.insert(checks, {
		name = "prop_clipping",
		pass = #clipping == 0,
		value = #clipping,
		limit = 0,
		detail = table.concat(clipping, ",", 1, math.min(#clipping, 5)),
	})
	table.insert(checks, {
		name = "prop_support",
		pass = #floating == 0,
		value = #floating,
		limit = 0,
		detail = table.concat(floating, ",", 1, math.min(#floating, 5)),
	})
	Validate.dressing(scene, checks)
	return checks
end

local LIGHT_CLASSES = { PointLight = true, SpotLight = true, SurfaceLight = true }
local MAX_LIGHT_RANGE = 60 -- engine cap for PointLight/SpotLight/SurfaceLight Range

-- Appends light_placement (valid class, range within the engine cap, and every fixture recorded
-- for a room inside that room's box) and sign_text (non-empty text) when the scene has any light
-- or sign; scenes without them get neither check, so their reports are unchanged.
function Validate.dressing(scene: Scene, checks: { Check }): { Check }
	local byId, lights, signs = {}, 0, 0
	local badLights, badSigns = {}, {}
	for _, spec in scene.specs do
		byId[spec.id :: string] = spec
		local light = spec.light
		if light then
			lights += 1
			if not LIGHT_CLASSES[light.class] then
				table.insert(
					badLights,
					string.format("%s class %s", tostring(spec.id), tostring(light.class))
				)
			elseif (light.range or 16) <= 0 or (light.range or 16) > MAX_LIGHT_RANGE then
				table.insert(
					badLights,
					string.format("%s range %s", tostring(spec.id), tostring(light.range))
				)
			end
		end
		if spec.sign then
			signs += 1
			local text = spec.sign.text
			if type(text) ~= "string" or string.match(text, "^%s*$") then
				table.insert(badSigns, tostring(spec.id))
			end
		end
	end
	local records = (scene.meta :: any).lights or {}
	for _, record in records do
		local spec = byId[record.id]
		if spec == nil then
			table.insert(badLights, record.id .. " missing")
		else
			-- Fixture corners in the room's frame (u along `dir`, v up from the floor, w across).
			local dir = record.dir
			local across = { x = -dir.z, y = 0, z = dir.x }
			local hx, hy, hz = spec.size.x / 2, spec.size.y / 2, spec.size.z / 2
			local inside = true
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local corner =
							Vec.add(spec.pos, Vec.rotate({ x = sx * hx, y = sy * hy, z = sz * hz }, spec.rot))
						local d = Vec.sub(corner, record.pos)
						if
							math.abs(Vec.dot(d, dir)) > record.half[1] + EPS
							or math.abs(Vec.dot(d, across)) > record.half[2] + EPS
							or d.y < -EPS
							or d.y > record.height + EPS
						then
							inside = false
						end
					end
				end
			end
			if not inside then
				table.insert(badLights, record.id .. " outside " .. record.room)
			end
		end
	end
	if lights > 0 or #records > 0 then
		table.insert(checks, {
			name = "light_placement",
			pass = #badLights == 0,
			value = #badLights,
			limit = 0,
			detail = table.concat(badLights, "; ", 1, math.min(#badLights, 5)),
		})
	end
	if signs > 0 then
		table.insert(checks, {
			name = "sign_text",
			pass = #badSigns == 0,
			value = #badSigns,
			limit = 0,
			detail = table.concat(badSigns, ",", 1, math.min(#badSigns, 5)),
		})
	end
	return checks
end

function Validate.summary(checks: { Check })
	local failed = {}
	for _, c in checks do
		if not c.pass then
			table.insert(failed, c.name)
		end
	end
	return { pass = #failed == 0, failed = failed, checks = checks }
end

return Validate
