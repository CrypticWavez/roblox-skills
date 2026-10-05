-- Regression specs for SceneKit review findings: Apply replace default, doorways bisected by
-- partitions, stair-hole railings cutting the next flight, and the buried fixture ramp.
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local SK = require("../packages/SceneKit/SceneKit")
local Rng = require("../packages/ProcGen/Rng")
local Settlement = require("../packages/ProcGen/Settlement")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

-- Positive overlap of two specs' world AABBs on every axis (0 when they only touch).
local function overlap(a, b): number
	local amin, amax = SK.Scene.specBounds(a)
	local bmin, bmax = SK.Scene.specBounds(b)
	local x = math.min(amax.x, bmax.x) - math.max(amin.x, bmin.x)
	local y = math.min(amax.y, bmax.y) - math.max(amin.y, bmin.y)
	local z = math.min(amax.z, bmax.z) - math.max(amin.z, bmin.z)
	if x <= 1e-3 or y <= 1e-3 or z <= 1e-3 then
		return 0
	end
	return x * y * z
end

local function failedChecks(scene): { string }
	return SK.Validate.summary(SK.Validate.scene(scene)).failed
end

-- Every door's measured clear width must equal its nominal width (nothing intrudes at all).
local function assertDoorsClear(t, scene, label: string)
	local doors = 0
	for _, door in scene.meta.doors do
		if door.kind == "door" then
			doors += 1
			t.ok(door.dir ~= nil, label .. ": door record carries its wall axis")
			local clear = SK.Validate.doorClearWidth(door, scene.specs)
			t.near(clear, door.width, 1e-6, string.format("%s %s door clear width", label, door.group))
			t.ok(SK.Measure.doorClearance(clear, door.height).pass, label .. " door passes doorMin")
		end
	end
	return doors
end

-- Studio globals for Apply's default env; Lune has none, so inject them into Apply's module
-- environment for the duration of `body` and restore afterwards.
local function withStudioGlobals(body: () -> ())
	local env = getfenv(SK.Apply.scene)
	local names = { "Instance", "Vector3", "CFrame", "Color3", "Enum" }
	local saved = {}
	for _, name in names do
		saved[name] = env[name]
		env[name] = (roblox :: any)[name]
	end
	local ok, err = pcall(body)
	for _, name in names do
		env[name] = saved[name]
	end
	if not ok then
		error(err, 0)
	end
end

