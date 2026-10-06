--!strict
-- BSP room layout with MST corridors and a controlled number of extra loops.
-- Output is a Grid plus a room Graph, ready for Placement and Validate.
-- Loop links are kept only when their carve raises the walkable loop count measured on the
-- grid (RoomGraph), so every loop edge in the room Graph is a route a player can walk around
-- a real wall, not a pillar inside one wide passage.
local Graph = require("./Graph")
local Grid = require("./Grid")
local Rng = require("./Rng")
local RoomGraph = require("./RoomGraph")

local Dungeon = {}

export type Room = { id: string, x: number, y: number, w: number, h: number, cx: number, cy: number }
export type Params = {
	seed: number | string,
	width: number?, -- cells
	height: number?,
	cellSize: number?, -- studs per cell
	minRoom: number?, -- cells
	maxRoom: number?,
	corridorWidth: number?, -- cells
	loopChance: number?, -- fraction of non-tree neighbour links kept as loops
	maxDepth: number?,
	minLoops: number?, -- guarantee at least this many walkable loops on the grid (default 1)
	minLoopWallStuds: number?, -- wall a loop must wrap, square studs (default RoomGraph's 144)
}

local function split(rng, rect, depth, maxDepth, minLeaf, out)
	local canH = rect.h >= minLeaf * 2
	local canV = rect.w >= minLeaf * 2
	if depth >= maxDepth or (not canH and not canV) then
		table.insert(out, rect)
		return
	end
	local horizontal = if canH and canV
		then (if rect.h > rect.w then true elseif rect.w > rect.h then false else rng:chance(0.5))
		else canH
	if horizontal then
		local cut = rng:int(minLeaf, rect.h - minLeaf)
		split(rng, { x = rect.x, y = rect.y, w = rect.w, h = cut }, depth + 1, maxDepth, minLeaf, out)
		split(
			rng,
			{ x = rect.x, y = rect.y + cut, w = rect.w, h = rect.h - cut },
			depth + 1,
			maxDepth,
			minLeaf,
			out
		)
	else
		local cut = rng:int(minLeaf, rect.w - minLeaf)
		split(rng, { x = rect.x, y = rect.y, w = cut, h = rect.h }, depth + 1, maxDepth, minLeaf, out)
		split(
			rng,
			{ x = rect.x + cut, y = rect.y, w = rect.w - cut, h = rect.h },
			depth + 1,
			maxDepth,
			minLeaf,
			out
		)
	end
end

-- Cell keys an L-shaped corridor between room centres covers (in bounds; may repeat).
local function corridorCells(grid, a: Room, b: Room, width: number, horizontalFirst: boolean): { number }
	local x1, y1, x2, y2 = a.cx, a.cy, b.cx, b.cy
	local half = math.floor((width - 1) / 2)
	local keys = {}
	local function add(x, y)
		if grid:inBounds(x, y) then
			table.insert(keys, (y - 1) * grid.width + x)
		end
	end
	local function hline(xa, xb, y)
		for x = math.min(xa, xb), math.max(xa, xb) do
			for offset = 0, width - 1 do
				add(x, y - half + offset)
			end
		end
	end
	local function vline(ya, yb, x)
		for y = math.min(ya, yb), math.max(ya, yb) do
			for offset = 0, width - 1 do
				add(x - half + offset, y)
			end
		end
	end
	if horizontalFirst then
		hline(x1, x2, y1)
		vline(y1, y2, x2)
	else
		vline(y1, y2, x1)
		hline(x1, x2, y2)
	end
	return keys
end

local function carveCorridor(grid, a: Room, b: Room, width: number, horizontalFirst: boolean)
	for _, key in corridorCells(grid, a, b, width, horizontalFirst) do
		grid.cells[key] = 1
	end
end

function Dungeon.generate(params: Params)
	local rng = Rng.new(params.seed)
	local width, height = params.width or 48, params.height or 48
	local minRoom, maxRoom = params.minRoom or 4, params.maxRoom or 10
	local corridorWidth = params.corridorWidth or 2
	local grid = Grid.new(width, height, params.cellSize or 4, 0)
	local leaves = {}
	split(
		rng:fork("bsp"),
		{ x = 2, y = 2, w = width - 2, h = height - 2 },
		0,
		params.maxDepth or 4,
		minRoom + 2,
		leaves
	)

	local rooms: { Room } = {}
	local roomRng = rng:fork("rooms")
	for index, leaf in leaves do
		local w = math.min(roomRng:int(minRoom, maxRoom), leaf.w - 1)
		local h = math.min(roomRng:int(minRoom, maxRoom), leaf.h - 1)
		local x = leaf.x + roomRng:int(0, leaf.w - 1 - w)
		local y = leaf.y + roomRng:int(0, leaf.h - 1 - h)
		-- math.floor rather than // here: StyLua 2.5.2 panics formatting // inside a long table field.
		local cx, cy = x + math.floor(w / 2), y + math.floor(h / 2)
		local room = { id = string.format("R%02d", index), x = x, y = y, w = w, h = h, cx = cx, cy = cy }
		grid:fillRect(x, y, w, h, 1)
		table.insert(rooms, room)
	end

	-- Candidate links: every pair, weighted by center distance; Kruskal MST + loop extras.
	local candidates = {}
	for i = 1, #rooms do
		for j = i + 1, #rooms do
			local a, b = rooms[i], rooms[j]
			table.insert(candidates, { i = i, j = j, d = math.abs(a.cx - b.cx) + math.abs(a.cy - b.cy) })
		end
	end
	table.sort(candidates, function(p, q)
		return if p.d == q.d then p.i * 1000 + p.j < q.i * 1000 + q.j else p.d < q.d
	end)
	local parent = {}
	for i = 1, #rooms do
		parent[i] = i
	end
	local function find(i)
		while parent[i] ~= i do
			parent[i] = parent[parent[i]]
			i = parent[i]
		end
		return i
	end

	local graph = Graph.new()
	for _, room in rooms do
		graph:addNode(room.id, "room", { area = room.w * room.h })
	end
	local owner = RoomGraph.roomCells(grid, rooms)
	local minWallCells = RoomGraph.minWallCells(grid, params.minLoopWallStuds)
	local function walkableLoops(): number
		return RoomGraph.loops(grid, rooms, owner, minWallCells)
	end
	-- A loop link must add a walkable alternate route. Try the preferred bend, then the
	-- other; keep a carve only if it adds floor, crosses no third room and raises the grid's
	-- loop count. Otherwise restore the grid and report failure (no graph edge is added).
	local function carveLoop(a: Room, b: Room, horizontalFirst: boolean): boolean
		local before = walkableLoops()
		for _, bend in { horizontalFirst, not horizontalFirst } do
			local keys = corridorCells(grid, a, b, corridorWidth, bend)
			local fresh, crossesRoom = 0, false
			for _, key in keys do
				local inside = owner[key]
				if inside ~= nil and inside ~= a.id and inside ~= b.id then
					crossesRoom = true
				elseif grid.cells[key] == 0 then
					fresh += 1
				end
			end
			if fresh > 0 and not crossesRoom then
				local saved = table.clone(grid.cells)
				for _, key in keys do
					grid.cells[key] = 1
				end
				if walkableLoops() > before then
					return true
				end
				grid.cells = saved
			end
		end
		return false
	end

	local corridorRng = rng:fork("corridors")
	local loopRng = rng:fork("loops")
	local loopChance = params.loopChance or 0.15
	-- Loops only between near neighbours so they read as alternate routes, not cross-map tunnels.
	local nearLimit = if #candidates > 0 then candidates[math.max(1, math.floor(#candidates * 0.25))].d else 0
	local corridors = {}
	for _, link in candidates do
		local a, b = rooms[link.i], rooms[link.j]
		local ra, rb = find(link.i), find(link.j)
		if ra ~= rb then
			parent[ra] = rb
			carveCorridor(grid, a, b, corridorWidth, corridorRng:chance(0.5))
			graph:addEdge(a.id, b.id)
			table.insert(corridors, { from = a.id, to = b.id, loop = false })
		elseif link.d <= nearLimit and loopRng:chance(loopChance) then
			if carveLoop(a, b, corridorRng:chance(0.5)) then
				graph:addEdge(a.id, b.id)
				table.insert(corridors, { from = a.id, to = b.id, loop = true })
			end
		end
	end

	-- Guarantee redundancy on the grid: try the shortest remaining links until minLoops
	-- walkable loops exist (Validate.rooms measures the same thing).
	local minLoops = params.minLoops or 1
	for _, link in candidates do
		if walkableLoops() >= minLoops then
			break
		end
		local a, b = rooms[link.i], rooms[link.j]
		if not graph:hasEdge(a.id, b.id) and carveLoop(a, b, corridorRng:chance(0.5)) then
			graph:addEdge(a.id, b.id)
			table.insert(corridors, { from = a.id, to = b.id, loop = true })
		end
	end

	return {
		kind = "dungeon",
		params = {
			seed = params.seed,
			width = width,
			height = height,
			cellSize = grid.cellSize,
			minRoom = minRoom,
			maxRoom = maxRoom,
			corridorWidth = corridorWidth,
			loopChance = loopChance,
			-- Recorded only when set (nil keeps default manifests unchanged).
			minLoops = params.minLoops,
			minLoopWallStuds = params.minLoopWallStuds,
		},
		grid = grid,
		rooms = rooms,
		graph = graph,
		corridors = corridors,
	}
end

return Dungeon
