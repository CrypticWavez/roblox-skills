--!strict
-- Bridge from a ProcGen course/1 manifest to SceneKit parts (Course.toScene):
--   linear, tower  pads (top at pad.pos.y), hazard strips, structures (tower core)
--   race_loop      one track piece per sample (yaw, pitch from grade, roll from bank), gate posts,
--                  crossbars and non-collidable gate triggers, start-grid marks
--   lanes          ground, lane strips (one per run, corners not doubled), build slots, spawn
--                  and base slabs
--   micro_arena    floor (tiles or one disc/square), edge walls, cover, hazards, spawn pads
-- Every gameplay part carries an `asset` attribute (a kit/1 piece key such as course_platform,
-- swappable with SceneKit Kit + Apply.swap) and the attributes GameKit binds to: Checkpoint
-- (index), SpawnSlot (index), Finish, Hazard ("kill"), Gate (index), BuildSlot (index), Lane.
-- The course record (kind, hash, spawn, finish, checkpoints with respawns, killY) is appended to
-- scene.meta.courses. Course coordinates are world coordinates: build a course outside
-- Scene.transformed.
local Scene = require("../SceneKit/Scene")

local CourseScene = {}
type Scene = Scene.Scene

local THICKNESS = 1 -- pad and track thickness, studs (Course.PAD_THICKNESS)
local GATE_HEIGHT = 12 -- gate posts and triggers, studs (convention: over a jumping character)
local MARK = 0.2 -- thickness of flat markers (slots, spawn pads), studs

local function attrs(asset: string, extra: { [string]: any }?): { [string]: any }
	local out: { [string]: any } = { asset = asset }
	local fields: { [string]: any } = extra or {}
	for key, value in fields do
		out[key] = value
	end
	return out
end

-- scene:group for a body that returns nothing. Scene.group is generic over one return value, so
-- a body without a return does not type-check against `() -> T`; this one returns nil for it.
local function group(scene: Scene, name: string, body: () -> ())
	scene:group(name, function()
		body()
		return nil
	end)
end

local PAD_ROLE = { spawn = "spawn", platform = "platform", checkpoint = "checkpoint", finish = "finish" }

local function jumpCourse(scene: Scene, course: any)
	local checkpointOf = {}
	for _, cp in course.checkpoints do
		checkpointOf[cp.pad] = cp.index
	end
	group(scene, "Pads", function()
		for index, pad in course.pads do
			local role = PAD_ROLE[pad.role] or "platform"
			local extra: { [string]: any } = { CoursePad = pad.id }
			if checkpointOf[index] then
				extra.Checkpoint = checkpointOf[index]
			end
			if index == course.spawn.pad then
				extra.SpawnSlot = 1
			end
			if index == course.finish.pad then
				extra.Finish = true
			end
			scene:add({
				role = role,
				name = pad.id,
				size = { x = pad.size.x, y = pad.size.y, z = pad.size.z },
				pos = { x = pad.pos.x, y = pad.pos.y - pad.size.y / 2, z = pad.pos.z },
				rot = { x = 0, y = pad.yaw, z = 0 },
				attributes = attrs("course_" .. role, extra),
			})
		end
	end)
	if #course.hazards > 0 then
		group(scene, "Hazards", function()
			for _, hazard in course.hazards do
				scene:add({
					role = "hazard",
					name = "hazard",
					size = { x = hazard.size.x, y = hazard.size.y, z = hazard.size.z },
					pos = { x = hazard.pos.x, y = hazard.pos.y - hazard.size.y / 2, z = hazard.pos.z },
					rot = { x = 0, y = hazard.yaw, z = 0 },
					attributes = attrs("course_hazard", { Hazard = "kill", Segment = hazard.segment }),
				})
			end
		end)
	end
	if course.structures and #course.structures > 0 then
		group(scene, "Structures", function()
			for _, structure in course.structures do
				scene:add({
					role = "structure",
					name = structure.role,
					size = { x = structure.size.x, y = structure.size.y, z = structure.size.z },
					pos = { x = structure.pos.x, y = structure.pos.y, z = structure.pos.z },
					attributes = attrs("course_" .. structure.role),
				})
			end
		end)
	end
