--!strict
-- Seeded forest / biome dressing for a rectangular area in studs (min corner at the origin,
-- entry on the west edge, exit on the east edge). Pure data and trig-free, so Lune and Studio
-- produce the same manifest.
--   bands       fbm noise ranked into quantile bands, ascending: open, sparse, dense, rocky;
--               a band map (one letter per cell) plus greedy-merged ground tiles
--   clearings   circles kept free of trunks and rocks, each with a role: the largest
--               `landmarks` are landmark, the rest encounter (on the entry-exit route) or
--               treasure (on a spur)
--   paths       minimum spanning tree over entry, clearings and exit with jittered bends, plus a
--               lead-in from the west edge and a lead-out to the east edge
--   vegetation  trees, bushes and rocks by random sequential adsorption over a jittered
--               candidate grid: per-band fill, kind weights and spacing, a character-width gap
--               between collidables, nothing in the path corridor, the clearings or the
--               entry/exit pads
-- ForestScene turns a layout into SceneKit parts; Validate.forest checks it.
local Graph = require("./Graph")
local Noise = require("./Noise")
local Rng = require("./Rng")

local Forest = {}

export type Band = { spacing: number, fill: number, tree: number, bush: number, rock: number }
export type Params = {
	seed: number | string,
	width: number?, -- studs along X
	depth: number?, -- studs along Z
	bandCell: number?, -- studs per band-map cell
	noiseScale: number?, -- studs per noise unit (larger = broader bands)
	shares: { [string]: number }?, -- share of band cells per band, assigned by noise rank
	bands: { [string]: { [string]: number } }?, -- per-band overrides merged over Forest.BANDS
	clearings: number?, -- requested clearings
	clearingRadius: { number }?, -- {min, max} studs
	pathWidth: number?,
	wobble: number?, -- max sideways bend of a path in studs
	spawnInset: number?, -- studs from the west edge to the entry (spawn) and east edge to the exit
	spawnClear: number?, -- radius around entry and exit kept free of vegetation
	landmarks: number?, -- largest clearings that get the landmark role
}

Forest.BAND_ORDER = { "open", "sparse", "dense", "rocky" }
Forest.BAND_LETTER = { o = "open", s = "sparse", d = "dense", r = "rocky" }
-- spacing: studs between slot centres; fill: share of slots that hold vegetation (the rest stay
-- empty); tree/bush/rock: kind weights within filled slots.
Forest.BANDS = {
	open = { spacing = 12, fill = 0.4, tree = 0.35, bush = 0.55, rock = 0.1 },
	sparse = { spacing = 10, fill = 0.75, tree = 0.6, bush = 0.3, rock = 0.1 },
	dense = { spacing = 7, fill = 1, tree = 0.8, bush = 0.15, rock = 0.05 },
	rocky = { spacing = 9, fill = 0.85, tree = 0.2, bush = 0.15, rock = 0.65 },
}
Forest.SHARES = { open = 0.2, sparse = 0.35, dense = 0.3, rocky = 0.15 }
-- Footprints match SceneKit Vegetation: trunk 1.4 * scale wide, bush 3 * scale wide.
Forest.TRUNK_RADIUS = 0.7
local BUSH_RADIUS = 1.5
local ROCK_SIDE, ROCK_HEIGHT = { 3, 5 }, { 2, 3.5 }
local CANDIDATE_CELL = 4 -- one jittered candidate per 4 x 4 studs
local GAP = 3 -- studs between collidables: a 2.5-stud character width plus margin
local MIN_CORRIDOR = 6 -- Validate minCorridorStuds default
local PATH_MARGIN = 1 -- extra studs kept clear beyond the corridor and clearing edges
local CLEARING_MARGIN = 20 -- forest kept between clearings and around entry and exit

local function round(value: number, step: number): number
	return math.round(value / step) * step
end

-- Round up to 0.01 so a stored radius does not understate a footprint (the 1e-9 keeps float
-- noise such as 70.00000000000001 from adding a whole 0.01).
local function ceil2(value: number): number
	return math.ceil(value * 100 - 1e-9) / 100
end

function Forest.segmentDistance(px: number, pz: number, a: { number }, b: { number }): number
	local dx, dz = b[1] - a[1], b[2] - a[2]
	local length2 = dx * dx + dz * dz
	local t = if length2 == 0 then 0 else math.clamp(((px - a[1]) * dx + (pz - a[2]) * dz) / length2, 0, 1)
	local qx, qz = a[1] + t * dx - px, a[2] + t * dz - pz
	return math.sqrt(qx * qx + qz * qz)
