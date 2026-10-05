--!strict
-- Assigns gameplay roles to a room layout from requirements rather than at random:
-- spawn on the periphery, goal farthest away, encounters paced along the critical path,
-- every dead end given a purpose (treasure/optional), landmarks at hubs.
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

	-- Spawn: node with greatest eccentricity (ties by id) so the run crosses the map.
	local bestSpawn, bestEcc = ids[1], -1
	for _, id in ids do
		local ecc = 0
		for _, d in graph:distances(id) do
			ecc = math.max(ecc, d)
		end
		if ecc > bestEcc then
			bestSpawn, bestEcc = id, ecc
		end
	end
	local fromSpawn = graph:distances(bestSpawn)
	local goal, goalDist = bestSpawn, -1
	for _, id in ids do
		local d = fromSpawn[id]
		if d and d > goalDist then
			goal, goalDist = id, d
		end
	end

	local roles: { [string]: string } = { [bestSpawn] = "spawn", [goal] = "goal" }
	local critical = graph:shortestPath(bestSpawn, goal) or { bestSpawn, goal }
	local onCritical = {}
	for _, id in critical do
		onCritical[id] = true
	end

	-- Encounters evenly paced between spawn and goal (exclusive).
	local interior = {}
	for index = 2, #critical - 1 do
		table.insert(interior, critical[index])
	end
	local areaOf = {}
	local cellArea = if layout.grid then layout.grid.cellSize ^ 2 else 1
	for _, room in layout.rooms or {} do
		areaOf[room.id] = room.w * room.h * cellArea
	end
	local minArea = requirements.minEncounterAreaStuds or 576
	local function fits(id: string): boolean
		return roles[id] == nil and (areaOf[id] == nil or areaOf[id] >= minArea)
	end
	local wanted = math.min(requirements.encounters or 2, #interior)
	for k = 1, wanted do
		local target = math.clamp(math.round(k * (#interior + 1) / (wanted + 1)), 1, #interior)
		-- Nearest roomy-enough interior room to the paced target; fall back to the target.
		local chosen = nil
		for offset = 0, #interior do
			for _, index in { target - offset, target + offset } do
				if chosen == nil and interior[index] and fits(interior[index]) then
					chosen = interior[index]
				end
			end
		end
		chosen = chosen or interior[target]
		if roles[chosen] == nil then
			roles[chosen] = "encounter"
		end
	end

	-- Dead ends get purpose so no branch is wasted walking.
	if requirements.treasureInDeadEnds ~= false then
		for _, id in graph:deadEnds() do
			if roles[id] == nil then
				roles[id] = if requirements.optionalEncounters and rng:chance(0.5)
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
	return { roles = roles, spawn = bestSpawn, goal = goal, criticalPath = critical }
end

return Placement
