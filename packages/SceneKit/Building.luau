--!strict
-- Architectural primitives (walls with openings, floors with holes, roofs, stairs, ramps,
-- railings, columns, arches, trim, foundations) and a composed Building.create that turns
-- footprint + storey requirements into a validated, dressed-ready shell.
local Rng = require("../ProcGen/Rng")
local Measure = require("./Measure")
local Scene = require("./Scene")
local Vec = require("./Vec")

local Building = {}
type Scene = Scene.Scene
type V3 = Vec.V3
export type Rect = { x: number, z: number, w: number, d: number } -- min corner + size (studs)
export type Opening = {
	at: number,
	width: number,
	bottom: number,
	height: number,
	kind: ("door" | "window" | "gap")?,
}

local function yawFor(dx: number, dz: number): number
	return math.deg(math.atan2(-dz, dx))
end

-- Wall along a centreline with doors/windows cut out. `at` is the opening centre measured
-- from `from`. Returns the opening records (world positions) for validation.
function Building.wall(
	scene: Scene,
	options: {
		from: { number },
		to: { number },
		y: number,
		height: number,
		thickness: number?,
		openings: { Opening }?,
		role: string?,
		glass: boolean?,
	}
)
	local fx, fz, tx, tz = options.from[1], options.from[2], options.to[1], options.to[2]
	local length = math.sqrt((tx - fx) ^ 2 + (tz - fz) ^ 2)
	assert(length > 0, "zero-length wall")
	local thickness = options.thickness or 1
	local height = options.height
	local role = options.role or "wall"
	local dir = { x = (tx - fx) / length, z = (tz - fz) / length }
	local yaw = yawFor(dir.x, dir.z)
	local openings = table.clone(options.openings or {})
	table.sort(openings, function(a, b)
		return a.at < b.at
	end)
	local function piece(
		u0: number,
		u1: number,
		y0: number,
		y1: number,
		pieceRole: string?,
		extra: { [string]: any }?
	)
		if u1 - u0 < 1e-3 or y1 - y0 < 1e-3 then
			return
		end
		local mid = (u0 + u1) / 2
		local spec: any = {
			role = pieceRole or role,
			size = { x = u1 - u0, y = y1 - y0, z = thickness },
			pos = { x = fx + dir.x * mid, y = options.y + (y0 + y1) / 2, z = fz + dir.z * mid },
			rot = { x = 0, y = yaw, z = 0 },
		}
		for key, value in extra or {} do
			spec[key] = value
		end
		scene:add(spec)
	end
	local cursor = 0
	local records = {}
	for _, opening in openings do
		local u0, u1 = opening.at - opening.width / 2, opening.at + opening.width / 2
		assert(
			u0 >= cursor - 1e-6 and u1 <= length + 1e-6,
			"opening outside wall or overlapping another opening"
		)
		assert(
			opening.bottom >= 0 and opening.bottom + opening.height <= height + 1e-6,
			"opening taller than wall"
		)
		piece(cursor, u0, 0, height)
		piece(u0, u1, 0, opening.bottom)
		piece(u0, u1, opening.bottom + opening.height, height)
		if opening.kind == "window" and options.glass ~= false then
			piece(u0, u1, opening.bottom, opening.bottom + opening.height, "glass", {
				size = { x = opening.width, y = opening.height, z = math.min(0.2, thickness) },
				transparency = scene.style.windowTransparency,
				canCollide = true,
			})
		end
		-- dir (wall axis) and thickness let Validate measure the clear width actually left at the
		-- opening once other walls are taken into account.
		local record = {
			kind = opening.kind or "gap",
			width = opening.width,
			height = opening.height,
			bottom = opening.bottom,
			pos = { x = fx + dir.x * opening.at, y = options.y + opening.bottom, z = fz + dir.z * opening.at },
			dir = { x = dir.x, y = 0, z = dir.z },
			thickness = thickness,
			group = scene:currentGroup(),
		}
		if record.kind == "door" or record.kind == "gap" then
			table.insert(scene.meta.doors, record)
		end
		table.insert(records, record)
		cursor = u1
	end
	piece(cursor, length, 0, height)
	return records
