-- Regression specs for reviewed ProcGen defects: loops must be walkable on the grid, arena
-- fairness must fail on unreachable spawns, the arena objective sits on the symmetry
-- centre, goal/encounter rooms fit an encounter, and caves always join into one region.
local Arena = require("../packages/ProcGen/Arena")
local Cave = require("../packages/ProcGen/Cave")
local Dungeon = require("../packages/ProcGen/Dungeon")
local Graph = require("../packages/ProcGen/Graph")
local Grid = require("../packages/ProcGen/Grid")
local Placement = require("../packages/ProcGen/Placement")
local Validate = require("../packages/ProcGen/Validate")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

local function find(checks, name)
	for _, c in checks do
		if c.name == name then
			return c
		end
	end
	error("no check named " .. name)
end

local NEIGHBOURS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- Independent of RoomGraph/Validate: flood-fill each corridor component (floor outside every
-- room), fill it solid, and see whether two rooms it touched still share a walkable region.
-- If they do, the map has a loop a player can walk around.
local function hasWalkableLoop(layout): boolean
	local grid = layout.grid
	local roomAt = {}
	for _, room in layout.rooms do
		for y = room.y, room.y + room.h - 1 do
			for x = room.x, room.x + room.w - 1 do
				roomAt[(y - 1) * grid.width + x] = room
			end
		end
	end
	local seen = {}
	for y = 1, grid.height do
		for x = 1, grid.width do
			local key = (y - 1) * grid.width + x
			if grid:get(x, y) ~= 0 and roomAt[key] == nil and not seen[key] then
				local cells, touched = {}, {}
				local stack = { { x, y } }
				seen[key] = true
				while #stack > 0 do
					local cell = table.remove(stack)
					table.insert(cells, cell)
					for _, o in NEIGHBOURS do
						local nx, ny = cell[1] + o[1], cell[2] + o[2]
						local nkey = (ny - 1) * grid.width + nx
						if grid:get(nx, ny) ~= 0 then
							local room = roomAt[nkey]
							if room then
								touched[room.id] = room
							elseif not seen[nkey] then
								seen[nkey] = true
								table.insert(stack, { nx, ny })
							end
						end
					end
				end
				local saved = table.clone(grid.cells)
				for _, cell in cells do
					grid:set(cell[1], cell[2], 0)
				end
				local regionOf = {}
				for index, region in grid:regions() do
					for _, cell in region do
						regionOf[(cell[2] - 1) * grid.width + cell[1]] = index
					end
				end
				grid.cells = saved
				local usedRegions = {}
				for _, room in touched do
					local region = regionOf[(room.cy - 1) * grid.width + room.cx]
					if usedRegions[region] then
						return true
					end
					usedRegions[region] = true
				end
			end
		end
	end
	return false
end

-- Three 6x6 rooms in a row joined by two corridors; the layout graph also claims an A-C
-- loop, which on this grid could only run along the same cells through B.
local function rowOfRooms()
	local grid = Grid.new(30, 10, 4, 0)
	local rooms = {}
	for index, id in { "A", "B", "C" } do
		local x = 2 + (index - 1) * 10
		grid:fillRect(x, 2, 6, 6, 1)
		table.insert(rooms, { id = id, x = x, y = 2, w = 6, h = 6, cx = x + 3, cy = 5 })
	end
	grid:fillRect(8, 4, 4, 2, 1) -- A-B
	grid:fillRect(18, 4, 4, 2, 1) -- B-C
	local graph = Graph.new()
	for _, room in rooms do
		graph:addNode(room.id, "room")
	end
	graph:addEdge("A", "B")
	graph:addEdge("B", "C")
	graph:addEdge("A", "C")
	local layout = { kind = "dungeon", grid = grid, rooms = rooms, graph = graph }
	local placement = {
		spawn = "A",
		goal = "C",
		roles = { A = "spawn", B = "connector", C = "goal" },
		criticalPath = { "A", "B", "C" },
	}
	return layout, placement
end

test("redundant_paths fails when the graph claims a loop the grid does not have", function(t)
	local layout, placement = rowOfRooms()
	t.eq(layout.graph:cycleRank(), 1, "layout graph claims a loop")
	local redundant = find(Validate.rooms(layout, placement), "redundant_paths")
	t.eq(redundant.value, 0, "walkable loops")
	t.ok(not redundant.pass, "graph-only loop must not pass")
	t.ok(not hasWalkableLoop(layout), "independent check agrees")

	-- A second, separate A-B corridor along the rooms' bottom row is a real alternate route.
	layout.grid:fillRect(8, 7, 4, 1, 1)
	redundant = find(Validate.rooms(layout, placement), "redundant_paths")
	t.eq(redundant.value, 1, "walkable loops after a parallel corridor")
	t.ok(redundant.pass)
	t.ok(hasWalkableLoop(layout), "independent check agrees")
end)