end

-- Distance from a point to the nearest path centreline.
function Forest.pathDistance(paths, x: number, z: number): number
	local best = math.huge
	for _, path in paths do
		for index = 1, #path.points - 1 do
			best = math.min(best, Forest.segmentDistance(x, z, path.points[index], path.points[index + 1]))
		end
	end
	return best
end

-- Band name at a point (clamped to the map).
function Forest.bandAt(layout, x: number, z: number): string
	local bands = layout.bands
	local col = math.clamp(math.floor(x / bands.cell) + 1, 1, bands.cols)
	local row = math.clamp(math.floor(z / bands.cell) + 1, 1, bands.rows)
	return Forest.BAND_LETTER[string.sub(bands.map[row], col, col)]
end

-- Greedy rectangles of equal band letters, in studs (clipped to the area).
local function mergeTiles(
	map: { string },
	cols: number,
	rows: number,
	cell: number,
	width: number,
	depth: number
)
	local used: { [number]: boolean } = {}
	local tiles = {}
	local function letter(col: number, row: number): string
		return string.sub(map[row], col, col)
	end
	for row = 1, rows do
		for col = 1, cols do
			if not used[(row - 1) * cols + col] then
				local l = letter(col, row)
				local w = 1
				while
					col + w <= cols
					and letter(col + w, row) == l
					and not used[(row - 1) * cols + col + w]
				do
					w += 1
				end
				local h = 1
				local grow = true
				while grow and row + h <= rows do
					for c = col, col + w - 1 do
						if letter(c, row + h) ~= l or used[(row + h - 1) * cols + c] then
							grow = false
							break
						end
					end
					if grow then
						h += 1
					end
				end
				for r = row, row + h - 1 do
					for c = col, col + w - 1 do
						used[(r - 1) * cols + c] = true
					end
				end
				local x, z = (col - 1) * cell, (row - 1) * cell
				table.insert(tiles, {
					band = Forest.BAND_LETTER[l],
					x = x,
					z = z,
					w = math.min(w * cell, width - x),
					d = math.min(h * cell, depth - z),
				})
			end
		end
	end
	return tiles
end

