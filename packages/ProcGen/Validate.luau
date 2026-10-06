--!strict
-- Layout validators. Each check returns { name, pass, value, limit, detail } so reports
-- are machine-readable and comparable across seeds.
local Forest = require("./Forest")
local Grid = require("./Grid")
local RoomGraph = require("./RoomGraph")

local Validate = {}

export type Check = { name: string, pass: boolean, value: any, limit: any?, detail: string? }
export type Rules = {
	minCorridorStuds: number?, -- default 6 (two players abreast at 2 studs each, with margin)
	minLoops: number?, -- redundant routes required
	minLoopWallStuds: number?, -- square studs of wall a loop must wrap (smaller pockets are pillars)
	maxDeadEndRatio: number?,
	minEncounterAreaStuds: number?, -- square studs for an encounter room
	maxSpawnDistanceSpread: number?, -- fairness ratio tolerance (0.1 = 10%)
	maxParts: number?, -- performance budget estimate
	minRoomStuds: number?, -- smallest room side; keeps the default camera boom inside
	minTrunkSpacing: number?, -- forest: studs between trunk centres
	minObstacleGapStuds: number?, -- forest: edge gap between collidable trunks and rocks
	spawnClearStuds: number?, -- forest: studs from the spawn to the nearest trunk or rock edge
	bandDensity: { [string]: { number } }?, -- forest: {min, max} collidables per 1000 sq studs
}

local DEFAULTS = {
	minCorridorStuds = 6,
	minLoops = 1,
	minLoopWallStuds = RoomGraph.MIN_LOOP_WALL_STUDS, -- 144: one 12 x 12 minimum room footprint
	maxDeadEndRatio = 0.5,
	minEncounterAreaStuds = 576, -- 24 x 24
	maxSpawnDistanceSpread = 0.1,
	maxParts = 5000,
	minRoomStuds = 12,
	-- Two trunks up to 2 studs wide 6 studs apart leave a 2.5-stud character width plus margin.
	minTrunkSpacing = 6,
	-- A gap narrower than a character (2.5 studs) between collidables is a snag, not a route.
	minObstacleGapStuds = 3,
	-- The 6-stud spawn pad plus a character width on every side.
	spawnClearStuds = 8,
}

local function rule(rules: Rules?, key: string): number
	return ((rules :: any) or {})[key] or (DEFAULTS :: any)[key]
end

local function check(name: string, pass: boolean, value: any, limit: any?, detail: string?): Check
	return { name = name, pass = pass, value = value, limit = limit, detail = detail }
end

-- Bresenham line over cells; true when no solid cell lies strictly between the endpoints.
function Validate.lineOfSight(grid, a: { number }, b: { number }): boolean
	local x0, y0, x1, y1 = a[1], a[2], b[1], b[2]
	local dx, dy = math.abs(x1 - x0), -math.abs(y1 - y0)
	local sx, sy = if x0 < x1 then 1 else -1, if y0 < y1 then 1 else -1
	local err = dx + dy
	while not (x0 == x1 and y0 == y1) do
		local e2 = 2 * err
		if e2 >= dy then
			err += dy
			x0 += sx
		end
		if e2 <= dx then
			err += dx
			y0 += sy
		end
		if not (x0 == x1 and y0 == y1) and grid:get(x0, y0) == 0 then
			return false
		end
	end
	return true
end

-- Rough part estimate: one floor tile per floor cell plus one wall per exposed solid edge
-- (before greedy merging, so it is an upper bound).
function Validate.estimateParts(grid): number
	local total = 0
	for y = 1, grid.height do
		for x = 1, grid.width do
			if grid:get(x, y) ~= 0 then
				total += 1
				for _, o in grid.OFFSETS do
					if grid:get(x + o[1], y + o[2]) == 0 then
						total += 1
					end
				end
			end
		end
	end
	return total
end

