-- Regression specs for reviewed ProcGen defects: loops must be walkable on the grid and wrap
-- a real wall (not a pillar), arena fairness must fail on unreachable spawns, the arena
-- objective sits on the symmetry centre, goal/encounter rooms fit an encounter, a requested
-- encounter that cannot be placed fails visibly, and caves always join into one region.
local Arena = require("../packages/ProcGen/Arena")
local Cave = require("../packages/ProcGen/Cave")
local Dungeon = require("../packages/ProcGen/Dungeon")
local Graph = require("../packages/ProcGen/Graph")
local Grid = require("../packages/ProcGen/Grid")
local Placement = require("../packages/ProcGen/Placement")
local RoomGraph = require("../packages/ProcGen/RoomGraph")
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

-- Default dungeons, placements and checks are shared by the 200-seed sweeps (generation is
-- deterministic and nothing below mutates a layout or placement).
local defaultDungeons, defaultRuns = {}, {}
local function defaultDungeon(seed: number)
	defaultDungeons[seed] = defaultDungeons[seed] or Dungeon.generate({ seed = seed })
	return defaultDungeons[seed]
end
local function defaultRun(seed: number, encounters: number)
	local key = seed .. "/" .. encounters
	if defaultRuns[key] == nil then
		local layout = defaultDungeon(seed)
		local placement = Placement.assign(layout, { encounters = encounters, landmarks = 1 })
		defaultRuns[key] =
			{ layout = layout, placement = placement, checks = Validate.rooms(layout, placement) }
	end
	return defaultRuns[key]
end

local NEIGHBOURS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- Wall a loop must wrap by default: 144 sq studs (one 12 x 12 minimum room) = 9 cells of 4 studs.
local PILLAR_CELLS = 9

-- Independent of RoomGraph: a copy of the grid where every wall pocket the map edge cannot
-- reach through wall (8-connected) and smaller than `minWallCells` is floor. Such a pocket is
-- a pillar inside one wide passage, not a wall between two routes.
local function withoutPillars(grid, minWallCells: number)
	local copy = Grid.new(grid.width, grid.height, grid.cellSize, 0)
	copy.cells = table.clone(grid.cells)
	local width, height = grid.width, grid.height
	local function key(x, y)
		return (y - 1) * width + x
	end
	local outside, stack = {}, {}
	for y = 1, height do
		for x = 1, width do
			if (x == 1 or y == 1 or x == width or y == height) and grid:get(x, y) == 0 then
				outside[key(x, y)] = true
				table.insert(stack, { x, y })
			end
		end
	end
	while #stack > 0 do
		local cell = table.remove(stack)
		for dy = -1, 1 do
			for dx = -1, 1 do
				local nx, ny = cell[1] + dx, cell[2] + dy
				if grid:inBounds(nx, ny) and grid:get(nx, ny) == 0 and not outside[key(nx, ny)] then
					outside[key(nx, ny)] = true
					table.insert(stack, { nx, ny })
				end
			end
		end
	end
	local grouped = {}
	for y = 1, height do
		for x = 1, width do
			if grid:get(x, y) == 0 and not outside[key(x, y)] and not grouped[key(x, y)] then
				local pocket = {}
				grouped[key(x, y)] = true
				stack = { { x, y } }
				while #stack > 0 do
					local cell = table.remove(stack)
					table.insert(pocket, cell)
					for dy = -1, 1 do
						for dx = -1, 1 do
							local nx, ny = cell[1] + dx, cell[2] + dy
							if
								grid:get(nx, ny) == 0
								and grid:inBounds(nx, ny)
								and not outside[key(nx, ny)]
								and not grouped[key(nx, ny)]
							then
								grouped[key(nx, ny)] = true
								table.insert(stack, { nx, ny })
							end
						end
					end
				end
				if #pocket < minWallCells then
					for _, cell in pocket do
						copy:set(cell[1], cell[2], 1)
					end
				end
			end
		end
	end
	return copy
end

