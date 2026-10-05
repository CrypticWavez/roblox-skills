--!strict
-- Walkable topology of a carved room layout. Nodes are the room rectangles plus every
-- 4-connected corridor component (floor outside all rooms); edges join nodes whose floor
-- cells touch. Its cycle rank counts loops a player can actually walk, whereas a layout's
-- abstract room graph only records the links the generator meant to carve.
-- A loop only counts as an alternate route when it encloses a real wall mass: enclosed wall
-- pockets smaller than `minWallCells` (a pillar splitting one wide passage) are treated as
-- floor before the graph is built.
local Graph = require("./Graph")

local RoomGraph = {}

export type Room = { id: string, x: number, y: number, w: number, h: number }

local OFFSETS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- Smallest wall a loop must wrap, in square studs: one minimum room footprint (12 x 12, the
-- Validate minRoomStuds side). Seed 35's old loop wrapped a 4x1-cell (16 x 4 stud) pillar.
RoomGraph.MIN_LOOP_WALL_STUDS = 144

-- Wall cells (0) that are not 8-connected to the grid edge, grouped into pockets of cell
-- keys. Floor is 4-connected, so its complement is 8-connected: every pocket is a hole that
-- a floor loop wraps.
function RoomGraph.pockets(grid): { { number } }
	local width, height, cells = grid.width, grid.height, grid.cells
	local seen: { [number]: boolean } = {}
	local result = {}
	local stack: { number } = {}
	for start = 1, width * height do
		if cells[start] == 0 and not seen[start] then
			seen[start] = true
			local keys, edge = {}, false
			stack[1] = start
			local top = 1
			while top > 0 do
				local key = stack[top]
				top -= 1
				table.insert(keys, key)
				local x, y = (key - 1) % width + 1, (key - 1) // width + 1
				if x == 1 or y == 1 or x == width or y == height then
					edge = true
				end
				for dy = -1, 1 do
					if y + dy >= 1 and y + dy <= height then
						for dx = -1, 1 do
							local nkey = key + dy * width + dx
							if x + dx >= 1 and x + dx <= width and cells[nkey] == 0 and not seen[nkey] then
								seen[nkey] = true
								top += 1
								stack[top] = nkey
							end
						end
					end
				end
			end
			if not edge then
				table.insert(result, keys)
			end
		end
	end
	return result
end

-- Cells in pockets under `minWallCells`, as a key set (empty when minWallCells <= 1).
local function pillarCells(grid, minWallCells: number?): { [number]: boolean }
	local filled = {}
	if (minWallCells or 0) > 1 then
		for _, keys in RoomGraph.pockets(grid) do
			if #keys < (minWallCells :: number) then
				for _, key in keys do
					filled[key] = true
				end
			end
		end
	end
	return filled
end

-- Default pocket size in cells for a grid: MIN_LOOP_WALL_STUDS over the cell area.
function RoomGraph.minWallCells(grid, minWallStuds: number?): number
	return math.ceil((minWallStuds or RoomGraph.MIN_LOOP_WALL_STUDS) / grid.cellSize ^ 2)
end

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
-- Wall pockets smaller than `minWallCells` count as floor (default 0: pure topology).
function RoomGraph.build(
	grid,
	rooms: { Room },
	owner: { [number]: string }?,
	minWallCells: number?
): Graph.Graph
	local roomOf = owner or RoomGraph.roomCells(grid, rooms)
	local width, height = grid.width, grid.height
	local graph = Graph.new()
	for _, room in rooms do
		graph:addNode(room.id, "room")
	end
	local pillar = pillarCells(grid, minWallCells)
	local cells = grid.cells
	local function floor(key: number): boolean
		return cells[key] ~= 0 or pillar[key] == true
	end
	local nodeAt: { [number]: string } = {}
	local corridors = 0
	local stack: { number } = {}
	for start = 1, width * height do
		if floor(start) and roomOf[start] == nil and nodeAt[start] == nil then
			corridors += 1
			local id = "~corridor" .. corridors
			graph:addNode(id, "corridor")
			nodeAt[start] = id
			stack[1] = start
			local top = 1
			while top > 0 do
				local key = stack[top]
				top -= 1
				local x, y = (key - 1) % width + 1, (key - 1) // width + 1
				for _, o in OFFSETS do
					local nx, ny = x + o[1], y + o[2]
					local nkey = key + o[2] * width + o[1]
					if
						nx >= 1
						and ny >= 1
						and nx <= width
						and ny <= height
						and floor(nkey)
						and roomOf[nkey] == nil
						and nodeAt[nkey] == nil
					then
						nodeAt[nkey] = id
						top += 1
						stack[top] = nkey
					end
				end
			end
		end
	end
	-- Right and down neighbours cover every touching pair once.
	for y = 1, height do
		for x = 1, width do
			local key = (y - 1) * width + x
			if floor(key) then
				local me = roomOf[key] or nodeAt[key]
				for _, nkey in { if x < width then key + 1 else 0, if y < height then key + width else 0 } do
					if nkey > 0 and floor(nkey) then
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

-- Independent loops a player can walk around a real wall: cycle rank of the room/corridor
-- graph once pillars (pockets under `minWallCells`, default RoomGraph.minWallCells(grid))
-- are filled. Pass 0 for the pure topological count.
function RoomGraph.loops(grid, rooms: { Room }, owner: { [number]: string }?, minWallCells: number?): number
	return RoomGraph.build(grid, rooms, owner, minWallCells or RoomGraph.minWallCells(grid)):cycleRank()
end

return RoomGraph
