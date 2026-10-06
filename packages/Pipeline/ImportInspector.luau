--!strict
-- @tier T3
-- probe: import_appearance
-- (also probe import_clips; the pure checks run in Lune: tests/import_inspector.spec.luau)
-- Studio half of the Blender -> Roblox round trip. Compares an imported MeshPart/Model with
-- the `roblox_expectation_vN.json` written by tools/blender/factory.py roundtrip.
-- Run in Studio (command bar, Studio MCP execute_luau, or a plugin):
--   local Inspector = require(path.to.Pipeline.ImportInspector)
--   local report = Inspector.inspect(workspace.SM_RoundTripMarker, expectation)
-- Checks: mesh present, size (with unit/axis diagnoses), unrotated, pivot at the base centre, facing
-- (surface centroid vs Blender), side (X handedness), triangle count, collision fidelity, and the
-- appearance: with an `appearance` block (factory bakes, bkit/bake.py) the route it names must have
-- arrived (colour map and PBR maps as TextureID/SurfaceAppearance, vertex colours on a white part, or a
-- library MaterialVariant); without one, a multi-material asset needs any colour binding.
-- A check the expectation or the import cannot support is reported with `checked = false` and fails
-- (listed in `notChecked`): nothing passes unmeasured.
-- `inspectClips` compares imported animations with a clips/1 sidecar (docs/runtime-kits.md 9.4):
-- names, lengths and markers, and returns the play plan (looping, priority, marker times) that the
-- sidecar carries because the files do not.
-- Pure functions over instance-like tables, so the logic is unit-tested in Lune with mocks. Mesh reads
-- use EditableMesh in Studio; tests inject `options.triangles` and `options.colours`.
local ImportInspector = {}

-- How the factory baked the look (bkit/bake.py `rbx_appearance`): kind "palette_atlas" or "baked"
-- (maps by role: color, roughness, metalness, normal, emissive), "vertex_colors" (palette = distinct
-- colours; the MeshPart Color must be white) or "library" (materials = { "library:<name>" }).
export type Appearance = {
	kind: string,
	maps: { [string]: string }?,
	palette: number?,
	vertex_colors: string?,
	material: string?,
	materials: { string }?,
	part_color: { number }?,
}

export type Expectation = {
	asset: string,
	revision: number,
	size: { number }, -- studs, Roblox axes (x, y up, z back)
	front: string?, -- "-Z"
	-- Area-weighted surface centroid minus bounds centre, measured in Blender along the declared front
	-- and up axes (studs). Intrinsic to the shape, so the check assumes no exporter axis mapping.
	front_offset: number?,
	up_offset: number?,
	-- The same along Roblox +X (bkit/expectation.py derives Roblox x = -Blender x; the side fin on the
	-- round-trip marker measures it). Under 0.1 studs the asset is symmetric and a mirror is invisible.
	side_offset: number?,
	pivot: string?, -- "base-centre"
	materials: { string }?, -- exported material names; more than one needs a colour binding
	appearance: Appearance?,
	triangles: number?, -- Blender's triangle count (sum of polygon corners - 2)
	tolerance: number?, -- size: relative (0.05 = 5%); pivot: studs. Default 0.05
}

-- `checked = false`: the check could not be measured (missing expectation field or unreadable mesh).
export type Check = {
	name: string,
	pass: boolean,
	value: any,
	expected: any?,
	detail: string?,
	checked: boolean?,
}
export type Report = { pass: boolean, checks: { Check }, notChecked: { string } }

-- Returns a part's triangles as three {x, y, z} world-space points each, or nil and a reason.
export type TriangleReader = (part: any) -> ({ { { number } } }?, string?)
-- Returns the number of distinct vertex colours in a part's mesh (0 when it has none), or nil and a reason.
export type ColourReader = (part: any) -> (number?, string?)
export type Options = { triangles: TriangleReader?, colours: ColourReader? }

-- Size comparison only: `b` is an expected size, so the tolerance is relative to the asset's size.
-- Never use this for world positions (a tolerance scaled by a coordinate grows with distance).
local function sameSize(a: number, b: number, tol: number): boolean
	return math.abs(a - b) <= math.max(tol, math.abs(b) * tol)
end

local function vec(v: any): { number }
	return { v.X, v.Y, v.Z }
end

-- Collect MeshParts under a root (the root itself may be a MeshPart).
function ImportInspector.meshParts(root: any): { any }
	local found = {}
	if root:IsA("MeshPart") then
		table.insert(found, root)
	end
	for _, d in root:GetDescendants() do
		if d:IsA("MeshPart") then
			table.insert(found, d)
		end
	end
	return found
end

