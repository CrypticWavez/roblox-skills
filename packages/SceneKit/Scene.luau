--!strict
-- A Scene is a deterministic list of part specs plus authoring metadata (doors, rooms,
-- stairs, placements). Every operation in SceneKit writes into a Scene; Apply turns it
-- into Instances, and Manifest/compare make it diffable without screenshots.
local Style = require("./Style")
local Vec = require("./Vec")

local Scene = {}
Scene.__index = Scene

export type V3 = Vec.V3
export type PartSpec = {
	id: string?,
	shape: ("Block" | "Wedge" | "Cylinder" | "Ball" | "CornerWedge")?,
	name: string?,
	role: string, -- style role and validation category: wall, floor, roof, stair, trim, prop ...
	size: V3,
	pos: V3, -- centre
	rot: V3?, -- orientation degrees
	material: string?,
	color: { number }?,
	transparency: number?,
	canCollide: boolean?,
	group: string?,
	attributes: { [string]: any }?,
}

export type Scene = typeof(setmetatable(
	{} :: {
		name: string,
		seed: number | string,
		style: Style.Profile,
		specs: { PartSpec },
		meta: { doors: { any }, rooms: { any }, stairs: { any }, placements: { any }, notes: { string } },
		provenance: { [string]: any },
		groupStack: { string },
		counters: { [string]: number },
	},
	Scene
))

function Scene.new(options: {
	name: string,
	seed: (number | string)?,
	style: string?,
	provenance: { [string]: any }?,
}): Scene
	return setmetatable({
		name = options.name,
		seed = options.seed or 0,
		style = Style.get(options.style),
		specs = {},
		meta = { doors = {}, rooms = {}, stairs = {}, placements = {}, notes = {} },
		provenance = options.provenance or { source = "SceneKit", generated = true },
		groupStack = {},
		counters = {},
	}, Scene)
end

function Scene.group<T>(self: Scene, name: string, body: () -> T): T
	table.insert(self.groupStack, name)
	local ok, result = pcall(body)
	table.remove(self.groupStack)
	if not ok then
		error(result, 0)
	end
	return result
end

function Scene.currentGroup(self: Scene): string
	return table.concat(self.groupStack, "/")
end

function Scene.add(self: Scene, spec: PartSpec): PartSpec
	assert(
		spec.size.x > 0 and spec.size.y > 0 and spec.size.z > 0,
		"non-positive part size for " .. spec.role
	)
	local group = spec.group or self:currentGroup()
	local base = (if group == "" then "" else group .. "/") .. (spec.name or spec.role)
	self.counters[base] = (self.counters[base] or 0) + 1
	spec.id = base .. "#" .. self.counters[base]
	spec.group = group
	spec.shape = spec.shape or "Block"
	spec.material = spec.material or self.style.materials[spec.role] or "SmoothPlastic"
	spec.color = spec.color or self.style.colors[spec.role] or { 200, 200, 200 }
	table.insert(self.specs, spec)
	return spec
end

-- Convenience: axis-aligned box from min/max corners.
function Scene.box(self: Scene, role: string, min: V3, max: V3, extra: { [string]: any }?): PartSpec
	local spec: any = {
		role = role,
		size = Vec.sub(max, min),
		pos = Vec.scale(Vec.add(min, max), 0.5),
	}
	for key, value in extra or {} do
		spec[key] = value
	end
	return self:add(spec)
end

-- Rotated-corner world AABB of one spec.
function Scene.specBounds(spec: PartSpec): (V3, V3)
	local hx, hy, hz = spec.size.x / 2, spec.size.y / 2, spec.size.z / 2
	local min = { x = math.huge, y = math.huge, z = math.huge }
	local max = { x = -math.huge, y = -math.huge, z = -math.huge }
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local corner =
					Vec.add(spec.pos, Vec.rotate({ x = sx * hx, y = sy * hy, z = sz * hz }, spec.rot))
				min = {
					x = math.min(min.x, corner.x),
					y = math.min(min.y, corner.y),
					z = math.min(min.z, corner.z),
				}
				max = {
					x = math.max(max.x, corner.x),
					y = math.max(max.y, corner.y),
					z = math.max(max.z, corner.z),
				}
			end
		end
	end
	return min, max
