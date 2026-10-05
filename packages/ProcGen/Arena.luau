--!strict
-- Mirror-symmetric competitive arena: cover blocks, two team spawns, a centre objective.
-- Symmetry gives spawn fairness by construction; Validate still measures it.
local Grid = require("./Grid")
local Rng = require("./Rng")

local Arena = {}

export type Params = {
	seed: number | string,
	width: number?, -- cells, along the spawn axis
	height: number?,
	cellSize: number?,
	coverDensity: number?, -- 0..1 of half-map cells used as cover seeds
	spawnShield: number?, -- cells around spawns kept clear and walled from direct sight
	symmetry: ("mirror" | "rotational")?,
	minGap: number?, -- cells between cover pieces (default 2 = 8 studs at cellSize 4)
}

function Arena.generate(params: Params)
	local rng = Rng.new(params.seed)
	local width, height = params.width or 40, params.height or 24
	local grid = Grid.new(width, height, params.cellSize or 4, 0)
	grid:fillRect(2, 2, width - 2, height - 2, 1)
	local symmetry = params.symmetry or "rotational"
	local spawnA = { 4, height // 2 }
	local spawnB = { width - 3, height + 1 - height // 2 }
	if symmetry == "mirror" then
		spawnB = { width - 3, height // 2 }
	end
	local objective = { width // 2, height // 2 }
	local shield = params.spawnShield or 4

	local function mirror(x: number, y: number): (number, number)
		if symmetry == "mirror" then
			return width + 1 - x, y
		end
		return width + 1 - x, height + 1 - y
	end
	local function protected(x: number, y: number): boolean
		local ax, ay = math.abs(x - spawnA[1]), math.abs(y - spawnA[2])
		local ox, oy = math.abs(x - objective[1]), math.abs(y - objective[2])
		return (ax <= shield + 2 and ay <= shield + 2) or (ox <= 1 and oy <= 1)
	end

	-- Cover pieces (2x1/1x2/2x2) on the A half, mirrored onto the B half.
	local density = params.coverDensity or 0.05
	local seeds = math.floor((width // 2) * height * density)
	local coverRng = rng:fork("cover")
	local pieces = 0
	local gap = params.minGap or 2
	for _ = 1, seeds do
		local shape = coverRng:pick({ { 2, 1 }, { 1, 2 }, { 2, 2 }, { 1, 3 } })
		local w, h = shape[1], shape[2]
		local x = coverRng:int(4, width // 2 - 2)
		local y = coverRng:int(4, height - 2 - h)
		local blocked = false
		-- Keep at least `gap` floor cells between pieces so lanes stay player-scale.
		for cy = y - gap, y + h - 1 + gap do
			for cx = x - gap, x + w - 1 + gap do
				if cx > 1 and cy > 1 and cx < width and cy < height and grid:get(cx, cy) == 0 then
					blocked = true
				end
			end
		end
		for cy = y, y + h - 1 do
			for cx = x, x + w - 1 do
				if protected(cx, cy) or cx >= width // 2 then
					blocked = true
				end
			end
		end
		if not blocked then
			for cy = y, y + h - 1 do
				for cx = x, x + w - 1 do
					grid:set(cx, cy, 0)
					local mx, my = mirror(cx, cy)
					grid:set(mx, my, 0)
				end
			end
			pieces += 1
		end
	end

	-- Spawn shield wall in front of each spawn (with side exits) blocks spawn-to-spawn sight.
	for dy = -1, 1 do
		local x, y = spawnA[1] + shield - 1, spawnA[2] + dy
		grid:set(x, y, 0)
		local mx, my = mirror(x, y)
		grid:set(mx, my, 0)
	end

	grid:label(spawnA[1], spawnA[2], "A")
	grid:label(spawnB[1], spawnB[2], "B")
	grid:label(objective[1], objective[2], "O")
	return {
		kind = "arena",
		params = {
			seed = params.seed,
			width = width,
			height = height,
			cellSize = grid.cellSize,
			symmetry = symmetry,
		},
		grid = grid,
		spawns = { spawnA, spawnB },
		objectives = { objective },
		coverPieces = pieces,
	}
end

return Arena
