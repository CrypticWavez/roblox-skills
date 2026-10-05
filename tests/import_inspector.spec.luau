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

local expectation = {
	asset = "SM_RoundTripMarker",
	revision = 1,
	size = { 4, 7, 3.5 },
	front = "-Z",
	pivot = "base-centre",
	tolerance = 0.05,
}

test("correct import passes", function(t)
	local report =
		Inspector.inspect(meshPart("SM_RoundTripMarker", { 4, 7, 3.5 }, { 0, 3.5, 0 }), expectation)
	for _, c in report.checks do
		t.ok(c.pass, c.name)
	end
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