end

-- Floor slab whose top surface is at `y`, optionally with one rectangular hole (stairwell).
function Building.floor(
	scene: Scene,
	options: { rect: Rect, y: number, thickness: number?, hole: Rect?, role: string? }
)
	local r, t = options.rect, options.thickness or 1
	local role = options.role or "floor"
	local y0, y1 = options.y - t, options.y
	local function slab(x0, z0, x1, z1)
		if x1 - x0 > 1e-3 and z1 - z0 > 1e-3 then
			scene:box(role, { x = x0, y = y0, z = z0 }, { x = x1, y = y1, z = z1 })
		end
	end
	local x0, z0, x1, z1 = r.x, r.z, r.x + r.w, r.z + r.d
	local hole = options.hole
	if hole == nil then
		slab(x0, z0, x1, z1)
		return
	end
	local hx0, hz0 = math.max(x0, hole.x), math.max(z0, hole.z)
	local hx1, hz1 = math.min(x1, hole.x + hole.w), math.min(z1, hole.z + hole.d)
	slab(x0, z0, x1, hz0) -- front strip
	slab(x0, hz1, x1, z1) -- back strip
	slab(x0, hz0, hx0, hz1) -- left
	slab(hx1, hz0, x1, hz1) -- right
end

function Building.foundation(
	scene: Scene,
	options: { rect: Rect, y: number, height: number, outset: number? }
)
	local r, o = options.rect, options.outset or 0.5
	scene:box(
		"foundation",
		{ x = r.x - o, y = options.y, z = r.z - o },
		{ x = r.x + r.w + o, y = options.y + options.height, z = r.z + r.d + o }
	)
end

-- Band of trim around a rectangle (outside face), e.g. storey lines and cornices.
function Building.trim(scene: Scene, options: { rect: Rect, y: number, height: number?, depth: number? })
	local r, h, d = options.rect, options.height or 0.5, options.depth or 0.4
	local y0, y1 = options.y - h / 2, options.y + h / 2
	scene:box("trim", { x = r.x - d, y = y0, z = r.z - d }, { x = r.x + r.w + d, y = y1, z = r.z })
	scene:box(
		"trim",
		{ x = r.x - d, y = y0, z = r.z + r.d },
		{ x = r.x + r.w + d, y = y1, z = r.z + r.d + d }
	)
	scene:box("trim", { x = r.x - d, y = y0, z = r.z }, { x = r.x, y = y1, z = r.z + r.d })
	scene:box("trim", { x = r.x + r.w, y = y0, z = r.z }, { x = r.x + r.w + d, y = y1, z = r.z + r.d })
end

