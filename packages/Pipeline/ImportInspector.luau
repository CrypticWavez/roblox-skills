--!strict
-- Studio half of the Blender -> Roblox round trip. Compares an imported MeshPart/Model with
-- the `roblox_expectation_vN.json` written by tools/blender/factory.py roundtrip.
-- Run in Studio (command bar, Studio MCP execute_luau, or a plugin):
--   local Inspector = require(path.to.Pipeline.ImportInspector)
--   local report = Inspector.inspect(workspace.SM_RoundTripMarker, expectation)
-- Pure functions over instance-like tables, so the logic is unit-tested in Lune with mocks.
local ImportInspector = {}

export type Expectation = {
	asset: string,
	revision: number,
	size: { number }, -- studs, Roblox axes (x, y up, z back)
	front: string?, -- "-Z"
	pivot: string?, -- "base-centre"
	materials: { string }?,
	triangles: number?,
	tolerance: number?,
}

export type Check = { name: string, pass: boolean, value: any, expected: any?, detail: string? }

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

function ImportInspector.inspect(root: any, expected: Expectation): { pass: boolean, checks: { Check } }
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

	-- Front marker: the part/material named *Front* should lie on the -Z side of the centre.
	if expected.front then
		local frontZ = nil
		for _, part in parts do
			if string.find(part.Name, "Front") or (part:GetAttribute("Material") == "MAT_Front") then
				frontZ = part.CFrame.Position.Z
			end
		end
		if frontZ ~= nil then
			table.insert(checks, {
				name = "orientation_front",
				pass = frontZ < (mn[3] + mx[3]) / 2,
				value = frontZ,
				expected = "< centre z (front -Z)",
			})
		else
			table.insert(checks, {
				name = "orientation_front",
				pass = size[3] < size[2],
				value = size,
				expected = "front marker not split; height > depth sanity",
				detail = "single mesh import: verify the orange front visually or via screen_capture",
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