-- World AABB of axis-aligned parts (imports arrive unrotated; rotated parts are flagged).
local function aabb(parts: { any }): ({ number }, { number }, boolean)
	local mn = { math.huge, math.huge, math.huge }
	local mx = { -math.huge, -math.huge, -math.huge }
	local rotated = false
	for _, part in parts do
		local cf, size = part.CFrame, part.Size
		local rx, ry, rz = cf:ToOrientation()
		if math.abs(rx) + math.abs(ry) + math.abs(rz) > 1e-3 then
			rotated = true
		end
		local p, s = vec(cf.Position), vec(size)
		for i = 1, 3 do
			mn[i] = math.min(mn[i], p[i] - s[i] / 2)
			mx[i] = math.max(mx[i], p[i] + s[i] / 2)
		end
	end
	return mn, mx, rotated
end

-- Opens the MeshPart's mesh as an EditableMesh. Needs edit access (true for your own fresh import).
local function openMesh(part: any): any
	local AssetService = (game :: any):GetService("AssetService")
	local opened, mesh = pcall(AssetService.CreateEditableMeshAsync, AssetService, part.MeshContent)
	if not opened or mesh == nil then
		mesh = AssetService:CreateEditableMeshAsync((Content :: any).fromUri(part.MeshId))
	end
	return mesh
end

-- Studio reader: the MeshPart's mesh via EditableMesh, scaled from mesh space to the part's Size
-- and placed by its CFrame.
function ImportInspector.studioTriangles(part: any): ({ { { number } } }?, string?)
	local ok, result = pcall(function()
		local mesh = openMesh(part)
		local lo = Vector3.new(math.huge, math.huge, math.huge)
		local hi = -lo
		for _, v in mesh:GetVertices() do
			local p = mesh:GetPosition(v)
			lo, hi = lo:Min(p), hi:Max(p)
		end
		local span = hi - lo
		local scale = part.Size
			/ Vector3.new(math.max(span.X, 1e-6), math.max(span.Y, 1e-6), math.max(span.Z, 1e-6))
		local mid = (lo + hi) / 2
		local tris = {}
		for _, face in mesh:GetFaces() do
			local tri = {}
			for i, v in mesh:GetFaceVertices(face) do
				local w = part.CFrame:PointToWorldSpace((mesh:GetPosition(v) - mid) * scale)
				tri[i] = { w.X, w.Y, w.Z }
			end
			table.insert(tris, tri)
		end
		mesh:Destroy()
		return tris
	end)
	if not ok then
		return nil, "EditableMesh read failed: " .. tostring(result)
	end
	return result
end

-- Studio reader: distinct vertex colours in the MeshPart's mesh via EditableMesh.
function ImportInspector.studioColours(part: any): (number?, string?)
	local ok, result = pcall(function()
		local mesh = openMesh(part)
		local seen, count = {}, 0
		for _, id in mesh:GetColors() do
			local c = mesh:GetColor(id)
			local key = if c then string.format("%.3f,%.3f,%.3f", c.R, c.G, c.B) else nil
			if key and not seen[key] then
				seen[key] = true
				count += 1
			end
		end
		mesh:Destroy()
		return count
	end)
	if not ok then
		return nil, "EditableMesh colour read failed: " .. tostring(result)
	end
	return result
end

-- Every part's triangles, read once and shared by the triangle count and facing checks.
local function readTriangles(parts: { any }, read: TriangleReader): ({ { { number } } }?, string?)
	local all = {}
	for _, part in parts do
		local tris, err = read(part)
		if tris == nil then
			return nil, err
		end
		for _, t in tris do
			table.insert(all, t)
		end
	end
	return all
end

-- Area-weighted centroid of the surfaces (robust to how the importer splits triangles).
local function surfaceCentroid(tris: { { { number } } }): ({ number }?, string?)
	local sum, total = { 0, 0, 0 }, 0
	for _, t in tris do
		local a, b, c = t[1], t[2], t[3]
		local u = { b[1] - a[1], b[2] - a[2], b[3] - a[3] }
		local v = { c[1] - a[1], c[2] - a[2], c[3] - a[3] }
		local cx, cy, cz = u[2] * v[3] - u[3] * v[2], u[3] * v[1] - u[1] * v[3], u[1] * v[2] - u[2] * v[1]
		local area = math.sqrt(cx * cx + cy * cy + cz * cz) / 2
		total += area
		for i = 1, 3 do
			sum[i] += area * (a[i] + b[i] + c[i]) / 3
		end
	end
	if total <= 0 then
		return nil, "mesh has no surface area"
	end
	return { sum[1] / total, sum[2] / total, sum[3] / total }
end

local function sameOffset(observed: number, expected: number): boolean
	return math.abs(observed - expected) <= math.max(0.1, math.abs(expected) * 0.2)
end

local function notChecked(name: string, value: any, expected: any, why: string): Check
	return {
		name = name,
		pass = false,
		checked = false,
		value = value,
		expected = expected,
		detail = "not checked: " .. why,
	}
end

-- Reads a property that may not exist on this instance class or engine version (nil then).
local function read(object: any, key: string): any
	local ok, value = pcall(function()
		return object[key]
	end)
	return if ok then value else nil
