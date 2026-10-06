--!strict
-- kit/1 manifests (docs/runtime-kits.md section 9.5): validate, define, and resolve placeholders
-- to pieces. A placeholder is any SceneKit part (or Instance) whose `asset` attribute names a
-- piece key; resolving it gives the piece and the pivot transform that puts the piece's bounds
-- where the placeholder box is (centred in X and Z, bottoms level, in the placeholder's own
-- frame), so Apply.swap keeps every placeholder CFrame. Pure: no Instances, no files. G6
-- `factory.py kit` writes the manifests; decode the JSON before passing it here.
local Kit = {}

Kit.SCHEMA = "kit/1"
Kit.PIVOTS = table.freeze({ "base_center", "center", "origin" })
Kit.COLLISIONS = table.freeze({ "box", "hull", "default", "none" })
Kit.FITS = table.freeze({ "none", "uniform", "stretch" })
-- Size mismatch between a placeholder and a piece that resolve reports (share of the larger
-- side, convention).
Kit.SIZE_TOLERANCE = 0.1

export type V3 = { x: number, y: number, z: number }
export type Piece = { [string]: any }
export type Kit = { schema: string, id: string, pieces: { Piece }, byKey: { [string]: Piece }? }
export type Placeholder = { asset: string, size: V3, id: string? }
export type Match = {
	placeholder: Placeholder,
	key: string,
	piece: Piece?,
	procedural: boolean,
	scale: V3, -- per-axis scale of the piece (uniform fits give three equal numbers)
	offset: V3, -- piece pivot in the placeholder's local frame (studs, centre origin)
	problems: { string },
}

local function isLabel(value: any): boolean
	return type(value) == "string" and #value <= 64 and string.match(value, "^[%a][%w_]*$") ~= nil
end

local function isVector(value: any): boolean
	if type(value) ~= "table" or #value ~= 3 then
		return false
	end
	for i = 1, 3 do
		local n = value[i]
		if type(n) ~= "number" or n ~= n or n == math.huge or n == -math.huge then
			return false
		end
	end
	return true
end

local function sourceProblem(source: any): string?
	if source == "procedural" then
		return nil
	end
	if type(source) ~= "string" then
		return "source must be a string"
	end
	local template = string.match(source, "^blender_template:(.+)$")
	if template then
		return if isLabel(template) then nil else "blender_template source needs a template label"
	end
	local origin, id = string.match(source, "^cc0:([^:]+):(.+)$")
	if origin and id then
		return nil
	end
	return "source must be procedural, blender_template:<template> or cc0:<source>:<id> (got "
		.. source
		.. ")"
end

local function materialProblem(material: any): string?
	if material == "vertex_color" then
		return nil
	end
	if type(material) ~= "string" then
		return "material must be a string"
	end
	local prefix, rest = string.match(material, "^(%a+):(.+)$")
	if prefix == "library" and isLabel(rest) then
		return nil
	elseif prefix == "builtin" and string.match(rest :: string, "^%u%w*$") then
		return nil
	elseif prefix == "atlas" and rest ~= nil then
		return nil
	end
	return "material "
		.. material
		.. " must be library:<name>, builtin:<Enum.Material>, atlas:<file> or vertex_color"
end

-- Problems with a kit/1 table (empty when valid). Each names the piece key or index.
function Kit.validate(kit: any): { string }
	local problems: { string } = {}
	if type(kit) ~= "table" then
		return { "kit must be a table" }
	end
	if kit.schema ~= Kit.SCHEMA then
		table.insert(problems, "schema must be kit/1 (got " .. tostring(kit.schema) .. ")")
	end
	if not isLabel(kit.id) then
		table.insert(problems, "id must be a label")
	end
	if type(kit.pieces) ~= "table" or #kit.pieces == 0 then
		table.insert(problems, "pieces must be a non-empty list")
		return problems
	end
	local seen = {}
	for index, piece in kit.pieces do
		local name = if type(piece) == "table" and isLabel(piece.key)
			then "piece " .. piece.key
			else "piece " .. index
		local function add(problem: string)
			table.insert(problems, name .. ": " .. problem)
		end
		if type(piece) ~= "table" then
			add("must be a table")
			continue
		end
		if not isLabel(piece.key) then
			add("key must be a label")
		elseif seen[piece.key] then
			add("duplicate key")
		end
		seen[piece.key] = true
		local sourceIssue = sourceProblem(piece.source)
		if sourceIssue then
			add(sourceIssue)
		end
		if piece.source == "procedural" then
			if piece.file ~= nil then
				add("procedural pieces have no file")
			end
		elseif type(piece.file) ~= "string" or piece.file == "" then
			add("file must name the exported model")
		elseif string.find(piece.file, "..", 1, true) or string.match(piece.file, "^[/\\]") then
			add("file must be relative to the kit file, inside it")
		end
		local bounds = piece.bounds
		if type(bounds) ~= "table" or not isVector(bounds.min) or not isVector(bounds.max) then
			add("bounds must be { min = [x, y, z], max = [x, y, z] }")
		else
			for i = 1, 3 do
				if bounds.max[i] <= bounds.min[i] then
					add("bounds max must exceed min on every axis")
					break
				end
			end
		end
		if piece.pivot ~= nil and not table.find(Kit.PIVOTS, piece.pivot) then
			add("pivot must be base_center, center or origin")
		end
		if type(piece.materials) ~= "table" then
			add("materials must be a list")
		else
			for _, material in piece.materials do
				local issue = materialProblem(material)
				if issue then
					add(issue)
				end
			end
		end
		if type(piece.provenance) ~= "string" or piece.provenance == "" then
			add("provenance must be local-template or an asset-sources/1 key")
		elseif piece.source == "procedural" and piece.provenance ~= "local-template" then
			add("procedural pieces have provenance local-template")
		end
		if piece.sockets ~= nil then
			if type(piece.sockets) ~= "table" then
				add("sockets must be a list")
			else
				for s, socket in piece.sockets do
					if
						type(socket) ~= "table"
						or not isLabel(socket.name)
						or not isVector(socket.position)
						or type(socket.yaw) ~= "number"
					then
						add("socket " .. s .. " needs name (label), position [x, y, z] and yaw")
					end
				end
			end
		end
		if piece.collision ~= nil and not table.find(Kit.COLLISIONS, piece.collision) then
			add("collision must be box, hull, default or none")
		end
		if
			piece.triangles ~= nil
			and (type(piece.triangles) ~= "number" or piece.triangles < 0 or piece.triangles % 1 ~= 0)
		then
			add("triangles must be a whole number >= 0")
		end
	end
	return problems