test("dungeon redundant_paths agrees with an independent walkable-loop check", function(t)
	local treesWithoutLoops = 0
	for seed = 1, 40 do
		for _, params in { { seed = seed }, { seed = seed, loopChance = 0, minLoops = 0 } } do
			local layout = Dungeon.generate(params)
			local placement = Placement.assign(layout, { encounters = 2, landmarks = 1 })
			local redundant = find(Validate.rooms(layout, placement), "redundant_paths")
			local walkable = hasWalkableLoop(layout)
			local label = string.format("seed %d minLoops %s", seed, tostring(params.minLoops))
			t.eq(redundant.pass, walkable, label .. " redundant_paths vs grid")
			t.eq(redundant.value >= 1, walkable, label .. " loop count vs grid")
			if params.minLoops == nil then
				t.ok(walkable, label .. ": default dungeons need a walkable loop")
			elseif not walkable then
				treesWithoutLoops += 1
			end
		end
	end
	-- The sweep must exercise the failing direction too, not only passing layouts.
	t.ok(treesWithoutLoops > 0, "some loop-free layouts were checked")
end)

test("seeds whose old loops were graph-only now have walkable loops", function(t)
	-- 35: R03-R05 ran over R03-R04-R05's cells; 17: R03-R09 only widened R08/R09's opening.
	for _, seed in { 17, 21, 23, 24, 35 } do
		local layout = Dungeon.generate({ seed = seed })
		t.ok(hasWalkableLoop(layout), "seed " .. seed .. " has a walkable loop")
		local placement = Placement.assign(layout, { encounters = 2, landmarks = 1 })
		t.ok(find(Validate.rooms(layout, placement), "redundant_paths").pass, "seed " .. seed)
	end
end)

test("spawn_fairness fails when a spawn cannot reach the objective", function(t)
	local baseline = find(Validate.arena(Arena.generate({ seed = 404 })), "spawn_fairness")
	t.ok(baseline.pass, "unmodified arena is fair")

	-- Spawn B's own cell made solid (one distance missing, which used to give NaN and pass).
	local layout = Arena.generate({ seed = 404 })
	local b = layout.spawns[2]
	layout.grid:set(b[1], b[2], 0)
	local fairness = find(Validate.arena(layout), "spawn_fairness")
	t.ok(not fairness.pass, "one unreachable spawn fails")
	t.eq(fairness.value, math.huge)
	t.ok(string.find(fairness.detail, "unreachable", 1, true) ~= nil, "detail names the unreachable spawn")

	-- Spawn B walled into a pocket.
	layout = Arena.generate({ seed = 404 })
	for dy = -1, 1 do
		for dx = -1, 1 do
			if dx ~= 0 or dy ~= 0 then
				layout.grid:set(b[1] + dx, b[2] + dy, 0)
			end
		end
	end
	t.ok(not find(Validate.arena(layout), "spawn_fairness").pass, "walled-in spawn fails")

	-- Objective sealed off from both spawns.
	layout = Arena.generate({ seed = 404 })
	for _, cell in Grid.cellsCovering(layout.objectives[1]) do
		layout.grid:set(cell[1], cell[2], 0)
	end
	t.ok(not find(Validate.arena(layout), "spawn_fairness").pass, "unreachable objective fails")
end)