test("Apply.scene with no options replaces the previous model of the same name", function(t)
	local scene = SK.Scene.new({ name = "ApplyDefault", seed = 1 })
	SK.Building.create(scene, { footprint = { x = 0, z = 0, w = 24, d = 20 }, storeys = 1 })
	withStudioGlobals(function()
		local ws = roblox.Instance.new("DataModel"):GetService("Workspace")
		SK.Apply.scene(scene, ws)
		SK.Apply.scene(scene, ws)
		t.eq(#ws:GetChildren(), 1, "documented call SceneKit.Apply.scene(scene, workspace) twice")
		SK.Apply.scene(scene, ws, {})
		t.eq(#ws:GetChildren(), 1, "empty options table")
		-- Failure cases: replace = false keeps the old copy; a non-SceneKit model is never destroyed.
		SK.Apply.scene(scene, ws, { replace = false })
		t.eq(#ws:GetChildren(), 2, "replace = false must keep the previous model")
		local other = roblox.Instance.new("DataModel"):GetService("Workspace")
		local foreign = roblox.Instance.new("Model")
		foreign.Name = "ApplyDefault"
		foreign.Parent = other
		SK.Apply.scene(scene, other)
		t.eq(#other:GetChildren(), 2, "a same-named model without SceneKitHash is left alone")
		t.ok(foreign.Parent == other, "foreign model still parented")
	end)
end)

test("door_clearance measures the clear width and fails a bisected doorway", function(t)
	-- Partition door (width 5) on x = 13 with a perpendicular wall ending on it mid-span, as the
	-- old subdivide produced (seed 1, 40x30): clear runs 2.25 | 2.25.
	local scene = SK.Scene.new({ name = "Bisected" })
	SK.Building.floor(scene, { rect = { x = 0, z = 0, w = 30, d = 24 }, y = 1, thickness = 0.2 })
	SK.Building.wall(scene, {
		from = { 13, 1 },
		to = { 13, 23 },
		y = 1,
		height = 11,
		thickness = 0.5,
		openings = { { at = 11, width = 5, bottom = 0, height = 8, kind = "door" } },
	})
	SK.Building.wall(scene, { from = { 13, 12 }, to = { 26, 12 }, y = 1, height = 11, thickness = 0.5 })
	t.near(SK.Validate.doorClearWidth(scene.meta.doors[1], scene.specs), 2.25, 1e-6, "bisected door clear")
	t.ok(table.find(failedChecks(scene), "door_clearance"), "bisected door must fail door_clearance")

	-- Front door (width 6) with a partition starting at the wall's inner face inside the span.
	local front = SK.Scene.new({ name = "FrontDoor" })
	SK.Building.wall(front, {
		from = { 0, 0.5 },
		to = { 26, 0.5 },
		y = 1,
		height = 11,
		thickness = 1,
		openings = { { at = 12.86, width = 6, bottom = 0, height = 8, kind = "door" } },
	})
	SK.Building.wall(front, { from = { 13, 1 }, to = { 13, 12 }, y = 1, height = 10, thickness = 0.5 })
	local clear = SK.Validate.doorClearWidth(front.meta.doors[1], front.specs)
	t.near(clear, 12.75 - 9.86, 1e-6, "front door widest clear run (9.86..12.75)")
	t.ok(table.find(failedChecks(front), "door_clearance"), "partition in the front doorway must fail")

	-- Control: the same partition 1.5 studs beyond the door edge leaves the door fully clear.
	local ok = SK.Scene.new({ name = "Clear" })
	SK.Building.wall(ok, {
		from = { 0, 0.5 },
		to = { 26, 0.5 },
		y = 1,
		height = 11,
		thickness = 1,
		openings = { { at = 8, width = 6, bottom = 0, height = 8, kind = "door" } },
	})
	SK.Building.wall(ok, { from = { 12.5, 1 }, to = { 12.5, 12 }, y = 1, height = 10, thickness = 0.5 })
	t.near(SK.Validate.doorClearWidth(ok.meta.doors[1], ok.specs), 6, 1e-6, "unobstructed door")
	t.ok(not table.find(failedChecks(ok), "door_clearance"))
end)

test("door records keep their wall axis through scene:transformed", function(t)
	local scene = SK.Scene.new({ name = "Turned" })
	scene:transformed({ x = 10, y = 0, z = 5 }, 90, function()
		SK.Building.wall(scene, {
			from = { 0, 0 },
			to = { 10, 0 },
			y = 0,
			height = 10,
			openings = { { at = 5, width = 4, bottom = 0, height = 8, kind = "door" } },
		})
	end)
	local door = scene.meta.doors[1]
	t.near(door.dir.x, 0, 1e-9)
	t.near(door.dir.z, -1, 1e-9, "local +X turned by yaw 90 is world -Z")
	t.near(SK.Validate.doorClearWidth(door, scene.specs), 4, 1e-6)
end)

test("subdivide keeps cuts out of reserved doorways and doors off T-junctions", function(t)
	local clearance = 0.25 + SK.Measure.GUIDE.characterWidth / 2
	for seed = 1, 300 do
		local r = Rng.new(seed)
		local rect =
			{ x = r:range(-20, 20), z = r:range(-20, 20), w = 12 + r:int(0, 40), d = 8 + r:int(0, 30) }
		local minRoom = r:pick({ 5, 6, 8, 10 })
		local doorAt = rect.x + r:range(4, rect.w - 4)
		local span = { from = { doorAt - 3, rect.z }, to = { doorAt + 3, rect.z } }
		local rooms, partitions = SK.Building.subdivide(rect, Rng.new(seed), minRoom, { reserved = { span } })
		local _, again = SK.Building.subdivide(rect, Rng.new(seed), minRoom, { reserved = { span } })
		t.eq(#again, #partitions, "deterministic")
		t.ok(#rooms == #partitions + 1, "BSP: one more room than partitions")
		for _, p in partitions do
			if p.from[1] == p.to[1] and math.abs(p.from[2] - rect.z) < 1e-9 then
				t.ok(
					p.from[1] <= doorAt - 3 - clearance + 1e-9 or p.from[1] >= doorAt + 3 + clearance - 1e-9,
					string.format("seed %d: cut x=%.2f ends in the front doorway", seed, p.from[1])
				)
			end
			local door = p.door
			t.ok(door ~= nil and door.width >= SK.Measure.GUIDE.doorMin.width, "every partition has a door")
			local along = if p.from[1] == p.to[1] then 2 else 1
			local across = 3 - along
			local d0 = p.from[along] + door.at - door.width / 2
			local d1 = p.from[along] + door.at + door.width / 2
			for _, q in partitions do
				for _, e in { q.from, q.to } do
					if q ~= p and math.abs(e[across] - p.from[across]) < 1e-9 then
						-- A wall meeting this partition (half thickness 0.25) must stay outside the door span.
						t.ok(
							e[along] + 0.25 <= d0 + 1e-9 or e[along] - 0.25 >= d1 - 1e-9,
							string.format(
								"seed %d: T-junction at %.2f inside door %.2f..%.2f",
								seed,
								e[along],
								d0,
								d1
							)
						)
					end
				end
			end
		end
	end
	-- Failure case: a doorway spanning the whole room leaves no legal cut, so the rect stays one room.
	local rect = { x = 0, z = 0, w = 30, d = 12 }
	local rooms, partitions =
		SK.Building.subdivide(rect, Rng.new(1), 10, { reserved = { { from = { 0, 0 }, to = { 30, 0 } } } })
	t.eq(#partitions, 0, "no cut may land in a full-width doorway")
	t.eq(#rooms, 1)
end)

test("buildings from the review repros leave every doorway fully clear", function(t)
	-- tests p8: 2-storey 32x24, 30x26, 40x30 (40x30 obstructed a partition door on every seed).
	for seed = 1, 12 do
		for _, fp in
			{
				{ x = 0, z = 0, w = 32, d = 24 },
				{ x = 0, z = 0, w = 30, d = 26 },
				{ x = 0, z = 0, w = 40, d = 30 },
			}
		do
			local scene = SK.Scene.new({ name = "B", seed = seed, style = "neutral-stone" })
			SK.Building.create(scene, { footprint = fp, storeys = 2 })
			local label = string.format("seed %d %gx%g", seed, fp.w, fp.d)
			t.ok(assertDoorsClear(t, scene, label) > 1, label .. " has front and partition doors")
			t.eq(#failedChecks(scene), 0, label .. " validation")
		end
	end
	-- p8b/p8c: the settlement fixture's houses (seed 202), built exactly as build_fixtures does.
	local layout = Settlement.generate({ seed = 202, streets = 3, length = 220 })
	local scene = SK.Scene.new({ name = "SETUP_ONLY_Settlement", seed = 202, style = "neutral-timber" })
	for index, lot in layout.lots do
		local fp = lot.footprint
		local turned = lot.facing == 90 or lot.facing == 270
		local w, d = if turned then fp.d else fp.w, if turned then fp.w else fp.d
		scene:transformed({ x = fp.x + fp.w / 2, y = 0, z = fp.z + fp.d / 2 }, lot.facing, function()
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
	t.ok(assertDoorsClear(t, scene, "settlement 202") > #layout.lots, "settlement doors measured")
	t.eq(#failedChecks(scene), 0, "settlement validation")
end)

-- Railings vs stair steps, measured part by part.
local function railingStairOverlaps(scene): { string }
	local hits = {}
	for _, a in scene.specs do
		if a.role == "trim" then
			for _, b in scene.specs do
				if b.role == "stair" and overlap(a, b) > 0 then
					table.insert(hits, a.id .. " x " .. b.id)
				end
			end
		end
	end
	return hits
end

test("stair-hole railings never cut the next flight (3+ storeys)", function(t)
	local configs = {
		{ name = "Townhouse", footprint = { x = -16, z = -12, w = 32, d = 24 }, storeys = 3, seed = 101 },
		{ name = "B", footprint = { x = 0, z = 0, w = 30, d = 26 }, storeys = 3, seed = 3 },
		{ name = "B", footprint = { x = 0, z = 0, w = 32, d = 24 }, storeys = 4, seed = 4 },
		{ name = "B", footprint = { x = 0, z = 0, w = 40, d = 30 }, storeys = 5, seed = 5 },
	}
	for _, c in configs do
		local scene = SK.Scene.new({ name = "S", seed = c.seed, style = "neutral-stone" })
		SK.Building.create(scene, { name = c.name, footprint = c.footprint, storeys = c.storeys })
		local label = string.format("%gx%g x%d", c.footprint.w, c.footprint.d, c.storeys)
		local railings = 0
		for _, spec in scene.specs do
			if spec.role == "trim" and spec.size.y == SK.Measure.GUIDE.railingHeight then
				railings += 1
			end
		end
		t.ok(railings > 0, label .. " has railings")
		local hits = railingStairOverlaps(scene)
		t.eq(
			#hits,
			0,
			label .. " railing/stair overlaps: " .. table.concat(hits, ", ", 1, math.min(#hits, 3))
		)
		t.eq(#failedChecks(scene), 0, label .. " validation")
		for _, stair in scene.meta.stairs do
			t.ok(stair.width >= SK.Measure.GUIDE.doorMin.width, label .. " flight stays wide enough")
		end
	end
	-- Failure case: a railing dropped across a flight is caught by the measurement and Validate.
	local bad = SK.Scene.new({ name = "Bad" })
	SK.Building.stairs(bad, { base = { x = 0, y = 0, z = 0 }, rise = 6, width = 4.8 })
	SK.Building.railing(bad, { from = { x = 0, y = 3, z = 2.2 }, to = { x = 9, y = 3, z = 2.2 } })
	t.ok(#railingStairOverlaps(bad) > 0, "measurement sees the clipped railing")
	t.ok(table.find(failedChecks(bad), "stair_obstruction"), "Validate fails a railing through a flight")
end)

test("modular_building fixture ramp is clear and walkable", function(t)
	local outDir = "build/spec-fixtures"
	local run = process.exec("lune", { "run", "tools/lune/build_fixtures.luau", outDir, "modular_building" })
	t.ok(run.ok, "build_fixtures modular_building: " .. run.stdout .. run.stderr)
	local manifest = serde.decode("json", fs.readFile(outDir .. "/modular_building.manifest.json"))
	local report = serde.decode("json", fs.readFile(outDir .. "/report.json"))
	t.ok(report.fixtures.modular_building.pass, "fixture validation")
	local function spec(part)
		return {
			id = part.id,
			role = part.role,
			size = { x = part.size[1], y = part.size[2], z = part.size[3] },
			pos = { x = part.pos[1], y = part.pos[2], z = part.pos[3] },
			rot = { x = part.rot[1], y = part.rot[2], z = part.rot[3] },
		}
	end
	local ramp, foundation = nil, nil
	for _, part in manifest.parts do
		if part.role == "stair" and part.shape == "Wedge" then
			ramp = spec(part)
		elseif part.id == "Annex/foundation#1" then
			foundation = spec(part)
		end
	end
	t.ok(ramp and foundation, "ramp and Annex foundation present")
	for _, part in manifest.parts do
		if part.id ~= ramp.id then
			t.eq(overlap(ramp, spec(part)), 0, "ramp overlaps " .. part.id)
		end
	end
	-- Wedge high side is local +Z: the high edge must meet the foundation top at its front face.
	local high =
		SK.Vec.add(ramp.pos, SK.Vec.rotate({ x = 0, y = ramp.size.y / 2, z = ramp.size.z / 2 }, ramp.rot))
	local low =
		SK.Vec.add(ramp.pos, SK.Vec.rotate({ x = 0, y = -ramp.size.y / 2, z = -ramp.size.z / 2 }, ramp.rot))
	local fmin, fmax = SK.Scene.specBounds(foundation)
	t.near(high.y, fmax.y, 1e-6, "high edge at the sill")
	t.near(high.z, fmin.z, 1e-6, "high edge on the foundation's front face")
	t.ok(high.x > fmin.x and high.x < fmax.x, "ramp lands on the Annex foundation")
	t.near(low.y, 0, 1e-6, "low edge on the ground")
	t.ok(SK.Measure.slope(ramp.size.y, ramp.size.z) < 15, "gentle slope")
	local door = nil
	for _, record in manifest.meta.doors do
		if record.group == "Annex/Storey1" and record.kind == "door" then
			door = record
		end
	end
	t.ok(door and math.abs(door.pos.x - ramp.pos.x) < 1e-6, "ramp is centred on the Annex door")

	-- Failure case: the old placement (base x=44, yaw 180) sits inside the foundation and fails.
	local old = SK.Scene.new({ name = "OldRamp", seed = 101, style = "neutral-stone" })
	SK.Building.create(old, {
		name = "Annex",
		footprint = { x = 24, z = -10, w = 20, d = 20 },
		storeys = 1,
		roof = { style = "flat" },
		stairs = false,
	})
	SK.Building.ramp(old, { base = { x = 44, y = 0, z = 0 }, yaw = 180, rise = 1, run = 6 })
	t.ok(table.find(failedChecks(old), "stair_obstruction"), "a ramp buried in a foundation must fail")
end)

return cases