end

-- Validated, frozen kit with a key index (raises with every problem joined).
function Kit.define(kit: any): Kit
	local problems = Kit.validate(kit)
	if #problems > 0 then
		error("Kit.define: " .. table.concat(problems, "; "), 2)
	end
	local byKey = {}
	for _, piece in kit.pieces do
		byKey[piece.key] = piece
	end
	local copy = table.clone(kit)
	copy.byKey = byKey
	return table.freeze(copy) :: any
end

function Kit.find(kit: Kit, key: string): Piece?
	if kit.byKey then
		return kit.byKey[key]
	end
	for _, piece in kit.pieces do
		if piece.key == key then
			return piece
		end
	end
	return nil
end

-- Size of a piece's bounds, studs.
function Kit.size(piece: Piece): V3
	local b = piece.bounds
	return { x = b.max[1] - b.min[1], y = b.max[2] - b.min[2], z = b.max[3] - b.min[3] }
end

-- How one placeholder takes one piece. options.fit: "none" (default, keep the piece's size),
-- "uniform" (largest uniform scale that fits the placeholder box) or "stretch" (per axis).
function Kit.fit(piece: Piece, placeholder: Placeholder, fit: string?): (V3, V3, { string })
	local problems = {}
	local mode = fit or "none"
	local size = Kit.size(piece)
	local target = placeholder.size
	local sx, sy, sz = 1, 1, 1
	if mode == "uniform" then
		local s = math.min(target.x / size.x, target.y / size.y, target.z / size.z)
		sx, sy, sz = s, s, s
	elseif mode == "stretch" then
		sx, sy, sz = target.x / size.x, target.y / size.y, target.z / size.z
	elseif mode ~= "none" then
		error("Kit.fit: fit must be none, uniform or stretch (got " .. tostring(mode) .. ")", 2)
	end
	if mode == "none" then
		for _, axis in { "x", "y", "z" } do
			local a, b = (size :: any)[axis], (target :: any)[axis]
			if math.abs(a - b) > Kit.SIZE_TOLERANCE * math.max(a, b) then
				table.insert(
					problems,
					string.format("%s size %.2f differs from the placeholder's %.2f", axis, a, b)
				)
			end
		end
	end
	-- Bounds centre over the placeholder centre in X and Z, bounds bottom on the placeholder's.
	local b = piece.bounds
	local offset = {
		x = -sx * (b.min[1] + b.max[1]) / 2,
		y = -target.y / 2 - sy * b.min[2],
		z = -sz * (b.min[3] + b.max[3]) / 2,
	}
	return { x = sx, y = sy, z = sz }, offset, problems
end

-- Matches placeholders ({ asset, size, id? }) to pieces. Returns matches (one per placeholder
-- whose asset is a piece key; procedural pieces match but are flagged, since SceneKit already
-- built them), the placeholders with no piece, and the piece keys nothing used.
function Kit.resolve(
	kit: Kit,
	placeholders: { Placeholder },
	options: { fit: string? }?
): ({ Match }, { Placeholder }, { string })
	local matches: { Match } = {}
	local missing: { Placeholder } = {}
	local used = {}
	for _, placeholder in placeholders do
		local piece = if type(placeholder.asset) == "string" then Kit.find(kit, placeholder.asset) else nil
		if piece == nil then
			table.insert(missing, placeholder)
			continue
		end
		used[piece.key] = true
		local scale, offset, problems = Kit.fit(piece, placeholder, options and options.fit)
		table.insert(matches, {
			placeholder = placeholder,
			key = piece.key,
			piece = piece,
			procedural = piece.source == "procedural",
			scale = scale,
			offset = offset,
			problems = problems,
		})
	end
	local unused = {}
	for _, piece in kit.pieces do
		if not used[piece.key] then
			table.insert(unused, piece.key)
		end
	end
	return matches, missing, unused
end

-- Placeholders of a SceneKit scene: every spec with an `asset` attribute.
function Kit.placeholders(scene: any): { Placeholder }
	local out = {}
	for _, spec in scene.specs do
		local asset = spec.attributes and spec.attributes.asset
		if type(asset) == "string" then
			table.insert(out, { asset = asset, size = spec.size, id = spec.id })
		end
	end
	return out
end

return Kit