end

local function raceLoop(scene: Scene, course: any)
	local samples = course.samples
	local n = #samples
	local width = course.params.width
	group(scene, "Track", function()
		for i = 1, n do
			local a, b = samples[i], samples[i % n + 1]
			local dx, dy, dz = b.pos.x - a.pos.x, b.pos.y - a.pos.y, b.pos.z - a.pos.z
			local flat = math.sqrt(dx * dx + dz * dz)
			local length = math.sqrt(flat * flat + dy * dy)
			-- Heading of the piece; the outer edge of a turn needs the piece a little longer so
			-- neighbouring pieces meet there (the inner edge overlaps).
			local yaw = math.deg(math.atan2(dx, dz))
			local turn = math.rad(math.abs(((b.yaw - a.yaw + 180) % 360) - 180))
			local extra = width * math.tan(math.min(turn, 1.2) / 2) + 0.1
			local pitch = -math.deg(math.atan2(dy, flat))
			local roll = (a.bank + b.bank) / 2
			scene:add({
				role = "track",
				name = "track",
				size = { x = width, y = THICKNESS, z = length + extra },
				pos = {
					x = (a.pos.x + b.pos.x) / 2,
					y = (a.pos.y + b.pos.y) / 2 - THICKNESS / 2,
					z = (a.pos.z + b.pos.z) / 2,
				},
				rot = { x = pitch, y = yaw % 360, z = roll },
				attributes = attrs("course_track", { Sample = i }),
			})
		end
	end)
	group(scene, "Gates", function()
		for _, gate in course.checkpoints do
			local point = samples[gate.sample]
			local r = math.rad(point.yaw)
			local ax, az = math.cos(r), -math.sin(r)
			local half = gate.width / 2 + 0.5
			local finish = gate.index == course.finish.gate
			local role = if finish then "finish" else "gate"
			for _, side in { -1, 1 } do
				scene:add({
					role = role,
					name = "post",
					size = { x = 1, y = GATE_HEIGHT, z = 1 },
					pos = {
						x = point.pos.x + ax * half * side,
						y = point.pos.y + GATE_HEIGHT / 2,
						z = point.pos.z + az * half * side,
					},
					rot = { x = 0, y = point.yaw, z = 0 },
					attributes = attrs("course_gate_post", { Gate = gate.index }),
				})
			end
			scene:add({
				role = role,
				name = "crossbar",
				size = { x = gate.width + 2, y = 1, z = 1 },
				pos = { x = point.pos.x, y = point.pos.y + GATE_HEIGHT + 0.5, z = point.pos.z },
				rot = { x = 0, y = point.yaw, z = 0 },
				attributes = attrs("course_gate_bar", { Gate = gate.index }),
			})
			scene:add({
				role = "gate",
				name = "trigger",
				size = { x = gate.width, y = GATE_HEIGHT, z = gate.size.z },
				pos = { x = point.pos.x, y = point.pos.y + GATE_HEIGHT / 2, z = point.pos.z },
				rot = { x = 0, y = point.yaw, z = 0 },
				transparency = 0.85,
				canCollide = false,
				attributes = attrs(
					"course_gate_trigger",
					{ Gate = gate.index, Checkpoint = gate.index, Finish = if finish then true else nil }
				),
			})
		end
	end)
	group(scene, "Grid", function()
		for _, slot in course.spawn.slots do
			local point = samples[slot.sample]
			local lift = slot.lateral * math.sin(math.rad(point.bank))
			scene:add({
				role = "spawn",
				name = "grid_slot",
				size = { x = 6, y = MARK, z = 8 },
				pos = { x = slot.pos.x, y = slot.pos.y + lift + MARK / 2, z = slot.pos.z },
				rot = { x = 0, y = slot.yaw, z = point.bank },
				canCollide = false,
				attributes = attrs("course_grid_slot", { SpawnSlot = slot.index }),
			})
		end
	end)
end