-- Independent of RoomGraph/Validate: flood-fill each corridor component (floor outside every
-- room), fill it solid, and see whether two rooms it touched still share a walkable region.
-- If they do, the map has a loop a player can walk around. Pillars (pockets under
-- `minWallCells`, default PILLAR_CELLS) are floor first; pass 0 for the pure topology.
local function hasWalkableLoop(layout, minWallCells: number?): boolean
	local grid = withoutPillars(layout.grid, minWallCells or PILLAR_CELLS)
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

	-- A detour from A's bottom-left corner along row 9 into B's bottom-right corner wraps a
	-- 22-cell wall (row 8 plus the gap under the A-B corridor): a real alternate route.
	layout.grid:fillRect(2, 8, 1, 2, 1)
	layout.grid:fillRect(2, 9, 16, 1, 1)
	layout.grid:fillRect(17, 8, 1, 1, 1)
	redundant = find(Validate.rooms(layout, placement), "redundant_paths")
	t.eq(redundant.value, 1, "walkable loops after a detour corridor")
	t.ok(redundant.pass)
	t.ok(hasWalkableLoop(layout), "independent check agrees")
	local pockets = RoomGraph.pockets(layout.grid)
	t.eq(#pockets, 1, "one enclosed wall")
	t.eq(#pockets[1], 22, "wrapped wall cells")
end)

test("a loop around a pillar is not an alternate route", function(t)
	-- Seed 35's old only loop: a second A-B corridor one cell below the first, so the "loop"
	-- wraps a 4x1-cell (16 x 4 stud) pillar inside one wide passage.
	local layout, placement = rowOfRooms()
	layout.grid:fillRect(8, 7, 4, 1, 1)
	t.eq(RoomGraph.loops(layout.grid, layout.rooms, nil, 0), 1, "topologically a loop")
	t.ok(hasWalkableLoop(layout, 0), "independent topology check agrees")
	local redundant = find(Validate.rooms(layout, placement), "redundant_paths")
	t.eq(redundant.value, 0, "pillar loop does not count")
	t.ok(not redundant.pass, "pillar loop must not pass redundant_paths")
	t.ok(not hasWalkableLoop(layout), "independent pillar-aware check agrees")
	-- The threshold is a rule, not a hidden constant: a 64 sq stud limit accepts the 64 sq stud pillar.
	t.ok(find(Validate.rooms(layout, placement, { minLoopWallStuds = 64 }), "redundant_paths").pass)
	t.ok(not find(Validate.rooms(layout, placement, { minLoopWallStuds = 65 }), "redundant_paths").pass)
end)

test("dungeon redundant_paths agrees with an independent walkable-loop check", function(t)
	local treesWithoutLoops, pillarOnly = 0, 0
	for seed = 1, 40 do
		for _, params in { { seed = seed }, { seed = seed, loopChance = 0, minLoops = 0 } } do
			local layout = if params.minLoops == nil then defaultDungeon(seed) else Dungeon.generate(params)
			local placement = Placement.assign(layout, { encounters = 2, landmarks = 1 })
			local redundant = find(Validate.rooms(layout, placement), "redundant_paths")
			local walkable = hasWalkableLoop(layout)
			local label = string.format("seed %d minLoops %s", seed, tostring(params.minLoops))
			t.eq(redundant.pass, walkable, label .. " redundant_paths vs grid")
			t.eq(redundant.value >= 1, walkable, label .. " loop count vs grid")
			-- The pure topological count must agree with the independent check too.
			local topological = hasWalkableLoop(layout, 0)
			t.eq(RoomGraph.loops(layout.grid, layout.rooms, nil, 0) >= 1, topological, label .. " topology")
			if topological and not walkable then
				pillarOnly += 1
			end
			if params.minLoops == nil then
				t.ok(walkable, label .. ": default dungeons need a walkable loop")
			elseif not walkable then
				treesWithoutLoops += 1
			end
		end
	end
	-- The sweep must exercise the failing directions too, not only passing layouts.
	t.ok(treesWithoutLoops > 0, "some loop-free layouts were checked")
	t.ok(pillarOnly > 0, "some pillar-only loops were checked")
end)

test("default dungeons loop around a real wall across 200 seeds", function(t)
	for seed = 1, 200 do
		local run = defaultRun(seed, 2)
		t.ok(find(run.checks, "redundant_paths").pass, "seed " .. seed)
		t.ok(hasWalkableLoop(run.layout), "seed " .. seed .. " independent check")
	end
end)

test("seeds whose old loops were graph-only now have walkable loops", function(t)
	-- 35: R03-R05 ran over R03-R04-R05's cells; 17: R03-R09 only widened R08/R09's opening.
	for _, seed in { 17, 21, 23, 24, 35 } do
		local layout = defaultDungeon(seed)
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
		local layout = defaultDungeon(seed)
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
	t.eq(placement.requestedEncounters, 2)
	t.eq(placement.unplacedEncounters, 2, "encounters not squeezed in")
	for _, role in placement.roles do
		t.ok(role ~= "encounter", "no encounter in a cramped room")
	end
	local checks = Validate.rooms(layout, placement)
	local space = find(checks, "encounter_space")
	t.ok(not space.pass, "cramped goal is reported, not hidden")
	t.eq(space.detail, placement.goal)
	local placed = find(checks, "encounters_placed")
	t.ok(not placed.pass, "the shortfall is reported too")
	t.eq(placed.value, 0)
	t.eq(placed.limit, 2)
end)

local function encounterCount(placement): number
	local count = 0
	for _, role in placement.roles do
		if role == "encounter" then
			count += 1
		end
	end
	return count
end

test("an encounter that cannot be placed fails encounters_placed", function(t)
	-- Default dungeons whose shortest spawn-goal routes hold fewer roomy rooms than asked for.
	-- These used to drop the missing encounters silently and pass every check (194: 0 of 2).
	for _, seed in { 39, 63, 194 } do
		local layout = defaultDungeon(seed)
		local placement = Placement.assign(layout, { encounters = 2, landmarks = 1 })
		local checks = Validate.rooms(layout, placement)
		local placed = find(checks, "encounters_placed")
		local label = "seed " .. seed
		t.eq(placed.value, encounterCount(placement), label .. " counts placed encounters")
		t.eq(placed.value, 1, label .. " places one")
		t.eq(placed.limit, 2, label .. " of two requested")
		t.eq(placement.unplacedEncounters, 1, label .. " unplaced")
		t.ok(not placed.pass, label .. " shortfall fails")
		t.ok(not Validate.summary(checks).pass, label .. " summary fails")
		t.ok(find(checks, "encounter_space").pass, label .. " no cramped room was used instead")
	end

	-- A critical path with one interior room cannot hold three encounters either.
	local grid = Grid.new(30, 10, 4, 0)
	local rooms, graph = {}, Graph.new()
	for index, id in { "A", "B", "C" } do
		local x = 2 + (index - 1) * 10
		grid:fillRect(x, 2, 6, 6, 1)
		table.insert(rooms, { id = id, x = x, y = 2, w = 6, h = 6, cx = x + 3, cy = 5 })
		graph:addNode(id, "room")
	end
	grid:fillRect(8, 4, 4, 2, 1)
	grid:fillRect(18, 4, 4, 2, 1)
	graph:addEdge("A", "B")
	graph:addEdge("B", "C")
	local layout = { kind = "dungeon", grid = grid, rooms = rooms, graph = graph }
	local placement = Placement.assign(layout, { encounters = 3 })
	t.eq(placement.criticalPath, { "A", "B", "C" })
	t.eq(placement.roles.B, "encounter")
	t.eq(placement.unplacedEncounters, 2, "short path shortfall is counted")
	local placed = find(Validate.rooms(layout, placement), "encounters_placed")
	t.ok(not placed.pass, "short critical path fails")
	t.eq(placed.value, 1)
	t.eq(placed.limit, 3)
end)

test("encounters_placed agrees with the roles across 200 seeds", function(t)
	local shortfalls, met = 0, 0
	for seed = 1, 200 do
		for _, requested in { 2, 3 } do
			local run = defaultRun(seed, requested)
			local layout, placement = run.layout, run.placement
			local label = string.format("seed %d enc %d", seed, requested)
			local count = encounterCount(placement)
			local placed = find(run.checks, "encounters_placed")
			t.eq(placed.value, count, label .. " value")
			t.eq(placed.limit, requested, label .. " limit")
			t.eq(placed.pass, count >= requested, label .. " pass")
			t.eq(placement.unplacedEncounters, requested - count, label .. " unplaced")
			-- Encounters only sit strictly inside the critical path, which is a shortest route.
			local inside = {}
			for index = 2, #placement.criticalPath - 1 do
				inside[placement.criticalPath[index]] = true
			end
			for id, role in placement.roles do
				if role == "encounter" then
					t.ok(inside[id], label .. " " .. id .. " on the critical path")
				end
			end
			local hops = layout.graph:distances(placement.spawn)[placement.goal]
			t.eq(#placement.criticalPath, hops + 1, label .. " critical path is a shortest route")
			for index = 2, #placement.criticalPath do
				local a, b = placement.criticalPath[index - 1], placement.criticalPath[index]
				t.ok(layout.graph:hasEdge(a, b), label .. " critical path is connected")
			end
			if count < requested then
				shortfalls += 1
			else
				met += 1
			end
		end
	end
	-- Both directions are exercised: most seeds meet the request, some visibly do not.
	t.ok(shortfalls > 0 and met > shortfalls, string.format("met %d, short %d", met, shortfalls))
end)

test("the encounter path is picked over every shortest route", function(t)
	-- Seed 194: the BFS route R06..R13-R12-R14 has no roomy interior room; the equally short
	-- R06..R13-R15-R14 has one, so one of the two requested encounters is placed there.
	local layout = Dungeon.generate({ seed = 194 })
	local placement = Placement.assign(layout, { encounters = 2, landmarks = 1 })
	t.eq(placement.spawn, "R06")
	t.eq(placement.goal, "R14")
	t.eq(#layout.graph:shortestPath("R06", "R14"), #placement.criticalPath, "still a shortest route")
	t.eq(placement.criticalPath[#placement.criticalPath - 1], "R15")
	t.eq(placement.roles.R15, "encounter")
end)

test("encounter-sized goals keep the run long", function(t)
	-- Ranking pairs by encounter capacity used to cut seed 4's run from 12 rooms to 6.
	local layout = Dungeon.generate({ seed = 4 })
	t.eq(#Placement.assign(layout, { encounters = 2, landmarks = 1 }).criticalPath, 12, "seed 4")
	for seed = 1, 200 do
		layout = defaultDungeon(seed)
		local diameter = 0
		for _, id in layout.graph.order do
			for _, d in layout.graph:distances(id) do
				diameter = math.max(diameter, d)
			end
		end
		local hops = #defaultRun(seed, 2).placement.criticalPath - 1
		t.ok(hops >= 0.75 * diameter, string.format("seed %d run %d of diameter %d", seed, hops, diameter))
	end
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
