-- Coverage for SceneKit calls that had no spec: Terrain.sculpt/carve/water replayed through
-- Apply.terrain on a recording Terrain stand-in (call order, shapes, materials, broken input),
-- Measure.cameraClearance and Measure.corridorWidth with expected numbers, and
-- Vegetation.tree/bush/cluster/clear.
local roblox = require("@lune/roblox")
local SK = require("../packages/SceneKit/SceneKit")
local Manifest = require("../packages/ProcGen/Manifest")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

-- Records every FillBlock/FillBall call with plain numbers and the material name.
local function recordingTerrain()
	local calls = {}
	return {
		calls = calls,
		FillBlock = function(_, cf, size, material)
			local p = cf.Position
			table.insert(calls, {
				"FillBlock",
				{ p.X, p.Y, p.Z },
				{ size.X, size.Y, size.Z },
				material.Name,
			})
		end,
		FillBall = function(_, center, radius, material)
			table.insert(calls, { "FillBall", { center.X, center.Y, center.Z }, radius, material.Name })
		end,
	}
end

local function recorder()
	local calls = {}
	return {
		calls = calls,
		TryBeginRecording = function(_, name)
			table.insert(calls, "begin:" .. name)
			return "rec"
		end,
		FinishRecording = function(_, id, operation)
			table.insert(calls, "finish:" .. id .. ":" .. operation.Name)
		end,
	}
end

-- 4 x 3 cells of 8 studs, flat at height 2 (amplitude 0), base -8.
local function flat()
	return SK.Terrain.heightmap({
		cols = 4,
		rows = 3,
		cell = 8,
		base = -8,
		seed = "mc10",
		amplitude = 0,
		floor = 2,
	})
end

test("Terrain.sculpt raises a smooth bump and lowers with a negative amount", function(t)
	local hm = flat()
	SK.Terrain.sculpt(hm, 12, 12, 6, 10) -- centre of cell (2, 2); neighbours are 8 studs away
	t.eq(hm.heights, { 2, 2, 2, 2, 2, 12, 2, 2, 2, 2, 2, 2 })
	SK.Terrain.sculpt(hm, 12, 12, 12, -4) -- neighbours at 8 of 12: t = 1/3, smoothstep 7/27
	t.near(hm.heights[6], 8, 1e-9, "centre lowered by the full amount")
	t.near(hm.heights[2], 2 - 4 * 7 / 27, 1e-9, "neighbour lowered by the falloff")
	local u = 1 - math.sqrt(128) / 12 -- diagonal cell centre, 11.31 studs away
	t.near(hm.heights[1], 2 - 4 * u * u * (3 - 2 * u), 1e-9, "diagonal lowered by the falloff")
	t.near(hm.heights[4], 2, 1e-9, "far cell (20.4 studs) untouched")
end)

