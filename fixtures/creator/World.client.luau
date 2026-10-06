--!strict
-- Neutral query fixture; creates and cleans only this script's explicitly owned root.
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
assert(
	RunService:IsStudio() and game.GameId == 0 and game.PlaceId == 0,
	"unpublished SETUP_ONLY fixture required"
)
local WorldInspector = require(game:GetService("ReplicatedStorage").Workbench.Creator.WorldInspector)
local receipt = Instance.new("StringValue")
receipt.Name, receipt.Parent =
	"WorkbenchCreatorWorldEvidence", Players.LocalPlayer:WaitForChild("PlayerScripts")
local owner = Instance.new("Folder")
owner.Name, owner.Parent = "WorkbenchCreatorWorldFixture", workspace
owner:SetAttribute("WorkbenchOwned", true)
local geometry = Instance.new("Folder")
geometry.Name, geometry.Parent = "Geometry", owner
geometry:SetAttribute("WorkbenchOwned", true)
local function block(name, position, size, parent)
	local part = Instance.new("Part")
	part.Name, part.Position, part.Size = name, position, size
	part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery = true, false, false, true
	part.Color, part.Parent = Color3.fromRGB(98, 143, 176), parent
	return part
end
local left = block("NeutralLeft", Vector3.new(0, 200, 0), Vector3.new(4, 4, 4), geometry)
local right = block("NeutralRight", Vector3.new(8, 200, 0), Vector3.new(4, 4, 4), geometry)
local rotated = block("NeutralRotated", Vector3.new(0, 200, 8), Vector3.new(2, 4, 6), geometry)
rotated.CFrame *= CFrame.Angles(0, math.pi / 4, 0)
local sentinel = block("OutsideInspectionScope", Vector3.new(16, 200, 0), Vector3.new(4, 4, 4), owner)
local report: any = {
	schema_version = 1,
	mode = "SETUP_ONLY",
	method = "assisted_native_diagnostic",
	status = "partially_verified",
	target = { universe_id = game.GameId, place_id = game.PlaceId },
	checks = {},
	limitations = {
		"Four neutral anchored blocks; no game layout, route or spawn-system acceptance.",
		"Include-only bounding-box overlap and current CanQuery sightline diagnostics; no accurate contact, player sweep or navigability certification.",
		"Source readback, actual target identity and native captures must be retained separately.",
	},
}
local function check(name, passed)
	table.insert(report.checks, { name = name, passed = passed == true })
