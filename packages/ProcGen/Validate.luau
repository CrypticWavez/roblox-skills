--!strict
-- Layout validators. Each check returns { name, pass, value, limit, detail } so reports
-- are machine-readable and comparable across seeds.
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
