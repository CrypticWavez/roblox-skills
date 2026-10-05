--!strict
-- Cell grid used by layout generators. 0 = solid, 1 = floor; extra layers hold labels.
local Grid = {}
Grid.__index = Grid

export type Grid = typeof(setmetatable(
	{} :: { width: number, height: number, cellSize: number, cells: { number }, labels: { [number]: string } },
	Grid
))

function Grid.new(width: number, height: number, cellSize: number?, fill: number?): Grid
	assert(width >= 1 and height >= 1 and width * height <= 1_000_000, "grid size out of range")
	local cells = table.create(width * height, fill or 0)
	return setmetatable(
		{ width = width, height = height, cellSize = cellSize or 4, cells = cells, labels = {} },
		Grid
	)
end

function Grid.inBounds(self: Grid, x: number, y: number): boolean
	return x >= 1 and y >= 1 and x <= self.width and y <= self.height
end

function Grid.get(self: Grid, x: number, y: number): number
	if not self:inBounds(x, y) then
		return 0
	end
	return self.cells[(y - 1) * self.width + x]
end

function Grid.set(self: Grid, x: number, y: number, value: number)
	if self:inBounds(x, y) then
		self.cells[(y - 1) * self.width + x] = value
	end
end

function Grid.fillRect(self: Grid, x: number, y: number, w: number, h: number, value: number)
	for cy = y, y + h - 1 do
		for cx = x, x + w - 1 do
			self:set(cx, cy, value)
		end
	end
end

function Grid.label(self: Grid, x: number, y: number, label: string)
	self.labels[(y - 1) * self.width + x] = label
end

function Grid.labelAt(self: Grid, x: number, y: number): string?
	return self.labels[(y - 1) * self.width + x]
end

function Grid.count(self: Grid, value: number): number
	local total = 0
	for _, cell in self.cells do
		if cell == value then
			total += 1
		end
	end
	return total
end

local OFFSETS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
Grid.OFFSETS = OFFSETS

-- Cells a point in cell coordinates covers: its own cell, or, when a coordinate is a .5
-- cell boundary (the true centre of an even-sized grid), the 2 or 2x2 cells around it.
function Grid.cellsCovering(point: { number }): { { number } }
	local cells = {}
	local xs = { math.floor(point[1]) }
	if math.ceil(point[1]) ~= xs[1] then
		table.insert(xs, math.ceil(point[1]))
	end
	local ys = { math.floor(point[2]) }
	if math.ceil(point[2]) ~= ys[1] then
		table.insert(ys, math.ceil(point[2]))
	end
	for _, y in ys do
		for _, x in xs do
			table.insert(cells, { x, y })
		end
	end
	return cells
end

-- 4-connected floor regions, largest first.
function Grid.regions(self: Grid): { { { number } } }
	local seen: { [number]: boolean } = {}
	local regions = {}
	for y = 1, self.height do
		for x = 1, self.width do
			local key = (y - 1) * self.width + x
			if self.cells[key] ~= 0 and not seen[key] then
				local region, stack = {}, { { x, y } }
				seen[key] = true
				while #stack > 0 do
					local cell = table.remove(stack) :: { number }
					table.insert(region, cell)
					for _, offset in OFFSETS do
						local nx, ny = cell[1] + offset[1], cell[2] + offset[2]
						local nkey = (ny - 1) * self.width + nx
						if self:inBounds(nx, ny) and self.cells[nkey] ~= 0 and not seen[nkey] then
							seen[nkey] = true
							table.insert(stack, { nx, ny })
						end
					end
				end
				table.insert(regions, region)
			end
		end
	end
	table.sort(regions, function(a, b)
		return #a > #b
	end)
	return regions
end

-- BFS step distance between floor cells; nil when unreachable.
function Grid.walkDistance(self: Grid, from: { number }, to: { number }): number?
	if self:get(from[1], from[2]) == 0 or self:get(to[1], to[2]) == 0 then
		return nil
	end
	local dist = { [(from[2] - 1) * self.width + from[1]] = 0 }
	local queue, head = { from }, 1
	local goal = (to[2] - 1) * self.width + to[1]
	while head <= #queue do
		local cell = queue[head]
		head += 1
		local key = (cell[2] - 1) * self.width + cell[1]
		if key == goal then
			return dist[key]
		end
		for _, offset in OFFSETS do
			local nx, ny = cell[1] + offset[1], cell[2] + offset[2]
			local nkey = (ny - 1) * self.width + nx
			if self:get(nx, ny) ~= 0 and dist[nkey] == nil then
				dist[nkey] = dist[key] + 1
				table.insert(queue, { nx, ny })
			end
		end
	end
	return nil
end

-- Narrowest clear width (in cells) of floor at a cell: min of horizontal and vertical runs.
function Grid.clearWidth(self: Grid, x: number, y: number): number
	if self:get(x, y) == 0 then
		return 0
	end
	local function run(dx: number, dy: number): number
		local length = 1
		local cx, cy = x + dx, y + dy
		while self:get(cx, cy) ~= 0 do
			length += 1
			cx += dx
			cy += dy
		end
		cx, cy = x - dx, y - dy
		while self:get(cx, cy) ~= 0 do
			length += 1
			cx -= dx
			cy -= dy
		end
		return length
	end
	return math.min(run(1, 0), run(0, 1))
end

function Grid.toAscii(self: Grid): string
	local lines = {}
	for y = 1, self.height do
		local row = table.create(self.width, "#")
		for x = 1, self.width do
			local label = self:labelAt(x, y)
			row[x] = if label then string.sub(label, 1, 1) elseif self:get(x, y) ~= 0 then "." else "#"
		end
		table.insert(lines, table.concat(row))
	end
	return table.concat(lines, "\n")
end

return Grid
