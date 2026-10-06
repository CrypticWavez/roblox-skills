--!strict
-- Terrain authoring as a reviewable op list. Heightmaps are generated, sculpted, carved,
-- smoothed and painted as data; Apply.terrain replays the ops on workspace.Terrain.
local Noise = require("../ProcGen/Noise")

local Terrain = {}

export type Op = { op: string, [string]: any }
export type Heightmap = {
	origin: { number }, -- {x, z} min corner in studs
	cell: number,
	cols: number,
	rows: number,
	base: number, -- bottom of the terrain slab
	heights: { number },
	materials: { string },
}

function Terrain.heightmap(options: {
	origin: { number }?,
	cols: number,
	rows: number,
	cell: number?,
	base: number?,
	seed: number | string,
	amplitude: number?,
	scale: number?,
	floor: number?,
	octaves: number?,
}): Heightmap
	assert(options.cols * options.rows <= 65536, "heightmap too large for one op batch")
	local hm = {
		origin = options.origin or { 0, 0 },
		cell = options.cell or 8,
		cols = options.cols,
		rows = options.rows,
		base = options.base or -8,
		heights = table.create(options.cols * options.rows, 0),
		materials = table.create(options.cols * options.rows, "Grass"),
	}
	local amplitude, scale, floor = options.amplitude or 24, options.scale or 12, options.floor or 2
	for r = 1, hm.rows do
		for c = 1, hm.cols do
			hm.heights[(r - 1) * hm.cols + c] = floor
				+ Noise.fbm(options.seed, c / scale, r / scale, options.octaves or 4) * amplitude
		end
	end
	return hm
end

local function index(hm: Heightmap, c: number, r: number): number
	return (math.clamp(r, 1, hm.rows) - 1) * hm.cols + math.clamp(c, 1, hm.cols)
end

function Terrain.heightAt(hm: Heightmap, x: number, z: number): number
	local c = math.floor((x - hm.origin[1]) / hm.cell) + 1
	local r = math.floor((z - hm.origin[2]) / hm.cell) + 1
	return hm.heights[index(hm, c, r)]
end

-- Raise (amount > 0) or lower within a radius with smooth falloff.
function Terrain.sculpt(hm: Heightmap, x: number, z: number, radius: number, amount: number)
	for r = 1, hm.rows do
		for c = 1, hm.cols do
			local cx = hm.origin[1] + (c - 0.5) * hm.cell
			local cz = hm.origin[2] + (r - 0.5) * hm.cell
			local d = math.sqrt((cx - x) ^ 2 + (cz - z) ^ 2)
			if d < radius then
				local t = 1 - d / radius
				hm.heights[index(hm, c, r)] += amount * t * t * (3 - 2 * t)
			end
		end
	end
end

-- Flatten a pad (e.g. under a building footprint) to a fixed height.
function Terrain.flatten(hm: Heightmap, rect: { x: number, z: number, w: number, d: number }, height: number)
	for r = 1, hm.rows do
		for c = 1, hm.cols do
			local cx = hm.origin[1] + (c - 0.5) * hm.cell
			local cz = hm.origin[2] + (r - 0.5) * hm.cell
			if cx >= rect.x and cx <= rect.x + rect.w and cz >= rect.z and cz <= rect.z + rect.d then
				hm.heights[index(hm, c, r)] = height
			end
		end
	end
end

function Terrain.smooth(hm: Heightmap, passes: number?)
	for _ = 1, passes or 1 do
		local nextHeights = table.clone(hm.heights)
		for r = 1, hm.rows do
			for c = 1, hm.cols do
				local sum = 0
				for dr = -1, 1 do
					for dc = -1, 1 do
						sum += hm.heights[index(hm, c + dc, r + dr)]
					end
				end
				nextHeights[index(hm, c, r)] = sum / 9
			end
		end
		hm.heights = nextHeights
	end
end

