--!strict
-- Builds the neutral SETUP_ONLY benchmark scenes with SceneKit + ProcGen and writes, per
-- fixture: <name>.rbxlx (open in Studio), <name>.manifest.json (Blender preview input,
-- diffing) and one validation report. Usage: lune run tools/lune/build_fixtures.luau [outDir]
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local Arena = require("../../packages/ProcGen/Arena")
local Cave = require("../../packages/ProcGen/Cave")
local Course = require("../../packages/ProcGen/Course")
local Dungeon = require("../../packages/ProcGen/Dungeon")
local Forest = require("../../packages/ProcGen/Forest")
local ForestScene = require("../../packages/ProcGen/ForestScene")
local Manifest = require("../../packages/ProcGen/Manifest")
local Placement = require("../../packages/ProcGen/Placement")
local PValidate = require("../../packages/ProcGen/Validate")
local Settlement = require("../../packages/ProcGen/Settlement")
local SK = require("../../packages/SceneKit/SceneKit")

local outDir = process.args[1] or "build/fixtures"
fs.writeDir(outDir)

local fixtures = {}

fixtures.modular_building = function()
	local scene = SK.Scene.new({ name = "SETUP_ONLY_ModularBuilding", seed = 101, style = "neutral-stone" })
	SK.Building.create(scene, {
		name = "Townhouse",
		footprint = { x = -16, z = -12, w = 32, d = 24 },
		storeys = 3,
		roof = { style = "gable", pitch = 32 },
	})
	SK.Building.create(scene, {
		name = "Annex",
		footprint = { x = 24, z = -10, w = 20, d = 20 },
		storeys = 1,
		roof = { style = "flat" },
		stairs = false,
	})
	SK.Building.column(scene, { pos = { x = -10, y = 0, z = -20 }, height = 12, round = true })
	SK.Building.column(scene, { pos = { x = 10, y = 0, z = -20 }, height = 12, round = true })
	SK.Building.arch(scene, { pos = { x = 0, y = 12, z = -20 }, span = 20, depth = 2 })
	-- Entrance ramp: rises from the ground (+Z, yaw 270) to the Annex door sill, ending flush with
	-- the foundation's front edge (footprint z - 0.5 outset) instead of being sunk inside it.
	local annexDoor: any = nil
	for _, record in scene.meta.doors do
		if record.group == "Annex/Storey1" and record.kind == "door" then
			annexDoor = record
		end
	end
	assert(annexDoor, "Annex front door missing")
	local sillY, foundationFront, run = annexDoor.pos.y, -10 - 0.5, 6
	SK.Building.ramp(scene, {
		base = { x = annexDoor.pos.x, y = 0, z = foundationFront - run },
		yaw = 270,
		rise = sillY,
		run = run,
		width = annexDoor.width,
	})
	SK.Paths.fence(scene, { { x = -30, y = 0, z = -30 }, { x = 50, y = 0, z = -30 } })
	return scene, {}
end

fixtures.settlement = function()
	local layout = Settlement.generate({ seed = 202, streets = 3, length = 220 })
	local scene = SK.Scene.new({ name = "SETUP_ONLY_Settlement", seed = 202, style = "neutral-timber" })
	for _, road in layout.roads do
		SK.Paths.road(
			scene,
			{ { x = road.from[1], y = 0, z = road.from[2] }, { x = road.to[1], y = 0, z = road.to[2] } },
			{ width = road.width, kerb = true }
		)
	end
	for index, lot in layout.lots do
		local fp = lot.footprint
		local center = { x = fp.x + fp.w / 2, y = 0, z = fp.z + fp.d / 2 }
		local turned = lot.facing == 90 or lot.facing == 270
		local w, d = if turned then fp.d else fp.w, if turned then fp.w else fp.d
		scene:transformed(center, lot.facing, function()
			SK.Building.create(scene, {
				name = "House" .. index,
				footprint = { x = -w / 2, z = -d / 2, w = w, d = d },
				storeys = if index % 3 == 0 and w >= 22 then 2 else 1,
				storeyHeight = 11,
				roof = { style = if index % 4 == 0 then "flat" else "gable" },
				seed = index,
				interior = { minRoom = 8 },
			})
		end)
	end
	local occupied = {}
	for _, lot in layout.lots do
		table.insert(occupied, { lot.x - 2, lot.z - 2, lot.w + 4, lot.d + 4 })
	end
	for _, road in layout.roads do
		local x0, x1 =
			math.min(road.from[1], road.to[1]) - road.width, math.max(road.from[1], road.to[1]) + road.width
		local z0, z1 =
			math.min(road.from[2], road.to[2]) - road.width, math.max(road.from[2], road.to[2]) + road.width
		table.insert(occupied, { x0, z0, x1 - x0, z1 - z0 })
	end
	SK.Vegetation.scatter(scene, {
		rect = { x = -160, z = -160, w = 320, d = 320 },
		radius = 12,
		density = 0.5,
		seed = 202,
		exclude = function(x, z)
			for _, r in occupied do
				if x > r[1] and x < r[1] + r[3] and z > r[2] and z < r[2] + r[4] then
					return true
				end
			end
			return false
		end,
	})
	return scene, { procgen = PValidate.settlement(layout), layoutHash = Manifest.fromLayout(layout).hash }