local function lanes(scene: Scene, course: any)
	local cell = course.grid.cellSize
	local width, rows = course.grid.width, course.grid.height
	group(scene, "Ground", function()
		scene:add({
			role = "ground",
			name = "ground",
			size = { x = width * cell, y = THICKNESS, z = (rows + 4) * cell },
			pos = { x = width * cell / 2, y = -THICKNESS / 2, z = rows * cell / 2 },
			attributes = attrs("course_ground"),
		})
		scene:add({
			role = "spawn",
			name = "spawn_edge",
			size = { x = width * cell, y = MARK, z = 2 * cell },
			pos = { x = width * cell / 2, y = MARK / 2, z = -cell },
			attributes = attrs("course_spawn_edge", { SpawnSlot = 1 }),
		})
		scene:add({
			role = "finish",
			name = "base",
			size = { x = width * cell, y = MARK, z = 2 * cell },
			pos = { x = width * cell / 2, y = MARK / 2, z = (rows + 1) * cell },
			attributes = attrs("course_base", { Finish = true }),
		})
	end)
	group(scene, "Lanes", function()
		local seenStart = {}
		for _, run in course.segments do
			-- Cells from..to inclusive; a run after the lane's first starts one cell in, so the
			-- corner cell it shares with the previous run is laid once.
			local fx, fy, tx, ty = run.from[1], run.from[2], run.to[1], run.to[2]
			if seenStart[run.lane] then
				local sx, sy =
					(if tx > fx then 1 elseif tx < fx then -1 else 0),
					(if ty > fy then 1 elseif ty < fy then -1 else 0)
				fx, fy = fx + sx, fy + sy
			end
			seenStart[run.lane] = true
			local x0, x1 = math.min(fx, tx) - 1, math.max(fx, tx)
			local y0, y1 = math.min(fy, ty) - 1, math.max(fy, ty)
			scene:add({
				role = "lane",
				name = "lane" .. run.lane,
				size = { x = (x1 - x0) * cell, y = MARK, z = (y1 - y0) * cell },
				pos = { x = (x0 + x1) / 2 * cell, y = MARK / 2, z = (y0 + y1) / 2 * cell },
				attributes = attrs("course_lane", { Lane = run.lane, Segment = run.index }),
			})
		end
	end)
	group(scene, "Slots", function()
		for _, slot in course.slots do
			scene:add({
				role = "slot",
				name = "slot",
				size = { x = cell * 0.8, y = MARK, z = cell * 0.8 },
				pos = { x = slot.pos.x, y = MARK / 2, z = slot.pos.z },
				attributes = attrs("course_build_slot", { BuildSlot = slot.index, Lane = slot.lane }),
			})
		end
	end)
end