test("arena objective sits on the symmetry centre for odd and even sizes", function(t)
	local sizes = { { 40, 24 }, { 41, 25 }, { 32, 20 }, { 30, 20 }, { 28, 18 }, { 41, 24 }, { 40, 25 } }
	for _, size in sizes do
		local w, h = size[1], size[2]
		for _, symmetry in { "rotational", "mirror" } do
			for seed = 1, 8 do
				local layout = Arena.generate({ seed = seed, width = w, height = h, symmetry = symmetry })
				local label = string.format("%dx%d %s seed %d", w, h, symmetry, seed)
				local objective = layout.objectives[1]
				t.eq(objective[1], (w + 1) / 2, label .. " objective x")
				t.eq(objective[2], (h + 1) / 2, label .. " objective y")
				local expected = (if w % 2 == 0 then 2 else 1) * (if h % 2 == 0 then 2 else 1)
				local cells = Grid.cellsCovering(objective)
				t.eq(#cells, expected, label .. " objective cells")
				for _, cell in cells do
					t.ok(layout.grid:get(cell[1], cell[2]) ~= 0, label .. " objective cell is floor")
					t.eq(layout.grid:labelAt(cell[1], cell[2]), "O", label .. " objective label")
				end
				-- The grid maps onto itself, so equal spawn distances follow by construction.
				for y = 1, h do
					for x = 1, w do
						local my = if symmetry == "mirror" then y else h + 1 - y
						t.eq(
							layout.grid:get(x, y),
							layout.grid:get(w + 1 - x, my),
							label .. " symmetric grid"
						)
					end
				end
				t.eq(find(Validate.arena(layout), "spawn_fairness").value, 0, label .. " spread")
			end
		end
	end
end)

test("an off-centre objective is caught by spawn_fairness", function(t)
	-- Where the old generator put it on a 41x25 map: (20, 12) instead of the centre (21, 13).
	local layout = Arena.generate({ seed = 8, width = 41, height = 25 })
	layout.objectives = { { 20, 12 } }
	local fairness = find(Validate.arena(layout), "spawn_fairness")
	t.ok(fairness.value > 0, "off-centre objective is not equidistant")
	t.ok(not fairness.pass, "and exceeds the 10% spread limit: " .. tostring(fairness.detail))
end)

test("goal and encounter rooms fit minEncounterAreaStuds", function(t)
	for seed = 1, 60 do
		local layout = Dungeon.generate({ seed = seed })
		for _, requirements in
			{
				{ encounters = 2, landmarks = 1 },
				{ encounters = 3, landmarks = 1 },
				{ encounters = 2, optionalEncounters = true },
			}
		do
			local placement = Placement.assign(layout, requirements)
			local space = find(Validate.rooms(layout, placement), "encounter_space")
			t.ok(space.pass, string.format("seed %d enc %d: %s", seed, requirements.encounters, space.detail))
			local cellArea = layout.grid.cellSize ^ 2
			for _, room in layout.rooms do
				local role = placement.roles[room.id]
				if role == "goal" or role == "encounter" or role == "optional_encounter" then
					t.ok(
						room.w * room.h * cellArea >= 576,
						string.format("seed %d %s %s", seed, room.id, role)
					)
				end
			end
			t.ok(#placement.criticalPath >= 3, "spawn and goal are not adjacent")
		end
	end
end)

test("with no roomy room the goal falls back and encounter_space reports it", function(t)
	-- Rooms of 4-5 cells (at most 20x20 studs) can never hold a 24x24 encounter.
	local layout = Dungeon.generate({ seed = 5, minRoom = 4, maxRoom = 5 })
	local placement = Placement.assign(layout, { encounters = 2 })
	t.eq(placement.roles[placement.goal], "goal")
	t.eq(placement.unplacedEncounters, math.min(2, #placement.criticalPath - 2), "encounters not squeezed in")
	for _, role in placement.roles do
		t.ok(role ~= "encounter", "no encounter in a cramped room")
	end
	local space = find(Validate.rooms(layout, placement), "encounter_space")
	t.ok(not space.pass, "cramped goal is reported, not hidden")
	t.eq(space.detail, placement.goal)
end)

test("caves join into exactly one region", function(t)
	-- Seed 87 at 48x36 used to end with two regions: a pocket filled after a tunnel crossed it.
	local cave = Cave.generate({ seed = 87, width = 48, height = 36 })
	t.eq(#cave.grid:regions(), 1, "seed 87 regions")
	t.ok(find(Validate.grid(cave.grid), "connectivity").pass, "seed 87 connectivity")
	for _, size in { { 48, 36 }, { 32, 24 } } do
		for seed = 1, 200 do
			local grid = Cave.generate({ seed = seed, width = size[1], height = size[2] }).grid
			t.eq(#grid:regions(), 1, string.format("%dx%d seed %d regions", size[1], size[2], seed))
		end
	end
end)

test("connectivity fails on a cave split into two regions", function(t)
	local grid = Cave.generate({ seed = 87, width = 48, height = 36 }).grid
	-- Open an isolated pocket inside solid rock: the validator must count two regions.
	local opened = false
	for y = 3, grid.height - 2 do
		for x = 3, grid.width - 2 do
			local solid = true
			for dy = -1, 1 do
				for dx = -1, 1 do
					solid = solid and grid:get(x + dx, y + dy) == 0
				end
			end
			if solid and not opened then
				grid:set(x, y, 1)
				opened = true
			end
		end
	end
	t.ok(opened, "found solid rock to open")
	local connectivity = find(Validate.grid(grid), "connectivity")
	t.ok(not connectivity.pass)
	t.eq(connectivity.value, 2)
end)

return cases