test("Apply.terrain replays sculpt, carve and water ops in order with shapes and materials", function(t)
	local hm = flat()
	SK.Terrain.sculpt(hm, 12, 12, 6, 10)
	SK.Terrain.paint(
		hm,
		{ bands = { { below = 6, material = "Sand" }, { below = math.huge, material = "Rock" } }, steep = 89 }
	)
	local ops = SK.Terrain.toOps(hm)
	t.eq(#ops, 5, "row 1 merged, row 2 split around the bump, row 3 merged")
	table.insert(ops, SK.Terrain.carve({ 12, 4, 12 }, 3))
	table.insert(ops, SK.Terrain.water({ 0, -8, 16 }, { 32, 0, 24 }))
	local terrain, history = recordingTerrain(), recorder()
	t.eq(SK.Apply.terrain(ops, terrain, roblox, { history = history }), 7)
	t.eq(terrain.calls, {
		{ "FillBlock", { 16, -3, 4 }, { 32, 10, 8 }, "Sand" },
		{ "FillBlock", { 4, -3, 12 }, { 8, 10, 8 }, "Sand" },
		{ "FillBlock", { 12, 2, 12 }, { 8, 20, 8 }, "Rock" },
		{ "FillBlock", { 24, -3, 12 }, { 16, 10, 8 }, "Sand" },
		{ "FillBlock", { 16, -3, 20 }, { 32, 10, 8 }, "Sand" },
		{ "FillBall", { 12, 4, 12 }, 3, "Air" },
		{ "FillBlock", { 16, -4, 20 }, { 32, 8, 8 }, "Water" },
	})
	t.eq(history.calls, { "begin:SceneKit terrain", "finish:rec:Commit" })
end)

test("Apply.terrain and Terrain.carve/water reject broken input before any voxel changes", function(t)
	local good = SK.Terrain.toOps(flat())
	for label, bad in
		{
			["unknown op"] = { op = "FillCylinder", pos = { 0, 0, 0 }, size = { 1, 1, 1 }, material = "Rock" },
			["unknown material"] = {
				op = "FillBlock",
				pos = { 0, 0, 0 },
				size = { 4, 4, 4 },
				material = "Lava2",
			},
			["flat block"] = { op = "FillBlock", pos = { 0, 0, 0 }, size = { 4, 0, 4 }, material = "Rock" },
			["zero radius"] = { op = "FillBall", pos = { 0, 0, 0 }, radius = 0, material = "Air" },
		}
	do
		local ops = table.clone(good)
		table.insert(ops, bad)
		local terrain = recordingTerrain()
		local ok, err = pcall(SK.Apply.terrain, ops, terrain, roblox)
		t.ok(not ok, label .. " must error")
		t.ok(
			string.find(tostring(err), "terrain op " .. #ops, 1, true),
			label .. " names the op: " .. tostring(err)
		)
		t.eq(#terrain.calls, 0, label .. ": nothing applied")
	end
	t.throws(function()
		SK.Terrain.carve({ 1, 2 }, 3)
	end, "carve needs three coordinates")
	t.throws(function()
		SK.Terrain.carve({ 1, 2, 3 }, 0)
	end, "carve radius must be positive")
	t.throws(function()
		SK.Terrain.water({ 0, 0, 0 }, { 10, 0, 10 })
	end, "water box with no height")
	t.throws(function()
		SK.Terrain.water({ 10, 0, 0 }, { 0, 5, 10 })
	end, "water min above max")
end)

test("Measure.cameraClearance: wall behind blocks at 6 studs, open side and glass are clear", function(t)
	local scene = SK.Scene.new({ name = "Cam" })
	scene:box("wall", { x = -7, y = 0, z = -5 }, { x = -6, y = 10, z = 5 })
	scene:box("glass", { x = 6, y = 0, z = -5 }, { x = 7, y = 10, z = 5 }, { transparency = 0.6 })
	local origin = { x = 0, y = 0, z = 0 }
	local blocked = SK.Measure.cameraClearance(scene, origin, { x = -1, y = 0, z = 0 })
	t.eq(blocked.clear, false)
	t.near(blocked.available, 6, 1e-9, "head to wall face")
	local open = SK.Measure.cameraClearance(scene, origin, { x = 0, y = 0, z = 1 })
	t.eq(open.clear, true)
	t.near(open.available, SK.Measure.ENGINE.cameraDistance, 1e-9, "full default boom")
	local glass = SK.Measure.cameraClearance(scene, origin, { x = 1, y = 0, z = 0 })
	t.eq(glass.clear, true, "transparent glass does not block the camera")
	local short = SK.Measure.cameraClearance(scene, origin, { x = -1, y = 0, z = 0 }, 5)
	t.eq(short.clear, true, "a 5-stud boom stops before the wall")
	t.near(short.available, 5, 1e-9)
	-- The boom starts at head height (1.5): a 1-stud kerb behind the feet does not block it.
	local kerb = SK.Scene.new({ name = "Kerb" })
	kerb:box("trim", { x = -4, y = 0, z = -5 }, { x = -3, y = 1, z = 5 })
	t.eq(SK.Measure.cameraClearance(kerb, origin, { x = -1, y = 0, z = 0 }).clear, true)
end)

test("Measure.corridorWidth: walls 5 apart fail, 6 pass, 10 comfortable, 3 players need 8.5", function(t)
	local function gap(width: number): number
		local scene = SK.Scene.new({ name = "Corridor" })
		local left = scene:box("wall", { x = -1, y = 0, z = 0 }, { x = 0, y = 10, z = 20 })
		local right = scene:box("wall", { x = width, y = 0, z = 0 }, { x = width + 1, y = 10, z = 20 })
		return SK.Measure.bounds(right).min.x - SK.Measure.bounds(left).max.x
	end
	t.eq(gap(5), 5)
	t.eq(SK.Measure.corridorWidth(gap(5)), { pass = false, comfortable = false })
	t.eq(SK.Measure.corridorWidth(gap(6)), { pass = true, comfortable = false })
	t.eq(SK.Measure.corridorWidth(gap(10)), { pass = true, comfortable = true })
	-- Three players abreast: 3 x characterWidth 2.5 + 1 = 8.5 studs.
	t.eq(SK.Measure.corridorWidth(8, 3), { pass = false, comfortable = false })
	t.eq(SK.Measure.corridorWidth(8.5, 3), { pass = true, comfortable = false })
	t.eq(SK.Measure.corridorWidth(1, 0).pass, false, "corridorMin applies even for zero players")
end)

test("Props.alignToWall and Props.distribute: offsets, yaw and spacing", function(t)
	local scene = SK.Scene.new({ name = "Dress" })
	local crate = { asset = "PropCrate", size = { x = 2, y = 2, z = 1 } }
	-- Wall face at z = 10, room on -Z: the prop backs onto the face with a 0.1 gap.
	local spec = SK.Props.alignToWall(scene, crate, { x = 3, y = 0, z = 10 }, { x = 0, y = 0, z = -1 })
	t.near(spec.pos.z, 10 - 0.5 - 0.1, 1e-9, "half depth plus gap off the wall")
	t.near(spec.pos.y, 1, 1e-9, "stands on y = 0")
	t.near(spec.rot.y % 360, 0, 1e-9, "front (-Z) faces into the room")
	local side = SK.Props.alignToWall(scene, crate, { x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 }, 0)
	t.near(side.pos.x, 0.5, 1e-9, "gap 0 sits flush")
	t.eq(
		SK.Validate.penetration(spec, scene:box("wall", { x = -5, y = 0, z = 10 }, { x = 5, y = 5, z = 11 })),
		0
	)
	-- Five evenly spaced along +Z, ends included, local X turned along the line.
	local row = SK.Props.distribute(scene, crate, { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 8 }, 5)
	t.eq(#row, 5)
	for index, placed in row do
		t.near(placed.pos.z, (index - 1) * 2, 1e-9, "spacing 2")
		local along = SK.Vec.rotate({ x = 1, y = 0, z = 0 }, placed.rot)
		t.near(math.abs(along.z), 1, 1e-9, "local X along the line")
	end
	t.near(
		SK.Props.distribute(scene, crate, { x = 0, y = 0, z = 0 }, { x = 4, y = 0, z = 0 }, 1)[1].pos.x,
		2,
		1e-9
	)
	t.eq(#scene.meta.placements, 8, "every placement recorded")
end)

test("Vegetation.tree, bush, cluster and clear", function(t)
	local scene = SK.Scene.new({ name = "Grove", seed = 9 })
	SK.Vegetation.tree(scene, 10, 0, 5, 2, "placeholder/oak")
	t.eq(#scene.specs, 2)
	local trunk, canopy = scene.specs[1], scene.specs[2]
	t.eq(trunk.role, "trunk")
	t.eq(trunk.shape, "Cylinder")
	t.eq(trunk.size, { x = 16, y = 2.8, z = 2.8 }, "scale 2 doubles the 8 x 1.4 trunk")
	t.eq(trunk.rot, { x = 0, y = 0, z = 90 }, "cylinder rolled upright")
	t.eq(trunk.pos, { x = 10, y = 8, z = 5 }, "trunk centre at half its height")
	t.eq(trunk.group, "Tree")
	t.eq(trunk.attributes.asset, "placeholder/oak")
	t.eq(canopy.shape, "Ball")
	t.eq(canopy.canCollide, false)
	t.eq(canopy.pos.y, 18)
	t.eq(scene.meta.placements[1].asset, "placeholder/oak")
	SK.Vegetation.bush(scene, -4, 1, 0)
	local bush = scene.specs[3]
	t.eq(bush.role, "foliage")
	t.eq(bush.size, { x = 3, y = 2.2, z = 3 })
	t.near(bush.pos.y, 2.1, 1e-9, "bush sits on y = 1")
	t.eq(bush.attributes.asset, "placeholder/bush")

	local function grove(seed: number)
		local s = SK.Scene.new({ name = "Grove", seed = seed })
		SK.Vegetation.cluster(s, { center = { 50, -20 }, radius = 12, count = 7 })
		return s
	end
	local a, b, c = grove(1), grove(1), grove(2)
	t.eq(#a.specs, 14, "7 trees, two parts each")
	for _, spec in a.specs do
		t.eq(string.sub(spec.group, 1, 10), "Grove/Tree")
		if spec.role == "trunk" then
			local d = math.sqrt((spec.pos.x - 50) ^ 2 + (spec.pos.z + 20) ^ 2)
			t.ok(d <= 12 + 1e-9, "tree inside the cluster radius")
			t.ok(spec.size.x >= 8 * 0.8 - 1e-9 and spec.size.x <= 8 * 1.3 + 1e-9, "scale within 0.8..1.3")
		end
	end
	t.eq(Manifest.hash(a:manifest().parts), Manifest.hash(b:manifest().parts), "same seed, same grove")
	t.ok(Manifest.hash(a:manifest().parts) ~= Manifest.hash(c:manifest().parts), "different seed")

	-- Clearing a rect outside the grove removes nothing; around it removes all 14 parts.
	t.eq(SK.Vegetation.clear(a, { x = -100, z = -100, w = 20, d = 20 }), 0)
	t.eq(SK.Vegetation.clear(a, { x = 30, z = -40, w = 40, d = 40 }), 14)
	t.eq(#a.specs, 0)
end)

return cases