-- Roof over a rectangle whose eaves sit at `y`. Gable ridge runs along the longer side.
function Building.roof(
	scene: Scene,
	options: {
		rect: Rect,
		y: number,
		style: ("gable" | "shed" | "flat")?,
		pitch: number?,
		overhang: number?,
		thickness: number?,
		parapet: number?,
	}
)
	local r = options.rect
	local style = options.style or "gable"
	local t = options.thickness or 1
	local overhang = options.overhang or 1.5
	local cx, cz = r.x + r.w / 2, r.z + r.d / 2
	if style == "flat" then
		scene:box(
			"roof",
			{ x = r.x - overhang, y = options.y, z = r.z - overhang },
			{ x = r.x + r.w + overhang, y = options.y + t, z = r.z + r.d + overhang }
		)
		local p = options.parapet or 2
		if p > 0 then
			Building.wall(scene, {
				from = { r.x - overhang, r.z - overhang + 0.25 },
				to = { r.x + r.w + overhang, r.z - overhang + 0.25 },
				y = options.y + t,
				height = p,
				thickness = 0.5,
				role = "trim",
			})
			Building.wall(scene, {
				from = { r.x - overhang, r.z + r.d + overhang - 0.25 },
				to = { r.x + r.w + overhang, r.z + r.d + overhang - 0.25 },
				y = options.y + t,
				height = p,
				thickness = 0.5,
				role = "trim",
			})
			Building.wall(scene, {
				from = { r.x - overhang + 0.25, r.z - overhang + 0.5 },
				to = { r.x - overhang + 0.25, r.z + r.d + overhang - 0.5 },
				y = options.y + t,
				height = p,
				thickness = 0.5,
				role = "trim",
			})
			Building.wall(scene, {
				from = { r.x + r.w + overhang - 0.25, r.z - overhang + 0.5 },
				to = { r.x + r.w + overhang - 0.25, r.z + r.d + overhang - 0.5 },
				y = options.y + t,
				height = p,
				thickness = 0.5,
				role = "trim",
			})
		end
		return { ridgeHeight = options.y + t + p }
	end
	-- Build with the ridge along local X, then rotate 90 degrees if the footprint is deeper.
	local alongX = r.w >= r.d
	local length = if alongX then r.w else r.d
	local span = if alongX then r.d else r.w
	local pitch = options.pitch or 30
	local yaw = if alongX then 0 else 90
	local ridge = 0
	scene:transformed({ x = cx, y = 0, z = cz }, yaw, function()
		local half = span / 2
		if style == "shed" then
			local rise = span * math.tan(math.rad(pitch))
			local slope = (span + 2 * overhang) / math.cos(math.rad(pitch))
			scene:add({
				role = "roof",
				size = { x = length + 2 * overhang, y = t, z = slope },
				pos = { x = 0, y = options.y + rise / 2 + t / 2, z = 0 },
				rot = { x = -pitch, y = 0, z = 0 },
			})
			ridge = options.y + rise + t
			return
		end
		local rise = half * math.tan(math.rad(pitch))
		local run = half + overhang
		local slope = run / math.cos(math.rad(pitch))
		-- Slab centre sits on the roof line midway between ridge and eave, lifted by half thickness.
		-- side = +1 is the +Z slope: positive X rotation tips its local +Z (away from the ridge) down.
		local midZ = run / 2
		local midY = options.y + rise - (run / 2) * math.tan(math.rad(pitch))
		local lift = (t / 2) / math.cos(math.rad(pitch))
		for _, side in { -1, 1 } do
			scene:add({
				role = "roof",
				size = { x = length + 2 * overhang, y = t, z = slope },
				pos = { x = 0, y = midY + lift, z = side * midZ },
				rot = { x = side * pitch, y = 0, z = 0 },
			})
		end
		-- Gable end triangles from two wedges each (vertical face toward the ridge).
		for _, endX in { -length / 2 + 0.5, length / 2 - 0.5 } do
			scene:add({
				role = "wall",
				shape = "Wedge",
				size = { x = 1, y = rise, z = half },
				pos = { x = endX, y = options.y + rise / 2, z = -half / 2 },
				rot = { x = 0, y = 0, z = 0 },
			})
			scene:add({
				role = "wall",
				shape = "Wedge",
				size = { x = 1, y = rise, z = half },
				pos = { x = endX, y = options.y + rise / 2, z = half / 2 },
				rot = { x = 0, y = 180, z = 0 },
			})
		end
		ridge = options.y + rise + t
	end)
	return { ridgeHeight = ridge }
end

-- Straight stair. `yaw` turns local +X (the ascent direction) like Roblox's Y rotation.
function Building.stairs(
	scene: Scene,
	options: {
		base: V3,
		yaw: number?,
		rise: number,
		width: number?,
		stepRise: number?,
		stepRun: number?,
		role: string?,
	}
)
	local stepRiseTarget = options.stepRise or 1
	local count = math.max(1, math.ceil(options.rise / stepRiseTarget - 1e-6))
	local stepRise = options.rise / count
	local stepRun = options.stepRun or 1.5
	local width = options.width or 6
	local yaw = options.yaw or 0
	scene:transformed(options.base, yaw, function()
		for index = 1, count do
			local top = index * stepRise
			scene:add({
				role = options.role or "stair",
				size = { x = stepRun, y = top, z = width },
				pos = { x = (index - 0.5) * stepRun, y = top / 2, z = 0 },
			})
		end
	end)
	local record = {
		pos = options.base,
		yaw = yaw,
		steps = count,
		stepRise = stepRise,
		stepRun = stepRun,
		width = width,
		run = count * stepRun,
		rise = options.rise,
	}
	table.insert(scene.meta.stairs, record)
	return record
