-- Level dressing: light and sign specs (Props.light/Props.sign -> Apply -> Light / SurfaceGui
-- instances), their Validate checks (light_placement, sign_text), Building.decorate (one light per
-- room, neutral props against walls, doorways clear, nothing sunk into walls, seeded), and the
-- oriented-box prop_clipping check decorate relies on at non-axis yaw.
local roblox = require("@lune/roblox")
local SK = require("../packages/SceneKit/SceneKit")
local Manifest = require("../packages/ProcGen/Manifest")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

local STRUCTURE =
	{ wall = true, floor = true, roof = true, stair = true, foundation = true, trim = true, glass = true }
local DECOR = { prop = true, fixture = true, sign = true }

local function checkNamed(scene, name: string)
	for _, c in SK.Validate.scene(scene) do
		if c.name == name then
			return c
		end
	end
	return nil
end

local function room(id: string, x: number, z: number, w: number, d: number)
	return { id = id, rect = { x = x, z = z, w = w, d = d }, floorY = 0, clearHeight = 10 }
end

local function decorated(seed: number, options: any?, yaw: number?, size: { number }?)
	local scene = SK.Scene.new({ name = "Dressed", seed = seed, style = "neutral-stone" })
	local building, result
	local w, d, storeys = 30, 24, 2
	if size then
		w, d, storeys = size[1], size[2], size[3]
	end
	scene:transformed({ x = 0, y = 0, z = 0 }, yaw or 0, function()
		building = SK.Building.create(scene, {
			name = "House",
			footprint = { x = -w / 2, z = -d / 2, w = w, d = d },
			storeys = storeys,
		})
		result = SK.Building.decorate(scene, building, options)
	end)
	return scene, building, result
end

-- Corners of a spec's footprint (oriented), for door and window tests.
local function footprint(spec)
	local out = {}
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			table.insert(
				out,
				SK.Vec.add(
					spec.pos,
					SK.Vec.rotate({ x = sx * spec.size.x / 2, y = 0, z = sz * spec.size.z / 2 }, spec.rot)
				)
			)
		end
	end
	return out
end

-- Shared assertions for a decorated building: valid, every room lit once, no decor sunk into
-- structure or into other decor, every doorway's clear width intact and its approach free.
local function assertDressed(t, scene, label: string)
	local summary = SK.Validate.summary(SK.Validate.scene(scene))
	t.ok(summary.pass, label .. ": " .. table.concat(summary.failed, ","))
	t.ok(checkNamed(scene, "light_placement"), label .. ": light_placement ran")

	local lit = {}
	for _, record in (scene.meta :: any).lights do
		lit[record.room] = (lit[record.room] or 0) + 1
	end
	for _, r in scene.meta.rooms do
		t.eq(lit[r.id], 1, label .. ": lights in " .. r.id)
	end

	local decor, structure = {}, {}
	for _, spec in scene.specs do
		if DECOR[spec.role] then
			table.insert(decor, spec)
		elseif STRUCTURE[spec.role] then
			table.insert(structure, spec)
		end
	end
	local props = 0
	for i, a in decor do
		props += if a.role == "prop" then 1 else 0
		for _, s in structure do
			local depth = SK.Validate.penetration(a, s)
			t.ok(depth < 1e-3, string.format("%s: %s sunk %.4f into %s", label, a.id, depth, s.id))
		end
		for j = i + 1, #decor do
			local depth = SK.Validate.penetration(a, decor[j])
			t.ok(depth < 1e-3, string.format("%s: %s overlaps %s", label, a.id, decor[j].id))
		end
	end
	t.ok(props > 0, label .. ": some props placed")

	for _, door in scene.meta.doors do
		if door.kind == "door" then
			t.near(
				SK.Validate.doorClearWidth(door, scene.specs),
				door.width,
				1e-6,
				label .. " clear width " .. door.group
			)
			local nx, nz = -door.dir.z, door.dir.x
			for _, a in decor do
				if a.role == "prop" then
					local u0, u1, n0, n1 = math.huge, -math.huge, math.huge, -math.huge
					for _, c in footprint(a) do
						local dx, dz = c.x - door.pos.x, c.z - door.pos.z
						local u, n = dx * door.dir.x + dz * door.dir.z, dx * nx + dz * nz
						u0, u1 = math.min(u0, u), math.max(u1, u)
						n0, n1 = math.min(n0, n), math.max(n1, n)
					end
					local inPassage = u0 < door.width / 2
						and u1 > -door.width / 2
						and n0 < 3.5
						and n1 > -3.5
						and a.pos.y - a.size.y / 2 < door.pos.y + door.height
						and a.pos.y + a.size.y / 2 > door.pos.y
					t.ok(not inPassage, label .. ": " .. a.id .. " stands in front of " .. door.group)
				end
			end
		end
	end
	return decor
