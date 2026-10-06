--!strict
-- Prop placement: single placement, Poisson-disc scatter with exclusions, snapping,
-- alignment to walls and even distribution along lines. Props are placeholder blocks
-- tagged with an `asset` attribute that an approved-asset swap step can replace later.
local Rng = require("../ProcGen/Rng")
local Scene = require("./Scene")
local Vec = require("./Vec")

local Props = {}
type Scene = Scene.Scene
type V3 = Vec.V3
export type PropKind = { asset: string, size: V3, role: string?, shape: string? }

function Props.place(scene: Scene, kind: PropKind, pos: V3, yaw: number?)
	local spec = scene:add({
		role = kind.role or "prop",
		name = kind.asset,
		shape = kind.shape :: any,
		size = kind.size,
		pos = { x = pos.x, y = pos.y + kind.size.y / 2, z = pos.z },
		rot = { x = 0, y = yaw or 0, z = 0 },
		attributes = { asset = kind.asset },
	})
	table.insert(scene.meta.placements, { asset = kind.asset, pos = pos, yaw = yaw or 0, id = spec.id })
	return spec
end

function Props.snap(pos: V3, grid: number): V3
	return { x = Vec.snap(pos.x, grid), y = pos.y, z = Vec.snap(pos.z, grid) }
end