end

-- Wedge ramp rising along the yaw direction (local +Z of the wedge after rotation).
function Building.ramp(
	scene: Scene,
	options: { base: V3, yaw: number?, rise: number, run: number, width: number? }
)
	local yaw = options.yaw or 0
	scene:transformed(options.base, yaw, function()
		-- Wedge high side is local +Z (back); yaw +90 turns local +Z to +X so ascent follows +X like stairs.
		scene:add({
			role = "stair",
			shape = "Wedge",
			size = { x = options.width or 6, y = options.rise, z = options.run },
			pos = { x = options.run / 2, y = options.rise / 2, z = 0 },
			rot = { x = 0, y = 90, z = 0 },
		})
	end)
	return { slope = math.deg(math.atan2(options.rise, options.run)) }
end

function Building.railing(
	scene: Scene,
	options: { from: V3, to: V3, height: number?, spacing: number?, role: string? }
)
	local height = options.height or 3.5
	local role = options.role or "trim"
	local delta = Vec.sub(options.to, options.from)
	local length = math.sqrt(delta.x ^ 2 + delta.z ^ 2)
	local yaw = yawFor(delta.x / length, delta.z / length)
	local posts = math.max(1, math.ceil(length / (options.spacing or 4)))
	for index = 0, posts do
		local p = Vec.lerp(options.from, options.to, index / posts)
		scene:add({
			role = role,
			size = { x = 0.4, y = height, z = 0.4 },
			pos = { x = p.x, y = p.y + height / 2, z = p.z },
		})
	end
	local mid = Vec.lerp(options.from, options.to, 0.5)
	for _, h in { height - 0.15, height / 2 } do
		scene:add({
			role = role,
			size = { x = length, y = 0.3, z = 0.3 },
			pos = { x = mid.x, y = mid.y + h, z = mid.z },
			rot = { x = 0, y = yaw, z = 0 },
		})
	end
end

function Building.column(scene: Scene, options: { pos: V3, height: number, size: number?, round: boolean? })
	local s = options.size or 2
	local base = options.pos
	scene:add({
		role = "trim",
		size = { x = s * 1.4, y = 0.6, z = s * 1.4 },
		pos = { x = base.x, y = base.y + 0.3, z = base.z },
	})
	local shaftHeight = options.height - 1.2
	if options.round then
		-- Roblox cylinders extend along X; roll 90 degrees to stand upright.
		scene:add({
			role = "wall",
			shape = "Cylinder",
			size = { x = shaftHeight, y = s, z = s },
			pos = { x = base.x, y = base.y + 0.6 + shaftHeight / 2, z = base.z },
			rot = { x = 0, y = 0, z = 90 },
		})
	else
		scene:add({
			role = "wall",
			size = { x = s, y = shaftHeight, z = s },
			pos = { x = base.x, y = base.y + 0.6 + shaftHeight / 2, z = base.z },
		})
	end
	scene:add({
		role = "trim",
		size = { x = s * 1.4, y = 0.6, z = s * 1.4 },
		pos = { x = base.x, y = base.y + options.height - 0.3, z = base.z },
	})
end

-- Semicircular arch of voussoir blocks. `pos` is the springing-line centre.
function Building.arch(
	scene: Scene,
	options: {
		pos: V3,
		span: number,
		thickness: number?,
		depth: number?,
		segments: number?,
		yaw: number?,
	}
)
	local segments = options.segments or 9
	local t = options.thickness or 1
	local radius = options.span / 2 + t / 2
	scene:transformed(options.pos, options.yaw or 0, function()
		for index = 0, segments - 1 do
			local angle = math.pi * (index + 0.5) / segments
			local chord = 2 * radius * math.sin(math.pi / (2 * segments)) + 0.05
			scene:add({
				role = "trim",
				size = { x = chord, y = t, z = options.depth or 1 },
				pos = { x = radius * math.cos(angle), y = radius * math.sin(angle), z = 0 },
				rot = { x = 0, y = 0, z = math.deg(angle) - 90 },
			})
		end
	end)
