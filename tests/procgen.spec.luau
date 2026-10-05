local Arena = require("../packages/ProcGen/Arena")
local Cave = require("../packages/ProcGen/Cave")
local Dungeon = require("../packages/ProcGen/Dungeon")
local Graph = require("../packages/ProcGen/Graph")
local Grid = require("../packages/ProcGen/Grid")
local Manifest = require("../packages/ProcGen/Manifest")
local Noise = require("../packages/ProcGen/Noise")
local Placement = require("../packages/ProcGen/Placement")
local Rng = require("../packages/ProcGen/Rng")
local Settlement = require("../packages/ProcGen/Settlement")
local Validate = require("../packages/ProcGen/Validate")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

local function failedNames(checks)
	local out = {}
	for _, c in checks do
		if not c.pass then
			table.insert(out, c.name)
		end
	end
	return table.concat(out, ",")
end

test("rng is deterministic and seed-sensitive", function(t)
	local a, b, c = Rng.new(42), Rng.new(42), Rng.new(43)
	local sa, sb, sc = {}, {}, {}
	for i = 1, 50 do
		sa[i], sb[i], sc[i] = a:nextUInt(), b:nextUInt(), c:nextUInt()
	end
	t.eq(sa, sb, "same seed")
	t.ok(sa[1] ~= sc[1] or sa[2] ~= sc[2], "different seed differs")
	t.eq(Rng.new("x"):fork("child"):nextUInt(), Rng.new("x"):fork("child"):nextUInt(), "fork stable")
	t.ok(Rng.new("x"):fork("a"):nextUInt() ~= Rng.new("x"):fork("b"):nextUInt(), "forks independent")
end)

test("rng ranges stay in bounds and cover them", function(t)
	local r = Rng.new(7)
	local seen = {}
	for _ = 1, 2000 do
		local v = r:int(1, 6)
		t.ok(v >= 1 and v <= 6)
		seen[v] = true
		local f = r:next()
		t.ok(f >= 0 and f < 1)
	end
	for v = 1, 6 do
		t.ok(seen[v], "value " .. v .. " reachable")
	end
end)

test("fnv1a matches reference vectors", function(t)
	t.eq(Rng.hash(""), 2166136261)
	t.eq(Rng.hash("a"), 0xe40c292c)
	t.eq(Rng.hash("foobar"), 0xbf9cf968)
end)

test("noise is deterministic and bounded", function(t)
	for i = 1, 200 do
		local v = Noise.fbm("seed", i * 0.37, i * 0.11)
		t.ok(v >= 0 and v < 1)
		t.eq(v, Noise.fbm("seed", i * 0.37, i * 0.11))
	end
end)

test("graph analysis: bridges, dead ends, cycle rank", function(t)
	local g = Graph.new()
	for _, id in { "a", "b", "c", "d", "e" } do
		g:addNode(id)
	end
	g:addEdge("a", "b")
	g:addEdge("b", "c")
	g:addEdge("c", "a") -- loop a-b-c
	g:addEdge("c", "d") -- bridge
	g:addEdge("d", "e") -- bridge, e is a dead end
	t.eq(g:cycleRank(), 1)
	t.eq(g:bridges(), { { "c", "d" }, { "d", "e" } })
	t.eq(g:deadEnds(), { "e" })
	t.eq(g:shortestPath("a", "e"), { "a", "c", "d", "e" })
	t.eq(#g:components(), 1)
end)

test("grid regions, walk distance and clear width", function(t)
	local grid = Grid.new(10, 5, 4, 0)
	grid:fillRect(2, 2, 3, 3, 1)
	grid:fillRect(7, 2, 2, 2, 1)
	t.eq(#grid:regions(), 2)
	t.eq(grid:walkDistance({ 2, 2 }, { 4, 4 }), 4)
	t.eq(grid:walkDistance({ 2, 2 }, { 7, 2 }), nil)
	t.eq(grid:clearWidth(3, 3), 3)
end)

test("dungeon is reproducible from its seed", function(t)
	local a = Manifest.fromLayout(Dungeon.generate({ seed = "repro" }))
	local b = Manifest.fromLayout(Dungeon.generate({ seed = "repro" }))
	local c = Manifest.fromLayout(Dungeon.generate({ seed = "other" }))
	t.eq(a.hash, b.hash)
	t.ok(a.hash ~= c.hash)
end)

test("dungeons validate across 25 seeds", function(t)
	for seed = 1, 25 do
		local layout = Dungeon.generate({ seed = seed })
		local placement = Placement.assign(layout, { encounters = 2, landmarks = 1 })
		local checks = Validate.rooms(layout, placement)
		-- Every validator, encounter_space included: Placement only picks rooms that fit.
		for _, c in checks do
			t.ok(c.pass, string.format("seed %d failed %s (%s)", seed, c.name, failedNames(checks)))
		end
		t.eq(placement.roles[placement.spawn], "spawn")
		t.eq(placement.roles[placement.goal], "goal")
	end
end)

test("placement gives every dead end a purpose", function(t)
	local layout = Dungeon.generate({ seed = 9, loopChance = 0, minLoops = 0 })
	local placement = Placement.assign(layout, { encounters = 2 })
	for _, id in layout.graph:deadEnds() do
		t.ok(placement.roles[id] ~= "connector", id .. " is purposeless")
	end
end)

test("arena is fair and player-scale across 20 seeds", function(t)
	for seed = 1, 20 do
		local checks = Validate.arena(Arena.generate({ seed = seed }))
		for _, c in checks do
			t.ok(c.pass, string.format("seed %d: %s", seed, failedNames(checks)))
		end
	end
end)

test("caves are one connected player-scale region", function(t)
	for seed = 1, 10 do
		local cave = Cave.generate({ seed = seed, width = 48, height = 36 })
		local checks = Validate.grid(cave.grid)
		for _, c in checks do
			t.ok(c.pass, string.format("seed %d: %s", seed, failedNames(checks)))
		end
	end
end)

test("settlements have no overlapping footprints", function(t)
	for seed = 1, 10 do
		local checks = Validate.settlement(Settlement.generate({ seed = seed }))
		for _, c in checks do
			t.ok(c.pass, string.format("seed %d: %s", seed, failedNames(checks)))
		end
	end
end)

test("line of sight respects solid cells", function(t)
	local grid = Grid.new(10, 3, 4, 1)
	t.ok(Validate.lineOfSight(grid, { 1, 2 }, { 10, 2 }))
	grid:set(5, 2, 0)
	t.ok(not Validate.lineOfSight(grid, { 1, 2 }, { 10, 2 }))
end)

test("manifest encoding is canonical", function(t)
	t.eq(Manifest.encode({ b = 1, a = { 1, 2, "x" }, c = true }), '{"a":[1,2,"x"],"b":1,"c":true}')
	t.eq(Manifest.encode({ q = 'say "hi"' }), '{"q":"say \\u0022hi\\u0022"}')
end)

return cases
