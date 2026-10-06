--!strict
-- Converts ProcGen grid layouts into SceneKit geometry: greedy-merged floor slabs, merged
-- wall blocks on solid cells that border floor, and role markers for placements.
local Scene = require("./Scene")

local Layout = {}
type Scene = Scene.Scene

-- Greedy rectangle merge over cells where `want(x, y)` is true.
function Layout.merge(width: number, height: number, want: (x: number, y: number) -> boolean): { { number } }
	local used: { [number]: boolean } = {}
	local rects = {}
	for y = 1, height do
		for x = 1, width do
			local key = (y - 1) * width + x
			if want(x, y) and not used[key] then
				local w = 1
				while x + w <= width and want(x + w, y) and not used[(y - 1) * width + x + w] do
					w += 1
				end
				local h = 1
				local grow = true
				while grow and y + h <= height do
					for cx = x, x + w - 1 do
						if not want(cx, y + h) or used[(y + h - 1) * width + cx] then
							grow = false
							break
						end
					end
					if grow then
						h += 1
					end
				end
				for cy = y, y + h - 1 do
					for cx = x, x + w - 1 do
						used[(cy - 1) * width + cx] = true
					end
				end
				table.insert(rects, { x, y, w, h })
			end
		end
	end
	return rects
end

local MARKERS = {
	spawn = { size = { x = 6, y = 0.6, z = 6 }, color = { 80, 170, 255 } },
	goal = { size = { x = 6, y = 6, z = 6 }, color = { 255, 90, 90 } },
	encounter = { size = { x = 4, y = 4, z = 4 }, color = { 255, 150, 60 } },
	optional_encounter = { size = { x = 3, y = 3, z = 3 }, color = { 255, 200, 60 } },
	treasure = { size = { x = 3, y = 2, z = 2 }, color = { 250, 220, 80 } },
	landmark = { size = { x = 3, y = 18, z = 3 }, color = { 180, 120, 255 } },
}

function Layout.toScene(
	scene: Scene,
	layout,
	options: { y: number?, wallHeight: number?, ceiling: boolean?, placement: any? }?
)
	local grid = layout.grid
	local cs = grid.cellSize
	local y = options and options.y or 0
	local wallHeight = options and options.wallHeight or 12
	local function floorCell(x, z)
		return grid:get(x, z) ~= 0
	end
	local function wallCell(x, z)
		if grid:get(x, z) ~= 0 then
			return false
		end
		for dz = -1, 1 do
			for dx = -1, 1 do
				if grid:get(x + dx, z + dz) ~= 0 then
					return true
				end
			end
		end
		return false
	end
	-- Grid cell (x, z) spans studs [(x-1)*cs, x*cs].
	scene:group(layout.kind or "Layout", function()
		for _, r in Layout.merge(grid.width, grid.height, floorCell) do
			scene:box(
				"floor",
				{ x = (r[1] - 1) * cs, y = y - 1, z = (r[2] - 1) * cs },
				{ x = (r[1] - 1 + r[3]) * cs, y = y, z = (r[2] - 1 + r[4]) * cs }
			)
		end
		for _, r in Layout.merge(grid.width, grid.height, wallCell) do
			scene:box(
				"wall",
				{ x = (r[1] - 1) * cs, y = y - 1, z = (r[2] - 1) * cs },
				{ x = (r[1] - 1 + r[3]) * cs, y = y + wallHeight, z = (r[2] - 1 + r[4]) * cs }
			)
		end
		if options and options.ceiling then
			for _, r in Layout.merge(grid.width, grid.height, floorCell) do
				scene:box(
					"roof",
					{ x = (r[1] - 1) * cs, y = y + wallHeight, z = (r[2] - 1) * cs },
					{ x = (r[1] - 1 + r[3]) * cs, y = y + wallHeight + 1, z = (r[2] - 1 + r[4]) * cs }
				)
			end
		end
		local placement = options and options.placement
		if placement and layout.rooms then
			for _, room in layout.rooms do
				local role = placement.roles[room.id]
				local marker = MARKERS[role]
				if marker then
					local cx, cz = (room.cx - 0.5) * cs, (room.cy - 0.5) * cs
					scene:add({
						role = "prop",
						name = "marker_" .. role,
						size = marker.size,
						pos = { x = cx, y = y + marker.size.y / 2, z = cz },
						color = marker.color,
						canCollide = role ~= "spawn",
						attributes = { asset = "marker/" .. role, room = room.id },
					})
					table.insert(scene.meta.placements, {
						asset = "marker/" .. role,
						pos = { x = cx, y = y, z = cz },
						yaw = 0,
						room = room.id,
					})
				end
			end
		end
		for index, spawn in layout.spawns or {} do
			scene:add({
				role = "prop",
				name = "marker_spawn",
				size = MARKERS.spawn.size,
				pos = { x = (spawn[1] - 0.5) * cs, y = y + 0.3, z = (spawn[2] - 0.5) * cs },
				color = MARKERS.spawn.color,
				attributes = { asset = "marker/spawn", team = index },
			})
		end
		for _, objective in layout.objectives or {} do
			scene:add({
				role = "prop",
				name = "marker_objective",
				size = MARKERS.goal.size,
				pos = { x = (objective[1] - 0.5) * cs, y = y + 3, z = (objective[2] - 0.5) * cs },
				color = MARKERS.goal.color,
				canCollide = false,
				attributes = { asset = "marker/objective" },
			})
		end
	end)
	return scene
end

return Layout