end

-- For a building decorated at yaw 0: props taller than a window's sill never stand across it,
-- and nothing stands within 3.5 studs of a room's open side (the stair hall approach).
local function assertOpeningsClear(t, building, decor, label: string): (number, number)
	local tallNearWindows, openSides = 0, 0
	for _, floor in building.floors do
		local onFloor = {}
		for _, spec in decor do
			if spec.role == "prop" and math.abs(spec.pos.y - spec.size.y / 2 - floor.base) < 0.05 then
				table.insert(onFloor, spec)
			end
		end
		for _, span in floor.openings do
			if span.kind == "window" then
				for _, spec in onFloor do
					if spec.size.y > span.bottom then
						tallNearWindows += 1
						for _, c in footprint(spec) do
							local along = if span.axis == "z" then c.x else c.z
							local across = math.abs((if span.axis == "z" then c.z else c.x) - span.line)
							t.ok(
								not (along > span.lo and along < span.hi and across < 0.5),
								label .. ": " .. spec.id .. " blocks a window"
							)
						end
					end
				end
			end
		end
		for _, r in floor.rooms do
			local rect = r.rect
			for _, edge in
				{
					{ "z", rect.z, 1, rect.x, rect.x + rect.w },
					{ "z", rect.z + rect.d, -1, rect.x, rect.x + rect.w },
					{ "x", rect.x, 1, rect.z, rect.z + rect.d },
					{ "x", rect.x + rect.w, -1, rect.z, rect.z + rect.d },
				}
			do
				local axis, line, inward, lo, hi = edge[1], edge[2], edge[3], edge[4], edge[5]
				local walled = false
				for _, wall in floor.walls do
					if
						wall.axis == axis
						and math.abs(wall.line - line) < 1e-6
						and wall.lo <= lo + 1e-6
						and wall.hi >= hi - 1e-6
					then
						walled = true
					end
				end
				if not walled then
					openSides += 1
					for _, spec in onFloor do
						for _, c in footprint(spec) do
							local along = if axis == "z" then c.x else c.z
							local into = ((if axis == "z" then c.z else c.x) - line) * inward
							t.ok(
								not (along > lo and along < hi and into > -1e-6 and into < 3.5),
								label .. ": " .. spec.id .. " blocks the open side of " .. r.id
							)
						end
					end
				end
			end
		end
	end
	return tallNearWindows, openSides
end

test("light and sign specs become Light and SurfaceGui instances and enter the manifest", function(t)
	local scene = SK.Scene.new({ name = "Lit", seed = 1 })
	scene:box("floor", { x = 0, y = -1, z = 0 }, { x = 12, y = 0, z = 12 })
	scene:box("wall", { x = 0, y = 0, z = 12 }, { x = 12, y = 10, z = 13 })
	local r = room("Lit/R1", 0, 0, 12, 12)
	local ceiling =
		SK.Props.light(scene, { pos = { x = 6, y = 10, z = 6 }, room = r, range = 20, brightness = 2 })
	local wall = SK.Props.light(scene, {
		mount = "wall",
		pos = { x = 6, y = 8, z = 12 },
		normal = { x = 0, y = 0, z = -1 },
		room = r,
		class = "SpotLight",
		angle = 120,
	})
	local sign = SK.Props.sign(scene, { pos = { x = 6, y = 5, z = 12 }, normal = { x = 0, y = 0, z = -1 } })
	t.near(ceiling.pos.y, 10 - 0.15, 1e-9, "ceiling fixture hangs under the ceiling")
	t.near(wall.pos.z, 12 - 0.2, 1e-9, "wall fixture sits on the wall face")
	t.eq(sign.sign.text, "SIGN_A", "neutral placeholder text by default")

	local ws = roblox.Instance.new("DataModel"):GetService("Workspace")
	local _, model = SK.Apply.scene(scene, ws, { env = roblox })
	local byId = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			byId[d:GetAttribute("SceneKitId")] = d
		end
	end
	local point = byId[ceiling.id]:FindFirstChildWhichIsA("PointLight")
	t.ok(point, "PointLight under the ceiling fixture")
	t.eq(point.Range, 20)
	t.eq(point.Brightness, 2)
	local spot = byId[wall.id]:FindFirstChildWhichIsA("SpotLight")
	t.ok(spot, "SpotLight under the wall fixture")
	t.eq(spot.Face.Name, "Front")
	t.eq(spot.Angle, 120)
	t.ok(not byId[wall.id].CanCollide, "fixtures do not collide")
	local gui = byId[sign.id]:FindFirstChildWhichIsA("SurfaceGui")
	t.ok(gui, "SurfaceGui on the sign")
	t.eq(gui.Face.Name, "Front")
	t.eq(gui:FindFirstChildWhichIsA("TextLabel").Text, "SIGN_A")

	-- Manifest carries them, so hashes and diffs see a light change.
	local manifest = scene:manifest()
	local before = Manifest.hash(manifest.parts)
	t.eq(manifest.parts[3].light.class, "PointLight")
	ceiling.light.range = 30
	local after = scene:manifest()
	t.ok(Manifest.hash(after.parts) ~= before, "light range changes the hash")
	t.eq(SK.Scene.compare(manifest, after).changed, { ceiling.id })
	t.throws(function()
		SK.Props.light(scene, { mount = "wall", pos = { x = 0, y = 0, z = 0 } })
	end, "wall mount without a normal")
	t.throws(function()
		SK.Apply.light(roblox, roblox.Instance.new("Part"), { class = "LaserLight" } :: any)
	end, "unknown light class")
end)

