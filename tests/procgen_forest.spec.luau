-- Forest / biome dressing: determinism, every validator on the fixture seed and across a seed
-- sweep, the SceneKit conversion (exact part estimate, scene checks), and broken inputs that must
-- fail the right validator: a trunk on the path, an unreachable clearing, an over-dense band, a
-- crowded or blocked spawn, crowded trunks, a cluttered clearing, a narrow path, a clearing
-- shortfall and a part budget.
local Forest = require("../packages/ProcGen/Forest")
local ForestScene = require("../packages/ProcGen/ForestScene")
local Manifest = require("../packages/ProcGen/Manifest")
local SK = require("../packages/SceneKit/SceneKit")
local Validate = require("../packages/ProcGen/Validate")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

-- Same parameters as the `forest` fixture in tools/lune/build_fixtures.luau.
local FIXTURE = { seed = 606, width = 256, depth = 192, clearings = 4 }
local CHECKS = {
	"player_scale_corridor",
	"path_clearance",
	"clearing_reachability",
	"spawn_clear",
	"band_density",
	"min_trunk_spacing",
	"obstacle_gap",
	"clearing_space",
	"clearings_placed",
	"performance_part_estimate",
}

local function generate(overrides: { [string]: any }?)
	local params = table.clone(FIXTURE)
	for key, value in overrides or {} do
		params[key] = value
	end
	return Forest.generate(params :: any)
end

local function find(checks, name)
	for _, c in checks do
		if c.name == name then
			return c
		end
	end
	error("no check named " .. name)
end

local function failed(checks): { string }
	local out = {}
	for _, c in checks do
		if not c.pass then
			table.insert(out, c.name)
		end
	end
	return out
end

local function sceneOf(layout)
	local scene =
		SK.Scene.new({ name = "SETUP_ONLY_Forest", seed = layout.params.seed, style = "neutral-timber" })
	ForestScene.toScene(scene, layout)
	return scene
end

local function clearing(layout, id: string)
	for _, c in layout.clearings do
		if c.id == id then
			return c
		end
	end
	error("no clearing " .. id)
end

test("forest layout and scene are reproducible from the seed", function(t)
	local a, b, c = generate(), generate(), generate({ seed = 607 })
	t.eq(Manifest.fromLayout(a).hash, Manifest.fromLayout(b).hash, "same seed, same layout hash")
	t.ok(Manifest.fromLayout(a).hash ~= Manifest.fromLayout(c).hash, "different seed, different layout hash")
	local sa, sb, sc = sceneOf(a):manifest(), sceneOf(b):manifest(), sceneOf(c):manifest()
	t.eq(Manifest.hash(sa.parts), Manifest.hash(sb.parts), "same seed, same scene hash")
	t.ok(Manifest.hash(sa.parts) ~= Manifest.hash(sc.parts), "different seed, different scene hash")
	local manifest = Manifest.fromLayout(a)
	for _, key in { "bands", "clearings", "paths", "vegetation", "entry", "exit", "graph" } do
		t.ok(manifest[key] ~= nil, "manifest records " .. key)
	end
end)