end

-- Evenly spaced window openings along a wall, skipping reserved intervals (doors).
function Building.windowRun(
	length: number,
	options: {
		width: number,
		height: number,
		sill: number,
		spacing: number,
		margin: number?,
		reserved: { { number } }?,
	}
): { Opening }
	local margin = options.margin or 2
	local usable = length - 2 * margin
	local count = math.floor((usable + options.spacing - options.width) / options.spacing)
	if count < 1 then
		return {}
	end
	local used = (count - 1) * options.spacing + options.width
	local start = margin + (usable - used) / 2 + options.width / 2
	local result = {}
	for index = 0, count - 1 do
		local at = start + index * options.spacing
		local clash = false
		for _, interval in options.reserved or {} do
			if at + options.width / 2 + 1 > interval[1] and at - options.width / 2 - 1 < interval[2] then
				clash = true
			end
		end
		if not clash then
			table.insert(result, {
				at = at,
				width = options.width,
				bottom = options.sill,
				height = options.height,
				kind = "window",
			})
		end
	end
	return result
end

-- A doorway on the boundary of a subdivided rect, as a span along the wall's inner face in the
-- rect's XZ coordinates, e.g. the front door: { from = { x0, innerZ }, to = { x1, innerZ } }.
export type DoorSpan = { from: { number }, to: { number } }
export type Partition = { from: { number }, to: { number }, door: { at: number, width: number }? }

