local roblox = require("@lune/roblox")
local SK = require("../packages/SceneKit/SceneKit")
local Manifest = require("../packages/ProcGen/Manifest")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

test("Vec.rotate matches Roblox CFrame.fromOrientation", function(t)
	local samples = { { 0, 90, 0 }, { 30, 0, 0 }, { 0, 0, 45 }, { 20, 35, -50 }, { -90, 180, 10 } }
	for _, rot in samples do
		local cf = roblox.CFrame.fromOrientation(math.rad(rot[1]), math.rad(rot[2]), math.rad(rot[3]))
		local expected = cf:VectorToWorldSpace(roblox.Vector3.new(1, 2, 3))
		local got = SK.Vec.rotate({ x = 1, y = 2, z = 3 }, { x = rot[1], y = rot[2], z = rot[3] })
		t.near(got.x, expected.X, 1e-5)
		t.near(got.y, expected.Y, 1e-5)
		t.near(got.z, expected.Z, 1e-5)
	end
end)

test("wall openings cut the expected pieces", function(t)
	local scene = SK.Scene.new({ name = "W" })
	SK.Building.wall(scene, {
		from = { 0, 0 },
		to = { 20, 0 },
		y = 0,
		height = 10,
		openings = {
			{ at = 5, width = 4, bottom = 0, height = 8, kind = "door" },
			{ at = 14, width = 4, bottom = 3, height = 4, kind = "window" },
		},
	})
	-- left, door lintel, middle, window sill, window head, glass, right
	t.eq(#scene.specs, 7)
	local area = 0
	for _, s in scene.specs do
		if s.role == "wall" then
			area += s.size.x * s.size.y
		end
	end
	t.near(area, 20 * 10 - 4 * 8 - 4 * 4, 1e-6, "solid wall area")
	t.eq(#scene.meta.doors, 1)
	t.throws(function()
		SK.Building.wall(scene, {
			from = { 0, 0 },
			to = { 4, 0 },
			y = 0,
			height = 10,
			openings = { { at = 3, width = 4, bottom = 0, height = 8 } },
		})
	end, "opening outside wall must error")
end)

test("floor hole leaves four strips with the right area", function(t)
	local scene = SK.Scene.new({ name = "F" })
	SK.Building.floor(
		scene,
		{ rect = { x = 0, z = 0, w = 20, d = 10 }, y = 0, hole = { x = 5, z = 2, w = 6, d = 4 } }
	)
	local area = 0
	for _, s in scene.specs do
		area += s.size.x * s.size.z
	end
	t.near(area, 200 - 24, 1e-6)
end)

test("buildings pass clearance, stair and headroom validation", function(t)
	for storeys = 1, 4 do
		for _, roof in { "gable", "flat", "shed" } do
			local scene = SK.Scene.new({ name = "B", seed = storeys, style = "neutral-stone" })
			SK.Building.create(
				scene,
				{ footprint = { x = 0, z = 0, w = 30, d = 26 }, storeys = storeys, roof = { style = roof } }
			)
			local summary = SK.Validate.summary(SK.Validate.scene(scene))
			t.ok(
				summary.pass,
				string.format("%d storeys %s: %s", storeys, roof, table.concat(summary.failed, ","))
			)
			t.eq(#scene.meta.stairs, storeys - 1)
		end
	end
end)

test("validator catches a stair flight under another (headroom)", function(t)
	local scene = SK.Scene.new({ name = "H" })
	SK.Building.stairs(scene, { base = { x = 0, y = 0, z = 0 }, rise = 12 })
	SK.Building.stairs(scene, { base = { x = 0, y = 12, z = 0 }, rise = 12 })
	local failed = SK.Validate.summary(SK.Validate.scene(scene)).failed
	t.ok(table.find(failed, "stair_headroom"), "stacked flights must fail headroom")
end)

test("measurement: jump reach, clearances, sightline", function(t)
	t.near(SK.Measure.jumpReach(0) :: number, 8.67, 0.02, "flat jump reach")
	t.eq(SK.Measure.jumpReach(8), nil, "above jump height")
	t.ok(SK.Measure.canJump(6, 2))
	t.ok(not SK.Measure.canJump(9, 0))
	t.ok(SK.Measure.doorClearance(4, 7).pass)
	t.ok(not SK.Measure.doorClearance(3, 7).pass)
	t.eq(SK.Measure.coverClass(4), "half")
	local scene = SK.Scene.new({ name = "S" })
	scene:box("wall", { x = 4, y = 0, z = -5 }, { x = 5, y = 10, z = 5 })
	t.ok(not SK.Measure.sightline(scene, { x = 0, y = 2, z = 0 }, { x = 10, y = 2, z = 0 }).visible)
	t.ok(SK.Measure.sightline(scene, { x = 0, y = 12, z = 0 }, { x = 10, y = 12, z = 0 }).visible)
	t.near(SK.Measure.angle({ x = 1, y = 0, z = 0 }, { x = 0, y = 0, z = 1 }), 90, 1e-9)
end)

test("scene manifests diff by part id", function(t)
	local function build(w)
		local scene = SK.Scene.new({ name = "D", seed = 1 })
		SK.Building.create(
			scene,
			{ footprint = { x = 0, z = 0, w = w, d = 24 }, storeys = 1, interior = false }
		)
		return scene:manifest()
	end
	local a, b, c = build(24), build(24), build(28)
	t.ok(SK.Scene.compare(a, b).identical)
	local diff = SK.Scene.compare(a, c)
	t.ok(not diff.identical and #diff.changed > 0)
end)

test("props: poisson spacing and exclusion", function(t)
	local points = SK.Props.poisson({ x = 0, z = 0, w = 100, d = 100 }, 8, 3, {
		exclude = function(x, z)
			return x < 50
		end,
	})
	t.ok(#points > 20)
	for i, p in points do
		t.ok(p[1] >= 50, "excluded region respected")
		for j = i + 1, #points do
			local q = points[j]
			t.ok((p[1] - q[1]) ^ 2 + (p[2] - q[2]) ^ 2 >= 64 - 1e-6, "min spacing")
		end
	end
end)

test("layout merge covers every floor cell exactly once", function(t)
	local Dungeon = require("../packages/ProcGen/Dungeon")
	local layout = Dungeon.generate({ seed = 5 })
	local rects = SK.Layout.merge(layout.grid.width, layout.grid.height, function(x, y)
		return layout.grid:get(x, y) ~= 0
	end)
	local covered = 0
	for _, r in rects do
		covered += r[3] * r[4]
	end
	t.eq(covered, layout.grid:count(1))
	t.ok(#rects < covered / 4, "merging reduces part count")
end)

test("terrain heightmap ops are deterministic and validated", function(t)
	local hm = SK.Terrain.heightmap({ cols = 32, rows = 32, seed = "t" })
	SK.Terrain.flatten(hm, { x = 64, z = 64, w = 64, d = 64 }, 8)
	SK.Terrain.smooth(hm, 1)
	SK.Terrain.paint(hm)
	local ops = SK.Terrain.toOps(hm)
	t.ok(#ops > 0 and #ops <= 32 * 32)
	local hm2 = SK.Terrain.heightmap({ cols = 32, rows = 32, seed = "t" })
	SK.Terrain.flatten(hm2, { x = 64, z = 64, w = 64, d = 64 }, 8)
	SK.Terrain.smooth(hm2, 1)
	SK.Terrain.paint(hm2)
	t.eq(Manifest.hash(SK.Terrain.toOps(hm2)), Manifest.hash(ops))
	for _, c in SK.Terrain.validate(hm) do
		t.ok(c.pass, c.name)
	end
end)

test("camera framing fits the bounds", function(t)
	local view = SK.Camera.frame({ x = -10, y = 0, z = -10 }, { x = 10, y = 20, z = 10 }, "front", 70)
	t.ok(view.distance > 17)
	t.near(view.focus.y, 10, 1e-9)
end)

test("Apply builds matching instances in a DataModel (Lune)", function(t)
	local scene = SK.Scene.new({ name = "ApplyTest", seed = 1 })
	SK.Building.create(scene, { footprint = { x = 0, z = 0, w = 24, d = 20 }, storeys = 2 })
	local game = roblox.Instance.new("DataModel")
	local ws = game:GetService("Workspace")
	local summary, model = SK.Apply.scene(scene, ws, { env = roblox })
	local parts = 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			parts += 1
			local spec = nil
			for _, s in scene.specs do
				if s.id == d:GetAttribute("SceneKitId") then
					spec = s
				end
			end
			t.ok(spec, "part maps to spec")
			t.near(d.CFrame.Position.X, spec.pos.x, 1e-3)
			t.near(d.CFrame.Position.Y, spec.pos.y, 1e-3)
		end
	end
	t.eq(parts, #scene.specs)
	t.eq(summary.parts, parts)
	-- Re-applying replaces instead of duplicating.
	SK.Apply.scene(scene, ws, { env = roblox })
	t.eq(#ws:GetChildren(), 1)
	local dry = SK.Apply.scene(scene, ws, { dryRun = true })
	t.eq(dry.parts, parts)
end)

test("lighting profiles apply and inspect (schema 1 ids resolve to schema 2 presets)", function(t)
	local game = roblox.Instance.new("DataModel")
	local lighting = game:GetService("Lighting")
	SK.Lighting.apply(lighting, "golden-hour", roblox)
	t.near(lighting.ClockTime, 17.6, 1e-4)
	t.ok(lighting:FindFirstChildOfClass("Atmosphere"))
	t.eq(lighting:GetAttribute("SceneKitLightingProfile"), "golden_hour")
	t.eq(SK.Lighting.inspect(lighting).profile, "golden_hour")
	t.throws(function()
		SK.Lighting.apply(lighting, "no-such-profile", roblox)
	end, "unknown profile ids raise")
end)

test("gable roof slopes peak at the ridge", function(t)
	for _, footprint in { { x = 0, z = 0, w = 32, d = 24 }, { x = 0, z = 0, w = 20, d = 30 } } do
		local scene = SK.Scene.new({ name = "R" })
		SK.Building.roof(scene, { rect = footprint, y = 10, style = "gable", pitch = 30, overhang = 1.5 })
		local cx, cz = footprint.x + footprint.w / 2, footprint.z + footprint.d / 2
		local slabs = 0
		for _, spec in scene.specs do
			if spec.role == "roof" then
				slabs += 1
				-- The highest corner of each slab must sit on the ridge line (centre of the short axis).
				local best, bestY = nil, -math.huge
				for _, sx in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local corner = SK.Vec.add(
							spec.pos,
							SK.Vec.rotate(
								{ x = sx * spec.size.x / 2, y = spec.size.y / 2, z = sz * spec.size.z / 2 },
								spec.rot
							)
						)
						if corner.y > bestY then
							best, bestY = corner, corner.y
						end
					end
				end
				local offRidge = if footprint.w >= footprint.d
					then math.abs(best.z - cz)
					else math.abs(best.x - cx)
				t.ok(offRidge < 1, "slab peak is " .. offRidge .. " studs from the ridge")
				t.ok(bestY > 10 + 5, "ridge above eaves")
			end
		end
		t.eq(slabs, 2)
	end
end)

test("front camera sits in front of -Z facing buildings", function(t)
	local view = SK.Camera.frame({ x = -1, y = 0, z = -1 }, { x = 1, y = 2, z = 1 }, "front")
	t.ok(view.eye.z < 0)
end)

test("studio smoke scenes match the committed golden hashes", function(t)
	local fs = require("@lune/fs")
	local serde = require("@lune/serde")
	local FactorySmoke = require("../packages/Pipeline/FactorySmoke")
	-- Repo root from this spec's own path, so the spec runs from any working directory.
	local root = string.match(debug.info(1, "s"), "^(.*)[/\\]tests[/\\][^/\\]*$") or "."
	local golden = serde.decode("json", fs.readFile(root .. "/tests/golden/studio-smoke.json"))
	local game = roblox.Instance.new("DataModel")
	local result = FactorySmoke.run(game:GetService("Workspace"), roblox)
	for key, entry in result do
		t.eq(entry.hash, golden[key].hash, key .. " hash")
		t.eq(entry.instances, entry.parts, key .. " instances created")
		t.ok(entry.pass, key .. " validation")
	end
end)

return cases