local function microArena(scene: Scene, course: any)
	local arena = course.arena
	group(scene, "Floor", function()
		if #course.tiles > 0 then
			for index, tile in course.tiles do
				scene:add({
					role = "ground",
					name = "tile",
					size = { x = tile.size.x, y = tile.size.y, z = tile.size.z },
					pos = { x = tile.pos.x, y = tile.pos.y, z = tile.pos.z },
					attributes = attrs("course_floor_tile", { Tile = index }),
				})
			end
		elseif arena.shape == "round" then
			scene:add({
				role = "ground",
				name = "floor",
				shape = "Cylinder",
				size = { x = THICKNESS, y = arena.half * 2, z = arena.half * 2 },
				pos = { x = 0, y = -THICKNESS / 2, z = 0 },
				rot = { x = 0, y = 0, z = 90 },
				attributes = attrs("course_floor"),
			})
		else
			scene:add({
				role = "ground",
				name = "floor",
				size = { x = arena.half * 2, y = THICKNESS, z = arena.half * 2 },
				pos = { x = 0, y = -THICKNESS / 2, z = 0 },
				attributes = attrs("course_floor"),
			})
		end
	end)
	if arena.edge == "wall" then
		group(scene, "Edge", function()
			local height = 6
			if arena.shape == "round" then
				-- Wall pieces about 8 studs long on a ring just outside the floor.
				local count = math.max(8, math.ceil(2 * math.pi * arena.half / 8))
				local radius = arena.half + 0.5
				local length = 2 * radius * math.tan(math.pi / count) + 0.2
				for k = 0, count - 1 do
					local angle = k * 360 / count
					local r = math.rad(angle)
					scene:add({
						role = "barrier",
						name = "wall",
						size = { x = length, y = height, z = 1 },
						pos = { x = radius * math.cos(r), y = height / 2, z = radius * math.sin(r) },
						rot = { x = 0, y = -(angle + 90) % 360, z = 0 },
						attributes = attrs("course_wall"),
					})
				end
			else
				local span = arena.half * 2 + 2
				for _, side in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
					scene:add({
						role = "barrier",
						name = "wall",
						size = {
							x = if side[1] ~= 0 then 1 else span,
							y = height,
							z = if side[1] ~= 0 then span else 1,
						},
						pos = {
							x = side[1] * (arena.half + 0.5),
							y = height / 2,
							z = side[2] * (arena.half + 0.5),
						},
						attributes = attrs("course_wall"),
					})
				end
			end
		end)
	end
	group(scene, "Pieces", function()
		for _, piece in course.segments do
			scene:add({
				role = piece.role,
				name = piece.role,
				size = { x = piece.size.x, y = piece.size.y, z = piece.size.z },
				pos = { x = piece.pos.x, y = piece.pos.y, z = piece.pos.z },
				rot = { x = 0, y = piece.yaw, z = 0 },
				attributes = attrs(
					"course_" .. piece.role,
					{ Sector = piece.sector, Hazard = if piece.role == "hazard" then "kill" else nil }
				),
			})
		end
	end)
	group(scene, "Spawns", function()
		for _, slot in course.spawn.slots do
			scene:add({
				role = "spawn",
				name = "spawn",
				size = { x = 4, y = MARK, z = 4 },
				pos = { x = slot.pos.x, y = slot.pos.y + MARK / 2, z = slot.pos.z },
				rot = { x = 0, y = slot.yaw, z = 0 },
				attributes = attrs("course_spawn", { SpawnSlot = slot.index }),
			})
		end
	end)
end

local BUILDERS = {
	linear = jumpCourse,
	tower = jumpCourse,
	race_loop = raceLoop,
	lanes = lanes,
	micro_arena = microArena,
}

-- Adds a course's parts to `scene` (inside a group named after the kind) and returns the scene.
function CourseScene.into(scene: Scene, course: any): Scene
	assert(type(course) == "table" and course.schema == "course/1", "CourseScene: not a course/1 manifest")
	local builder = BUILDERS[course.kind]
	assert(builder, "CourseScene: unknown course kind " .. tostring(course.kind))
	group(scene, course.kind, function()
		builder(scene, course)
	end)
	local meta = scene.meta :: any
	meta.courses = meta.courses or {}
	local checkpoints = {}
	for _, cp in course.checkpoints do
		table.insert(checkpoints, {
			index = cp.index,
			pos = cp.pos,
			respawn = cp.respawn,
			lane = cp.lane,
			gate = if course.kind == "race_loop" then cp.index else nil,
		})
	end
	table.insert(meta.courses, {
		kind = course.kind,
		hash = course.hash,
		spawn = { pos = course.spawn.pos, yaw = course.spawn.yaw },
		finish = { pos = course.finish.pos, yaw = course.finish.yaw },
		checkpoints = checkpoints,
		killY = course.killY,
	})
	return scene
end

-- A new Scene holding the course: name "Course_<kind>" unless options.name, style id (default
-- greybox), seed from the course params.
function CourseScene.toScene(course: any, style: string?, options: { name: string? }?): Scene
	local scene = Scene.new({
		name = options and options.name or ("Course_" .. tostring(course and course.kind)),
		seed = course and course.params and course.params.seed or 0,
		style = style,
		provenance = { source = "ProcGen/Course", generated = true, course = course and course.hash },
	})
	return CourseScene.into(scene, course)
end

return CourseScene
