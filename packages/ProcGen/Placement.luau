--!strict
-- Assigns gameplay roles to a room layout from requirements rather than at random:
-- spawn on the periphery, goal as far away as possible among rooms big enough for an
-- encounter, encounters paced along the critical path (only in rooms that fit), every dead
-- end given a purpose (treasure/optional), landmarks at hubs.
local Rng = require("./Rng")

local Placement = {}

export type Requirements = {
	encounters: number?, -- on the critical path
	optionalEncounters: boolean?, -- allow encounters off the critical path
	treasureInDeadEnds: boolean?,
	landmarks: number?,
	minEncounterAreaStuds: number?, -- encounter rooms smaller than this are skipped when possible
	seed: (number | string)?,
}

function Placement.assign(layout, requirements: Requirements)
	local graph = layout.graph
	local rng = Rng.new(requirements.seed or (layout.params and layout.params.seed) or 0):fork("placement")
	local ids = table.clone(graph.order)
	assert(#ids >= 2, "layout needs at least two rooms")

	local areaOf = {}
	local cellArea = if layout.grid then layout.grid.cellSize ^ 2 else 1
	for _, room in layout.rooms or {} do
		areaOf[room.id] = room.w * room.h * cellArea
	end
	local minArea = requirements.minEncounterAreaStuds or 576
	local function roomy(id: string): boolean
		return areaOf[id] == nil or areaOf[id] >= minArea
	end

	-- Spawn candidates: greatest eccentricity first (ties by layout order) so the run
	-- crosses the map.
	local hops, eccentricity, rank = {}, {}, {}
	for index, id in ids do
		hops[id] = graph:distances(id)
		local ecc = 0
		for _, d in hops[id] do
			ecc = math.max(ecc, d)
		end
		eccentricity[id], rank[id] = ecc, index
	end
	local spawnOrder = table.clone(ids)
	table.sort(spawnOrder, function(a, b)
		return if eccentricity[a] == eccentricity[b]
			then rank[a] < rank[b]
			else eccentricity[a] > eccentricity[b]
	end)
	-- Goal: a room that fits an encounter (the goal is the climactic one). Among such pairs,
	-- prefer a critical path with room for the requested encounters, then the longest run;
	-- ties keep the most peripheral spawn and layout order. When the farthest room is roomy
	-- and its path has capacity this is the plain diameter pair. If no room is roomy, fall
	-- back to the farthest room and let Validate report it.
	local requested = requirements.encounters or 2
	local bestSpawn, goal, goalDist, goalCapacity = spawnOrder[1], nil :: string?, -1, -1
	for _, candidate in spawnOrder do
		for _, id in ids do
			local d = hops[candidate][id]
			if id ~= candidate and d and roomy(id) then
				local path = graph:shortestPath(candidate, id) or {}
				local capacity = 0
				for index = 2, #path - 1 do
					if roomy(path[index]) then
						capacity += 1
					end
				end
				capacity = math.min(capacity, requested)
				if capacity > goalCapacity or (capacity == goalCapacity and d > goalDist) then
					bestSpawn, goal, goalDist, goalCapacity = candidate, id, d, capacity
				end
			end
		end
	end
	if goal == nil then
		bestSpawn, goalDist = spawnOrder[1], -1
		for _, id in ids do
			local d = hops[bestSpawn][id]
			if id ~= bestSpawn and d and d > goalDist then
				goal, goalDist = id, d
			end
		end
	end
	local goalId: string = goal or bestSpawn

	local roles: { [string]: string } = { [bestSpawn] = "spawn", [goalId] = "goal" }
	local critical = graph:shortestPath(bestSpawn, goalId) or { bestSpawn, goalId }
	local onCritical = {}
	for _, id in critical do
		onCritical[id] = true
	end

	-- Encounters evenly paced between spawn and goal (exclusive).
	local interior = {}
	for index = 2, #critical - 1 do
		table.insert(interior, critical[index])
	end
	local function fits(id: string): boolean
		return roles[id] == nil and roomy(id)
	end
	local wanted = math.min(requirements.encounters or 2, #interior)
	local unplaced = 0
	for k = 1, wanted do
		local target = math.clamp(math.round(k * (#interior + 1) / (wanted + 1)), 1, #interior)
		-- Nearest free, roomy-enough interior room to the paced target. When none is left the
		-- encounter is reported as unplaced rather than squeezed into a cramped room.
		local chosen = nil
		for offset = 0, #interior do
			for _, index in { target - offset, target + offset } do
				if chosen == nil and interior[index] and fits(interior[index]) then
					chosen = interior[index]
				end
			end
		end
		if chosen then
			roles[chosen] = "encounter"
		else
			unplaced += 1
		end
	end

	-- Dead ends get purpose so no branch is wasted walking. Optional encounters only go
	-- where an encounter fits; cramped dead ends hold treasure.
	if requirements.treasureInDeadEnds ~= false then
		for _, id in graph:deadEnds() do
			if roles[id] == nil then
				roles[id] = if requirements.optionalEncounters
						and rng:chance(0.5)
						and roomy(id)
					then "optional_encounter"
					else "treasure"
			end
		end
	end

	-- Landmarks: highest-degree unassigned hubs, visible orientation points.
	local hubs = {}
	for _, id in ids do
		if roles[id] == nil then
			table.insert(hubs, id)
		end
	end
	table.sort(hubs, function(a, b)
		local da, db = graph:degree(a), graph:degree(b)
		return if da == db then a < b else da > db
	end)
	for index = 1, math.min(requirements.landmarks or 1, #hubs) do
		roles[hubs[index]] = "landmark"
	end

	for _, id in ids do
		roles[id] = roles[id] or "connector"
	end
	return {
		roles = roles,
		spawn = bestSpawn,
		goal = goalId,
		criticalPath = critical,
		unplacedEncounters = unplaced,
	}
end

return Placement