test("Validate: light outside its room, bad light settings and empty sign text fail", function(t)
	local function base()
		local scene = SK.Scene.new({ name = "V" })
		scene:box("floor", { x = 0, y = -1, z = 0 }, { x = 20, y = 0, z = 10 })
		return scene
	end
	local plain = base()
	t.eq(checkNamed(plain, "light_placement"), nil, "no lights: no check, reports unchanged")
	t.eq(checkNamed(plain, "sign_text"), nil, "no signs: no check")

	local good = base()
	SK.Props.light(good, { pos = { x = 5, y = 10, z = 5 }, room = room("V/R1", 0, 0, 10, 10) })
	SK.Props.sign(
		good,
		{ pos = { x = 15, y = 5, z = 10 }, normal = { x = 0, y = 0, z = -1 }, text = "SIGN_B" }
	)
	t.ok(checkNamed(good, "light_placement").pass)
	t.ok(checkNamed(good, "sign_text").pass)

	-- Fixture at x = 15 belongs to the room 0..10: outside.
	local outside = base()
	SK.Props.light(outside, { pos = { x = 15, y = 10, z = 5 }, room = room("V/R1", 0, 0, 10, 10) })
	local c = checkNamed(outside, "light_placement")
	t.ok(not c.pass and c.value == 1, "light outside its room fails")
	t.ok(string.find(c.detail, "outside V/R1", 1, true), c.detail)
	-- Ceiling fixture pushed through the ceiling (room clearHeight 10).
	local high = base()
	SK.Props.light(high, { pos = { x = 5, y = 10.5, z = 5 }, room = room("V/R1", 0, 0, 10, 10) })
	t.ok(not checkNamed(high, "light_placement").pass, "fixture above the ceiling fails")
	-- Range over the engine cap and an unknown class.
	local bright = base()
	SK.Props.light(bright, { pos = { x = 5, y = 10, z = 5 }, range = 120 })
	t.ok(not checkNamed(bright, "light_placement").pass, "range 120 fails")
	local unknown = base()
	local spec = SK.Props.light(unknown, { pos = { x = 5, y = 10, z = 5 } })
	spec.light.class = "LaserLight" :: any
	t.ok(not checkNamed(unknown, "light_placement").pass, "unknown class fails")

	for _, text in { "", "   " } do
		local blank = base()
		SK.Props.sign(
			blank,
			{ pos = { x = 5, y = 5, z = 10 }, normal = { x = 0, y = 0, z = -1 }, text = text }
		)
		local s = checkNamed(blank, "sign_text")
		t.ok(not s.pass and s.value == 1, "sign text '" .. text .. "' must fail")
	end
end)

