--!strict
-- Cellular-automata caves. Keeps the largest region and tunnels orphan regions back in,
-- so the result is always one connected walkable space.
local Grid = require("./Grid")
local Rng = require("./Rng")

local Cave = {}

export type Params = {
	seed: number | string,
	width: number?,
	height: number?,
	cellSize: number?,
	fill: number?, -- initial solid probability
	steps: number?,
	minRegion: number?, -- regions smaller than this are filled instead of connected
}

local function solidNeighbours(grid, x, y)
	local count = 0
	for dy = -1, 1 do
		for dx = -1, 1 do
			if (dx ~= 0 or dy ~= 0) and grid:get(x + dx, y + dy) == 0 then
				count += 1
			end
		end
	end
	return count
end

function Cave.generate(params: Params)
	local rng = Rng.new(params.seed)
	local width, height = params.width or 64, params.height or 48
	local grid = Grid.new(width, height, params.cellSize or 8, 0)
	local fill = params.fill or 0.45
	for y = 2, height - 1 do
		for x = 2, width - 1 do
			grid:set(x, y, if rng:chance(fill) then 0 else 1)
		end
	end
	for _ = 1, params.steps or 5 do
		local nextCells = table.clone(grid.cells)
		for y = 2, height - 1 do
			for x = 2, width - 1 do
				local solid = solidNeighbours(grid, x, y)
				nextCells[(y - 1) * width + x] = if solid >= 5
					then 0
					elseif solid <= 3 then 1
					else grid:get(x, y)
			end
		end
		grid.cells = nextCells
	end

	local regions = grid:regions()
	local minRegion = params.minRegion or 12
	local main = regions[1]
	local tunnels = 0
	for index = 2, #regions do
		local region = regions[index]
		if #region < minRegion then
			for _, cell in region do
				grid:set(cell[1], cell[2], 0)
			end
		elseif main then
			-- Straight two-wide tunnel from region's first cell to nearest main-region cell.
			local from = region[1]
			local best, bestD = main[1], math.huge
			for _, cell in main do
				local d = math.abs(cell[1] - from[1]) + math.abs(cell[2] - from[2])
				if d < bestD then
					best, bestD = cell, d
				end
			end
			local x, y = from[1], from[2]
			while x ~= best[1] or y ~= best[2] do
				if x ~= best[1] then
					x += if best[1] > x then 1 else -1
				else
					y += if best[2] > y then 1 else -1
				end
				grid:fillRect(x, y, 2, 2, 1)
			end
			tunnels += 1
		end
	end
	return {
		kind = "cave",
		params = { seed = params.seed, width = width, height = height, cellSize = grid.cellSize, fill = fill },
		grid = grid,
		tunnels = tunnels,
	}
end

return Cave
