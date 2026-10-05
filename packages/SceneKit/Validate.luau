--!strict
-- Scene-level validation: part budget, door/ceiling/stair clearances from authoring
-- metadata, stair headroom, stairs/ramps cut by other structure, props intersecting structure
-- and unsupported props.
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
	local cutStairs = {}
	for i, spec in scene.specs do
		if spec.role == "stair" and spec.canCollide ~= false then
			for j, other in scene.specs do
				if
					j ~= i
					and STRUCTURE[other.role]
					and other.canCollide ~= false
					and (other.role ~= "stair" or j > i)
					and overlapVolume(bounds[i][1], bounds[i][2], bounds[j][1], bounds[j][2]) > 0.01
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

	-- Headroom: vertical clearance above each step's walking surface to the nearest solid part.
	local minHeadroom = math.huge
	for _, spec in scene.specs do
		if spec.role == "stair" and spec.shape == "Block" then
			local _, top = Scene.specBounds(spec)
			local cx, cz = spec.pos.x, spec.pos.z
			for i, other in scene.specs do
				local b = bounds[i]
				if
					other ~= spec
					and (other.transparency or 0) < 0.5
					and other.canCollide ~= false
					and b[1].y > top.y + 0.01
					and cx > b[1].x
					and cx < b[2].x
					and cz > b[1].z
					and cz < b[2].z
				then
					minHeadroom = math.min(minHeadroom, b[1].y - top.y)
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

	-- Props intersecting structure and props with nothing under them.
	local clipping, floating = {}, {}
	local groundY = options and options.groundY or 0
	for i, spec in scene.specs do
		if spec.role == "prop" then
			local pmin, pmax = bounds[i][1], bounds[i][2]
			local supported = math.abs(pmin.y - groundY) < 0.05
			for j, other in scene.specs do
				if STRUCTURE[other.role] then
					local omin, omax = bounds[j][1], bounds[j][2]
					if overlapVolume(pmin, pmax, omin, omax) > 0.05 then
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
