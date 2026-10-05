local roblox = require("@lune/roblox")
local Inspector = require("../packages/Pipeline/ImportInspector")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

-- Minimal MeshPart mock (Lune instances do not implement GetPivot/CollisionFidelity).
local function meshPart(name, size, pos, rotY)
	local cf = roblox.CFrame.new(pos[1], pos[2], pos[3])
		* roblox.CFrame.fromOrientation(0, math.rad(rotY or 0), 0)
	return {
		Name = name,
		Size = roblox.Vector3.new(size[1], size[2], size[3]),
		CFrame = cf,
		CollisionFidelity = "Enum.CollisionFidelity.Hull",
		TextureID = "",
		IsA = function(_, class)
			return class == "MeshPart"
		end,
		GetDescendants = function()
			return {}
		end,
		GetAttribute = function()
			return nil
		end,
		FindFirstChildOfClass = function()
			return nil
		end,
		GetPivot = function(self)
			return roblox.CFrame.new(pos[1], pos[2] - size[2] / 2, pos[3])
		end,
	}
end

-- The v1 marker as imported correctly (front -Z, up +Y): a body box and a nose box sticking out at -Z.
local BODY = { { -2, 0, -0.25 }, { 2, 7, 1.75 } }
local NOSE = { { -0.5, 2.5, -1.75 }, { 0.5, 3.5, -0.25 } }

-- Twelve world-space triangles covering an axis-aligned box.
local function boxTriangles(box, flipZ)
	local lo, hi = box[1], box[2]
	local function corner(i)
		local x = if i % 2 == 1 then hi[1] else lo[1]
		local y = if (i // 2) % 2 == 1 then hi[2] else lo[2]
		local z = if (i // 4) % 2 == 1 then hi[3] else lo[3]
		return { x, y, if flipZ then -z else z }
	end
	local quads =
		{ { 0, 1, 3, 2 }, { 4, 5, 7, 6 }, { 0, 1, 5, 4 }, { 2, 3, 7, 6 }, { 0, 2, 6, 4 }, { 1, 3, 7, 5 } }
	local tris = {}
	for _, q in quads do
		table.insert(tris, { corner(q[1]), corner(q[2]), corner(q[3]) })
		table.insert(tris, { corner(q[1]), corner(q[3]), corner(q[4]) })
	end
	return tris
end

local function markerReader(flipZ)
	return function()
		local tris = boxTriangles(BODY, flipZ)
		for _, tri in boxTriangles(NOSE, flipZ) do
			table.insert(tris, tri)
		end
		return tris
	end
end

-- Independent of the inspector's triangle integration: a closed box's surface centroid is its centre.
local function expectedOffsets()
	local sum, total = { 0, 0, 0 }, 0
	for _, box in { BODY, NOSE } do
		local d = { box[2][1] - box[1][1], box[2][2] - box[1][2], box[2][3] - box[1][3] }
		local area = 2 * (d[1] * d[2] + d[2] * d[3] + d[3] * d[1])
		total += area
		for i = 1, 3 do
			sum[i] += area * (box[1][i] + box[2][i]) / 2
		end
	end
	-- bounds: x -2..2, y 0..7, z -1.75..1.75 (centre 0, 3.5, 0); front is -Z, up is +Y
	return -sum[3] / total, sum[2] / total - 3.5
end

local frontOffset, upOffset = expectedOffsets()
local expectation = {
	asset = "SM_RoundTripMarker",
	revision = 1,
	size = { 4, 7, 3.5 },
	front = "-Z",
	front_offset = frontOffset,
	up_offset = upOffset,
	pivot = "base-centre",
	tolerance = 0.05,
}
local correct = { triangles = markerReader(false) }

local function check(report, name)
	for _, c in report.checks do
		if c.name == name then
			return c
		end
	end
	error("no check " .. name)
end

test("correct import passes", function(t)
	local report =
		Inspector.inspect(meshPart("SM_RoundTripMarker", { 4, 7, 3.5 }, { 0, 3.5, 0 }), expectation, correct)
	for _, c in report.checks do
		t.ok(c.pass, c.name)
	end
	t.ok(math.abs(frontOffset) > 0.1, "marker is asymmetric along its front axis")
end)

test("asset facing +Z fails the front check", function(t)
	local part = meshPart("SM_RoundTripMarker", { 4, 7, 3.5 }, { 0, 3.5, 0 })
	local front =
		check(Inspector.inspect(part, expectation, { triangles = markerReader(true) }), "orientation_front")
	t.ok(not front.pass)
	t.ok(string.find(front.detail, "faces %+Z"), front.detail)
end)

test("unreadable mesh leaves the front undetermined and fails", function(t)
	local part = meshPart("SM_RoundTripMarker", { 4, 7, 3.5 }, { 0, 3.5, 0 })
	local unreadable = {
		triangles = function()
			return nil, "no access"
		end,
	}
	local front = check(Inspector.inspect(part, expectation, unreadable), "orientation_front")
	t.ok(not front.pass)
	t.ok(string.find(front.detail, "undetermined"), front.detail)
	local legacy = table.clone(expectation)
	legacy.front_offset = nil
	t.ok(not check(Inspector.inspect(part, legacy, correct), "orientation_front").pass)
end)

test("split import uses the named front part", function(t)
	local root = meshPart("SM_RoundTripMarker", { 4, 7, 3.5 }, { 0, 3.5, 0 })
	local nose = meshPart("Front", { 1, 1, 1.5 }, { 0, 3, -1 })
	root.GetDescendants = function()
		return { nose }
	end
	t.ok(check(Inspector.inspect(root, expectation, correct), "orientation_front").pass)
	nose.CFrame = roblox.CFrame.new(0, 3, 1)
	t.ok(not check(Inspector.inspect(root, expectation, correct), "orientation_front").pass)
end)

test("metre-scaled import is diagnosed", function(t)
	local report =
		Inspector.inspect(meshPart("M", { 4 * 0.28, 7 * 0.28, 3.5 * 0.28 }, { 0, 1, 0 }), expectation)
	t.ok(not report.pass)
	t.ok(string.find(report.checks[2].detail, "Scale Unit"), report.checks[2].detail)
end)

test("Y/Z swap is diagnosed", function(t)
	local report = Inspector.inspect(meshPart("M", { 4, 3.5, 7 }, { 0, 1.75, 0 }), expectation)
	t.ok(string.find(report.checks[2].detail, "swapped"))
end)

test("rotated import and precise collision are flagged", function(t)
	local part = meshPart("M", { 4, 7, 3.5 }, { 0, 3.5, 0 }, 90)
	part.CollisionFidelity = "Enum.CollisionFidelity.PreciseConvexDecomposition"
	local report = Inspector.inspect(part, expectation)
	local failed = {}
	for _, c in report.checks do
		if not c.pass then
			failed[c.name] = true
		end
	end
	t.ok(failed.orientation_unrotated and failed.collision_fidelity)
end)

test("revision comparison detects updated geometry", function(t)
	local v1 = Inspector.inspect(meshPart("M", { 4, 7, 3.5 }, { 0, 3.5, 0 }), expectation)
	local v2 = Inspector.inspect(meshPart("M", { 4, 8, 4.5 }, { 0, 4, 0 }), expectation)
	t.ok(Inspector.compareRevisions(v1, v2).changed)
	t.ok(not Inspector.compareRevisions(v1, v1).changed)
end)

return cases