function Forest.generate(params: Params)
	local rng = Rng.new(params.seed)
	local width, depth = params.width or 256, params.depth or 192
	local cell = params.bandCell or 16
	local noiseScale = params.noiseScale or 64
	local pathWidth = params.pathWidth or 8
	local wobble = params.wobble or 10
	local inset = params.spawnInset or 12
	local spawnClear = params.spawnClear or 10
	local radius = params.clearingRadius or { 14, 20 }
	local requested = params.clearings or 4
	local landmarks = params.landmarks or 1
	local shares = table.clone(params.shares or Forest.SHARES)
	local presets = {}
	local maxSpacing = 0
	for _, name in Forest.BAND_ORDER do
		local preset = table.clone(Forest.BANDS[name])
		for key, value in (params.bands and params.bands[name]) or {} do
			(preset :: any)[key] = value
		end
		presets[name] = preset
		maxSpacing = math.max(maxSpacing, preset.spacing)
	end

	-- Band map: rank cells by noise and hand out quantile shares, so every band with a share
	-- exists on every seed and bands follow the noise contours.
	local cols, rows = math.ceil(width / cell), math.ceil(depth / cell)
	local bandSeed = rng:fork("bands").seed
	local ranked = {}
	for row = 1, rows do
		for col = 1, cols do
			local v = Noise.fbm(bandSeed, (col - 0.5) * cell / noiseScale, (row - 0.5) * cell / noiseScale, 3)
			table.insert(ranked, { v = v, index = (row - 1) * cols + col })
		end
	end
	table.sort(ranked, function(a, b)
		if a.v ~= b.v then
			return a.v < b.v
		end
		return a.index < b.index
	end)
	local shareTotal = 0
	for _, name in Forest.BAND_ORDER do
		shareTotal += shares[name] or 0
	end
	assert(shareTotal > 0, "Forest.generate: band shares sum to zero")
	local letters = table.create(#ranked, "")
	local cumulative, assigned = 0, 0
	for index, name in Forest.BAND_ORDER do
		cumulative += (shares[name] or 0) / shareTotal
		local upto = if index == #Forest.BAND_ORDER then #ranked else math.round(cumulative * #ranked)
		while assigned < upto do
			assigned += 1
			letters[ranked[assigned].index] = string.sub(name, 1, 1)
		end
	end
	local map = {}
	for row = 1, rows do
		map[row] = table.concat(letters, "", (row - 1) * cols + 1, row * cols)
	end
	local bands = {
		cell = cell,
		cols = cols,
		rows = rows,
		map = map,
		tiles = mergeTiles(map, cols, rows, cell, width, depth),
	}
	local lookup = { bands = bands }

	-- Entry and exit nodes sit `inset` studs inside the west and east edges.
	local endRng = rng:fork("ends")
	local entryZ = round(endRng:range(depth * 0.3, depth * 0.7), 0.5)
	local exitZ = round(endRng:range(depth * 0.3, depth * 0.7), 0.5)
	local entry = { x = inset, z = entryZ, edge = { 0, entryZ } }
	local exit = { x = width - inset, z = exitZ, edge = { width, exitZ } }

	-- Clearings by rejection sampling, with forest between them and the edges, each other and the
	-- entry/exit pads; a shortfall is kept (Validate fails clearings_placed).
	local clearRng = rng:fork("clearings")
	local clearings = {}
	local rim = CLEARING_MARGIN / 2
	for _ = 1, requested * 100 do
		if #clearings >= requested then
			break
		end
		local r = round(clearRng:range(radius[1], radius[2]), 0.5)
		local x = round(clearRng:range(r + rim, width - r - rim), 0.5)
		local z = round(clearRng:range(r + rim, depth - r - rim), 0.5)
		local ok = x - r >= rim and z - r >= rim and x + r <= width - rim and z + r <= depth - rim
		for _, node in { entry, exit } do
			if math.sqrt((node.x - x) ^ 2 + (node.z - z) ^ 2) < r + spawnClear + CLEARING_MARGIN then
				ok = false
			end
		end
		for _, other in clearings do
			if math.sqrt((other.x - x) ^ 2 + (other.z - z) ^ 2) < r + other.radius + CLEARING_MARGIN then
				ok = false
			end
		end
		if ok then
			table.insert(clearings, { x = x, z = z, radius = r })
		end
	end
	table.sort(clearings, function(a, b)
		if a.x ~= b.x then
			return a.x < b.x
		end
		return a.z < b.z
	end)
	for index, clearing in clearings do
		clearing.id = "C" .. index
	end

	-- Path network: Prim's minimum spanning tree over entry, clearings and exit.
	local graph = Graph.new()
	local nodes = { { id = "entry", x = entry.x, z = entry.z } }
	graph:addNode("entry", "entry")
	for _, clearing in clearings do
		table.insert(nodes, { id = clearing.id, x = clearing.x, z = clearing.z })
		graph:addNode(clearing.id, "clearing")
	end
	table.insert(nodes, { id = "exit", x = exit.x, z = exit.z })
	graph:addNode("exit", "exit")
	local inTree, links = { [1] = true }, {}
	for _ = 2, #nodes do
		local best, from, to = math.huge, 0, 0
		for u = 1, #nodes do
			if inTree[u] then
				for v = 1, #nodes do
					local d = (nodes[u].x - nodes[v].x) ^ 2 + (nodes[u].z - nodes[v].z) ^ 2
					if not inTree[v] and d < best then
						best, from, to = d, u, v
					end
				end
			end
		end
		inTree[to] = true
		table.insert(links, { nodes[from], nodes[to] })
		graph:addEdge(nodes[from].id, nodes[to].id)
	end
	local pathRng = rng:fork("paths")
	local paths = {
		{ id = "edge-entry", from = "edge", to = "entry", points = { entry.edge, { entry.x, entry.z } } },
	}
	for _, link in links do
		local a, b = link[1], link[2]
		local dx, dz = b.x - a.x, b.z - a.z
		local length = math.sqrt(dx * dx + dz * dz)
		local nx, nz = -dz / length, dx / length
		local bend = math.min(wobble, length / 6)
		local points = { { a.x, a.z } }
		for _, t in { 1 / 3, 2 / 3 } do
			local j = pathRng:range(-bend, bend)
			table.insert(points, {
				round(math.clamp(a.x + dx * t + nx * j, pathWidth, width - pathWidth), 0.1),
				round(math.clamp(a.z + dz * t + nz * j, pathWidth, depth - pathWidth), 0.1),
			})
		end
		table.insert(points, { b.x, b.z })
		table.insert(paths, { id = a.id .. "-" .. b.id, from = a.id, to = b.id, points = points })
	end
	table.insert(
		paths,
		{ id = "exit-edge", from = "exit", to = "edge", points = { { exit.x, exit.z }, exit.edge } }
	)

	-- Roles: largest clearings are landmarks; the rest are encounters on the route, treasure off it.
	local onRoute = {}
	for _, id in graph:shortestPath("entry", "exit") or {} do
		onRoute[id] = true
	end
	local bySize = table.clone(clearings)
	table.sort(bySize, function(a, b)
		if a.radius ~= b.radius then
			return a.radius > b.radius
		end
		return a.id < b.id -- total order: table.sort is not stable
	end)
	for index, clearing in bySize do
		clearing.role = if index <= landmarks
			then "landmark"
			elseif onRoute[clearing.id] then "encounter"
			else "treasure"
	end

	-- Vegetation: random sequential adsorption over shuffled jittered candidates. A candidate that
	-- clears the corridor, clearings, entry/exit pads and its neighbours claims a spacing slot;
	-- the band's fill roll decides whether the slot holds vegetation or stays empty (an empty
	-- slot still reserves its space, so fill thins a band instead of only delaying saturation).
	local vegRng = rng:fork("vegetation")
	local corridorHalf = math.max(pathWidth, MIN_CORRIDOR) / 2
	local hashCell = math.max(maxSpacing, GAP + math.sqrt(2) * ROCK_SIDE[2])
	local buckets: { [number]: { any } } = {}
	local function bucket(gx: number, gz: number): number
		return gz * 65536 + gx
	end
	local candidates = {}
	for gz = 0, math.floor(depth / CANDIDATE_CELL) - 1 do
		for gx = 0, math.floor(width / CANDIDATE_CELL) - 1 do
			table.insert(candidates, {
				round((gx + vegRng:range(0.1, 0.9)) * CANDIDATE_CELL, 0.01),
				round((gz + vegRng:range(0.1, 0.9)) * CANDIDATE_CELL, 0.01),
			})
		end
	end
	vegRng:shuffle(candidates)
	local vegetation, counters = {}, { tree = 0, bush = 0, rock = 0 }
	for _, p in candidates do
		local x, z = p[1], p[2]
		local band = Forest.bandAt(lookup, x, z)
		local preset = presets[band]
		local kind = if vegRng:chance(preset.fill)
			then vegRng:weighted({
				{ value = "tree", weight = preset.tree },
				{ value = "bush", weight = preset.bush },
				{ value = "rock", weight = preset.rock },
			})
			else "empty"
		local item: { [string]: any } = { kind = kind, band = band, x = x, z = z, r = 0 }
		local footprint = 0
		if kind == "tree" then
			item.scale = round(vegRng:range(0.8, 1.4), 0.01)
			item.r = ceil2(Forest.TRUNK_RADIUS * item.scale)
			footprint = item.r
		elseif kind == "bush" then
			item.scale = round(vegRng:range(0.8, 1.3), 0.01)
			footprint = BUSH_RADIUS * item.scale -- r stays 0: bushes do not collide
		elseif kind == "rock" then
			local w = round(vegRng:range(ROCK_SIDE[1], ROCK_SIDE[2]), 0.1)
			local d = round(vegRng:range(ROCK_SIDE[1], ROCK_SIDE[2]), 0.1)
			item.size = { w, round(vegRng:range(ROCK_HEIGHT[1], ROCK_HEIGHT[2]), 0.1), d }
			item.yaw = vegRng:int(0, 89)
			item.r = ceil2(math.sqrt(w * w + d * d) / 2) -- circumscribed, so it holds at any yaw
			footprint = item.r
		end
		local ok = x >= footprint
			and z >= footprint
			and x + footprint <= width
			and z + footprint <= depth
			and Forest.pathDistance(paths, x, z) >= corridorHalf + PATH_MARGIN + footprint
		for _, clearing in clearings do
			local d = math.sqrt((clearing.x - x) ^ 2 + (clearing.z - z) ^ 2)
			ok = ok and d >= clearing.radius + PATH_MARGIN + footprint
		end
		for _, node in { entry, exit } do
			ok = ok and math.sqrt((node.x - x) ^ 2 + (node.z - z) ^ 2) >= spawnClear + footprint
		end
		local gx, gz = math.floor(x / hashCell), math.floor(z / hashCell)
		for oz = -1, 1 do
			for ox = -1, 1 do
				for _, other in (ok and buckets[bucket(gx + ox, gz + oz)]) or {} do
					local d = math.sqrt((other.x - x) ^ 2 + (other.z - z) ^ 2)
					if
						d < math.max(preset.spacing, presets[other.band].spacing)
						or (item.r > 0 and other.r > 0 and d - item.r - other.r < GAP)
					then
						ok = false
					end
				end
			end
		end
		if ok then
			local key = bucket(gx, gz)
			buckets[key] = buckets[key] or {}
			table.insert(buckets[key], item)
			if kind ~= "empty" then
				counters[kind] += 1
				item.id = kind .. counters[kind]
				table.insert(vegetation, item)
			end
		end
	end

	return {
		kind = "forest",
		params = {
			seed = params.seed,
			width = width,
			depth = depth,
			bandCell = cell,
			noiseScale = noiseScale,
			shares = shares,
			bands = presets,
			clearings = requested,
			clearingRadius = radius,
			pathWidth = pathWidth,
			wobble = wobble,
			spawnInset = inset,
			spawnClear = spawnClear,
			landmarks = landmarks,
		},
		bands = bands,
		entry = entry,
		exit = exit,
		clearings = clearings,
		paths = paths,
		graph = graph,
		vegetation = vegetation,
	}