end

-- True when `legacy` (a string id) or `modern` (a Content with a Uri or an Object) is set.
local function hasContent(object: any, legacy: string?, modern: string?): boolean
	if legacy then
		local value = read(object, legacy)
		if type(value) == "string" and value ~= "" then
			return true
		end
	end
	if modern then
		local content = read(object, modern)
		if type(content) == "string" then
			return content ~= ""
		elseif content ~= nil then
			local uri = read(content, "Uri")
			return (type(uri) == "string" and uri ~= "") or read(content, "Object") ~= nil
		end
	end
	return false
end

-- SurfaceAppearance properties per map role: { legacy string id, Content property }.
local MAP_PROPERTIES: { [string]: { string? } } = {
	color = { "ColorMap", "ColorMapContent" },
	normal = { "NormalMap", "NormalMapContent" },
	roughness = { "RoughnessMap", "RoughnessMapContent" },
	metalness = { "MetalnessMap", "MetalnessMapContent" },
	emissive = { nil, "EmissiveMaskContent" },
}

-- The maps a MeshPart carries: color from its TextureID/TextureContent or a SurfaceAppearance, the
-- other roles from the SurfaceAppearance. Second result: whether it has a SurfaceAppearance.
function ImportInspector.partMaps(part: any): ({ [string]: boolean }, boolean)
	local maps = { color = hasContent(part, "TextureID", "TextureContent") }
	local surface = part:FindFirstChildOfClass("SurfaceAppearance")
	if surface ~= nil then
		for role, props in MAP_PROPERTIES do
			if hasContent(surface, props[1], props[2]) then
				maps[role] = true
			end
		end
	end
	return maps, surface ~= nil
end

local ROLE_ORDER = { "color", "normal", "roughness", "metalness", "emissive" }