test("fixture forest passes every validator", function(t)
	local checks = Validate.forest(generate())
	t.eq(#checks, #CHECKS, "validator count")
	for _, name in CHECKS do
		local c = find(checks, name)
		t.ok(c.pass, string.format("%s failed: %s %s", name, tostring(c.value), tostring(c.detail)))
	end
	local density = find(checks, "band_density").detail
	t.ok(not string.find(density, "unchecked"), "all four bands judged: " .. density)
end)

test("forest scene matches its part estimate and passes SceneKit checks", function(t)
	local layout = generate()
	local scene = sceneOf(layout)
	t.eq(#scene.specs, Forest.partEstimate(layout), "estimate equals emitted parts")
	for _, c in SK.Validate.scene(scene) do
		t.ok(c.pass, "SceneKit " .. c.name)
	end
	local trees, markers = 0, 0
	for _, item in layout.vegetation do
		trees += if item.kind == "tree" then 1 else 0
	end
	for _, spec in scene.specs do
		markers += if string.find(spec.id, "/Markers/", 1, true) then 1 else 0
	end
	t.eq(scene:counts().trunk, trees, "one trunk per tree")
	t.eq(markers, #layout.clearings + 2, "a marker per clearing plus spawn and goal")
end)

test("forests validate across seeds and sizes", function(t)
	for _, size in { { 256, 192, 4 }, { 384, 256, 6 }, { 160, 128, 2 } } do
		for seed = 1, 10 do
			local layout =
				Forest.generate({ seed = seed, width = size[1], depth = size[2], clearings = size[3] })
			local checks = Validate.forest(layout)
			t.eq(
				failed(checks),
				{},
				string.format("seed %d %dx%d: %s", seed, size[1], size[2], table.concat(failed(checks), ","))
			)
		end
	end
end)

test("bands are noise quantiles that tile the area", function(t)
	local layout = generate()
	local bands = layout.bands
	local cells, letters = bands.cols * bands.rows, {}
	for _, row in bands.map do
		for index = 1, #row do
			local letter = string.sub(row, index, index)
			letters[letter] = (letters[letter] or 0) + 1
		end
	end
	for _, name in Forest.BAND_ORDER do
		local expected = Forest.SHARES[name] * cells
		t.ok(math.abs((letters[string.sub(name, 1, 1)] or 0) - expected) <= 1, name .. " share")
	end
	local area = 0
	for _, tile in bands.tiles do
		area += tile.w * tile.d
		t.eq(Forest.bandAt(layout, tile.x + 0.5, tile.z + 0.5), tile.band, "tile band")
	end
	t.eq(area, layout.params.width * layout.params.depth, "tiles cover the area once")
end)

test("path network joins entry, clearings and exit with purposeful roles", function(t)
	local layout = generate()
	t.eq(#layout.graph:components(), 1, "one network")
	local route = {}
	for _, id in layout.graph:shortestPath("entry", "exit") do
		route[id] = true
	end
	local landmarks = 0
	for _, c in layout.clearings do
		t.ok(layout.graph.nodes[c.id] ~= nil, c.id .. " on the network")
		if c.role == "landmark" then
			landmarks += 1
		else
			t.eq(c.role, if route[c.id] then "encounter" else "treasure", c.id .. " role")
		end
	end
	t.eq(landmarks, layout.params.landmarks)
	local ascii = Forest.toAscii(layout)
	t.ok(string.find(ascii, "E", 1, true) and string.find(ascii, "X", 1, true), "ascii shows entry and exit")
	t.eq(#string.split(ascii, "\n"), layout.params.depth / 4, "ascii rows")
end)

test("a trunk on the path fails path_clearance", function(t)
	local layout = generate()
	-- Midpoint of the longest network segment.
	local best, mid = -1, { 0, 0 }
	for _, path in layout.paths do
		for index = 1, #path.points - 1 do
			local a, b = path.points[index], path.points[index + 1]
			local length = math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
			if length > best then
				best, mid = length, { (a[1] + b[1]) / 2, (a[2] + b[2]) / 2 }
			end
		end
	end
	table.insert(layout.vegetation, {
		id = "tree_on_path",
		kind = "tree",
		band = Forest.bandAt(layout, mid[1], mid[2]),
		x = mid[1],
		z = mid[2],
		scale = 1,
		r = Forest.TRUNK_RADIUS,
	})
	local checks = Validate.forest(layout)
	local c = find(checks, "path_clearance")
	t.ok(not c.pass, "path_clearance must fail")
	t.ok(string.find(c.detail, "tree_on_path", 1, true) ~= nil, c.detail)
	-- One trunk narrows an 8-stud path but does not cut it.
	t.ok(find(checks, "clearing_reachability").pass, "path still walkable around one trunk")
end)

test("a clearing without a path fails clearing_reachability", function(t)
	local layout = generate()
	-- A spur clearing (one path) so only it is cut off; the layout graph still lists the edge.
	local spur
	for _, c in layout.clearings do
		if spur == nil and layout.graph:degree(c.id) == 1 then
			spur = c.id
		end
	end
	t.ok(spur ~= nil, "fixture has a spur clearing")
	local kept = {}
	for _, path in layout.paths do
		if path.from ~= spur and path.to ~= spur then
			table.insert(kept, path)
		end
	end
	layout.paths = kept
	local checks = Validate.forest(layout)
	t.eq(failed(checks), { "clearing_reachability" })
	t.ok(string.find(find(checks, "clearing_reachability").detail, spur, 1, true) ~= nil, "names " .. spur)
end)

test("an over-dense band fails band_density", function(t)
	-- Dense band: trunks only, every slot filled, at exactly the minimum legal trunk spacing.
	local packed = { spacing = 6, fill = 1, tree = 1, bush = 0, rock = 0 }
	local checks = Validate.forest(generate({ bands = { dense = packed } }))
	t.eq(failed(checks), { "band_density" })
	local detail = find(checks, "band_density").detail
	t.ok(string.find(detail, "dense [%d%.]+ %[6%-12%] over %d+ OUT") ~= nil, detail)
	t.ok(find(checks, "min_trunk_spacing").pass, "spacing itself is legal")
	-- The same planting in the open band breaks the open band's bound, not the dense one's.
	local open = Validate.forest(generate({ bands = { open = packed } }))
	t.eq(failed(open), { "band_density" })
	detail = find(open, "band_density").detail
	t.ok(string.find(detail, "open [%d%.]+ %[0%-2%] over %d+ OUT") ~= nil, detail)
	t.ok(string.find(detail, "dense [%d%.]+ %[6%-12%] over %d+;") ~= nil, detail)
end)

test("crowding the spawn fails spawn_clear", function(t)
	local layout = generate()
	-- A rock 4 studs north of the spawn, on the side away from the lead-in path.
	table.insert(layout.vegetation, {
		id = "rock_by_spawn",
		kind = "rock",
		band = "open",
		x = layout.entry.x,
		z = layout.entry.z - 7,
		size = { 3, 2, 3 },
		yaw = 0,
		r = 2.13,
	})
	local c = find(Validate.forest(layout), "spawn_clear")
	t.ok(not c.pass and string.find(c.detail, "rock_by_spawn", 1, true) ~= nil, tostring(c.detail))
	-- A rock on the spawn itself also blocks the walk from the spawn.
	local blocked = generate()
	table.insert(blocked.vegetation, {
		id = "rock_on_spawn",
		kind = "rock",
		band = "open",
		x = blocked.entry.x,
		z = blocked.entry.z,
		size = { 3, 2, 3 },
		yaw = 0,
		r = 2.13,
	})
	local checks = Validate.forest(blocked)
	t.eq(find(checks, "spawn_clear").detail, "spawn cell blocked or off the path")
	t.ok(not find(checks, "clearing_reachability").pass, "nothing reachable from a blocked spawn")
end)

test("crowded trunks fail min_trunk_spacing and obstacle_gap", function(t)
	local layout = generate()
	-- The tree farthest from every path gets a twin 4 studs away.
	local far, farDistance = nil, -1
	for _, item in layout.vegetation do
		local d = Forest.pathDistance(layout.paths, item.x, item.z)
		if item.kind == "tree" and d > farDistance and item.x > 8 then
			far, farDistance = item, d
		end
	end
	assert(far, "fixture has trees")
	table.insert(layout.vegetation, {
		id = "twin",
		kind = "tree",
		band = far.band,
		x = far.x - 4,
		z = far.z,
		scale = 1,
		r = Forest.TRUNK_RADIUS,
	})
	local checks = Validate.forest(layout)
	local spacing = find(checks, "min_trunk_spacing")
	t.ok(not spacing.pass and spacing.value == 4, "spacing " .. tostring(spacing.value))
	t.ok(not find(checks, "obstacle_gap").pass, "gap under a character width")
end)

test("a trunk inside a clearing fails clearing_space", function(t)
	local layout = generate()
	local c = clearing(layout, "C1")
	table.insert(layout.vegetation, {
		id = "tree_in_clearing",
		kind = "tree",
		band = Forest.bandAt(layout, c.x, c.z),
		x = c.x,
		z = c.z + c.radius - 3,
		scale = 1,
		r = Forest.TRUNK_RADIUS,
	})
	local check = find(Validate.forest(layout), "clearing_space")
	t.ok(not check.pass and string.find(check.detail, "C1", 1, true) ~= nil, tostring(check.detail))
end)

test("a narrow path, a clearing shortfall and a small budget fail their checks", function(t)
	t.eq(failed(Validate.forest(generate({ pathWidth = 4 }))), { "player_scale_corridor" })
	local cramped = generate({ width = 128, depth = 96, clearings = 6 })
	t.ok(#cramped.clearings < 6, "area too small for six clearings")
	t.ok(not find(Validate.forest(cramped), "clearings_placed").pass, "shortfall fails clearings_placed")
	local layout = generate()
	local budget = Forest.partEstimate(layout) - 1
	t.eq(failed(Validate.forest(layout, { maxParts = budget })), { "performance_part_estimate" })
end)

return cases