end
local inspector
local ok, failure = pcall(function()
	inspector = WorldInspector.new({ root = geometry })
	local result = inspector:inspect({
		spawns = {
			{ id = "clear-spawn", cframe = CFrame.new(16, 200, 0), size = Vector3.new(2, 2, 2) },
			{ id = "blocked-spawn", cframe = CFrame.new(0, 200, 0), size = Vector3.new(2, 2, 2) },
			{ id = "noncollidable-spawn", cframe = CFrame.new(8, 200, 0), size = Vector3.new(2, 2, 2) },
		},
		sightlines = {
			{ id = "clear-ray", origin = Vector3.new(13, 200, 0), destination = Vector3.new(19, 200, 0) },
			{ id = "blocked-ray", origin = Vector3.new(-6, 200, 0), destination = Vector3.new(6, 200, 0) },
		},
	})
	report.inspection = result
	check(
		"owned parts and bounded grid inspected",
		result.summary.parts == 3
			and result.summary.descendants == 3
			and result.summary.occupied_grid_cells > 0
			and result.summary.cell_references <= result.limits.max_cell_references
	)
	local rotatedWidth = 0
	for _, row in result.parts do
		if row.position[3] == 8 then
			rotatedWidth = row.maximum[1] - row.minimum[1]
		end
	end
	check("rotated bounds include projected size", rotatedWidth > 5.65 and rotatedWidth < 5.67)
	check(
		"clear spawn excludes outside-scope sentinel",
		result.spawns[1].clear_of_owned_query_bounds and #result.spawns[1].overlapping_part_ids == 0
	)
	check(
		"blocked spawn reports owned overlaps",
		not result.spawns[2].clear_of_owned_query_bounds and #result.spawns[2].overlapping_part_ids == 1
	)
	check(
		"noncollidable query geometry included",
		not right.CanCollide and not result.spawns[3].clear_of_owned_query_bounds
	)
	check(
		"clear ray excludes outside-scope sentinel",
		result.sightlines[1].clear_of_owned_query_geometry and result.sightlines[1].hit == nil
	)
	check(
		"blocked ray reports owned geometry",
		not result.sightlines[2].clear_of_owned_query_geometry and result.sightlines[2].hit ~= nil
	)
	check(
		"ray hit distance within requested segment",
		result.sightlines[2].hit.distance > 3.99
			and result.sightlines[2].hit.distance < 4.01
			and result.sightlines[2].hit.distance <= result.sightlines[2].length
	)
	left.CanQuery = false
	local filtered = inspector:inspect({
		spawns = { { id = "unqueryable-spawn", cframe = left.CFrame, size = Vector3.new(2, 2, 2) } },
		sightlines = {
			{
				id = "unqueryable-ray",
				origin = Vector3.new(-6, 200, 0),
				destination = Vector3.new(6, 200, 0),
			},
		},
	})
	left.CanQuery = true
	check(
		"unqueryable geometry excluded",
		filtered.spawns[1].clear_of_owned_query_bounds
			and filtered.sightlines[1].clear_of_owned_query_geometry
	)
	check("invalid spawn bounds rejected", not pcall(function()
		inspector:inspect({
			spawns = { { id = "invalid", cframe = CFrame.new(), size = Vector3.new(-1, 1, 1) } },
		})
	end))
	check("nonfinite spawn transform rejected", not pcall(function()
		inspector:inspect({
			spawns = { { id = "invalid", cframe = CFrame.new(0 / 0, 200, 0), size = Vector3.one } },
		})
	end))
	check("zero length sightline rejected", not pcall(function()
		inspector:inspect({
			sightlines = { { id = "invalid", origin = Vector3.zero, destination = Vector3.zero } },
		})
	end))
	check("excessive sightline length rejected", not pcall(function()
		inspector:inspect({
			sightlines = { { id = "invalid", origin = Vector3.zero, destination = Vector3.new(2000, 0, 0) } },
		})
	end))
	check("query budget rejected", not pcall(function()
		WorldInspector.new({ root = geometry, limits = { max_queries = 1 } }):inspect({
			spawns = {
				{ id = "a", cframe = CFrame.new(), size = Vector3.one },
				{ id = "b", cframe = CFrame.new(), size = Vector3.one },
			},
		})
	end))
	check("dictionary query bypass rejected", not pcall(function()
		inspector:inspect({
			spawns = { hidden = { id = "hidden", cframe = CFrame.new(), size = Vector3.one } },
		})
	end))
	check("part budget rejected", not pcall(function()
		WorldInspector.new({ root = geometry, limits = { max_parts = 2 } }):inspect({})
	end))
	check("descendant budget rejected", not pcall(function()
		WorldInspector.new({ root = geometry, limits = { max_parts = 2, max_descendants = 2 } }):inspect({})
	end))
	check("grid reference budget rejected", not pcall(function()
		WorldInspector.new({ root = geometry, limits = { max_cell_references = 1 } }):inspect({})
	end))
	check("grid cell budget rejected", not pcall(function()
		WorldInspector.new({ root = geometry, limits = { max_grid_cells = 1 } }):inspect({})
	end))
	check("geometry extent budget rejected", not pcall(function()
		WorldInspector.new({ root = geometry, limits = { max_extent = 8 } }):inspect({})
	end))
	check("unowned root rejected", not pcall(function()
		WorldInspector.new({ root = workspace })
	end))
	check("nonfinite budget rejected", not pcall(function()
		WorldInspector.new({ root = geometry, limits = { max_ray_distance = math.huge } })
	end))
	inspector:destroy()
	inspector:destroy()
	check(
		"inspector destroy preserves caller geometry",
		geometry.Parent == owner and left.Parent == geometry and sentinel.Parent == owner
	)
	check("destroyed inspector rejects queries", not pcall(inspector.inspect, inspector, {}))
end)
if inspector then
	inspector:destroy()
end
owner:Destroy()
check(
	"fixture cleanup removes only owned root",
	owner.Parent == nil and geometry.Parent == nil and sentinel.Parent == nil
)
if not ok then
	report.status, report.error = "blocked", tostring(failure)
else
	for _, row in report.checks do
		if not row.passed then
			report.status = "blocked"
		end
	end
end
receipt.Value = HttpService:JSONEncode(report)
if report.status == "blocked" then
	warn("World inspection diagnostic blocked; inspect WorkbenchCreatorWorldEvidence")
end