function Terrain.slopeAt(hm: Heightmap, c: number, r: number): number
	local dx = (hm.heights[index(hm, c + 1, r)] - hm.heights[index(hm, c - 1, r)]) / (2 * hm.cell)
	local dz = (hm.heights[index(hm, c, r + 1)] - hm.heights[index(hm, c, r - 1)]) / (2 * hm.cell)
	return math.deg(math.atan(math.sqrt(dx * dx + dz * dz)))
end

-- Biome painting by height bands and slope (rock on steep faces).
function Terrain.paint(
	hm: Heightmap,
	rules: {
		bands: { { below: number, material: string } }?,
		steep: number?,
		steepMaterial: string?,
	}?
)
	local bands = rules and rules.bands
		or {
			{ below = 4, material = "Sand" },
			{ below = 18, material = "Grass" },
			{ below = 24, material = "Ground" },
			{ below = math.huge, material = "Rock" },
		}
	local steep = rules and rules.steep or 40
	for r = 1, hm.rows do
		for c = 1, hm.cols do
			local i = index(hm, c, r)
			local material = bands[#bands].material
			for _, band in bands do
				if hm.heights[i] < band.below then
					material = band.material
					break
				end
			end
			if Terrain.slopeAt(hm, c, r) > steep then
				material = rules and rules.steepMaterial or "Rock"
			end
			hm.materials[i] = material
		end
	end
end

-- Column FillBlock ops; adjacent cells with equal material and height merge along rows.
function Terrain.toOps(hm: Heightmap): { Op }
	local ops = {}
	for r = 1, hm.rows do
		local c = 1
		while c <= hm.cols do
			local i = index(hm, c, r)
			local top = math.round(hm.heights[i] / 2) * 2
			local material = hm.materials[i]
			local run = 1
			while c + run <= hm.cols do
				local j = index(hm, c + run, r)
				if hm.materials[j] ~= material or math.round(hm.heights[j] / 2) * 2 ~= top then
					break
				end
				run += 1
			end
			local height = top - hm.base
			table.insert(ops, {
				op = "FillBlock",
				pos = {
					hm.origin[1] + (c - 1 + run / 2) * hm.cell,
					hm.base + height / 2,
					hm.origin[2] + (r - 0.5) * hm.cell,
				},
				size = { run * hm.cell, height, hm.cell },
				material = material,
			})
			c += run
		end
	end
	return ops
end

-- Air ball (cave mouth, tunnel bend). Errors on a missing coordinate or a non-positive radius.
function Terrain.carve(center: { number }, radius: number): Op
	assert(#center == 3, "Terrain.carve: center needs {x, y, z}")
	assert(radius > 0, "Terrain.carve: radius must be positive")
	return { op = "FillBall", pos = center, radius = radius, material = "Air" }
end

-- Water box between two corners. Errors unless min < max on every axis.
function Terrain.water(min: { number }, max: { number }): Op
	assert(#min == 3 and #max == 3, "Terrain.water: corners need {x, y, z}")
	for axis = 1, 3 do
		assert(min[axis] < max[axis], "Terrain.water: min must be below max on every axis")
	end
	return {
		op = "FillBlock",
		pos = { (min[1] + max[1]) / 2, (min[2] + max[2]) / 2, (min[3] + max[3]) / 2 },
		size = { max[1] - min[1], max[2] - min[2], max[3] - min[3] },
		material = "Water",
	}
end

function Terrain.validate(hm: Heightmap, options: { maxWalkableSlope: number?, maxOps: number? }?)
	local limit = options and options.maxWalkableSlope or 45
	local steepCells, total = 0, hm.cols * hm.rows
	for r = 1, hm.rows do
		for c = 1, hm.cols do
			if Terrain.slopeAt(hm, c, r) > limit then
				steepCells += 1
			end
		end
	end
	local ops = #Terrain.toOps(hm)
	local maxOps = options and options.maxOps or 20000
	return {
		{
			name = "steep_ratio",
			pass = steepCells / total <= 0.25,
			value = math.round(steepCells / total * 100) / 100,
			limit = 0.25,
		},
		{ name = "op_budget", pass = ops <= maxOps, value = ops, limit = maxOps },
	}
end

return Terrain