end

-- Parts ForestScene.toScene emits: ground tiles, path strips and bend joints, one pad and one
-- marker per clearing, entry and exit markers, two parts per tree, one per bush or rock.
function Forest.partEstimate(layout): number
	local parts = #layout.bands.tiles + 2 * #layout.clearings + 2
	for _, path in layout.paths do
		local points = path.points
		for index = 1, #points - 1 do
			local dx, dz = points[index + 1][1] - points[index][1], points[index + 1][2] - points[index][2]
			if math.sqrt(dx * dx + dz * dz) > 1e-3 then
				parts += 1
			end
		end
		parts += math.max(0, #points - 2)
	end
	for _, item in layout.vegetation do
		parts += if item.kind == "tree" then 2 else 1
	end
	return parts
end

-- ASCII map, one character per `cellStuds` (default 4): band . open , sparse ; dense ^ rocky,
-- * clearing, = path, b bush, T trunk, R rock, 1-9 clearing centres, E entry, X exit.
local BAND_CHAR = { open = ".", sparse = ",", dense = ";", rocky = "^" }
function Forest.toAscii(layout, cellStuds: number?): string
	local cs = cellStuds or 4
	local cols, rows = math.ceil(layout.params.width / cs), math.ceil(layout.params.depth / cs)
	local half = layout.params.pathWidth / 2
	local chars = {}
	for row = 1, rows do
		for col = 1, cols do
			local x, z = (col - 0.5) * cs, (row - 0.5) * cs
			local ch = BAND_CHAR[Forest.bandAt(layout, x, z)]
			for _, clearing in layout.clearings do
				if (clearing.x - x) ^ 2 + (clearing.z - z) ^ 2 <= clearing.radius ^ 2 then
					ch = "*"
				end
			end
			if Forest.pathDistance(layout.paths, x, z) <= half then
				ch = "="
			end
			chars[(row - 1) * cols + col] = ch
		end
	end
	local function mark(x: number, z: number, ch: string)
		local col = math.clamp(math.floor(x / cs) + 1, 1, cols)
		local row = math.clamp(math.floor(z / cs) + 1, 1, rows)
		chars[(row - 1) * cols + col] = ch
	end
	for _, pass in { "bush", "tree", "rock" } do
		for _, item in layout.vegetation do
			if item.kind == pass then
				mark(item.x, item.z, if pass == "bush" then "b" elseif pass == "tree" then "T" else "R")
			end
		end
	end
	for index, clearing in layout.clearings do
		mark(clearing.x, clearing.z, tostring(index % 10))
	end
	mark(layout.entry.x, layout.entry.z, "E")
	mark(layout.exit.x, layout.exit.z, "X")
	local lines = {}
	for row = 1, rows do
		lines[row] = table.concat(chars, "", (row - 1) * cols + 1, row * cols)
	end
	return table.concat(lines, "\n")
end

return Forest
