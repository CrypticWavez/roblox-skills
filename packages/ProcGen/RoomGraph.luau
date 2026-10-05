--!strict
-- Walkable topology of a carved room layout. Nodes are the room rectangles plus every
-- 4-connected corridor component (floor outside all rooms); edges join nodes whose floor
-- cells touch. Its cycle rank counts loops a player can actually walk, whereas a layout's
-- abstract room graph only records the links the generator meant to carve.
local Graph = require("./Graph")

local RoomGraph = {}

export type Room = { id: string, x: number, y: number, w: number, h: number }

local OFFSETS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- Cell key -> room id for every in-bounds cell of a room rectangle. Keys match Grid:
-- (y - 1) * width + x.
function RoomGraph.roomCells(grid, rooms: { Room }): { [number]: string }
	local owner: { [number]: string } = {}
	for _, room in rooms do
		for y = room.y, room.y + room.h - 1 do
			for x = room.x, room.x + room.w - 1 do
				if grid:inBounds(x, y) then
					owner[(y - 1) * grid.width + x] = room.id
				end
			end
		end
	end
	return owner
end

-- Room/corridor adjacency graph built from the grid's floor cells. Corridor nodes are
-- named "~corridor<n>" in scan order; pass `owner` (from roomCells) to skip recomputing it.
function RoomGraph.build(grid, rooms: { Room }, owner: { [number]: string }?): Graph.Graph
	local roomOf = owner or RoomGraph.roomCells(grid, rooms)
	local width, height = grid.width, grid.height
	local graph = Graph.new()
	for _, room in rooms do
		graph:addNode(room.id, "room")
	end
	local function floor(x: number, y: number): boolean
		return x >= 1 and y >= 1 and x <= width and y <= height and grid.cells[(y - 1) * width + x] ~= 0
	end
	local nodeAt: { [number]: string } = {}
	local corridors = 0
	for y = 1, height do
		for x = 1, width do
			local key = (y - 1) * width + x
			if floor(x, y) and roomOf[key] == nil and nodeAt[key] == nil then
				corridors += 1
				local id = "~corridor" .. corridors
				graph:addNode(id, "corridor")
				nodeAt[key] = id
				local stack = { { x, y } }
				while #stack > 0 do
					local cell = table.remove(stack) :: { number }
					for _, o in OFFSETS do
						local nx, ny = cell[1] + o[1], cell[2] + o[2]
						local nkey = (ny - 1) * width + nx
						if floor(nx, ny) and roomOf[nkey] == nil and nodeAt[nkey] == nil then
							nodeAt[nkey] = id
							table.insert(stack, { nx, ny })
						end
					end
				end
			end
		end
	end
	-- Right and down neighbours cover every touching pair once.
	for y = 1, height do
		for x = 1, width do
			if floor(x, y) then
				local key = (y - 1) * width + x
				local me = roomOf[key] or nodeAt[key]
				for _, o in { { 1, 0 }, { 0, 1 } } do
					local nx, ny = x + o[1], y + o[2]
					if floor(nx, ny) then
						local nkey = (ny - 1) * width + nx
						local other = roomOf[nkey] or nodeAt[nkey]
						if other ~= me then
							graph:addEdge(me, other)
						end
					end
				end
			end
		end
	end
	return graph
end

-- Independent loops a player can walk: cycle rank of the room/corridor graph.
function RoomGraph.loops(grid, rooms: { Room }, owner: { [number]: string }?): number
	return RoomGraph.build(grid, rooms, owner):cycleRank()
end

return RoomGraph