test("Building.decorate: every room lit, props clear of walls and doorways, sign above the door", function(t)
	local scene, building, result = decorated(7, { lights = "mixed", sign = "SIGN_A" })
	t.eq(result.rooms, #scene.meta.rooms)
	t.eq(#result.lights, #scene.meta.rooms)
	t.eq(#result.signs, 1)
	local decor = assertDressed(t, scene, "seed 7")
	local mounts = {}
	for _, spec in decor do
		if spec.light then
			mounts[spec.light.class] = true
		end
	end
	t.ok(mounts.PointLight and mounts.SpotLight, "mixed mode uses ceiling and wall lights")

	assertOpeningsClear(t, building, decor, "seed 7")
	-- Props placed through both helpers, each tagged with its placeholder asset.
	local assets = {}
	for _, spec in decor do
		if spec.role == "prop" then
			assets[spec.attributes.asset] = true
		end
	end
	t.ok(next(assets) ~= nil, "props carry asset placeholders")
end)

test("Building.decorate: same seed same output, different seed different output", function(t)
	local function hash(seed: number, options: any?)
		local scene = decorated(seed, options)
		return Manifest.hash(scene:manifest().parts)
	end
	t.eq(hash(11, { lights = "mixed" }), hash(11, { lights = "mixed" }), "same seed")
	t.ok(hash(11, { lights = "mixed" }) ~= hash(12, { lights = "mixed" }), "different scene seed")
	t.ok(hash(11, { seed = 1 }) ~= hash(11, { seed = 2 }), "decorate seed option")
	-- The shell is untouched: decorating only appends specs.
	local bare = SK.Scene.new({ name = "Dressed", seed = 11, style = "neutral-stone" })
	SK.Building.create(
		bare,
		{ name = "House", footprint = { x = -15, z = -12, w = 30, d = 24 }, storeys = 2 }
	)
	local dressed = decorated(11)
	for index, spec in bare.specs do
		t.eq(dressed.specs[index].id, spec.id)
	end
end)

test("Building.decorate sweep: 16 seeds x 3 buildings x every light mode", function(t)
	local modes = { "ceiling", "wall", "mixed" }
	local placed, tall, openSides = 0, 0, 0
	for seed = 1, 16 do
		for index, size in { { 30, 24, 2 }, { 40, 30, 3 }, { 24, 20, 1 } } do
			local label = string.format("seed %d %dx%d", seed, size[1], size[2])
			local scene, building, result =
				decorated(seed, { lights = modes[(seed + index) % 3 + 1], sign = "SIGN_A" }, 0, size)
			local decor = assertDressed(t, scene, label)
			local windows, open = assertOpeningsClear(t, building, decor, label)
			placed += #result.props
			tall += windows
			openSides += open
		end
	end
	t.ok(placed > 300, "props placed across the sweep: " .. placed)
	t.ok(tall > 0, "tall props were checked against windows")
	t.ok(openSides > 0, "the sweep includes rooms open to a stair hall")
end)

test("Building.decorate inside Scene.transformed at yaw 30 still validates", function(t)
	for _, yaw in { 30, 90, 217 } do
		local scene = decorated(3, { lights = "wall", sign = "SIGN_A" }, yaw)
		assertDressed(t, scene, "yaw " .. yaw)
	end
end)

test("Building.decorate options and failure cases", function(t)
	local _, _, none = decorated(5, { lights = false, props = false })
	t.eq(#none.lights + #none.props + #none.signs, 0, "lights = false and props = false add nothing")
	local _, _, crates = decorated(5, { props = { { asset = "PropCrate", size = { x = 2, y = 2, z = 2 } } } })
	t.ok(#crates.props > 0)
	t.throws(function()
		SK.Building.decorate(SK.Scene.new({ name = "X" }), {})
	end, "needs a Building.create summary")
	-- A room too small for a prop records the miss instead of forcing it into a wall.
	local _, _, big = decorated(5, { props = { { asset = "PropWide", size = { x = 40, y = 2, z = 2 } } } })
	t.eq(#big.props, 0)
	t.ok(#big.skipped > 0, "oversized props are skipped")
end)

test("prop_clipping uses oriented boxes: a prop against a yawed wall passes, a sunk one fails", function(t)
	local function scene(sink: number)
		local s = SK.Scene.new({ name = "Yawed" })
		s:transformed({ x = 0, y = 0, z = 0 }, 30, function()
			s:box("floor", { x = -10, y = -1, z = -10 }, { x = 10, y = 0, z = 10 })
			s:box("wall", { x = -10, y = 0, z = 4 }, { x = 10, y = 10, z = 5 })
			SK.Props.alignToWall(
				s,
				{ asset = "PropCrate", size = { x = 2, y = 2, z = 2 } },
				{ x = 0, y = 0, z = 4 + sink },
				{ x = 0, y = 0, z = -1 },
				0
			)
		end)
		return s
	end
	t.ok(checkNamed(scene(0), "prop_clipping").pass, "touching prop at yaw 30 is not clipping")
	local sunk = checkNamed(scene(0.3), "prop_clipping")
	t.ok(not sunk.pass and sunk.value == 1, "prop sunk 0.3 into the wall fails")
end)

return cases
