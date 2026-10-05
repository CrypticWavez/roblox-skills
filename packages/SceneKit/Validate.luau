--!strict
-- Scene-level validation: part budget, door/ceiling/stair clearances from authoring
-- metadata, stair headroom, props intersecting structure and unsupported props.
local Measure = require("./Measure")
local Scene = require("./Scene")

local Validate = {}
type Scene = Scene.Scene
export type Check = { name: string, pass: boolean, value: any, limit: any?, detail: string? }

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

function Validate.scene(scene: Scene, options: { maxParts: number?, groundY: number? }?): { Check }
	local checks: { Check } = {}
	local maxParts = options and options.maxParts or 5000
	table.insert(
		checks,
		{ name = "part_budget", pass = #scene.specs <= maxParts, value = #scene.specs, limit = maxParts }
	)

	local badDoors = {}
	for _, door in scene.meta.doors do
		if door.kind == "door" and not Measure.doorClearance(door.width, door.height).pass then
			table.insert(badDoors, string.format("%s %.1fx%.1f", door.group, door.width, door.height))
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

	-- Headroom: vertical clearance above each step's walking surface to the nearest solid part.
	local bounds = {}
	for i, spec in scene.specs do
		local min, max = Scene.specBounds(spec)
		bounds[i] = { min, max }
	end
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
