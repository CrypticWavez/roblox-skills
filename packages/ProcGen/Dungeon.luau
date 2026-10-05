--!strict
-- BSP room layout with MST corridors and a controlled number of extra loops.
-- Output is a Grid plus a room Graph, ready for Placement and Validate.
local Graph = require("./Graph")
local Grid = require("./Grid")
local Rng = require("./Rng")

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
	minLoops: number?, -- guarantee at least this many alternate routes (default 1)
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

local function carveCorridor(grid, a: Room, b: Room, width: number, horizontalFirst: boolean)
	local x1, y1, x2, y2 = a.cx, a.cy, b.cx, b.cy
	local half = math.floor((width - 1) / 2)
	local function hline(xa, xb, y)
		for x = math.min(xa, xb), math.max(xa, xb) do
			grid:fillRect(x, y - half, 1, width, 1)
		end
	end
	local function vline(ya, yb, x)
		for y = math.min(ya, yb), math.max(ya, yb) do
			grid:fillRect(x - half, y, width, 1, 1)
		end
	end
	if horizontalFirst then
		hline(x1, x2, y1)
		vline(y1, y2, x2)
	else
		vline(y1, y2, x1)
		hline(x1, x2, y2)
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
	local corridorRng = rng:fork("corridors")
	local loopRng = rng:fork("loops")
	local loopChance = params.loopChance or 0.15
	-- Loops only between near neighbours so they read as alternate routes, not cross-map tunnels.
	local nearLimit = if #candidates > 0 then candidates[math.max(1, math.floor(#candidates * 0.25))].d else 0
	local corridors = {}
	for _, link in candidates do
		local a, b = rooms[link.i], rooms[link.j]
		local ra, rb = find(link.i), find(link.j)
		local isTree = ra ~= rb
		if isTree or (link.d <= nearLimit and loopRng:chance(loopChance)) then
			if isTree then
				parent[ra] = rb
			end
			carveCorridor(grid, a, b, corridorWidth, corridorRng:chance(0.5))
			graph:addEdge(a.id, b.id)
			table.insert(corridors, { from = a.id, to = b.id, loop = not isTree })
		end
	end

	-- Guarantee redundancy: add the shortest remaining links until minLoops alternates exist.
	local loops = 0
	for _, corridor in corridors do
		if corridor.loop then
			loops += 1
		end
	end
	for _, link in candidates do
		if loops >= (params.minLoops or 1) then
			break
		end
		local a, b = rooms[link.i], rooms[link.j]
		if not graph:hasEdge(a.id, b.id) then
			carveCorridor(grid, a, b, corridorWidth, corridorRng:chance(0.5))
			graph:addEdge(a.id, b.id)
			table.insert(corridors, { from = a.id, to = b.id, loop = true })
			loops += 1
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
		},
		grid = grid,
		rooms = rooms,
		graph = graph,
		corridors = corridors,
	}
end

return Dungeon