function Validate.grid(grid, rules: Rules?): { Check }
	local checks = {}
	local regions = grid:regions()
	table.insert(checks, check("connectivity", #regions == 1, #regions, 1, "walkable regions"))
	local narrowest = math.huge
	for y = 1, grid.height do
		for x = 1, grid.width do
			if grid:get(x, y) ~= 0 then
				narrowest = math.min(narrowest, grid:clearWidth(x, y))
			end
		end
	end
	local narrowStuds = if narrowest == math.huge then 0 else narrowest * grid.cellSize
	table.insert(
		checks,
		check(
			"player_scale_corridor",
			narrowStuds >= rule(rules, "minCorridorStuds"),
			narrowStuds,
			rule(rules, "minCorridorStuds"),
			"narrowest clear width in studs"
		)
	)
	local parts = Validate.estimateParts(grid)
	table.insert(
		checks,
		check("performance_part_estimate", parts <= rule(rules, "maxParts"), parts, rule(rules, "maxParts"))
	)
	return checks
end

function Validate.rooms(layout, placement, rules: Rules?): { Check }
	local grid, graph = layout.grid, layout.graph
	local checks = Validate.grid(grid, rules)
	local byId = {}
	for _, room in layout.rooms do
		byId[room.id] = room
	end
	local spawn = byId[placement.spawn]
	local unreachable = {}
	for _, room in layout.rooms do
		if grid:walkDistance({ spawn.cx, spawn.cy }, { room.cx, room.cy }) == nil then
			table.insert(unreachable, room.id)
		end
	end
	table.insert(
		checks,
		check("reachability", #unreachable == 0, #unreachable, 0, table.concat(unreachable, ","))
	)
	-- Loops are counted on the carved grid (rooms + corridor components), not on the layout
	-- graph: a loop link whose corridor reuses existing cells is not an alternate route, and
	-- neither is a pillar splitting one wide passage (a wall pocket under minLoopWallStuds).
	local loops = RoomGraph.loops(
		grid,
		layout.rooms,
		nil,
		RoomGraph.minWallCells(grid, rule(rules, "minLoopWallStuds"))
	)
	table.insert(
		checks,
		check(
			"redundant_paths",
			loops >= rule(rules, "minLoops"),
			loops,
			rule(rules, "minLoops"),
			string.format(
				"walkable loops around >= %d sq studs of wall; layout graph claims %d",
				rule(rules, "minLoopWallStuds"),
				graph:cycleRank()
			)
		)
	)
	local deadEnds = graph:deadEnds()
	local ratio = #deadEnds / math.max(1, #graph.order)
	table.insert(
		checks,
		check(
			"dead_end_ratio",
			ratio <= rule(rules, "maxDeadEndRatio"),
			math.round(ratio * 100) / 100,
			rule(rules, "maxDeadEndRatio")
		)
	)
	local purposeless = {}
	for _, id in deadEnds do
		local role = placement.roles[id]
		if role == nil or role == "connector" then
			table.insert(purposeless, id)
		end
	end
	table.insert(
		checks,
		check("purposeless_branches", #purposeless == 0, #purposeless, 0, table.concat(purposeless, ","))
	)
	local cramped, smallest = {}, math.huge
	for _, room in layout.rooms do
		local role = placement.roles[room.id]
		smallest = math.min(smallest, math.min(room.w, room.h) * grid.cellSize)
		if
			(role == "encounter" or role == "goal" or role == "optional_encounter")
			and room.w * room.h * grid.cellSize ^ 2 < rule(rules, "minEncounterAreaStuds")
		then
			table.insert(cramped, room.id)
		end
	end
	table.insert(checks, check("encounter_space", #cramped == 0, #cramped, 0, table.concat(cramped, ",")))
	-- Requirement shortfall: Placement leaves an encounter unplaced rather than squeezing it
	-- into a cramped room or off the critical path, so a short count must fail here, not vanish.
	local placed = 0
	for _, role in placement.roles do
		if role == "encounter" then
			placed += 1
		end
	end
	local requested = placement.requestedEncounters or (placed + (placement.unplacedEncounters or 0))
	table.insert(
		checks,
		check(
			"encounters_placed",
			placed >= requested,
			placed,
			requested,
			"critical-path encounters placed in rooms that fit / requested"
		)
	)
	table.insert(
		checks,
		check(
			"camera_clearance_room",
			smallest >= rule(rules, "minRoomStuds"),
			smallest,
			rule(rules, "minRoomStuds"),
			"smallest room side in studs"
		)
	)
	local goal = byId[placement.goal]
	local length = grid:walkDistance({ spawn.cx, spawn.cy }, { goal.cx, goal.cy })
	table.insert(
		checks,
		check(
			"critical_path_studs",
			length ~= nil,
			(length or 0) * grid.cellSize,
			nil,
			#placement.criticalPath .. " rooms"
		)
	)
	return checks
end

function Validate.arena(layout, rules: Rules?): { Check }
	local grid = layout.grid
	local checks = Validate.grid(grid, rules)
	local spread, worst = 0, ""
	for _, objective in layout.objectives do
		local distances, labels, unreachable = {}, {}, 0
		for _, spawn in layout.spawns do
			-- Distance to the nearest cell the objective covers (2 or 4 cells on a .5 centre).
			local best: number? = nil
			for _, cell in Grid.cellsCovering(objective) do
				local d = grid:walkDistance(spawn, cell)
				if d ~= nil and (best == nil or d < best) then
					best = d
				end
			end
			if best == nil then
				unreachable += 1
				table.insert(labels, "unreachable")
			else
				table.insert(distances, best)
				table.insert(labels, tostring(best))
			end
		end
		-- Any spawn that cannot reach the objective is maximally unfair (never NaN).
		local s = 0
		if unreachable > 0 then
			s = math.huge
		elseif #distances > 0 then
			local lo, hi = math.min(table.unpack(distances)), math.max(table.unpack(distances))
			s = if hi == 0 then 0 else (hi - lo) / hi
		end
		if s > spread or worst == "" then
			spread, worst = math.max(s, spread), table.concat(labels, "/")
		end
	end
	table.insert(
		checks,
		check(
			"spawn_fairness",
			spread <= rule(rules, "maxSpawnDistanceSpread"),
			spread,
			rule(rules, "maxSpawnDistanceSpread"),
			worst
		)
	)
	local exposed = Validate.lineOfSight(grid, layout.spawns[1], layout.spawns[2])
	table.insert(
		checks,
		check("spawn_sightline_blocked", not exposed, exposed, false, "direct spawn-to-spawn line of sight")
	)
	return checks
end

function Validate.settlement(layout): { Check }
	local checks = {}
	local overlaps = 0
	for i, a in layout.lots do
		for j = i + 1, #layout.lots do
			local b = layout.lots[j]
			local fa, fb = a.footprint, b.footprint
			if fa.x < fb.x + fb.w and fb.x < fa.x + fa.w and fa.z < fb.z + fb.d and fb.z < fa.z + fa.d then
				overlaps += 1
			end
		end
	end
	table.insert(checks, check("footprint_overlap", overlaps == 0, overlaps, 0))
	local undersized = 0
	for _, lot in layout.lots do
		if lot.footprint.w < 12 or lot.footprint.d < 12 then
			undersized += 1
		end
	end
	table.insert(
		checks,
		check("footprint_player_scale", undersized == 0, undersized, 0, "footprints narrower than 12 studs")
	)
	table.insert(
		checks,
		check("road_connectivity", #layout.graph:components() == 1, #layout.graph:components(), 1)
	)
	table.insert(checks, check("lot_count", #layout.lots > 0, #layout.lots, ">0"))
	return checks
end

-- Collidables (trunks and rocks) per 1000 sq studs of plantable band area, i.e. outside the
-- path corridor and the clearings. Above 12 (one stem per ~83 sq studs, about 9 studs apart)
-- trunks close sightlines to a few studs and a band reads as a wall at player scale; trunks
-- packed at the 6-stud minimum spacing exceed it. Open stays under 2 to keep long sightlines.
Validate.FOREST_BAND_DENSITY = {
	open = { 0, 2 },
	sparse = { 1.5, 6 },
	dense = { 6, 12 },
	rocky = { 2, 8 },
}
local CHARACTER_RADIUS = 1.25 -- half of SceneKit Measure.GUIDE.characterWidth (2.5 studs)
local WALK_CELL = 2 -- studs per walk-grid cell, finer than a trunk's blocked disc
-- Sq studs (one 64 x 64 noise patch); a smaller plantable band area holds a handful of stems and
-- its density is noise, so it is reported as unchecked rather than judged.
local MIN_BAND_AREA = 4096

local function round2(value: number): number
	return math.round(value * 100) / 100
end

-- Forest / biome dressing, measured from the layout's geometry (paths, clearings, band map and
-- the collidable trunks and rocks, r > 0) rather than the generator's bookkeeping, so a moved
-- trunk, a dropped path or an over-dense band fails here.
function Validate.forest(layout, rules: Rules?): { Check }
	local checks = {}
	local p = layout.params
	local width, depth, pathWidth = p.width, p.depth, p.pathWidth
	local minCorridor = rule(rules, "minCorridorStuds")
	local corridorHalf = math.max(pathWidth, minCorridor) / 2
	local obstacles, trees = {}, {}
	for _, item in layout.vegetation do
		if item.r > 0 then
			table.insert(obstacles, item)
		end
		if item.kind == "tree" then
			table.insert(trees, item)
		end
	end
	local function distance(a, b): number
		return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
	end
	local function listed(ids: { string }): string
		return table.concat(ids, ",", 1, math.min(#ids, 5))
	end

	table.insert(
		checks,
		check(
			"player_scale_corridor",
			pathWidth >= minCorridor,
			pathWidth,
			minCorridor,
			"path width in studs"
		)
	)

	-- No trunk or rock edge inside the corridor: the path width, and never under minCorridorStuds.
	local clearance, intruders = math.huge, {}
	for _, o in obstacles do
		local edge = Forest.pathDistance(layout.paths, o.x, o.z) - o.r
		clearance = math.min(clearance, edge)
		if edge < corridorHalf then
			table.insert(intruders, o.id)
		end
	end
	table.insert(
		checks,
		check(
			"path_clearance",
			#intruders == 0,
			if clearance == math.huge then "open" else round2(clearance),
			corridorHalf,
			if #intruders > 0
				then "inside the corridor: " .. listed(intruders)
				else "studs from a path centreline to the nearest trunk or rock edge"
		)
	)

	-- Walk grid: path surface and clearing cells, minus cells a character centre cannot occupy
	-- next to a trunk or rock. The wider corridor mask feeds the plantable area below.
	local cols, rows = math.ceil(width / WALK_CELL), math.ceil(depth / WALK_CELL)
	local onPath, corridor, inClearing, blocked = {}, {}, {}, {}
	local function stamp(
		x0: number,
		z0: number,
		x1: number,
		z1: number,
		visit: (number, number, number) -> ()
	)
		for row = math.max(1, math.floor(z0 / WALK_CELL) + 1), math.min(rows, math.floor(z1 / WALK_CELL) + 1) do
			for col = math.max(1, math.floor(x0 / WALK_CELL) + 1), math.min(cols, math.floor(x1 / WALK_CELL) + 1) do
				visit((row - 1) * cols + col, (col - 0.5) * WALK_CELL, (row - 0.5) * WALK_CELL)
			end
		end
	end
	for _, path in layout.paths do
		for index = 1, #path.points - 1 do
			local a, b = path.points[index], path.points[index + 1]
			stamp(
				math.min(a[1], b[1]) - corridorHalf,
				math.min(a[2], b[2]) - corridorHalf,
				math.max(a[1], b[1]) + corridorHalf,
				math.max(a[2], b[2]) + corridorHalf,
				function(key, x, z)
					local d = Forest.segmentDistance(x, z, a, b)
					if d <= corridorHalf then
						corridor[key] = true
					end
					if d <= pathWidth / 2 then
						onPath[key] = true
					end
				end
			)
		end
	end
	for _, c in layout.clearings do
		stamp(c.x - c.radius, c.z - c.radius, c.x + c.radius, c.z + c.radius, function(key, x, z)
			if (x - c.x) ^ 2 + (z - c.z) ^ 2 <= c.radius ^ 2 then
				inClearing[key] = true
			end
		end)
	end
	for _, o in obstacles do
		local reach = o.r + CHARACTER_RADIUS
		stamp(o.x - reach, o.z - reach, o.x + reach, o.z + reach, function(key, x, z)
			if (x - o.x) ^ 2 + (z - o.z) ^ 2 < reach ^ 2 then
				blocked[key] = true
			end
		end)
	end
	local grid = Grid.new(cols, rows, WALK_CELL, 0)
	for key = 1, cols * rows do
		if (onPath[key] or inClearing[key]) and not blocked[key] then
			grid.cells[key] = 1
		end
	end
	local function cellOf(x: number, z: number): { number }
		return {
			math.clamp(math.floor(x / WALK_CELL) + 1, 1, cols),
			math.clamp(math.floor(z / WALK_CELL) + 1, 1, rows),
		}
	end

	-- Every clearing, the exit and both edge ends reachable from the spawn along the paths.
	local spawn = cellOf(layout.entry.x, layout.entry.z)
	local targets = { { "entry_edge", layout.entry.edge[1], layout.entry.edge[2] } }
	for _, c in layout.clearings do
		table.insert(targets, { c.id, c.x, c.z })
	end
	table.insert(targets, { "exit", layout.exit.x, layout.exit.z })
	table.insert(targets, { "exit_edge", layout.exit.edge[1], layout.exit.edge[2] })
	local unreachable = {}
	for _, target in targets do
		if grid:walkDistance(spawn, cellOf(target[2], target[3])) == nil then
			table.insert(unreachable, target[1])
		end
	end
	table.insert(
		checks,
		check(
			"clearing_reachability",
			#unreachable == 0,
			#unreachable,
			0,
			if #unreachable > 0
				then "not reachable along the paths: " .. table.concat(unreachable, ",")
				else #targets .. " targets reached along the paths"
		)
	)

	local nearest, nearestId = math.huge, "none"
	for _, o in obstacles do
		local edge = distance(o, layout.entry) - o.r
		if edge < nearest then
			nearest, nearestId = edge, o.id
		end
	end
	local spawnOpen = grid:get(spawn[1], spawn[2]) ~= 0
	table.insert(
		checks,
		check(
			"spawn_clear",
			spawnOpen and nearest >= rule(rules, "spawnClearStuds"),
			if nearest == math.huge then "open" else round2(nearest),
			rule(rules, "spawnClearStuds"),
			if spawnOpen
				then "studs from the spawn to the nearest trunk or rock edge (" .. nearestId .. ")"
				else "spawn cell blocked or off the path"
		)
	)

	local bounds = (rules and rules.bandDensity) or Validate.FOREST_BAND_DENSITY
	local area, count = {}, {}
	for row = 1, rows do
		for col = 1, cols do
			local key = (row - 1) * cols + col
			if not corridor[key] and not inClearing[key] then
				local band = Forest.bandAt(layout, (col - 0.5) * WALK_CELL, (row - 0.5) * WALK_CELL)
				area[band] = (area[band] or 0) + WALK_CELL ^ 2
			end
		end
	end
	for _, o in obstacles do
		local band = Forest.bandAt(layout, o.x, o.z)
		count[band] = (count[band] or 0) + 1
	end
	local outside, notes = 0, {}
	for _, band in Forest.BAND_ORDER do
		local limits, plantable = bounds[band], area[band] or 0
		if limits and plantable >= MIN_BAND_AREA then
			local density = (count[band] or 0) / plantable * 1000
			local ok = density >= limits[1] and density <= limits[2]
			outside += if ok then 0 else 1
			table.insert(
				notes,
				string.format(
					"%s %.2f [%g-%g] over %d%s",
					band,
					density,
					limits[1],
					limits[2],
					plantable,
					if ok then "" else " OUT"
				)
			)
		else
			table.insert(
				notes,
				string.format(
					"%s unchecked (%d sq studs; no bounds or under %d)",
					band,
					plantable,
					MIN_BAND_AREA
				)
			)
		end
	end
	table.insert(
		checks,
		check(
			"band_density",
			outside == 0,
			outside,
			0,
			"collidables per 1000 sq studs of plantable area: " .. table.concat(notes, "; ")
		)
	)

	local closest, pair = math.huge, ""
	for i = 1, #trees do
		for j = i + 1, #trees do
			local d = distance(trees[i], trees[j])
			if d < closest then
				closest, pair = d, trees[i].id .. "/" .. trees[j].id
			end
		end
	end
	table.insert(
		checks,
		check(
			"min_trunk_spacing",
			closest >= rule(rules, "minTrunkSpacing"),
			if closest == math.huge then "open" else round2(closest),
			rule(rules, "minTrunkSpacing"),
			"closest trunk centres " .. pair
		)
	)
	local gap, gapPair = math.huge, ""
	for i = 1, #obstacles do
		for j = i + 1, #obstacles do
			local a, b = obstacles[i], obstacles[j]
			local d = distance(a, b) - a.r - b.r
			if d < gap then
				gap, gapPair = d, a.id .. "/" .. b.id
			end
		end
	end
	table.insert(
		checks,
		check(
			"obstacle_gap",
			gap >= rule(rules, "minObstacleGapStuds"),
			if gap == math.huge then "open" else round2(gap),
			rule(rules, "minObstacleGapStuds"),
			"narrowest gap between trunk or rock edges " .. gapPair
		)
	)

	local cramped = {}
	for _, c in layout.clearings do
		local free = c.radius
		for _, o in obstacles do
			free = math.min(free, distance(o, c) - o.r)
		end
		if free < c.radius or math.pi * c.radius ^ 2 < rule(rules, "minEncounterAreaStuds") then
			table.insert(cramped, c.id)
		end
	end
	table.insert(
		checks,
		check(
			"clearing_space",
			#cramped == 0,
			#cramped,
			0,
			if #cramped > 0
				then "trunk or rock inside, or under minEncounterAreaStuds: " .. listed(cramped)
				else "clearings free of trunks and rocks and big enough for an encounter"
		)
	)
	table.insert(
		checks,
		check(
			"clearings_placed",
			#layout.clearings >= p.clearings,
			#layout.clearings,
			p.clearings,
			"clearings placed / requested"
		)
	)
	local parts = Forest.partEstimate(layout)
	table.insert(
		checks,
		check(
			"performance_part_estimate",
			parts <= rule(rules, "maxParts"),
			parts,
			rule(rules, "maxParts"),
			"parts ForestScene emits"
		)
	)
	return checks
end

function Validate.summary(checks: { Check }): { pass: boolean, failed: { string }, checks: { Check } }
	local failed = {}
	for _, c in checks do
		if not c.pass then
			table.insert(failed, c.name)
		end
	end
	return { pass = #failed == 0, failed = failed, checks = checks }
end

return Validate
