--!strict
-- Vegetation dressing: density-field scatter (fbm noise) and clustered groves, using
-- placeholder trunk/canopy primitives tagged with an `asset` key for approved-asset swaps.
local Noise = require("../ProcGen/Noise")
local Props = require("./Props")
local Rng = require("../ProcGen/Rng")
local Scene = require("./Scene")

local Vegetation = {}
type Scene = Scene.Scene
type Rect = { x: number, z: number, w: number, d: number }

function Vegetation.tree(scene: Scene, x: number, y: number, z: number, scale: number?, asset: string?)
	local s = scale or 1
	scene:group("Tree", function()
		scene:add({
			role = "trunk",
			name = asset or "tree",
			shape = "Cylinder",
			size = { x = 8 * s, y = 1.4 * s, z = 1.4 * s },
			pos = { x = x, y = y + 4 * s, z = z },
			rot = { x = 0, y = 0, z = 90 },
			attributes = { asset = asset or "placeholder/tree" },
		})
		scene:add({
			role = "foliage",
			name = asset or "tree",
			shape = "Ball",
			size = { x = 7 * s, y = 7 * s, z = 7 * s },
			pos = { x = x, y = y + 9 * s, z = z },
			canCollide = false,
		})
	end)
	table.insert(
		scene.meta.placements,
		{ asset = asset or "placeholder/tree", pos = { x = x, y = y, z = z }, yaw = 0 }
	)
end

function Vegetation.bush(scene: Scene, x: number, y: number, z: number, scale: number?)
	local s = scale or 1
	scene:add({
		role = "foliage",
		name = "bush",
		shape = "Ball",
		size = { x = 3 * s, y = 2.2 * s, z = 3 * s },
		pos = { x = x, y = y + 1.1 * s, z = z },
		canCollide = false,
		attributes = { asset = "placeholder/bush" },
	})
	table.insert(
		scene.meta.placements,
		{ asset = "placeholder/bush", pos = { x = x, y = y, z = z }, yaw = 0 }
	)
end

-- Scatter with a noise density field: dense groves and natural clearings.
function Vegetation.scatter(
	scene: Scene,
	options: {
		rect: Rect,
		y: number?,
		radius: number?,
		density: number?,
		seed: (number | string)?,
		exclude: ((x: number, z: number) -> boolean)?,
		bushRatio: number?,
	}
)
	local seed = options.seed or scene.seed
	local rng = Rng.new(seed):fork("vegetation")
	local density = options.density or 0.55
	local count = 0
	scene:group("Vegetation", function()
		for _, p in Props.poisson(options.rect, options.radius or 8, seed, { exclude = options.exclude }) do
			local field = Noise.fbm(seed, p[1] / 48, p[2] / 48, 3)
			if field > 1 - density then
				count += 1
				if rng:chance(options.bushRatio or 0.35) then
					Vegetation.bush(scene, p[1], options.y or 0, p[2], rng:range(0.8, 1.3))
				else
					Vegetation.tree(scene, p[1], options.y or 0, p[2], rng:range(0.8, 1.4))
				end
			end
		end
	end)
	return count
end

function Vegetation.cluster(
	scene: Scene,
	options: {
		center: { number },
		radius: number,
		count: number,
		y: number?,
		seed: (number | string)?,
	}
)
	local rng = Rng.new(options.seed or scene.seed):fork("cluster")
	scene:group("Grove", function()
		for _ = 1, options.count do
			local angle, dist = rng:range(0, 2 * math.pi), options.radius * math.sqrt(rng:next())
			Vegetation.tree(
				scene,
				options.center[1] + math.cos(angle) * dist,
				options.y or 0,
				options.center[2] + math.sin(angle) * dist,
				rng:range(0.8, 1.3)
			)
		end
	end)
end

-- Remove vegetation specs inside a rect (e.g. after placing a building).
function Vegetation.clear(scene: Scene, rect: Rect): number
	local kept, removed = {}, 0
	for _, spec in scene.specs do
		local inside = spec.pos.x >= rect.x
			and spec.pos.x <= rect.x + rect.w
			and spec.pos.z >= rect.z
			and spec.pos.z <= rect.z + rect.d
		if inside and (spec.role == "trunk" or spec.role == "foliage") then
			removed += 1
		else
			table.insert(kept, spec)
		end
	end
	scene.specs = kept
	return removed
end

return Vegetation