-- BSP subdivision of an interior rectangle into rooms; returns rooms and partition walls, each
-- with the door it should carry (`door.at` measured from `from`; nil when no door fits).
-- Doorways are never bisected: a cut may not end inside a reserved span (plus half the partition
-- thickness and half a character width either side); when the drawn position would, the nearest
-- free whole-stud position is used, then the other axis, else the rect stays one room. Partition
-- doors are placed after all cuts, centred in the longest run between T-junctions and kept a
-- character half-width clear of the walls that meet there.
function Building.subdivide(
	rect: Rect,
	rng,
	minRoom: number,
	options: { reserved: { DoorSpan }?, doorWidth: number?, thickness: number? }?
): ({ Rect }, { Partition })
	local reserved = options and options.reserved or {}
	local doorWidth = options and options.doorWidth or 5
	local halfT = (options and options.thickness or 0.5) / 2
	local clearance = halfT + Measure.GUIDE.characterWidth / 2
	local rooms: { Rect }, partitions: { Partition } = {}, {}

	-- Would a cut at `at` (x = at when cutX, else z = at) end inside a reserved doorway on one of
	-- the rect edges e0/e1 it runs between?
	local function blocked(cutX: boolean, at: number, e0: number, e1: number): boolean
		local along, across = if cutX then 1 else 2, if cutX then 2 else 1
		for _, span in reserved do
			if math.abs(span.from[across] - span.to[across]) < 1e-6 then
				local line = span.from[across]
				local lo = math.min(span.from[along], span.to[along])
				local hi = math.max(span.from[along], span.to[along])
				if
					(math.abs(line - e0) < 1e-6 or math.abs(line - e1) < 1e-6)
					and at > lo - clearance
					and at < hi + clearance
				then
					return true
				end
			end
		end
		return false
	end

	local function chooseCut(cutX: boolean, r: Rect): number?
		local origin, size = if cutX then r.x else r.z, if cutX then r.w else r.d
		local e0, e1 = if cutX then r.z else r.x, if cutX then r.z + r.d else r.x + r.w
		local want = math.round(rng:range(minRoom, size - minRoom))
		if not blocked(cutX, origin + want, e0, e1) then
			return origin + want
		end
		local best: number? = nil
		for offset = math.ceil(minRoom), math.floor(size - minRoom) do
			if
				not blocked(cutX, origin + offset, e0, e1)
				and (best == nil or math.abs(offset - want) < math.abs(best - want))
			then
				best = offset
			end
		end
		return if best then origin + best else nil
	end

	local function split(r: Rect, depth: number)
		local canX, canZ = r.w >= minRoom * 2, r.d >= minRoom * 2
		if depth > 3 or (not canX and not canZ) then
			table.insert(rooms, r)
			return
		end
		local cutX = if canX and canZ then r.w >= r.d else canX
		local at = chooseCut(cutX, r)
		if at == nil and (if cutX then canZ else canX) then
			cutX = not cutX
			at = chooseCut(cutX, r)
		end
		if at == nil then
			table.insert(rooms, r)
		elseif cutX then
			table.insert(partitions, { from = { at, r.z }, to = { at, r.z + r.d } })
			split({ x = r.x, z = r.z, w = at - r.x, d = r.d }, depth + 1)
			split({ x = at, z = r.z, w = r.x + r.w - at, d = r.d }, depth + 1)
		else
			table.insert(partitions, { from = { r.x, at }, to = { r.x + r.w, at } })
			split({ x = r.x, z = r.z, w = r.w, d = at - r.z }, depth + 1)
			split({ x = r.x, z = at, w = r.w, d = r.z + r.d - at }, depth + 1)
		end
	end
	split(rect, 0)

	-- Doors: partition ends keep the 1-stud jamb they always had and a T-junction (another
	-- partition ending on this one) keeps `clearance`; only when no run fits a minimum door that
	-- way are both relaxed to the abutting wall face (clear width is still the full door width).
	for _, p in partitions do
		local along = if p.from[1] == p.to[1] then 2 else 1
		local across = 3 - along
		local length = p.to[along] - p.from[along]
		local marks = { { u = 0, junction = false }, { u = length, junction = false } }
		for _, q in partitions do
			if q ~= p then
				for _, e in { q.from, q.to } do
					if
						math.abs(e[across] - p.from[across]) < 1e-6
						and e[along] > p.from[along] + 1e-6
						and e[along] < p.to[along] - 1e-6
					then
						table.insert(marks, { u = e[along] - p.from[along], junction = true })
					end
				end
			end
		end
		table.sort(marks, function(a, b)
			return a.u < b.u
		end)
		for _, margins in { { 1, clearance }, { halfT, halfT } } do
			local bestLo, bestHi = 0, -1
			for index = 1, #marks - 1 do
				local a, b = marks[index], marks[index + 1]
				local lo = a.u + (if a.junction then margins[2] else margins[1])
				local hi = b.u - (if b.junction then margins[2] else margins[1])
				if hi - lo > bestHi - bestLo then
					bestLo, bestHi = lo, hi
				end
			end
			local width = math.min(doorWidth, bestHi - bestLo)
			if width >= Measure.GUIDE.doorMin.width then
				p.door = { at = (bestLo + bestHi) / 2, width = width }
				break
			end
		end
	end
	return rooms, partitions
end

export type BuildingOptions = {
	name: string?,
	footprint: Rect,
	y: number?,
	storeys: number?,
	storeyHeight: number?,
	wallThickness: number?,
	floorThickness: number?,
	foundationHeight: number?,
	door: { width: number, height: number }?,
	window: { width: number, height: number, sill: number, spacing: number }?,
	roof: { style: ("gable" | "shed" | "flat")?, pitch: number?, overhang: number? }?,
	interior: { minRoom: number }? | false,
	stairs: boolean?,
	seed: (number | string)?,
}

