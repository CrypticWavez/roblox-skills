--!strict
-- Settlement planner in stud space: a main road with branching streets, lots fronting
-- the roads, building footprints inside lots, and a plaza landmark. Pure data; SceneKit
-- turns it into roads, buildings and props.
local Graph = require("./Graph")
local Rng = require("./Rng")

local Settlement = {}

export type Params = {
	seed: number | string,
	length: number?, -- studs along main road
	streets: number?, -- side streets
	roadWidth: number?,
	lotDepth: number?,
	lotWidth: { number }?, -- {min, max}
	setback: number?, -- gap between road edge and building
}

export type Lot = {
	id: string,
	road: string,
	x: number,
	z: number,
	w: number,
	d: number,
	facing: number,
	footprint: { x: number, z: number, w: number, d: number },
}

function Settlement.generate(params: Params)
	local rng = Rng.new(params.seed)
	local length = params.length or 240
	local roadWidth = params.roadWidth or 16
	local lotDepth = params.lotDepth or 32
	local lotWidth = params.lotWidth or { 20, 32 }
	local setback = params.setback or 4
	local roads = {}
	local graph = Graph.new()

	-- Main road along +X, centred on z = 0.
	table.insert(roads, { id = "main", from = { -length / 2, 0 }, to = { length / 2, 0 }, width = roadWidth })
	local junctions = {}
	local streetCount = params.streets or 3
	local streetRng = rng:fork("streets")
	graph:addNode("main_w", "road_end")
	graph:addNode("main_e", "road_end")
	local previous = "main_w"
	for index = 1, streetCount do
		local x = -length / 2 + length * index / (streetCount + 1) + streetRng:range(-8, 8)
		x = math.round(x / 4) * 4
		local side = if index % 2 == 1 then 1 else -1
		local streetLength = streetRng:int(6, 12) * 8
		local id = "street" .. index
		table.insert(roads, {
			id = id,
			from = { x, side * roadWidth / 2 },
			to = { x, side * (roadWidth / 2 + streetLength) },
			width = roadWidth * 0.75,
		})
		local junction = "junction" .. index
		graph:addNode(junction, "junction")
		graph:addNode(id .. "_end", "road_end")
		graph:addEdge(previous, junction)
		graph:addEdge(junction, id .. "_end")
		previous = junction
		table.insert(junctions, { id = junction, x = x, z = 0 })
	end
	graph:addEdge(previous, "main_e")

	-- Lots along each road side, skipping road/street corridors and each other.
	local lots: { Lot } = {}
	local occupied: { { number } } = {}
	local function overlaps(x, z, w, d)
		for _, rect in occupied do
			if x < rect[1] + rect[3] and rect[1] < x + w and z < rect[2] + rect[4] and rect[2] < z + d then
				return true
			end
		end
		return false
	end
	for _, road in roads do
		local horizontal = road.from[2] == road.to[2]
		table.insert(
			occupied,
			if horizontal
				then {
					math.min(road.from[1], road.to[1]),
					road.from[2] - road.width / 2,
					math.abs(road.to[1] - road.from[1]),
					road.width,
				}
				else {
					road.from[1] - road.width / 2,
					math.min(road.from[2], road.to[2]),
					road.width,
					math.abs(road.to[2] - road.from[2]),
				}
		)
	end
	local lotRng = rng:fork("lots")
	for _, road in roads do
		local horizontal = road.from[2] == road.to[2]
		local startAlong = if horizontal
			then math.min(road.from[1], road.to[1])
			else math.min(road.from[2], road.to[2])
		local endAlong = if horizontal
			then math.max(road.from[1], road.to[1])
			else math.max(road.from[2], road.to[2])
		for _, side in { -1, 1 } do
			local along = startAlong + 2
			while true do
				local w = lotRng:int(lotWidth[1], lotWidth[2])
				if along + w > endAlong then
					break
				end
				local x, z, lw, ld
				if horizontal then
					x, lw, ld = along, w, lotDepth
					z = if side > 0
						then road.from[2] + road.width / 2
						else road.from[2] - road.width / 2 - lotDepth
				else
					z, lw, ld = along, lotDepth, w
					x = if side > 0
						then road.from[1] + road.width / 2
						else road.from[1] - road.width / 2 - lotDepth
				end
				if not overlaps(x, z, lw, ld) then
					table.insert(occupied, { x, z, lw, ld })
					local fw = if horizontal then lw - 4 else lw - setback - 4
					local fd = if horizontal then ld - setback - 4 else ld - 4
					local fx = if horizontal then x + 2 elseif side > 0 then x + setback else x + 4
					local fz = if not horizontal then z + 2 elseif side > 0 then z + setback else z + 4
					-- Yaw that turns a building whose front faces -Z toward this lot's road.
					local facing = if horizontal
						then (if side > 0 then 0 else 180)
						else (if side > 0 then 90 else 270)
					table.insert(lots, {
						id = string.format("L%02d", #lots + 1),
						road = road.id,
						x = x,
						z = z,
						w = lw,
						d = ld,
						facing = facing,
						footprint = { x = fx, z = fz, w = fw, d = fd },
					})
				end
				along += w + lotRng:int(0, 1) * 4
			end
		end
	end

	-- Plaza landmark at the central junction.
	local plaza = junctions[math.max(1, math.ceil(#junctions / 2))]
	return {
		kind = "settlement",
		params = {
			seed = params.seed,
			length = length,
			roadWidth = roadWidth,
			lotDepth = lotDepth,
			streets = streetCount,
		},
		roads = roads,
		lots = lots,
		graph = graph,
		landmark = plaza and { x = plaza.x, z = plaza.z, id = plaza.id } or nil,
	}
end

return Settlement
