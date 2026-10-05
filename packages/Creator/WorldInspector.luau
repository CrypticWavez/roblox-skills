--!strict
-- SETUP_ONLY read-only inspection of an explicitly owned unpublished diagnostic root.
local WorldInspector = {}

local defaults = {
	max_descendants = 256,
	max_parts = 64,
	max_extent = 512,
	max_coordinate = 1000000,
	max_queries = 16,
	max_ray_distance = 1024,
	max_grid_cells = 1024,
	max_cell_references = 4096,
	cell_size = 4,
}
local ceilings = {
	max_descendants = 5000,
	max_parts = 512,
	max_extent = 2048,
	max_coordinate = 1000000,
	max_queries = 64,
	max_ray_distance = 4096,
	max_grid_cells = 4096,
	max_cell_references = 16384,
	cell_size = 512,
}
local integers = {
	max_descendants = true,
	max_parts = true,
	max_queries = true,
	max_grid_cells = true,
	max_cell_references = true,
}

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function label(value: any): boolean
	return type(value) == "string"
		and #value > 0
		and #value <= 80
		and value:match("^[a-z][a-z0-9_-]*$") ~= nil
end

function WorldInspector.validateLimits(overrides: any): any
	assert(overrides == nil or type(overrides) == "table", "limits must be a table")
	local result = table.clone(defaults)
	for key, value in overrides or {} do
		assert(defaults[key] ~= nil, "unknown world inspection budget")
		assert(finite(value) and value > 0 and value <= ceilings[key], "world budget outside finite bounds")
		assert(not integers[key] or value % 1 == 0, "world count budgets must be integers")
		result[key] = value
	end
	assert(result.max_parts <= result.max_descendants, "part cap exceeds descendant cap")
	return result
end

-- Pure conservative AABB-to-grid arithmetic, bounded before any cell enumeration.
function WorldInspector.gridCoverage(
	minimum: any,
	maximum: any,
	cellSize: any,
	origin: any,
	referenceCap: any
): any
	assert(finite(cellSize) and cellSize > 0 and cellSize <= 512, "invalid grid cell size")
	assert(
		finite(referenceCap) and referenceCap % 1 == 0 and referenceCap >= 1 and referenceCap <= 16384,
		"invalid grid reference cap"
	)
	local first, last, total = {}, {}, 1
	for index = 1, 3 do
		assert(
			type(minimum) == "table" and type(maximum) == "table" and type(origin) == "table",
			"grid vectors required"
		)
		local low, high, offset = minimum[index], maximum[index], origin[index]
		assert(
			finite(low)
				and finite(high)
				and finite(offset)
				and math.max(math.abs(low), math.abs(high), math.abs(offset)) <= 1000000,
			"invalid grid coordinate"
		)
		assert(low <= high, "grid bounds reversed")
		first[index], last[index] =
			math.floor((low - offset) / cellSize), math.floor((high - offset) / cellSize)
		total *= last[index] - first[index] + 1
		assert(finite(total) and total <= referenceCap, "grid reference budget exceeded")
	end
	return { first = first, last = last, references = total }
end

local function vector(value: Vector3): { number }
	return { value.X, value.Y, value.Z }
end

