--!strict
-- @tier T0
-- PlacementGrid: footprints on a cell grid for building, tycoon and tower-defence placement.
-- Items come from definitions { [key] = { size = { w, d }, tags? } } (cells along X and Z); an
-- item sits at an anchor cell (its footprint's minimum corner after rotation) with a rotation of
-- 0, 90, 180 or 270 degrees (90 and 270 swap w and d). canPlace explains a refusal with one
-- reason: unknown_item, bad_rotation, out_of_bounds, blocked, not_allowed, occupied, duplicate_id.
-- Cells are 1-based { x, y }; world positions use origin (the grid's minimum corner) and cellSize
-- in studs on the X/Z plane. serialize() gives placement/1 plain data for a key store;
-- PlacementGrid.restore(data, definitions, options) rebuilds a grid and reports bad records.
local Check = require("./Check")

local PlacementGrid = {}
PlacementGrid.FORMAT = "placement/1"
PlacementGrid.ROTATIONS = table.freeze({ 0, 90, 180, 270 })

export type Cell = { x: number, y: number }
export type Definition = { size: { number }, tags: { string }? }
export type Options = {
	width: number,
	height: number,
	cellSize: number?, -- studs (default 4)
	origin: { x: number, z: number }?, -- world X/Z of the grid's minimum corner (default 0, 0)
	blocked: { Cell }?, -- cells nothing may cover (paths, decorations)
	allowed: ((cell: Cell, key: string, definition: Definition) -> boolean)?, -- zone rules (plots, lanes)
}
export type Item = { id: string, key: string, x: number, y: number, rotation: number }

local Grid = {}
Grid.__index = Grid

export type PlacementGrid = typeof(setmetatable(
	{} :: {
		width: number,
		height: number,
		cellSize: number,
		origin: { x: number, z: number },
		definitions: { [string]: Definition },
		items: { [string]: Item },
		cells: { [number]: string },
		blocked: { [number]: boolean },
		allowed: ((Cell, string, Definition) -> boolean)?,
	},
	Grid
))

local function cellKey(x: number, y: number): number
	return y * 65536 + x
end

-- Problems with definitions and options (empty when valid).
function PlacementGrid.validate(definitions: any, options: any): { string }
	local problems = {}
	if type(options) ~= "table" then
		return { "options must be a table" }
	end
	for _, key in { "width", "height" } do
		local value = options[key]
		if not Check.integer(value) or value < 1 or value > 4096 then
			table.insert(problems, key .. " must be an integer in [1, 4096]")
		end
	end
	if options.cellSize ~= nil and (not Check.finite(options.cellSize) or options.cellSize <= 0) then
		table.insert(problems, "cellSize must be a finite number > 0")
	end
	if type(definitions) ~= "table" then
		table.insert(problems, "definitions must be a table keyed by item key")
		return problems
	end
	local keys = {}
	for key in definitions do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	for _, key in keys do
		local def = definitions[key]
		if not Check.label(key) then
			table.insert(problems, "definition key " .. tostring(key) .. " must be a label")
		end
		local size = type(def) == "table" and def.size
		if
			type(size) ~= "table"
			or not Check.integer(size[1])
			or not Check.integer(size[2])
			or size[1] < 1
			or size[2] < 1
		then
			table.insert(
				problems,
				"definition " .. tostring(key) .. " size must be { w, d } whole cells >= 1"
			)
		end
	end
	return problems
end

function PlacementGrid.new(definitions: { [string]: Definition }, options: Options): PlacementGrid
	local problems = PlacementGrid.validate(definitions, options)
	if #problems > 0 then
		error("PlacementGrid.new: " .. table.concat(problems, "; "), 2)
	end
	local blocked = {}
	for _, cell in options.blocked or {} do
		blocked[cellKey(cell.x, cell.y)] = true
	end
	return setmetatable({
		width = options.width,
		height = options.height,
		cellSize = options.cellSize or 4,
		origin = options.origin or { x = 0, z = 0 },
		definitions = definitions,
		items = {},
		cells = {},
		blocked = blocked,
		allowed = options.allowed,
	}, Grid)
end

-- Footprint size { w, d } after rotation.
function PlacementGrid.rotatedSize(definition: Definition, rotation: number): (number, number)
	if rotation == 90 or rotation == 270 then
		return definition.size[2], definition.size[1]
	end
	return definition.size[1], definition.size[2]
end

-- Cells an item would cover (anchor = minimum corner), in row order.
function Grid.footprint(self: PlacementGrid, key: string, cell: Cell, rotation: number): { Cell }
	local def = self.definitions[key]
	assert(def, "PlacementGrid: unknown item " .. tostring(key))
	local w, d = PlacementGrid.rotatedSize(def, rotation)
	local out = {}
	for y = cell.y, cell.y + d - 1 do
		for x = cell.x, cell.x + w - 1 do
			table.insert(out, { x = x, y = y })
		end
	end
	return out
end

-- (true) or (false, reason, cell?) for placing key at cell with rotation; `ignore` is an item id
-- whose cells count as free (moving an item over itself).
function Grid.canPlace(
	self: PlacementGrid,
	key: string,
	cell: Cell,
	rotation: number,
	ignore: string?
): (boolean, string?, Cell?)
	local def = self.definitions[key]
	if def == nil then
		return false, "unknown_item"
	end
	if not table.find(PlacementGrid.ROTATIONS, rotation) then
		return false, "bad_rotation"
	end
	if type(cell) ~= "table" or not Check.integer(cell.x) or not Check.integer(cell.y) then
		return false, "out_of_bounds"
	end
	for _, c in self:footprint(key, cell, rotation) do
		if c.x < 1 or c.y < 1 or c.x > self.width or c.y > self.height then
			return false, "out_of_bounds", c
		end
		local k = cellKey(c.x, c.y)
		if self.blocked[k] then
			return false, "blocked", c
		end
		if self.allowed and not self.allowed(c, key, def) then
			return false, "not_allowed", c
		end
		local owner = self.cells[k]
		if owner ~= nil and owner ~= ignore then
			return false, "occupied", c
		end
	end
	return true
end

function Grid.place(
	self: PlacementGrid,
	id: string,
	key: string,
	cell: Cell,
	rotation: number
): (boolean, string?)
	if type(id) ~= "string" or id == "" then
		return false, "bad_id"
	end
	if self.items[id] then
		return false, "duplicate_id"
	end
	local ok, reason = self:canPlace(key, cell, rotation)
	if not ok then
		return false, reason
	end
	self.items[id] = { id = id, key = key, x = cell.x, y = cell.y, rotation = rotation }
	for _, c in self:footprint(key, cell, rotation) do
		self.cells[cellKey(c.x, c.y)] = id
	end
	return true
end

function Grid.remove(self: PlacementGrid, id: string): boolean
	local item = self.items[id]
	if item == nil then
		return false
	end
	for _, c in self:footprint(item.key, { x = item.x, y = item.y }, item.rotation) do
		self.cells[cellKey(c.x, c.y)] = nil
	end
	self.items[id] = nil
	return true
end

-- Moves (or turns) an item; on refusal it stays where it was.
function Grid.move(self: PlacementGrid, id: string, cell: Cell, rotation: number): (boolean, string?)
	local item = self.items[id]
	if item == nil then
		return false, "unknown_id"
	end
	local ok, reason = self:canPlace(item.key, cell, rotation, id)
	if not ok then
		return false, reason
	end
	local key = item.key
	self:remove(id)
	return self:place(id, key, cell, rotation)
end

function Grid.at(self: PlacementGrid, cell: Cell): string?
	return self.cells[cellKey(cell.x, cell.y)]
end

-- Cell under a world X/Z position (nil outside the grid).
function Grid.snap(self: PlacementGrid, x: number, z: number): Cell?
	local cx = math.floor((x - self.origin.x) / self.cellSize) + 1
	local cy = math.floor((z - self.origin.z) / self.cellSize) + 1
	if cx < 1 or cy < 1 or cx > self.width or cy > self.height then
		return nil
	end
	return { x = cx, y = cy }
end

-- World centre (X, Z) and yaw of an item's footprint, for the adapter that builds it.
function Grid.worldPose(self: PlacementGrid, id: string): { x: number, z: number, yaw: number }?
	local item = self.items[id]
	if item == nil then
		return nil
	end
	local w, d = PlacementGrid.rotatedSize(self.definitions[item.key], item.rotation)
	return {
		x = self.origin.x + (item.x - 1 + w / 2) * self.cellSize,
		z = self.origin.z + (item.y - 1 + d / 2) * self.cellSize,
		yaw = item.rotation,
	}
end

-- Free anchor cells where key fits with rotation, row by row (for previews and AI builders).
function Grid.freeAnchors(self: PlacementGrid, key: string, rotation: number): { Cell }
	local out = {}
	for y = 1, self.height do
		for x = 1, self.width do
			if self:canPlace(key, { x = x, y = y }, rotation) then
				table.insert(out, { x = x, y = y })
			end
		end
	end
	return out
end

function Grid.serialize(self: PlacementGrid): { [string]: any }
	local items = {}
	for _, item in self.items do
		table.insert(items, table.clone(item))
	end
	table.sort(items, function(a, b)
		return a.id < b.id
	end)
	return { format = PlacementGrid.FORMAT, width = self.width, height = self.height, items = items }
end

-- Rebuilds a grid from serialize() output. Records that no longer fit (unknown key, overlap,
-- out of bounds after a resize) are skipped and listed as "<id>: <reason>".
function PlacementGrid.restore(
	data: any,
	definitions: { [string]: Definition },
	options: Options
): (PlacementGrid?, { string })
	if type(data) ~= "table" or data.format ~= PlacementGrid.FORMAT or type(data.items) ~= "table" then
		return nil, { "not placement/1 data" }
	end
	local grid = PlacementGrid.new(definitions, options)
	local skipped = {}
	for index, record in data.items do
		if type(record) ~= "table" then
			table.insert(skipped, "item " .. index .. ": not a table")
			continue
		end
		local ok, reason = grid:place(record.id, record.key, { x = record.x, y = record.y }, record.rotation)
		if not ok then
			table.insert(skipped, tostring(record.id) .. ": " .. tostring(reason))
		end
	end
	return grid, skipped
end

return PlacementGrid
