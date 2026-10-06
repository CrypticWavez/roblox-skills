--!strict
-- Bridge from a ProcGen Forest layout to SceneKit parts: band ground tiles, path strips,
-- clearing pads, trees and bushes (Vegetation.tree/bush), rocks (Props.place) and role markers
-- (non-collidable, so they never block the measured paths). The part count equals
-- Forest.partEstimate(layout), which Validate.forest budgets.
local Paths = require("../SceneKit/Paths")
local Props = require("../SceneKit/Props")
local Scene = require("../SceneKit/Scene")
local Vegetation = require("../SceneKit/Vegetation")

local ForestScene = {}
type Scene = Scene.Scene

-- Neutral placeholder ground per band (explicit so any style profile reads as ground).
local GROUND = {
	open = { material = "Grass", color = { 110, 150, 82 } },
	sparse = { material = "Grass", color = { 96, 136, 72 } },
	dense = { material = "LeafyGrass", color = { 74, 112, 60 } },
	rocky = { material = "Ground", color = { 122, 114, 100 } },
}
local CLEARING = { material = "Grass", color = { 140, 168, 100 } }
local ROCK = { material = "Slate", color = { 128, 128, 132 } }
-- Same sizes and colours as SceneKit Layout's room markers.
local MARKERS = {
	spawn = { size = { x = 6, y = 0.6, z = 6 }, color = { 80, 170, 255 } },
	goal = { size = { x = 6, y = 6, z = 6 }, color = { 255, 90, 90 } },
	encounter = { size = { x = 4, y = 4, z = 4 }, color = { 255, 150, 60 } },
	treasure = { size = { x = 3, y = 2, z = 2 }, color = { 250, 220, 80 } },
	landmark = { size = { x = 3, y = 18, z = 3 }, color = { 180, 120, 255 } },
}

local function marker(scene: Scene, role: string, x: number, y: number, z: number, tag: string)
	local m = MARKERS[role]
	scene:add({
		role = "prop",
		name = "marker_" .. role,
		size = m.size,
		pos = { x = x, y = y + m.size.y / 2, z = z },
		color = m.color,
		canCollide = false,
		attributes = { asset = "marker/" .. role, node = tag },
	})
	table.insert(
		scene.meta.placements,
		{ asset = "marker/" .. role, pos = { x = x, y = y, z = z }, yaw = 0, node = tag }
	)
end

function ForestScene.toScene(scene: Scene, layout, options: { y: number?, pathThickness: number? }?)
	local y = options and options.y or 0
	local thickness = options and options.pathThickness or 0.4
	scene:group(layout.kind or "forest", function()
		scene:group("Ground", function()
			for _, tile in layout.bands.tiles do
				local ground = GROUND[tile.band]
				scene:box(
					"floor",
					{ x = tile.x, y = y - 1, z = tile.z },
					{ x = tile.x + tile.w, y = y, z = tile.z + tile.d },
					{ name = "ground_" .. tile.band, material = ground.material, color = ground.color }
				)
			end
		end)
		for _, path in layout.paths do
			local points = {}
			for _, p in path.points do
				table.insert(points, { x = p[1], y = y, z = p[2] })
			end
			Paths.path(
				scene,
				points,
				{ width = layout.params.pathWidth, thickness = thickness, role = "road" }
			)
		end
		-- Clearing pads sit just above the path strips so path ends vanish under them.
		scene:group("Clearings", function()
			for _, clearing in layout.clearings do
				scene:add({
					role = "road",
					name = "clearing",
					shape = "Cylinder",
					size = { x = thickness + 0.2, y = clearing.radius * 2, z = clearing.radius * 2 },
					pos = { x = clearing.x, y = y + (thickness + 0.2) / 2, z = clearing.z },
					rot = { x = 0, y = 0, z = 90 },
					material = CLEARING.material,
					color = CLEARING.color,
					attributes = { clearing = clearing.id },
				})
			end
		end)
		scene:group("Vegetation", function()
			for _, item in layout.vegetation do
				if item.kind == "tree" then
					Vegetation.tree(scene, item.x, y, item.z, item.scale)
				elseif item.kind == "bush" then
					Vegetation.bush(scene, item.x, y, item.z, item.scale)
				else
					local size = { x = item.size[1], y = item.size[2], z = item.size[3] }
					local kind = { asset = "placeholder/rock", size = size }
					local spec = Props.place(scene, kind, { x = item.x, y = y, z = item.z }, item.yaw)
					spec.material, spec.color = ROCK.material, ROCK.color
				end
			end
		end)
		scene:group("Markers", function()
			marker(scene, "spawn", layout.entry.x, y, layout.entry.z, "entry")
			marker(scene, "goal", layout.exit.x, y, layout.exit.z, "exit")
			for _, clearing in layout.clearings do
				marker(scene, clearing.role, clearing.x, y, clearing.z, clearing.id)
			end
		end)
	end)
	return scene
end

return ForestScene