function WorldInspector.new(options: any): any
	local runService = game:GetService("RunService")
	assert(
		runService:IsStudio() and runService:IsClient() and game.GameId == 0 and game.PlaceId == 0,
		"unpublished SETUP_ONLY Studio client required"
	)
	assert(type(options) == "table", "world inspection options required")
	local root = options.root
	assert(
		typeof(root) == "Instance"
			and (root:IsA("Folder") or root:IsA("Model"))
			and root ~= workspace
			and root:IsDescendantOf(workspace)
			and root:GetAttribute("WorkbenchOwned") == true,
		"explicit owned Folder/Model below workspace required"
	)
	local limits = WorldInspector.validateLimits(options.limits)
	local api: any = { destroyed = false }
	local function live()
		assert(
			not api.destroyed
				and root.Parent ~= nil
				and root:IsDescendantOf(workspace)
				and root:GetAttribute("WorkbenchOwned") == true,
			"owned inspection scope is no longer live"
		)
	end
	local function validVector(value: any, positive: boolean?): boolean
		return typeof(value) == "Vector3"
			and finite(value.X)
			and finite(value.Y)
			and finite(value.Z)
			and math.max(math.abs(value.X), math.abs(value.Y), math.abs(value.Z)) <= limits.max_coordinate
			and (not positive or math.min(value.X, value.Y, value.Z) > 0)
	end
	local function validFrame(value: any): boolean
		if typeof(value) ~= "CFrame" then
			return false
		end
		for _, component in { value:GetComponents() } do
			if not finite(component) or math.abs(component) > limits.max_coordinate then
				return false
			end
		end
		return true
	end
	local function queryArray(value: any): boolean
		if type(value) ~= "table" or #value > limits.max_queries then
			return false
		end
		local count = 0
		for key in value do
			count += 1
			if
				count > limits.max_queries
				or type(key) ~= "number"
				or key % 1 ~= 0
				or key < 1
				or key > #value
			then
				return false
			end
		end
		return count == #value
	end
	local function parts(): any
		live()
		local stack, found, count = { root }, {}, 0
		while #stack > 0 do
			local item = table.remove(stack)
			local children = item:GetChildren()
			assert(count + #children <= limits.max_descendants, "owned descendant budget exceeded")
			count += #children
			for _, child in children do
				assert(child:IsDescendantOf(root), "geometry left the owned scope")
				if child:IsA("BasePart") then
					table.insert(found, child)
					assert(#found <= limits.max_parts, "owned part budget exceeded")
				end
				table.insert(stack, child)
			end
		end
		assert(#found > 0, "owned scope has no inspectable parts")
		return found, count
	end
	local function bounds(part: BasePart): any
		assert(
			validFrame(part.CFrame)
				and validVector(part.Size, true)
				and math.max(part.Size.X, part.Size.Y, part.Size.Z) <= limits.max_extent,
			"part transform or size outside finite budgets"
		)
		local half, frame = part.Size / 2, part.CFrame
		local r, u, l = frame.RightVector, frame.UpVector, frame.LookVector
		local extent = Vector3.new(
			math.abs(r.X) * half.X + math.abs(u.X) * half.Y + math.abs(l.X) * half.Z,
			math.abs(r.Y) * half.X + math.abs(u.Y) * half.Y + math.abs(l.Y) * half.Z,
			math.abs(r.Z) * half.X + math.abs(u.Z) * half.Y + math.abs(l.Z) * half.Z
		)
		local low, high = frame.Position - extent, frame.Position + extent
		assert(validVector(low) and validVector(high), "rotated part bounds exceed coordinate cap")
		return low, high
	end
	function api:inspect(specification: any): any
		live()
		assert(type(specification) == "table", "inspection specification required")
		local spawns, sightlines = specification.spawns or {}, specification.sightlines or {}
		assert(
			queryArray(spawns) and queryArray(sightlines) and #spawns + #sightlines <= limits.max_queries,
			"query budget exceeded"
		)
		local gridOrigin = specification.grid_origin or Vector3.zero
		assert(validVector(gridOrigin), "invalid grid origin")
		local found, descendants = parts()
		local partIds, rows, cells, cellCount, references, volume = {}, {}, {}, 0, 0, 0
		local low, high =
			Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
		for index, part in found do
			local id = "owned-part-" .. index
			partIds[part] = id
			local first, last = bounds(part)
			low = Vector3.new(math.min(low.X, first.X), math.min(low.Y, first.Y), math.min(low.Z, first.Z))
			high = Vector3.new(math.max(high.X, last.X), math.max(high.Y, last.Y), math.max(high.Z, last.Z))
			volume += part.Size.X * part.Size.Y * part.Size.Z
			local coverage = WorldInspector.gridCoverage(
				vector(first),
				vector(last),
				limits.cell_size,
				vector(gridOrigin),
				limits.max_cell_references
			)
			references += coverage.references
			assert(references <= limits.max_cell_references, "total grid reference budget exceeded")
			for x = coverage.first[1], coverage.last[1] do
				for y = coverage.first[2], coverage.last[2] do
					for z = coverage.first[3], coverage.last[3] do
						local key = x .. ":" .. y .. ":" .. z
						if not cells[key] then
							cellCount += 1
							assert(cellCount <= limits.max_grid_cells, "occupied grid cell budget exceeded")
							cells[key] = { index = { x, y, z }, part_references = 0 }
						end
						cells[key].part_references += 1
					end
				end
			end
			table.insert(rows, {
				id = id,
				class = part.ClassName,
				position = vector(part.Position),
				size = vector(part.Size),
				minimum = vector(first),
				maximum = vector(last),
				anchored = part.Anchored,
				can_collide = part.CanCollide,
				can_query = part.CanQuery,
				transparency = part.Transparency,
			})
		end
		local extent = high - low
		assert(
			math.max(extent.X, extent.Y, extent.Z) <= limits.max_extent,
			"total geometry extent budget exceeded"
		)
		local grid = {}
		for _, cell in cells do
			cell.reference_density_per_cubic_stud = cell.part_references / limits.cell_size ^ 3
			table.insert(grid, cell)
		end
		table.sort(grid, function(a, b)
			for index = 1, 3 do
				if a.index[index] ~= b.index[index] then
					return a.index[index] < b.index[index]
				end
			end
			return false
		end)
		local report: any = {
			schema_version = 1,
			mode = "SETUP_ONLY",
			method = "owned_geometry_inspection",
			status = "partially_verified",
			target = { universe_id = 0, place_id = 0 },
			limits = table.clone(limits),
			summary = {
				descendants = descendants,
				parts = #found,
				queries = #spawns + #sightlines,
				minimum = vector(low),
				maximum = vector(high),
				extent = vector(extent),
				nominal_part_box_volume = volume,
				bounds_volume = extent.X * extent.Y * extent.Z,
				occupied_grid_cells = cellCount,
				cell_references = references,
			},
			parts = rows,
			grid_origin = vector(gridOrigin),
			grid = grid,
			spawns = {},
			sightlines = {},
			limitations = {
				"Current owned geometry only; no complete streamed world or external geometry acceptance.",
				"Rotated AABBs/grid density are conservative box statistics; overlapping volumes double count and do not measure traversability.",
				"Spawn checks are GetPartBoundsInBox bounding overlaps under Default collision group/CanQuery; no accurate mesh contact or movement sweep.",
				"Sightline rays use owned CanQuery geometry including noncollidable/transparent parts; no navigability, visibility policy or player clearance acceptance.",
			},
		}
		local queryIds = {}
		local overlap = OverlapParams.new()
		overlap.FilterType = Enum.RaycastFilterType.Include
		overlap.FilterDescendantsInstances = found
		overlap.RespectCanCollide = false
		overlap.CollisionGroup = "Default"
		overlap.MaxParts = limits.max_parts + 1
		for _, spawn in spawns do
			assert(
				type(spawn) == "table" and label(spawn.id) and not queryIds[spawn.id],
				"spawn ids must be stable and unique"
			)
			queryIds[spawn.id] = true
			assert(
				validFrame(spawn.cframe)
					and validVector(spawn.size, true)
					and math.max(spawn.size.X, spawn.size.Y, spawn.size.Z) <= limits.max_extent,
				"spawn box outside finite bounds"
			)
			local hits = workspace:GetPartBoundsInBox(spawn.cframe, spawn.size, overlap)
			local hitIds = {}
			for _, hit in hits do
				assert(
					partIds[hit] ~= nil and hit:IsDescendantOf(root),
					"overlap returned geometry outside owned include filter"
				)
				table.insert(hitIds, partIds[hit])
			end
			table.sort(hitIds)
			table.insert(report.spawns, {
				id = spawn.id,
				position = vector(spawn.cframe.Position),
				size = vector(spawn.size),
				clear_of_owned_query_bounds = #hitIds == 0,
				overlapping_part_ids = hitIds,
			})
		end
		local raycast = RaycastParams.new()
		raycast.FilterType = Enum.RaycastFilterType.Include
		raycast.FilterDescendantsInstances = found
		raycast.RespectCanCollide = false
		raycast.CollisionGroup = "Default"
		raycast.IgnoreWater = true
		for _, sightline in sightlines do
			assert(
				type(sightline) == "table" and label(sightline.id) and not queryIds[sightline.id],
				"sightline ids must be stable and unique"
			)
			queryIds[sightline.id] = true
			assert(
				validVector(sightline.origin) and validVector(sightline.destination),
				"sightline coordinates outside finite bounds"
			)
			local direction = sightline.destination - sightline.origin
			assert(
				direction.Magnitude > 0 and direction.Magnitude <= limits.max_ray_distance,
				"sightline distance outside finite budget"
			)
			local hit = workspace:Raycast(sightline.origin, direction, raycast)
			local row: any = {
				id = sightline.id,
				origin = vector(sightline.origin),
				destination = vector(sightline.destination),
				length = direction.Magnitude,
				clear_of_owned_query_geometry = hit == nil,
			}
			if hit then
				assert(
					partIds[hit.Instance] ~= nil and hit.Instance:IsDescendantOf(root),
					"ray returned geometry outside owned include filter"
				)
				row.hit = {
					part_id = partIds[hit.Instance],
					position = vector(hit.Position),
					normal = vector(hit.Normal),
					distance = hit.Distance,
				}
			end
			table.insert(report.sightlines, row)
		end
		return report
	end
	function api:destroy()
		api.destroyed = true
	end
	return api
end

return WorldInspector