-- Bridson Poisson-disc sampling in an XZ rectangle: natural spacing without clumps.
function Props.poisson(
	rect: { x: number, z: number, w: number, d: number },
	radius: number,
	seed: number | string,
	options: { maxPoints: number?, exclude: ((x: number, z: number) -> boolean)? }?
): { { number } }
	local rng = Rng.new(seed)
	local cell = radius / math.sqrt(2)
	local cols, rows = math.max(1, math.ceil(rect.w / cell)), math.max(1, math.ceil(rect.d / cell))
	local grid: { [number]: { number } } = {}
	local points, active = {}, {}
	local maxPoints = options and options.maxPoints or 10000
	local exclude = options and options.exclude
	local function key(px: number, pz: number): number
		return math.floor((pz - rect.z) / cell) * cols + math.floor((px - rect.x) / cell)
	end
	local function ok(px: number, pz: number): boolean
		if px < rect.x or pz < rect.z or px >= rect.x + rect.w or pz >= rect.z + rect.d then
			return false
		end
		if exclude and exclude(px, pz) then
			return false
		end
		local cx, cz = math.floor((px - rect.x) / cell), math.floor((pz - rect.z) / cell)
		for dz = -2, 2 do
			for dx = -2, 2 do
				local nx, nz = cx + dx, cz + dz
				if nx >= 0 and nz >= 0 and nx < cols and nz < rows then
					local other = grid[nz * cols + nx]
					if other and (other[1] - px) ^ 2 + (other[2] - pz) ^ 2 < radius * radius then
						return false
					end
				end
			end
		end
		return true
	end
	local function add(px: number, pz: number)
		local p = { px, pz }
		table.insert(points, p)
		table.insert(active, p)
		grid[key(px, pz)] = p
	end
	-- Seed from the first valid of a few random tries.
	for _ = 1, 30 do
		local px, pz = rng:range(rect.x, rect.x + rect.w), rng:range(rect.z, rect.z + rect.d)
		if ok(px, pz) then
			add(px, pz)
			break
		end
	end
	while #active > 0 and #points < maxPoints do
		local index = rng:int(1, #active)
		local base = active[index]
		local found = false
		for _ = 1, 30 do
			local angle = rng:range(0, 2 * math.pi)
			local dist = rng:range(radius, 2 * radius)
			local px, pz = base[1] + math.cos(angle) * dist, base[2] + math.sin(angle) * dist
			if ok(px, pz) then
				add(px, pz)
				found = true
				break
			end
		end
		if not found then
			table.remove(active, index)
		end
	end
	return points
end

function Props.scatter(
	scene: Scene,
	kinds: { PropKind },
	options: {
		rect: { x: number, z: number, w: number, d: number },
		y: number?,
		radius: number,
		seed: (number | string)?,
		exclude: ((x: number, z: number) -> boolean)?,
		maxPoints: number?,
	}
)
	local seed = options.seed or scene.seed
	local rng = Rng.new(seed):fork("scatter-kinds")
	local placed = {}
	for _, p in
		Props.poisson(
			options.rect,
			options.radius,
			seed,
			{ exclude = options.exclude, maxPoints = options.maxPoints }
		)
	do
		table.insert(
			placed,
			Props.place(scene, rng:pick(kinds), { x = p[1], y = options.y or 0, z = p[2] }, rng:range(0, 360))
		)
	end
	return placed
end

-- Evenly distribute props on a line (inclusive ends), facing along the line.
function Props.distribute(scene: Scene, kind: PropKind, from: V3, to: V3, count: number)
	local dir = Vec.sub(to, from)
	local yaw = math.deg(math.atan2(-dir.z, dir.x))
	local placed = {}
	for index = 0, count - 1 do
		local t = if count == 1 then 0.5 else index / (count - 1)
		table.insert(placed, Props.place(scene, kind, Vec.lerp(from, to, t), yaw))
	end
	return placed
end

-- Place against a wall: `wallPoint` on the wall face, `normal` pointing into the room.
function Props.alignToWall(scene: Scene, kind: PropKind, wallPoint: V3, normal: V3, gap: number?)
	local n = Vec.unit({ x = normal.x, y = 0, z = normal.z })
	local offset = kind.size.z / 2 + (gap or 0.1)
	local yaw = math.deg(math.atan2(n.x, n.z)) + 180
	return Props.place(scene, kind, Vec.add(wallPoint, Vec.scale(n, offset)), yaw)
end

export type RoomRecord = {
	id: string,
	rect: { x: number, z: number, w: number, d: number },
	floorY: number,
	clearHeight: number,
}

-- Light fixture: a small non-colliding part carrying a `light` spec (Apply adds the
-- PointLight/SpotLight/SurfaceLight). mount "ceiling": `pos` is a point on the ceiling's underside
-- and the fixture hangs below it, lighting downward. mount "wall": `pos` is a point on the wall
-- face, `normal` points into the room and the fixture's front faces along it. With `room` (a
-- scene.meta.rooms record) the room's box is recorded in scene.meta.lights so Validate can check
-- the fixture stays inside it, also after Scene.transformed.
function Props.light(
	scene: Scene,
	options: {
		pos: V3,
		mount: ("ceiling" | "wall")?,
		normal: V3?,
		class: ("PointLight" | "SpotLight" | "SurfaceLight")?,
		room: RoomRecord?,
		size: V3?,
		brightness: number?,
		range: number?,
		color: { number }?,
		angle: number?,
		shadows: boolean?,
		asset: string?,
	}
)
	local mount = options.mount or "ceiling"
	local class = options.class or (if mount == "wall" then "SpotLight" else "PointLight")
	local size, pos, yaw, face
	if mount == "ceiling" then
		size = options.size or { x = 1.6, y = 0.3, z = 1.6 }
		pos = { x = options.pos.x, y = options.pos.y - size.y / 2, z = options.pos.z }
		yaw, face = 0, "Bottom"
	else
		assert(mount == "wall", "Props.light: mount must be ceiling or wall")
		assert(options.normal, "Props.light: a wall mount needs the wall normal")
		local n = Vec.unit({ x = options.normal.x, y = 0, z = options.normal.z })
		size = options.size or { x = 1.2, y = 0.8, z = 0.4 }
		pos = Vec.add(options.pos, Vec.scale(n, size.z / 2))
		-- Same yaw as alignToWall: the part's front face (-Z) turns to face `normal`.
		yaw, face = math.deg(math.atan2(n.x, n.z)) + 180, "Front"
	end
	local spec = scene:add({
		role = "fixture",
		name = options.asset or "LightFixture",
		size = size,
		pos = pos,
		rot = { x = 0, y = yaw, z = 0 },
		material = "Neon",
		color = options.color or { 255, 244, 229 },
		canCollide = false,
		attributes = { asset = options.asset or "placeholder/light-fixture" },
		light = {
			class = class,
			brightness = options.brightness or 1,
			range = options.range or 16,
			color = options.color or { 255, 244, 229 },
			face = if class == "PointLight" then nil else face,
			angle = if class == "PointLight" then nil else (options.angle or 90),
			shadows = options.shadows,
		},
	})
	local room = options.room
	if room then
		local meta = scene.meta :: any
		meta.lights = meta.lights or {}
		table.insert(meta.lights, {
			id = spec.id,
			room = room.id,
			-- Room box as centre-on-floor + wall axis so Scene.transformed moves it with the fixture.
			pos = { x = room.rect.x + room.rect.w / 2, y = room.floorY, z = room.rect.z + room.rect.d / 2 },
			dir = { x = 1, y = 0, z = 0 },
			half = { room.rect.w / 2, room.rect.d / 2 },
			height = room.clearHeight,
		})
	end
	return spec
end

-- Sign: a thin plate on a wall face (`pos` on the face, `normal` pointing away from the wall)
-- whose front carries a SurfaceGui + TextLabel. Text is placeholder only (default "SIGN_A");
-- Validate's sign_text check rejects empty text.
function Props.sign(
	scene: Scene,
	options: {
		pos: V3,
		normal: V3,
		text: string?,
		width: number?,
		height: number?,
		depth: number?,
		canCollide: boolean?,
	}
)
	local n = Vec.unit({ x = options.normal.x, y = 0, z = options.normal.z })
	local depth = options.depth or 0.2
	return scene:add({
		role = "sign",
		name = "Sign",
		size = { x = options.width or 4, y = options.height or 1.5, z = depth },
		pos = Vec.add(options.pos, Vec.scale(n, depth / 2)),
		rot = { x = 0, y = math.deg(math.atan2(n.x, n.z)) + 180, z = 0 },
		material = "SmoothPlastic",
		color = { 235, 235, 230 },
		canCollide = options.canCollide == true,
		attributes = { asset = "placeholder/sign" },
		sign = { text = if options.text == nil then "SIGN_A" else options.text, face = "Front" },
	})
end

return Props