end

fixtures.dungeon = function()
	local layout = Dungeon.generate({
		seed = 303,
		width = 48,
		height = 48,
		cellSize = 4,
		corridorWidth = 2,
		loopChance = 0.2,
	})
	local placement = Placement.assign(layout, { encounters = 3, landmarks = 1 })
	local scene = SK.Scene.new({ name = "SETUP_ONLY_Dungeon", seed = 303, style = "greybox" })
	SK.Layout.toScene(scene, layout, { wallHeight = 12, placement = placement })
	return scene,
		{
			procgen = PValidate.rooms(layout, placement),
			layoutHash = Manifest.fromLayout(layout, { roles = placement.roles }).hash,
			ascii = layout.grid:toAscii(),
		}
end

fixtures.arena = function()
	local layout = Arena.generate({ seed = 404, width = 40, height = 24 })
	local scene = SK.Scene.new({ name = "SETUP_ONLY_Arena", seed = 404, style = "greybox" })
	SK.Layout.toScene(scene, layout, { wallHeight = 8 })
	return scene,
		{
			procgen = PValidate.arena(layout),
			layoutHash = Manifest.fromLayout(layout).hash,
			ascii = layout.grid:toAscii(),
		}
end

fixtures.cave = function()
	local layout = Cave.generate({ seed = 505, width = 48, height = 36 })
	local scene = SK.Scene.new({ name = "SETUP_ONLY_Cave", seed = 505, style = "greybox" })
	SK.Layout.toScene(scene, layout, { wallHeight = 14, ceiling = true })
	return scene,
		{
			procgen = PValidate.grid(layout.grid),
			layoutHash = Manifest.fromLayout(layout).hash,
			ascii = layout.grid:toAscii(),
		}
end

fixtures.forest = function()
	local layout = Forest.generate({ seed = 606, width = 256, depth = 192, clearings = 4 })
	local scene = SK.Scene.new({ name = "SETUP_ONLY_Forest", seed = 606, style = "neutral-timber" })
	ForestScene.toScene(scene, layout)
	return scene,
		{
			procgen = PValidate.forest(layout),
			layoutHash = Manifest.fromLayout(layout).hash,
			ascii = Forest.toAscii(layout),
		}
end

-- Course fixtures: one per ProcGen Course kind, default player (R15 guide numbers), validated
-- with Validate.course (jump physics, checkpoints, loop, lanes, spawns).
local function courseFixture(name: string, params: { [string]: any })
	return function()
		local course = Course.generate(params)
		local scene = Course.toScene(course, "greybox", { name = name })
		return scene, { procgen = PValidate.course(course), layoutHash = course.hash }
	end
end
fixtures.course_linear =
	courseFixture("SETUP_ONLY_CourseLinear", { kind = "linear", seed = 701, length = 24 })
fixtures.course_tower = courseFixture("SETUP_ONLY_CourseTower", { kind = "tower", seed = 702, floors = 4 })
fixtures.course_race_loop = courseFixture("SETUP_ONLY_CourseRaceLoop", { kind = "race_loop", seed = 703 })
fixtures.course_lanes = courseFixture("SETUP_ONLY_CourseLanes", { kind = "lanes", seed = 704, lanes = 3 })
fixtures.course_micro_arena = courseFixture(
	"SETUP_ONLY_CourseMicroArena",
	{ kind = "micro_arena", seed = 705, players = 8, edge = "wall" }
)

local only = process.args[2]
local report = { generatedBy = "tools/lune/build_fixtures.luau", fixtures = {} }
local names = {}
for name in fixtures do
	table.insert(names, name)
end
table.sort(names)
local allPass = true
for _, name in names do
	if only == nil or only == name then
		local scene, extra = fixtures[name]()
		local checks = SK.Validate.scene(scene)
		for _, c in extra.procgen or {} do
			table.insert(checks, c)
		end
		local summary = SK.Validate.summary(checks)
		allPass = allPass and summary.pass
		local manifest = scene:manifest()
		manifest.cameras = SK.Camera.captureSet(SK.Scene.bounds(scene))
		local game = roblox.Instance.new("DataModel")
		SK.Lighting.apply(game:GetService("Lighting"), "neutral-day", roblox)
		local applied = SK.Apply.scene(scene, game:GetService("Workspace"), { env = roblox })
		fs.writeFile(outDir .. "/" .. name .. ".rbxlx", roblox.serializePlace(game, true))
		fs.writeFile(outDir .. "/" .. name .. ".manifest.json", serde.encode("json", manifest, false))
		report.fixtures[name] = {
			pass = summary.pass,
			failed = summary.failed,
			checks = checks,
			parts = applied.parts,
			hash = applied.hash,
			layoutHash = extra.layoutHash,
			ascii = extra.ascii,
		}
		print(
			string.format(
				"%-18s %s parts=%d hash=%s %s",
				name,
				if summary.pass then "PASS" else "FAIL",
				applied.parts,
				applied.hash,
				table.concat(summary.failed, ",")
			)
		)
	end
end
report.pass = allPass
fs.writeFile(outDir .. "/report.json", serde.encode("json", report, true))
if not allPass then
	process.exit(1)
end