end

function Scene.bounds(self: Scene, filter: ((PartSpec) -> boolean)?): (V3, V3)
	local min = { x = math.huge, y = math.huge, z = math.huge }
	local max = { x = -math.huge, y = -math.huge, z = -math.huge }
	for _, spec in self.specs do
		if filter == nil or filter(spec) then
			local a, b = Scene.specBounds(spec)
			min = { x = math.min(min.x, a.x), y = math.min(min.y, a.y), z = math.min(min.z, a.z) }
			max = { x = math.max(max.x, b.x), y = math.max(max.y, b.y), z = math.max(max.z, b.z) }
		end
	end
	return min, max
end

-- Translate + yaw (about origin) every spec added by `body`; used to place locally-built pieces.
function Scene.transformed<T>(self: Scene, offset: V3, yaw: number, body: () -> T): T
	local first = #self.specs + 1
	local firstMeta = {}
	for key, list in self.meta :: any do
		firstMeta[key] = #list + 1
	end
	local result = body()
	local function move(p: V3): V3
		return Vec.add(Vec.rotateY(p, yaw), offset)
	end
	for index = first, #self.specs do
		local spec = self.specs[index]
		spec.pos = move(spec.pos)
		local rot = spec.rot or Vec.new()
		spec.rot = { x = rot.x, y = (rot.y + yaw) % 360, z = rot.z }
	end
	for key, list in self.meta :: any do
		for index = firstMeta[key], #list do
			local record = list[index]
			if type(record) == "table" and record.pos then
				record.pos = move(record.pos)
			end
		end
	end
	return result
end

function Scene.counts(self: Scene): { [string]: number }
	local counts = {}
	for _, spec in self.specs do
		counts[spec.role] = (counts[spec.role] or 0) + 1
	end
	return counts
end

-- Compact, rounded, sortable representation for manifests and diffs.
function Scene.manifest(self: Scene)
	local parts = {}
	for _, spec in self.specs do
		local rot = spec.rot or Vec.new()
		table.insert(parts, {
			id = spec.id,
			shape = spec.shape,
			role = spec.role,
			size = {
				math.round(spec.size.x * 1000) / 1000,
				math.round(spec.size.y * 1000) / 1000,
				math.round(spec.size.z * 1000) / 1000,
			},
			pos = {
				math.round(spec.pos.x * 1000) / 1000,
				math.round(spec.pos.y * 1000) / 1000,
				math.round(spec.pos.z * 1000) / 1000,
			},
			rot = {
				math.round(rot.x * 1000) / 1000,
				math.round(rot.y * 1000) / 1000,
				math.round(rot.z * 1000) / 1000,
			},
			material = spec.material,
			color = spec.color,
			transparency = spec.transparency,
		})
	end
	local min, max = self:bounds()
	return {
		version = 1,
		name = self.name,
		seed = self.seed,
		style = self.style.id,
		provenance = self.provenance,
		counts = self:counts(),
		partCount = #self.specs,
		bounds = if #self.specs > 0 then { min = Vec.round(min), max = Vec.round(max) } else nil,
		meta = self.meta,
		parts = parts,
	}
end

-- Diff two manifests by part id: added, removed, changed (any of size/pos/rot/material/color).
function Scene.compare(a, b)
	local index = {}
	for _, part in a.parts do
		index[part.id] = part
	end
	local added, removed, changed = {}, {}, {}
	local seen = {}
	local function same(p, q)
		for _, key in { "size", "pos", "rot", "color" } do
			for i = 1, 3 do
				if math.abs((p[key][i] or 0) - (q[key][i] or 0)) > 1e-3 then
					return false
				end
			end
		end
		return p.material == q.material
			and p.shape == q.shape
			and (p.transparency or 0) == (q.transparency or 0)
	end
	for _, part in b.parts do
		local old = index[part.id]
		seen[part.id] = true
		if old == nil then
			table.insert(added, part.id)
		elseif not same(old, part) then
			table.insert(changed, part.id)
		end
	end
	for _, part in a.parts do
		if not seen[part.id] then
			table.insert(removed, part.id)
		end
	end
	return {
		identical = #added + #removed + #changed == 0,
		added = added,
		removed = removed,
		changed = changed,
	}
end

return Scene