-- Compose a complete shell. Front (main door) faces -Z; use Scene.transformed to rotate.
function Building.create(scene: Scene, options: BuildingOptions)
	local fp = options.footprint
	local rng = Rng.new(options.seed or scene.seed):fork(options.name or "building")
	local storeys = options.storeys or 2
	local storeyHeight = options.storeyHeight or 12
	local t = options.wallThickness or 1
	local floorT = options.floorThickness or 1
	local foundationH = options.foundationHeight or 1
	local door = options.door or { width = 6, height = 8 }
	local window = options.window or { width = 4, height = 5, sill = 3, spacing = 8 }
	local y0 = options.y or 0
	local stairsWanted = storeys > 1 and options.stairs ~= false
	local stairWidth, stairRun = 5, 1.5
	local railDepth = 0.4 -- Building.railing post size
	local summary = { name = options.name or "Building", storeys = storeys, rooms = {}, ridge = 0 }

	return scene:group(options.name or "Building", function()
		Building.foundation(scene, { rect = fp, y = y0, height = foundationH })
		local inner: Rect = { x = fp.x + t, z = fp.z + t, w = fp.w - 2 * t, d = fp.d - 2 * t }
		assert(inner.w >= 8 and inner.d >= 8, "footprint too small for a usable interior")
		local stepCount = math.ceil(storeyHeight - 1e-6)
		local stairLength = stepCount * stairRun
		-- Stair hall along the back wall. Flights alternate between two parallel lanes so no
		-- flight runs underneath another (headroom); a two-storey building needs one lane.
		local stairHole: Rect? = nil -- whole hall (both lanes)
		local lanes: { Rect } = {}
		if stairsWanted then
			assert(inner.w >= stairLength + 2, "footprint too narrow for stairs; widen or set stairs=false")
			local laneCount = if storeys > 2 then 2 else 1
			local backZ = inner.z + inner.d - 0.5
			for lane = 1, laneCount do
				table.insert(
					lanes,
					{ x = inner.x + 1, z = backZ - lane * stairWidth, w = stairLength, d = stairWidth }
				)
			end
			stairHole = {
				x = inner.x + 1,
				z = backZ - laneCount * stairWidth,
				w = stairLength,
				d = laneCount * stairWidth,
			}
		end
		local doorAt = fp.w / 2 + rng:range(-1, 1) * math.max(0, fp.w / 2 - door.width - 4)
		for storey = 0, storeys - 1 do
			scene:group("Storey" .. (storey + 1), function()
				local base = y0 + foundationH + storey * storeyHeight
				if storey > 0 then
					-- Opening above the flight that arrives here.
					Building.floor(scene, {
						rect = inner,
						y = base,
						thickness = floorT,
						hole = lanes[(storey - 1) % #lanes + 1],
					})
				else
					Building.floor(scene, { rect = inner, y = base, thickness = 0.2 })
				end
				-- Exterior walls: front/back span the full width; sides fit between them.
				local frontReserved = {}
				local frontOpenings = {}
				if storey == 0 then
					table.insert(
						frontOpenings,
						{ at = doorAt, width = door.width, bottom = 0, height = door.height, kind = "door" }
					)
					table.insert(frontReserved, { doorAt - door.width / 2, doorAt + door.width / 2 })
				end
				local wobble = rng:pick({ 0, 0, 1 }) -- facade variation: occasional wider windows
				local win = {
					width = window.width + wobble * 2,
					height = window.height,
					sill = window.sill,
					spacing = window.spacing + wobble * 2,
				}
				for _, opening in
					Building.windowRun(fp.w, {
						width = win.width,
						height = win.height,
						sill = win.sill,
						spacing = win.spacing,
						reserved = frontReserved,
					})
				do
					table.insert(frontOpenings, opening)
				end
				Building.wall(scene, {
					from = { fp.x, fp.z + t / 2 },
					to = { fp.x + fp.w, fp.z + t / 2 },
					y = base,
					height = storeyHeight,
					thickness = t,
					openings = frontOpenings,
				})
				local backReserved = if stairHole then { { 0, fp.w } } else {}
				Building.wall(scene, {
					from = { fp.x + fp.w, fp.z + fp.d - t / 2 },
					to = { fp.x, fp.z + fp.d - t / 2 },
					y = base,
					height = storeyHeight,
					thickness = t,
					openings = Building.windowRun(fp.w, {
						width = win.width,
						height = win.height,
						sill = win.sill,
						spacing = win.spacing,
						reserved = backReserved,
					}),
				})
				local sideLength = fp.d - 2 * t
				for _, side in { { fp.x + t / 2, 1 }, { fp.x + fp.w - t / 2, -1 } } do
					local x, dir = side[1], side[2]
					local from = if dir > 0 then { x, fp.z + fp.d - t } else { x, fp.z + t }
					local to = if dir > 0 then { x, fp.z + t } else { x, fp.z + fp.d - t }
					local sideWindows = if rng:chance(0.8)
						then Building.windowRun(sideLength, {
							width = window.width,
							height = window.height,
							sill = window.sill,
							spacing = window.spacing + 4,
						})
						else {}
					Building.wall(scene, {
						from = from,
						to = to,
						y = base,
						height = storeyHeight,
						thickness = t,
						openings = sideWindows,
					})
				end
				local clearHeight = storeyHeight - floorT
				-- Interior rooms in front of the stair hall.
				local roomArea: Rect = if stairHole
					then { x = inner.x, z = inner.z, w = inner.w, d = stairHole.z - inner.z - 0.5 }
					else inner
				local rooms: { Rect }, partitions: { Partition } = { roomArea }, {}
				if options.interior ~= false then
					local minRoom = (options.interior and (options.interior :: any).minRoom) or 10
					-- The front door sits on the room area's front edge (the front wall's inner face).
					local reserved: { DoorSpan } = if storey == 0
						then {
							{
								from = { fp.x + doorAt - door.width / 2, inner.z },
								to = { fp.x + doorAt + door.width / 2, inner.z },
							},
						}
						else {}
					rooms, partitions = Building.subdivide(
						roomArea,
						rng:fork("rooms" .. storey),
						minRoom,
						{ reserved = reserved, doorWidth = 5, thickness = 0.5 }
					)
				end
				for _, partition in partitions do
					local partitionDoor = partition.door
					Building.wall(scene, {
						from = partition.from,
						to = partition.to,
						y = base,
						height = clearHeight,
						thickness = 0.5,
						openings = if partitionDoor
							then {
								{
									at = partitionDoor.at,
									width = partitionDoor.width,
									bottom = 0,
									height = math.min(8, clearHeight - 1),
									kind = "door",
								},
							}
							else {},
					})
				end
				if stairHole then
					-- The stair hall stays open to the rooms (no wall line between them).
					local hole = if storey > 0 then lanes[(storey - 1) % #lanes + 1] else nil
					if storey < storeys - 1 then
						local lane = lanes[storey % #lanes + 1]
						-- A flight that starts directly in front of the hole this storey was reached
						-- through shares its back edge with that hole's railing (3+ storeys): narrow
						-- it by the railing depth so posts and rails stand on the slab, not in the steps.
						local inset = if hole and hole ~= lane and lane.z < hole.z then railDepth else 0
						local flightWidth = stairWidth - 0.2 - inset
						Building.stairs(scene, {
							base = { x = lane.x, y = base, z = lane.z + (stairWidth - inset) / 2 },
							yaw = 0,
							rise = storeyHeight,
							width = flightWidth,
							stepRise = storeyHeight / stepCount,
							stepRun = stairRun,
						})
					end
					if hole then
						-- Railing along the hole's front edge, on the slab in front of it.
						Building.railing(scene, {
							from = { x = hole.x, y = base, z = hole.z - railDepth / 2 },
							to = { x = hole.x + hole.w - stairRun * 2, y = base, z = hole.z - railDepth / 2 },
						})
					end
				end
				for index, room in rooms do
					table.insert(scene.meta.rooms, {
						id = summary.name .. "/S" .. (storey + 1) .. "R" .. index,
						rect = room,
						floorY = base,
						clearHeight = clearHeight,
					})
					table.insert(summary.rooms, room)
				end
				if scene.style.trim then
					Building.trim(scene, { rect = fp, y = base + storeyHeight, height = 0.6, depth = 0.4 })
				end
			end)
		end
		local top = y0 + foundationH + storeys * storeyHeight
		Building.floor(scene, { rect = inner, y = top, thickness = floorT, role = "floor" })
		local roofOptions = options.roof or {}
		local roof = Building.roof(scene, {
			rect = fp,
			y = top,
			style = roofOptions.style,
			pitch = roofOptions.pitch,
			overhang = roofOptions.overhang,
		})
		summary.ridge = roof.ridgeHeight
		return summary
	end)
end

return Building
