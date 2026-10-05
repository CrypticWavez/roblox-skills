--!strict
-- Studio half of the Blender -> Roblox round trip. Compares an imported MeshPart/Model with
-- the `roblox_expectation_vN.json` written by tools/blender/factory.py roundtrip.
-- Run in Studio (command bar, Studio MCP execute_luau, or a plugin):
--   local Inspector = require(path.to.Pipeline.ImportInspector)
--   local report = Inspector.inspect(workspace.SM_RoundTripMarker, expectation)
-- Pure functions over instance-like tables, so the logic is unit-tested in Lune with mocks. The front
-- check reads the mesh's triangles (EditableMesh in Studio); tests inject `options.triangles`.
local ImportInspector = {}

export type Expectation = {
	asset: string,
	revision: number,
	size: { number }, -- studs, Roblox axes (x, y up, z back)
	front: string?, -- "-Z"
	-- Area-weighted surface centroid minus bounds centre, measured in Blender along the declared front
	-- and up axes (studs). Intrinsic to the shape, so the check assumes no exporter axis mapping.
	front_offset: number?,
	up_offset: number?,
	pivot: string?, -- "base-centre"
	materials: { string }?,
	triangles: number?,
	tolerance: number?,
}

export type Check = { name: string, pass: boolean, value: any, expected: any?, detail: string? }

-- Returns a part's triangles as three {x, y, z} world-space points each, or nil and a reason.
export type TriangleReader = (part: any) -> ({ { { number } } }?, string?)
export type Options = { triangles: TriangleReader? }

local function near(a: number, b: number, tol: number): boolean
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

-- Studio reader: the MeshPart's mesh via EditableMesh, scaled from mesh space to the part's Size
-- and placed by its CFrame. Needs edit access to the mesh (true for your own fresh import).
function ImportInspector.studioTriangles(part: any): ({ { { number } } }?, string?)
	local ok, result = pcall(function()
		local AssetService = (game :: any):GetService("AssetService")
		local opened, mesh = pcall(AssetService.CreateEditableMeshAsync, AssetService, part.MeshContent)
		if not opened or mesh == nil then
			mesh = AssetService:CreateEditableMeshAsync((Content :: any).fromUri(part.MeshId))
		end
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

-- Area-weighted centroid of all parts' surfaces (robust to how the importer splits triangles).
local function surfaceCentroid(parts: { any }, read: TriangleReader): ({ number }?, string?)
	local sum, total = { 0, 0, 0 }, 0
	for _, part in parts do
		local tris, err = read(part)
		if tris == nil then
			return nil, err
		end
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
	end
	if total <= 0 then
		return nil, "mesh has no surface area"
	end
	return { sum[1] / total, sum[2] / total, sum[3] / total }
end

local function sameOffset(observed: number, expected: number): boolean
	return math.abs(observed - expected) <= math.max(0.1, math.abs(expected) * 0.2)
end

function ImportInspector.inspect(
	root: any,
	expected: Expectation,
	options: Options?
): { pass: boolean, checks: { Check } }
	local tol = expected.tolerance or 0.05
	local checks: { Check } = {}
	local parts = ImportInspector.meshParts(root)
	table.insert(checks, { name = "mesh_present", pass = #parts > 0, value = #parts, expected = ">=1" })
	if #parts == 0 then
		return { pass = false, checks = checks }
	end
	local mn, mx, rotated = aabb(parts)
	local size = { mx[1] - mn[1], mx[2] - mn[2], mx[3] - mn[3] }
	local sizeOk = near(size[1], expected.size[1], tol)
		and near(size[2], expected.size[2], tol)
		and near(size[3], expected.size[3], tol)
	local swapped = not sizeOk
		and near(size[1], expected.size[1], tol)
		and near(size[2], expected.size[3], tol)
		and near(size[3], expected.size[2], tol)
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

	-- Pivot: model/part pivot should sit at the bottom centre of the bounds.
	local pivot = if root.GetPivot then root:GetPivot().Position else parts[1].CFrame.Position
	local centre = { (mn[1] + mx[1]) / 2, mn[2], (mn[3] + mx[3]) / 2 }
	local p = vec(pivot)
	local pivotOk = near(p[1], centre[1], tol) and near(p[2], centre[2], tol) and near(p[3], centre[3], tol)
	table.insert(checks, {
		name = "pivot_base_centre",
		pass = pivotOk or expected.pivot ~= "base-centre",
		value = p,
		expected = centre,
		detail = if pivotOk then nil else "set PivotOffset or fix origin in Blender",
	})

	-- Front: a part named *Front* (split imports) must lie on the -Z side of the centre. A single mesh
	-- is checked by where its surface centroid sits relative to the bounds centre, compared with
	-- the same measurement taken in Blender. Anything undetermined fails: never assume facing.
	if expected.front then
		local mid = { (mn[1] + mx[1]) / 2, (mn[2] + mx[2]) / 2, (mn[3] + mx[3]) / 2 }
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
			local read = (options and options.triangles) or ImportInspector.studioTriangles
			local centroid, err = surfaceCentroid(parts, read)
			if centroid == nil then
				check = {
					name = "orientation_front",
					pass = false,
					value = nil,
					expected = expected.front_offset,
					detail = `front undetermined: {err} - confirm facing with screen_capture`,
				}
			else
				local front, up = mid[3] - centroid[3], centroid[2] - mid[2] -- front is -Z, up is +Y
				local frontOk = sameOffset(front, expected.front_offset)
				local upOk = expected.up_offset == nil or sameOffset(up, expected.up_offset)
				check = {
					name = "orientation_front",
					pass = frontOk and upOk,
					value = { front = front, up = up },
					expected = { front = expected.front_offset, up = expected.up_offset },
					detail = if frontOk and upOk
						then nil
						elseif
							not frontOk and sameOffset(-front, expected.front_offset)
						then "asset faces +Z (turned 180 degrees): fix the FBX forward axis or rotate before export"
						elseif
							not upOk
							and expected.up_offset
							and sameOffset(-up, expected.up_offset)
						then "asset is upside down: fix the FBX up axis"
						else "surface centroid differs from Blender: wrong axis mapping or changed geometry",
				}
			end
		end
		table.insert(checks, check)
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

	-- Appearance: textures or SurfaceAppearance present when materials were exported.
	local appearance = 0
	for _, part in parts do
		if (part.TextureID and part.TextureID ~= "") or part:FindFirstChildOfClass("SurfaceAppearance") then
			appearance += 1
		end
	end
	table.insert(checks, {
		name = "appearance_bound",
		pass = true,
		value = appearance,
		detail = "informational: vertex/material colours may import as part colour only",
	})

	local pass = true
	for _, c in checks do
		pass = pass and c.pass
	end
	return { pass = pass, checks = checks }
end

-- Compare two inspections of the same asset across revisions (the update workflow).
function ImportInspector.compareRevisions(
	before: { checks: { Check } },
	after: { checks: { Check } }
): { changed: boolean, sizeBefore: any, sizeAfter: any }
	local function sizeOf(r)
		for _, c in r.checks do
			if c.name == "scale" then
				return c.value
			end
		end
		return nil
	end
	local a, b = sizeOf(before), sizeOf(after)
	local changed = a == nil or b == nil or a[1] ~= b[1] or a[2] ~= b[2] or a[3] ~= b[3]
	return { changed = changed, sizeBefore = a, sizeAfter = b }
end

return ImportInspector