-- Appearance checks for an expectation with an `appearance` block (see the Appearance type).
local function appearanceChecks(parts: { any }, look: Appearance, readColours: ColourReader): { Check }
	local out: { Check } = {}
	local kind = look.kind
	if kind == "palette_atlas" or kind == "baked" then
		local wanted = look.maps or {}
		for _, role in ROLE_ORDER do
			if role ~= "color" and wanted[role] == nil then
				continue
			end
			local missing, textureOnly = 0, 0
			for _, part in parts do
				local maps, surfaced = ImportInspector.partMaps(part)
				if not maps[role] then
					missing += 1
					if maps.color and not surfaced then
						textureOnly += 1
					end
				end
			end
			local ok = missing == 0
			local detail: string? = nil
			if not ok and role == "color" then
				detail =
					`no colour map on {missing} of {#parts} parts: the import dropped {wanted.color or "the colour map"} (B06); keep the maps next to the model or add a SurfaceAppearance`
			elseif not ok then
				detail = `{role} map missing on {missing} of {#parts} parts`
					.. (
						if textureOnly > 0
							then ": Import 3D kept only the colour map as TextureID (B02); add a SurfaceAppearance with the factory's maps"
							else ""
					)
			end
			table.insert(out, {
				name = if role == "color" then "appearance" else "appearance_" .. role,
				pass = ok,
				value = #parts - missing,
				expected = { parts = #parts, map = wanted[role] or role },
				detail = detail,
			})
		end
	elseif kind == "vertex_colors" then
		local coloured, unread, notWhite = 0, nil, 0
		for _, part in parts do
			local colours, err = readColours(part)
			if colours == nil then
				unread = err
			elseif colours > 0 then
				coloured += 1
			end
			local colour = read(part, "Color")
			if colour == nil or colour.R < 0.99 or colour.G < 0.99 or colour.B < 0.99 then
				notWhite += 1
			end
		end
		if unread ~= nil and coloured < #parts then
			table.insert(
				out,
				notChecked("appearance", coloured, #parts, `vertex colours unreadable: {unread}`)
			)
		else
			table.insert(out, {
				name = "appearance",
				pass = coloured == #parts,
				value = coloured,
				expected = #parts,
				detail = if coloured == #parts
					then nil
					else `{#parts - coloured} of {#parts} parts have no vertex colours: the import dropped them`,
			})
		end
		table.insert(out, {
			name = "appearance_part_color",
			pass = notWhite == 0,
			value = notWhite,
			expected = 0,
			detail = if notWhite == 0
				then nil
				else `{notWhite} parts are not white: Studio multiplies vertex colours by the part Color`,
		})
	elseif kind == "library" then
		local names = {}
		for _, m in look.materials or {} do
			table.insert(names, (string.gsub(m, "^library:", "")))
		end
		local applied = 0
		for _, part in parts do
			local variant = read(part, "MaterialVariant")
			if type(variant) == "string" and table.find(names, variant) then
				applied += 1
			end
		end
		table.insert(out, {
			name = "appearance",
			pass = applied == #parts,
			value = applied,
			expected = names,
			detail = if applied == #parts
				then nil
				else "MaterialVariant not applied: SceneKit/Materials sets it from material-library/1 after import",
		})
	else
		table.insert(out, notChecked("appearance", nil, kind, `unknown appearance kind {tostring(kind)}`))
	end
	return out
end

function ImportInspector.inspect(root: any, expected: Expectation, options: Options?): Report
	local tol = expected.tolerance or 0.05
	local checks: { Check } = {}
	local parts = ImportInspector.meshParts(root)
	table.insert(checks, { name = "mesh_present", pass = #parts > 0, value = #parts, expected = ">=1" })
	if #parts == 0 then
		return { pass = false, checks = checks, notChecked = {} }
	end
	local readTris = (options and options.triangles) or ImportInspector.studioTriangles
	local readColours = (options and options.colours) or ImportInspector.studioColours
	local meshRead, meshTris, meshErr = false, nil, nil
	local function triangles(): ({ { { number } } }?, string?)
		if not meshRead then
			meshRead = true
			meshTris, meshErr = readTriangles(parts, readTris)
		end
		return meshTris, meshErr
	end
	local function centroid(): ({ number }?, string?)
		local tris, err = triangles()
		if tris == nil then
			return nil, err
		end
		return surfaceCentroid(tris)
	end

	local mn, mx, rotated = aabb(parts)
	local mid = { (mn[1] + mx[1]) / 2, (mn[2] + mx[2]) / 2, (mn[3] + mx[3]) / 2 }
	local size = { mx[1] - mn[1], mx[2] - mn[2], mx[3] - mn[3] }
	local sizeOk = sameSize(size[1], expected.size[1], tol)
		and sameSize(size[2], expected.size[2], tol)
		and sameSize(size[3], expected.size[3], tol)
	local swapped = not sizeOk
		and sameSize(size[1], expected.size[1], tol)
		and sameSize(size[2], expected.size[3], tol)
		and sameSize(size[3], expected.size[2], tol)
	local ratio = size[2] / expected.size[2]
	table.insert(checks, {
		name = "scale",
		pass = sizeOk,
		value = size,
		expected = expected.size,
		detail = if sizeOk
			then nil
			elseif swapped then "Y/Z swapped: export axis_up/forward wrong"
			elseif
				math.abs(ratio - 3.571) < 0.2 or math.abs(ratio - 0.28) < 0.05
			then "metre/stud mismatch: set importer Scale Unit = Studs"
			elseif
				math.abs(ratio - 100) < 5 or math.abs(ratio - 0.01) < 0.001
			then "centimetre scale: FBX unit scale not applied"
			else "unexpected size",
	})
	table.insert(checks, {
		name = "orientation_unrotated",
		pass = not rotated,
		value = rotated,
		expected = false,
		detail = "imported parts should arrive with identity rotation",
	})

	-- Pivot: the model/part pivot should sit at the bottom centre of the bounds. Measured as an offset
	-- from the base centre in the model's frame (the axes of an unrotated import) against `tol` studs,
	-- so the allowed error is the same wherever the model is placed.
	local pivot = vec(if root.GetPivot then root:GetPivot().Position else parts[1].CFrame.Position)
	local centre = { (mn[1] + mx[1]) / 2, mn[2], (mn[3] + mx[3]) / 2 }
	local offset = { pivot[1] - centre[1], pivot[2] - centre[2], pivot[3] - centre[3] }
	local pivotOk = math.abs(offset[1]) <= tol and math.abs(offset[2]) <= tol and math.abs(offset[3]) <= tol
	if expected.pivot ~= "base-centre" then
		table.insert(
			checks,
			notChecked("pivot_base_centre", offset, expected.pivot, "expectation has no pivot = base-centre")
		)
	else
		table.insert(checks, {
			name = "pivot_base_centre",
			pass = pivotOk,
			value = offset, -- studs from the base centre (x, y, z)
			expected = { 0, 0, 0 },
			detail = if pivotOk
				then nil
				else string.format(
					"pivot is (%.3f, %.3f, %.3f) studs from the base centre: set PivotOffset or fix origin in Blender",
					offset[1],
					offset[2],
					offset[3]
				),
		})
	end

	-- Front: a part named *Front* (split imports) must lie on the -Z side of the centre. A single mesh
	-- is checked by where its surface centroid sits relative to the bounds centre, compared with
	-- the same measurement taken in Blender. Anything undetermined fails: never assume facing.
	if expected.front == nil then
		table.insert(checks, notChecked("orientation_front", nil, nil, "expectation has no front"))
	else
		local frontZ = nil
		for _, part in parts do
			if string.find(part.Name, "Front") or (part:GetAttribute("Material") == "MAT_Front") then
				frontZ = part.CFrame.Position.Z
			end
		end
		local check: Check
		if frontZ ~= nil then
			check = {
				name = "orientation_front",
				pass = frontZ < mid[3],
				value = frontZ,
				expected = "< centre z (front -Z)",
				detail = if frontZ < mid[3] then nil else "front part is on +Z: asset faces backwards",
			}
		elseif expected.front_offset == nil or math.abs(expected.front_offset) < 0.1 then
			check = {
				name = "orientation_front",
				pass = false,
				value = nil,
				expected = expected.front_offset,
				detail = "front undetermined: expectation has no usable front_offset (regenerate with factory.py roundtrip) - confirm facing with screen_capture",
			}
		else
			local c, err = centroid()
			if c == nil then
				check = {
					name = "orientation_front",
					pass = false,
					value = nil,
					expected = expected.front_offset,
					detail = `front undetermined: {err} - confirm facing with screen_capture`,
				}
			else
				local front, up = mid[3] - c[3], c[2] - mid[2] -- front is -Z, up is +Y
				local frontOk = sameOffset(front, expected.front_offset)
				local upOk = expected.up_offset == nil or sameOffset(up, expected.up_offset)
				-- Below 0.1 studs a flipped up axis lands inside sameOffset's tolerance, so say so.
				local upWeak = expected.up_offset == nil or math.abs(expected.up_offset) < 0.1
				local upFlipped = not upOk
					and expected.up_offset ~= nil
					and sameOffset(-up, expected.up_offset)
				local frontFlipped = not frontOk and sameOffset(-front, expected.front_offset)
				check = {
					name = "orientation_front",
					pass = frontOk and upOk,
					value = { front = front, up = up },
					expected = { front = expected.front_offset, up = expected.up_offset },
					detail = if frontOk and upOk
						then (if upWeak
							then "up not verified by the centroid (up_offset missing or under 0.1 studs): pivot_base_centre and screen_capture cover it"
							else nil)
						elseif
							frontFlipped and upFlipped
						then "asset is upside down and faces +Z (turned 180 degrees about X): fix the FBX up axis"
						elseif
							frontFlipped
						then "asset faces +Z (turned 180 degrees): fix the FBX forward axis or rotate before export"
						elseif upFlipped then "asset is upside down: fix the FBX up axis"
						else "surface centroid differs from Blender: wrong axis mapping or changed geometry",
				}
			end
		end
		table.insert(checks, check)
	end

	-- Side (X handedness): the surface centroid along Roblox +X against Blender's measurement mapped by
	-- bkit/expectation.py. Only when the expectation has side_offset (older ones do not).
	if expected.side_offset ~= nil then
		local want = expected.side_offset
		if math.abs(want) < 0.1 then
			table.insert(checks, {
				name = "orientation_side",
				pass = true,
				value = nil,
				expected = want,
				detail = "symmetric in X (side_offset under 0.1 studs): a mirrored import looks identical",
			})
		else
			local c, err = centroid()
			if c == nil then
				table.insert(checks, notChecked("orientation_side", nil, want, tostring(err)))
			else
				local side = c[1] - mid[1]
				local ok = sameOffset(side, want)
				local mirrored = not ok and sameOffset(-side, want)
				table.insert(checks, {
					name = "orientation_side",
					pass = ok,
					value = side,
					expected = want,
					detail = if ok
						then nil
						elseif
							mirrored
						then "mirrored along X: Studio maps Blender X differently from bkit/expectation.py (record the observed mapping)"
						else "side offset differs from Blender: wrong axis mapping or changed geometry",
				})
			end
		end
	end

	-- Geometry: the imported triangle count against Blender's. Topology should survive exactly; allow
	-- 1% (at least 1) for faces the importer drops as degenerate.
	if expected.triangles == nil then
		table.insert(checks, notChecked("triangle_count", nil, nil, "expectation has no triangles"))
	else
		local tris, err = triangles()
		if tris == nil then
			table.insert(checks, notChecked("triangle_count", nil, expected.triangles, tostring(err)))
		else
			local slack = math.max(1, math.floor(expected.triangles * 0.01))
			local ok = math.abs(#tris - expected.triangles) <= slack
			table.insert(checks, {
				name = "triangle_count",
				pass = ok,
				value = #tris,
				expected = expected.triangles,
				detail = if ok
					then nil
					else `{#tris} triangles, Blender exported {expected.triangles}: wrong or stale mesh, or the importer simplified it`,
			})
		end
	end

	-- Collision: props should not use expensive precise collision by default.
	local precise = 0
	for _, part in parts do
		local fidelity = tostring(part.CollisionFidelity)
		if string.find(fidelity, "PreciseConvexDecomposition") then
			precise += 1
		end
	end
	table.insert(checks, {
		name = "collision_fidelity",
		pass = precise == 0,
		value = precise,
		expected = 0,
		detail = "Box/Hull/Default for props",
	})

	-- Appearance: per-material base colours import as one grey part colour (gap row B06). A factory
	-- expectation names the baked route (`appearance`); an older one only lists materials, and then an
	-- asset with more than one needs a texture, a SurfaceAppearance or vertex colours on every part.
	local materials = expected.materials
	if expected.appearance ~= nil then
		for _, c in appearanceChecks(parts, expected.appearance, readColours) do
			table.insert(checks, c)
		end
	elseif materials == nil then
		table.insert(checks, notChecked("appearance_bound", nil, nil, "expectation has no materials list"))
	elseif #materials <= 1 then
		table.insert(checks, {
			name = "appearance_bound",
			pass = true,
			value = #materials,
			expected = "<= 1 material",
			detail = "one material: no binding needed (the part Color is not compared)",
		})
	else
		local bound, unread = 0, nil
		for _, part in parts do
			local textured = (part.TextureID and part.TextureID ~= "")
				or part:FindFirstChildOfClass("SurfaceAppearance") ~= nil
			local colours, err = nil, nil
			if not textured then
				colours, err = readColours(part)
				unread = if colours == nil then err else unread
			end
			if textured or (colours ~= nil and colours > 1) then
				bound += 1
			end
		end
		local ok = bound == #parts
		table.insert(checks, {
			name = "appearance_bound",
			pass = ok,
			value = bound,
			expected = #parts,
			detail = if ok
				then nil
				else `material colours lost: {#parts - bound} of {#parts} parts have no TextureID, SurfaceAppearance or vertex colours for {#materials} materials (bake a texture, gap B06)`
					.. (if unread then `; vertex colours unreadable: {unread}` else ""),
		})
	end

	local pass, skipped = true, {}
	for _, c in checks do
		pass = pass and c.pass
		if c.checked == false then
			table.insert(skipped, c.name)
		end
	end
	return { pass = pass, checks = checks, notChecked = skipped }
end

-- Compare two inspections of the same asset across revisions (the update workflow): bounding size,
-- triangle count and surface offsets. A measurement missing from either report is listed in
-- `notCompared` and never counts as a change.
function ImportInspector.compareRevisions(
	before: { checks: { Check } },
	after: { checks: { Check } }
): {
	changed: boolean,
	differences: { string },
	notCompared: { string },
	sizeBefore: any,
	sizeAfter: any,
	trianglesBefore: number?,
	trianglesAfter: number?,
	offsetsBefore: any,
	offsetsAfter: any,
}
	local function value(r, name: string): any
		for _, c in r.checks do
			if c.name == name then
				return c.value
			end
		end
		return nil
	end
	local function offsets(r): any
		local v = value(r, "orientation_front")
		return if type(v) == "table" and v.front ~= nil then v else nil
	end
	local sizeA, sizeB = value(before, "scale"), value(after, "scale")
	local trisA, trisB = value(before, "triangle_count"), value(after, "triangle_count")
	local offA, offB = offsets(before), offsets(after)
	local differences, notCompared = {}, {}
	local function compare(name: string, a: any, b: any, differ: (any, any) -> boolean)
		if a == nil or b == nil then
			table.insert(notCompared, name)
		elseif differ(a, b) then
			table.insert(differences, name)
		end
	end
	compare("size", sizeA, sizeB, function(a, b)
		return a[1] ~= b[1] or a[2] ~= b[2] or a[3] ~= b[3]
	end)
	compare("triangles", trisA, trisB, function(a, b)
		return a ~= b
	end)
	compare("surface_offsets", offA, offB, function(a, b)
		return a.front ~= b.front or a.up ~= b.up
	end)
	return {
		changed = #differences > 0,
		differences = differences,
		notCompared = notCompared,
		sizeBefore = sizeA,
		sizeAfter = sizeB,
		trianglesBefore = trisA,
		trianglesAfter = trisB,
		offsetsBefore = offA,
		offsetsAfter = offB,
	}
end

-- ---------------------------------------------------------------- clips (clips/1 sidecar)

local SLOTS = {
	"idle",
	"walk",
	"run",
	"jump",
	"fall",
	"climb",
	"swim",
	"sit",
	"land",
	"action_1",
	"action_2",
	"action_3",
	"action_4",
	"action_5",
	"action_6",
	"action_7",
	"action_8",
}
local PRIORITIES = { "Core", "Idle", "Movement", "Action", "Action2", "Action3", "Action4" }
local RIGS = { "r15_pose", "r15_avatar", "custom" }

local function isInteger(v: any): boolean
	return type(v) == "number" and v == math.floor(v) and v == v
end

local function isLabel(v: any, maxLength: number): boolean
	return type(v) == "string" and #v <= maxLength and string.match(v, "^[a-z][a-z0-9_]*$") ~= nil
end

-- Problems with a clips/1 table (docs/runtime-kits.md 9.4); empty when valid. Mirrors
-- tools/blender/bkit/formats.py validate_clips.
function ImportInspector.validateClips(data: any): { string }
	local problems = {}
	if type(data) ~= "table" or data.schema ~= "clips/1" then
		return { "schema must be 'clips/1'" }
	end
	if not isLabel(data.asset, 64) then
		table.insert(problems, "asset must be a label")
	end
	if not table.find(RIGS, data.rig) then
		table.insert(problems, "rig must be r15_pose, r15_avatar or custom")
	end
	if not isInteger(data.fps) or data.fps <= 0 then
		table.insert(problems, "fps must be an integer > 0")
	end
	local files = data.files
	if type(files) ~= "table" or type(files.glb) ~= "string" or type(files.fbx) ~= "table" then
		table.insert(problems, "files must be { glb = <file>, fbx = { [clip] = <file> } }")
	end
	if type(data.clips) ~= "table" or #data.clips == 0 then
		table.insert(problems, "clips must be a non-empty list")
		return problems
	end
	local seen = {}
	for i, clip in data.clips do
		local where = `clips[{i}]`
		if type(clip) ~= "table" then
			table.insert(problems, where .. ": not a table")
			continue
		end
		if not isLabel(clip.name, 48) then
			table.insert(problems, where .. ": name must match ^[a-z][a-z0-9_]{0,47}$")
		elseif seen[clip.name] then
			table.insert(problems, where .. ": duplicate name " .. clip.name)
		else
			seen[clip.name] = true
			where = clip.name
			if
				type(files) == "table"
				and type(files.fbx) == "table"
				and type(files.fbx[clip.name]) ~= "string"
			then
				table.insert(problems, where .. ": files.fbx has no file for this clip")
			end
		end
		if clip.slot ~= nil and not table.find(SLOTS, clip.slot) then
			table.insert(problems, where .. ": slot " .. tostring(clip.slot) .. " is not a standard slot")
		end
		local start, finish = clip.start, clip["end"]
		local rangeOk = isInteger(start) and isInteger(finish) and finish >= start and start >= 0
		if not rangeOk then
			table.insert(problems, where .. ": start and end must be integers with end >= start >= 0")
		end
		if type(clip.loop) ~= "boolean" or type(clip.root_motion) ~= "boolean" then
			table.insert(problems, where .. ": loop and root_motion must be booleans")
		end
		if clip.priority ~= nil and not table.find(PRIORITIES, clip.priority) then
			table.insert(problems, where .. ": priority must be an Enum.AnimationPriority name")
		end
		if clip.weight ~= nil and (type(clip.weight) ~= "number" or clip.weight <= 0) then
			table.insert(problems, where .. ": weight must be a number > 0")
		end
		if type(clip.markers) ~= "table" then
			table.insert(problems, where .. ": markers must be a list")
			continue
		end
		for _, marker in clip.markers do
			if type(marker) ~= "table" or not isLabel(marker.name, 64) or not isInteger(marker.frame) then
				table.insert(problems, where .. ": marker needs a label name and an integer frame")
			elseif rangeOk and (marker.frame < start or marker.frame > finish) then
				table.insert(
					problems,
					where .. `: marker {marker.name} at frame {marker.frame} outside {start}..{finish}`
				)
			elseif marker.param ~= nil and type(marker.param) ~= "string" then
				table.insert(problems, where .. `: marker {marker.name} param must be a string`)
			end
		end
	end
	return problems
end

-- An animation as found after import: name (Studio may prefix the take, "<rig>|<clip>"), length in
-- seconds, and markers when the file carried any.
export type ClipObservation = {
	name: string,
	length: number?,
	loop: boolean?,
	priority: string?,
	markers: { { name: string, time: number, param: string? } }?,
	-- Where it was found (studioClips sets it, for the probe's record of the importer's layout).
	path: string?,
}
export type ClipPlan = {
	name: string,
	slot: string?,
	length: number,
	looped: boolean,
	priority: string?,
	weight: number?,
	markers: { { name: string, time: number, param: string? } },
}
export type ClipsReport = {
	pass: boolean,
	checks: { Check },
	notChecked: { string },
	plan: { ClipPlan },
	extra: { string },
}

local function observedClip(observed: { ClipObservation }, name: string): ClipObservation?
	for _, o in observed do
		local tail = string.match(o.name, "[|/]([^|/]+)$")
		if o.name == name or tail == name then
			return o
		end
	end
	return nil
end

-- Compares imported animations with a clips/1 sidecar: the sidecar validates, every clip arrived
-- under its name, each lasts (end - start) / fps within half a frame, and markers that arrived sit
-- where the sidecar puts them. Files do not carry markers or looping (UNVERIFIED for FBX markers),
-- so `plan` lists per clip what AnimSet applies at play time: Looped, Priority, the marker times
-- for GetMarkerReachedSignal. `extra` lists imported animations the sidecar does not name.
function ImportInspector.inspectClips(sidecar: any, observed: { ClipObservation }): ClipsReport
	local checks: { Check } = {}
	local plan: { ClipPlan } = {}
	local problems = ImportInspector.validateClips(sidecar)
	table.insert(checks, {
		name = "sidecar_valid",
		pass = #problems == 0,
		value = problems,
		expected = {},
		detail = if #problems == 0 then nil else table.concat(problems, "; "),
	})
	if #problems > 0 then
		return { pass = false, checks = checks, notChecked = {}, plan = plan, extra = {} }
	end
	local fps = sidecar.fps
	local matched = {}
	for _, clip in sidecar.clips do
		local length = (clip["end"] - clip.start) / fps
		local markers = {}
		for _, m in clip.markers do
			table.insert(markers, { name = m.name, time = (m.frame - clip.start) / fps, param = m.param })
		end
		table.insert(plan, {
			name = clip.name,
			slot = clip.slot,
			length = length,
			looped = clip.loop,
			priority = clip.priority,
			weight = clip.weight,
			markers = markers,
		})
		local found = observedClip(observed, clip.name)
		table.insert(checks, {
			name = "clip_present:" .. clip.name,
			pass = found ~= nil,
			value = if found then found.name else nil,
			expected = clip.name,
			detail = if found
				then nil
				else "not imported (or renamed): import the multi-clip GLB or the clip's FBX",
		})
		if found == nil then
			continue
		end
		matched[found] = true
		if found.length == nil then
			table.insert(
				checks,
				notChecked(
					"clip_length:" .. clip.name,
					nil,
					length,
					"the imported animation has no readable length"
				)
			)
		else
			local ok = math.abs(found.length - length) <= 0.5 / fps + 1e-6
			table.insert(checks, {
				name = "clip_length:" .. clip.name,
				pass = ok,
				value = found.length,
				expected = length,
				detail = if ok
					then nil
					else string.format(
						"%.4f s imported, %.4f s in the sidecar: frame range or fps lost on export (FBX start/end keying, NLA strip)",
						found.length,
						length
					),
			})
		end
		local got = found.markers or {}
		if #got == 0 then
			table.insert(checks, {
				name = "clip_markers:" .. clip.name,
				pass = true,
				value = 0,
				expected = #markers,
				detail = if #markers > 0
					then "no markers in the import: AnimSet takes them from the plan"
					else nil,
			})
		else
			local missing = {}
			for _, want in markers do
				local hit = false
				for _, m in got do
					if m.name == want.name and math.abs(m.time - want.time) <= 0.5 / fps + 1e-6 then
						hit = true
					end
				end
				if not hit then
					table.insert(missing, string.format("%s@%.3f", want.name, want.time))
				end
			end
			table.insert(checks, {
				name = "clip_markers:" .. clip.name,
				pass = #missing == 0 and #got == #markers,
				value = #got,
				expected = #markers,
				detail = if #missing == 0 and #got == #markers
					then nil
					else "imported markers differ from the sidecar: " .. table.concat(missing, ", "),
			})
		end
	end
	local extra = {}
	for _, o in observed do
		if not matched[o] then
			table.insert(extra, o.name)
		end
	end
	local pass, skipped = true, {}
	for _, c in checks do
		pass = pass and c.pass
		if c.checked == false then
			table.insert(skipped, c.name)
		end
	end
	return { pass = pass, checks = checks, notChecked = skipped, plan = plan, extra = extra }
end

-- Studio reader: the animations under `root` (KeyframeSequence, CurveAnimation), with
-- KeyframeSequence lengths (last keyframe time) and markers, and each one's full name as `path`.
-- The Animation Clip Editor saves to ServerStorage.RBX_ANIMSAVES (research); where the 3D Importer
-- stores imported clips is UNVERIFIED, so the probe tests/engine/import_clips.luau scans the model
-- and RBX_ANIMSAVES and records the paths it found.
function ImportInspector.studioClips(root: any): { ClipObservation }
	local out: { ClipObservation } = {}
	local function where(d: any): string?
		local ok, full = pcall(function()
			return d:GetFullName()
		end)
		return if ok then full else nil
	end
	for _, d in root:GetDescendants() do
		if d:IsA("KeyframeSequence") then
			local length, markers = 0, {}
			for _, keyframe in d:GetKeyframes() do
				length = math.max(length, keyframe.Time)
				for _, marker in keyframe:GetMarkers() do
					table.insert(markers, { name = marker.Name, time = keyframe.Time, param = marker.Value })
				end
			end
			table.insert(out, {
				name = d.Name,
				length = length,
				loop = d.Loop,
				priority = d.Priority.Name,
				markers = markers,
				path = where(d),
			})
		elseif d:IsA("CurveAnimation") then
			table.insert(
				out,
				{ name = d.Name, length = nil, loop = d.Loop, priority = d.Priority.Name, path = where(d) }
			)
		end
	end
	return out
end

return ImportInspector
